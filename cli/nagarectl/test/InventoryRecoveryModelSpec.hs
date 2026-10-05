-- | EP-173 M1: the recovery invariant model. Real planning, the real driver and
-- recovery policy, and the real Kubernetes adapter run over an in-memory world
-- with an adversary. For every scheduled fault, every stopped transaction must
-- have a supported exit (I1), nothing unreviewed may be accepted or reported
-- converged (I2), and no reviewed operation may write twice (I4).
module InventoryRecoveryModelSpec (inventoryRecoveryModelTests) where

import Control.Exception (try)
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
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.World.Adversary
import Nagare.Test.World.Kubernetes
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
  ]

type Schedule = [(Boundary, Fault)]

singleFaults :: Int -> [Schedule]
singleFaults boundaries = [[(Boundary MutateCall n, fault)] | n <- [1 .. boundaries], fault <- [minBound .. maxBound]]

faultPairs :: Int -> [Schedule]
faultPairs boundaries =
  [ [(Boundary MutateCall n, first'), (Boundary MutateCall m, second')]
  | n <- [1 .. boundaries]
  , m <- [n + 1 .. boundaries]
  , first' <- [minBound .. maxBound]
  , second' <- [minBound .. maxBound]
  ]

runTier :: (Int -> [Schedule]) -> Assertion
runTier schedulesFor = do
  violations <- fmap concat . forM scenarios $ \scenario -> do
    clean <- runScenario scenario []
    case clean of
      Left violation -> pure ["the fault-free scenario violates the model:\n" <> violation]
      Right finished ->
        fmap concat . forM (schedulesFor (finishedMutations finished)) $ \schedule ->
          either (\violation -> [violation]) (const []) <$> runScenario scenario schedule
  case violations of
    [] -> pure ()
    _ -> assertFailure (T.unpack (T.intercalate "\n\n" (take 5 violations)) <> "\n\n" <> show (length violations) <> " violation(s)")

-- * One execution

