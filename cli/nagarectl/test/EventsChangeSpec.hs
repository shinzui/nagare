-- | EP-276 M1: every converged reviewed transaction is one @change.applied@
-- event, through the real planner, executor, journal and feed.
module EventsChangeSpec (eventsChangeTests) where

import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import EventsDeploymentSpec
import Nagare.Dsl.Prelude
import Nagare.Events.Change (changeKey, changeProducer)
import Nagare.Events.Envelope (eventIdFor)
import Nagare.Events.Read (FeedEntry)
import Nagare.Events.Source
import Nagare.Inventory.Actor (Actor (..), ReviewSource (..))
import Nagare.Inventory.DelegatedPlanning (attributeReview)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..))
import Nagare.Inventory.Journal (TransactionId, mkTransactionId)
import Nagare.Inventory.Store (ScopeRevision (..))
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
    , testCase "a named actor's review names the actor and the source it came from" $ withWorld $ \world -> do
        let source = ReviewSource (Just "github.com/example/notes") (Just "0123abc") Nothing
        _ <- deployWith world (attributeReview (OperatorActor (Just "alice")) (Just source)) [notes (releaseLog ["r1"] "r1") "v1"]
        [change] <- changes <$> feedEntries world
        change ^. #payload . #actor @?= OperatorActor (Just "alice")
        change ^. #payload . #source @?= ChangeSource (Just "github.com/example/notes") (Just "0123abc") Nothing
    , testCase "a deployer's change names the deployer; retiring a scope is a retirement from its converged revision" $ do
        let before = ScopeRevision (checked (mkScopeGeneration 1)) (contentDigest "before")
            input =
              SourceInput
                { context = binding ^. #identity
                , transaction = checked (mkTransactionId "tx-deployer")
                , review = contentDigest "review"
                , payloadIdentity = "operator-cli"
                , baseRevisions = Map.fromList [(notesScope, before)]
                , desiredRevisions = Map.empty
                , convergedBefore = Map.fromList [(notesScope, before)]
                , operations = Map.empty
                , steps = []
                , actor = DeployerActor "ci"
                , source = Nothing
                , retained = Map.empty
                , collected = Map.empty
                , journal = []
                , members = Map.empty
                , scopes = Map.empty
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
