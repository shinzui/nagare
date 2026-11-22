-- | EP-276 M1: every converged reviewed transaction is one @change.applied@
-- event, through the real planner, executor, journal and feed.
module EventsChangeSpec (eventsChangeTests) where

import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import EventsDeploymentSpec
import Nagare.Dsl.Prelude
import Nagare.Events.Application (deletionProducer)
import Nagare.Events.Change (changeKey, changeProducer)
import Nagare.Events.Envelope (eventIdFor)
import Nagare.Events.Read (FeedEntry)
import Nagare.Events.Restore (restoreProducer)
import Nagare.Events.Source
import Nagare.Inventory.Actor (Actor (..), ReviewSource (..))
import Nagare.Inventory.DelegatedPlanning (attributeReview)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..))
import Nagare.Inventory.Journal (TransactionId, mkOperationId, mkTransactionId)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory (ScopeDeclaration, withScopeOverrides)
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

eventsChangeTests :: TestTree
eventsChangeTests =
  testGroup
    "Events.Change"
    [ testCase "a deploy is one change.applied beside its app.deployed, about the application" $ withWorld $ \world -> do
        first' <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        assertConverged first'
        events <- feedEntries world
        map kindOf events @?= [AppDeployed, ChangeApplied]
        [change] <- pure (changes events)
        change ^. #resource @?= notesScope
        map (\scope -> (scope ^. #scope, scope ^. #change)) (change ^. #payload . #scopes) @?= [(notesScope, ScopeCreated)]
        change ^. #payload . #actor @?= OperatorActor Nothing
        change ^. #payload . #source @?= ChangeSource Nothing Nothing Nothing
        assertBool "the deploy creates and updates members" (not (null (change ^. #payload . #operations)))
        -- The two events of one change share its transaction.
        [deployment] <- pure [value | entry <- events, AppDeployedPayload value <- [entry ^. #envelope . #payload]]
        deployment ^. #transaction @?= change ^. #payload . #transaction
    , testCase "a later change of the same scope is an update from the revision converged before" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1-patched"]
        [first', second'] <- changes <$> feedEntries world
        [created] <- pure (first' ^. #payload . #scopes)
        [updated] <- pure (second' ^. #payload . #scopes)
        updated ^. #change @?= ScopeUpdated
        updated ^. #from @?= created ^. #to
        assertBool "the update moves the revision" (updated ^. #to /= updated ^. #from)
    , testCase "a rerun that only verifies is a change.applied with no scope, about the context" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        rerun <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        assertConverged rerun
        events <- feedEntries world
        map kindOf events @?= [AppDeployed, ChangeApplied, ChangeApplied]
        [_, verified] <- pure (changes events)
        verified ^. #payload . #scopes @?= []
        verified ^. #resource @?= contextScope
        -- Its verifications are proved at admission and never journaled.
        verified ^. #payload . #operations @?= []
    , testCase "two changed applications are one change.applied about the context, listing both" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1", docs (releaseLog ["d1"] "d1")]
        [change] <- changes <$> feedEntries world
        change ^. #resource @?= contextScope
        map (^. #scope) (change ^. #payload . #scopes) @?= [docsScope, notesScope]
    , testCase "a stopped transaction announces nothing; its resume announces it once, under its own key" $ withWorld $ \world -> do
        writeIORef (world ^. #interruptNext) True
        stopped <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        transaction <- case stopped of
          StoppedAmbiguous token _ _ -> pure token
          other -> assertFailure ("expected the rollout to stop, got " <> show other) >> fail "stop"
        changes <$> feedEntries world >>= (@?= [])
        resumed <- resume world transaction
        resumed @?= Converged transaction
        events <- feedEntries world
        let expected = eventIdFor (binding ^. #identity) (either (error . T.unpack) id (changeKey transaction))
        [entry ^. #envelope . #eventId | entry <- events, kindOf entry == ChangeApplied] @?= [expected]
        feedEntries world >>= (@?= events)
    , testCase "a stopped apply is one change.failed about its application; its resume is change.applied (M2)" $ withWorld $ \world -> do
        writeIORef (world ^. #interruptNext) True
        stopped <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        transaction <- stoppedTransaction stopped
        events <- feedEntries world
        map kindOf events @?= [ChangeFailed]
        [(scope, failure)] <- pure (failures events)
        scope @?= notesScope
        failure ^. #transaction @?= transaction
        failure ^. #outcome @?= AmbiguousOutcome
        failure ^. #next @?= ResumeOrClose
        failure ^. #scope @?= Just notesScope
        failure ^. #actor @?= OperatorActor Nothing
        assertBool "the failure names its operation and resources" (isJust (failure ^. #operation) && not (null (failure ^. #resources)))
        resumed <- resume world transaction
        resumed @?= Converged transaction
        after <- feedEntries world
        map kindOf after @?= [ChangeFailed, AppDeployed, ChangeApplied]
        -- A later cycle, or a restarted worker, repeats nothing.
        feedEntries world >>= (@?= after)
    , testCase "closing a stopped change is one change.closed naming its record (M2)" $ withWorld $ \world -> do
        writeIORef (world ^. #interruptNext) True
        stopped <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        transaction <- stoppedTransaction stopped
        closeStopped world transaction
        events <- feedEntries world
        map kindOf events @?= [ChangeFailed, ChangeClosed]
        [closure] <- pure [value | entry <- events, ChangeClosedPayload value <- [entry ^. #envelope . #payload]]
        closure ^. #transaction @?= transaction
        map (^. #scope) (closure ^. #scopes) @?= [notesScope]
        closure ^. #attested @?= False
        feedEntries world >>= (@?= events)
    , testCase "a stop is app.stopped and a later restart app.restarted; rerunning either names nothing (M3)" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        stopped <- deploy world [withOverrides [("operational.visibility", "cluster-local")] (notes (releaseLog ["r1"] "r1") "v1")]
        assertConverged stopped
        _ <- deploy world [withOverrides [("operational.visibility", "cluster-local")] (notes (releaseLog ["r1"] "r1") "v1")]
        restarted <- deploy world [withOverrides [("operational.restart", "s1")] (notes (releaseLog ["r1"] "r1") "v1")]
        assertConverged restarted
        _ <- deploy world [withOverrides [("operational.restart", "s1")] (notes (releaseLog ["r1"] "r1") "v1")]
        events <- feedEntries world
        [(kindOf entry, entry ^. #envelope . #resource . #scope) | entry <- events, kindOf entry `elem` [AppStopped, AppRestarted]]
          @?= [(AppStopped, notesScope), (AppRestarted, notesScope)]
        [stamp' | entry <- events, AppRestartedPayload value <- [entry ^. #envelope . #payload], let { stamp' = value ^. #restartStamp }] @?= ["s1"]
        length [() | entry <- events, kindOf entry == ChangeApplied] @?= 5
    , testCase "a scope with no converged view, or whose release also moved, is neither stopped nor restarted (M3)" $ withWorld $ \world -> do
        _ <- deploy world [withOverrides [("operational.restart", "s1")] (notes (releaseLog ["r1"] "r1") "v1")]
        _ <- deploy world [withOverrides [("operational.visibility", "cluster-local")] (notes (releaseLog ["r2", "r1"] "r2") "v2")]
        kinds <- map kindOf <$> feedEntries world
        kinds @?= [AppDeployed, ChangeApplied, AppDeployed, ChangeApplied]
    , testCase "retiring an application is app.deleted counting the members it retained (M3)" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        retired <- retire world notesScope
        assertConverged retired
        events <- feedEntries world
        [(entry ^. #envelope . #resource . #scope, value ^. #subject, value ^. #retainedMembers) | entry <- events, AppDeletedPayload value <- [entry ^. #envelope . #payload]]
          @?= [(notesScope, ApplicationSubject, 3)]
        [change] <- pure (drop 1 (changes events))
        map (\scope -> (scope ^. #scope, scope ^. #change)) (change ^. #payload . #scopes) @?= [(notesScope, ScopeRetired)]
    , testCase "a converged restore scope is database.restored once; a review that keeps its overrides is none (M3)" $ withWorld $ \world -> do
        let restoreScope = checked (mkScopeId Standalone "restore-notes-1")
            overrides =
              [ ("restore.id", "restore-1")
              , ("restore.backup.id", "bk-1")
              , ("restore.database", "notes")
              , ("restore.namespace", "personal")
              , ("restore.target.database", "notes_restore_1")
              ]
        restored <- deploy world [withOverrides overrides (scopeWith restoreScope [workload restoreScope "job" "j1"])]
        assertConverged restored
        _ <- deploy world [withOverrides overrides (scopeWith restoreScope [workload restoreScope "job" "j2"])]
        events <- feedEntries world
        [value | entry <- events, DatabaseRestoredPayload value <- [entry ^. #envelope . #payload]]
          & map (\value -> (value ^. #restore, value ^. #backup, value ^. #database, value ^. #appDatabase, value ^. #targetDatabase, value ^. #targetKind))
          & (@?= [("restore-1", Just "bk-1", Just "notes", Nothing, Just "notes_restore_1", ScratchTarget)])
    , testCase "a deletion that operated the release log names the last release; a rebuild restore is rebuilt (M3)" $ do
        let before = ScopeRevision (checked (mkScopeGeneration 3)) (contentDigest "before")
            (logId, (_, logBytes)) = history notesScope "notes" (releaseLog ["r2", "r1"] "r2")
            restoreScope = checked (mkScopeId Standalone "restore-notes-2")
            input =
              (emptyInput (checked (mkTransactionId "tx-retire")))
                { baseRevisions = Map.fromList [(notesScope, before)]
                , convergedBefore = Map.fromList [(notesScope, before)]
                , members = Map.singleton logId (MemberView notesScope (checked (mkOperationId "op-retire")) Nothing (Just logBytes))
                , scopes = Map.singleton restoreScope (ScopeView before (Map.fromList [("restore.id", "restore-2"), ("restore.rebuild.review", "abc")]) Nothing)
                }
        [value | PublicCandidate candidate <- (deletionProducer ^. #produce) input, AppDeletedPayload value <- [candidate ^. #payload]]
          & map (\value -> (value ^. #lastRelease, value ^. #scopeRevision))
          & (@?= [(Just "r2", before)])
        [value ^. #targetKind | PublicCandidate candidate <- (restoreProducer ^. #produce) input, DatabaseRestoredPayload value <- [candidate ^. #payload]] @?= [RebuiltTarget]
    , testCase "a named actor's review names the actor and the source it came from" $ withWorld $ \world -> do
        let source = ReviewSource (Just "github.com/example/notes") (Just "0123abc") Nothing
        _ <- deployWith world (attributeReview (OperatorActor (Just "alice")) (Just source)) [notes (releaseLog ["r1"] "r1") "v1"]
        [change] <- changes <$> feedEntries world
        change ^. #payload . #actor @?= OperatorActor (Just "alice")
        change ^. #payload . #source @?= ChangeSource (Just "github.com/example/notes") (Just "0123abc") Nothing
    , testCase "a deployer's change names the deployer; retiring a scope is a retirement from its converged revision" $ do
        let before = ScopeRevision (checked (mkScopeGeneration 1)) (contentDigest "before")
            input =
              (emptyInput (checked (mkTransactionId "tx-deployer")))
                { baseRevisions = Map.fromList [(notesScope, before)]
                , convergedBefore = Map.fromList [(notesScope, before)]
                , actor = DeployerActor "ci"
                }
        case (changeProducer ^. #produce) input of
          [PublicCandidate candidate] -> do
            candidate ^. #resource . #scope @?= notesScope
            case candidate ^. #payload of
              ChangeAppliedPayload change -> do
                change ^. #actor @?= DeployerActor "ci"
                change ^. #scopes @?= [ScopeChange notesScope ScopeRetired (Just before) Nothing]
              other -> assertFailure ("not a change: " <> show other)
          other -> assertFailure ("expected one candidate, got " <> show (length other))
    ]

data Applied = Applied
  { resource :: !ScopeId
  , payload :: !ChangeApplication
  }
  deriving stock (Eq, Show, Generic)

-- | A converging transaction that changed nothing.
emptyInput :: TransactionId -> SourceInput
emptyInput transaction =
  SourceInput
    { context = binding ^. #identity
    , transaction
    , review = contentDigest "review"
    , payloadIdentity = "operator-cli"
    , baseRevisions = Map.empty
    , desiredRevisions = Map.empty
    , convergedBefore = Map.empty
    , operations = Map.empty
    , steps = []
    , actor = OperatorActor Nothing
    , source = Nothing
    , retained = Map.empty
    , collected = Map.empty
    , journal = []
    , members = Map.empty
    , scopes = Map.empty
    }

withOverrides :: [(Text, Text)] -> (ScopeDeclaration, natives) -> (ScopeDeclaration, natives)
withOverrides values (declaration, native) = (withScopeOverrides (Map.fromList values) declaration, native)

stoppedTransaction :: TransactionResult -> IO TransactionId
stoppedTransaction = \case
  StoppedAmbiguous token _ _ -> pure token
  other -> assertFailure ("expected the rollout to stop, got " <> show other) >> fail "stop"

failures :: [FeedEntry] -> [(ScopeId, ChangeFailure)]
failures events = [(entry ^. #envelope . #resource . #scope, value) | entry <- events, ChangeFailedPayload value <- [entry ^. #envelope . #payload]]

kindOf :: FeedEntry -> EventKind
kindOf entry = payloadKind (entry ^. #envelope . #payload)

changes :: [FeedEntry] -> [Applied]
changes events =
  [ Applied (entry ^. #envelope . #resource . #scope) value
  | entry <- events
  , ChangeAppliedPayload value <- [entry ^. #envelope . #payload]
  ]
