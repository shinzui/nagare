-- | EP-173 M1: the recovery invariant model. Real planning, the real driver and
-- recovery policy, and the real Kubernetes adapter run over an in-memory world
-- with an adversary. For every scheduled fault, every stopped transaction must
-- have a supported exit (I1), nothing unreviewed may be accepted or reported
-- converged (I2), and no reviewed operation may write twice (I4).
module InventoryRecoveryModelSpec (inventoryRecoveryModelTests) where

import Control.Exception (Exception, throwIO, try)
import Control.Monad (foldM, forM, forM_)
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import InventoryObjectOpsSpec (fakeObjectOps)
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
import Nagare.Test.World.Adversary
import Nagare.Test.World.Kubernetes
import Nagare.Test.World.Store (faultingObjectOps)
import System.Environment (lookupEnv)
import Test.Tasty
import Test.Tasty.HUnit

inventoryRecoveryModelTests :: TestTree
inventoryRecoveryModelTests =
  testGroup
    "recovery model"
    [ testCase "fast tier: every single fault at every boundary has an exit" (runTier singleFaults)
    , testCase "deep tier: every ordered pair of faults has an exit (NAGARE_RECOVERY_MODEL_DEEP=1)" $ do
        deepTier <- lookupEnv "NAGARE_RECOVERY_MODEL_DEEP"
        when (deepTier == Just "1") (runTier faultPairs)
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
  }
  deriving stock (Eq, Show)

scenarios :: [Scenario]
scenarios =
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

-- | The application's members besides its Service and release history.
data Shape = Shape
  { shapeVolume :: !Bool
  , shapeWorker :: !Bool
  -- ^ A worker Deployment whose image follows the release; in a worker
  -- scenario only the worker's revision of an unready image fails readiness.
  }
  deriving stock (Eq, Show)

plainShape, volumeShape, workerShape :: Shape
plainShape = Shape False False
volumeShape = Shape True False
workerShape = Shape False True

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
singleFaults scenario finished =
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

placements :: Finished -> [(Boundary, Fault)]
placements finished =
  [ (Boundary (faultCall fault) n, fault)
  | fault <- [minBound .. maxBound]
  , n <- [1 .. Map.findWithDefault 0 (faultCall fault) (finishedCalls finished)]
  ]

runTier :: (Scenario -> Finished -> [Schedule]) -> Assertion
runTier schedulesFor = do
  violations <- fmap concat . forM scenarios $ \scenario -> do
    clean <- runScenario scenario []
    case clean of
      Left violation -> pure ["the fault-free scenario violates the model:\n" <> violation]
      Right finished ->
        fmap concat . forM (schedulesFor scenario finished) $ \schedule ->
          either (\violation -> [violation]) (const []) <$> runScenario scenario schedule
  case violations of
    [] -> pure ()
    _ -> assertFailure (T.unpack (T.intercalate "\n\n" (take 400 violations)) <> "\n\n" <> show (length violations) <> " violation(s)")

-- * One execution

data Finished = Finished
  { finishedCalls :: !(Map.Map Call Int)
  }
  deriving stock (Eq, Show)

-- | An exit move for a stopped transaction.
-- | An exit move for a stopped transaction (ADR 26: resume, or close).
data Move
  = Resume
  | Close
  deriving stock (Eq, Show)

-- | Run the scenario's reviews in order under the schedule. After a stopped
-- review, search for a supported exit by replaying the run so far along every
-- candidate path, then continue from the found exit. 'Left' explains the first
-- violation.
runScenario :: Scenario -> Schedule -> IO (Either Text Finished)
runScenario scenario schedule = loop []
  where
    -- I7 (liveness): persistent status churn alone must never need an exit.
    liveness finished taken
      | null (unready scenario) && all ((== ChurnAlways) . snd) schedule && not (null schedule) && any (not . null) taken =
          Left (describe scenario schedule "(all)" ("I7: under persistent status churn a review needed the exits " <> T.pack (show taken)) [])
      | otherwise = Right finished
    loop taken = do
      result <- replay scenario schedule taken []
      case result of
        Replayed (Left violation) -> pure (Left violation)
        Replayed (Right calls) -> pure (liveness (Finished calls) taken)
        AtStop image why moves -> do
          search <- searchExit scenario schedule taken moves
          case search of
            ExitFound path -> loop (taken <> [path])
            ExitViolated violation -> pure (Left violation)
            NoExit tried -> pure (Left (describe scenario schedule image ("I1: stopped (" <> why <> ") with no supported exit") tried))
        Probed {} -> pure (Left "internal: a probe outcome without a probe path")

