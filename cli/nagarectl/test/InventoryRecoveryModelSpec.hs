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
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lifecycle (decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
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

-- | A sequence of reviews of one application scope; each names the image of
-- its Knative Service and release-history ConfigMap.
data Scenario = Scenario
  { label :: !Text
  , steps :: ![Text]
  , unready :: ![Text]
  -- ^ Images whose revision never becomes Ready (a bad update).
  , historyFollows :: !Bool
  -- ^ Whether the release-history ConfigMap records each image, as an
  -- application's release history does, or stays as first created.
  , withVolume :: !Bool
  -- ^ Whether the application also declares an independent durable volume.
  }
  deriving stock (Eq, Show)

scenarios :: [Scenario]
scenarios =
  [ Scenario "create" ["v1"] [] True False
  , Scenario "create then good update" ["v1", "v2"] [] True False
  , Scenario "create, bad update, corrected update (history unchanged)" ["v1", "bad", "v3"] ["bad"] False False
  , Scenario "create, bad update, corrected update (history follows the release)" ["v1", "bad", "v3"] ["bad"] True False
  , Scenario "create, bad update, corrected update (with a durable volume)" ["v1", "bad", "v3"] ["bad"] True True
  , Scenario "create with a durable volume, then retire" ["v1", retireStep] [] True True
  ]

-- | The step that retires the application scope, retaining its members.
retireStep :: Text
retireStep = "retire"

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
    _ -> assertFailure (T.unpack (T.intercalate "\n\n" (take 5 violations)) <> "\n\n" <> show (length violations) <> " violation(s)")

-- * One execution

data Finished = Finished
  { finishedCalls :: !(Map.Map Call Int)
  }
  deriving stock (Eq, Show)

-- | An exit move for a stopped transaction.
data Move
  = Resume
  | Recover !RecoveryAction !OperationId
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
    -- The image the accepted scope declares after a step; a retirement
    -- leaves no accepted scope, and nothing follows it.
    next image = image
    go run _ [] _ = do
      adversary <- readIORef (runAdversary run)
      consistent <- storeConsistent run
      pure $ case consistent of
        Left violation -> Replayed (Left (describe scenario schedule "(end)" violation []))
        Right () -> Replayed (Right (counts adversary))
    go run previous (image : rest) exits = do
      let historyImage step = if historyFollows scenario then step else "v1"
      outcome <-
        if image == retireStep
          then retireAndApply run (withVolume scenario) previous (historyImage previous)
          else reviewAndApply run (withVolume scenario) image (historyImage image)
      case outcome of
        Left refusal
          | any ((== ForeignObject) . snd) schedule -> do
              -- An unowned object at a planned address refuses planning; there is
              -- no transaction to wedge, so the scenario ends here.
              adversary <- readIORef (runAdversary run)
              pure (Replayed (Right (counts adversary)))
          | otherwise -> pure (Replayed (Left (describe scenario schedule image ("planning refused: " <> refusal) [])))
        Right (registry, reviewed, applied) -> do
          checked <- checkInvariants run
          case (checked, applied) of
            (Left violation, _) -> pure (Replayed (Left (describe scenario schedule image violation [])))
            (Right (), Done) -> go run (next image) rest exits
            (Right (), Stopped transaction why) -> case exits of
              path : more -> do
                outcomes <- mapM (tryMove run registry reviewed transaction) path
                afterExit <- checkInvariants run
                case (afterExit, reverse outcomes) of
                  (Left violation, _) -> pure (Replayed (Left (describe scenario schedule image (violation <> " (after exit " <> T.pack (show path) <> ")") [])))
                  (Right (), MoveIdle : _) -> go run (next image) rest more
                  _ -> pure (Replayed (Left "internal: a replayed exit did not reach an idle head"))
              [] -> case probe of
                [] -> AtStop image why <$> candidateMoves run reviewed transaction
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
  , runImages :: !(IORef (Map.Map ContentDigest (Bool, Text, Text)))
  -- ^ The volume, service image and history image each desired scope revision
  -- declares, so the model can observe accepted members (I3).
  , runIncarnations :: !(IORef (Map.Map ResourceId PhysicalIdentity))
  -- ^ The last incarnation the head recorded for each member, kept after the
  -- head drops the record (I3's retirement clause).
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
  world <- newKubeWorld (Set.fromList [serviceDigest image | image <- unready scenario])
  bound <- newIORef Map.empty
  images <- newIORef Map.empty
  incarnations <- newIORef Map.empty
  converged <- newIORef Map.empty
  pure (Run store inspect world adversary bound images incarnations converged)

data Applied
  = Done
  | Stopped !TransactionId !Text

-- | Plan, review and apply one image. A store fault during planning is a
-- command an operator simply re-runs, so planning is retried once when a store
-- fault fired during it; an interrupted apply is a stopped transaction and is
-- never retried.
reviewAndApply :: Run -> Bool -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
reviewAndApply run volume image historyImage = do
  planned <- retryingStoreFaults run (planReview run volume image historyImage)
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      forM_ (Map.elems (reviewDesiredRevisions (reviewedDocument reviewed))) $ \revision ->
        modifyIORef' (runBound run) (Map.insert (revisionDigest revision) (boundDigests volume image historyImage))
          >> modifyIORef' (runImages run) (Map.insert (revisionDigest revision) (volume, image, historyImage))
      applied <- try (applyReviewed (runStore run) registry reviewed)
      Right . (registry,reviewed,) <$> classify run applied

-- | Retire the application scope, retaining its members, as `inventory
-- retire` plans it.
retireAndApply :: Run -> Bool -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
retireAndApply run volume image historyImage = do
  planned <- retryingStoreFaults run (planRetirement run volume image historyImage)
  case planned of
    Left err -> pure (Left err)
    Right (registry, reviewed) -> do
      applied <- try (applyReviewed (runStore run) registry reviewed)
      Right . (registry,reviewed,) <$> classify run applied

planRetirement :: Run -> Bool -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan))
planRetirement run volume image historyImage =
  planWith run (registryFor run volume image historyImage) (RetireScope appScope RetainResources) decideRetirement

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

