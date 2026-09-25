-- | Reviewed Kubernetes mutations. The transport must perform the write with
-- the retained UID/resourceVersion precondition; re-observation alone is not
-- a mutation guard. No default transport is installed until it can enforce
-- that requirement for every supported kind.
module Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesState (..)
  , KubernetesMutation (..)
  , KubernetesAdapterOps (..)
  , mkKubernetesAdapter
  , unstampNative
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
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
import Nagare.Inventory.BackendMap (renderBackendMapNative, renderShomeiSettingsNative)
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The revision is the Kubernetes metadata.resourceVersion. The owner is
-- read from the guarded logical-identity stamp, never inferred from a name.
data KubernetesState
  = KubernetesAbsent !ContentDigest
  | KubernetesPresent !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesNotReady !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesReplacementRequired !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
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
  { kubernetesContext :: !ContextId
  , kubernetesObserve :: !(ResourceId -> IO KubernetesState)
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
      KubernetesPresent physical _ owner digest
        | owner == Nothing -> ObservedUnowned physical
        | owner /= Just resource -> ObservedForeign physical
        | Just (_, native) <- Map.lookup resource specs
        , digest /= contentDigest native -> ObservedDrifted physical digest
        | otherwise -> ObservedPresent physical
      KubernetesNotReady physical _ owner digest
        | owner == Nothing -> ObservedUnowned physical
        | owner /= Just resource -> ObservedForeign physical
        | Just (_, native) <- Map.lookup resource specs
        , digest /= contentDigest native -> ObservedDrifted physical digest
        | otherwise -> ObservedPresent physical
      KubernetesReplacementRequired physical _ owner digest
        | owner == Nothing -> ObservedUnowned physical
        | owner /= Just resource -> ObservedForeign physical
        | otherwise -> ObservedReplacementRequired physical digest
      KubernetesUnknown reason -> ObservationUnavailable reason)
    prepare operation = case singleSpec specs operation of
      Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
      Right (resource, declaration, native) -> do
        before <- kubernetesObserve ops resource
        pure $ do
          validateBefore operation resource (contentDigest native) before
          mutation <- buildMutation (kubernetesContext ops) operation resource declaration native before
          bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON mutation))
          pure (PreparedNative bytes (summary mutation))
    preflight operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        pure (if mutationAction mutation == RunDeclaredOperation && current == mutationBefore mutation
          then Right ()
          else requireSameBefore mutation current)
    execute operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        case requireSameBefore mutation current of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right () -> if mutationAction mutation `elem` [RunDeclaredOperation, VerifyResource]
            then pure AdapterEffectCompleted
            else kubernetesMutateConditional ops mutation
    verify operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        pure (completionProof mutation current)
    recover operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
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
  unless (plannedAction operation `elem` [CreateResource, UpdateResource, VerifyResource, AdoptResource, RetireResource, RunDeclaredOperation]) (Left "Kubernetes adapter does not support this action")
  resource <- case NE.toList (plannedResources operation) of
    [single] -> Right single
    _ -> Left "Kubernetes object operation must name exactly one resource"
  (declaration, native) <- maybe (Left "Kubernetes resource has no bound native object") Right (Map.lookup resource specs)
  unless (declaration ^. #identity == resource && declaration ^. #executor == KubernetesExecutor) (Left "bound declaration identity or executor differs")
  when (plannedAction operation == RetireResource && not (supportsRetainedCollection declaration))
    (Left "reviewed collection supports only proved stateless namespaced kinds with deletion policy")
  when (plannedAction operation == RunDeclaredOperation) $ case declaration ^. #address of
    Kubernetes _ "batch" kind _ _ | nameText kind == "job" -> pure ()
    _ -> Left "Kubernetes declared operation must verify a bound Job"
  pure (resource, declaration, native)

validateBefore :: PlannedOperation -> ResourceId -> ContentDigest -> KubernetesState -> Either PrepareError ()
validateBefore operation resource desiredDigest state =
  first (PrepareRefused (plannedOperationId operation)) $ case (plannedAction operation, state) of
    (CreateResource, KubernetesAbsent _) -> Right ()
    (AdoptResource, KubernetesPresent _ revision Nothing digest)
      | not (T.null revision) && digest == desiredDigest -> Right ()
    (UpdateResource, KubernetesPresent _ revision (Just owner) _) | owner == resource && not (T.null revision) -> Right ()
    (VerifyResource, KubernetesPresent _ revision (Just owner) digest)
      | owner == resource && not (T.null revision) && digest == desiredDigest -> Right ()
    (RetireResource, KubernetesPresent _ revision (Just owner) digest)
      | owner == resource && not (T.null revision) && digest == desiredDigest -> Right ()
    (RetireResource, KubernetesNotReady _ revision (Just owner) digest)
      | owner == resource && not (T.null revision) && digest == desiredDigest -> Right ()
    (RunDeclaredOperation, KubernetesPresent _ revision (Just owner) _) | owner == resource && not (T.null revision) -> Right ()
    (RunDeclaredOperation, KubernetesAbsent _) -> Right ()
    (_, KubernetesUnknown reason) -> Left ("Kubernetes observation unavailable: " <> reason)
    (_, KubernetesNotReady {}) -> Left "Kubernetes object is present but its required condition is not ready"
    (CreateResource, _) -> Left "create requires confirmed absence; an existing object needs reviewed adoption"
    (AdoptResource, _) -> Left "adoption requires an unstamped matching object with a physical identity and resourceVersion"
    (UpdateResource, _) -> Left "update requires a present object stamped with this logical identity and resourceVersion"
    (RunDeclaredOperation, _) -> Left "declared Job operation requires a completed owned Job"
    _ -> Left "unsupported Kubernetes action"

buildMutation :: ContextId -> PlannedOperation -> ResourceId -> ManagedResource -> ByteString -> KubernetesState -> Either PrepareError KubernetesMutation
buildMutation context operation resource declaration native before = do
  value <- first (refusal . T.pack) (eitherDecodeStrict native)
  case value of
    Object root | KM.member "status" root -> Left (refusal "desired Kubernetes object may not set controller-owned status")
    _ -> pure ()
  canonical <- first refusal (canonicalValue value)
  unless (canonical == native) (Left (refusal "native Kubernetes bytes are not canonical JSON"))
  let digest = contentDigest native
  let contributedNamespace = spec declaration == NamespaceSpec Nothing
        && declaration ^. #source . #file == "contribution"
      contributedBackend = case spec declaration of
        BackendMapSpec _ -> declaration ^. #source . #file == "contribution"
        _ -> False
      contributedShomei = case spec declaration of
        ShomeiSettingsSpec {} -> declaration ^. #source . #file == "contribution"
        _ -> False
  when contributedBackend $ case spec declaration of
    BackendMapSpec entries -> do
      expected <- first refusal (renderBackendMapNative entries)
      unless (expected == native) (Left (refusal "native backend map differs from typed contributions"))
    _ -> pure ()
  when contributedShomei $ case spec declaration of
    ShomeiSettingsSpec base portal -> do
      expected <- first refusal (renderShomeiSettingsNative base portal)
      unless (expected == native) (Left (refusal "native Shomei settings differ from typed contributions"))
    _ -> pure ()
  unless (specDigest (spec declaration) == Just digest || contributedNamespace || contributedBackend || contributedShomei)
    (Left (refusal "native Kubernetes bytes differ from the declared spec digest"))
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
  unless (address recompiled == address declaration
      && (spec recompiled == spec declaration
        || contributedNamespace && spec recompiled == NamespaceSpec (Just digest)
        || contributedBackend && spec recompiled == NativeObject digest
        || contributedShomei && spec recompiled == NativeObject digest)
      && rebound == native)
    (Left (refusal "native Kubernetes address or controller claims differ from the declaration"))
  stamped <- first refusal (stampNative context resource digest value)
  pure
    KubernetesMutation
      { mutationVersion = 1
      , mutationOperation = plannedOperationId operation
      , mutationInputDigest = plannedInputDigest operation
      , mutationAction = plannedAction operation
      , mutationResource = resource
      , mutationAddress = address declaration
      , mutationNativeJson = TE.decodeUtf8 stamped
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
  NamespaceSpec (Just digest) -> Just digest
  _ -> Nothing

decodeMutation :: ContextId -> Map ResourceId (ManagedResource, ByteString) -> PlannedOperation -> PreparedNative -> Either Text KubernetesMutation
decodeMutation context specs operation prepared = do
  mutation <- first T.pack (eitherDecodeStrict (preparedNativeBytes prepared))
  (resource, declaration, native) <- singleSpec specs operation
  unless (mutationVersion mutation == 1) (Left "unsupported Kubernetes mutation version")
  unless (mutationOperation mutation == plannedOperationId operation && mutationInputDigest mutation == plannedInputDigest operation) (Left "Kubernetes mutation operation binding changed")
  unless (mutationResource mutation == resource && mutationAction mutation == plannedAction operation && mutationAddress mutation == address declaration) (Left "Kubernetes mutation resource binding changed")
  value <- first T.pack (eitherDecodeStrict native)
  stamped <- stampNative context resource (contentDigest native) value
  unless (TE.encodeUtf8 (mutationNativeJson mutation) == stamped && mutationNativeDigest mutation == contentDigest native) (Left "Kubernetes native object differs from reviewed bytes")
  case validateBefore operation resource (contentDigest native) (mutationBefore mutation) of
    Left _ -> Left "Kubernetes mutation precondition is invalid"
    Right () -> Right mutation

-- | Reserved annotations bind the server object to this review's context,
-- logical resource and unstamped content. A supplied annotation can never
-- silently override the binding. The stamped JSON is retained privately.
stampNative :: ContextId -> ResourceId -> ContentDigest -> Value -> Either Text ByteString
stampNative context resource digest (Object root) = do
  metadata <- case KM.lookup "metadata" root of
    Just (Object value) -> Right value
    _ -> Left "Kubernetes native object lacks metadata"
  annotations <- case KM.lookup "annotations" metadata of
    Nothing -> Right KM.empty
    Just (Object value) -> Right value
    _ -> Left "Kubernetes metadata.annotations must be an object"
  let reserved =
        [ ("nagare.dev/context-id", contextIdText context)
        , ("nagare.dev/resource-id", resourceIdText resource)
        , ("nagare.dev/spec-digest", digestText digest)
        ]
  unless (all (\(key, _) -> not (KM.member key annotations)) reserved)
    (Left "Kubernetes native object sets a reserved inventory annotation")
  let stampedAnnotations = foldr (\(key, value) result -> KM.insert key (String value) result) annotations reserved
      stampedMetadata = KM.insert "annotations" (Object stampedAnnotations) metadata
  canonicalValue (Object (KM.insert "metadata" (Object stampedMetadata) root))
stampNative _ _ _ _ = Left "Kubernetes native object must be an object"

-- | Reconstruct the unstamped source member from an immutable private review.
-- Exact reserved values are required, so an apply adapter needs no mutable
-- renderer or manifest file after the review was published.
unstampNative :: ContextId -> ResourceId -> ContentDigest -> Text -> Either Text ByteString
unstampNative context resource digest stamped = do
  value <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 stamped))
  case value of
    Object root -> do
      metadata <- case KM.lookup "metadata" root of
        Just (Object objectMetadata) -> Right objectMetadata
        _ -> Left "reviewed Kubernetes object lacks metadata"
      annotations <- case KM.lookup "annotations" metadata of
        Just (Object objectAnnotations) -> Right objectAnnotations
        _ -> Left "reviewed Kubernetes object lacks inventory annotations"
      let reserved =
            [ ("nagare.dev/context-id", contextIdText context)
            , ("nagare.dev/resource-id", resourceIdText resource)
            , ("nagare.dev/spec-digest", digestText digest)
            ]
      unless (all (\(key, expected) -> KM.lookup key annotations == Just (String expected)) reserved)
        (Left "reviewed Kubernetes inventory annotations differ from the bound context, identity or digest")
      let remaining = foldr (KM.delete . fst) annotations reserved
          plainMetadata = if KM.null remaining then KM.delete "annotations" metadata else KM.insert "annotations" (Object remaining) metadata
      raw <- canonicalValue (Object (KM.insert "metadata" (Object plainMetadata) root))
      unless (contentDigest raw == digest) (Left "reviewed Kubernetes object does not reconstruct its declared digest")
      pure raw
    _ -> Left "reviewed Kubernetes native object is not an object"

