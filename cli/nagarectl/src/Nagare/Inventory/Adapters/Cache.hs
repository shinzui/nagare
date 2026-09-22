-- | Reviewed, recoverable boundary for an Attic logical cache. The transport
-- supplies native observation and mutation; this adapter never assumes that a
-- successful command alone proves the generated signing key is available.
module Nagare.Inventory.Adapters.Cache
  ( CacheMutationPlan (..)
  , CacheObservation (..)
  , CacheAdapterOps (..)
  , cacheSpecsFromDeclarations
  , mkCacheAdapter
  ) where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data CacheMutationPlan = CacheMutationPlan
  { cachePlanVersion :: !Int
  , cachePlanOperation :: !OperationId
  , cachePlanAction :: !OperationAction
  , cachePlanInputDigest :: !ContentDigest
  , cachePlanResource :: !ResourceId
  , cachePlanCluster :: !ResourceId
  , cachePlanName :: !Name
  , cachePlanConfigurationDigest :: !ContentDigest
  } deriving stock (Eq, Show, Generic)

data CacheObservation
  = CacheMissing
  | CachePresent !PhysicalIdentity !ContentDigest !Text
  | CacheForeign !Text
  | CacheUnavailable !Text
  deriving stock (Eq, Show, Generic)

data CacheAdapterOps = CacheAdapterOps
  { cacheObserveResources :: !([ResourceId] -> IO (Either Text ObservationSet))
  , cacheInspect :: !(CacheMutationPlan -> IO CacheObservation)
  , cacheCreate :: !(CacheMutationPlan -> IO AdapterExecution)
  , cacheConfigure :: !(CacheMutationPlan -> IO AdapterExecution)
  }

