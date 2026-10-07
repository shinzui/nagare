-- | Reviewed Kubernetes mutations. The transport must perform the write with
-- the retained UID/resourceVersion precondition; re-observation alone is not
-- a mutation guard. No default transport is installed until it can enforce
-- that requirement for every supported kind.
module Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesState (..)
  , KubernetesMutation (..)
  , FieldTakeover (..)
  , KubernetesAdapterOps (..)
  , kubernetesObserve
  , unstamped
  , mkKubernetesAdapter
  , mkKubernetesAdapterWithBackupReceipt
  , mkKubernetesAdapterWithRecoveryProbes
  , mkKubernetesAdapterWithFieldTakeover
  , mkKubernetesAdapterWithBackupReceiptAndBatch
  , mkKubernetesAdapterWithObservations
  , settleMutation
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
import Nagare.Inventory.Adapters.KubernetesProof
import Nagare.Inventory.Adapters.KubernetesStuckPod (KubernetesPodOps (..), decodePodReplacement, isStatefulSet, noPodOps, preparePodReplacement)
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
import Nagare.Inventory.KubernetesConfiguration (foreignFieldManagers, liveIdentity)
import Nagare.Inventory.Prune (manualPruneJobBackupPin)
import Nagare.Inventory.Restore (manualRestoreJobTargetPins, volumeRestoreJobSourcePins)
import Nagare.Inventory.ScheduledIngest (scheduledIngestJobSourcePins)
import Nagare.Inventory.VolumePrune (volumePruneJobCredentialPin)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data KubernetesAdapterOps = KubernetesAdapterOps
  { kubernetesContext :: !ContextId
  , kubernetesObserveStamped :: !(ResourceId -> IO (KubernetesState, Maybe ContentDigest))
  -- ^ The object's state and its spec-digest stamp, from one read (RES-4 U3).
  , -- The implementation must make the write conditional on mutationBefore at
    -- the API server. A local compare followed by unrestricted apply is unsafe.
    kubernetesMutateConditional :: !(KubernetesMutation -> IO AdapterExecution)
  }

-- | The object's state alone.
kubernetesObserve :: KubernetesAdapterOps -> ResourceId -> IO KubernetesState
kubernetesObserve ops = fmap fst . kubernetesObserveStamped ops

-- | An observation that reads no stamp.
unstamped :: (ResourceId -> IO KubernetesState) -> ResourceId -> IO (KubernetesState, Maybe ContentDigest)
unstamped observe = fmap (,Nothing) . observe

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
  mkKubernetesAdapterWithObservations specs ops noPodOps observeBatch readBackupReceipt noScratchFailureProbe Nothing

-- | Without a runtime pod probe, a failed restore scratch workload is never
-- proved terminal; recovery stays unresolved, as before.
noScratchFailureProbe :: ResourceId -> PhysicalIdentity -> IO (Either Text Bool)
noScratchFailureProbe _ _ = pure (Right False)

-- | The application adapter's recovery probes: a completed backup Job's
-- receipt and a failed restore scratch pod.
mkKubernetesAdapterWithRecoveryProbes ::
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps ->
  ([ResourceId] -> IO [KubernetesState]) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text Bool)) ->
  Adapter
mkKubernetesAdapterWithRecoveryProbes specs ops batch receipt scratch =
  mkKubernetesAdapterWithObservations specs ops noPodOps batch receipt scratch Nothing

-- | Planning with an explicit operator opt-in to reviewed field takeover. An
-- update whose live object has foreign managed fields records those exact
-- entries in a version-3 mutation instead of a review that apply refuses.
-- The reader returns the live object with its managed fields.
mkKubernetesAdapterWithFieldTakeover ::
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps ->
  ([ResourceId] -> IO [KubernetesState]) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text Bool)) ->
  (ProviderAddress -> IO (Either Text Value)) ->
  Adapter
mkKubernetesAdapterWithFieldTakeover specs ops batch receipt scratch reader =
  mkKubernetesAdapterWithObservations specs ops noPodOps batch receipt scratch (Just reader)

-- | Every observation and recovery input. The pod operations find a member
-- StatefulSet's stuck pod (EP-181); the other constructors install none.
-- The takeover reader enables reviewed field takeover (F37).
mkKubernetesAdapterWithObservations ::
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps ->
  KubernetesPodOps ->
  ([ResourceId] -> IO [KubernetesState]) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text ByteString)) ->
  (ResourceId -> PhysicalIdentity -> IO (Either Text Bool)) ->
  Maybe (ProviderAddress -> IO (Either Text Value)) ->
  Adapter