requireSameBefore :: KubernetesMutation -> KubernetesState -> Either Text ()
requireSameBefore mutation current =
  if mutationAction mutation == RunDeclaredOperation
    then case current of
      KubernetesPresent _ _ (Just owner) digest
        | owner == mutationResource mutation && digest == mutationNativeDigest mutation -> Right ()
      _ -> Left "declared Kubernetes Job is not complete at the reviewed digest"
    else if mutationAction mutation == VerifyResource
      then case (mutationBefore mutation, current) of
        (KubernetesPresent expectedPhysical _ (Just expectedOwner) expectedDigest,
          KubernetesPresent physical _ (Just owner) digest)
          | expectedPhysical == physical && expectedOwner == owner
          , owner == mutationResource mutation
          , expectedDigest == digest && digest == mutationNativeDigest mutation -> Right ()
        _ -> Left "Kubernetes object identity or desired fields changed since review"
    else if current == mutationBefore mutation
      then Right ()
      else Left "Kubernetes object changed since review; replan before mutation"

completionProof :: KubernetesMutation -> KubernetesState -> Either Text ContentDigest
completionProof mutation state
  | mutationAction mutation == RetireResource = case state of
      KubernetesAbsent absence -> case mutationBefore mutation of
        KubernetesPresent physical _ _ _ -> contentDigest <$> canonicalValue
          (object ["operation" .= mutationOperation mutation,
                   "resource" .= mutationResource mutation,
                   "removedPhysical" .= physical,
                   "absence" .= absence])
        KubernetesNotReady physical _ _ _ -> contentDigest <$> canonicalValue
          (object ["operation" .= mutationOperation mutation,
                   "resource" .= mutationResource mutation,
                   "removedPhysical" .= physical,
                   "absence" .= absence])
        _ -> Left "collection lacks a present historical precondition"
      KubernetesUnknown reason -> Left ("Kubernetes observation unavailable: " <> reason)
      KubernetesNotReady {} -> Left "Kubernetes object remains present but is not ready"
      _ -> Left "collected Kubernetes object remains present or was replaced"
  | otherwise = case state of
      KubernetesPresent physical _ (Just owner) digest
        | owner == mutationResource mutation && digest == mutationNativeDigest mutation ->
            contentDigest <$> canonicalValue (object ["operation" .= mutationOperation mutation, "resource" .= owner, "physicalIdentity" .= physical, "desiredDigest" .= digest])
      KubernetesUnknown reason -> Left ("Kubernetes observation unavailable: " <> reason)
      KubernetesNotReady {} -> Left "Kubernetes object remains present but is not ready"
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
    KubernetesNotReady physical revision owner digest -> object ["kind" .= ("not-ready" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesReplacementRequired physical revision owner digest -> object ["kind" .= ("replacement-required" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesUnknown reason -> object ["kind" .= ("unknown" :: Text), "reason" .= reason]

instance FromJSON KubernetesState where
  parseJSON = withObject "Kubernetes state" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "absent" -> KubernetesAbsent <$> o .: "proof"
      "present" -> KubernetesPresent <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "not-ready" -> KubernetesNotReady <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "replacement-required" -> KubernetesReplacementRequired <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
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
