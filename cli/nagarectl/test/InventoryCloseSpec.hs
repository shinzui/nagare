-- | ADR 26: closing a stopped transaction by per-operation proof. A scope in
-- which something took effect is kept; a scope in which nothing did reverts
-- to the review's base, with its own retained additions removed; a close whose
-- head release fails is completed by running close again.
module InventoryCloseSpec (inventoryCloseTests) where

import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE
import InventoryObjectOpsSpec (fakeObjectOps)
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal (mkTransactionId, transactionIdText)
import Nagare.Inventory.Lifecycle (decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Test.World.Adversary
import Nagare.Test.World.Store (faultingObjectOps)
import Test.Tasty
import Test.Tasty.HUnit

inventoryCloseTests :: TestTree
inventoryCloseTests =
  testGroup
    "close by per-operation proof (ADR 26)"
    [ testCase "a landed update is kept, and a refused head release is completed by closing again" $ do
        -- A dry run counts the store writes up to the close's head release.
        writes <- landedClose []
        assertBool "the close wrote to the store" (writes > 0)
        -- The same run refuses the release and its retries.
        _ <- landedClose [(Boundary StorePutCall n, PutRefused) | n <- [writes .. writes + 3]]
        pure ()
    , testCase "a review in which nothing took effect reverts every changed scope and its retained additions" revertedClose
    , testCase "close refuses while an operation is unproved, naming what would resolve it" unknownBlocks
    ]

-- | Admit an update that lands but never becomes ready, stop, and close. With
-- no faults it returns the number of store writes the close made; with the
-- release refused, the first close fails and a repeated close completes it.
landedClose :: [(Boundary, Fault)] -> IO Int
landedClose releaseFaults = do
  adversary <- newAdversary releaseFaults
  base <- fakeObjectOps
  store <- newObjectStore (faultingObjectOps adversary base) fixtureBinding "close-test" Nothing >>= expectRight
  _ <- initializeStore store fixtureBinding "close-test" >>= expectRight
  let owner = ok (mkScopeId Application "web")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      service digest = member owner cluster "service" digest
      landed = ok (mkPhysicalIdentity "landed-uid")
      registry =
        recordingRegistryWith
          (\_ _ -> pure (Right ()))
          (\operation _ -> pure (if plannedAction operation == UpdateResource then AdapterEffectAmbiguous "readiness wait timed out" else AdapterEffectCompleted))
          (\_ _ -> pure (RecoveryLandedUnready landed))
  _ <- converge store registry owner [service "v1"] [(declarationId (service "v1"), ConfirmedAbsent (contentDigest "absent"))]
  before <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  reviewed <- reviewFor store registry owner [service "v2"] [(declarationId (service "v2"), ObservedPresent landed)]
  applied <- applyReviewed store registry reviewed >>= expectRight
  transaction <- case applied of
    StoppedAmbiguous tx _ -> pure tx
    other -> assertFailure ("the update did not stop: " <> show other) >> pure (error "unreachable")
  let input = CloseInput transaction (reviewedDigest reviewed) False
  modifyIORef' adversary (\value -> value {storeArmed = True})
  closed <- closeTransaction store registry input
  writes <- maybe 0 id . Map.lookup StorePutCall . counts <$> readIORef adversary
  record <- case (releaseFaults, closed) of
    ([], Right record) -> pure record
    ([], Left errors) -> assertFailure ("close refused: " <> show (NE.toList errors)) >> pure (error "unreachable")
    (_, Right _) -> assertFailure "the close succeeded although its head release was refused" >> pure (error "unreachable")
    (_, Left _) -> do
      -- The close was journalled; closing again only completes the release.
      closeTransaction store registry input >>= either (\errors -> assertFailure ("the repeated close was refused: " <> show (NE.toList errors)) >> pure (error "unreachable")) pure
  Map.elems (closedClasses record) @?= [ClassLanded landed]
  Map.elems (closedScopes record) @?= [KeepDesired]
  after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  headActiveTransaction after @?= Nothing
  headConverged after @?= headConverged before
  headIncarnations after @?= headIncarnations before
  Map.lookup owner (headAccepted after) @?= Map.lookup owner (reviewDesiredRevisions (reviewedDocument reviewed))
  pure writes

-- | A changed scope whose update was refused at preflight (never started) and
-- a retired scope with retention proofs: nothing took effect, so both revert to
-- the review's base and the retirement's retained additions are removed (H1,
-- H3).
revertedClose :: Assertion
revertedClose = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "revert-test" >>= expectRight
  let web = ok (mkScopeId Application "web")
      jobs = ok (mkScopeId Application "jobs")
      cluster scope = mintResourceId scope (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      service digest = member web (cluster web) "service" digest
      worker = member jobs (cluster jobs) "worker" "w1"
      present = ObservedPresent (ok (mkPhysicalIdentity "uid"))
      recording =
        recordingRegistryWith
          (\operation _ -> pure (if plannedAction operation == UpdateResource then Left "refused before any effect" else Right ()))
          (\_ _ -> pure AdapterEffectCompleted)
          (\_ _ -> pure RecoverySafeToRetry)
      -- Admission re-observes the retained worker.
      registry = ok (mkAdapterRegistry [(ok (lookupAdapter recording KubernetesExecutor)) {adapterObserve = \resources -> pure (observationSet [(resource, present) | resource <- resources])}])
  _ <- converge store registry web [service "v1"] [(declarationId (service "v1"), ConfirmedAbsent (contentDigest "absent"))]
  _ <- converge store registry jobs [worker] [(declarationId worker, ConfirmedAbsent (contentDigest "absent"))]
  before <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  -- One review updates web (refused) and retires jobs (retained).
  history <- loadInventoryHistory store >>= expectRight
  let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))) (ReplaceScope (scopeOf web [service "v2"]) :| [RetireScope jobs RetainResources]))
      facts = ok (observationSet [(declarationId (service "v2"), present), (declarationId worker, present)])
  planning <- loadInventoryPlanningHistory store candidate >>= expectRight
  proposal <- expectRight (decideRetirement candidate planning facts >>= \decisions -> planChanges candidate decisions planning facts)
  reviewed <- publishReviewed store registry proposal
  assertBool "the review retains the retired worker" (Map.member (declarationId worker) (reviewRetentions (reviewedDocument reviewed)))
  applied <- applyReviewed store registry reviewed
  transaction <- case applied of
    Left _ -> do
      admitted <- readHead store >>= expectRight
      maybe (assertFailure "the review was not admitted" >> pure (error "unreachable")) (pure . ok . mkTransactionId) (admitted >>= headActiveTransaction)
    Right (StoppedFailed tx _ _) -> pure tx
    Right (StoppedAmbiguous tx _) -> pure tx
    Right other -> assertFailure ("the refused update did not stop: " <> show other) >> pure (error "unreachable")
  admitted <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  assertBool "admission retained the worker" (Map.member (declarationId worker) (headRetained admitted))
  record <- closeTransaction store registry (CloseInput transaction (reviewedDigest reviewed) False) >>= either (\errors -> assertFailure ("close refused: " <> show (NE.toList errors)) >> pure (error "unreachable")) pure
  Map.elems (closedScopes record) @?= [RevertTo (Map.lookup jobs (headAccepted before)), RevertTo (Map.lookup web (headAccepted before))]
  after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  headActiveTransaction after @?= Nothing
  headAccepted after @?= headAccepted before
  headRetained after @?= headRetained before
  headConverged after @?= headConverged before