-- | The exits taken so far, one path per stopped review.
type Taken = [[Move]]

data Replay
  = -- | The scenario finished (the provider call counts) or violated an invariant.
    Replayed !(Either Text (Map.Map Call Int))
  | -- | A stopped review with no exit yet: its image, why it stopped, and
    -- the candidate moves.
    AtStop !Text !Text ![Move]
  | -- | The outcome of a probe path's last move and the moves after it.
    Probed !MoveOutcome ![Move]

-- | Replay the scenario from a fresh world and store, taking the known exits,
-- then apply the probe path at the next stopped review.
replay :: Scenario -> Schedule -> Taken -> [Move] -> IO Replay
replay scenario schedule taken probe = do
  run <- newRun scenario schedule
  go run "v1" (steps scenario) taken
  where
    -- The image the accepted application declares after a step.
    next previous step = case step of
      Deploy image -> image
      _ -> previous
    go run _ [] _ = do
      adversary <- readIORef (runAdversary run)
      consistent <- storeConsistent run
      pure $ case consistent of
        Left violation -> Replayed (Left (describe scenario schedule "(end)" violation []))
        Right () -> Replayed (Right (counts adversary))
    go run previous (IngestReceipt : rest) exits = do
      checked <- ingestReceipt run (null schedule)
      case checked of
        Left violation -> pure (Replayed (Left (describe scenario schedule (stepText IngestReceipt) violation [])))
        Right () -> go run previous rest exits
    go run previous (step : rest) exits = attempt False run previous step rest exits
    attempt replanned run previous step rest exits = do
      let historyImage image' = if historyFollows scenario then image' else "v1"
          image = stepText step
      outcome <- case step of
        Retire -> retireAndApply run (shape scenario) previous (historyImage previous)
        CreateDatabase -> databaseAndApply run (databaseScope, databaseNative) (shape scenario) previous (historyImage previous)
        UpdateDatabase -> databaseAndApply run resizedDatabase (shape scenario) previous (historyImage previous)
        RetireDatabase -> scopeRetireAndApply run databaseScopeId (shape scenario) previous (historyImage previous)
        _ -> reviewAndApply run (shape scenario) image (historyImage image)
      deletedData <- either (deletedDataRefusal run) (const (pure False)) outcome
      case outcome of
        Left refusal
          | any ((== ForeignObject) . snd) schedule || deletedData -> do
              -- An unowned object at a planned address refuses planning, and a
              -- durable member deleted outside review refuses until its data is
              -- recovered or its collection reviewed. There is no transaction to
              -- wedge, so the scenario ends here.
              adversary <- readIORef (runAdversary run)
              pure (Replayed (Right (counts adversary)))
          | otherwise -> pure (Replayed (Left (describe scenario schedule image ("planning refused: " <> refusal) [])))
        Right (registry, reviewed, applied) -> do
          checked <- checkInvariants run
          case (checked, applied) of
            (Left violation, _) -> pure (Replayed (Left (describe scenario schedule image violation [])))
            (Right (), Done) -> go run (next previous step) rest exits
            (Right (), Refused why)
              -- A retained member deleted outside review is refused: its data
              -- needs reviewed recovery or collection, as at planning. A
              -- replaced member retires with its record retained (ADR 27, N1).
              -- A member replaced after its review is refused at admission;
              -- the exit is a fresh review, which names the replacement (N1).
              | not replanned && any ((== Replaced) . snd) schedule && "retention-observation" `T.isInfixOf` why ->
                  attempt True run previous step rest exits
              | any ((== Deleted) . snd) schedule && "retention-observation" `T.isInfixOf` why -> do
                  adversary <- readIORef (runAdversary run)
                  pure (Replayed (Right (counts adversary)))
              | otherwise -> pure (Replayed (Left (describe scenario schedule image ("admission refused: " <> why) [])))
            (Right (), Stopped transaction why) -> case exits of
              path : more -> do
                outcomes <- mapM (tryMove run registry reviewed transaction) path
                afterExit <- checkInvariants run
                case (afterExit, reverse outcomes) of
                  (Left violation, _) -> pure (Replayed (Left (describe scenario schedule image (violation <> " (after exit " <> T.pack (show path) <> ")") [])))
                  (Right (), MoveIdle : _) -> go run (next previous step) rest more
                  _ -> pure (Replayed (Left "internal: a replayed exit did not reach an idle head"))
              [] -> case probe of
                [] -> do
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
                  gaps <- settlementGaps run registry reviewed transaction
                  case gaps of
                    gap : _ -> pure (Replayed (Left (describe scenario schedule image ("I8: " <> gap <> context) [])))
                    [] -> AtStop image (why <> context) <$> candidateMoves run reviewed transaction
                path -> do
                  outcomes <- mapM (tryMove run registry reviewed transaction) path
                  afterProbe <- checkInvariants run
                  next <- candidateMoves run reviewed transaction
                  pure $ case (afterProbe, reverse outcomes) of
                    (Left violation, _) -> Replayed (Left (describe scenario schedule image (violation <> " (on exit path " <> T.pack (show path) <> ")") []))
                    (Right (), final : _) -> Probed final next
                    (Right (), []) -> Probed (MoveRefused "empty probe") next

