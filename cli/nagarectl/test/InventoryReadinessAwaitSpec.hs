-- | A healthy rollout that is slow is not a stop. A Deployment's readiness
-- wait ends on Kubernetes' own verdict, a resume of an update that landed and
-- is still rolling out waits for it, and only the adapter's proof completes
-- the operation. Nothing is written a second time.
module InventoryReadinessAwaitSpec (inventoryReadinessAwaitTests) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import InventoryTransactionSpec (preparedReadinessFixture)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.KubernetesApplication (kubernetesReadinessAwait)
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesTransport (runKubectlWith, withKubectlInterpreter)
import Nagare.Inventory.Store (newMemoryStore)
import Nagare.Resource.Inventory (Executor (KubernetesExecutor), ManagedResource)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Assertions (stoppedAt)
import Nagare.Test.Support.Kubernetes qualified as K
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty
import Test.Tasty.HUnit

inventoryReadinessAwaitTests :: TestTree
inventoryReadinessAwaitTests =
  testGroup
    "readiness waits on the provider's verdict"
    [ testCase "a Deployment update whose own write is live and still rolling out awaits readiness, not a replan" $ do
        state <- newIORef (KubernetesPresent K.physical "4" (Just K.resource) (contentDigest "old-spec"))
        calls <- newIORef (0 :: Int)
        let adapter = mkKubernetesAdapter worker (K.ops state calls)
        prepared <- adapterPrepare adapter K.updateOperation >>= K.expectRight
        -- The reviewed digest on the reviewed object is this update, live.
        writeIORef state (KubernetesNotReady K.physical "5" (Just K.resource) (contentDigest workerBytes))
        adapterRecover adapter K.updateOperation prepared >>= (@?= RecoveryAwaitingReadiness K.physical)
        -- Another write of this member's is not ours to await.
        writeIORef state (KubernetesNotReady K.physical "6" (Just K.resource) (contentDigest "another-review"))
        adapterRecover adapter K.updateOperation prepared >>= \case
          RecoveryUnresolved _ -> pure ()
          other -> assertFailure (show other)
        readIORef calls >>= (@?= 0)
    , testCase "a Deployment's readiness wait has no fixed timeout: kubectl rollout status ends on Kubernetes' verdict" $ do
        asked <- newIORef []
        let answer request = modifyIORef' asked (<> [request ^. #arguments]) >> pure (Right (ExitSuccess, "", ""))
            config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (K.ok (mkContextId "test")) "wait" (pure (Right ())))
        kubernetesReadinessAwait config worker K.updateOperation
        waits <- filter ((== ["rollout", "status"]) . take 2) <$> readIORef asked
        waits @?= [["rollout", "status", "deployment/nagare-events", "--namespace", "nagare-system"]]
    , testCase "resume waits for a landed effect's readiness, proves it and goes on without a second write" $ do
        store <- newMemoryStore
        effects <- newIORef []
        ready <- newIORef False
        let effect operation _ = do
              previous <- readIORef effects
              modifyIORef' effects (<> [plannedOperationId operation])
              pure (if null previous then AdapterEffectAmbiguous "readiness pending" else AdapterEffectCompleted)
            recover _ _ = do
              available <- readIORef ready
              pure (if available then RecoveryProvedComplete (contentDigest "rolled-out") else RecoveryAwaitingReadiness K.physical)
        -- The second Deployment depends on the first, so resume has nothing else to do but wait.
        (reviewed, registry) <- preparedReadinessFixture store True Stateless "deployment" effect recover
        stopped <- applyReviewed store registry reviewed >>= K.expectRight
        transaction <- case stopped of
          StoppedAmbiguous value _ _ -> pure value
          other -> assertFailure (show other) >> error "unreachable"
        -- Without a way to wait, resume stops where it did.
        resumeTransaction store registry transaction >>= K.expectRight >>= \resumed -> stoppedAt resumed @?= stoppedAt stopped
        let waiting = K.ok (withReadinessAwait KubernetesExecutor (\_ -> writeIORef ready True) registry)
        resumeTransaction store waiting transaction >>= K.expectRight >>= (@?= Converged transaction)
        calls <- readIORef effects
        (length calls, Set.size (Set.fromList calls)) @?= (2, 2)
    ]

workerObject :: Value
workerObject = object ["apiVersion" .= ("apps/v1" :: Text), "kind" .= ("Deployment" :: Text), "metadata" .= object ["name" .= ("nagare-events" :: Text), "namespace" .= ("nagare-system" :: Text)]]

workerBytes :: ByteString
workerBytes = K.ok (canonicalValue workerObject)

worker :: Map.Map ResourceId (ManagedResource, ByteString)
worker = Map.singleton K.resource (K.ok (bindKubernetesObject (K.input {inputObject = workerObject, objectDigest = contentDigest workerBytes})))
