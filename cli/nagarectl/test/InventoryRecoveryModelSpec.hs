-- | EP-173 M1: the recovery invariant model. Real planning, the real driver and
-- recovery policy, and the real Kubernetes adapter run over an in-memory world
-- with an adversary. For every scheduled fault, every stopped transaction must
-- have a supported exit (I1), nothing unreviewed may be accepted or reported
-- converged (I2), and no reviewed operation may write twice (I4).
module InventoryRecoveryModelSpec (inventoryRecoveryModelTests) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (foldM, forM, forM_, (>=>))
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (partition)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapter
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..), scheduledReceiptExpectationFromCronJob)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lifecycle (decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.ScheduledIngest (ScheduledIngestRequest (..), compileScheduledIngestScope)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Model.Fixtures
import Nagare.Test.Model.Run
import Nagare.Test.Model.Search
import Nagare.Test.World.Adversary
import Nagare.Test.World.Kinds (KindAction (..), KindRow, KindStatus (InLine), kindFixture, kindTable, kubernetesKind)
import Nagare.Test.World.Kubernetes
import System.Environment (lookupEnv)
import System.IO (hFlush, hPutStrLn, stderr)
import Test.Tasty
import Test.Tasty.HUnit

inventoryRecoveryModelTests :: TestTree
inventoryRecoveryModelTests =
  testGroup
    "recovery model"
    [ testCase
        ( "fast tier: every fault has an exit across "
            <> show (length explicitScenarios)
            <> " explicit scenarios (every boundary) and "
            <> show (length generatedScenarios)
            <> " generated from the kind table (one placement per fault)"
        )
        (runTier False scenarios singleFaults)
    , testCase "every generated create writes its kind's member" $ do
        let writes scenario = runScenario scenario [] >>= either (assertFailure . T.unpack) (pure . Map.findWithDefault 0 MutateCall . finishedCalls)
        plain <- writes (Scenario "create" [Deploy "v1"] [] True plainShape False)
        forM_ [scenario | scenario <- generatedScenarios, ": create" `T.isSuffixOf` label scenario] $ \scenario ->
          writes scenario >>= assertEqual (T.unpack (label scenario)) (plain + 1)
    , testCase "the new faults take effect: a lost claim needs take-over, a failed Job needs close" $ do
        let exitsUnder scenario fault = do
              clean <- runScenario scenario [] >>= either (assertFailure . T.unpack) pure
              let n = Map.findWithDefault 0 (faultCall fault) (finishedCalls clean)
              runs <- forM [1 .. n] $ \ordinal -> runScenario scenario [(Boundary (faultCall fault) ordinal, fault)]
              pure (concat [concat (finishedExits finished) | Right finished <- runs])
            storeRun = head [scenario | scenario <- explicitScenarios, label scenario == storeScenario]
            jobCreate = head [scenario | scenario <- generatedScenarios, label scenario == "kind (\"batch\",\"job\"): create"]
        exitsUnder storeRun ClaimLost >>= assertBool "no lost claim needed take-over" . elem TakeOver
        exitsUnder jobCreate LandsFailed >>= assertBool "no failed Job needed close" . elem Close
    , testCase "create-scenario fault pairs that had no exit now have one (EP-177, F66)" $ do
        let exits schedule = runScenario (Scenario "create" [Deploy "v1"] [] True plainShape False) schedule >>= either (assertFailure . T.unpack) (pure . finishedExits)
        -- Store faults on both attempts of admission: re-run until it lands.
        exits [(Boundary StoreGetCall 20, GetFailedOnce), (Boundary StoreGetCall 21, GetFailedOnce)] >>= (@?= [])
        exits [(Boundary MutateCall 1, LandsUnready), (Boundary StorePutCall 13, ClaimLost)] >>= (@?= [[CloseTakeOver]])
        -- The landed Service deleted outside Nagare: resume recreates it.
        exits [(Boundary MutateCall 1, LandsUnready), (Boundary ObserveCall 7, Deleted)] >>= (@?= [[Resume, Close]])
        -- F66: an object not stamped as the create's own is at its address.
        forM_ [[(Boundary ObserveCall 6, ForeignObject), (Boundary StorePutCall 12, PutRefused)], [(Boundary ObserveCall 7, Deleted), (Boundary ObserveCall 8, ForeignObject)], [(Boundary ObserveCall 5, ForeignObject), (Boundary StorePutCall 9, ClaimLost)]] $
          exits >=> assertBool "F66: no close" . any (`elem` [Close, CloseTakeOver]) . concat
    , testCase "an unexcused planning refusal of a reviewed step is I1: no supported exit (EP-177; F63's open Deployment half)" $ do
        let deployment = [scenario | scenario <- generatedScenarios, label scenario == "kind (\"apps\",\"deployment\"): update"]
        forM_ deployment $ \scenario ->
          runScenario scenario [(Boundary MutateCall 3, LandsUnready)]
            >>= either (assertBool "not named I1" . T.isInfixOf "violation: I1: planning refused (") (const (assertFailure "F63: the Deployment's corrective update now plans; update this test"))
        length deployment @?= 1
    , testCase "a move that a new fault stopped without progress is re-run; one that no fault stopped is not (EP-177)" $ do
        let service = [scenario | scenario <- generatedScenarios, label scenario == "kind (\"serving.knative.dev\",\"service\"): create"]
            exits scenario schedule = runScenario scenario schedule >>= either (assertFailure . T.unpack) (pure . finishedExits)
        length service @?= 1
        -- Resume stops again when its store write is refused; re-run, it completes.
        forM_ service $ \scenario -> exits scenario [(Boundary MutateCall 1, LostAcknowledgement), (Boundary StorePutCall 18, PutRefused)] >>= (@?= [[Resume]])
        -- No fault fires during the resume of a landed, unready create: it stays a dead end.
        exits (Scenario "create" [Deploy "v1"] [] True plainShape False) [(Boundary MutateCall 1, LandsUnready)] >>= (@?= [[Close]])
    , testCase "every harness-owned placement the self-test skips, the fast tier runs (EP-177)" $
        forM_ scenarios $ \scenario ->
          runScenario scenario [] >>= either (assertFailure . T.unpack) (\finished -> let (_, skipped) = harnessPlacements scenario finished in assertBool (T.unpack (label scenario)) (all (`elem` singleFaults scenario finished) skipped))
    , testCase "harness self-test: every harness-owned fault in every scenario ends in a result or a named violation (EP-177)" $ do
        started <- getMonotonicTime
        outcomes <- fmap concat . forM scenarios $ \scenario ->
          harnessRun scenario [] >>= \case
            Left failure -> pure [Left failure]
            Right finished -> forM (fst (harnessPlacements scenario finished)) (harnessRun scenario)
        ended <- getMonotonicTime
        let violations = [violation | Left violation <- outcomes]
            named violation = any (\i -> ("violation: I" <> T.pack (show i) <> ":") `T.isInfixOf` violation) [1 .. 8 :: Int]
        hPutStrLn stderr ("recovery-model self-test: " <> show (length outcomes) <> " runs in " <> show (round (ended - started) :: Int) <> "s, " <> show (length violations) <> " named violation(s)")
        mapM_ (hPutStrLn stderr . T.unpack) (take 5 violations)
        assertBool (T.unpack (T.unlines (filter (not . named) violations))) (all named violations)
        -- A crash before admission's head write once let the step pass unapplied.
        runScenario (Scenario "create" [Deploy "v1"] [] True plainShape False) [(Boundary StorePutCall 7, CrashBeforeStorePut)]
          >>= either (assertFailure . T.unpack) (\finished -> Map.lookup MutateCall (finishedCalls finished) @?= Just 2)
    , testCase "a snapshot taken at a stop restores the head, journal, world and adversary (EP-179)" $ do
        run <- newRun plainShape [] [(Boundary MutateCall 1, Interrupt)]
        let state = do
              current <- inspectHead run >>= orFail "read head"
              journal <- maybe (pure []) (\value -> inspectJournal run (headSequence value) >>= orFail "read journal") current
              (current,journal,) <$> snapshotRun run
        reviewAndApply run plainShape "v1" "v1" >>= \case
          Right (registry, reviewed, Stopped transaction _) -> do
            atStop@(_, _, snapshot) <- state
            _ <- tryMove run registry reviewed transaction Resume
            state >>= assertBool "the resume changed nothing" . (/= atStop)
            restoreRun run snapshot
            state >>= assertBool "the restored run differs from the stop" . (== atStop)
          _ -> assertFailure "an interrupted create did not stop"
    , testCase "the snapshot search finds what the replay search finds (EP-179; NAGARE_RECOVERY_MODEL_EQUIVALENCE=1)" $ do
        enabled <- lookupEnv "NAGARE_RECOVERY_MODEL_EQUIVALENCE"
        when (enabled == Just "1") . checkTier True scenarios (\scenario finished -> singleFaults scenario finished <> sampledPairs scenario finished) $ \scenario schedule -> do
          snapshot <- runScenarioWith FromSnapshot scenario schedule
          replayed <- runScenarioWith ByReplay scenario schedule
          pure ["strategies disagree under " <> T.pack (show schedule) <> ":\n" <> T.pack (show snapshot) <> "\n" <> T.pack (show replayed) | snapshot /= replayed]
    , testCase "deep tier: every ordered pair of faults has an exit (NAGARE_RECOVERY_MODEL_DEEP=1, shard with NAGARE_RECOVERY_MODEL_SHARD=i/n)" $ do
        deepTier <- lookupEnv "NAGARE_RECOVERY_MODEL_DEEP"
        shard <- lookupEnv "NAGARE_RECOVERY_MODEL_SHARD"
        when (deepTier == Just "1") $ case shardScenarios shard of
          Left reason -> assertFailure reason
          Right selected -> runTier True selected faultPairs
    ]

-- * Scenarios

-- | A sequence of reviews: deploys of one application scope, each naming the
-- image of its Knative Service and release-history ConfigMap, its retirement,
-- and a standalone database with a scheduled receipt ingestion.
data Scenario = Scenario
  { label :: !Text
  , steps :: ![Step]
  , unready :: ![Text]
  -- ^ Images whose revision never becomes Ready (a bad update).
  , historyFollows :: !Bool
  -- ^ Whether the release-history ConfigMap records each image, as an
  -- application's release history does, or stays as first created.
  , shape :: !Shape
  -- ^ The application's other members: a durable volume, a worker.
  , sampled :: !Bool
  -- ^ Generated from the kind table: the fast tier places each fault once.
  }
  deriving stock (Eq, Show)

scenarios :: [Scenario]
scenarios = explicitScenarios <> generatedScenarios

-- | EP-177 (ADR 25): one scenario per in-line kind and action, each adding a
-- member of that kind to the application scope.
generatedScenarios :: [Scenario]
generatedScenarios =
  [ Scenario ("kind " <> T.pack (show selected) <> ": " <> action) steps' [] True plainShape {shapeExtra = Just row} True
  | row <- kindTable
  , row ^. #status == InLine
  , Just selected <- [kubernetesKind row]
  , isJust (kindFixture row)
  , (action, steps') <-
      [("create", [Deploy "v1"])]
        <> [("update", [Deploy "v1", Deploy "v2"]) | KindUpdate `elem` row ^. #actions]
        <> [("retire", [Deploy "v1", Retire]) | KindRetire `elem` row ^. #actions]
  ]

explicitScenarios :: [Scenario]
explicitScenarios =
  map ($ False) $
    [ Scenario "create" [Deploy "v1"] [] True plainShape
    , Scenario "create then good update" [Deploy "v1", Deploy "v2"] [] True plainShape
    , Scenario "create, bad update, corrected update (history unchanged)" [Deploy "v1", Deploy "bad", Deploy "v3"] ["bad"] False plainShape
    , Scenario "create, bad update, corrected update (history follows the release)" [Deploy "v1", Deploy "bad", Deploy "v3"] ["bad"] True plainShape
    , Scenario "create, bad update, corrected update (with a durable volume)" [Deploy "v1", Deploy "bad", Deploy "v3"] ["bad"] True volumeShape
    , Scenario "create with a durable volume, then retire" [Deploy "v1", Retire] [] True volumeShape
    , Scenario "create a database, then ingest a scheduled receipt" [CreateDatabase, IngestReceipt] [] True plainShape
    , Scenario "create a database, then retire it" [CreateDatabase, RetireDatabase] [] True plainShape
    , Scenario "create a database, update its resources, then update it again" [CreateDatabase, UpdateDatabase, CreateDatabase] [] True plainShape
    ]

data Step
  = -- | Review and apply the application at this image.
    Deploy !Text
  | -- | Retire the application scope, retaining its members.
    Retire
  | -- | Review and apply the standalone PostgreSQL database.
    CreateDatabase
  | -- | Plan ingestion of a scheduled receipt as `db backup-receipts` does.
    IngestReceipt
  | -- | Retire the database scope, retaining its members.
    RetireDatabase
  | -- | Review and apply the database with new resource requests, which
    -- rewrites its StatefulSet.
    UpdateDatabase
  deriving stock (Eq, Show)

stepText :: Step -> Text
stepText step = case step of
  Deploy image -> image
  Retire -> "retire"
  CreateDatabase -> "create database"
  IngestReceipt -> "ingest receipt"
  RetireDatabase -> "retire database"
  UpdateDatabase -> "update database"

type Schedule = [(Boundary, Fault)]

-- | Every fault at every boundary of the provider call it is scheduled on.
-- Store faults do not depend on the application's shape, so the fast tier
-- sweeps them on one representative scenario; the deep tier sweeps them all.
singleFaults :: Scenario -> Finished -> [Schedule]
singleFaults scenario finished
  -- A generated scenario places each provider fault once, at the last
  -- boundary of its call: the step under test.
  | sampled scenario =
      [ [(Boundary (faultCall fault) n, fault)]
      | fault <- [minBound .. maxBound]
      , faultCall fault `notElem` [StorePutCall, StoreGetCall]
      , let n = Map.findWithDefault 0 (faultCall fault) (finishedCalls finished)
      , n > 0
      ]
  | otherwise =
      [ [placement]
      | placement@(Boundary call' _, _) <- placements finished
      , call' `notElem` [StorePutCall, StoreGetCall] || label scenario == storeScenario
      ]

storeScenario :: Text
storeScenario = "create then good update"

faultPairs :: Scenario -> Finished -> [Schedule]
faultPairs _ finished =
  [ [first', second']
  | first'@(Boundary call1 n, _) <- placements finished
  , second'@(Boundary call2 m, _) <- placements finished
  , (call1, n) < (call2, m)
  ]

-- | Every 97th pair: stops with several exits, which single faults rarely reach.
sampledPairs :: Scenario -> Finished -> [Schedule]
sampledPairs scenario finished = [schedule | (k, schedule) <- zip [0 :: Int ..] (faultPairs scenario finished), k `mod` 97 == 0]

placements :: Finished -> [(Boundary, Fault)]
placements finished =
  [ (Boundary (faultCall fault) n, fault)
  | fault <- [minBound .. maxBound]
  , n <- [1 .. Map.findWithDefault 0 (faultCall fault) (finishedCalls finished)]
  ]

-- | The deep tier's scenarios for one shard @i/n@ (0-based): every n-th
-- scenario from the i-th, so heavy explicit and light generated scenarios
-- spread across shards. No shard selects them all.
shardScenarios :: Maybe String -> Either String [Scenario]
shardScenarios = \case
  Nothing -> Right scenarios
  Just spec -> case break (== '/') spec of
    (index, '/' : count)
      | [(i, "")] <- reads index
      , [(n, "")] <- reads count
      , n > 0
      , i >= 0
      , i < n ->
          Right [scenario | (k, scenario) <- zip [0 :: Int ..] scenarios, k `mod` n == i]
    _ -> Left ("NAGARE_RECOVERY_MODEL_SHARD must be i/n with 0 <= i < n, not " <> spec)

-- | Replay every scenario under every schedule. With progress, each scenario
-- reports its schedule count, a heartbeat every 500 schedules, and its time
-- and violations on stderr, prefixed @recovery-model:@.
runTier :: Bool -> [Scenario] -> (Scenario -> Finished -> [Schedule]) -> Assertion
runTier progress selected schedulesFor = checkTier progress selected schedulesFor (\scenario schedule -> either pure (const []) <$> runScenario scenario schedule)

-- | Check every schedule of every selected scenario, collecting what each finds.
checkTier :: Bool -> [Scenario] -> (Scenario -> Finished -> [Schedule]) -> (Scenario -> Schedule -> IO [Text]) -> Assertion
checkTier progress selected schedulesFor check = do
  let total = length selected
      report line = when progress (hPutStrLn stderr ("recovery-model: " <> line) >> hFlush stderr)
  violations <- fmap concat . forM (zip [1 :: Int ..] selected) $ \(position, scenario) -> do
    started <- getMonotonicTime
    let named = "[" <> show position <> "/" <> show total <> "] " <> T.unpack (label scenario)
    clean <- runScenario scenario []
    found <- case clean of
      Left violation -> pure ["the fault-free scenario violates the model:\n" <> violation]
      Right finished -> do
        let schedules = schedulesFor scenario finished
            count = length schedules
        report (named <> ": " <> show count <> " schedules")
        fmap concat . forM (zip [1 :: Int ..] schedules) $ \(done, schedule) -> do
          when (done `mod` 500 == 0) (report (named <> ": " <> show done <> "/" <> show count))
          check scenario schedule
    ended <- getMonotonicTime
    report (named <> ": done in " <> show (round (ended - started) :: Int) <> "s, " <> show (length found) <> " violation(s)")
    pure found
  case violations of
    [] -> pure ()
    _ -> assertFailure (T.unpack (T.intercalate "\n\n" (take 400 violations)) <> "\n\n" <> show (length violations) <> " violation(s)")

-- | EP-177 6c: the faults whose handling the harness owns (store faults,
-- crashes, a lost claim, a failed read) at every placement, as those the
-- self-test runs and those it skips because the fast tier ('singleFaults')
-- runs them. Provider faults are placed at every boundary alone by the deep
-- tier (plan 179 M4), so the fast tier places them only at the last boundary
-- of their call.
harnessPlacements :: Scenario -> Finished -> ([Schedule], [Schedule])
harnessPlacements scenario finished =
  partition
    (`notElem` singleFaults scenario finished)
    [[placement] | placement@(_, fault) <- placements finished, fault `elem` [PutRefused, PutLandedUnacknowledged, GetFailedOnce, CrashBeforeStorePut, CrashAfterStorePut, ClaimLost, Interrupt, TransientReadFailure]]

-- | One run, with any exception from the harness itself reported as an
-- unnamed violation (EP-177 6c).
harnessRun :: Scenario -> Schedule -> IO (Either Text Finished)
harnessRun scenario schedule =
  either (\(err :: SomeException) -> Left ("harness error: " <> T.pack (show err) <> " under " <> T.pack (show schedule))) id
    <$> try (runScenario scenario schedule)

-- * One execution

data Finished = Finished
  { finishedCalls :: !(Map.Map Call Int)
  , finishedExits :: ![[Move]]
  -- ^ The exit taken at each stopped review.
  }
  deriving stock (Eq, Show)

-- | An exit move for a stopped transaction.
-- | An exit move for a stopped transaction (ADR 26: resume, or close).
data Move
  = Resume
  | Close
  | -- | Resume with take-over, after establishing the other executor
    -- stopped: the exit when a claim was lost (EP-177).
    TakeOver
  | -- | Close with take-over, after establishing the other executor stopped.
    CloseTakeOver
  deriving stock (Eq, Show)

-- | Which state each probe of the exit search starts from (EP-179): a
-- snapshot of the stop, or, as the reference, a fresh replay of the scenario
-- up to the stop.
data Strategy
  = FromSnapshot
  | ByReplay
  deriving stock (Eq, Show)

runScenario :: Scenario -> Schedule -> IO (Either Text Finished)
runScenario = runScenarioWith FromSnapshot

-- | Run the scenario's reviews in order under the schedule. At a stopped
-- review, search for a supported exit, then continue from the state it
-- reached. 'Left' explains the first violation.
runScenarioWith :: Strategy -> Scenario -> Schedule -> IO (Either Text Finished)
runScenarioWith strategy scenario schedule = do
  driven <- drive scenario schedule (searchStop strategy scenario schedule) =<< newRun (shape scenario) (unready scenario) schedule
  pure $ case driven of
    Ended (Right calls) taken -> liveness (Finished calls taken) taken
    Ended (Left violation) _ -> Left violation
    Halted {} -> Left "internal: a search halted at a stop"
  where
    -- I7 (liveness): persistent status churn alone must never need an exit.
    liveness finished taken
      | null (unready scenario) && all ((== ChurnAlways) . snd) schedule && not (null schedule) && any (not . null) taken =
          Left (describe scenario schedule "(all)" ("I7: under persistent status churn a review needed the exits " <> T.pack (show taken)) [])
      | otherwise = Right finished

-- | The exits taken so far, one path per stopped review.
type Taken = [[Move]]

data Driven
  = -- | The scenario finished (the provider call counts) or violated an
    -- invariant, after taking these exits.
    Ended !(Either Text (Map.Map Call Int)) !Taken
  | -- | A replay reached the stop it was asked to reach: its run, and the
    -- registry bound to that run's world.
    Halted !Run !AdapterRegistry

-- | What a stopped review does next.
data AtStop
  = -- | Continue from the run an exit path reached.
    Continue !Run ![Move]
  | Violated !Text
  | Halt !Run !AdapterRegistry

-- | At a stop: the exits taken before it, the run, the review's image, why it
-- stopped, and the stopped transaction.
type OnStop = Taken -> Run -> Text -> Text -> AdapterRegistry -> ReviewedPlan -> TransactionId -> IO AtStop

-- | Execute the scenario's steps on the run, handing each stop to @onStop@.
drive :: Scenario -> Schedule -> OnStop -> Run -> IO Driven
drive scenario schedule onStop start = go start "v1" (steps scenario) []
  where
    -- The image the accepted application declares after a step.
    next previous step = case step of
      Deploy image -> image
      _ -> previous
    ended taken result = pure (Ended result taken)
    go run _ [] taken = do
      adversary <- readIORef (runAdversary run)
      consistent <- storeConsistent run
      ended taken $ case consistent of
        Left violation -> Left (describe scenario schedule "(end)" violation [])
        Right () -> Right (counts adversary)
    go run previous (IngestReceipt : rest) taken = do
      checked <- ingestReceipt run (null schedule)
      case checked of
        Left violation -> ended taken (Left (describe scenario schedule (stepText IngestReceipt) violation []))
        Right () -> go run previous rest taken
    go run previous (step : rest) taken = attempt False run previous step rest taken
    attempt replanned run previous step rest taken = do
      let historyImage image' = if historyFollows scenario then image' else "v1"
          image = stepText step
      outcome <- case step of
        Retire -> retireAndApply run (shape scenario) previous (historyImage previous)
        CreateDatabase -> databaseAndApply run (databaseScope, databaseNative) (shape scenario) previous (historyImage previous)
        UpdateDatabase -> databaseAndApply run resizedDatabase (shape scenario) previous (historyImage previous)
        RetireDatabase -> scopeRetireAndApply run databaseScopeId (shape scenario) previous (historyImage previous)
        _ -> reviewAndApply run (shape scenario) image (historyImage image)
      deletedData <- either (deletedDataRefusal run) (const (pure False)) outcome
      foreignBlocked <- either (foreignObjectRefusal run) (const (pure False)) outcome
      absentScope <- either (absentScopeRetirement run) (const (pure False)) outcome
      case outcome of
        Left refusal
          | foreignBlocked || deletedData || absentScope -> do
              -- An unowned object at a planned address refuses planning, and a
              -- durable member deleted outside review refuses until its data is
              -- recovered or its collection reviewed. There is no transaction to
              -- wedge, so the scenario ends here.
              adversary <- readIORef (runAdversary run)
              ended taken (Right (counts adversary))
          -- ADR 26: a reviewed step refused at planning has no supported exit.
          | otherwise -> ended taken (Left (describe scenario schedule image ("I1: planning refused (" <> refusal <> ") with no supported exit") []))
        Right (registry, reviewed, applied) -> do
          checked <- checkInvariants run
          case (checked, applied) of
            (Left violation, _) -> ended taken (Left (describe scenario schedule image violation []))
            (Right (), Done) -> go run (next previous step) rest taken
            (Right (), Refused why)
              -- A retained member deleted outside review is refused: its data
              -- needs reviewed recovery or collection, as at planning. A
              -- replaced member retires with its record retained (ADR 27, N1).
              -- A member replaced after its review is refused at admission;
              -- the exit is a fresh review, which names the replacement (N1).
              | not replanned && any ((== Replaced) . snd) schedule && "retention-observation" `T.isInfixOf` why ->
                  attempt True run previous step rest taken
              | any ((== Deleted) . snd) schedule && "retention-observation" `T.isInfixOf` why -> do
                  adversary <- readIORef (runAdversary run)
                  ended taken (Right (counts adversary))
              | otherwise -> ended taken (Left (describe scenario schedule image ("admission refused: " <> why) []))
            (Right (), Stopped transaction why) ->
              onStop taken run image why registry reviewed transaction >>= \case
                Continue reached path -> go reached (next previous step) rest (taken <> [path])
                Violated violation -> ended taken (Left violation)
                Halt reached registry' -> pure (Halted reached registry')

-- | Settle the stop (I8), then search its exits. Each probe starts from a
-- snapshot of the stop or of the probe it extends; the reference replays the
-- scenario up to the stop and the whole path instead.
searchStop :: Strategy -> Scenario -> Schedule -> OnStop
searchStop strategy scenario schedule taken run image why registry reviewed transaction = do
  world <- readIORef (runWorld run)
  let operations =
        [ operationIdText (plannedOperationId planned) <> " " <> T.pack (show (plannedAction planned)) <> " " <> T.intercalate "," (map resourceIdText (NE.toList (plannedResources planned)))
        | entry <- reviewOperations (reviewedDocument reviewed)
        , let planned = reviewPlannedOperation entry
        ]
      context =
        "; operations: "
          <> T.intercalate "; " operations
          <> (if Set.null (deletedOutOfBand world) then "" else "; deleted outside review: " <> T.intercalate "," (map resourceIdText (Set.toList (deletedOutOfBand world))))
      judge probed path outcome = do
        afterProbe <- checkInvariants probed
        moves <- candidateMoves probed reviewed transaction
        pure $ case (afterProbe, outcome) of
          (Left violation, _) -> ProbeViolated (describe scenario schedule image (violation <> " (on exit path " <> T.pack (show path) <> ")") [])
          (Right (), MoveIdle) -> ProbeIdle
          (Right (), MoveProgressed) -> ProbeProgressed moves
          (Right (), MoveRefused reason) -> ProbeRefused reason
      move' probed = tryMove probed registry reviewed transaction
  gaps <- settlementGaps run registry reviewed transaction
  case gaps of
    gap : _ -> pure (Violated (describe scenario schedule image ("I8: " <> gap <> context) []))
    [] -> do
      initial <- candidateMoves run reviewed transaction
      found <- case strategy of
        FromSnapshot -> do
          let probe start path move = do
                restoreRun run start
                outcome <- move' run move
                reached <- snapshotRun run
                (,reached) <$> judge run path outcome
          (run <$) <$> (searchExit probe `flip` initial =<< snapshotRun run)
        ByReplay -> do
          let probe _ path _ = do
                replayed <- newRun (shape scenario) (unready scenario) schedule >>= drive scenario schedule (replayExits taken)
                case replayed of
                  Halted fresh registry' -> do
                    outcomes <- mapM (tryMove fresh registry' reviewed transaction) path
                    (,fresh) <$> judge fresh path (case reverse outcomes of final : _ -> final; [] -> MoveRefused "empty probe")
                  _ -> pure (ProbeViolated "internal: a replay did not reach the stop", run)
          searchExit probe run initial
      pure $ case found of
        ExitFound path reached -> Continue reached path
        ExitViolated violation -> Violated violation
        NoExit tried -> Violated (describe scenario schedule image ("I1: stopped (" <> why <> context <> ") with no supported exit") tried)
  where
    -- The reference: take the known exits, and halt at the next stop.
    replayExits known taken' replayed image' _ registry' reviewed' transaction' = case drop (length taken') known of
      [] -> pure (Halt replayed registry')
      path : _ -> do
        outcomes <- mapM (tryMove replayed registry' reviewed' transaction') path
        afterExit <- checkInvariants replayed
        pure $ case (afterExit, reverse outcomes) of
          (Left violation, _) -> Violated (describe scenario schedule image' (violation <> " (after exit " <> T.pack (show path) <> ")") [])
          (Right (), MoveIdle : _) -> Continue replayed path
          _ -> Violated "internal: a replayed exit did not reach an idle head"

data Applied
  = Done
  | -- | Admission refused the review; nothing ran.
    Refused !Text
  | Stopped !TransactionId !Text

-- | Plan, review and apply one image. Planning and admission are operator
-- commands, re-run while new faults fire; an apply that stopped once its
-- transaction started is ended by an exit, not re-run.
reviewAndApply :: Run -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
reviewAndApply run volume image historyImage = do
  planned <- asOperator run (planReview run volume image historyImage)
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      forM_ (Map.elems (reviewDesiredRevisions (reviewedDocument reviewed))) $ \revision ->
        modifyIORef' (runBound run) (Map.insert (revisionDigest revision) (boundDigests volume image historyImage))
          >> modifyIORef' (runImages run) (Map.insert (revisionDigest revision) (volume, image, historyImage))
      startTransaction run
      applied <- applyAsOperator run registry reviewed
      Right . (registry,reviewed,) <$> classify run applied

-- | Retire the application scope, retaining its members, as `inventory
-- retire` plans it.
retireAndApply :: Run -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
retireAndApply run volume image historyImage = do
  planned <- asOperator run (planRetirement run volume image historyImage)
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      startTransaction run
      applied <- applyAsOperator run registry reviewed
      Right . (registry,reviewed,) <$> classify run applied

-- | Retire one scope, retaining its members, as `inventory retire` plans it.
scopeRetireAndApply :: Run -> ScopeId -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
scopeRetireAndApply run scope volume image historyImage = do
  planned <- asOperator run (\store -> registryFor run volume image historyImage >>= \registry -> planWith store registry (RetireScope scope RetainResources) decideRetirement)
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      startTransaction run
      applied <- applyAsOperator run registry reviewed
      Right . (registry,reviewed,) <$> classify run applied

planRetirement :: Run -> Shape -> Text -> Text -> InventoryStore -> IO (Either Text (AdapterRegistry, ReviewedPlan))
planRetirement run volume image historyImage store =
  registryFor run volume image historyImage >>= \registry -> planWith store registry (RetireScope appScope RetainResources) decideRetirement

-- | Review and apply the standalone database scope at one compiled revision.
databaseAndApply :: Run -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString)) -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
databaseAndApply run (scope, native) volume image historyImage = do
  -- As production builds it: the reviewed revision's native specs.
  writeIORef (runDatabase run) native
  planned <- asOperator run (\store -> registryFor run volume image historyImage >>= \registry -> planWith store registry (ReplaceScope scope) (\_ _ _ -> Right noLifecycleDecisions))
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      forM_ (Map.lookup databaseScopeId (reviewDesiredRevisions (reviewedDocument reviewed))) $ \revision ->
        modifyIORef' (runBound run) (Map.insert (revisionDigest revision) (Map.map (contentDigest . snd) native))
      startTransaction run
      applied <- applyAsOperator run registry reviewed
      Right . (registry,reviewed,) <$> classify run applied

-- | I3: plan ingestion of a scheduled receipt from the live source, as `db
-- backup-receipts` plans it. A receipt whose source StatefulSet or PVC was
-- created outside review never compiles for ingestion. In a fault-free run the
-- receipt must compile, so the clause is never vacuous. A failed store read is
-- re-run, as an operator re-runs the command.
ingestReceipt :: Run -> Bool -> IO (Either Text ())
ingestReceipt run clean = do
  loaded <- asOperator run $ \store -> do
    history <- loadInventoryHistory store >>= orTrouble "load history"
    case Map.lookup databaseScopeId (historyAccepted history) of
      Nothing -> pure (Right Nothing)
      Just (revision, accepted) -> do
        let acceptedInventory = ok (composeSnapshot (ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision', declared) -> (revisionGeneration revision', declared)) (historyAccepted history)) (historyReservations history))))
        -- As the command does: the accepted members' native bytes come from
        -- the store's review evidence, not from the compiler.
        native <- Status.loadAcceptedNativeSelected (Set.fromList [statefulId, pvcId, cronId, signingId]) store history acceptedInventory >>= orTrouble "load accepted native"
        pure (Right (Just (history, revision, accepted, fst native)))
  case loaded of
    Left refusal -> pure (refusedWhen refusal)
    Right Nothing -> pure (refusedWhen "the database is not accepted")
    Right (Just (history, revision, accepted, native)) -> do
      registry <- registryFor run plainShape "v1" "v1"
      observed <- observeWithRegistry registry (Map.singleton KubernetesExecutor [statefulId, pvcId, cronId, signingId])
      world <- readIORef (runWorld run)
      let live resource = case Map.lookup resource . observationMap =<< either (const Nothing) Just observed of
            Just (ObservedPresent physical) -> Just physical
            _ -> Nothing
      pure $ case traverse live [statefulId, pvcId, cronId, signingId] of
        Just [statefulUid, pvcUid, cronUid, signingUid] ->
          let request expectation =
                ScheduledIngestRequest
                  { ingestDatabase = "pg"
                  , ingestNamespace = "personal"
                  , ingestBackupId = "job-1"
                  , ingestSourceRevision = revision
                  , ingestStatefulUid = statefulUid
                  , ingestPvcUid = pvcUid
                  , ingestScheduleUid = cronUid
                  , ingestSigningUid = signingUid
                  , ingestEvidence =
                      ScheduledReceiptEvidence
                        { scheduledReceipt =
                            ScheduledBackupReceipt
                              (ok (mkPhysicalIdentity "job-1"))
                              (scheduledObjectPrefix expectation <> "job-1." <> scheduledFormat expectation)
                              (T.replicate 64 "0")
                              (scheduledPolicyRevision expectation)
                              Nothing
                        , scheduledObjectVersion = "1"
                        , scheduledReceiptVersion = "1"
                        , scheduledObjectLength = 1
                        , scheduledReceiptLength = 1
                        , scheduledReceiptDigest = contentDigest "receipt"
                        }
                  , ingestBackend = databaseBackend
                  , ingestSource = SourceLocation "model" "ingest"
                  , ingestAcceptedIncarnations = recorded
                  }
              recorded = headIncarnations (historyHead history)
              -- ADR 27 (F60): the record is the identity the provider returned
              -- for Nagare's own write, so every replacement must refuse.
              replaced = [physical | physical <- [statefulUid, pvcUid], Set.member physical (replacedUids world)]
              compiled =
                maybe (Left "the accepted CronJob lacks native evidence") Right (Map.lookup cronId native)
                  >>= \(_, cronBytes) ->
                    first (T.pack . show) (scheduledReceiptExpectationFromCronJob databaseBackend "personal" "pg" statefulUid pvcUid cronBytes)
                      >>= \expectation -> first (T.pack . show) (compileScheduledIngestScope (request expectation) accepted native)
           in case compiled of
                Right _
                  | not (null replaced) ->
                      Left ("I3: a scheduled receipt from " <> T.intercalate ", " (map physicalIdentityText replaced) <> ", created outside review, compiled for ingestion")
                Left refusal | clean -> Left ("I3: the fault-free scheduled receipt was refused: " <> refusal)
                _ -> Right ()
        _ -> refusedWhen "the receipt source is not observed present"
  where
    refusedWhen why
      | clean = Left ("I3: fault-free ingestion could not be planned: " <> why)
      | otherwise = Right ()

-- | Planning refuses `durable-resource-missing` naming only members the world
-- deleted outside review: the expected refusal, not a wedge.
deletedDataRefusal :: Run -> Text -> IO Bool
deletedDataRefusal run refusal = do
  world <- readIORef (runWorld run)
  let named = [T.takeWhile (/= '"') chunk | chunk <- drop 1 (T.splitOn "ResourceId \"" refusal)]
      deleted = Set.map resourceIdText (deletedOutOfBand world)
  pure ("durable-resource-missing" `T.isInfixOf` refusal && not (null named) && all (`Set.member` deleted) named)

-- | EP-177: a planning refusal is excused by a 'ForeignObject' fault only when
-- it names a resource whose address that fault filled with an unowned object.
foreignObjectRefusal :: Run -> Text -> IO Bool
foreignObjectRefusal run refusal = do
  world <- readIORef (runWorld run)
  let named = [T.takeWhile (/= '"') chunk | chunk <- drop 1 (T.splitOn "ResourceId \"" refusal)]
      foreign' = Set.fromList [resourceIdText resource | (resource, KubeObject {owner = Nothing}) <- Map.toList (objects world)]
  pure (not (null named) && all (`Set.member` foreign') named)

-- | A retirement of a scope that was never accepted (its create was closed
-- and reverted) is correctly refused; there is nothing to retire.
absentScopeRetirement :: Run -> Text -> IO Bool
absentScopeRetirement run refusal = do
  current <- inspectHead run >>= orFail "read head"
  let accepted = maybe Map.empty headAccepted current
      named = [scope | scope <- [appScope, databaseScopeId], T.pack (show scope) `T.isInfixOf` refusal]
  pure ("unknown-retirement" `T.isInfixOf` refusal && not (null named) && all (`Map.notMember` accepted) named)

-- | I4 is per transaction: a later review may write the same deterministic
-- operation again as new reviewed intent.
startTransaction :: Run -> IO ()
startTransaction run = modifyIORef' (runWorld run) (\world -> world {writes = Map.empty})

-- | Apply a review as an operator does. Admission refused (the head is idle),
-- or a crash before any head write (the head is unchanged), is a command an
-- operator re-runs; otherwise the outcome is a stop, which an exit ends, or a
-- transaction that finished before the crash.
applyAsOperator :: Run -> AdapterRegistry -> ReviewedPlan -> IO (Either Interrupted (Either (NonEmpty AdmissionError) TransactionResult))
applyAsOperator run registry reviewed = do
  outcome <- operatorAction run $ \store -> do
    started <- fmap headGeneration <$> (inspectHead run >>= orFail "read head")
    attempt <- try (applyReviewed store registry reviewed)
    ended <- fmap headGeneration <$> (inspectHead run >>= orFail "read head")
    idle <- headIdle run
    case attempt of
      Left Interrupted | ended == started -> throwIO Interrupted
      Right (Left refusal) | idle -> pure (Left refusal)
      _ -> pure (Right attempt)
  pure $ case outcome of
    Right attempt -> attempt
    Left (CommandRefused refusal) -> Right (Left refusal)
    Left _ -> Left Interrupted

-- | Plan or read as an operator does, re-run while new faults fire.
asOperator :: Run -> (InventoryStore -> IO (Either Text a)) -> IO (Either Text a)
asOperator run command = first failureText <$> operatorAction run command
  where
    failureText = \case
      CommandRefused refusal -> refusal
      CommandCrashed -> "interrupted"
      CommandTrouble trouble -> trouble

headIdle :: Run -> IO Bool
headIdle run = maybe True (isNothing . headActiveTransaction) <$> (inspectHead run >>= orFail "read head")

planReview :: Run -> Shape -> Text -> Text -> InventoryStore -> IO (Either Text (AdapterRegistry, ReviewedPlan))
planReview run volume image historyImage store =
  registryFor run volume image historyImage >>= \registry -> planWith store registry (ReplaceScope (scopeFor volume image historyImage)) (\_ _ _ -> Right noLifecycleDecisions)

planWith ::
  InventoryStore ->
  AdapterRegistry ->
  ScopeChange ->
  (CompositionCandidate -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  IO (Either Text (AdapterRegistry, ReviewedPlan))
planWith store registry change decide = do
  loaded <- loadInventoryHistory store >>= orTrouble "load history"
  let accepted = historyAccepted loaded
      snapshot = ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) accepted) (historyReservations loaded))
  case composeInventory snapshot (change :| []) of
    Left err -> pure (Left (T.pack (show err)))
    Right candidate -> do
      history <- loadInventoryPlanningHistory store candidate >>= orTrouble "load planning history"
      let required = Set.toList (requiredResources (observationRequirements candidate history))
      observed <- observeWithRegistry registry (Map.singleton KubernetesExecutor required)
      case observed >>= \observations -> first (T.pack . show) (decide candidate history observations >>= \decisions -> planChanges candidate decisions history observations) of
        Left err -> pure (Left err)
        Right proposal -> do
          before <- readStoreSnapshot store >>= orTrouble "read snapshot"
          prepared <- prepareReview registry before proposal
          case prepared of
            Left err -> pure (Left (T.pack (show err)))
            Right bundle -> do
              _ <- publishReview store bundle >>= orTrouble "publish review"
              published <- readStoreSnapshot store >>= orTrouble "read snapshot"
              pure (first (T.pack . show . NE.toList) ((registry,) <$> verifyReview published bundle))

classify :: (Show e) => Run -> Either Interrupted (Either e TransactionResult) -> IO Applied
classify run applied = case applied of
  Left Interrupted -> stoppedFromHead run "executor interrupted"
  Right (Left err) -> do
    applied' <- stoppedFromHead run ("driver error: " <> T.pack (show err))
    -- An admission refusal leaves no transaction; it is not a completed step.
    pure $ case applied' of
      Done -> Refused (T.pack (show err))
      stopped -> stopped
  Right (Right result) -> case result of
    Converged _ -> pure Done
    Closed _ -> pure Done
    StoppedAmbiguous transaction _ -> pure (Stopped transaction "ambiguous")
    StoppedFailed transaction _ _ -> pure (Stopped transaction "failed")
    PausedAtBarrier transaction _ -> pure (Stopped transaction "paused at barrier")

stoppedFromHead :: Run -> Text -> IO Applied
stoppedFromHead run why = do
  current <- inspectHead run >>= orFail "read head"
  case current >>= headActiveTransaction of
    Just active -> pure (Stopped (ok (mkTransactionId active)) why)
    Nothing -> pure Done

data MoveOutcome
  = MoveIdle
  | MoveProgressed
  | MoveRefused !Text

-- | Moves are tried in place: refused moves leave the head unchanged, so trying
-- the next one from the same state is sound. A progressing move is kept. A
-- move is an operator's command, re-run while new faults fire; an attempt that
-- returns without progress has failed, so a fault that stopped it again (a
-- refused store write, a failed read) is re-run, and one no fault stopped is a
-- dead end.
tryMove :: Run -> AdapterRegistry -> ReviewedPlan -> TransactionId -> Move -> IO MoveOutcome
tryMove run registry reviewed transaction move = do
  modifyIORef' (runWorld run) (\world -> world {quiet = True})
  before <- progressSignature run transaction
  result <- operatorAction run $ \store -> do
    started <- progressSignature run transaction
    moved <-
      first (T.pack . show) <$> case move of
        Resume -> fmap (const ()) <$> resumeTransaction store registry transaction
        TakeOver -> fmap (const ()) <$> resumeTransactionWithTakeover store registry transaction True
        Close -> close store False
        CloseTakeOver -> close store True
    ended <- progressSignature run transaction
    active <- not <$> headIdle run
    pure (if moved == Right () && active && ended == started then Left noProgress else moved)
  later <- progressSignature run transaction
  idle <- headIdle run
  modifyIORef' (runWorld run) (\world -> world {quiet = False})
  pure $ case result of
    Left CommandCrashed -> MoveRefused "interrupted"
    _ | idle -> MoveIdle
    _ | later /= before, either (== CommandRefused noProgress) (const True) result -> MoveProgressed
    Left (CommandRefused err) -> MoveRefused err
    Left (CommandTrouble err) -> MoveRefused err
    Right () -> MoveRefused noProgress
  where
    noProgress = "no progress: the transaction's state is unchanged"
    review = contentDigest (encodeReviewDocument (reviewedDocument reviewed))
    close store takeOver = fmap (const ()) <$> closeTransaction store registry (CloseInput transaction review takeOver Nothing)

-- | What counts as progress: the active transaction, the accepted and converged
-- revisions, each operation's latest state, and each live object's identity,
-- content and readiness (a resume that recreates a deleted object stops again
-- in the same state). A resume that changes none only appends journal events.
progressSignature :: Run -> TransactionId -> IO (Maybe Text, Map.Map ScopeId ScopeRevision, Map.Map ScopeId ScopeRevision, Map.Map OperationId Text, Map.Map ResourceId (PhysicalIdentity, ContentDigest, Readiness))
progressSignature run transaction = do
  current <- inspectHead run >>= orFail "read head"
  world <- readIORef (runWorld run)
  raw <- maybe (pure []) (\value -> inspectJournal run (headSequence value) >>= orFail "read journal") current
  let events = [event | Right event <- map decodeJournalEvent raw, eventTransaction event == transaction]
      latest = Map.fromList [(operation, T.pack (takeWhile (/= ' ') (show (eventState event)))) | event <- events, Just operation <- [eventOperation event]]
  pure
    ( current >>= headActiveTransaction
    , maybe Map.empty headAccepted current
    , maybe Map.empty headConverged current
    , latest
    , Map.map (\object' -> (uid object', nativeDigest object', readiness object')) (objects world)
    )