data Run = Run
  { runStore :: !InventoryStore
  , runInspect :: !InventoryStore
  -- ^ A clean view of the same objects for the model's own reads; faults
  -- reach only Nagare's commands.
  , runWorld :: !(IORef KubeWorld)
  , runAdversary :: !(IORef Adversary)
  , runBound :: !(IORef (Map.Map ContentDigest (Map.Map ResourceId ContentDigest)))
  -- ^ Native digests the review of each desired scope revision bound.
  , runImages :: !(IORef (Map.Map ContentDigest (Shape, Text, Text)))
  -- ^ The volume, service image and history image each desired scope revision
  -- declares, so the model can observe accepted members (I3).
  , runIncarnations :: !(IORef (Map.Map ResourceId PhysicalIdentity))
  -- ^ The last incarnation the head recorded for each member, kept after the
  -- head drops the record (I3's retirement clause).
  , runDatabase :: !(IORef (Map.Map ResourceId (ManagedResource, ByteString)))
  -- ^ The database revision's native specs the current review binds.
  , runConverged :: !(IORef (Map.Map ScopeId ScopeRevision))
  -- ^ The converged revisions last checked; I2 checks a revision when the
  -- head first reports it converged.
  }

newRun :: Scenario -> Schedule -> IO Run
newRun scenario schedule = do
  adversary <- newAdversary schedule
  base <- fakeObjectOps
  store <- newObjectStore (faultingObjectOps adversary base) fixtureBinding "recovery-model" Nothing >>= orFail "open store"
  inspect <- newObjectStore base fixtureBinding "recovery-inspect" Nothing >>= orFail "open inspection store"
  _ <- initializeStore store fixtureBinding "recovery-model" >>= orFail "initialize store"
  modifyIORef' adversary (\value -> value {storeArmed = True})
  world <- newKubeWorld (Set.fromList [if shapeWorker (shape scenario) then workerDigest image else serviceDigest image | image <- unready scenario])
  bound <- newIORef Map.empty
  images <- newIORef Map.empty
  incarnations <- newIORef Map.empty
  database <- newIORef databaseNative
  converged <- newIORef Map.empty
  pure (Run store inspect world adversary bound images incarnations database converged)

data Applied
  = Done
  | -- | Admission refused the review; nothing ran.
    Refused !Text
  | Stopped !TransactionId !Text

-- | Plan, review and apply one image. A store fault during planning is a
-- command an operator simply re-runs, so planning is retried once when a store
-- fault fired during it; an interrupted apply is a stopped transaction and is
-- never retried.
reviewAndApply :: Run -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
reviewAndApply run volume image historyImage = do
  planned <- retryingStoreFaults run (planReview run volume image historyImage)
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      forM_ (Map.elems (reviewDesiredRevisions (reviewedDocument reviewed))) $ \revision ->
        modifyIORef' (runBound run) (Map.insert (revisionDigest revision) (boundDigests volume image historyImage))
          >> modifyIORef' (runImages run) (Map.insert (revisionDigest revision) (volume, image, historyImage))
      startTransaction run
      applied <- applyRetryingFaults run registry reviewed
      Right . (registry,reviewed,) <$> classify run applied

-- | Retire the application scope, retaining its members, as `inventory
-- retire` plans it.
retireAndApply :: Run -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
retireAndApply run volume image historyImage = do
  planned <- retryingStoreFaults run (planRetirement run volume image historyImage)
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      startTransaction run
      applied <- applyRetryingFaults run registry reviewed
      Right . (registry,reviewed,) <$> classify run applied

-- | Retire one scope, retaining its members, as `inventory retire` plans it.
scopeRetireAndApply :: Run -> ScopeId -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
scopeRetireAndApply run scope volume image historyImage = do
  planned <- retryingStoreFaults run (registryFor run volume image historyImage >>= \registry -> planWith run registry (RetireScope scope RetainResources) decideRetirement)
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      startTransaction run
      applied <- applyRetryingFaults run registry reviewed
      Right . (registry,reviewed,) <$> classify run applied

planRetirement :: Run -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan))
planRetirement run volume image historyImage =
  registryFor run volume image historyImage >>= \registry -> planWith run registry (RetireScope appScope RetainResources) decideRetirement

