-- | ADR 26: closing a stopped transaction by per-operation proof. A scope in
-- which something took effect is kept; a scope in which nothing did reverts
-- to the review's base, with its own retained additions removed; a close whose
-- head release fails is completed by running close again.
module InventoryCloseSpec (inventoryCloseTests) where

import Data.Either (isLeft)
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
import Nagare.Inventory.Journal (TransactionId, mkTransactionId, transactionIdText)
import Nagare.Inventory.Lifecycle (decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
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
    , testCase "close refuses while an operation is unproved, naming what would resolve it; an attested close then accepts nothing" unknownBlocks
    , testCase "an attestation file is strict" $ do
        let decode = decodeAttestation . TE.encodeUtf8
        decode "{\"version\":1,\"operator\":\"op\",\"reason\":\"why\",\"evidence\":[{\"note\":\"log\"}]}" @?= Right (Attestation "op" "why" [AttestedEvidence "log" Nothing])
        assertBool "unknown field" (isLeft (decode "{\"version\":1,\"operator\":\"op\",\"reason\":\"why\",\"evidence\":[],\"accept\":true}"))
        assertBool "empty operator" (isLeft (decode "{\"version\":1,\"operator\":\" \",\"reason\":\"why\",\"evidence\":[]}"))
        assertBool "version" (isLeft (decode "{\"version\":2,\"operator\":\"op\",\"reason\":\"why\",\"evidence\":[]}"))
    , testCase "closing a refused update keeps a created member owned and admits no update as never-started (H2)" keepsCompletedEffects
    , testCase "abandoning a refused correction after a stop reverts to the correction's base (H1)" revertsToReviewBase
    , testCase "an abandon whose head release was refused is completed by repeating it (U1)" $ do
        writes <- abandonWithRefusedRelease []
        _ <- abandonWithRefusedRelease [(Boundary StorePutCall n, PutRefused) | n <- [writes .. writes + 3]]
        pure ()
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
      -- Ordered after the update, so it never starts; this registry cannot
      -- confirm its absence, so close must not admit it as never-started.
      extra = case member owner cluster "extra" "e1" of
        Managed value -> Managed (value {dependencies = [OrderedAfter (declarationId (service "v1"))]})
        other -> other
      landed = ok (mkPhysicalIdentity "landed-uid")
      registry =
        recordingRegistryWith
          (\_ _ -> pure (Right ()))
          (\operation _ -> pure (if plannedAction operation == UpdateResource then AdapterEffectAmbiguous "readiness wait timed out" else AdapterEffectCompleted))
          (\_ _ -> pure (RecoveryLandedUnready landed))
  _ <- converge store registry owner [service "v1"] [(declarationId (service "v1"), ConfirmedAbsent (contentDigest "absent"))]
  before <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  reviewed <- reviewFor store registry owner [service "v2", extra] [(declarationId (service "v2"), ObservedPresent landed), (declarationId extra, ConfirmedAbsent (contentDigest "absent"))]
  applied <- applyReviewed store registry reviewed >>= expectRight
  transaction <- case applied of
    StoppedAmbiguous tx _ -> pure tx
    other -> assertFailure ("the update did not stop: " <> show other) >> pure (error "unreachable")
  -- A recorded incarnation that close must leave alone.
  stopped <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  let incarnations = Map.singleton (declarationId (service "v1")) landed
  _ <- replaceHeadIfGenerationMatches store (Just (headGeneration stopped)) stopped {headGeneration = headGeneration stopped + 1, headIncarnations = incarnations} >>= expectRight
  let input = CloseInput transaction (reviewedDigest reviewed) False Nothing
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
  assertBool "classes" (all (`elem` Map.elems (closedClasses record)) [ClassLanded landed, ClassNeverStarted] && Map.size (closedClasses record) == 2)
  closedNeverStarted record @?= mempty
  Map.elems (closedScopes record) @?= [KeepDesired]
  after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  headActiveTransaction after @?= Nothing
  headConverged after @?= headConverged before
  headIncarnations after @?= incarnations
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
  record <- closeTransaction store registry (CloseInput transaction (reviewedDigest reviewed) False Nothing) >>= either (\errors -> assertFailure ("close refused: " <> show (NE.toList errors)) >> pure (error "unreachable")) pure
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
  closeTransaction store registry (CloseInput transaction (reviewedDigest reviewed) False Nothing) >>= \case
    Left errors -> assertBool ("unexpected refusal: " <> show (NE.toList errors)) (any ((== "unknown-operation") . admissionErrorCode) (NE.toList errors))
    Right record -> assertFailure ("an unproved operation was closed: " <> show record)
  stuck <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  headActiveTransaction stuck @?= Just (transactionIdText transaction)
  -- §5 (E's U2): the operator attests, and the close accepts nothing.
  let attestation = Attestation "operator@example.test" "the provider's change log shows no write" [AttestedEvidence "provider audit log export" Nothing]
      attested = CloseInput transaction (reviewedDigest reviewed) False (Just attestation)
  record <- closeTransaction store registry attested >>= either (\errors -> assertFailure ("attested close refused: " <> show (NE.toList errors)) >> pure (error "unreachable")) pure
  closedAttestation record @?= Just attestation
  Map.elems (closedScopes record) @?= [KeepDesired]
  closedNeverStarted record @?= mempty
  closed <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  headActiveTransaction closed @?= Nothing
  headAccepted closed @?= headAccepted stuck
  headConverged closed @?= headConverged stuck
  headRetained closed @?= headRetained stuck
  headIncarnations closed @?= headIncarnations stuck
  -- Repeating it only completes the release.
  closeTransaction store registry attested >>= either (\errors -> assertFailure ("repeated close refused: " <> show (NE.toList errors))) (@?= record)

-- | H2: a review creates one member and then has its dependent update refused
-- before any effect. The legacy abandon reset the scope to its converged
-- revision and disowned the created member; close keeps the review's desired
-- revision because something took effect.
keepsCompletedEffects :: Assertion
keepsCompletedEffects = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "h2-test" >>= expectRight
  let owner = ok (mkScopeId Application "web")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      settings digest = member owner cluster "settings" digest
      created = member owner cluster "created" "c1"
      dependent digest = case settings digest of
        Managed value -> Managed (value {dependencies = [OrderedAfter (declarationId created)]})
        other -> other
      registry = refusingUpdates
  _ <- converge store registry owner [settings "v1"] [(declarationId (settings "v1"), ConfirmedAbsent (contentDigest "absent"))]
  reviewed <- reviewFor store registry owner [dependent "v2", created] [(declarationId (settings "v1"), ObservedPresent (ok (mkPhysicalIdentity "settings-uid"))), (declarationId created, ConfirmedAbsent (contentDigest "absent"))]
  transaction <- stoppedTransaction store registry reviewed
  -- Every operation is proved, so an attestation has nothing to decide.
  let unneeded = Attestation "operator@example.test" "unneeded" []
  closeTransaction store registry (CloseInput transaction (reviewedDigest reviewed) False (Just unneeded)) >>= \case
    Left errors -> map admissionErrorCode (NE.toList errors) @?= ["attestation-unneeded"]
    Right record -> assertFailure ("an attestation overrode the proof: " <> show record)
  -- Every target reads absent at close, yet the refused update is no
  -- never-started create, so nothing may be replanned as one.
  let absent = ok (mkAdapterRegistry [(ok (lookupAdapter registry KubernetesExecutor)) {adapterObserve = \resources -> pure (observationSet [(resource, ConfirmedAbsent (contentDigest "absent")) | resource <- resources])}])
  record <- closeTransaction store absent (CloseInput transaction (reviewedDigest reviewed) False Nothing) >>= either (\errors -> assertFailure ("close refused: " <> show (NE.toList errors)) >> pure (error "unreachable")) pure
  closedNeverStarted record @?= mempty
  after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  headActiveTransaction after @?= Nothing
  Map.lookup owner (headAccepted after) @?= Map.lookup owner (reviewDesiredRevisions (reviewedDocument reviewed))

-- | H1: a stop leaves a scope accepted at its first review's desired
-- revision; a correction's update is then refused. The legacy abandon reset
-- the scope to its converged revision, past the stop; close reverts it to the
-- correction's base.
revertsToReviewBase :: Assertion
revertsToReviewBase = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "h1-test" >>= expectRight
  let owner = ok (mkScopeId Application "web")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      settings digest = member owner cluster "settings" digest
      first' = refusingUpdates
  _ <- converge store first' owner [settings "v1"] [(declarationId (settings "v1"), ConfirmedAbsent (contentDigest "absent"))]
  -- A review whose update is refused and closed with nothing taking effect
  -- would revert; instead stop the first change with a landed update so the
  -- scope stays accepted at its desired revision without converging.
  let landed = ok (mkPhysicalIdentity "landed-uid")
      landing =
        recordingRegistryWith
          (\_ _ -> pure (Right ()))
          (\operation _ -> pure (if plannedAction operation == UpdateResource then AdapterEffectAmbiguous "readiness wait timed out" else AdapterEffectCompleted))
          (\_ _ -> pure (RecoveryLandedUnready landed))
  stopped <- reviewFor store landing owner [settings "v2"] [(declarationId (settings "v1"), ObservedPresent landed)]
  stoppedTx <- stoppedTransaction store landing stopped
  _ <- closeTransaction store landing (CloseInput stoppedTx (reviewedDigest stopped) False Nothing) >>= either (\errors -> assertFailure ("close refused: " <> show (NE.toList errors)) >> pure (error "unreachable")) pure
  afterStop <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  -- The correction's update is refused before any effect, then abandoned.
  correction <- reviewFor store first' owner [settings "v3"] [(declarationId (settings "v1"), ObservedPresent landed)]
  transaction <- stoppedTransaction store first' correction
  abandonRefused store first' correction transaction UpdateResource
  after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
  headActiveTransaction after @?= Nothing
  Map.lookup owner (headAccepted after) @?= Map.lookup owner (headAccepted afterStop)

-- | U1: the legacy abandon journalled its decision before its head release; a
-- refused release then left no command that could end the transaction. A
-- repeated abandon (now a close) completes it. With no faults it returns the
-- store writes the abandon made.
abandonWithRefusedRelease :: [(Boundary, Fault)] -> IO Int
abandonWithRefusedRelease releaseFaults = do
  adversary <- newAdversary releaseFaults
  base <- fakeObjectOps
  store <- newObjectStore (faultingObjectOps adversary base) fixtureBinding "u1-test" Nothing >>= expectRight
  _ <- initializeStore store fixtureBinding "u1-test" >>= expectRight
  let owner = ok (mkScopeId Application "web")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      settings digest = member owner cluster "settings" digest
      registry = refusingUpdates
      present = [(declarationId (settings "v1"), ObservedPresent (ok (mkPhysicalIdentity "settings-uid")))]
  _ <- converge store registry owner [settings "v1"] [(declarationId (settings "v1"), ConfirmedAbsent (contentDigest "absent"))]
  reviewed <- reviewFor store registry owner [settings "v2"] present
  transaction <- stoppedTransaction store registry reviewed
  operation <- case [plannedOperationId (reviewPlannedOperation entry) | entry <- reviewOperations (reviewedDocument reviewed)] of
    [selected] -> pure selected
    other -> assertFailure ("expected one operation, found " <> show other) >> pure (error "unreachable")
  let decision = OperatorRecoveryInput transaction operation (reviewedDigest reviewed) AbandonRefusedOperation
  modifyIORef' adversary (\value -> value {storeArmed = True})
  first' <- recordOperatorRecovery store registry decision False
  writes <- maybe 0 id . Map.lookup StorePutCall . counts <$> readIORef adversary
  case (releaseFaults, first') of
    ([], Left errors) -> assertFailure ("abandon refused: " <> show (NE.toList errors))
    (_ : _, Right ()) -> assertFailure "the abandon succeeded although its head release was refused"
    (_ : _, Left _) -> recordOperatorRecovery store registry decision False >>= either (\errors -> assertFailure ("the repeated abandon was refused: " <> show (NE.toList errors))) pure
    _ -> pure ()
  after <- readHead store >>= expectRight
  (after >>= headActiveTransaction) @?= Nothing
  pure writes

-- | Updates are refused at preflight, before any effect; everything else
-- completes.
refusingUpdates :: AdapterRegistry
refusingUpdates =
  recordingRegistryWith
    (\operation _ -> pure (if plannedAction operation == UpdateResource then Left "refused before any effect" else Right ()))
    (\_ _ -> pure AdapterEffectCompleted)
    (\_ _ -> pure RecoverySafeToRetry)

stoppedTransaction :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> IO TransactionId
stoppedTransaction store registry reviewed = do
  _ <- applyReviewed store registry reviewed
  current <- readHead store >>= expectRight
  maybe (assertFailure "the review did not stop with an active transaction" >> pure (error "unreachable")) (pure . ok . mkTransactionId) (current >>= headActiveTransaction)

-- | The legacy abandon-refused-operation decision for the operation with the
-- given action, as an operator's saved decision file names it.
abandonRefused :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> TransactionId -> OperationAction -> Assertion
abandonRefused store registry reviewed transaction action = do
  operation <- case [plannedOperationId (reviewPlannedOperation entry) | entry <- reviewOperations (reviewedDocument reviewed), plannedAction (reviewPlannedOperation entry) == action] of
    [selected] -> pure selected
    other -> assertFailure ("expected one operation, found " <> show other) >> pure (error "unreachable")
  recordOperatorRecovery store registry (OperatorRecoveryInput transaction operation (reviewedDigest reviewed) AbandonRefusedOperation) False
    >>= either (\errors -> assertFailure ("abandon refused: " <> show (NE.toList errors))) pure

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
