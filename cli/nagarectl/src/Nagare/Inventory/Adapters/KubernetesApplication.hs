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
import Nagare.Inventory.Adapters.Kubernetes (mkKubernetesAdapterWithFieldTakeover, mkKubernetesAdapterWithRecoveryProbes)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOpsAndBatchWithCacheKey, readBackupReceiptFromCompletedPod, readLiveManagedObject)
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
   in if takeover
        then mkKubernetesAdapterWithFieldTakeover specs ops observeBatch receipt scratch guardedLiveObject
        else mkKubernetesAdapterWithRecoveryProbes specs ops observeBatch receipt scratch
  where
    guardedLiveObject target = do
      guarded <- runtimeGuard config
      either (pure . Left . ("cluster guard refused: " <>)) (const (readLiveManagedObject config target)) guarded