-- | Review and apply the standalone database scope at one compiled revision.
databaseAndApply :: Run -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString)) -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
databaseAndApply run (scope, native) volume image historyImage = do
  -- As production builds it: the reviewed revision's native specs.
  writeIORef (runDatabase run) native
  planned <- retryingStoreFaults run (registryFor run volume image historyImage >>= \registry -> planWith run registry (ReplaceScope scope) (\_ _ _ -> Right noLifecycleDecisions))
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      forM_ (Map.lookup databaseScopeId (reviewDesiredRevisions (reviewedDocument reviewed))) $ \revision ->
        modifyIORef' (runBound run) (Map.insert (revisionDigest revision) (Map.map (contentDigest . snd) native))
      startTransaction run
      applied <- applyRetryingFaults run registry reviewed
      Right . (registry,reviewed,) <$> classify run applied

-- | I3: plan ingestion of a scheduled receipt from the live source, as `db
-- backup-receipts` plans it. A receipt whose source StatefulSet or PVC was
-- created outside review never compiles for ingestion. In a fault-free run the
-- receipt must compile, so the clause is never vacuous.
ingestReceipt :: Run -> Bool -> IO (Either Text ())
ingestReceipt run clean = do
  history <- loadInventoryHistory (runStore run) >>= orFail "load history"
  case Map.lookup databaseScopeId (historyAccepted history) of
    Nothing -> pure (refusedWhen "the database is not accepted")
    Just (revision, accepted) -> do
      let acceptedInventory = ok (composeSnapshot (ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision', declared) -> (revisionGeneration revision', declared)) (historyAccepted history)) (historyReservations history))))
      -- As the command does: the accepted members' native bytes come from the
      -- store's review evidence, not from the compiler.
      native <- either (const Map.empty) fst <$> Status.loadAcceptedNativeSelected (Set.fromList [statefulId, pvcId, cronId, signingId]) (runStore run) history acceptedInventory
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

-- | I4 is per transaction: a later review may write the same deterministic
-- operation again as new reviewed intent.
startTransaction :: Run -> IO ()
startTransaction run = modifyIORef' (runWorld run) (\world -> world {writes = Map.empty})

