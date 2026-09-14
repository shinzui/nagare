{-# LANGUAGE OverloadedStrings #-}

module PlatformCutoverSpec (platformCutoverTests) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Foldable (traverse_)
import Data.IORef
import Data.List (elemIndex)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, defaultTimeLocale, parseTimeOrError)
import Nagare.Dsl.Prelude hiding (first, over)
import Nagare.Platform.Cutover
import Nagare.Platform.Replacement
import Nagare.Platform.StateTransfer
import Numeric.Natural (Natural)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

platformCutoverTests :: TestTree
platformCutoverTests =
  testGroup
    "PlatformCutover"
    [ testCase "starts deadline on first successful write fence and commits in order" testSuccessfulCutover
    , testCase "rolls back before reserved threshold" testDeadlineRollback
    , testCase "reconciles crash after old address detach" testDetachedReconciliation
    , testCase "never admits candidate writes before context commit" testCommitOrdering
    , testCase "rolls back a failure after candidate address attachment" testPostAttachFailure
    , testCase "converges every pre-commit before/after failpoint to old service" testPreCommitFailureMatrix
    , testCase "refuses automatic rollback after write admission and fences candidate" testPostCommitRollback
    , testCase "observes an unjournalled write-admission commit before rollback" testObservedCommitRollback
    , testCase "cleanup rejects an unrecorded resource" testCleanupOwnership
    , testCase "finalize removes only recorded former-active resources" testFinalize
    , testCase "finalize resumes after recorded resources were already deleted" testFinalizeResume
    , testCase "transaction persistence ignores a sibling temporary file and rejects future schema" testPersistence
    , testCase "readiness accepts the exact budget boundary and rejects one-second excess" testBudgetBoundary
    , testCase "JSON uses stable committed and address tokens" testStableJson
    ]

testSuccessfulCutover :: Assertion
testSuccessfulCutover = do
  fixture <- newFixture Nothing
  result <- runCutover (fixtureOps fixture) readyTransaction
  completed <- assertRight result
  replacementState completed @?= Committed
  replacementWritesAdmitted completed @?= True
  replacementCandidateFenced completed @?= False
  replacementOldPower completed @?= InstanceStopped
  replacementDowntimeStartedMonotonic completed @?= Just (MonotonicTime 10)
  replacementObservedDowntimeSeconds completed @?= Just 0
  events <- readIORef (fixtureEvents fixture)
  assertBefore "commit-context" "admit-writes" events
  assertBefore "admit-writes" "stop-old" events

testDeadlineRollback :: Assertion
testDeadlineRollback = do
  fixture <- newFixture Nothing
  let ops = (fixtureOps fixture) {finalizeState = \_ _ -> writeIORef (fixtureClock fixture) 660 >> logResult fixture "finalize-state" (Right finalEvidence)}
  result <- runCutover ops readyTransaction
  failure <- assertLeft result
  cutoverRecoveryAttempted failure @?= True
  replacementState (cutoverErrorTransaction failure) @?= RolledBack
  replacementWritesAdmitted (cutoverErrorTransaction failure) @?= False
  replacementAddressOwner (cutoverErrorTransaction failure) @?= AddressOnOld

testDetachedReconciliation :: Assertion
testDetachedReconciliation = do
  fixture <- newFixture Nothing
  writeIORef (fixtureAddress fixture) AddressUnattached
  let interrupted = readyTransaction {replacementState = CuttingOver, replacementPhase = Just DetachOldAddress, replacementDowntimeStartedAt = Just fixtureNow, replacementDowntimeStartedMonotonic = Just (MonotonicTime 10), replacementAddressOwner = AddressUnattached}
  reconciliation <- reconcileCutover (fixtureOps fixture) interrupted >>= assertRight
  reconciled <- case reconciliation of
    RollbackRequired tx -> pure tx
    other -> assertFailure ("expected rollback reconciliation, got " <> show other) >> pure interrupted
  recovered <- runRollback (fixtureOps fixture) reconciled >>= assertRight
  replacementState recovered @?= RolledBack
  readIORef (fixtureAddress fixture) >>= (@?= AddressOnOld)

testCommitOrdering :: Assertion
testCommitOrdering = do
  fixture <- newFixture (Just "admit-writes")
  result <- runCutover (fixtureOps fixture) readyTransaction
  completed <- assertRight result
  replacementState completed @?= Committed
  replacementWritesAdmitted completed @?= True
  events <- readIORef (fixtureEvents fixture)
  assertBefore "commit-context" "admit-writes" events
  assertBool "an observed commit point is never rolled back" ("restore-context" `notElem` events)

