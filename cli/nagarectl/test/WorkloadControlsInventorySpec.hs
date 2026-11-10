-- | EP-254: the workload controls through review, the journal and recovery. The
-- members are the production renderers' bytes, and execution is the production
-- adapter and kubectl interpreter over the fake API server.
module WorkloadControlsInventorySpec (workloadControlsInventoryTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (String))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Yaml qualified as Yaml
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Task (scheduledTask)
import Nagare.Dsl.Task.Render (renderTask)
import Nagare.Dsl.Types (mkServiceAccountName, mkServiceName)
import Nagare.Dsl.Worker
  ( Worker
  , execProbe
  , mkShutdownSeconds
  , webWorker
  )
import Nagare.Dsl.Worker.Render (renderWorkerDeployment)
import Nagare.Inventory.Adapter (AdapterRegistry, OperationAction (CreateResource), PlannedOperation (..), ResourceObservation (ConfirmedAbsent), mkAdapterRegistry, observationSet)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Journal (TransactionId)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.TaskRun (jobFromCronJob)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (VerifyBeforeRetry))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures (appScope, bindMember, extraId, ok, workerId)
import Nagare.Test.World.Adversary (newAdversary)
import Nagare.Test.World.ApiServer (settleControllers)
import Nagare.Test.World.Kubernetes (KubeWorld, effectiveWrites, newKubeWorld, worldKubernetesAdapter)
import Test.Tasty
import Test.Tasty.HUnit

workloadControlsInventoryTests :: TestTree
workloadControlsInventoryTests =
  testGroup
    "workload controls through the inventory (EP-254)"
    [ testCase "changing one control changes only that workload's reviewed bytes and input digest" controlChangesReview
    , testCase "a Deployment that landed while its readiness probe fails is not converged and stays resumable" landedUnreadyStaysResumable
    , testCase "after a successful hook and a failed readiness wait, resume does not run the hook again" resumeKeepsCompletedHook
    ]

-- | The reviewed worker, with readiness, shutdown and no account.
baseWorker :: Worker
baseWorker =
  either error id (webWorker "controlled" "registry.test/controlled")
    & #readiness
    .~ Just (ok (execProbe ["test", "-f", "/tmp/ready"]))
    & #liveness
    .~ Just (ok (execProbe ["test", "-f", "/tmp/alive"]))
    & #shutdown
    .~ Just (ok (mkShutdownSeconds 60))