-- | Apply a review. An admission refused while a fault fired is a command an
-- operator simply re-runs, so it runs once more, as planning does.
applyRetryingFaults :: Run -> AdapterRegistry -> ReviewedPlan -> IO (Either Interrupted (Either (NonEmpty AdmissionError) TransactionResult))
applyRetryingFaults run registry reviewed = do
  before <- length . fired <$> readIORef (runAdversary run)
  attempt <- try (applyReviewed (runStore run) registry reviewed)
  after <- length . fired <$> readIORef (runAdversary run)
  idle <- maybe True (isNothing . headActiveTransaction) <$> (readHead (runInspect run) >>= orFail "read head")
  case attempt of
    Right (Left _) | after > before && idle -> try (applyReviewed (runStore run) registry reviewed)
    _ -> pure attempt

-- | Run a command; if it failed while a store fault fired, run it once more.
retryingStoreFaults :: Run -> IO (Either Text a) -> IO (Either Text a)
retryingStoreFaults run command = do
  before <- length . fired <$> readIORef (runAdversary run)
  first' <- try command
  after <- length . fired <$> readIORef (runAdversary run)
  case first' of
    Right (Right value) -> pure (Right value)
    failed
      | after > before -> either (\(StoreTrouble err) -> Left err) id <$> try command
      | otherwise -> pure (either (\(StoreTrouble err) -> Left err) id failed)

newtype StoreTrouble = StoreTrouble Text
  deriving stock (Show)

instance Exception StoreTrouble

orTrouble :: (Show e) => Text -> Either e a -> IO a
orTrouble context = either (\err -> throwIO (StoreTrouble (context <> ": " <> T.pack (show err)))) pure

planReview :: Run -> Shape -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan))
planReview run volume image historyImage =
  registryFor run volume image historyImage >>= \registry -> planWith run registry (ReplaceScope (scopeFor volume image historyImage)) (\_ _ _ -> Right noLifecycleDecisions)