mkKubernetesAdapterWithObservations specs ops pods observeBatch readBackupReceipt scratchFailed takeoverReader =
  Adapter
    { adapterExecutor = KubernetesExecutor
    , adapterIdentity = "kubernetes-conditional-object"
    , adapterVersion = "1"
    , adapterObserve = observeAll
    , adapterPrepare = prepare
    , adapterPreflight = preflight
    , adapterExecute = execute
    , adapterVerify = verify
    , adapterSettle = Just settle
    , adapterRecover = recover
    }
  where
    -- ADR 26: what an operation with intent and no completion did, from its
    -- recovery decision and one fresh observation. It never writes.
    settle operation prepared
      | plannedAction operation == ReplaceStuckPod = pure (SettledUnknown "replace-stuck-pod settlement lands in EP-181 M4" "inventory resume")
    settle operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (SettledUnknown reason "the saved review's native bundle")
      Right mutation -> do
        decision <- recover operation prepared
        (current, stamp) <- kubernetesObserveStamped ops (mutationResource mutation)
        (before, _) <- observeMutation mutation
        pure (settleMutation mutation before current stamp decision)
    observeMutation mutation = kubernetesObserveStamped ops (mutationResource mutation)
    -- EP-181 M3 executes the replacement; until then it refuses with no effect.
    podReplacementPending operation prepared = either id (const "replace-stuck-pod execution is not implemented yet (EP-181 M3)") $ do
      (resource, declaration, _) <- singleSpec specs operation
      decodePodReplacement operation resource (address declaration) prepared
    observeAll resources = do
      states <- observeBatch resources
      let observed = zipWith toObservation resources states
      -- EP-181 (RES-4 G3): an unchanged member StatefulSet that is not Ready
      -- may have a pod that blocks its rollout. A failed pod read makes the
      -- member's observation unavailable rather than "not stuck".
      stuck <- traverse stuckRollout [resource | ((resource, ObservedPresent _), state) <- zip observed states, candidateStuck resource state]
      let failures = Map.fromList [(resource, ObservationUnavailable ("the StatefulSet's pods could not be read: " <> reason)) | (resource, Left reason) <- stuck]
          found = Map.fromList [(resource, describe pod') | (resource, Right (Just pod')) <- stuck]
          describe pod' = pod' ^. #pod <> " at revision " <> pod' ^. #podRevision <> " is not Ready and blocks the rollout to " <> pod' ^. #updateRevision
      pure (withStuckRollouts found <$> observationSet [(resource, Map.findWithDefault observation resource failures) | (resource, observation) <- observed])
    candidateStuck resource = \case
      KubernetesNotReady {} -> maybe False (isStatefulSet . address . fst) (Map.lookup resource specs)
      _ -> False
    stuckRollout resource = (resource,) <$> readStuckPod pods resource
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
          -- G5, RES-4 U6: an object whose DELETE finalizers hold is no live
          -- member; planning waits until it is gone.
          KubernetesTerminating {} -> ObservationUnavailable "Kubernetes object is being deleted (its deletion timestamp is set); replan once it is gone"
          KubernetesUnknown reason -> ObservationUnavailable reason
      )
    prepare operation = case singleSpec specs operation of
      Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
      Right (resource, declaration, _)
        | plannedAction operation == ReplaceStuckPod -> preparePodReplacement pods operation resource (address declaration)
      Right (resource, declaration, native) -> do
        takeover <- case takeoverReader of
          Just reader | plannedAction operation == UpdateResource -> prepareTakeover reader operation resource declaration
          _ -> pure (Right Nothing)
        (before, beforeStamp) <- case takeover of
          Right (Just (_, observed, stamp)) -> pure (observed, stamp)
          _ -> kubernetesObserveStamped ops resource
        pure $ do
          reviewedTakeover <- fmap (\(reviewed, _, _) -> reviewed) <$> takeover
          validateBefore operation resource (address declaration) (contentDigest native) before
          initial <- buildMutation (kubernetesContext ops) operation resource declaration native before
          -- F67: every update records the stamp its before-state carried.
          let stamped = if plannedAction operation == UpdateResource then initial {mutationBeforeStamp = beforeStamp} else initial
              mutation = case reviewedTakeover of
                Just _ -> stamped {mutationVersion = 3, mutationTakeover = reviewedTakeover}
                Nothing -> stamped
          bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON mutation))
          pure (PreparedNative bytes (summary mutation))
    -- The exact object observation and its live managed fields must name the
    -- same UID and resourceVersion; otherwise the object moved between reads.
    prepareTakeover reader operation resource declaration = do
      (observed, stamp) <- kubernetesObserveStamped ops resource
      live <- reader (address declaration)
      pure $ first (PrepareRefused (plannedOperationId operation)) $ do
        value <- live
        (uid, revision) <- liveIdentity value
        others <- foreignFieldManagers (Just (address declaration)) value
        case observed of
          _ | null others -> Right Nothing
          KubernetesPresent physical observedRevision _ _
            | physicalIdentityText physical == uid && observedRevision == revision ->
                Right (Just (FieldTakeover physical revision others, observed, stamp))
          KubernetesNotReady physical observedRevision _ _
            | physicalIdentityText physical == uid && observedRevision == revision ->
                Right (Just (FieldTakeover physical revision others, observed, stamp))
          _ -> Left "Kubernetes object changed while its field takeover was prepared; replan"
    preflight operation prepared
      | plannedAction operation == ReplaceStuckPod = pure (Left (podReplacementPending operation prepared))
    preflight operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        (current, stamp) <- observeMutation mutation
        sourceGuard <- verifyBackupSources mutation
        pure $ do
          if mutationAction mutation == RunDeclaredOperation && current == mutationBefore mutation
            then Right ()
            else requireWriteTarget mutation current stamp
          sourceGuard
    execute operation prepared
      | plannedAction operation == ReplaceStuckPod = pure (AdapterEffectFailed (KnownNoEffect (podReplacementPending operation prepared)))
    execute operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right mutation -> do
        (current, stamp) <- observeMutation mutation
        case requireWriteTarget mutation current stamp of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right () -> do
            sourceGuard <- verifyBackupSources mutation
            case sourceGuard of
              Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
              Right () ->
                if mutationAction mutation `elem` [RunDeclaredOperation, VerifyResource]
                  then pure AdapterEffectCompleted
                  -- G6: a retire's DELETE carries the fresh observation as its
                  -- precondition. An update's apply takes its resourceVersion
                  -- from the runtime's own guarded live read (RES-4 U10).
                  else kubernetesMutateConditional ops (if mutationAction mutation == RetireResource then mutation {mutationBefore = current} else mutation)
    verify operation prepared
      | plannedAction operation == ReplaceStuckPod = pure (Left (podReplacementPending operation prepared))
    verify operation prepared = case decodeMutation (kubernetesContext ops) specs operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- kubernetesObserve ops (mutationResource mutation)
        sourceGuard <- verifyBackupSources mutation
        case sourceGuard of
          Left reason -> pure (Left reason)
          Right () -> verifiedProof mutation current
    recover operation prepared
      | plannedAction operation == ReplaceStuckPod = pure (RecoveryUnresolved (podReplacementPending operation prepared))
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
              (before, liveStamp) <- observeMutation mutation
              -- A created restore scratch StatefulSet whose pod has a failed,
              -- restarted container never becomes Ready on its own (for example
              -- its pinned download or load failed); prove that failure so the
              -- restore-only review can be abandoned without claiming success.
              scratchFailure <- case current of
                KubernetesNotReady physical _ (Just owner) digest
                  | createdScratchStatefulSet mutation owner digest -> scratchFailed (mutationResource mutation) physical
                _ -> pure (Right False)
              pure $ case requireWriteTarget mutation before liveStamp of
                Right () -> RecoverySafeToRetry
                Left reason -> case current of
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
                               -- Only a created Deployment's wait lets resume go on
                               -- (Driver's continueReadiness); a created StatefulSet
                               -- that is not yet Ready settles as landed (M9).
                               Kubernetes _ "apps" kind _ _ -> nameText kind == "deployment"
                               Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind `elem` ["service", "domainmapping"]
                               _ -> False
                           ) ->
                        RecoveryAwaitingReadiness physical
                  -- F73, RES-4 U3: the stamp is written with the spec, so the
                  -- reviewed digest on the reviewed object is this update live;
                  -- another write left unready is not ours to await.
                  KubernetesNotReady physical _ (Just owner) digest
                    | mutationAction mutation == UpdateResource
                    , knativeServiceAddress (mutationAddress mutation)
                    , owner == mutationResource mutation
                    , digest == mutationNativeDigest mutation
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
               , ReplaceStuckPod
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
  when (plannedAction operation == ReplaceStuckPod && not (isStatefulSet (declaration ^. #address))) (Left "a stuck pod is replaced only for an apps/StatefulSet")
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
    -- change, an unschedulable pod) is an update of the unready object. So is
    -- correcting a Deployment, whose rollout replaces stuck pods (RES-4 §2).
    (UpdateResource, KubernetesNotReady _ revision (Just owner) _)
      | owner == resource && not (T.null revision)
      , statefulSetAddress target || deploymentAddress target ->
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
      , mutationBeforeStamp = Nothing
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