testPostAttachFailure :: Assertion
testPostAttachFailure = do
  fixture <- newFixture (Just "verify-candidate")
  result <- runCutover (fixtureOps fixture) readyTransaction
  failure <- assertLeft result
  cutoverRecoveryAttempted failure @?= True
  replacementState (cutoverErrorTransaction failure) @?= RolledBack
  readIORef (fixtureAddress fixture) >>= (@?= AddressOnOld)

testPreCommitFailureMatrix :: Assertion
testPreCommitFailureMatrix =
  traverse_
    check
    [ "quiesce-old"
    , "finalize-state"
    , "prepare-ingress"
    , "detach-old"
    , "attach-candidate"
    , "verify-candidate"
    , "commit-context"
    ]
  where
    check label = traverse_ (checkMode label) [Before, After]
    checkMode label mode = do
      fixture <- newFixtureWith (Just (Fault mode label))
      failure <- runCutover (fixtureOps fixture) readyTransaction >>= assertLeft
      let recovered = cutoverErrorTransaction failure
      assertBool (T.unpack label <> " recovery attempted") (cutoverRecoveryAttempted failure)
      replacementState recovered @?= RolledBack
      replacementAddressOwner recovered @?= AddressOnOld
      replacementWritesAdmitted recovered @?= False

testPostCommitRollback :: Assertion
testPostCommitRollback = do
  fixture <- newFixture Nothing
  let committed = readyTransaction {replacementState = Committed, replacementWritesAdmitted = True, replacementCandidateFenced = False, replacementRollbackEligible = False}
  failure <- runRollback (fixtureOps fixture) committed >>= assertLeft
  replacementState (cutoverErrorTransaction failure) @?= ReplacementFailed
  replacementCandidateFenced (cutoverErrorTransaction failure) @?= True
  assertBool "manual recovery is named" ("manual" `T.isInfixOf` cutoverErrorMessage failure)

testObservedCommitRollback :: Assertion
testObservedCommitRollback = do
  fixture <- newFixture Nothing
  let admittedObservation = CutoverObservation AddressOnCandidate InstanceRunning False True True False
      ops = (fixtureOps fixture) {observeCutover = const (pure (Right admittedObservation))}
      stale = readyTransaction {replacementState = CuttingOver, replacementWritesAdmitted = False}
  failure <- runRollback ops stale >>= assertLeft
  replacementState (cutoverErrorTransaction failure) @?= ReplacementFailed
  events <- readIORef (fixtureEvents fixture)
  assertBool "old context is never restored after observed admission" ("restore-context" `notElem` events)
  assertBool "old address is never restored after observed admission" ("attach-old" `notElem` events)

testCleanupOwnership :: Assertion
testCleanupOwnership = do
  deleted <- newIORef []
  let transaction = committedForCleanup [RetainedResource "old-vm" "former-active-instance" False, RetainedResource "foreign-disk" "unrecorded" True]
      ops = cleanupFixture deleted (\resource -> pure (Right (retainedResourceId resource /= "foreign-disk")))
  failure <- finalizeReplacement True ops transaction >>= assertLeftCleanup
  assertBool "role mismatch is reported" ("role-mismatched" `T.isInfixOf` cleanupErrorMessage failure)
  readIORef deleted >>= (@?= [])

testFinalize :: Assertion
testFinalize = do
  deleted <- newIORef []
  let resources = [RetainedResource "old-vm" "former-active-instance" False, RetainedResource "old-disk" "former-active-data" True]
      transaction = committedForCleanup resources
      ops = cleanupFixture deleted (const (pure (Right True)))
  completed <- finalizeReplacement False ops transaction >>= assertRightCleanup
  replacementState completed @?= Complete
  replacementRetainedResources completed @?= []
  readIORef deleted >>= (@?= ["old-vm", "old-disk"])

testFinalizeResume :: Assertion
testFinalizeResume = do
  deleted <- newIORef []
  let interrupted = (committedForCleanup []) {replacementState = Finalizing}
      ops = cleanupFixture deleted (const (pure (Right True)))
  completed <- finalizeReplacement True ops interrupted >>= assertRightCleanup
  replacementState completed @?= Complete
  readIORef deleted >>= (@?= [])

testPersistence :: Assertion
testPersistence =
  withSystemTempDirectory "nagare-replacement" $ \root -> do
    let path = root </> "transaction.json"
    writeReplacementTransaction path readyTransaction
    writeFile (path <> ".tmp") "torn"
    doesFileExist (path <> ".tmp") >>= assertBool "fixture temporary exists"
    decoded <- readReplacementTransaction path >>= either (assertFailure . T.unpack) pure
    decoded @?= readyTransaction
    writeReplacementTransaction path (readyTransaction {replacementSchemaVersion = 2})
    future <- readReplacementTransaction path
    assertBool "future schemas fail closed" (either (T.isInfixOf "unsupported") (const False) future)