planWith ::
  Run ->
  AdapterRegistry ->
  ScopeChange ->
  (CompositionCandidate -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  IO (Either Text (AdapterRegistry, ReviewedPlan))
planWith run registry change decide = do
  let store = runStore run
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
  current <- readHead (runInspect run) >>= orFail "read head"
  case current >>= headActiveTransaction of
    Just active -> pure (Stopped (ok (mkTransactionId active)) why)
    Nothing -> pure Done

data ExitSearch
  = ExitFound ![Move]
  | NoExit ![Text]
  | ExitViolated !Text

-- | Depth-first search, at most four moves deep, over the supported exit moves.
-- Every node is a fresh replay, so exploring one path never disturbs another.
-- A move the driver refuses ends its path; a move that changes the
-- transaction's state without ending it is extended. The world is never
-- written directly.
searchExit :: Scenario -> Schedule -> Taken -> [Move] -> IO ExitSearch
searchExit scenario schedule taken initial = do
  result <- explore (1 :: Int) [] initial []
  pure $ case result of
    Left violation -> ExitViolated violation
    Right (Just path, _) -> ExitFound path
    Right (Nothing, tried) -> NoExit (reverse tried)
  where
    explore depth path candidates tried = case candidates of
      [] -> pure (Right (Nothing, tried))
      move : more -> do
        let attempt = path <> [move]
            note text = T.pack (show attempt) <> ": " <> text
        result <- replay scenario schedule taken attempt
        case result of
          Probed MoveIdle _ -> pure (Right (Just attempt, tried))
          Probed MoveProgressed next
            | depth < 4 -> do
                deeper <- explore (depth + 1) attempt next (note "head changed, still active" : tried)
                case deeper of
                  Right (Nothing, tried') -> explore depth path more tried'
                  found -> pure found
            | otherwise -> explore depth path more (note "head changed at the depth limit" : tried)
          Probed (MoveRefused reason) _ -> explore depth path more (note ("refused: " <> reason) : tried)
          Replayed (Left violation) -> pure (Left violation)
          _ -> explore depth path more (note "unexpected replay outcome" : tried)

data MoveOutcome
  = MoveIdle
  | MoveProgressed
  | MoveRefused !Text

-- | Moves are tried in place: refused moves leave the head unchanged, so trying
-- the next one from the same state is sound. A progressing move is kept.
tryMove :: Run -> AdapterRegistry -> ReviewedPlan -> TransactionId -> Move -> IO MoveOutcome
tryMove run registry reviewed transaction move = do
  modifyIORef' (runWorld run) (\world -> world {quiet = True})
  before <- length . fired <$> readIORef (runAdversary run)
  attempt <- tryMoveQuiet run registry reviewed transaction move
  after <- length . fired <$> readIORef (runAdversary run)
  outcome <- case attempt of
    MoveRefused _ | after > before -> tryMoveQuiet run registry reviewed transaction move
    _ -> pure attempt
  modifyIORef' (runWorld run) (\world -> world {quiet = False})
  pure outcome

tryMoveQuiet :: Run -> AdapterRegistry -> ReviewedPlan -> TransactionId -> Move -> IO MoveOutcome
tryMoveQuiet run registry reviewed transaction move = do
  before <- progressSignature run transaction
  result <- try $ case move of
    Resume -> fmap (const ()) <$> resumeTransaction (runStore run) registry transaction
    Close ->
      fmap (const ())
        <$> closeTransaction
          (runStore run)
          registry
          (CloseInput transaction (contentDigest (encodeReviewDocument (reviewedDocument reviewed))) False Nothing)
  later <- progressSignature run transaction
  idle <- maybe True (isNothing . headActiveTransaction) <$> (readHead (runInspect run) >>= orFail "read head")
  pure $ case result of
    Left Interrupted -> MoveRefused "interrupted"
    Right _ | idle -> MoveIdle
    Right (Right ()) | later /= before -> MoveProgressed
    Right (Left err) -> MoveRefused (T.pack (show err))
    Right (Right ()) -> MoveRefused "no progress: the transaction's state is unchanged"

-- | What counts as progress: the active transaction, the accepted and converged
-- revisions, and each operation's latest state. A resume that stops again at
-- the same operation in the same state only appends journal events.
progressSignature :: Run -> TransactionId -> IO (Maybe Text, Map.Map ScopeId ScopeRevision, Map.Map ScopeId ScopeRevision, Map.Map OperationId Text)
progressSignature run transaction = do
  current <- readHead (runInspect run) >>= orFail "read head"
  raw <- maybe (pure []) (\value -> readJournalPrefix (runInspect run) (headSequence value) >>= orFail "read journal") current
  let events = [event | Right event <- map decodeJournalEvent raw, eventTransaction event == transaction]
      latest = Map.fromList [(operation, T.pack (takeWhile (/= ' ') (show (eventState event)))) | event <- events, Just operation <- [eventOperation event]]
  pure
    ( current >>= headActiveTransaction
    , maybe Map.empty headAccepted current
    , maybe Map.empty headConverged current
    , latest
    )

-- | I8 (ADR 26, obligation O1): every operation of a stopped transaction that
-- has intent and no completion settles to a proof class, unless resume can
-- still progress it. Settlement is read in inspection mode, so it fires no
-- fault.
settlementGaps :: Run -> AdapterRegistry -> ReviewedPlan -> TransactionId -> IO [Text]
settlementGaps run registry reviewed transaction = do
  current <- readHead (runInspect run) >>= orFail "read head"
  raw <- maybe (pure []) (\value -> readJournalPrefix (runInspect run) (headSequence value) >>= orFail "read journal") current
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

-- | ADR 26: a stopped transaction's supported exits are resume and close.
candidateMoves :: Run -> ReviewedPlan -> TransactionId -> IO [Move]
candidateMoves _ _ _ = pure [Resume, Close]

-- * Invariants I2, I4 and I5

-- | I5: after the scenario, the head reads back idle and every published
-- journal event up to it decodes and validates as one chain.
storeConsistent :: Run -> IO (Either Text ())
storeConsistent run = do
  current <- readHead (runInspect run)
  case current of
    Left err -> pure (Left ("I5: the head cannot be read: " <> T.pack (show err)))
    Right Nothing -> pure (Left "I5: the head is missing")
    Right (Just value)
      | isJust (headActiveTransaction value) -> pure (Left "I5: the scenario ended with an active transaction")
      | otherwise -> do
          raw <- readJournalPrefix (runInspect run) (headSequence value)
          pure $ case raw >>= first (StoreInvalidObject "journal") . traverse decodeJournalEvent of
            Left err -> Left ("I5: the published journal is unreadable: " <> T.pack (show err))
            Right events -> first (\err -> "I5: the journal chain is invalid: " <> err) (() <$ validateJournal events)

checkInvariants :: Run -> IO (Either Text ())
checkInvariants run = do
  current <- readHead (runInspect run) >>= orFail "read head"
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
  history <- loadInventoryHistory (runInspect run) >>= orFail "load history"
  images <- readIORef (runImages run)
  let appImages = Map.lookup appScope (historyAccepted history) >>= \(revision, _) -> Map.lookup (revisionDigest revision) images
  case (if Map.null (historyAccepted history) then Nothing else Just (fromMaybe (plainShape, "v1", "v1") appImages)) of
    Nothing -> pure []
    Just (volume, image, historyImage) -> do
      let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
          inventory = ok (composeSnapshot (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))))
          members = [resource ^. #identity | Managed resource <- inventoryDeclarations inventory]
      incarnations <- Status.statusIncarnations (runInspect run) (historyHead history) >>= orFail "status incarnations"
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

-- * The application scope and its registry

appScope :: ScopeId
appScope = ok (mkScopeId Application "model-web")

appCluster :: ResourceId
appCluster = mintResourceId appScope (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

serviceId, historyId :: ResourceId
serviceId = mintResourceId appScope (ok (mkLogicalKey "service")) (ok (mkName "resource"))
historyId = mintResourceId appScope (ok (mkLogicalKey "history")) (ok (mkName "resource"))

serviceValue :: Text -> Value
serviceValue image =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata" .= object ["name" .= ("web" :: Text), "namespace" .= ("personal" :: Text)]
    , "spec" .= object ["template" .= object ["spec" .= object ["containers" .= [object ["image" .= ("registry.example/web:" <> image)]]]]]
    ]

historyValue :: Text -> Value
historyValue image =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("ConfigMap" :: Text)
    , "metadata" .= object ["name" .= ("web-history" :: Text), "namespace" .= ("personal" :: Text)]
    , "data" .= object ["current" .= image]
    ]

