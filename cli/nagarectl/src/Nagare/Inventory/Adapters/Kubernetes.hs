-- | Reviewed Kubernetes mutations. The transport must perform the write with
-- the retained UID/resourceVersion precondition; re-observation alone is not
-- a mutation guard. No default transport is installed until it can enforce
-- that requirement for every supported kind.
module Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesState (..)
  , KubernetesMutation (..)
  , KubernetesAdapterOps (..)
  , mkKubernetesAdapter
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Aeson.Types (Parser)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The revision is the Kubernetes metadata.resourceVersion. The owner is
-- read from the guarded logical-identity stamp, never inferred from a name.
data KubernetesState
  = KubernetesAbsent !ContentDigest
  | KubernetesPresent !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesUnknown !Text
  deriving stock (Eq, Show, Generic)

-- | Private reviewed plan. The native JSON is the exact canonical object
-- submitted by the transport, including any private Secret fields.
data KubernetesMutation = KubernetesMutation
  { mutationVersion :: !Int
  , mutationOperation :: !OperationId
  , mutationInputDigest :: !ContentDigest
  , mutationAction :: !OperationAction
  , mutationResource :: !ResourceId
  , mutationAddress :: !ProviderAddress
  , mutationNativeJson :: !Text
  , mutationNativeDigest :: !ContentDigest
  , mutationBefore :: !KubernetesState
  }
  deriving stock (Eq, Generic)

data KubernetesAdapterOps = KubernetesAdapterOps
  { kubernetesObserve :: !(ResourceId -> IO KubernetesState)
  -- The implementation must make the write conditional on mutationBefore at
  -- the API server. A local compare followed by unrestricted apply is unsafe.
  , kubernetesMutateConditional :: !(KubernetesMutation -> IO AdapterExecution)
  }

mkKubernetesAdapter :: Map ResourceId (ManagedResource, ByteString) -> KubernetesAdapterOps -> Adapter
mkKubernetesAdapter specs ops =
  Adapter
    { adapterExecutor = KubernetesExecutor
    , adapterIdentity = "kubernetes-conditional-object"
    , adapterVersion = "1"
    , adapterObserve = observeAll
    , adapterPrepare = prepare
    , adapterPreflight = preflight
    , adapterExecute = execute
    , adapterVerify = verify
    , adapterRecover = recover
    }
  where
    observeAll resources = do
      states <- traverse (kubernetesObserve ops) resources
      pure (observationSet (zipWith toObservation resources states))
    toObservation resource state = (resource, case state of
      KubernetesAbsent proof -> ConfirmedAbsent proof
      KubernetesPresent physical _ _ _ -> ObservedPresent physical
      KubernetesUnknown reason -> ObservationUnavailable reason)
    prepare operation = case singleSpec specs operation of
      Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
      Right (resource, declaration, native) -> do
        before <- kubernetesObserve ops resource
        pure $ do
          validateBefore operation resource before
          mutation <- buildMutation operation resource declaration native before
          bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON mutation))
          pure (PreparedNative bytes (summary mutation))
    preflight operation prepared = case decodeMutation specs operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        pure (requireSameBefore mutation current)
    execute operation prepared = case decodeMutation specs operation prepared of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        case requireSameBefore mutation current of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right () -> kubernetesMutateConditional ops mutation
    verify operation prepared = case decodeMutation specs operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        pure (completionProof mutation current)
    recover operation prepared = case decodeMutation specs operation prepared of
      Left reason -> pure (RecoveryUnresolved reason)
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        pure $ case completionProof mutation current of
          Right proof -> RecoveryProvedComplete proof
          Left _ -> case requireSameBefore mutation current of
            Right () -> RecoverySafeToRetry
            Left reason -> RecoveryUnresolved reason