testBudgetBoundary :: Assertion
testBudgetBoundary = do
  let exact = readyTransaction {replacementPredictedStateSeconds = 500, replacementPredictedHandoffSeconds = 100, replacementPredictedVerificationSeconds = 50}
      over = exact {replacementPredictedVerificationSeconds = 51}
  ready (readiness fixtureNow exact) @?= True
  ready (readiness fixtureNow over) @?= False
  blockers (readiness fixtureNow over) @?= ["predicted downtime exceeds the budget by 1 seconds"]

testStableJson :: Assertion
testStableJson = do
  let bytes = LBC.unpack (Aeson.encode (readyTransaction {replacementState = Committed, replacementAddressOwner = AddressOnCandidate}))
  assertBool "committed token" ("\"committed\"" `isInfix` bytes)
  assertBool "candidate address token" ("\"candidate\"" `isInfix` bytes)
  where
    needle `isInfix` haystack = any (needle `prefixOf`) (tails haystack)
    prefixOf prefix value = take (length prefix) value == prefix
    tails [] = [[]]
    tails value@(_ : rest) = value : tails rest

data Fixture = Fixture
  { fixtureOps :: !CutoverOps
  , fixtureEvents :: !(IORef [Text])
  , fixtureClock :: !(IORef Natural)
  , fixtureAddress :: !(IORef AddressOwner)
  }

data FaultMode = Before | After
  deriving stock (Eq, Show)

data Fault = Fault !FaultMode !Text
  deriving stock (Eq, Show)

newFixture :: Maybe Text -> IO Fixture
newFixture failAt = newFixtureWith (Fault After <$> failAt)

newFixtureWith :: Maybe Fault -> IO Fixture
newFixtureWith fault = do
  events <- newIORef []
  clock <- newIORef 10
  address <- newIORef AddressOnOld
  oldPower <- newIORef InstanceRunning
  fenced <- newIORef True
  contextCommitted <- newIORef False
  writesAdmitted <- newIORef False
  persisted <- newIORef []
  let fixture = Fixture ops events clock address
      operation label effect = do
        modifyIORef' events (<> [label])
        case fault of
          Just (Fault Before failed) | failed == label -> pure (Left ("injected failure before " <> label))
          _ -> do
            effect
            pure $ case fault of
              Just (Fault After failed) | failed == label -> Left ("injected failure after " <> label)
              _ -> Right ()
      evidenceOperation label effect token = fmap (fmap (const token)) (operation label effect)
      hostIsOld host = hostResourceId host == hostResourceId oldHost
      ops =
        CutoverOps
          { cutoverConfirmation = "prod/12345678"
          , cutoverStatePlan = transferPlan
          , monotonicNow = MonotonicTime <$> readIORef clock
          , wallNow = pure fixtureNow
          , persistCutover = \tx -> modifyIORef' persisted (<> [tx])
          , revalidate = \_ -> do
              modifyIORef' events (<> ["revalidate"])
              pure $ if fault == Just (Fault Before "revalidate") || fault == Just (Fault After "revalidate") then Left "injected failure at revalidate" else Right validRevalidation
          , armCandidate = \_ -> evidenceOperation "arm-candidate" (pure ()) "armed"
          , quiesceOld = \_ -> do
              result <- operation "quiesce-old" (pure ())
              pure (result >> Right (QuiesceResult (QuiesceSnapshot "scales-and-schedules") fixtureNow (MonotonicTime 10)))
          , finalizeState = \_ _ -> fmap (fmap (const finalEvidence)) (operation "finalize-state" (pure ()))
          , prepareCandidateIngress = \_ -> evidenceOperation "prepare-ingress" (pure ()) "candidate ingress prepared"
          , observeCutover = \_ -> do
              owner <- readIORef address
              power <- readIORef oldPower
              gate <- readIORef fenced
              committed <- readIORef contextCommitted
              admitted <- readIORef writesAdmitted
              pure (Right (CutoverObservation owner power gate committed admitted (owner == AddressOnOld && power == InstanceRunning)))
          , detachAddress = \host -> operation (if hostIsOld host then "detach-old" else "detach-candidate") (writeIORef address AddressUnattached)
          , attachAddress = \host -> operation (if hostIsOld host then "attach-old" else "attach-candidate") (writeIORef address (if hostIsOld host then AddressOnOld else AddressOnCandidate))
          , verifyPublic = \mode -> case mode of
              CandidateMaintenanceBypass -> do
                modifyIORef' events (<> ["verify-candidate"])
                pure $ case fault of
                  Just (Fault _ "verify-candidate") -> Left "injected failure at verify-candidate"
                  _ -> Right publicEvidence
              OldPublicService -> modifyIORef' events (<> ["verify-old"]) >> pure (Right publicEvidence)
          , commitContext = \_ -> operation "commit-context" (writeIORef contextCommitted True)
          , restoreContext = \_ -> operation "restore-context" (writeIORef contextCommitted False)
          , setWriteGate = \host gate ->
              let label = case gate of WritesFenced -> "fence-candidate"; WritesAdmitted -> "admit-writes"
               in operation label (if hostIsOld host then pure () else writeIORef fenced (gate == WritesFenced) >> writeIORef writesAdmitted (gate == WritesAdmitted))
          , setInstancePower = \host power -> operation (if power == InstanceStopped then "stop-old" else "start-old") (if hostIsOld host then writeIORef oldPower power else pure ())
          , restoreOldWorkloads = \_ -> operation "restore-workloads" (pure ())
          , cancelForwardWork = modifyIORef' events (<> ["cancel-forward"])
          }
  pure fixture

