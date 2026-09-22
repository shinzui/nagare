-- | Explicit-context subprocess transport for the logical Attic cache.
-- The transport may mutate only the named Attic cache; Kubernetes workloads,
-- credentials and client configuration remain separate reviewed resources.
module Nagare.Inventory.Adapters.CacheRuntime
  ( CacheRuntimeConfig (..)
  , mkCacheRuntimeOps
  , cachePublicKeyFromObservation
  , cachePublicKeyForResource
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Cache
import Nagare.Inventory.Cache (logicalConfigurationDigest)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), mkOperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.Environment (getEnvironment)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)

data CacheRuntimeConfig = CacheRuntimeConfig
  { runtimeCacheExecutable :: !FilePath
  , runtimeCacheKubectlContext :: !Text
  , runtimeCacheContextId :: !ContextId
  , runtimeCacheGuard :: !(IO (Either Text ()))
  , runtimeCacheSpecs :: !(Map ResourceId ManagedResource)
  }

data CacheRequest = CacheRequest
  { requestVersion :: !Int
  , requestContext :: !Text
  , requestResource :: !ResourceId
  , requestCluster :: !ResourceId
  , requestName :: !Name
  } deriving stock (Eq, Show, Generic)

data CacheReply = ReplyMissing | ReplyPresent !Value
  deriving stock (Eq, Show)

mkCacheRuntimeOps :: CacheRuntimeConfig -> CacheAdapterOps
mkCacheRuntimeOps config = CacheAdapterOps
  { cacheObserveResources = \resources -> do
      observations <- traverse observe resources
      pure (sequence observations >>= observationSet)
  , cacheInspect = \plan -> inspect (cachePlanResource plan)
  , cacheCreate = mutate "create"
  , cacheConfigure = mutate "configure"
  }
  where
    observe resource = do
      state <- inspect resource
      pure $ case state of
        CacheMissing -> Right (resource, ConfirmedAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent"))))
        CachePresent physical _ _ -> Right (resource, ObservedPresent physical)
        CacheForeign reason -> Left reason
        CacheUnavailable reason -> Left reason
    inspect resource = case Map.lookup resource (runtimeCacheSpecs config) of
      Nothing -> pure (CacheUnavailable "cache resource is absent from the reviewed declaration")
      Just declaration -> case declaration ^. #address of
        AtticCache cluster name -> do
          result <- runTransport config "observe" (CacheRequest 1 (runtimeCacheKubectlContext config) resource cluster name)
          pure (either CacheUnavailable (replyToObservation config name) result)
        _ -> pure (CacheUnavailable "cache declaration has no Attic address")
    mutate action plan = case Map.lookup (cachePlanResource plan) (runtimeCacheSpecs config) of
      Nothing -> pure (AdapterEffectFailed (KnownNoEffect "cache resource is absent from the reviewed declaration"))
      Just declaration -> case declaration ^. #address of
        AtticCache cluster name
          | cluster == cachePlanCluster plan && name == cachePlanName plan -> do
              result <- runTransport config action (CacheRequest 1 (runtimeCacheKubectlContext config)
                (cachePlanResource plan) cluster name)
              pure $ case result of
                Left reason -> AdapterEffectAmbiguous reason
                Right reply -> case replyToObservation config name reply of
                  CachePresent _ digest key
                    | digest == cachePlanConfigurationDigest plan && not (T.null key) -> AdapterEffectCompleted
                  _ -> AdapterEffectAmbiguous "Attic cache mutation returned no matching configuration and public key"
          | otherwise -> pure (AdapterEffectFailed (KnownNoEffect "cache mutation differs from the reviewed address"))
        _ -> pure (AdapterEffectFailed (KnownNoEffect "cache declaration has no Attic address"))

cachePublicKeyFromObservation :: CacheAdapterOps -> CacheMutationPlan -> IO (Either Text Text)
cachePublicKeyFromObservation ops plan = do
  observed <- cacheInspect ops plan
  pure $ case observed of
    CachePresent _ digest key
      | digest == cachePlanConfigurationDigest plan && not (T.null key) -> Right key
    CacheMissing -> Left "logical cache is absent"
    CacheForeign reason -> Left reason
    CacheUnavailable reason -> Left reason
    CachePresent {} -> Left "logical cache configuration or signing key differs"

cachePublicKeyForResource :: CacheRuntimeConfig -> ResourceId -> IO (Either Text Text)
cachePublicKeyForResource config resource = case Map.lookup resource (runtimeCacheSpecs config) of
  Nothing -> pure (Left "cache public-key producer is absent from the reviewed declarations")
  Just declaration -> case (declaration ^. #address, declaration ^. #spec) of
    (AtticCache cluster name, LogicalCache digest) ->
      let operation = either (error . T.unpack) id (mkOperationId "op-cache-output")
          plan = CacheMutationPlan 1 operation RunDeclaredOperation (contentDigest "cache-output")
            resource cluster name digest
       in cachePublicKeyFromObservation (mkCacheRuntimeOps config) plan
    _ -> pure (Left "cache public-key producer has no logical cache specification")

runTransport :: CacheRuntimeConfig -> String -> CacheRequest -> IO (Either Text CacheReply)
runTransport config action request = do
  guarded <- runtimeCacheGuard config
  case guarded of
    Left reason -> pure (Left ("cache context guard refused: " <> reason))
    Right () -> case canonicalValue (toJSON request) of
      Left reason -> pure (Left reason)
      Right bytes -> do
        environment <- getEnvironment
        let childEnvironment = ("NAGARE_INVENTORY_ADAPTER_CHILD", "cache")
              : filter ((/= "NAGARE_INVENTORY_ADAPTER_CHILD") . fst) environment
            command = (proc (runtimeCacheExecutable config) [action]) {env = Just childEnvironment}
        result <- try (readCreateProcessWithExitCode command (T.unpack (TE.decodeUtf8 bytes)))
        pure $ case result of
          Left (_ :: IOException) -> Left "could not invoke cache transport"
          Right (ExitFailure _, _, _) -> Left "cache transport failed; inspect the target context before retry"
          Right (ExitSuccess, output, _) -> first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 (T.strip (T.pack output))))