singleSpec :: Map ResourceId (ManagedResource, ByteString) -> PlannedOperation -> Either Text (ResourceId, ManagedResource, ByteString)
singleSpec specs operation = do
  unless (plannedExecutor operation == KubernetesExecutor) (Left "operation has a different executor")
  unless (plannedAction operation `elem` [CreateResource, UpdateResource]) (Left "Kubernetes adapter does not yet support adoption, retirement, or declared operations")
  resource <- case NE.toList (plannedResources operation) of
    [single] -> Right single
    _ -> Left "Kubernetes object operation must name exactly one resource"
  (declaration, native) <- maybe (Left "Kubernetes resource has no bound native object") Right (Map.lookup resource specs)
  unless (declaration ^. #identity == resource && declaration ^. #executor == KubernetesExecutor) (Left "bound declaration identity or executor differs")
  pure (resource, declaration, native)

validateBefore :: PlannedOperation -> ResourceId -> KubernetesState -> Either PrepareError ()
validateBefore operation resource state =
  first (PrepareRefused (plannedOperationId operation)) $ case (plannedAction operation, state) of
    (CreateResource, KubernetesAbsent _) -> Right ()
    (UpdateResource, KubernetesPresent _ revision (Just owner) _) | owner == resource && not (T.null revision) -> Right ()
    (_, KubernetesUnknown reason) -> Left ("Kubernetes observation unavailable: " <> reason)
    (CreateResource, _) -> Left "create requires confirmed absence; an existing object needs reviewed adoption"
    (UpdateResource, _) -> Left "update requires a present object stamped with this logical identity and resourceVersion"
    _ -> Left "unsupported Kubernetes action"

buildMutation :: PlannedOperation -> ResourceId -> ManagedResource -> ByteString -> KubernetesState -> Either PrepareError KubernetesMutation
buildMutation operation resource declaration native before = do
  value <- first (refusal . T.pack) (eitherDecodeStrict native)
  canonical <- first refusal (canonicalValue value)
  unless (canonical == native) (Left (refusal "native Kubernetes bytes are not canonical JSON"))
  let digest = contentDigest native
  unless (specDigest (spec declaration) == Just digest) (Left (refusal "native Kubernetes bytes differ from the declared spec digest"))
  cluster <- case address declaration of
    Kubernetes target _ _ _ _ -> Right target
    _ -> Left (refusal "bound declaration has no Kubernetes address")
  let input =
        KubernetesInput
          (declaration ^. #identity)
          (declaration ^. #owner)
          cluster
          value
          digest
          (declaration ^. #lifecycle)
          (declaration ^. #dataPolicy)
          (declaration ^. #sensitivity)
          (declaration ^. #source)
  (recompiled, rebound) <- first (refusal . T.pack . show) (bindKubernetesObject input)
  unless (address recompiled == address declaration && spec recompiled == spec declaration && rebound == native) (Left (refusal "native Kubernetes address or controller claims differ from the declaration"))
  pure
    KubernetesMutation
      { mutationVersion = 1
      , mutationOperation = plannedOperationId operation
      , mutationInputDigest = plannedInputDigest operation
      , mutationAction = plannedAction operation
      , mutationResource = resource
      , mutationAddress = address declaration
      , mutationNativeJson = TE.decodeUtf8 native
      , mutationNativeDigest = digest
      , mutationBefore = before
      }
  where
    refusal = PrepareRefused (plannedOperationId operation)

specDigest :: DesiredSpec -> Maybe ContentDigest
specDigest = \case
  NativeObject digest -> Just digest
  KnativeService digest -> Just digest
  Certificate _ digest -> Just digest
  StatefulSet _ _ digest -> Just digest
  _ -> Nothing

decodeMutation :: Map ResourceId (ManagedResource, ByteString) -> PlannedOperation -> PreparedNative -> Either Text KubernetesMutation
decodeMutation specs operation prepared = do
  mutation <- first T.pack (eitherDecodeStrict (preparedNativeBytes prepared))
  (resource, declaration, native) <- singleSpec specs operation
  unless (mutationVersion mutation == 1) (Left "unsupported Kubernetes mutation version")
  unless (mutationOperation mutation == plannedOperationId operation && mutationInputDigest mutation == plannedInputDigest operation) (Left "Kubernetes mutation operation binding changed")
  unless (mutationResource mutation == resource && mutationAction mutation == plannedAction operation && mutationAddress mutation == address declaration) (Left "Kubernetes mutation resource binding changed")
  unless (TE.encodeUtf8 (mutationNativeJson mutation) == native && mutationNativeDigest mutation == contentDigest native) (Left "Kubernetes native object differs from reviewed bytes")
  case validateBefore operation resource (mutationBefore mutation) of
    Left _ -> Left "Kubernetes mutation precondition is invalid"
    Right () -> Right mutation

requireSameBefore :: KubernetesMutation -> KubernetesState -> Either Text ()
requireSameBefore mutation current =
  if current == mutationBefore mutation
    then Right ()
    else Left "Kubernetes object changed since review; replan before mutation"

completionProof :: KubernetesMutation -> KubernetesState -> Either Text ContentDigest
completionProof mutation state = case state of
  KubernetesPresent physical _ (Just owner) digest
    | owner == mutationResource mutation && digest == mutationNativeDigest mutation ->
        contentDigest <$> canonicalValue (object ["operation" .= mutationOperation mutation, "resource" .= owner, "physicalIdentity" .= physical, "desiredDigest" .= digest])
  KubernetesUnknown reason -> Left ("Kubernetes observation unavailable: " <> reason)
  _ -> Left "Kubernetes object is absent, foreign, or differs from the reviewed native object"

summary :: KubernetesMutation -> Text
summary mutation =
  "Kubernetes " <> T.pack (show (mutationAction mutation))
    <> " " <> resourceIdText (mutationResource mutation)
    <> " at " <> T.pack (show (mutationAddress mutation))
    <> "; native digest " <> digestText (mutationNativeDigest mutation)

instance ToJSON KubernetesState where
  toJSON = \case
    KubernetesAbsent proof -> object ["kind" .= ("absent" :: Text), "proof" .= proof]
    KubernetesPresent physical revision owner digest -> object ["kind" .= ("present" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesUnknown reason -> object ["kind" .= ("unknown" :: Text), "reason" .= reason]

instance FromJSON KubernetesState where
  parseJSON = withObject "Kubernetes state" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "absent" -> KubernetesAbsent <$> o .: "proof"
      "present" -> KubernetesPresent <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "unknown" -> KubernetesUnknown <$> o .: "reason"
      _ -> fail "unknown Kubernetes state"

instance ToJSON KubernetesMutation where
  toJSON mutation =
    object
      [ "version" .= mutationVersion mutation
      , "operation" .= mutationOperation mutation
      , "inputDigest" .= mutationInputDigest mutation
      , "action" .= mutationAction mutation
      , "resource" .= mutationResource mutation
      , "address" .= mutationAddress mutation
      , "nativeJson" .= mutationNativeJson mutation
      , "nativeDigest" .= mutationNativeDigest mutation
      , "before" .= mutationBefore mutation
      ]

instance FromJSON KubernetesMutation where
  parseJSON = withObject "Kubernetes mutation" $ \o ->
    KubernetesMutation <$> o .: "version" <*> o .: "operation" <*> o .: "inputDigest" <*> o .: "action" <*> o .: "resource" <*> o .: "address" <*> o .: "nativeJson" <*> o .: "nativeDigest" <*> o .: "before"
