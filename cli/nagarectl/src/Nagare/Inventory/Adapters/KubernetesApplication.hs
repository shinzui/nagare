-- | The application-scope Kubernetes adapter, composed in one place for the
-- CLI and for the recovery model's fake cluster (EP-182), so the model runs
-- exactly the adapter production runs.
module Nagare.Inventory.Adapters.KubernetesApplication
  ( kubernetesApplicationAdapter
  )
where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (Adapter)
import Nagare.Inventory.Adapters.Kubernetes (mkKubernetesAdapterWithObservations)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOpsAndBatchWithCacheKey, readBackupReceiptFromCompletedPod, readLiveManagedObject)
import Nagare.Inventory.Adapters.KubernetesStuckPod (runtimePodOps)
import Nagare.Inventory.Adapters.RestoreScratch (restoreScratchPodFailed)
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