-- | I8 (ADR 26, obligation O1): every operation of a stopped transaction that
-- has intent and no completion settles to a proof class, unless resume can
-- still progress it. Settlement is read in inspection mode, so it fires no
-- fault.
settlementGaps :: Run -> AdapterRegistry -> ReviewedPlan -> TransactionId -> IO [Text]
settlementGaps run registry reviewed transaction = do
  current <- inspectHead run >>= orFail "read head"
  raw <- maybe (pure []) (\value -> inspectJournal run (headSequence value) >>= orFail "read journal") current
  let events = [event | Right event <- map decodeJournalEvent raw, eventTransaction event == transaction]
      latest = Map.fromList [(operation, eventState event) | event <- events, Just operation <- [eventOperation event]]
      unsettled = [operation | (operation, state) <- Map.toList latest, hasIntentOnly state]
  modifyIORef' (runWorld run) (\world -> world {inspecting = True})
  settled <- forM unsettled $ \operation -> (operation,) <$> settleReviewedOperation registry reviewed operation
  modifyIORef' (runWorld run) (\world -> world {inspecting = False})
  pure
    [ operationIdText operation <> " settles unknown: " <> reason <> " (resolved by " <> resolvesBy <> ")"
    | (operation, result) <- settled
    , (reason, resolvesBy) <- case result of
        Left err -> [(err, "a readable review")]
        Right (SettledUnknown reason resolvesBy) | resolvesBy /= "inventory resume" -> [(reason, resolvesBy)]
        Right _ -> []
    ]
  where
    hasIntentOnly state = case state of
      IntentRecorded -> True
      Ambiguous -> True
      Failed (PartialOrUnknown _) -> True
      _ -> False