-- | An ambiguous update whose adapter cannot settle it: close refuses and the
-- transaction stays active.
unknownBlocks :: Assertion
unknownBlocks = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "unknown-test" >>= expectRight
  let owner = ok (mkScopeId Application "web")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      service digest = member owner cluster "service" digest
      registry =
        recordingRegistryWith
          (\_ _ -> pure (Right ()))
          (\operation _ -> pure (if plannedAction operation == UpdateResource then AdapterEffectAmbiguous "provider unreachable" else AdapterEffectCompleted))
          (\_ _ -> pure (RecoveryUnresolved "the provider cannot be observed"))
  _ <- converge store registry owner [service "v1"] [(declarationId (service "v1"), ConfirmedAbsent (contentDigest "absent"))]
  reviewed <- reviewFor store registry owner [service "v2"] [(declarationId (service "v2"), ObservedPresent (ok (mkPhysicalIdentity "uid")))]
  transaction <-
    applyReviewed store registry reviewed >>= expectRight >>= \case
      StoppedAmbiguous tx _ -> pure tx
      other -> assertFailure ("the update did not stop: " <> show other) >> pure (error "unreachable")
  closeTransaction store registry (CloseInput transaction (reviewedDigest reviewed) False) >>= \case
    Left errors -> assertBool ("unexpected refusal: " <> show (NE.toList errors)) (any ((== "unknown-operation") . admissionErrorCode) (NE.toList errors))
    Right record -> assertFailure ("an unproved operation was closed: " <> show record)
  after <- readHead store >>= expectRight
  (after >>= headActiveTransaction) @?= Just (transactionIdText transaction)

-- Fixtures ---------------------------------------------------------------

converge :: InventoryStore -> AdapterRegistry -> ScopeId -> [Declaration] -> [(ResourceId, ResourceObservation)] -> IO TransactionResult
converge store registry owner members facts = do
  reviewed <- reviewFor store registry owner members facts
  applyReviewed store registry reviewed >>= expectRight

reviewFor :: InventoryStore -> AdapterRegistry -> ScopeId -> [Declaration] -> [(ResourceId, ResourceObservation)] -> IO ReviewedPlan
reviewFor store registry owner members facts = do
  history <- loadInventoryHistory store >>= expectRight
  let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))) (ReplaceScope (scopeOf owner members) :| []))
  planning <- loadInventoryPlanningHistory store candidate >>= expectRight
  proposal <- expectRight (planChanges candidate noLifecycleDecisions planning (ok (observationSet facts)))
  publishReviewed store registry proposal

publishReviewed :: InventoryStore -> AdapterRegistry -> ChangeProposal -> IO ReviewedPlan
publishReviewed store registry proposal = do
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  expectRight (verifyReview published bundle)

reviewedDigest :: ReviewedPlan -> ContentDigest
reviewedDigest = contentDigest . encodeReviewDocument . reviewedDocument

scopeOf :: ScopeId -> [Declaration] -> ScopeDeclaration
scopeOf owner members = ok (mkScopeDeclaration owner [ResourceBundle members [] [] [] [] []])

member :: ScopeId -> ResourceId -> Text -> Text -> Declaration
member owner cluster role digest =
  Managed
    ManagedResource
      { identity = mintResourceId owner (ok (mkLogicalKey role)) (ok (mkName "resource"))
      , owner = owner
      , executor = KubernetesExecutor
      , address = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "system"))) (ok (mkName role))
      , aliases = []
      , spec = NativeObject (contentDigest (TE.encodeUtf8 digest))
      , lifecycle = Retain
      , dataPolicy = Stateless
      , sensitivity = Public
      , dependencies = []
      , delegations = []
      , source = SourceLocation "test" role
      }

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