cacheSpecsFromDeclarations :: [Declaration] -> Either Text (Map ResourceId ManagedResource)
cacheSpecsFromDeclarations declarations = Map.fromList <$> traverse cacheSpec managed
  where
    managed = [resource | Managed resource <- declarations, resource ^. #executor == CacheExecutor]
    cacheSpec resource = case (resource ^. #address, resource ^. #spec) of
      (AtticCache _ _, LogicalCache _) -> Right (resource ^. #identity, resource)
      _ -> Left ("cache resource lacks a logical Attic cache specification: " <> resourceIdText (resource ^. #identity))

mkCacheAdapter :: Map ResourceId ManagedResource -> CacheAdapterOps -> Adapter
mkCacheAdapter specs ops = Adapter
  { adapterExecutor = CacheExecutor
  , adapterIdentity = "reviewed-attic-cache"
  , adapterVersion = "1"
  , adapterObserve = cacheObserveResources ops
  , adapterPrepare = prepare
  , adapterPreflight = preflight
  , adapterExecute = execute
  , adapterVerify = verify
  , adapterRecover = recover
  }
  where
    prepare operation = pure $ do
      plan <- first (PrepareRefused (plannedOperationId operation)) (planFor specs operation)
      bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON plan))
      pure (PreparedNative bytes ("reconcile Attic cache " <> nameText (cachePlanName plan)))
    preflight operation prepared = case decodePlan specs operation (preparedNativeBytes prepared) of
      Left err -> pure (Left err)
      Right plan -> do
        observation <- cacheInspect ops plan
        pure (case observation of
          CacheForeign reason -> Left reason
          CacheUnavailable reason -> Left reason
          CacheMissing | plannedAction operation /= CreateResource -> Left "logical cache is absent"
          _ -> Right ())
    execute operation prepared = case decodePlan specs operation (preparedNativeBytes prepared) of
      Left err -> pure (AdapterEffectFailed (KnownNoEffect err))
      Right plan -> do
        observation <- cacheInspect ops plan
        case observation of
          CacheForeign reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          CacheUnavailable reason -> pure (AdapterEffectAmbiguous reason)
          CachePresent _ digest key | digest == cachePlanConfigurationDigest plan && not (T.null key) -> pure AdapterEffectCompleted
          CacheMissing | plannedAction operation == CreateResource -> cacheCreate ops plan
          CacheMissing -> pure (AdapterEffectFailed (KnownNoEffect "logical cache is absent"))
          CachePresent {} | plannedAction operation == CreateResource -> pure (AdapterEffectFailed (KnownNoEffect "named cache already exists with a different configuration"))
          CachePresent {} -> cacheConfigure ops plan
    verify operation prepared = case decodePlan specs operation (preparedNativeBytes prepared) of
      Left err -> pure (Left err)
      Right plan -> do
        observation <- cacheInspect ops plan
        pure (case observation of
          CachePresent physical digest key
            | digest == cachePlanConfigurationDigest plan && not (T.null key) -> Right (completionProof plan physical key)
          CachePresent {} -> Left "cache configuration or generated public key differs from review"
          CacheMissing -> Left "logical cache is absent"
          CacheForeign reason -> Left reason
          CacheUnavailable reason -> Left reason)
    recover operation prepared = case decodePlan specs operation (preparedNativeBytes prepared) of
      Left err -> pure (RecoveryUnresolved err)
      Right plan -> do
        observation <- cacheInspect ops plan
        pure (case observation of
          CachePresent physical digest key
            | digest == cachePlanConfigurationDigest plan && not (T.null key) -> RecoveryProvedComplete (completionProof plan physical key)
          CacheMissing | plannedAction operation == CreateResource -> RecoverySafeToRetry
          CacheMissing -> RecoveryUnresolved "logical cache is absent"
          CachePresent {} -> RecoveryUnresolved "cache configuration or generated public key differs from review"
          CacheForeign reason -> RecoveryUnresolved reason
          CacheUnavailable reason -> RecoveryUnresolved reason)

planFor :: Map ResourceId ManagedResource -> PlannedOperation -> Either Text CacheMutationPlan
planFor specs operation = do
  resource <- case NE.toList (plannedResources operation) of
    [single] -> Right single
    _ -> Left "cache operation must affect exactly one logical cache"
  declaration <- maybe (Left "cache resource is absent from the declaration bundle") Right (Map.lookup resource specs)
  (cluster, name, digest) <- case (declaration ^. #address, declaration ^. #spec) of
    (AtticCache cluster name, LogicalCache digest) -> Right (cluster, name, digest)
    _ -> Left "cache resource has an invalid address or specification"
  unless (plannedAction operation `elem` [CreateResource, UpdateResource, RunDeclaredOperation])
    (Left "cache adapter cannot adopt or retire a logical cache")
  pure (CacheMutationPlan 1 (plannedOperationId operation) (plannedAction operation) (plannedInputDigest operation) resource cluster name digest)

decodePlan :: Map ResourceId ManagedResource -> PlannedOperation -> ByteString -> Either Text CacheMutationPlan
decodePlan specs operation bytes = do
  plan <- first T.pack (eitherDecodeStrict bytes)
  expected <- planFor specs operation
  unless (plan == expected) (Left "private cache mutation differs from the reviewed declaration and operation")
  pure plan

completionProof :: CacheMutationPlan -> PhysicalIdentity -> Text -> ContentDigest
completionProof plan physical key = contentDigest (either (error . T.unpack) id (canonicalValue (object
  [ "plan" .= plan
  , "physicalIdentity" .= physical
  , "publicKeyDigest" .= contentDigest (TE.encodeUtf8 key)
  ])))

instance ToJSON CacheMutationPlan where
  toJSON plan = object
    [ "version" .= cachePlanVersion plan
    , "operation" .= cachePlanOperation plan
    , "action" .= cachePlanAction plan
    , "inputDigest" .= cachePlanInputDigest plan
    , "resource" .= cachePlanResource plan
    , "cluster" .= cachePlanCluster plan
    , "name" .= cachePlanName plan
    , "configurationDigest" .= cachePlanConfigurationDigest plan
    ]

instance FromJSON CacheMutationPlan where
  parseJSON = withObject "cache mutation plan" $ \o -> CacheMutationPlan
    <$> o .: "version" <*> o .: "operation" <*> o .: "action" <*> o .: "inputDigest"
    <*> o .: "resource" <*> o .: "cluster" <*> o .: "name" <*> o .: "configurationDigest"
