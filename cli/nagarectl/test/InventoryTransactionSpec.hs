module InventoryTransactionSpec (inventoryTransactionTests, runInventoryLockProbe) where

import Control.Monad (forM_)
import Data.Aeson (toJSON)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp
import System.Process (CreateProcess (env), createProcess, proc, waitForProcess)
import Test.Tasty
import Test.Tasty.HUnit

inventoryTransactionTests :: TestTree
inventoryTransactionTests =
  testGroup
    "inventory transactions"
    [ testCase "conditional store contract is identical in memory and on disk" $ do
        memory <- newMemoryStore
        exerciseStore memory
        withSystemTempDirectory "inventory-store" $ \root -> do
          filesystem <- openFilesystemStore root >>= expectRight
          exerciseStore filesystem
    , testCase "reviewed execution converges and skips no completed operation" $ do
        store <- newMemoryStore
        calls <- newIORef ([] :: [OperationId])
        (reviewed, registry) <- preparedFixture store calls (const (pure AdapterEffectCompleted)) (\operation -> pure (RecoveryProvedComplete (proof operation)))
        result <- applyReviewed store registry reviewed >>= expectRight
        case result of Converged _ -> pure (); other -> assertFailure (show other)
        length <$> readIORef calls >>= (@?= 1)
        headValue <- readHead store >>= expectRight >>= maybe (assertFailure "missing head" >> undefined) pure
        headActiveTransaction headValue @?= Nothing
        headAccepted headValue @?= headConverged headValue
    , testCase "ambiguous execution resumes from adapter proof without repeating the effect" $ do
        store <- newMemoryStore
        calls <- newIORef ([] :: [OperationId])
        firstAttempt <- newIORef True
        let executeOnce operation _ = do
              modifyIORef' calls (<> [plannedOperationId operation])
              wasFirst <- atomicModifyIORef' firstAttempt (\value -> (False, value))
              pure (if wasFirst then AdapterEffectAmbiguous "simulated process loss" else AdapterEffectCompleted)
        (reviewed, registry) <- preparedFixtureWith store executeOnce (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of StoppedAmbiguous value _ -> pure value; other -> assertFailure (show other) >> undefined
        resumed <- resumeTransaction store registry transaction >>= expectRight
        case resumed of Converged value -> value @?= transaction; other -> assertFailure (show other)
        length <$> readIORef calls >>= (@?= 1)
    , testCase "known no-effect failure retries the same reviewed operation" $ do
        store <- newMemoryStore
        attempts <- newIORef (0 :: Int)
        let executeRetry _ _ = do
              attempt <- atomicModifyIORef' attempts (\value -> (value + 1, value))
              pure (if attempt == 0 then AdapterEffectFailed (KnownNoEffect "simulated refusal") else AdapterEffectCompleted)
        (reviewed, registry) <- preparedFixtureWith store executeRetry (\_ _ -> pure RecoverySafeToRetry)
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of StoppedFailed value _ _ -> pure value; other -> assertFailure (show other) >> undefined
        resumed <- resumeTransaction store registry transaction >>= expectRight
        case resumed of Converged _ -> pure (); other -> assertFailure (show other)
        readIORef attempts >>= (@?= 2)
    , testCase "a second process is refused while the filesystem process lock is held" $
        withSystemTempDirectory "inventory-lock" $ \root -> do
          store <- openFilesystemStore root >>= expectRight
          held <- withProcessLock store $ \_ -> do
            executable <- getExecutablePath
            environment <- getEnvironment
            let childEnvironment = ("NAGARE_INVENTORY_LOCK_PROBE", root) : filter ((/= "NAGARE_INVENTORY_LOCK_PROBE") . fst) environment
            (_, _, _, process) <- createProcess (proc executable []) {env = Just childEnvironment}
            status <- waitForProcess process
            status @?= ExitSuccess
          case held of Right () -> pure (); other -> assertFailure (show other)
    , testCase "journal validation rejects a missing or reordered event" $ do
        let transaction = ok (mkTransactionId ("tx-" <> T.replicate 64 "a"))
            operation = ok (mkOperationId "op-one")
            firstEvent = JournalEvent 1 0 Nothing transaction (Just operation) IntentRecorded "2026-09-22T00:00:00Z" "intent"
            secondEvent = JournalEvent 1 1 (Just (journalEventDigest firstEvent)) transaction (Just operation) (Completed (proofOperation operation)) "2026-09-22T00:00:01Z" "done"
        validateJournal [firstEvent, secondEvent] @?= Right [firstEvent, secondEvent]
        assertBool "missing event refused" (isLeft (validateJournal [secondEvent]))
    ]

exerciseStore :: InventoryStore -> Assertion
exerciseStore store = do
  let binding = fixtureBinding
  initial <- initializeStore store binding "client-test" >>= expectRight
  headGeneration initial @?= 0
  let bytes = "immutable"
      key = objectKeyFor "objects" (contentDigest bytes)
  _ <- publishIfAbsent store key bytes >>= expectRight
  _ <- publishIfAbsent store key bytes >>= expectRight
  conflicting <- publishIfAbsent store key "different"
  assertBool "different bytes at an immutable key are refused" (isLeft conflicting)
  let replacement = initial {headGeneration = 1}
  _ <- replaceHeadIfGenerationMatches store (Just 0) replacement >>= expectRight
  stale <- replaceHeadIfGenerationMatches store (Just 0) replacement
  assertBool "stale head generation is refused" (isLeft stale)

preparedFixture :: InventoryStore -> IORef [OperationId] -> (PlannedOperation -> IO AdapterExecution) -> (PlannedOperation -> IO RecoveryDecision) -> IO (ReviewedPlan, AdapterRegistry)
preparedFixture store calls execution recovery =
  preparedFixtureWith store (\operation _ -> modifyIORef' calls (<> [plannedOperationId operation]) >> execution operation) (\operation _ -> recovery operation)

preparedFixtureWith :: InventoryStore -> (PlannedOperation -> PreparedNative -> IO AdapterExecution) -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision) -> IO (ReviewedPlan, AdapterRegistry)
preparedFixtureWith store execution recovery = do
  bytes <- BS.readFile "test/fixtures/inventory/valid.json"
  let CandidateInput snapshot changes = ok (decodeCandidateInput bytes)
      candidate = ok (composeInventory snapshot changes)
      binding = inventoryBinding (candidateInventory candidate)
  _ <- initializeStore store binding "client-test" >>= expectRight
  _ <- seedInventoryHistory store candidate >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let acceptedIds = Set.fromList [declarationId declaration | (_, (_, scope)) <- Map.toAscList (historyAccepted history), bundle <- scopeBundles scope, declaration <- bundle ^. #declarations]
      requirements = observationRequirements candidate history
      observations =
        ok $
          observationSet
            [ (resource, if Set.member resource acceptedIds then ObservedPresent (physical resource) else ConfirmedAbsent (absence resource))
            | resource <- Set.toAscList (requiredResources requirements)
            ]
      registry = recordingRegistry execution recovery
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
  snapshotBefore <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshotBefore proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  snapshotAfter <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshotAfter bundle)
  pure (reviewed, registry)
  where
    physical resource = ok (mkPhysicalIdentity ("accepted:" <> resourceIdText resource))
    absence resource = contentDigest (TE.encodeUtf8 ("absent:" <> resourceIdText resource))

recordingRegistry :: (PlannedOperation -> PreparedNative -> IO AdapterExecution) -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision) -> AdapterRegistry
recordingRegistry execution recovery =
  ok (mkAdapterRegistry (map adapter [KubernetesExecutor, PulumiExecutor, HostExecutor, ArtifactExecutor]))
  where
    adapter executor =
      Adapter
        { adapterExecutor = executor
        , adapterIdentity = "recording"
        , adapterVersion = "1"
        , adapterObserve = \_ -> pure (Left "tests inject observations")
        , adapterPrepare = \operation -> pure (Right (PreparedNative (canonical operation) "recording adapter"))
        , adapterPreflight = \_ _ -> pure (Right ())
        , adapterExecute = execution
        , adapterVerify = \operation -> pure (Right (proof operation))
        , adapterRecover = recovery
        }
    canonical = either (error . T.unpack) id . canonicalValue . toJSON

proof :: PlannedOperation -> ContentDigest
proof = contentDigest . TE.encodeUtf8 . operationIdText . plannedOperationId

proofOperation :: OperationId -> ContentDigest
proofOperation = contentDigest . TE.encodeUtf8 . operationIdText

fixtureBinding :: ContextBinding
fixtureBinding = ContextBinding (ok (mkContextId "context-1")) (ok (mkName "project"))

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

runInventoryLockProbe :: FilePath -> IO ExitCode
runInventoryLockProbe root = do
  storeResult <- openFilesystemStore root
  case storeResult of
    Left _ -> pure (ExitFailure 2)
    Right store -> do
      result <- withProcessLock store (\_ -> pure ())
      pure $ case result of Left StoreBusy -> ExitSuccess; _ -> ExitFailure 1