bindMember :: ResourceId -> Value -> (ManagedResource, ByteString)
bindMember = bindMemberWith Stateless

bindMemberWith :: DataPolicy -> ResourceId -> Value -> (ManagedResource, ByteString)
bindMemberWith policy resource value =
  let bytes = ok (canonicalValue value)
   in ok (bindKubernetesObject (KubernetesInput resource appScope appCluster value (contentDigest bytes) Retain policy Private (SourceLocation "model" (resourceIdText resource))))

volumePolicy :: DataPolicy
volumePolicy = Durable (RecoveryIntent (ok (mkName "uploads")) (mkSecretRef (ok (mkName "uploads-key")) (ok (mkName "v1")) :| []))

volumeId :: ResourceId
volumeId = mintResourceId appScope (ok (mkLogicalKey "uploads")) (ok (mkName "pvc"))

volumeValue :: Value
volumeValue =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("PersistentVolumeClaim" :: Text)
    , "metadata" .= object ["name" .= ("web-uploads" :: Text), "namespace" .= ("personal" :: Text)]
    , "spec" .= object ["accessModes" .= ["ReadWriteOnce" :: Text], "resources" .= object ["requests" .= object ["storage" .= ("1Gi" :: Text)]]]
    ]

boundMembers :: Shape -> Text -> Text -> Map.Map ResourceId (ManagedResource, ByteString)
boundMembers volume image historyImage =
  Map.fromList $
    [ (serviceId, bindMember serviceId (serviceValue image))
    , (historyId, first (\history -> history {dependencies = [OrderedAfter serviceId]}) (bindMember historyId (historyValue historyImage)))
    ]
      <> [(volumeId, bindMemberWith volumePolicy volumeId volumeValue) | shapeVolume volume]
      <> [(workerId, bindMember workerId (workerValue image)) | shapeWorker volume]

