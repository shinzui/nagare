-- | EP-183 M2 (ADR 28): scheduled backup retention as a graded target with a
-- reviewed prune. The policy, the prune selection, admission's retention
-- check, the status count, and a prune stopped at every operation.
module Nagare.Test.Backup.Retention
  ( backupRetentionTests
  )
where

import Control.Monad (forM_)
import Data.Either (isLeft, isRight)
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addDays, addUTCTime, defaultTimeLocale, formatTime, fromGregorian, getCurrentTime, secondsToDiffTime)
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..), recoveryPointThresholds)
import Nagare.Inventory.BackupRetention
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Inventory.Plan
import Nagare.Inventory.ScheduledPrune
import Nagare.Inventory.ScheduledStore (ListedObject (..))
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

backupRetentionTests :: [TestTree]
backupRetentionTests =
  [ testCase "retention keeps every point for 48 hours, the newest of each day for 30 days, and the newest" policyKeeps
  , testCase "retention keeps ties and the newest point however old, and refuses a future point" policyEdges
  , testCase "retention never places a point young any objective's breach window past policy" policyWindow
  , testCase "scheduled prune selects only accepted exact pairs past the retention policy" selection
  , testCase "admission refuses a prune of the newest, a recent, a day's newest, or an unsigned run" admissionRefuses
  , testCase "admission checks only new prunes, under the release policy, of one source's unpruned runs" admissionScope
  , testCase "server status counts accepted unpruned runs past policy" statusCount
  , testCase "a saved prune of an expired run is admitted and converges; pruning it again is refused" admittedPrune
  , testCase "a saved prune of the newest run refuses admission before any adapter effect" refusedNewest
  , testCase "a prune stopped at each operation closes by per-operation proof; its receipt recovery passes admission" stoppedPrunes
  ]

-- The fixed clock of the pure tests. The end-to-end tests place the same runs
-- relative to the wall clock, which admission reads.
now :: UTCTime
now = UTCTime (fromGregorian 2026 10 10) (secondsToDiffTime (12 * 3600))

hoursBefore :: UTCTime -> Integer -> UTCTime
hoursBefore clock hours = addUTCTime (fromInteger (negate (hours * 3600))) clock

hoursAgo :: Integer -> UTCTime
hoursAgo = hoursBefore now

-- | Ten days before, at this hour of that day.
tenDaysAt :: Integer -> UTCTime
tenDaysAt = tenDaysBefore now

tenDaysBefore :: UTCTime -> Integer -> UTCTime
tenDaysBefore clock hour = UTCTime (addDays (-10) (utctDay clock)) (secondsToDiffTime (hour * 3600))

-- | Name, signed recovery point (Nothing: a v4 receipt), past policy.
runsAt :: UTCTime -> [(Text, Maybe UTCTime, Bool)]
runsAt clock =
  [ ("forty-days", Just (hoursBefore clock (40 * 24)), True)
  , ("ten-days-morning", Just (tenDaysBefore clock 8), True)
  , ("ten-days-evening", Just (tenDaysBefore clock 20), False)
  , ("three-days", Just (hoursBefore clock 72), False)
  , ("forty-seven-hours", Just (hoursBefore clock 47), False)
  , ("one-hour", Just (hoursBefore clock 1), False)
  , ("unsigned", Nothing, False)
  ]

runs :: [(Text, Maybe UTCTime, Bool)]
runs = runsAt now

signedRuns :: [(Text, UTCTime)]
signedRuns = [(name, time) | (name, Just time, _) <- runs]

policyKeeps :: Assertion
policyKeeps = do
  split <- expectRight (splitByRetention standardRetention HourlyRecoveryPoint now signedRuns)
  pastPolicy split @?= ["forty-days", "ten-days-morning"]
  kept split @?= ["one-hour", "forty-seven-hours", "three-days", "ten-days-evening"]
  retentionPolicyText standardRetention @?= "all-172800s,daily-2592000s,newest"

policyEdges :: Assertion
policyEdges = do
  splitByRetention standardRetention HourlyRecoveryPoint now ([] :: [(Text, UTCTime)]) @?= Right (RetentionSplit [] [])
  -- The newest point is kept even when every point is older than 30 days.
  old <- expectRight (splitByRetention standardRetention DailyRecoveryPoint now [("a" :: Text, hoursAgo 1000), ("b", hoursAgo 2000)])
  old @?= RetentionSplit ["a"] ["b"]
  -- Two points tied for a day's newest time are both kept.
  tied <- expectRight (splitByRetention standardRetention HourlyRecoveryPoint now [("x" :: Text, tenDaysAt 20), ("y", tenDaysAt 20), ("z", tenDaysAt 1), ("n", hoursAgo 1)])
  pastPolicy tied @?= ["z"]
  assertBool "a future point was graded" (isLeft (splitByRetention standardRetention HourlyRecoveryPoint now [("f" :: Text, addUTCTime 60 now)]))

-- A policy shorter than an objective's breach window still keeps that window.
policyWindow :: Assertion
policyWindow = forM_ [minBound .. maxBound] $ \objective -> do
  let (_, breach) = recoveryPointThresholds objective
      short = RetentionPolicy {keepAllFor = 60, keepDailyFor = 0}
      young = [(T.pack (show minutes), addUTCTime (fromInteger (negate (minutes * 60))) now) | minutes <- [1, 30 .. breach `div` 60 - 1]]
  split <- expectRight (splitByRetention short objective now young)
  pastPolicy split @?= []
  assertBool "the standard keep-all window is shorter than a breach window" (keepAllFor standardRetention >= fromInteger breach)

-- Receipt scopes as ingestion accepts them.
sourceScope :: ScopeId
sourceScope = ok (mkScopeId Standalone "scheduled-prune-source")

-- | A run's Job UID: lower-case hex in UUID form.
runId :: Text -> Text
runId name = T.intercalate "-" [T.take 8 raw, T.take 4 (T.drop 8 raw), T.take 4 (T.drop 12 raw), T.take 4 (T.drop 16 raw), T.take 12 (T.drop 20 raw)]
  where
    raw = digestText (contentDigest (TE.encodeUtf8 name))

bucketAddress, keyPrefix :: Text
bucketAddress = "s3://backups/"
keyPrefix = "databases/mydb/"

objectKey, receiptKey :: Text -> Text
objectKey name = keyPrefix <> runId name <> ".sql.gz"
receiptKey name = objectKey name <> ".receipt.json"

receiptOwner :: Text -> ScopeId
receiptOwner name = ok (mkScopeId Standalone ("database-scheduled-receipt-personal-mydb-" <> name))

