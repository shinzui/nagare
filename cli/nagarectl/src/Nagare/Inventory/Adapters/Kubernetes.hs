-- | Reviewed Kubernetes mutations. The transport must perform the write with
-- the retained UID/resourceVersion precondition; re-observation alone is not
-- a mutation guard. No default transport is installed until it can enforce
-- that requirement for every supported kind.
module Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesState (..)
  , KubernetesMutation (..)
  , FieldTakeover (..)
  , KubernetesAdapterOps (..)
  , mkKubernetesAdapter
  , mkKubernetesAdapterWithBackupReceipt
  , mkKubernetesAdapterWithConfigurationObservation
  , mkKubernetesAdapterWithFieldTakeover
  , mkKubernetesAdapterWithBackupReceiptAndBatch
  , unstampNative
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.BackendMap (renderBackendMapNative, renderShomeiSettingsNative)
import Nagare.Inventory.Backup
  ( BackupReceiptExpectation (..)
  , manualBackupJobReceiptExpectation
  , manualBackupJobSourcePins
  , parseBackupReceipt
  , volumeSnapshotJobSourcePins
  )
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesConfiguration (confirmLandedUnready, foreignFieldManagers, liveIdentity)
import Nagare.Inventory.Prune (manualPruneJobBackupPin)
import Nagare.Inventory.Restore (manualRestoreJobTargetPins, volumeRestoreJobSourcePins)
import Nagare.Inventory.ScheduledIngest (scheduledIngestJobSourcePins)
import Nagare.Inventory.VolumePrune (volumePruneJobCredentialPin)
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
  | KubernetesFailed !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesReplacementRequired !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesUnknown !Text
  deriving stock (Eq, Show, Generic)

-- | Private reviewed plan. The native JSON is the exact canonical object
-- submitted by the transport, including any private Secret fields. Version 3
-- is a version-1 update that also carries a reviewed field takeover.
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
  , mutationTakeover :: !(Maybe FieldTakeover)
  }
  deriving stock (Eq, Generic)

-- | The foreign managed-field entries an operator reviewed for takeover (F37),
-- bound to the object's UID and resourceVersion at planning. Execution may
-- force Nagare's fields only while every live foreign entry is one of these.
data FieldTakeover = FieldTakeover
  { takeoverPhysical :: !PhysicalIdentity
  , takeoverResourceVersion :: !Text
  , takeoverManagers :: ![Value]
  }
  deriving stock (Eq, Show, Generic)

data KubernetesAdapterOps = KubernetesAdapterOps
  { kubernetesContext :: !ContextId
  , kubernetesObserve :: !(ResourceId -> IO KubernetesState)
  , -- The implementation must make the write conditional on mutationBefore at
    -- the API server. A local compare followed by unrestricted apply is unsafe.
    kubernetesMutateConditional :: !(KubernetesMutation -> IO AdapterExecution)
  }

mkKubernetesAdapter :: Map ResourceId (ManagedResource, ByteString) -> KubernetesAdapterOps -> Adapter
mkKubernetesAdapter specs ops =
  mkKubernetesAdapterWithBackupReceipt
    specs
    ops
    (\_ _ -> pure (Left "backup receipt reader is not installed"))

-- | The reader obtains the upload container's terminal copy of the receipt
-- that it fetched from object storage after writing and checking the backup.
-- This uses only the reviewed cluster context; restore still needs a fresh
-- object-store read and checksum before it can use the backup.
mkKubernetesAdapterWithBackupReceipt ::
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)) ->
  Adapter
mkKubernetesAdapterWithBackupReceipt specs ops =
  mkKubernetesAdapterWithBackupReceiptAndBatch
    specs
    ops
    (traverse (kubernetesObserve ops))

-- | Planning may validate the cluster once around a read-only batch. Effect
-- preparation, preflight, execution, verification, and recovery still use the
-- individually guarded 'kubernetesObserve' operation.
mkKubernetesAdapterWithBackupReceiptAndBatch ::
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps ->
  ([ResourceId] -> IO [KubernetesState]) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)) ->
  Adapter
mkKubernetesAdapterWithBackupReceiptAndBatch specs ops observeBatch readBackupReceipt =
  mkKubernetesAdapterWithObservations specs ops observeBatch Nothing readBackupReceipt noScratchFailureProbe Nothing Nothing

-- | Without a runtime pod probe, a failed restore scratch workload is never
-- proved terminal; recovery stays unresolved, as before.
noScratchFailureProbe :: ResourceId -> PhysicalIdentity -> IO (Either Text Bool)
noScratchFailureProbe _ _ = pure (Right False)