planReview :: Run -> Bool -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan))
planReview run volume image historyImage =
  planWith run (registryFor run volume image historyImage) (ReplaceScope (scopeFor volume image historyImage)) (\_ _ _ -> Right noLifecycleDecisions)

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
  Right (Left err) -> stoppedFromHead run ("driver error: " <> T.pack (show err))
  Right (Right result) -> case result of
    Converged _ -> pure Done
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
    Recover action operation ->
      fmap (const ())
        <$> recordOperatorRecovery
          (runStore run)
          registry
          (OperatorRecoveryInput transaction operation (contentDigest (encodeReviewDocument (reviewedDocument reviewed))) action)
          False
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

-- | Resume, then every recovery action for every operation of the stopped
-- transaction that has no completion.
candidateMoves :: Run -> ReviewedPlan -> TransactionId -> IO [Move]
candidateMoves run reviewed transaction = do
  current <- readHead (runInspect run) >>= orFail "read head"
  raw <- maybe (pure []) (\value -> readJournalPrefix (runInspect run) (headSequence value) >>= orFail "read journal") current
  let events = [event | Right event <- map decodeJournalEvent raw, eventTransaction event == transaction]
      latest = Map.fromList [(operation, eventState event) | event <- events, Just operation <- [eventOperation event]]
      reviewedOperations = [plannedOperationId (reviewPlannedOperation entry) | entry <- reviewOperations (reviewedDocument reviewed)]
      open = [operation | operation <- reviewedOperations, maybe True (not . completed) (Map.lookup operation latest)]
  pure (Resume : [Recover action operation | operation <- open, action <- recoveryActions])
  where
    completed state = case state of
      Completed _ -> True
      _ -> False

recoveryActions :: [RecoveryAction]
recoveryActions =
  [ AcceptAdapterProof
  , RetryAfterAdapterProof
  , ContinueFencedOperation
  , VerifyFencedEffect
  , RecoverFencedBackup
  , ForwardFencedRelease
  , AbandonPartialPrune
  , AbandonPartialVolumeRestore
  , AbandonPartialDatabaseRestore
  , StopIncompleteApplication
  , AbandonRefusedOperation
  ]

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
            Nothing -> True
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
  case Map.lookup appScope (historyAccepted history) >>= \(revision, _) -> Map.lookup (revisionDigest revision) images of
    Nothing -> pure []
    Just (volume, image, historyImage) -> do
      let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
          inventory = ok (composeSnapshot (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))))
          members = [resource ^. #identity | Managed resource <- inventoryDeclarations inventory]
      incarnations <- Status.statusIncarnations (runInspect run) (historyHead history) >>= orFail "status incarnations"
      modifyIORef' (runWorld run) (\world -> world {inspecting = True})
      observed <- observeWithRegistry (registryFor run volume image historyImage) (Map.singleton KubernetesExecutor members)
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
      <> map ("  " <>) (take 12 tried)

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

boundMembers :: Bool -> Text -> Text -> Map.Map ResourceId (ManagedResource, ByteString)
boundMembers volume image historyImage =
  Map.fromList $
    [ (serviceId, bindMember serviceId (serviceValue image))
    , (historyId, first (\history -> history {dependencies = [OrderedAfter serviceId]}) (bindMember historyId (historyValue historyImage)))
    ]
      <> [(volumeId, bindMemberWith volumePolicy volumeId volumeValue) | volume]

boundDigests :: Bool -> Text -> Text -> Map.Map ResourceId ContentDigest
boundDigests volume image historyImage = Map.map (contentDigest . snd) (boundMembers volume image historyImage)

serviceDigest :: Text -> ContentDigest
serviceDigest image = contentDigest (snd (bindMember serviceId (serviceValue image)))

scopeFor :: Bool -> Text -> Text -> ScopeDeclaration
scopeFor volume image historyImage = ok (mkScopeDeclaration appScope [ResourceBundle (map (Managed . fst) (Map.elems (boundMembers volume image historyImage))) [] [] [] [] []])

-- | As production builds it for one review: the reviewed members' specs.
registryFor :: Run -> Bool -> Text -> Text -> AdapterRegistry
registryFor run volume image historyImage =
  ok (mkAdapterRegistry [worldKubernetesAdapter (fixtureBinding ^. #identity) (boundMembers volume image historyImage) (runWorld run) (runAdversary run)])

orFail :: (Show e) => String -> Either e a -> IO a
orFail context = either (\err -> assertFailure (context <> ": " <> show err) >> pure (error "unreachable")) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