replyToObservation :: CacheRuntimeConfig -> Name -> CacheReply -> CacheObservation
replyToObservation _ _ ReplyMissing = CacheMissing
replyToObservation config name (ReplyPresent value) = case parseEither cacheConfig value of
  Left _ -> CacheUnavailable "Attic cache configuration response is malformed"
  Right (public, retention, endpoint, apiEndpoint, publicKey)
    | T.null publicKey -> CacheUnavailable "Attic cache has no public signing key"
    | otherwise ->
        let expectedEndpoint = "http://nix-cache-internal.nagare-system.svc.cluster.local:8080/" <> nameText name
            digest = if public && retention == 2592000 && endpoint == expectedEndpoint
              && apiEndpoint == "http://127.0.0.1:18080/"
              then logicalConfigurationDigest
              else contentDigest (either (error . T.unpack) id (canonicalValue value))
            physical = either (error . T.unpack) id (mkPhysicalIdentity
              ("attic://" <> contextIdText (runtimeCacheContextId config) <> "/" <> nameText name))
         in CachePresent physical digest publicKey
  where
    cacheConfig :: Value -> Parser (Bool, Int, Text, Text, Text)
    cacheConfig = withObject "Attic cache config" $ \o -> do
      public <- o .: "is_public"
      retention <- o .: "retention_period" >>= withObject "retention" (.: "Period")
      endpoint <- o .: "substituter_endpoint"
      apiEndpoint <- o .: "api_endpoint"
      publicKey <- o .: "public_key"
      pure (public, retention :: Int, endpoint, apiEndpoint, publicKey)

instance ToJSON CacheRequest where
  toJSON request = object
    [ "version" .= requestVersion request
    , "context" .= requestContext request
    , "resource" .= requestResource request
    , "cluster" .= requestCluster request
    , "name" .= requestName request
    ]

instance FromJSON CacheReply where
  parseJSON = withObject "cache transport reply" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "missing" -> pure ReplyMissing
      "present" -> ReplyPresent <$> o .: "cache"
      _ -> fail "unknown cache transport reply kind"