data Finished = Finished
  { finishedMutations :: !Int
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
    loop taken = do
      result <- replay scenario schedule taken []
      case result of
        Replayed (Left violation) -> pure (Left violation)
        Replayed (Right mutations) -> pure (Right (Finished mutations))
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
  = -- | The scenario finished (the mutation count) or violated an invariant.
    Replayed !(Either Text Int)
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
  go run (steps scenario) taken
  where
    go run [] _ = do
      adversary <- readIORef (runAdversary run)
      pure (Replayed (Right (Map.findWithDefault 0 MutateCall (counts adversary))))
    go run (image : rest) exits = do
      outcome <- reviewAndApply run (withVolume scenario) image (if historyFollows scenario then image else "v1")
      case outcome of
        Left refusal -> pure (Replayed (Left (describe scenario schedule image ("planning refused: " <> refusal) [])))
        Right (registry, reviewed, applied) -> do
          checked <- checkInvariants run
          case (checked, applied) of
            (Left violation, _) -> pure (Replayed (Left (describe scenario schedule image violation [])))
            (Right (), Done) -> go run rest exits
            (Right (), Stopped transaction why) -> case exits of
              path : more -> do
                outcomes <- mapM (tryMove run registry reviewed transaction) path
                afterExit <- checkInvariants run
                case (afterExit, reverse outcomes) of
                  (Left violation, _) -> pure (Replayed (Left (describe scenario schedule image (violation <> " (after exit " <> T.pack (show path) <> ")") [])))
                  (Right (), MoveIdle : _) -> go run rest more
                  _ -> pure (Replayed (Left "internal: a replayed exit did not reach an idle head"))
              [] -> case probe of
                [] -> AtStop image why <$> candidateMoves run transaction
                path -> do
                  outcomes <- mapM (tryMove run registry reviewed transaction) path
                  afterProbe <- checkInvariants run
                  next <- candidateMoves run transaction
                  pure $ case (afterProbe, reverse outcomes) of
                    (Left violation, _) -> Replayed (Left (describe scenario schedule image (violation <> " (on exit path " <> T.pack (show path) <> ")") []))
                    (Right (), final : _) -> Probed final next
                    (Right (), []) -> Probed (MoveRefused "empty probe") next

data Run = Run
  { runStore :: !InventoryStore
  , runWorld :: !(IORef KubeWorld)
  , runAdversary :: !(IORef Adversary)
  , runBound :: !(IORef (Map.Map ContentDigest (Map.Map ResourceId ContentDigest)))
  -- ^ Native digests the review of each desired scope revision bound.
  , runConverged :: !(IORef (Map.Map ScopeId ScopeRevision))
  -- ^ The converged revisions last checked; I2 checks a revision when the
  -- head first reports it converged.
  }

newRun :: Scenario -> Schedule -> IO Run
newRun scenario schedule = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "recovery-model" >>= orFail "initialize store"
  world <- newKubeWorld (Set.fromList [serviceDigest image | image <- unready scenario])
  adversary <- newAdversary schedule
  bound <- newIORef Map.empty
  converged <- newIORef Map.empty
  pure (Run store world adversary bound converged)

data Applied
  = Done
  | Stopped !TransactionId !Text

reviewAndApply :: Run -> Bool -> Text -> Text -> IO (Either Text (AdapterRegistry, ReviewedPlan, Applied))
reviewAndApply run volume image historyImage = do
  let store = runStore run
      registry = registryFor run volume image historyImage
  accepted <- historyAccepted <$> (loadInventoryHistory store >>= orFail "load history")
  reservations <- historyReservations <$> (loadInventoryHistory store >>= orFail "load history")
  let snapshot = ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) accepted) reservations)
  case composeInventory snapshot (ReplaceScope (scopeFor volume image historyImage) :| []) of
    Left err -> pure (Left (T.pack (show err)))
    Right candidate -> do
      history <- loadInventoryPlanningHistory store candidate >>= orFail "load planning history"
      let required = Set.toList (requiredResources (observationRequirements candidate history))
      observed <- observeWithRegistry registry (Map.singleton KubernetesExecutor required)
      case observed >>= \observations -> first (T.pack . show) (planChanges candidate noLifecycleDecisions history observations) of
        Left err -> pure (Left err)
        Right proposal -> do
          before <- readStoreSnapshot store >>= orFail "read snapshot"
          prepared <- prepareReview registry before proposal
          case prepared of
            Left err -> pure (Left (T.pack (show err)))
            Right bundle -> do
              _ <- publishReview store bundle >>= orFail "publish review"
              published <- readStoreSnapshot store >>= orFail "read snapshot"
              case verifyReview published bundle of
                Left errs -> pure (Left (T.pack (show (NE.toList errs))))
                Right reviewed -> do
                  forM_ (Map.elems (reviewDesiredRevisions (reviewedDocument reviewed))) $ \revision ->
                    modifyIORef' (runBound run) (Map.insert (revisionDigest revision) (boundDigests volume image historyImage))
                  applied <- try (applyReviewed store registry reviewed)
                  Right . (registry,reviewed,) <$> classify run applied

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
  current <- readHead (runStore run) >>= orFail "read head"
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
  idle <- maybe True (isNothing . headActiveTransaction) <$> (readHead (runStore run) >>= orFail "read head")
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
  current <- readHead (runStore run) >>= orFail "read head"
  raw <- maybe (pure []) (\value -> readJournalPrefix (runStore run) (headSequence value) >>= orFail "read journal") current
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
candidateMoves :: Run -> TransactionId -> IO [Move]
candidateMoves run transaction = do
  current <- readHead (runStore run) >>= orFail "read head"
  raw <- maybe (pure []) (\value -> readJournalPrefix (runStore run) (headSequence value) >>= orFail "read journal") current
  let events = [event | Right event <- map decodeJournalEvent raw, eventTransaction event == transaction]
      latest = Map.fromList [(operation, eventState event) | event <- events, Just operation <- [eventOperation event]]
      open = [operation | (operation, state) <- Map.toList latest, not (completed state)]
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

-- * Invariants I2 and I4

checkInvariants :: Run -> IO (Either Text ())
checkInvariants run = do
  current <- readHead (runStore run) >>= orFail "read head"
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
  pure $ case (twice, unproven) of
    (operation : _, _) -> Left ("I4: operation " <> operationIdText operation <> " wrote twice")
    (_, resource : _) -> Left ("I2: scope reported converged while " <> resourceIdText resource <> " is not the reviewed Ready object")
    _ -> Right ()

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