-- Version 1 keeps exact legacy observations. Only new Knative Service updates
-- opt into a separately versioned status-independent configuration observation.
-- The reader returns the live object with its managed fields; recovery uses it
-- only to prove a landed but unready update for a reviewed stop (F54).
mkKubernetesAdapterWithConfigurationObservation ::
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps ->
  ([ResourceId] -> IO [KubernetesState]) ->
  (ResourceId -> IO KubernetesState) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text Bool)) ->
  (ProviderAddress -> IO (Either Text Value)) ->
  Adapter
mkKubernetesAdapterWithConfigurationObservation specs ops batch stable receipt scratch reader =
  mkKubernetesAdapterWithObservations specs ops batch (Just stable) receipt scratch Nothing (Just reader)

-- | Planning with an explicit operator opt-in to reviewed field takeover. An
-- update whose live object has foreign managed fields records those exact
-- entries in a version-3 mutation instead of a review that apply refuses.
-- The reader returns the live object with its managed fields.
mkKubernetesAdapterWithFieldTakeover ::
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps ->
  ([ResourceId] -> IO [KubernetesState]) ->
  (ResourceId -> IO KubernetesState) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text Bool)) ->
  (ProviderAddress -> IO (Either Text Value)) ->
  Adapter
mkKubernetesAdapterWithFieldTakeover specs ops batch stable receipt scratch reader =
  mkKubernetesAdapterWithObservations specs ops batch (Just stable) receipt scratch (Just reader) (Just reader)

mkKubernetesAdapterWithObservations ::
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps ->
  ([ResourceId] -> IO [KubernetesState]) ->
  Maybe (ResourceId -> IO KubernetesState) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text Bool)) ->
  Maybe (ProviderAddress -> IO (Either Text Value)) ->
  Maybe (ProviderAddress -> IO (Either Text Value)) ->
  Adapter