-- | ADR 26: a stopped transaction's supported exits are resume and close,
-- each with take-over after a lost claim.
candidateMoves :: Run -> ReviewedPlan -> TransactionId -> IO [Move]
candidateMoves _ _ _ = pure [Resume, Close, TakeOver, CloseTakeOver]

-- * Invariants I2, I4 and I5

-- | I5: after the scenario, the head reads back idle and every published
-- journal event up to it decodes and validates as one chain.
storeConsistent :: Run -> IO (Either Text ())
storeConsistent run = do
  current <- inspectHead run
  case current of
    Left err -> pure (Left ("I5: the head cannot be read: " <> T.pack (show err)))
    Right Nothing -> pure (Left "I5: the head is missing")
    Right (Just value)
      | isJust (headActiveTransaction value) -> pure (Left "I5: the scenario ended with an active transaction")
      | otherwise -> do
          raw <- inspectJournal run (headSequence value)
          pure $ case raw >>= first (StoreInvalidObject "journal") . traverse decodeJournalEvent of
            Left err -> Left ("I5: the published journal is unreadable: " <> T.pack (show err))
            Right events -> first (\err -> "I5: the journal chain is invalid: " <> err) (() <$ validateJournal events)

checkInvariants :: Run -> IO (Either Text ())
checkInvariants run = do
  current <- inspectHead run >>= orFail "read head"
  world <- readIORef (runWorld run)
  bound <- readIORef (runBound run)
  previous <- readIORef (runConverged run)
  let now = maybe Map.empty headConverged current
  writeIORef (runConverged run) now
  let twice = Map.keys (Map.filter (> 1) (effectiveWrites world))
      newlyConverged = [revision | (scopeId', revision) <- Map.toList now, Map.lookup scopeId' previous /= Just revision]
      unproven =
        [ resource
        | revision <- newlyConverged
        , Just members <- [Map.lookup (revisionDigest revision) bound]
        , (resource, digest) <- Map.toList members
        , case Map.lookup resource (objects world) of
            Just object' -> nativeDigest object' /= digest || readiness object' /= Ready
            -- Deleted outside review after its verification; status, not
            -- convergence, reports that.
            Nothing -> Set.notMember resource (deletedOutOfBand world)
        ]
  stale <- convergedStaleIncarnations run
  known <- Map.union (maybe Map.empty headIncarnations current) <$> readIORef (runIncarnations run)
  writeIORef (runIncarnations run) known
  let laundered =
        [ resource
        | (resource, retained) <- Map.toList (maybe Map.empty headRetained current)
        , Just recorded <- [Map.lookup resource known]
        , retainedPhysical retained /= recorded
        ]
  pure $ case (twice, unproven, stale, laundered) of
    (operation : _, _, _, _) -> Left ("I4: operation " <> operationIdText operation <> " wrote twice")
    (_, resource : _, _, _) -> Left ("I2: scope reported converged while " <> resourceIdText resource <> " is not the reviewed Ready object")
    (_, _, resource : _, _) -> Left ("I3: status reports " <> resourceIdText resource <> " converged although its live UID differs from the recorded incarnation")
    (_, _, _, resource : _) -> Left ("I3: retirement retained " <> resourceIdText resource <> " under a UID other than its accepted incarnation")
    _ -> Right ()

-- | I3: status, computed as `inventory status` computes it, never reports a
-- member converged when its live UID differs from the recorded incarnation.
convergedStaleIncarnations :: Run -> IO [ResourceId]
convergedStaleIncarnations run = do
  history <- inspectHistory run >>= orFail "load history"
  images <- readIORef (runImages run)
  let appImages = Map.lookup appScope (historyAccepted history) >>= \(revision, _) -> Map.lookup (revisionDigest revision) images
  case (if Map.null (historyAccepted history) then Nothing else Just (fromMaybe (plainShape, "v1", "v1") appImages)) of
    Nothing -> pure []
    Just (volume, image, historyImage) -> do
      let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
          inventory = ok (composeSnapshot (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))))
          members = [resource ^. #identity | Managed resource <- inventoryDeclarations inventory]
      incarnations <- inspectIncarnations run (historyHead history) >>= orFail "status incarnations"
      modifyIORef' (runWorld run) (\world -> world {inspecting = True})
      registry <- registryFor run volume image historyImage
      observed <- observeWithRegistry registry (Map.singleton KubernetesExecutor members)
      modifyIORef' (runWorld run) (\world -> world {inspecting = False})
      world <- readIORef (runWorld run)
      pure $ case observed of
        Left _ -> []
        Right observations ->
          [ Status.findingResource finding
          | finding <- Status.classifyDriftWith incarnations inventory observations
          , Status.findingCategory finding == Status.Converged
          , Just recorded <- [Map.lookup (Status.findingResource finding) incarnations]
          , Just object' <- [Map.lookup (Status.findingResource finding) (objects world)]
          , uid object' /= recorded
          ]

describe :: Scenario -> Schedule -> Text -> Text -> [Text] -> Text
describe scenario schedule image violation tried =
  T.unlines $
    [ "scenario: " <> label scenario
    , "faults: " <> T.pack (show schedule)
    , "review: " <> image
    , "violation: " <> violation
    ]
      <> ["exits tried:" | not (null tried)]
      <> map ("  " <>) (take 40 tried)

-- | As production builds it for one review: the reviewed members' specs.
registryFor :: Run -> Shape -> Text -> Text -> IO AdapterRegistry
registryFor run volume image historyImage = do
  database <- readIORef (runDatabase run)
  pure (ok (mkAdapterRegistry [worldKubernetesAdapter (fixtureBinding ^. #identity) (boundMembers volume image historyImage <> database) (runWorld run) (runAdversary run)]))