logResult :: Fixture -> Text -> Either Text a -> IO (Either Text a)
logResult fixture label result = modifyIORef' (fixtureEvents fixture) (<> [label]) >> pure result

cleanupFixture :: IORef [Text] -> (RetainedResource -> IO (Either Text Bool)) -> CleanupOps
cleanupFixture deleted owns =
  CleanupOps
    { cleanupConfirmation = "prod/12345678"
    , cleanupNow = pure (addUTCTime 86401 fixtureNow)
    , persistCleanup = const (pure ())
    , cleanupPublicHealthy = pure (Right True)
    , cleanupEvidenceRetained = const (pure (Right True))
    , cleanupResourceOwned = \_ -> owns
    , deleteRecordedResource = \resource -> modifyIORef' deleted (<> [retainedResourceId resource]) >> pure (Right ())
    , convergeActiveOnly = const (pure (Right ()))
    , pruneTransactionArtifacts = const (pure (Right ()))
    }

committedForCleanup :: [RetainedResource] -> ReplacementTransaction
committedForCleanup resources =
  readyTransaction
    { replacementState = Committed
    , replacementWritesAdmitted = True
    , replacementRollbackEligible = False
    , replacementRetentionUntil = Just (addUTCTime 86400 fixtureNow)
    , replacementRetainedResources = resources
    }

readyTransaction :: ReplacementTransaction
readyTransaction =
  (newReplacementTransaction "transaction-12345678" "prod" "project" "zone" (DowntimeBudget 900 200 50) oldHost candidateHost "203.0.113.10" fixtureNow)
    { replacementConfirmation = "prod/12345678"
    , replacementState = Ready
    , replacementExpectedDriftToken = "drift"
    , replacementObservedDriftToken = "drift"
    , replacementEvidenceValidUntil = Just (addUTCTime 3600 fixtureNow)
    , replacementIdentitiesMatch = True
    , replacementQuiesceContractComplete = True
    , replacementPredictedStateSeconds = 500
    , replacementPredictedHandoffSeconds = 100
    , replacementPredictedVerificationSeconds = 50
    }

oldHost :: HostIdentity
oldHost = HostIdentity "old" "old-id" "nic0" "External NAT"

candidateHost :: HostIdentity
candidateHost = HostIdentity "candidate" "candidate-id" "nic0" "External NAT"

transferPlan :: StateTransferPlan
transferPlan = StateTransferPlan [StateTransferItem "database" 500 True True] 500 "drift"

validRevalidation :: Revalidation
validRevalidation = Revalidation "drift" True (Just (addUTCTime 3600 fixtureNow)) True

finalEvidence :: FinalStateEvidence
finalEvidence = FinalStateEvidence ["database-final"] 400 True

publicEvidence :: PublicEvidence
publicEvidence = PublicEvidence "public-ok" True True True True True

fixtureNow :: UTCTime
fixtureNow = parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" "2026-09-13T20:00:00Z"

assertBefore :: Text -> Text -> [Text] -> Assertion
assertBefore first second events =
  case (elemIndex first events, elemIndex second events) of
    (Just a, Just b) -> assertBool (T.unpack first <> " must precede " <> T.unpack second) (a < b)
    _ -> assertFailure ("missing ordered events: " <> show events)

assertRight :: (Show a) => Either a b -> IO b
assertRight = either (assertFailure . show) pure

assertLeft :: (Show b) => Either a b -> IO a
assertLeft = either pure (assertFailure . ("expected failure, got " <>) . show)

assertRightCleanup :: Either CleanupError a -> IO a
assertRightCleanup = either (assertFailure . show) pure

assertLeftCleanup :: (Show a) => Either CleanupError a -> IO CleanupError
assertLeftCleanup = either pure (assertFailure . ("expected cleanup failure, got " <>) . show)