renderedWorker :: Worker -> Value
renderedWorker worker = either (error . show) id (Yaml.decodeEither' (renderWorkerDeployment worker "t1"))

workerMember :: Worker -> [ResourceId] -> (ManagedResource, ByteString)
workerMember worker predecessors =
  first (\member -> member {dependencies = map OrderedAfter predecessors}) (bindMember workerId (renderedWorker worker))

-- | The pre-deploy Job exactly as the hook compiler derives it from the task.
hookMember :: (ManagedResource, ByteString)
hookMember = bindMember extraId job
  where
    task =
      either (error . show) id (scheduledTask "migrate" "0 0 * * *" "registry.test/controlled" "migrate")
        & #app
        .~ Just (ok (mkServiceName "controlled"))
    cron = either (error . show) id (Yaml.decodeEither' (renderTask task))
    job = either (error . show) id (jobFromCronJob (Just "controlled") "nagare-task-migrate" "personal" "migrate-hook-t1" cron)

hookProofId :: ResourceId
hookProofId = mintResourceId appScope (ok (mkLogicalKey "migrate")) (ok (mkName "completion"))

data Prepared = Prepared
  { store :: !InventoryStore
  , registry :: !AdapterRegistry
  , proposal :: !ChangeProposal
  , bundle :: !ReviewBundle
  , world :: !(IORef KubeWorld)
  , native :: !(Map.Map ResourceId (ManagedResource, ByteString))
  }

-- | Plan and review a create of these members, with the listed native digests
-- never becoming Ready.
prepare :: Map.Map ResourceId (ManagedResource, ByteString) -> [DeclaredOperation] -> Set.Set ContentDigest -> IO Prepared
prepare members operations unready = do
  let scope = ok (mkScopeDeclaration appScope [ResourceBundle (map (Managed . fst) (Map.elems members)) [] [] [] operations []])
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope scope :| []))
  store' <- newMemoryStore
  _ <- initializeStore store' fixtureBinding "workload-controls" >>= expectRight
  world' <- newKubeWorld unready
  adversary <- newAdversary []
  adapter <- worldKubernetesAdapter (fixtureBinding ^. #identity) members world' adversary
  let registry' = ok (mkAdapterRegistry [adapter])
  history <- loadInventoryHistory store' >>= expectRight
  let absent = ConfirmedAbsent (contentDigest "absent")
      observations = ok (observationSet [(resource, absent) | resource <- Set.toAscList (requiredResources (observationRequirements candidate history))])
      proposal' = ok (planChanges candidate noLifecycleDecisions history observations)
  before <- readStoreSnapshot store' >>= expectRight
  bundle' <- prepareReview registry' before proposal' >>= expectRight
  pure (Prepared store' registry' proposal' bundle' world' members)

-- | The input digest of each resource's single operation of this action.
inputDigests :: OperationAction -> ChangeProposal -> Map.Map ResourceId ContentDigest
inputDigests action proposal' =
  Map.fromList
    [ (resource, plannedInputDigest operation)
    | operation <- proposalOperations proposal'
    , plannedAction operation == action
    , resource <- NE.toList (plannedResources operation)
    ]

controlChangesReview :: Assertion
controlChangesReview = do
  baseline <- prepareWorker baseWorker
  kubernetesSpecsFromReview (bundle baseline) @?= Right (native baseline)
  let reader = ok (mkServiceAccountName "controlled-reader")
  forM_
    [ ("readiness path", baseWorker & #readiness .~ Just (ok (execProbe ["test", "-f", "/tmp/warm"])), "/tmp/warm")
    , ("shutdown duration", baseWorker & #shutdown .~ Just (ok (mkShutdownSeconds 90)), "terminationGracePeriodSeconds: 90")
    , ("service account", baseWorker & #serviceAccount .~ Just reader, "serviceAccountName: controlled-reader")
    ]
    $ \(label, changed, expected) -> do
      changedReview <- prepareWorker changed
      -- The saved review retains the new control in the worker's native bytes.
      kubernetesSpecsFromReview (bundle changedReview) @?= Right (native changedReview)
      assertBool (label <> ": retained") (BS.isInfixOf expected (renderWorkerDeployment changed "t1"))
      let digestsBefore = inputDigests CreateResource (proposal baseline)
          digestsAfter = inputDigests CreateResource (proposal changedReview)
          nativeDigests = Map.map (contentDigest . snd) . native
      Map.keysSet (Map.filter id (Map.intersectionWith (/=) digestsBefore digestsAfter)) @?= Set.singleton workerId
      Map.keysSet (Map.filter id (Map.intersectionWith (/=) (nativeDigests baseline) (nativeDigests changedReview))) @?= Set.singleton workerId
  where
    prepareWorker worker =
      prepare (Map.fromList [(workerId, workerMember worker []), (extraId, hookMember)]) [] Set.empty

-- | Review and apply a Job, its hook proof and a worker that waits for the
-- proof, with the worker's reviewed spec failing its readiness probe.
applyStopped :: IO (Prepared, TransactionId)
applyStopped = do
  let worker = workerMember baseWorker [hookProofId]
      proof = DeclaredOperation hookProofId (extraId :| []) [ContentInput (contentDigest (snd hookMember))] VerifyBeforeRetry PreDeployHook
      members = Map.fromList [(workerId, worker), (extraId, hookMember)]
  prepared <- prepare members [proof] (Set.singleton (contentDigest (snd worker)))
  _ <- publishReview (store prepared) (bundle prepared) >>= expectRight
  snapshot <- readStoreSnapshot (store prepared) >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshot (bundle prepared))
  result <- applyReviewed (store prepared) (registry prepared) reviewed >>= expectRight
  transaction <- case result of
    Converged _ -> assertFailure "a Deployment that never became ready converged"
    StoppedFailed tx _ _ -> pure tx
    StoppedAmbiguous tx _ _ -> pure tx
    other -> assertFailure ("unexpected stop: " <> show other)
  pure (prepared, transaction)

-- | Let the worker's readiness probe pass, as a fixed dependency would.
readinessRecovers :: Prepared -> IO ()
readinessRecovers prepared =
  modifyIORef' (world prepared) (#server %~ (settleControllers . (#objects %~ Map.map (#memory %~ Map.insert "templateOutcome" (String "Good")))))

landedUnreadyStaysResumable :: Assertion
landedUnreadyStaysResumable = do
  (prepared, transaction) <- applyStopped
  writesBefore <- effectiveWrites <$> readIORef (world prepared)
  readinessRecovers prepared
  resumed <- resumeTransaction (store prepared) (registry prepared) transaction >>= expectRight
  case resumed of
    Converged _ -> pure ()
    other -> assertFailure ("the transaction did not resume to convergence: " <> show other)
  writesAfter <- effectiveWrites <$> readIORef (world prepared)
  -- The landed write is settled by proof: resume writes nothing again.
  writesAfter @?= writesBefore

resumeKeepsCompletedHook :: Assertion
resumeKeepsCompletedHook = do
  (prepared, transaction) <- applyStopped
  let jobCreate =
        [ plannedOperationId operation
        | operation <- proposalOperations (proposal prepared)
        , plannedAction operation == CreateResource
        , extraId `elem` NE.toList (plannedResources operation)
        ]
  jobWrites <- Map.restrictKeys . effectiveWrites <$> readIORef (world prepared) <*> pure (Set.fromList jobCreate)
  Map.elems jobWrites @?= [1]
  readinessRecovers prepared
  resumed <- resumeTransaction (store prepared) (registry prepared) transaction >>= expectRight
  case resumed of
    Converged _ -> pure ()
    other -> assertFailure ("the transaction did not resume to convergence: " <> show other)
  jobWritesAfterResume <- Map.restrictKeys . effectiveWrites <$> readIORef (world prepared) <*> pure (Set.fromList jobCreate)
  jobWritesAfterResume @?= jobWrites

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure
