-- | EP-183 M2 (ADR 22 amendment): one reviewed transaction ingests every
-- verified, not-yet-ingested scheduled run. Each run keeps its own scope, Job
-- and proof, so a batch stopped at any operation leaves each run accepted or
-- not on its own, and the next batch picks up exactly the runs left over.
module Nagare.Test.Backup.BatchIngest
  ( batchIngestTests
  )
where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..), scheduledReceiptExpectationFromCronJob)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Inventory.Plan
import Nagare.Inventory.ScheduledIngest
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures (cronId, databaseBackend, databaseNative, databaseScope, databaseScopeId, pvcId, signingId, statefulId)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

batchIngestTests :: [TestTree]
batchIngestTests =
  [ testCase "a batch ingests only listed, complete, not-yet-ingested runs" pendingRuns
  , testCase "a batch compiles each run exactly as single ingestion does, and refuses a repeat or a mixed source" batchCompile
  , testCase "a batch ingestion stopped at each operation leaves each run accepted or not on its own" stoppedBatch
  ]

runs :: [Text]
runs = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", "33333333-3333-3333-3333-333333333333"]

pendingRuns :: Assertion
pendingRuns = do
  let both run = [(run, True), (run, False)]
      acceptedScope = ok (mkScopeDeclaration (ok (mkScopeId Standalone "accepted")) [])
      accepted = Map.singleton (runs !! 0) acceptedScope
  pendingScheduledRuns Map.empty (concatMap both runs) @?= runs
  -- Accepted runs are never candidates.
  pendingScheduledRuns accepted (concatMap both runs) @?= drop 1 runs
  -- A half-written pair is left unresolved.
  pendingScheduledRuns Map.empty ((runs !! 1, True) : both (runs !! 2)) @?= [runs !! 2]
  pendingScheduledRuns Map.empty [(runs !! 1, False)] @?= []

-- | The accepted source, as the model's database binds it.
uids :: (PhysicalIdentity, PhysicalIdentity, PhysicalIdentity, PhysicalIdentity)
uids = (physical "stateful-uid", physical "pvc-uid", physical "cron-uid", physical "signing-uid")
  where
    physical = ok . mkPhysicalIdentity

expectation :: ScheduledReceiptExpectation
expectation =
  let (stateful, pvc, _, _) = uids
   in ok (scheduledReceiptExpectationFromCronJob databaseBackend "personal" "pg" stateful pvc (snd (databaseNative Map.! cronId)))

request :: ScopeRevision -> Text -> ScheduledIngestRequest
request revision run =
  let (stateful, pvc, cron, signing) = uids
   in ScheduledIngestRequest
        { ingestSourceKind = IngestDatabase "pg" (stateful)
        , ingestNamespace = "personal"
        , ingestBackupId = run
        , ingestSourceRevision = revision
        , ingestPvcUid = pvc
        , ingestScheduleUid = cron
        , ingestSigningUid = signing
        , ingestEvidence =
            ScheduledReceiptEvidence
              { scheduledReceipt =
                  ScheduledBackupReceipt
                    (ok (mkPhysicalIdentity run))
                    (scheduledObjectPrefix expectation <> run <> "." <> scheduledFormat expectation)
                    (T.replicate 64 "0")
                    (scheduledPolicyRevision expectation)
                    Nothing
              , scheduledObjectVersion = "1"
              , scheduledReceiptVersion = "1"
              , scheduledObjectLength = 1
              , scheduledReceiptLength = 1
              , scheduledReceiptDigest = contentDigest (TE.encodeUtf8 run)
              }
        , ingestBackend = databaseBackend
        , ingestSource = SourceLocation "batch" run
        , ingestAcceptedIncarnations = Map.fromList [(statefulId, stateful), (pvcId, pvc), (cronId, cron), (signingId, signing)]
        }

anyRevision :: ScopeRevision
anyRevision = ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest "database")

batchCompile :: Assertion
batchCompile = do
  let requests = fmap (request anyRevision) (NE.fromList runs)
  compiled <- expectRight (compileScheduledIngestBatch requests databaseScope databaseNative)
  singles <- traverse (\one -> expectRight (compileScheduledIngestScope one databaseScope databaseNative)) requests
  compiled @?= singles
  length (Map.keys (Map.fromList [(scopeId scope, ()) | (scope, _) <- toList compiled])) @?= length runs
  assertBool "a repeated run was batched" (isLeft (compileScheduledIngestBatch (request anyRevision (runs !! 0) :| [request anyRevision (runs !! 0)]) databaseScope databaseNative))
  let otherRevision = ScopeRevision (ok (mkScopeGeneration 2)) (contentDigest "database-2")
  assertBool "two source revisions were batched" (isLeft (compileScheduledIngestBatch (request anyRevision (runs !! 0) :| [request otherRevision (runs !! 1)]) databaseScope databaseNative))
  let replaced = (request anyRevision (runs !! 1)) {ingestPvcUid = ok (mkPhysicalIdentity "other-pvc")}
  assertBool "two incarnations were batched" (isLeft (compileScheduledIngestBatch (request anyRevision (runs !! 0) :| [replaced]) databaseScope databaseNative))

-- | ADR 26: stop the batch at each of its operations with the provider
-- unreachable, then take the exit per-operation proof selects. A proved
-- operation resumes to convergence and every run is accepted; a terminal
-- failure closes, keeping each scope in which something took effect and
-- reverting the rest, so the next batch names exactly the runs not accepted.
stoppedBatch :: Assertion
stoppedBatch = do
  (_, reviewedProbe) <- seededBatch completing
  let operations = map (plannedOperationId . reviewPlannedOperation) (reviewOperations (reviewedDocument reviewedProbe))
  assertBool "the batch review has an operation per run and more" (length operations >= length runs)
  forM_ operations $ \stopAt -> forM_ [False, True] $ \terminal -> do
    let label = T.unpack (operationIdText stopAt) <> (if terminal then " (terminal)" else " (proved)")
        interrupted operation _ = pure (if plannedOperationId operation == stopAt then AdapterEffectAmbiguous "interrupted" else AdapterEffectCompleted)
        unreachable operation _ = pure (if plannedOperationId operation == stopAt then RecoveryUnresolved "provider unreachable" else RecoveryProvedComplete (proof operation))
        answer operation
          | plannedOperationId operation /= stopAt = RecoveryProvedComplete (proof operation)
          | terminal = RecoveryTerminalFailure (ok (mkPhysicalIdentity "failed-ingestion-job"))
          | otherwise = RecoveryProvedComplete (proof operation)
        registry = recordingRegistryWith (\_ _ -> pure (Right ())) interrupted unreachable
        answering = recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\operation _ -> pure (answer operation))
    (store, reviewed) <- seededBatch registry
    transaction <-
      applyReviewed store registry reviewed >>= expectRight >>= \case
        StoppedAmbiguous tx _ -> pure tx
        other -> assertFailure ("the batch did not stop at " <> label <> ": " <> show other) >> pure (error "unreachable")
    if terminal
      then do
        _ <- closeTransaction store answering (CloseInput transaction (reviewDigestOf reviewed) False Nothing) >>= either (\errors -> assertFailure ("close refused at " <> label <> ": " <> show (NE.toList errors)) >> pure (error "unreachable")) pure
        pure ()
      else
        resumeTransaction store answering transaction >>= expectRight >>= \case
          Converged _ -> pure ()
          other -> assertFailure ("the proved batch did not resume at " <> label <> ": " <> show other)
    after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
    headActiveTransaction after @?= Nothing
    history <- loadInventoryHistory store >>= expectRight
    let acceptedRuns =
          Map.fromList
            [ (run, scope)
            | (_, (_, scope)) <- Map.toList (historyAccepted history)
            , Just run <- [Map.lookup "scheduled.backup.id" (scopeOverrides scope)]
            ]
        leftOver = pendingScheduledRuns acceptedRuns (concat [[(run, True), (run, False)] | run <- runs])
    -- Every run is either accepted or offered to the next batch, never both.
    assertBool ("a run is both accepted and pending at " <> label) (all (`Map.notMember` acceptedRuns) leftOver)
    length leftOver + Map.size acceptedRuns @?= length runs
    -- A resumed batch accepts every run; a terminal stop keeps at least the
    -- run whose Job failed after taking effect.
    if terminal then assertBool ("nothing was kept at " <> label) (Map.size acceptedRuns >= 1) else leftOver @?= []

-- | A store whose accepted history holds the database, and a published review
-- of one batch ingesting every run.
seededBatch :: AdapterRegistry -> IO (InventoryStore, ReviewedPlan)
seededBatch registry = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "batch-ingest-test" >>= expectRight
  seeded <- reviewScopes store completing [databaseScope]
  applyReviewed store completing seeded >>= expectRight >>= \case
    Converged _ -> pure ()
    other -> assertFailure ("seeding the database did not converge: " <> show other)
  history <- loadInventoryHistory store >>= expectRight
  revision <- maybe (assertFailure "the database is not accepted" >> pure (error "unreachable")) (pure . fst) (Map.lookup databaseScopeId (historyAccepted history))
  compiled <- expectRight (compileScheduledIngestBatch (fmap (request revision) (NE.fromList runs)) databaseScope databaseNative)
  reviewed <- reviewScopes store registry (map fst (toList compiled))
  pure (store, reviewed)

completing :: AdapterRegistry
completing = recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\operation _ -> pure (RecoveryProvedComplete (proof operation)))

reviewScopes :: InventoryStore -> AdapterRegistry -> [ScopeDeclaration] -> IO ReviewedPlan
reviewScopes store registry scopes = do
  history <- loadInventoryHistory store >>= expectRight
  replacements <- maybe (assertFailure "no scopes to review" >> pure (error "unreachable")) pure (NE.nonEmpty (map ReplaceScope scopes))
  let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))) replacements)
      facts = [(declarationId declared, ConfirmedAbsent (contentDigest "absent")) | scope <- scopes, bundle <- scopeBundles scope, declared@(Managed _) <- declarations bundle]
  planning <- loadInventoryPlanningHistory store candidate >>= expectRight
  proposal <- expectRight (planChanges candidate noLifecycleDecisions planning (ok (observationSet facts)))
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  expectRight (verifyReview published bundle)

reviewDigestOf :: ReviewedPlan -> ContentDigest
reviewDigestOf = contentDigest . encodeReviewDocument . reviewedDocument

proof :: PlannedOperation -> ContentDigest
proof = contentDigest . TE.encodeUtf8 . operationIdText . plannedOperationId

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
