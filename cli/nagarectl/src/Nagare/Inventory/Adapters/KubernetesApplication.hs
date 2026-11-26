-- | The application-scope Kubernetes adapter, composed in one place for the
-- CLI and for the recovery model's fake cluster (EP-182), so the model runs
-- exactly the adapter production runs.
module Nagare.Inventory.Adapters.KubernetesApplication
  ( kubernetesApplicationAdapter
  , kubernetesPlanningAdapter
  , kubernetesExecutionAdapter
  , kubernetesOverlapAddress
  , kubernetesReadinessAwait
  )
where

import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (Adapter (..), OperationAction (CreateResource, UpdateResource), OperationResources (SingleResource), PlannedOperation (..), operationResources, soleResource)
import Nagare.Inventory.Adapters.Kubernetes (ForeignFieldPlanning (..), mkKubernetesAdapterWithObservations)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOpsAndBatchWithCacheKey, readBackupReceiptFromCompletedPod, readLiveManagedObject, waitForReadiness)
import Nagare.Inventory.Adapters.KubernetesStuckPod (runtimePodOps)
import Nagare.Inventory.Adapters.RestoreScratch (restoreScratchPodFailed)
import Nagare.Inventory.KubernetesSnapshot (beginPhase, endPhase, newPhaseEpoch, phaseRuntime)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..))
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Policy (DataPolicy (Stateless))
import Nagare.Resource.Types (ProviderAddress (Kubernetes), ResourceId, nameText)

-- | What planning an update does about another writer's fields: with the
-- operator's explicit takeover opt-in it records them in the review (F37),
-- without it it refuses the plan (EP-280). Execution reads none; it follows
-- what the saved review recorded.
kubernetesApplicationAdapter ::
  ForeignFieldPlanning () ->
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  Adapter
kubernetesApplicationAdapter foreignFields config cacheKey specs =
  let (ops, observeBatch) = mkKubernetesRuntimeOpsAndBatchWithCacheKey config cacheKey specs
      receipt = readBackupReceiptFromCompletedPod config specs
      scratch = restoreScratchPodFailed config specs
   in -- EP-181: the pod operations find and replace a member StatefulSet's
      -- stuck pod.
      mkKubernetesAdapterWithObservations specs ops (runtimePodOps config specs) observeBatch receipt scratch (guardedLiveObject <$ foreignFields)
  where
    guardedLiveObject target = do
      guarded <- runtimeGuard config
      either (pure . Left . ("cluster guard refused: " <>)) (const (readLiveManagedObject config target)) guarded

-- | The same adapter for one plan (EP-226 M2): each batch observation reads
-- its members in grouped reads of one observation epoch, after the guard
-- admits, and the plan's later reads of those members (preparing each
-- operation's before-state) are answered from that epoch. A plan writes
-- nothing; apply builds its own adapter, whose every read is fresh. The flag
-- is the takeover opt-in; without it a foreign field owner refuses the plan.
kubernetesPlanningAdapter ::
  Bool ->
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  IO Adapter
kubernetesPlanningAdapter takeover config cacheKey specs = do
  phase <- newPhaseEpoch
  let adapter = kubernetesApplicationAdapter (if takeover then ForeignFieldsTakenOver () else ForeignFieldsRefused ()) (phaseRuntime config phase) cacheKey specs
      observe resources = do
        guarded <- runtimeGuard config
        when (isRight guarded) (beginPhase config phase [declaration ^. #address | resource <- resources, Just (declaration, _) <- [Map.lookup resource specs]])
        adapterObserve adapter resources
  pure adapter {adapterObserve = observe}

-- | Where an execution adapter stands with its review's validations.
data ValidationPhase = Pending | Proving | Ended
  deriving stock (Eq)

-- | The adapter of one admitted review (EP-227 M2). While admission proves
-- the review's validations, their preflights and verifications read one
-- fresh grouped epoch over exactly the validated members, gathered after the
-- guard admits. The first call for anything else (an operation of the
-- transaction, an observation, a recovery) ends that phase for good, before
-- any write, so every later read is fresh. Validations never write.
kubernetesExecutionAdapter ::
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  [PlannedOperation] ->
  IO Adapter
kubernetesExecutionAdapter config cacheKey specs validations = do
  phase <- newPhaseEpoch
  state <- newIORef Pending
  let adapter = kubernetesApplicationAdapter ForeignFieldsUnread (phaseRuntime config phase) cacheKey specs
      validating = Set.fromList (map plannedOperationId validations)
      addresses = [declaration ^. #address | validation <- validations, resource <- NE.toList (plannedResources validation), Just (declaration, _) <- [Map.lookup resource specs]]
      end = do
        previous <- atomicModifyIORef' state (Ended,)
        when (previous /= Ended) (endPhase phase)
      enter operation
        | plannedOperationId operation `Set.member` validating = do
            previous <- atomicModifyIORef' state (\current -> (if current == Pending then Proving else current, current))
            when (previous == Pending) $ do
              guarded <- runtimeGuard config
              when (isRight guarded) (beginPhase config phase addresses)
        | otherwise = end
  pure
    adapter
      { adapterObserve = \resources -> end >> adapterObserve adapter resources
      , adapterPrepare = \operation -> end >> adapterPrepare adapter operation
      , adapterPreflight = \operation prepared -> enter operation >> adapterPreflight adapter operation prepared
      , adapterExecute = \operation prepared -> end >> adapterExecute adapter operation prepared
      , adapterVerify = \operation prepared -> enter operation >> adapterVerify adapter operation prepared
      , adapterRecover = \operation prepared -> end >> adapterRecover adapter operation prepared
      , adapterSettle = (\settle operation prepared -> end >> settle operation prepared) <$> adapterSettle adapter
      }

-- | EP-228 M2: the Kubernetes operations that may await readiness beside one
-- another: a create or update of one stateless Deployment, Knative Service,
-- Service, ConfigMap or Secret, named by its address. Namespaces, CRDs,
-- controllers, Jobs, StatefulSets, replacements, retirements and every
-- durable member stay exclusive.
kubernetesOverlapAddress :: Map ResourceId (ManagedResource, ByteString) -> PlannedOperation -> Maybe Text
kubernetesOverlapAddress specs operation = case operationResources operation of
  SingleResource resource
    | plannedAction operation `elem` [CreateResource, UpdateResource]
    , Just (declaration, _) <- Map.lookup resource specs
    , declaration ^. #dataPolicy == Stateless
    , address@(Kubernetes _ group kind _ _) <- declaration ^. #address
    , (group, nameText kind) `elem` overlapping ->
        Just (T.pack (show address))
  _ -> Nothing
  where
    overlapping = [("apps", "deployment"), ("serving.knative.dev", "service"), ("", "service"), ("", "configmap"), ("", "secret")]

-- | Wait for the object an operation wrote to become ready, as its write
-- does: a resume of an effect that landed and is still rolling out waits for
-- Kubernetes' verdict instead of stopping. The cluster guard still decides
-- whether this context may be read.
kubernetesReadinessAwait :: KubernetesRuntimeConfig -> Map ResourceId (ManagedResource, ByteString) -> PlannedOperation -> IO ()
kubernetesReadinessAwait config specs operation = case soleResource operation of
  Right resource
    | Just (declaration, _) <- Map.lookup resource specs ->
        runtimeGuard config >>= \case
          Right () -> void (waitForReadiness config (declaration ^. #address))
          Left _ -> pure ()
  _ -> pure ()