mkKubernetesAdapterWithObservations specs ops observeBatch stableObserve readBackupReceipt scratchFailed takeoverReader landedReader =
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
    observeMutation mutation =
      if mutationVersion mutation == 2
        then maybe (pure (KubernetesUnknown "version 2 configuration observation is unavailable")) ($ mutationResource mutation) stableObserve
        else kubernetesObserve ops (mutationResource mutation)
    observeAll resources = do
      states <- observeBatch resources
      pure (observationSet (zipWith toObservation resources states))
    toObservation resource state =
      ( resource
      , case state of
          KubernetesAbsent proof -> ConfirmedAbsent proof
          KubernetesPresent physical _ owner digest
            | owner == Nothing -> ObservedUnowned physical
            | owner /= Just resource -> ObservedForeign physical
            | Just (_, native) <- Map.lookup resource specs
            , digest /= contentDigest native ->
                ObservedDrifted physical digest
            | otherwise -> ObservedPresent physical
          KubernetesNotReady physical _ owner digest
            | owner == Nothing -> ObservedUnowned physical
            | owner /= Just resource -> ObservedForeign physical
            | Just (_, native) <- Map.lookup resource specs
            , digest /= contentDigest native ->
                ObservedDrifted physical digest
            | otherwise -> ObservedPresent physical
          KubernetesFailed physical _ owner digest
            | owner == Nothing -> ObservedUnowned physical
            | owner /= Just resource -> ObservedForeign physical
            | Just (_, native) <- Map.lookup resource specs
            , digest /= contentDigest native ->
                ObservedDrifted physical digest
            | otherwise -> ObservedPresent physical
          KubernetesReplacementRequired physical _ owner digest
            | owner == Nothing -> ObservedUnowned physical
            | owner /= Just resource -> ObservedForeign physical
            | otherwise -> ObservedReplacementRequired physical digest
          KubernetesUnknown reason -> ObservationUnavailable reason
      )
    prepare operation = case singleSpec specs operation of
      Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
      Right (resource, declaration, native) -> do
        takeover <- case takeoverReader of
          Just reader | plannedAction operation == UpdateResource -> prepareTakeover reader operation resource declaration
          _ -> pure (Right Nothing)
        let versioned = plannedAction operation == UpdateResource && knativeServiceAddress (address declaration) && isJust stableObserve
        before <- case takeover of
          Right (Just (_, observed)) -> pure observed
          _ | versioned -> maybe (kubernetesObserve ops resource) ($ resource) stableObserve
          _ -> kubernetesObserve ops resource
        pure $ do
          reviewedTakeover <- fmap fst <$> takeover
          validateBefore operation resource (address declaration) (contentDigest native) before
          initial <- buildMutation (kubernetesContext ops) operation resource declaration native before
          let mutation = case reviewedTakeover of
                Just _ -> initial {mutationVersion = 3, mutationTakeover = reviewedTakeover}
                Nothing -> initial {mutationVersion = if versioned then 2 else 1}
          bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON mutation))
          pure (PreparedNative bytes (summary mutation))
    -- The exact object observation and its live managed fields must name the
    -- same UID and resourceVersion; otherwise the object moved between reads.
    prepareTakeover reader operation resource declaration = do
      observed <- kubernetesObserve ops resource
      live <- reader (address declaration)
      pure $ first (PrepareRefused (plannedOperationId operation)) $ do
        value <- live
        (uid, revision) <- liveIdentity value
        others <- foreignFieldManagers (Just (address declaration)) value
        case observed of
          _ | null others -> Right Nothing
          KubernetesPresent physical observedRevision _ _
            | physicalIdentityText physical == uid && observedRevision == revision ->
                Right (Just (FieldTakeover physical revision others, observed))
          KubernetesNotReady physical observedRevision _ _
            | physicalIdentityText physical == uid && observedRevision == revision ->
                Right (Just (FieldTakeover physical revision others, observed))
          _ -> Left "Kubernetes object changed while its field takeover was prepared; replan"
    preflight operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- observeMutation mutation
        sourceGuard <- verifyBackupSources mutation
        pure $ do
          if mutationAction mutation == RunDeclaredOperation && current == mutationBefore mutation
            then Right ()
            else requireSameBefore mutation current
          sourceGuard
    execute operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right mutation -> do
        current <- observeMutation mutation
        case requireSameBefore mutation current of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right () -> do
            sourceGuard <- verifyBackupSources mutation
            case sourceGuard of
              Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
              Right () ->
                if mutationAction mutation `elem` [RunDeclaredOperation, VerifyResource]
                  then pure AdapterEffectCompleted
                  else kubernetesMutateConditional ops (if mutationVersion mutation == 2 then mutation {mutationBefore = current} else mutation)
    verify operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        sourceGuard <- verifyBackupSources mutation
        case sourceGuard of
          Left reason -> pure (Left reason)
          Right () -> verifiedProof mutation current
    recover operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (RecoveryUnresolved reason)
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        sourceGuard <- verifyBackupSources mutation
        case sourceGuard of
          Left reason -> pure (RecoveryUnresolved reason)
          Right () -> case completionProof mutation current of
            Right _ ->
              either RecoveryUnresolved RecoveryProvedComplete
                <$> verifiedProof mutation current
            Left _ -> do
              before <- observeMutation mutation
              -- A created restore scratch StatefulSet whose pod has a failed,
              -- restarted container never becomes Ready on its own (for example
              -- its pinned download or load failed); prove that failure so the
              -- restore-only review can be abandoned without claiming success.
              scratchFailure <- case current of
                KubernetesNotReady physical _ (Just owner) digest
                  | createdScratchStatefulSet mutation owner digest -> scratchFailed (mutationResource mutation) physical
                _ -> pure (Right False)
              -- F54: an intended Knative Service update that landed exactly as
              -- reviewed on the accepted object and never became Ready. The
              -- live read must agree with this observation's UID and version.
              landed <- case (current, landedReader) of
                (KubernetesNotReady physical revision (Just owner) digest, Just reader)
                  | landedUpdate mutation physical owner digest ->
                      (>>= confirmLandedUnready (Just (mutationAddress mutation)) physical revision) <$> reader (mutationAddress mutation)
                _ -> pure (Left "not a landed Knative Service or StatefulSet update")
              pure $ case requireSameBefore mutation before of
                Right () -> RecoverySafeToRetry
                Left reason -> case current of
                  -- F57: a verification writes nothing, so retrying it is
                  -- always safe; its preflight then refuses a changed target
                  -- with no effect.
                  _ | mutationAction mutation == VerifyResource -> RecoverySafeToRetry
                  KubernetesNotReady physical _ _ _
                    | Right () <- landed -> RecoveryLandedUnready physical
                  KubernetesNotReady physical _ (Just owner) _
                    | replacedUpdateTarget mutation physical owner -> RecoveryTargetReplaced physical
                  KubernetesPresent physical _ (Just owner) _
                    | replacedUpdateTarget mutation physical owner -> RecoveryTargetReplaced physical
                  KubernetesAbsent _
                    -- F64: an owned update target deleted outside review. Its
                    -- preflight refuses the absent object before any effect, so
                    -- the retry journals a no-effect refusal to abandon.
                    | ownedUpdateBefore mutation -> RecoverySafeToRetry
                  KubernetesNotReady physical _ (Just owner) digest
                    | createdScratchStatefulSet mutation owner digest
                    , scratchFailure == Right True ->
                        RecoveryTerminalFailure physical
                  KubernetesNotReady physical _ (Just owner) digest
                    | owner == mutationResource mutation
                        && digest == mutationNativeDigest mutation
                        && mutationAction mutation == CreateResource
                        && (case mutationBefore mutation of KubernetesAbsent {} -> True; _ -> False)
                        && ( case mutationAddress mutation of
                               -- F59: a created StatefulSet (a database's) that never
                               -- became Ready is the same no-data readiness wait.
                               Kubernetes _ "apps" kind _ _ -> nameText kind `elem` ["deployment", "statefulset"]
                               Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind `elem` ["service", "domainmapping"]
                               _ -> False
                           ) ->
                        RecoveryAwaitingReadiness physical
                  KubernetesNotReady physical _ (Just owner) _
                    | mutationVersion mutation `elem` [1, 3]
                    , mutationAction mutation == UpdateResource
                    , knativeServiceAddress (mutationAddress mutation)
                    , owner == mutationResource mutation
                    , ( case mutationBefore mutation of
                          KubernetesPresent prior _ (Just previousOwner) _ -> prior == physical && previousOwner == owner
                          KubernetesNotReady prior _ (Just previousOwner) _ -> prior == physical && previousOwner == owner
                          _ -> False
                      ) ->
                        RecoveryAwaitingReadiness physical
                  KubernetesFailed physical _ (Just owner) digest
                    | owner == mutationResource mutation
                        && digest == mutationNativeDigest mutation
                        && ( case mutationAddress mutation of
                               Kubernetes _ "batch" kind _ _ -> nameText kind == "job"
                               _ -> False
                           )
                        && mutationAction mutation
                          `elem` [CreateResource, RunDeclaredOperation] ->
                        RecoveryTerminalFailure physical
                  _ -> RecoveryUnresolved reason
    landedUpdate mutation physical owner digest =
      mutationAction mutation == UpdateResource
        -- F63: a database's StatefulSet update lands unready the same way.
        && (knativeServiceAddress (mutationAddress mutation) || statefulSetAddress (mutationAddress mutation))
        && owner == mutationResource mutation
        && digest == mutationNativeDigest mutation
        && case mutationBefore mutation of
          KubernetesPresent prior _ (Just previousOwner) _ -> prior == physical && previousOwner == owner
          KubernetesNotReady prior _ (Just previousOwner) _ -> prior == physical && previousOwner == owner
          _ -> False
    -- F56: an intended Knative Service update whose reviewed object was
    -- deleted and recreated outside review. The replacement carries the
    -- member's ownership stamp but another UID.
    replacedUpdateTarget mutation physical owner =
      mutationAction mutation == UpdateResource
        && knativeServiceAddress (mutationAddress mutation)
        && owner == mutationResource mutation
        && case mutationBefore mutation of
          KubernetesPresent prior _ (Just previousOwner) _ -> prior /= physical && previousOwner == owner
          KubernetesNotReady prior _ (Just previousOwner) _ -> prior /= physical && previousOwner == owner
          _ -> False
    ownedUpdateBefore mutation =
      mutationAction mutation == UpdateResource
        && case mutationBefore mutation of
          KubernetesPresent _ _ (Just previousOwner) _ -> previousOwner == mutationResource mutation
          KubernetesNotReady _ _ (Just previousOwner) _ -> previousOwner == mutationResource mutation
          _ -> False
    createdScratchStatefulSet mutation owner digest =
      owner == mutationResource mutation
        && digest == mutationNativeDigest mutation
        && mutationAction mutation == CreateResource
        && (case mutationBefore mutation of KubernetesAbsent {} -> True; _ -> False)
        && ( case mutationAddress mutation of
               Kubernetes _ "apps" kind _ _ -> nameText kind == "statefulset"
               _ -> False
           )
    verifiedProof mutation current = case completionProof mutation current of
      Left reason -> pure (Left reason)
      Right jobProof
        | mutationAction mutation == RetireResource -> pure (Right jobProof)
        | otherwise -> case Map.lookup (mutationResource mutation) specs of
            Nothing -> pure (Left "Kubernetes resource has no bound native object")
            Just (_, native) -> case manualBackupJobReceiptExpectation native of
              Left reason -> pure (Left reason)
              Right Nothing -> pure (Right jobProof)
              Right (Just expectation) -> case current of
                KubernetesPresent physical _ _ _ -> do
                  receiptResult <- readBackupReceipt (mutationResource mutation) physical
                  pure $ do
                    receiptBytes <- receiptResult
                    checksum <- parseBackupReceipt expectation (receiptAddress expectation) receiptBytes
                    contentDigest
                      <$> canonicalValue
                        ( object
                            [ "jobProof" .= jobProof
                            , "receiptAddress" .= receiptAddress expectation
                            , "receiptDigest" .= contentDigest receiptBytes
                            , "backupSha256" .= checksum
                            ]
                        )
                _ -> pure (Left "manual backup Job has no completed physical identity")
    verifyBackupSources mutation
      | mutationAction mutation `notElem` [CreateResource, RunDeclaredOperation] = pure (Right ())
      | otherwise = case Map.lookup (mutationResource mutation) specs of
          Nothing -> pure (Left "manual backup Job lacks its bound native object")
          Just (_, native) -> case ( manualBackupJobSourcePins native
                                   , manualRestoreJobTargetPins native
                                   , manualPruneJobBackupPin native
                                   , volumeSnapshotJobSourcePins native
                                   , volumeRestoreJobSourcePins native
                                   , volumePruneJobCredentialPin native
                                   , scheduledIngestJobSourcePins native
                                   ) of
            (Left reason, _, _, _, _, _, _) -> pure (Left reason)
            (_, Left reason, _, _, _, _, _) -> pure (Left reason)
            (_, _, Left reason, _, _, _, _) -> pure (Left reason)
            (_, _, _, Left reason, _, _, _) -> pure (Left reason)
            (_, _, _, _, Left reason, _, _) -> pure (Left reason)
            (_, _, _, _, _, Left reason, _) -> pure (Left reason)
            (_, _, _, _, _, _, Left reason) -> pure (Left reason)
            ( Right backupPins
              , Right restorePins
              , Right prunePin
              , Right volumePins
              , Right volumeRestorePins
              , Right volumePruneCredential
              , Right scheduledPins
              ) -> do
                checked <-
                  traverse
                    checkOne
                    ( maybe [] id backupPins
                        <> maybe [] id restorePins
                        <> maybe [] (: []) prunePin
                        <> maybe [] id volumePins
                        <> maybe [] id volumeRestorePins
                        <> maybe [] (: []) volumePruneCredential
                        <> maybe [] id scheduledPins
                    )
                pure (sequence_ checked)
      where
        checkOne (resource, expectedUid) = case Map.lookup resource specs of
          Nothing -> pure (Left "manual data Job source lacks accepted native evidence")
          Just (_, sourceNative) -> do
            current <- kubernetesObserve ops resource
            pure $ case current of
              KubernetesPresent uid _ (Just owner) digest
                | uid == expectedUid
                    && owner == resource
                    && digest == contentDigest sourceNative ->
                    Right ()
              _ -> Left "manual backup source UID, ownership, readiness, or native bytes changed"

singleSpec :: Map ResourceId (ManagedResource, ByteString) -> PlannedOperation -> Either Text (ResourceId, ManagedResource, ByteString)
singleSpec specs operation = do
  unless (plannedExecutor operation == KubernetesExecutor) (Left "operation has a different executor")
  unless
    ( plannedAction operation
        `elem` [ CreateResource
               , UpdateResource
               , VerifyResource
               , AdoptResource
               , RetireResource
               , RunDeclaredOperation
               , OpenMaintenanceSession
               , RestoreLiveDatabase
               ]
    )
    (Left "Kubernetes adapter does not support this action")
  resource <- case (plannedAction operation, NE.toList (plannedResources operation)) of
    (RunDeclaredOperation, affected) -> case [ resourceId
                                             | resourceId <- affected
                                             , Just (bound, _) <- [Map.lookup resourceId specs]
                                             , case bound ^. #address of
                                                 Kubernetes _ "batch" kind _ _ -> nameText kind == "job"
                                                 _ -> False
                                             ] of
      [job] -> Right job
      _ -> Left "Kubernetes declared operation must name exactly one bound Job"
    (_, [single]) -> Right single
    _ -> Left "Kubernetes object operation must name exactly one resource"
  (declaration, native) <- maybe (Left "Kubernetes resource has no bound native object") Right (Map.lookup resource specs)
  unless (declaration ^. #identity == resource && declaration ^. #executor == KubernetesExecutor) (Left "bound declaration identity or executor differs")
  when
    (plannedAction operation == RetireResource && not (supportsRetainedCollection declaration))
    (Left "reviewed collection supports only proved stateless namespaced kinds with deletion policy")
  when (plannedAction operation == RunDeclaredOperation) $ case declaration ^. #address of
    Kubernetes _ "batch" kind _ _ | nameText kind == "job" -> pure ()
    _ -> Left "Kubernetes declared operation must verify a bound Job"
  pure (resource, declaration, native)

validateBefore :: PlannedOperation -> ResourceId -> ProviderAddress -> ContentDigest -> KubernetesState -> Either PrepareError ()
validateBefore operation resource target desiredDigest state =
  first (PrepareRefused (plannedOperationId operation)) $ case (plannedAction operation, state) of
    (CreateResource, KubernetesAbsent _) -> Right ()
    (AdoptResource, KubernetesPresent _ revision Nothing digest)
      | not (T.null revision) && digest == desiredDigest -> Right ()
    (UpdateResource, KubernetesPresent _ revision (Just owner) _) | owner == resource && not (T.null revision) -> Right ()
    (UpdateResource, KubernetesNotReady _ revision (Just owner) _)
      | owner == resource && not (T.null revision)
      , Kubernetes _ "serving.knative.dev" kind (Just _) _ <- target
      , nameText kind == "service" ->
          Right ()
    -- F63: correcting a StatefulSet that never became Ready (a bad resource
    -- change, an unschedulable pod) is an update of the unready object.
    (UpdateResource, KubernetesNotReady _ revision (Just owner) _)
      | owner == resource && not (T.null revision)
      , statefulSetAddress target ->
          Right ()
    (VerifyResource, KubernetesPresent _ revision (Just owner) digest)
      | owner == resource && not (T.null revision) && digest == desiredDigest -> Right ()
    -- A dependency can repair this route before its read-only verification.
    -- Execution still requires Ready under the same UID, owner and digest.
    (VerifyResource, KubernetesNotReady _ revision (Just owner) digest)
      | owner == resource && not (T.null revision) && digest == desiredDigest
      , Kubernetes _ "serving.knative.dev" kind (Just _) _ <- target
      , nameText kind == "domainmapping" ->
          Right ()
    (RetireResource, KubernetesPresent _ revision (Just owner) digest)
      | owner == resource && not (T.null revision) && digest == desiredDigest -> Right ()
    (RetireResource, KubernetesNotReady _ revision (Just owner) digest)
      | owner == resource && not (T.null revision) && digest == desiredDigest -> Right ()
    (RunDeclaredOperation, KubernetesPresent _ revision (Just owner) _) | owner == resource && not (T.null revision) -> Right ()
    (RunDeclaredOperation, KubernetesAbsent _) -> Right ()
    (OpenMaintenanceSession, KubernetesPresent _ revision (Just owner) digest)
      | owner == resource && not (T.null revision)
      , digest == desiredDigest ->
          Right ()
    (RestoreLiveDatabase, KubernetesPresent _ revision (Just owner) digest)
      | owner == resource && not (T.null revision)
      , digest == desiredDigest ->
          Right ()
    (_, KubernetesUnknown reason) -> Left ("Kubernetes observation unavailable: " <> reason)
    (_, KubernetesNotReady {}) -> Left "Kubernetes object is present but its required condition is not ready"
    (_, KubernetesFailed {}) -> Left "Kubernetes Job has a terminal failure"
    (CreateResource, _) -> Left "create requires confirmed absence; an existing object needs reviewed adoption"
    (AdoptResource, _) -> Left "adoption requires an unstamped matching object with a physical identity and resourceVersion"
    (UpdateResource, _) -> Left "update requires a present object stamped with this logical identity and resourceVersion"
    (RunDeclaredOperation, _) -> Left "declared Job operation requires a completed owned Job"
    (OpenMaintenanceSession, _) ->
      Left "maintenance requires the reviewed present database object"
    (RestoreLiveDatabase, _) ->
      Left "live restore requires the reviewed present database object"
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
  let contributedNamespace =
        spec declaration == NamespaceSpec Nothing
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
  unless
    (specDigest (spec declaration) == Just digest || contributedNamespace || contributedBackend || contributedShomei)
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
  unless
    ( address recompiled == address declaration
        && ( spec recompiled == spec declaration
               || contributedNamespace && spec recompiled == NamespaceSpec (Just digest)
               || contributedBackend && spec recompiled == NativeObject digest
               || contributedShomei && spec recompiled == NativeObject digest
           )
        && rebound == native
    )
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
      , mutationTakeover = Nothing
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
  unless (mutationVersion mutation == 1 || (mutationVersion mutation == 2 && mutationAction mutation == UpdateResource && knativeServiceAddress (mutationAddress mutation))) (Left "unsupported Kubernetes mutation version")
    `orTakeover` mutation
  unless (mutationOperation mutation == plannedOperationId operation && mutationInputDigest mutation == plannedInputDigest operation) (Left "Kubernetes mutation operation binding changed")
  unless (mutationResource mutation == resource && mutationAction mutation == plannedAction operation && mutationAddress mutation == address declaration) (Left "Kubernetes mutation resource binding changed")
  value <- first T.pack (eitherDecodeStrict native)
  stamped <- stampNative context resource (contentDigest native) value
  unless (TE.encodeUtf8 (mutationNativeJson mutation) == stamped && mutationNativeDigest mutation == contentDigest native) (Left "Kubernetes native object differs from reviewed bytes")
  case validateBefore operation resource (address declaration) (contentDigest native) (mutationBefore mutation) of
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
  unless
    (all (\(key, _) -> not (KM.member key annotations)) reserved)
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
      unless
        (all (\(key, expected) -> KM.lookup key annotations == Just (String expected)) reserved)
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
    else
      if mutationAction mutation == VerifyResource
        then case (mutationBefore mutation, current) of
          ( KubernetesPresent expectedPhysical _ (Just expectedOwner) expectedDigest
            , KubernetesPresent physical _ (Just owner) digest
            )
              | expectedPhysical == physical && expectedOwner == owner
              , owner == mutationResource mutation
              , expectedDigest == digest && digest == mutationNativeDigest mutation ->
                  Right ()
          ( KubernetesNotReady expectedPhysical _ (Just expectedOwner) expectedDigest
            , KubernetesPresent physical _ (Just owner) digest
            )
              | Kubernetes _ "serving.knative.dev" kind (Just _) _ <- mutationAddress mutation
              , nameText kind == "domainmapping"
              , expectedPhysical == physical && expectedOwner == owner
              , owner == mutationResource mutation
              , expectedDigest == digest && digest == mutationNativeDigest mutation ->
                  Right ()
          _ -> Left "Kubernetes object identity or desired fields changed since review"
        else
          if mutationVersion mutation == 2 && mutationAction mutation == UpdateResource
            then case (configured (mutationBefore mutation), configured current) of
              (Just before, Just now) | before == now -> Right ()
              _ -> Left "Knative Service configuration or ownership changed since review"
            else
              if current == mutationBefore mutation
                then Right ()
                else Left "Kubernetes object changed since review; replan before mutation"
  where
    configured (KubernetesPresent uid _ (Just owner) digest) | owner == mutationResource mutation = Just (uid, owner, digest)
    configured (KubernetesNotReady uid _ (Just owner) digest) | owner == mutationResource mutation = Just (uid, owner, digest)
    configured _ = Nothing

knativeServiceAddress :: ProviderAddress -> Bool
knativeServiceAddress (Kubernetes _ "serving.knative.dev" kind (Just _) _) = nameText kind == "service"
knativeServiceAddress _ = False

statefulSetAddress :: ProviderAddress -> Bool
statefulSetAddress (Kubernetes _ "apps" kind (Just _) _) = nameText kind == "statefulset"
statefulSetAddress _ = False

completionProof :: KubernetesMutation -> KubernetesState -> Either Text ContentDigest
completionProof mutation state
  | mutationAction mutation == VerifyResource
  , Left reason <- requireSameBefore mutation state =
      Left reason
  | mutationAction mutation == RetireResource = case state of
      KubernetesAbsent absence -> case mutationBefore mutation of
        KubernetesPresent physical _ _ _ ->
          contentDigest
            <$> canonicalValue
              ( object
                  [ "operation" .= mutationOperation mutation
                  , "resource" .= mutationResource mutation
                  , "removedPhysical" .= physical
                  , "absence" .= absence
                  ]
              )
        KubernetesNotReady physical _ _ _ ->
          contentDigest
            <$> canonicalValue
              ( object
                  [ "operation" .= mutationOperation mutation
                  , "resource" .= mutationResource mutation
                  , "removedPhysical" .= physical
                  , "absence" .= absence
                  ]
              )
        _ -> Left "collection lacks a present historical precondition"
      KubernetesUnknown reason -> Left ("Kubernetes observation unavailable: " <> reason)
      KubernetesNotReady {} -> Left "Kubernetes object remains present but is not ready"
      KubernetesFailed {} -> Left "Kubernetes Job has a terminal failure"
      _ -> Left "collected Kubernetes object remains present or was replaced"
  | otherwise = case state of
      KubernetesPresent physical _ (Just owner) digest
        | owner == mutationResource mutation && digest == mutationNativeDigest mutation ->
            contentDigest <$> canonicalValue (object ["operation" .= mutationOperation mutation, "resource" .= owner, "physicalIdentity" .= physical, "desiredDigest" .= digest])
      KubernetesUnknown reason -> Left ("Kubernetes observation unavailable: " <> reason)
      KubernetesNotReady {} -> Left "Kubernetes object remains present but is not ready"
      KubernetesFailed {} -> Left "Kubernetes Job has a terminal failure"
      _ -> Left "Kubernetes object is absent, foreign, or differs from the reviewed native object"

summary :: KubernetesMutation -> Text
summary mutation =
  "Kubernetes "
    <> T.pack (show (mutationAction mutation))
    <> " "
    <> resourceIdText (mutationResource mutation)
    <> " at "
    <> T.pack (show (mutationAddress mutation))
    <> "; native digest "
    <> digestText (mutationNativeDigest mutation)
    <> maybe "" (\takeover -> "; takes over fields from " <> T.intercalate ", " (mapMaybe managerName (takeoverManagers takeover))) (mutationTakeover mutation)
  where
    managerName (Object entry) | Just (String manager) <- KM.lookup "manager" entry = Just manager
    managerName _ = Nothing

instance ToJSON KubernetesState where
  toJSON = \case
    KubernetesAbsent proof -> object ["kind" .= ("absent" :: Text), "proof" .= proof]
    KubernetesPresent physical revision owner digest -> object ["kind" .= ("present" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesNotReady physical revision owner digest -> object ["kind" .= ("not-ready" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesFailed physical revision owner digest -> object ["kind" .= ("failed" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesReplacementRequired physical revision owner digest -> object ["kind" .= ("replacement-required" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesUnknown reason -> object ["kind" .= ("unknown" :: Text), "reason" .= reason]

instance FromJSON KubernetesState where
  parseJSON = withObject "Kubernetes state" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "absent" -> KubernetesAbsent <$> o .: "proof"
      "present" -> KubernetesPresent <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "not-ready" -> KubernetesNotReady <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "failed" -> KubernetesFailed <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "replacement-required" -> KubernetesReplacementRequired <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "unknown" -> KubernetesUnknown <$> o .: "reason"
      _ -> fail "unknown Kubernetes state"

instance ToJSON KubernetesMutation where
  toJSON mutation =
    object
      ( [ "version" .= mutationVersion mutation
        , "operation" .= mutationOperation mutation
        , "inputDigest" .= mutationInputDigest mutation
        , "action" .= mutationAction mutation
        , "resource" .= mutationResource mutation
        , "address" .= mutationAddress mutation
        , "nativeJson" .= mutationNativeJson mutation
        , "nativeDigest" .= mutationNativeDigest mutation
        , "before" .= mutationBefore mutation
        ]
          -- Versions 1 and 2 keep their exact earlier bytes.
          <> maybe [] (\takeover -> ["takeover" .= takeover]) (mutationTakeover mutation)
      )

instance FromJSON KubernetesMutation where
  parseJSON = withObject "Kubernetes mutation" $ \o ->
    KubernetesMutation <$> o .: "version" <*> o .: "operation" <*> o .: "inputDigest" <*> o .: "action" <*> o .: "resource" <*> o .: "address" <*> o .: "nativeJson" <*> o .: "nativeDigest" <*> o .: "before" <*> o .:? "takeover"

instance ToJSON FieldTakeover where
  toJSON takeover =
    object
      [ "physical" .= takeoverPhysical takeover
      , "resourceVersion" .= takeoverResourceVersion takeover
      , "managers" .= takeoverManagers takeover
      ]

instance FromJSON FieldTakeover where
  parseJSON = withObject "Kubernetes field takeover" $ \o ->
    FieldTakeover <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "managers"

-- | Only a version-3 update carries a takeover, bound to its own exact
-- precondition; no other version may carry one.
orTakeover :: Either Text () -> KubernetesMutation -> Either Text ()
orTakeover versionCheck mutation = case (mutationVersion mutation, mutationTakeover mutation, mutationBefore mutation) of
  (3, Just takeover, before)
    | mutationAction mutation == UpdateResource
    , not (null (takeoverManagers takeover))
    , Just (physical, revision) <- presentIdentity before
    , physical == takeoverPhysical takeover && revision == takeoverResourceVersion takeover ->
        Right ()
  (3, _, _) -> Left "Kubernetes field takeover is not bound to its reviewed update precondition"
  (_, Just _, _) -> Left "only a version-3 Kubernetes update may carry a field takeover"
  _ -> versionCheck
  where
    presentIdentity (KubernetesPresent physical revision _ _) = Just (physical, revision)
    presentIdentity (KubernetesNotReady physical revision _ _) = Just (physical, revision)
    presentIdentity _ = Nothing