boundDigests :: Shape -> Text -> Text -> Map.Map ResourceId ContentDigest
boundDigests volume image historyImage = Map.map (contentDigest . snd) (boundMembers volume image historyImage)

workerId :: ResourceId
workerId = mintResourceId appScope (ok (mkLogicalKey "worker")) (ok (mkName "deployment"))

workerValue :: Text -> Value
workerValue image =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("Deployment" :: Text)
    , "metadata" .= object ["name" .= ("web-worker" :: Text), "namespace" .= ("personal" :: Text)]
    , "spec" .= object ["replicas" .= (1 :: Int), "template" .= object ["spec" .= object ["containers" .= [object ["image" .= ("registry.example/worker:" <> image)]]]]]
    ]

workerDigest :: Text -> ContentDigest
workerDigest image = contentDigest (snd (bindMember workerId (workerValue image)))

serviceDigest :: Text -> ContentDigest
serviceDigest image = contentDigest (snd (bindMember serviceId (serviceValue image)))

scopeFor :: Shape -> Text -> Text -> ScopeDeclaration
scopeFor volume image historyImage = ok (mkScopeDeclaration appScope [ResourceBundle (map (Managed . fst) (Map.elems (boundMembers volume image historyImage))) [] [] [] [] []])

-- | As production builds it for one review: the reviewed members' specs.
registryFor :: Run -> Shape -> Text -> Text -> IO AdapterRegistry
registryFor run volume image historyImage = do
  database <- readIORef (runDatabase run)
  pure (ok (mkAdapterRegistry [worldKubernetesAdapter (fixtureBinding ^. #identity) (boundMembers volume image historyImage <> database) (runWorld run) (runAdversary run)]))

-- * The standalone database scope

databaseScopeId :: ScopeId
databaseScopeId = ok (mkScopeId Standalone "database-pg")

databaseBackend :: StoreBackend
databaseBackend = GcsBackend "project" "bucket"

databaseScope :: ScopeDeclaration
databaseNative :: Map.Map ResourceId (ManagedResource, ByteString)
(databaseScope, databaseNative) = compiledDatabase Nothing

-- | The same database with CPU requests: only its StatefulSet changes.
resizedDatabase :: (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
resizedDatabase = compiledDatabase (Just (Dsl.Resources (Just (ok (Dsl.mkQuantity "500m"))) Nothing Nothing Nothing))

compiledDatabase :: Maybe Dsl.Resources -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compiledDatabase resources =
  ok
    ( compileStandaloneDatabase
        (DatabaseDirectInput database databaseScopeId appCluster Nothing recovery (SourceLocation "model" "pg"))
        (DatabaseBackupTarget databaseBackend HourlyRecoveryPoint)
    )
  where
    database =
      Database
        (ok (mkDatabaseName "pg"))
        Nothing
        Postgres
        (defaultEngineVersion Postgres)
        (ok (Dsl.mkNamespace "personal"))
        (ok (Dsl.mkQuantity "1Gi"))
        resources
        Dsl.Retain
    recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "nagare-db-pg")) (ok (mkName "v1")) :| [])

-- | The database member at one Kubernetes kind and name.
databaseMember :: Text -> Text -> ResourceId
databaseMember kind name =
  case [ member ^. #identity
       | (member, _) <- Map.elems databaseNative
       , Kubernetes _ _ nativeKind _ nativeName <- [member ^. #address]
       , nameText nativeKind == kind
       , nameText nativeName == name
       ] of
    [resource] -> resource
    found -> error ("database fixture lacks one " <> T.unpack kind <> " " <> T.unpack name <> ": " <> show found)

statefulId, pvcId, cronId, signingId :: ResourceId
statefulId = databaseMember "statefulset" "pg"
pvcId = databaseMember "persistentvolumeclaim" (dbPvcName "pg")
cronId = databaseMember "cronjob" "nagare-dbbackup-pg"
signingId = databaseMember "secret" "nagare-dbbackup-pg-signing"

orFail :: (Show e) => String -> Either e a -> IO a
orFail context = either (\err -> assertFailure (context <> ": " <> show err) >> pure (error "unreachable")) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
