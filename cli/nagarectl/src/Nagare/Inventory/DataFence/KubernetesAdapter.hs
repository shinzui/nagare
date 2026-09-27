-- | Attach the native Kubernetes fence to a reviewed inventory executor.
-- Planning captures provider facts once; replay reconstructs controls from
-- the private member saved with that review, without calling the selector.
module Nagare.Inventory.DataFence.KubernetesAdapter
  ( KubernetesFenceFactory (..)
  , registerKubernetesDataFence
  ) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence.KubernetesCapture
import Nagare.Inventory.DataFence.KubernetesExclusion
import Nagare.Inventory.DataFence.KubernetesIntent (decodeKubernetesFenceIntent)
import Nagare.Inventory.Store (DataFenceRecord (..), ScopeRevision)
import Nagare.Resource.Inventory (Declaration, Executor (KubernetesExecutor), ManagedResource)
import Nagare.Resource.Types

data KubernetesFenceFactory = KubernetesFenceFactory
  { factoryRuntime :: !KubernetesRuntimeConfig
  , factoryBinding :: !ContextBinding
  , factoryAccepted :: !(Map ScopeId ScopeRevision)
  , factoryDeclarations :: ![Declaration]
  , factoryNative :: !(Map ResourceId (ManagedResource, ByteString))
  , factorySelect :: !(PlannedOperation -> PreparedNative
      -> IO (Either Text (Maybe KubernetesCaptureRequest)))
  , factoryReplay :: !(DataFenceRecord -> PlannedOperation
      -> PreparedNative -> Either Text ())
  , factoryVerify :: !(DataFenceRecord -> IO (Either Text Bool))
  }

registerKubernetesDataFence :: KubernetesFenceFactory -> AdapterRegistry
  -> Either Text AdapterRegistry
registerKubernetesDataFence factory registry =
  withAdapterFence registry KubernetesExecutor AdapterFence
    { fenceCapability = "kubernetes-native-data-fence-v1"
    , fenceForOperation = \operation prepared -> do
        selected <- factorySelect factory operation prepared
        case selected of
          Left reason -> pure (Left reason)
          Right Nothing -> pure (Right Nothing)
          Right (Just request) ->
            if captureBinding request /= factoryBinding factory
                || captureAccepted request /= factoryAccepted factory
              then pure (Left "Kubernetes fence planning context or accepted revisions changed")
              else fmap (fmap Just) (captureKubernetesFence
                (kubectlKubernetesCaptureTransport (factoryRuntime factory))
                (factoryDeclarations factory) (factoryNative factory) request)
    , fenceFromReviewedRecord = \record operation prepared -> do
        let ContextBinding context _ = factoryBinding factory
        unless (fenceContext record == factoryBinding factory
            && fenceAccepted record == factoryAccepted factory
            && runtimeContext (factoryRuntime factory) == context)
          (Left "Kubernetes fence replay context or accepted revisions changed")
        _ <- decodeKubernetesFenceIntent record
        factoryReplay factory record operation prepared
        pure (kubernetesDataFenceControls
          (kubectlKubernetesExclusion (factoryRuntime factory)
            (factoryAccepted factory) (factoryDeclarations factory)
            (factoryNative factory)) (factoryVerify factory))
    }
