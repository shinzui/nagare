-- | The application-scope Kubernetes adapter, composed in one place for the
-- CLI and for the recovery model's fake cluster (EP-182), so the model runs
-- exactly the adapter production runs.
module Nagare.Inventory.Adapters.KubernetesApplication
  ( kubernetesApplicationAdapter
  , kubernetesPlanningAdapter
  )
where

import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (Adapter (..))
import Nagare.Inventory.Adapters.Kubernetes (mkKubernetesAdapterWithObservations)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOpsAndBatchWithCacheKey, readBackupReceiptFromCompletedPod, readLiveManagedObject)
import Nagare.Inventory.Adapters.KubernetesStuckPod (runtimePodOps)
import Nagare.Inventory.Adapters.RestoreScratch (restoreScratchPodFailed)
import Nagare.Inventory.KubernetesSnapshot (beginPhase, newPhaseEpoch, phaseRuntime)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..))
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types (ResourceId)

-- | With the operator's explicit takeover opt-in, planning records foreign
-- field managers of drifted objects in the review (F37). Execution needs no
-- opt-in; it follows what the saved review recorded.
kubernetesApplicationAdapter ::
  Bool ->
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  Adapter
kubernetesApplicationAdapter takeover config cacheKey specs =
  let (ops, observeBatch) = mkKubernetesRuntimeOpsAndBatchWithCacheKey config cacheKey specs
      receipt = readBackupReceiptFromCompletedPod config specs
      scratch = restoreScratchPodFailed config specs
   in -- EP-181: the pod operations find and replace a member StatefulSet's
      -- stuck pod. The takeover reader enables reviewed field takeover (F37).
      mkKubernetesAdapterWithObservations specs ops (runtimePodOps config specs) observeBatch receipt scratch (if takeover then Just guardedLiveObject else Nothing)
  where
    guardedLiveObject target = do
      guarded <- runtimeGuard config
      either (pure . Left . ("cluster guard refused: " <>)) (const (readLiveManagedObject config target)) guarded

-- | The same adapter for one plan (EP-226 M2): each batch observation reads
-- its members in grouped reads of one observation epoch, after the guard
-- admits, and the plan's later reads of those members (preparing each
-- operation's before-state) are answered from that epoch. A plan writes
-- nothing; apply builds its own adapter, whose every read is fresh.
kubernetesPlanningAdapter ::
  Bool ->
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  IO Adapter
kubernetesPlanningAdapter takeover config cacheKey specs = do
  phase <- newPhaseEpoch
  let adapter = kubernetesApplicationAdapter takeover (phaseRuntime config phase) cacheKey specs
      observe resources = do
        guarded <- runtimeGuard config
        when (isRight guarded) (beginPhase config phase [declaration ^. #address | resource <- resources, Just (declaration, _) <- [Map.lookup resource specs]])
        adapterObserve adapter resources
  pure adapter {adapterObserve = observe}