receiptFields :: Text -> Maybe UTCTime -> Map.Map Text Text
receiptFields name point =
  Map.fromList
    ( [ ("scheduled.backup.source.scope", scopeIdText sourceScope)
      , ("scheduled.backup.id", runId name)
      , ("scheduled.backup.object", bucketAddress <> objectKey name)
      , ("scheduled.backup.object.version", "object-version-" <> name)
      , ("scheduled.backup.object.length", "123")
      , ("scheduled.backup.object.sha256", T.replicate 64 "a")
      , ("scheduled.backup.receipt", bucketAddress <> receiptKey name)
      , ("scheduled.backup.receipt.version", "receipt-version-" <> name)
      , ("scheduled.backup.receipt.length", "456")
      , ("scheduled.backup.receipt.digest", T.replicate 64 "b")
      ]
        <> [("scheduled.backup.recovery.point", T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" time)) | Just time <- [point]]
    )

receiptScope :: Text -> Maybe UTCTime -> ScopeDeclaration
receiptScope name point = withScopeOverrides (receiptFields name point) (scopeOf (receiptOwner name) [member (receiptOwner name) "receipt"])

receiptScopesAt :: UTCTime -> [ScopeDeclaration]
receiptScopesAt clock = [receiptScope name point | (name, point, _) <- runsAt clock]

receiptScopes :: [ScopeDeclaration]
receiptScopes = receiptScopesAt now

selection :: Assertion
selection = do
  let listedFor name =
        [ ListedObject (objectKey name) (hoursAgo 0)
        , ListedObject (receiptKey name) (hoursAgo 0)
        ]
      listed = concatMap (\(name, _, _) -> listedFor name) runs
      select protected scopes entries =
        selectScheduledPruneCandidates sourceScope bucketAddress (bucketAddress <> keyPrefix) "sql.gz" standardRetention HourlyRecoveryPoint now protected scopes entries
  candidates <- expectRight (select Set.empty receiptScopes listed)
  map scheduledPruneId candidates @?= map runId ["forty-days", "ten-days-morning"]
  map scheduledPruneObjectVersion candidates @?= ["object-version-forty-days", "object-version-ten-days-morning"]
  assertBool
    "an unknown object passed the complete-listing guard"
    (isLeft (select Set.empty receiptScopes (listed <> [ListedObject (keyPrefix <> "stray") now])))
  assertBool "a missing receipt passed the complete-listing guard" (isLeft (select Set.empty receiptScopes (drop 1 listed)))
  -- A run uploaded after the newest accepted one is tolerated and never a
  -- candidate; an older un-ingested run refuses until it is ingested.
  let uningested time = [ListedObject (objectKey "uningested") time, ListedObject (receiptKey "uningested") time]
  meanwhile <- expectRight (select Set.empty receiptScopes (listed <> uningested (addUTCTime 60 (hoursAgo 0))))
  map scheduledPruneId meanwhile @?= map scheduledPruneId candidates
  assertBool "an older un-ingested run was tolerated" (isLeft (select Set.empty receiptScopes (listed <> uningested (hoursAgo 1))))
  -- A run an accepted restore depends on stays, and an independent one goes.
  protectedOnly <- expectRight (select (Set.singleton (scopeIdText (receiptOwner "forty-days"))) receiptScopes listed)
  map scheduledPruneId protectedOnly @?= [runId "ten-days-morning"]
  -- A malformed signed time refuses rather than counting as unsigned.
  let malformed = withScopeOverrides (Map.insert "scheduled.backup.recovery.point" "yesterday" (receiptFields "one-hour" Nothing)) (scopeOf (receiptOwner "one-hour") [])
  assertBool "a malformed recovery point was trusted" (isLeft (select Set.empty (malformed : filter ((/= receiptOwner "one-hour") . scopeId) receiptScopes) listed))

-- | A prune scope as `db prune-scheduled-backups` compiles it, reduced to the
-- fields admission reads, with one Job and its prune proof.
pruneScope :: Text -> [(Text, Text)] -> ScopeDeclaration
pruneScope name extra =
  withScopeOverrides
    ( Map.fromList
        ( [ ("scheduled.prune.backup.scope", scopeIdText (receiptOwner name))
          , ("scheduled.prune.policy.scope", scopeIdText sourceScope)
          , ("scheduled.prune.policy.retention", retentionPolicyText standardRetention)
          ]
            <> extra
        )
    )
    (ok (mkScopeDeclaration owner [ResourceBundle [job] [] [] [] [proofOperation] []]))
  where
    owner = ok (mkScopeId Standalone ("database-scheduled-prune-personal-mydb-" <> name))
    job = member owner "prune-job"
    proofOperation =
      DeclaredOperation
        (mintResourceId owner (ok (mkLogicalKey "prune")) (ok (mkName "prune")))
        (declarationId job :| [])
        [ContentInput (contentDigest (TE.encodeUtf8 name))]
        OperatorRecovery
        PruneData

acceptedOf :: [ScopeDeclaration] -> Map.Map ScopeId (ScopeRevision, ScopeDeclaration)
acceptedOf scopes = Map.fromList [(scopeId scope, (ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest (TE.encodeUtf8 (scopeIdText (scopeId scope)))), scope)) | scope <- scopes]

admissionRefuses :: Assertion
admissionRefuses = do
  let admit' reviewed = scheduledPruneRetentionAdmission standardRetention now (acceptedOf receiptScopes) reviewed
  forM_ [(name, past) | (name, _, past) <- runs] $ \(name, past) ->
    assertBool
      ("admission of " <> T.unpack name <> " was " <> show (admit' [pruneScope name []]))
      ((if past then isRight else isLeft) (admit' [pruneScope name []]))
  -- Several expired runs prune together; one kept run refuses the whole review.
  admit' [pruneScope "forty-days" [], pruneScope "ten-days-morning" []] @?= Right ()
  assertBool "a kept run rode along with an expired one" (isLeft (admit' [pruneScope "forty-days" [], pruneScope "one-hour" []]))

admissionScope :: Assertion
admissionScope = do
  let admit' accepted reviewed = scheduledPruneRetentionAdmission standardRetention now (acceptedOf accepted) reviewed
      recovery = pruneScope "one-hour" [("scheduled.prune.recovery.review", digestText (contentDigest "failed"))]
  -- Receipt recovery of an admitted partial prune is not a new prune.
  admit' receiptScopes [recovery] @?= Right ()
  assertBool "another policy was admitted" (isLeft (admit' receiptScopes [pruneScope "forty-days" [("scheduled.prune.policy.retention", "all-3600s,daily-0s,newest")]]))
  assertBool "another source was admitted" (isLeft (admit' receiptScopes [pruneScope "forty-days" [("scheduled.prune.policy.scope", "elsewhere")]]))
  assertBool "an unaccepted run was admitted" (isLeft (admit' receiptScopes [pruneScope "never-ingested" []]))
  -- Once an accepted prune names a run, it is neither pruned again nor counted:
  -- with the evening run pruned, the morning run is that day's newest.
  let prunedEvening = receiptScopes <> [pruneScope "ten-days-evening" []]
  assertBool "a pruned run was pruned again" (isLeft (admit' prunedEvening [pruneScope "ten-days-evening" []]))
  assertBool "a day's surviving newest run was prunable" (isLeft (admit' prunedEvening [pruneScope "ten-days-morning" []]))

statusCount :: Assertion
statusCount = do
  acceptedPastPolicy standardRetention now sourceScope receiptScopes @?= Right (map receiptOwner ["forty-days", "ten-days-morning"])
  acceptedPastPolicy standardRetention now sourceScope (receiptScopes <> [pruneScope "forty-days" []]) @?= Right [receiptOwner "ten-days-morning"]
  acceptedPastPolicy standardRetention now (ok (mkScopeId Standalone "other-source")) receiptScopes @?= Right []
  retentionDetail standardRetention 2 @?= "2 accepted scheduled recovery point(s) past policy (all-172800s,daily-2592000s,newest); review them with db prune-scheduled-backups"

-- End to end through the shared admission, with a recording registry.

-- | A store whose accepted history holds every run's receipt scope, the runs
-- placed relative to the wall clock.
seededStore :: IO InventoryStore
seededStore = do
  wall <- getCurrentTime
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "retention-test" >>= expectRight
  forM_ (receiptScopesAt wall) $ \scope -> do
    reviewed <- reviewScope store completing scope
    applyReviewed store completing reviewed >>= expectRight >>= \case
      Converged _ -> pure ()
      other -> assertFailure ("seeding a receipt did not converge: " <> show other)
  pure store

completing :: AdapterRegistry
completing = recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\operation _ -> pure (RecoveryProvedComplete (proof operation)))

admittedPrune :: Assertion
admittedPrune = do
  store <- seededStore
  calls <- newIORef (0 :: Int)
  let registry = recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> modifyIORef' calls (+ 1) >> pure AdapterEffectCompleted) (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
  reviewed <- reviewScope store registry (pruneScope "forty-days" [])
  applyReviewed store registry reviewed >>= expectRight >>= \case
    Converged _ -> pure ()
    other -> assertFailure ("the expired prune did not converge: " <> show other)
  readIORef calls >>= assertBool "the prune ran no operation" . (> 0)
  again <- reviewScope store registry (pruneScope "forty-days" [("prune.again", "1")])
  applyReviewed store registry again >>= \case
    Left errors -> map admissionErrorCode (NE.toList errors) @?= ["retention-policy"]
    Right other -> assertFailure ("a pruned run was pruned again: " <> show other)

refusedNewest :: Assertion
refusedNewest = do
  store <- seededStore
  calls <- newIORef (0 :: Int)
  let registry = recordingRegistryWith (\_ _ -> modifyIORef' calls (+ 1) >> pure (Right ())) (\_ _ -> modifyIORef' calls (+ 1) >> pure AdapterEffectCompleted) (\_ _ -> pure (RecoveryUnresolved "no recovery"))
  forM_ ["one-hour", "forty-seven-hours", "ten-days-evening", "unsigned"] $ \name -> do
    reviewed <- reviewScope store registry (pruneScope name [])
    applyReviewed store registry reviewed >>= \case
      Left errors -> map admissionErrorCode (NE.toList errors) @?= ["retention-policy"]
      Right other -> assertFailure ("a kept run's prune was admitted: " <> T.unpack name <> " " <> show other)
  readIORef calls >>= (@?= 0)

-- | ADR 26: stop the prune at each of its operations, as an interrupted
-- provider leaves it, then take the exit per-operation proof selects. An
-- operation the provider proves complete resumes to convergence; a Job that
-- failed after deleting the object closes, keeping the prune scope. Either
-- way no transaction stays active, and the receipt recovery of a partial prune
-- is not a new prune, so retention admission lets it through.
stoppedPrunes :: Assertion
stoppedPrunes = do
  probe <- seededStore
  reviewedProbe <- reviewScope probe completing (pruneScope "forty-days" [])
  let operations = map (plannedOperationId . reviewPlannedOperation) (reviewOperations (reviewedDocument reviewedProbe))
  assertBool "the prune review has no operations" (not (null operations))
  forM_ operations $ \stopAt -> forM_ [False, True] $ \terminal -> do
    store <- seededStore
    -- The provider is unreachable when the operation stops, and answers later.
    let interrupted operation _ = pure (if plannedOperationId operation == stopAt then AdapterEffectAmbiguous "interrupted" else AdapterEffectCompleted)
        unreachable operation _ = pure (if plannedOperationId operation == stopAt then RecoveryUnresolved "provider unreachable" else RecoveryProvedComplete (proof operation))
        answer operation
          | plannedOperationId operation /= stopAt = RecoveryProvedComplete (proof operation)
          | terminal = RecoveryTerminalFailure (ok (mkPhysicalIdentity "failed-prune-job"))
          | otherwise = RecoveryProvedComplete (proof operation)
        registry = recordingRegistryWith (\_ _ -> pure (Right ())) interrupted unreachable
        answering = recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\operation _ -> pure (answer operation))
        label = T.unpack (operationIdText stopAt) <> (if terminal then " (terminal)" else " (proved)")
    reviewed <- reviewScope store registry (pruneScope "forty-days" [])
    transaction <-
      applyReviewed store registry reviewed >>= expectRight >>= \case
        StoppedAmbiguous tx _ -> pure tx
        other -> assertFailure ("the prune did not stop at " <> label <> ": " <> show other) >> pure (error "unreachable")
    if terminal
      then do
        record <- closeTransaction store answering (CloseInput transaction (reviewDigestOf reviewed) False Nothing) >>= either (\errors -> assertFailure ("close refused at " <> label <> ": " <> show (NE.toList errors)) >> pure (error "unreachable")) pure
        Map.elems (closedScopes record) @?= [KeepDesired]
      else
        resumeTransaction store answering transaction >>= expectRight >>= \case
          Converged _ -> pure ()
          other -> assertFailure ("the proved prune did not resume at " <> label <> ": " <> show other)
    after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
    headActiveTransaction after @?= Nothing
    history <- loadInventoryHistory store >>= expectRight
    wall <- getCurrentTime
    assertBool ("the prune scope is not accepted at " <> label) (Map.member (scopeId (pruneScope "forty-days" [])) (historyAccepted history))
    scheduledPruneRetentionAdmission standardRetention wall (historyAccepted history) [pruneScope "forty-days" [("scheduled.prune.recovery.review", digestText (reviewDigestOf reviewed))]]
      @?= Right ()
    assertBool ("a stopped prune's run was prunable again at " <> label) (isLeft (scheduledPruneRetentionAdmission standardRetention wall (historyAccepted history) [pruneScope "forty-days" []]))

-- Review helpers.

reviewScope :: InventoryStore -> AdapterRegistry -> ScopeDeclaration -> IO ReviewedPlan
reviewScope store registry scope = do
  history <- loadInventoryHistory store >>= expectRight
  let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))) (ReplaceScope scope :| []))
      facts = [(declarationId declared, ConfirmedAbsent (contentDigest "absent")) | bundle <- scopeBundles scope, declared@(Managed _) <- declarations bundle]
  planning <- loadInventoryPlanningHistory store candidate >>= expectRight
  proposal <- expectRight (planChanges candidate noLifecycleDecisions planning (ok (observationSet facts)))
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  expectRight (verifyReview published bundle)

reviewDigestOf :: ReviewedPlan -> ContentDigest
reviewDigestOf = contentDigest . encodeReviewDocument . reviewedDocument

scopeOf :: ScopeId -> [Declaration] -> ScopeDeclaration
scopeOf owner members = ok (mkScopeDeclaration owner [ResourceBundle members [] [] [] [] []])

member :: ScopeId -> Text -> Declaration
member owner role =
  Managed
    ManagedResource
      { identity = mintResourceId owner (ok (mkLogicalKey role)) (ok (mkName "resource"))
      , owner = owner
      , executor = KubernetesExecutor
      , address = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "personal"))) (ok (mkName role))
      , aliases = []
      , spec = NativeObject (contentDigest (TE.encodeUtf8 role))
      , lifecycle = Retain
      , dataPolicy = Stateless
      , sensitivity = Public
      , dependencies = []
      , delegations = []
      , source = SourceLocation "test" role
      }
  where
    cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

proof :: PlannedOperation -> ContentDigest
proof = contentDigest . TE.encodeUtf8 . operationIdText . plannedOperationId

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
