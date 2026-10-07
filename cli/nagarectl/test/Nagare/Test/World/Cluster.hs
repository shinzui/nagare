-- | EP-182: the fake cluster the recovery model runs against. The 'ApiServer'
-- sits behind the production kubectl interpreter
-- ('withKubectlInterpreter'), so the production runtime builds every request,
-- maps every answer and parses every object; the world never constructs a
-- 'KubernetesState' itself. A request outside the grammar the runtime emits
-- throws, so a harness gap fails the run instead of looking like a provider
-- answer.
module Nagare.Test.World.Cluster
  ( Cluster (..)
  , UnsupportedRequest (..)
  , newCluster
  , clusterConfig
  , clusterOps
  , clusterAdapter
  )
where

import Control.Exception (Exception, throwIO)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (Adapter)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps, KubernetesState, mkKubernetesAdapterWithConfigurationObservation)
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( mkKubernetesRuntimeOpsAndBatchWithCacheKey
  , observeKubernetesConfiguration
  , readBackupReceiptFromCompletedPod
  , readLiveManagedObject
  )
import Nagare.Inventory.Adapters.RestoreScratch (restoreScratchPodFailed)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), runKubectlWith, withKubectlInterpreter)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types (ContextId, ResourceId)
import Nagare.Test.World.ApiServer
import Nagare.Test.World.Kubectl

data Cluster = Cluster
  { server :: !(IORef ApiServer)
  , requests :: !(IORef [LoggedRequest])
  -- ^ Every request, most recent first.
  }

newtype UnsupportedRequest = UnsupportedRequest Text
  deriving stock (Show)

instance Exception UnsupportedRequest

newCluster :: ApiServer -> IO Cluster
newCluster initial = Cluster <$> newIORef initial <*> newIORef []

-- | A runtime configuration whose kubectl is the fake server. The cluster
-- guard always passes: there is one cluster.
clusterConfig :: ContextId -> Cluster -> KubernetesRuntimeConfig
clusterConfig context cluster =
  withKubectlInterpreter
    (runKubectlWith answer)
    (KubernetesRuntimeConfig context "world" (pure (Right ())))
  where
    answer request = do
      modifyIORef' (requests cluster) (logRequest request :)
      response <- atomicModifyIORef' (server cluster) (kubectlResponse request)
      case response of
        Answered code stdout stderr -> pure (Right (code, T.unpack stdout, T.unpack stderr))
        Unsupported argv -> throwIO (UnsupportedRequest ("world: kubectl request outside the runtime's grammar: " <> argv))

clusterOps :: ContextId -> Cluster -> Map.Map ResourceId (ManagedResource, ByteString) -> (KubernetesAdapterOps, [ResourceId] -> IO [KubernetesState])
clusterOps context cluster = mkKubernetesRuntimeOpsAndBatchWithCacheKey (clusterConfig context cluster) noCache

-- | The application-scope adapter, composed as the CLI composes it
-- (@inventoryKubernetesAdapterWith False@), over the fake cluster.
clusterAdapter :: ContextId -> Cluster -> Map.Map ResourceId (ManagedResource, ByteString) -> Adapter
clusterAdapter context cluster specs =
  let config = clusterConfig context cluster
      (ops, batch) = mkKubernetesRuntimeOpsAndBatchWithCacheKey config noCache specs
   in mkKubernetesAdapterWithConfigurationObservation
        specs
        ops
        batch
        (observeKubernetesConfiguration config noCache specs)
        (readBackupReceiptFromCompletedPod config specs)
        (restoreScratchPodFailed config specs)
        (readLiveManagedObject config)

noCache :: ResourceId -> IO (Either Text Text)
noCache _ = pure (Left "the world has no cache client")
