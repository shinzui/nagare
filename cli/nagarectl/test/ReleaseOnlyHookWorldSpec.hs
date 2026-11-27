-- | EP-269 M3: a release-only pre-deploy hook through review, the journal and
-- the model world. The members are the compiled Application's own bytes and
-- ordering edges (its Kubernetes members, with references to the foundation's
-- external objects dropped), executed by the production adapter over the fake
-- API server, where a CronJob's schedule ticks as status writes.
module ReleaseOnlyHookWorldSpec (releaseOnlyHookWorldTests) where

import AppDatabaseSpec (known, testCluster)
import Data.Aeson (Value (Bool, Object), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import InventoryTransactionSpec (fixtureBinding)
import ManagedEnvScopeSpec (input, scopedApp)
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Task (TaskTrigger (..), scheduledTask)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapter (AdapterRegistry, OperationAction (..), PlannedOperation (..), mkAdapterRegistry, observeWithRegistry)
import Nagare.Inventory.Application (ApplicationScopeInput (..), compileApplicationDeployment, compileApplicationRetry, failedHookScopes, hookScopeMembers, hookTriggerOverrides, ownStoppedDeploy, spentHookScope)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (CloseInput (..), TransactionResult (..), applyReviewed, closeTransaction)
import Nagare.Inventory.Journal (OperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lifecycle (decideScopeRetirements)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (kubernetesMembersForReview)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RetirementIntent (RetainResources), Sensitivity (Public))
import Nagare.Resource.Reference (Dependency (..), SomeRef (..), refProducer)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.World.Adversary (Adversary, newAdversary)
import Nagare.Test.World.ApiServer (ObjectKey (..), Outcome (Failed), Stored, churnOnce)
import Nagare.Test.World.Kubernetes (KubeWorld, effectiveWrites, newKubeWorld, worldKubernetesAdapter)
import Test.Tasty
import Test.Tasty.HUnit

releaseOnlyHookWorldTests :: TestTree
releaseOnlyHookWorldTests =
  testGroup
    "release-only hook in the model world (EP-269)"
    [ testCase "a failed release-only hook leaves the Service and worker uncreated" failedHookBlocksServing
    , testCase "an identical accepted retry keeps the first completion proof and runs the hook once" retryKeepsProof
    , testCase "the scheduled-to-release-only review updates the CronJob in place, suspended" transitionUpdatesInPlace
    , testCase "after the transition the release-only CronJob never ticks and the scheduled one does" onlyScheduledTicks
    , testCase "a closed failed hook does not block later reviews (BUG-10)" closedHookUnblocksReviews
    , testCase "the same tag deployed again after a failed hook runs the hook afresh, beside the failed Job" sameTagRetries
    , testCase "a retry whose hook fails again is closed and retried the same way, and the recovery leaves no unconverged scope" retryFailsAgain
    ]

-- | The EP-261 fixture with an ordinary scheduled service task beside the
-- hook, so one world holds both kinds of CronJob.
scheduled :: DslApp.Application
scheduled =
  scopedApp Dsl.NoManagedEnv
    & #service
    %~ fmap (#tasks .~ [either (error . show) id (scheduledTask "scoped-report" "0 * * * *" "registry.example.com/scoped" "report")])

released :: DslApp.Application
released = scheduled & #tasks %~ map (#trigger .~ ReleaseOnly)

compiled :: DslApp.Application -> IO ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString))
compiled app =
  either (assertFailure . show) pure $
    compileApplicationDeployment ((input app) {scopeInputOverrides = scopeInputOverrides (input app) <> hookTriggerOverrides app})

-- | Keep each scope's Kubernetes members, their edges to one another and the
-- hook proofs; drop the foundation's external objects this world does not hold.
forWorld :: ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString)) -> ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString))
forWorld (scopes, native) = (map rebuild scopes, Map.map (first keepEdges) native)
  where
    proofs = Set.fromList [operation ^. #identity | scope <- scopes, bundle <- scopeBundles scope, operation <- operations bundle]
    kept identity = Map.member identity native || Set.member identity proofs
    keepEdges resource = resource & #dependencies %~ filter (kept . producer)
    producer = \case
      OrderedAfter identity -> identity
      Consumes (SomeRef ref) -> refProducer ref
      ReadyAfter (SomeRef ref) -> refProducer ref
    rebuild scope =
      either (error . show) id $
        mkScopeDeclaration
          (scopeId scope)
          [ ResourceBundle
              [Managed (keepEdges resource) | bundle <- scopeBundles scope, Managed resource <- declarations bundle, Map.member (resource ^. #identity) native]
              []
              []
              []
              (concatMap operations (scopeBundles scope))
              []
          ]

data Run = Run
  { store :: !InventoryStore
  , world :: !(IORef KubeWorld)
  , adversary :: !(IORef Adversary)
  , seen :: !(IORef (Map ResourceId (ManagedResource, ByteString)))
  -- ^ The bytes of every member deployed so far, as the accepted native state a retirement observes.
  }

newRun :: IO Run
newRun = do
  store' <- newMemoryStore
  _ <- initializeStore store' fixtureBinding "release-only-hook" >>= expectRight
  Run store' <$> newKubeWorld Set.empty <*> newAdversary [] <*> newIORef Map.empty

-- | Load accepted history, prepare a fresh review of the compiled scopes, and
-- apply it, as @app deploy --save-plan@ then @inventory apply@ do.
deploy :: Run -> ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString)) -> IO (ChangeProposal, TransactionResult)
deploy run compiledScopes = (\(proposal', _, _, result) -> (proposal', result)) <$> deployReviewed run compiledScopes

-- | 'deploy', also returning the review and the registry that applied it.
deployReviewed :: Run -> ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString)) -> IO (ChangeProposal, ReviewedPlan, AdapterRegistry, TransactionResult)
deployReviewed run compiledScopes = do
  let (scopes, compiledMembers) = forWorld compiledScopes
  members <- atomicModifyIORef' (seen run) (\earlier -> let every = Map.union compiledMembers earlier in (every, every))
  history <- loadInventoryHistory (store run) >>= expectRight
  let base = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      -- As @app deploy@ does: the application's earlier failed hook scopes are retired, their Jobs kept.
      superseded = failedHookScopes (scopeId (head scopes)) (historyAccepted history) (historyConverged history) (map scopeId scopes)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding base (historyReservations history))) (NE.fromList (map ReplaceScope scopes <> map (`RetireScope` RetainResources) superseded)))
  planning <- loadInventoryPlanningHistory (store run) candidate >>= expectRight
  adapter <- worldKubernetesAdapter (fixtureBinding ^. #identity) members (world run) (adversary run)
  let registry' = ok (mkAdapterRegistry [adapter])
  observations <- observeWithRegistry registry' (requirementsByExecutor (observationRequirements candidate planning)) >>= expectRight
  before <- readStoreSnapshot (store run) >>= expectRight
  let proposal' = ok (planChanges candidate (ok (decideScopeRetirements candidate planning observations)) planning observations)
  reviewBundle <- prepareReview registry' before proposal' >>= expectRight
  _ <- publishReview (store run) reviewBundle >>= expectRight
  snapshot <- readStoreSnapshot (store run) >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshot reviewBundle)
  reviewMembers <- kubernetesMembersForReview (store run) reviewBundle Map.empty >>= expectRight
  executor <- worldKubernetesAdapter (fixtureBinding ^. #identity) (Map.union reviewMembers members) (world run) (adversary run)
  let executing = ok (mkAdapterRegistry [executor])
  result <- applyReviewed (store run) executing reviewed >>= expectRight
  pure (proposal', reviewed, executing, result)

converged :: TransactionResult -> Assertion
converged = \case
  Converged _ -> pure ()
  other -> assertFailure ("the review did not converge: " <> show other)

-- | The live objects of one kind.
live :: Run -> Text -> IO (Map ObjectKey Stored)
live run kind = Map.filterWithKey (\key _ -> key ^. #kind == kind) . (^. #server . #objects) <$> readIORef (world run)

-- | The planned operations that write any of these members.
operationsOn :: Set.Set ResourceId -> ChangeProposal -> [PlannedOperation]
operationsOn members proposal' =
  [operation | operation <- proposalOperations proposal', any (`Set.member` members) (NE.toList (plannedResources operation))]

kindIds :: Text -> Map ResourceId (ManagedResource, ByteString) -> Set.Set ResourceId
kindIds kind native =
  Set.fromList [identity | (identity, (resource, _)) <- Map.toList native, Kubernetes _ _ k _ _ <- [resource ^. #address], nameText k == kind]

-- | The effective writes of these operations.
writesOf :: Run -> [PlannedOperation] -> IO (Map OperationId Int)
writesOf run operations' = do
  writes <- effectiveWrites <$> readIORef (world run)
  pure (Map.restrictKeys writes (Set.fromList (map plannedOperationId operations')))

hookCronKey, reportCronKey :: ObjectKey
hookCronKey = ObjectKey "batch" "cronjob" (Just "personal") "nagare-task-scoped-migrate"
reportCronKey = ObjectKey "batch" "cronjob" (Just "personal") "nagare-task-scoped-report"

suspended :: Stored -> Maybe Value
suspended stored = case stored ^. #content of
  Object root | Just (Object spec) <- KM.lookup "spec" root -> KM.lookup "suspend" spec
  _ -> Nothing

failedHookBlocksServing :: Assertion
failedHookBlocksServing = do
  run <- newRun
  release <- compiled released
  let jobBytes = [bytes | (identity, (_, bytes)) <- Map.toList (snd release), Set.member identity (kindIds "job" (snd release))]
  length jobBytes @?= 1
  modifyIORef' (world run) (#server . #outcomes %~ Map.union (Map.fromList [(digestText (contentDigest bytes), Failed) | bytes <- jobBytes]))
  (_, result) <- deploy run release
  case result of
    Converged _ -> assertFailure "a failed hook converged"
    _ -> pure ()
  Map.size <$> live run "job" >>= (@?= 1)
  Map.keys <$> live run "service" >>= (@?= [])
  Map.keys <$> live run "deployment" >>= (@?= [])

retryKeepsProof :: Assertion
retryKeepsProof = do
  run <- newRun
  release <- compiled released
  (first', result) <- deploy run release
  converged result
  let jobs = kindIds "job" (snd release)
      jobCreates = [operation | operation <- operationsOn jobs first', plannedAction operation == CreateResource]
      hookScopes = Set.fromList (map scopeId (drop 1 (fst release)))
  writes <- writesOf run jobCreates
  Map.elems writes @?= [1]
  accepted <- historyAccepted <$> (loadInventoryHistory (store run) >>= expectRight)
  -- A fresh review of the identical deploy against the accepted history.
  (retry, retried) <- deploy run =<< compiled released
  converged retried
  [plannedAction operation | operation <- operationsOn jobs retry, plannedAction operation /= VerifyResource] @?= []
  writesOf run jobCreates >>= (@?= writes)
  acceptedAfter <- historyAccepted <$> (loadInventoryHistory (store run) >>= expectRight)
  assertBool "the hook scope was accepted" (not (Set.null hookScopes) && Map.keysSet (Map.restrictKeys accepted hookScopes) == hookScopes)
  -- Each accepted review advances a scope's generation; the proof is its
  -- digest-addressed declaration, which the retry leaves as it was.
  let proofOf = Map.map (\(revision, declared) -> (revisionDigest revision, declared)) . (`Map.restrictKeys` hookScopes)
  proofOf acceptedAfter @?= proofOf accepted
  Map.size <$> live run "job" >>= (@?= 1)

-- | The scheduled release, then its release-only review with the same tag.
transitioned :: IO (Run, ChangeProposal, Map ResourceId (ManagedResource, ByteString), Map ObjectKey Stored)
transitioned = do
  run <- newRun
  (_, result) <- deploy run =<< compiled scheduled
  converged result
  cronsBefore <- live run "cronjob"
  release <- compiled released
  (proposal', result') <- deploy run release
  converged result'
  pure (run, proposal', snd release, cronsBefore)

transitionUpdatesInPlace :: Assertion
transitionUpdatesInPlace = do
  (run, proposal', native, cronsBefore) <- transitioned
  let crons = kindIds "cronjob" native
  [plannedAction operation | operation <- operationsOn crons proposal', plannedAction operation /= VerifyResource] @?= [UpdateResource]
  cronsAfter <- live run "cronjob"
  Map.keys cronsAfter @?= Map.keys cronsBefore
  fmap (^. #uid) (Map.lookup hookCronKey cronsAfter) @?= fmap (^. #uid) (Map.lookup hookCronKey cronsBefore)
  assertBool "the scheduled CronJob was live before" (Map.member hookCronKey cronsBefore)
  (suspended =<< Map.lookup hookCronKey cronsBefore) @?= Nothing
  (suspended =<< Map.lookup hookCronKey cronsAfter) @?= Just (Bool True)

onlyScheduledTicks :: Assertion
onlyScheduledTicks = do
  (run, _, _, _) <- transitioned
  untick <- live run "cronjob"
  assertBool "both CronJobs exist before the tick" (all (`Map.member` untick) [hookCronKey, reportCronKey])
  modifyIORef' (world run) (#server %~ churnOnce reportCronKey . churnOnce hookCronKey)
  ticked <- live run "cronjob"
  fmap (^. #status) (Map.lookup hookCronKey ticked) @?= fmap (^. #status) (Map.lookup hookCronKey untick)
  fmap (^. #resourceVersion) (Map.lookup hookCronKey ticked) @?= fmap (^. #resourceVersion) (Map.lookup hookCronKey untick)
  assertBool "the scheduled CronJob did not tick" (fmap (^. #status) (Map.lookup reportCronKey ticked) /= fmap (^. #status) (Map.lookup reportCronKey untick))

-- | A plain object outside the Application, in its own converged scope: the
-- data every release's hook declares it changes, as Kotei's hooks name their
-- PostgreSQL volume.
sharedScopeId :: ScopeId
sharedScopeId = known (mkScopeId Standalone "shared-data")

sharedData :: ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString))
sharedData = ([ok (mkScopeDeclaration sharedScopeId [ResourceBundle [Managed (fst bound)] [] [] [] [] []])], Map.singleton sharedId bound)
  where
    bound = ok (bindKubernetesObject member)
    value =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ConfigMap" :: Text)
        , "metadata" .= object ["name" .= ("shared-data" :: Text), "namespace" .= ("personal" :: Text)]
        , "data" .= object ["schema" .= ("1" :: Text)]
        ]
    member =
      KubernetesInput
        { resourceId = sharedId
        , ownerScope = sharedScopeId
        , clusterId = testCluster
        , inputObject = value
        , objectDigest = contentDigest (ok (canonicalValue value))
        , lifecyclePolicy = DeleteWhenUnreferenced
        , inputDataPolicy = Stateless
        , inputSensitivity = Public
        , sourceLocation = SourceLocation "test" "shared-data"
        }

sharedId :: ResourceId
sharedId = mintResourceId sharedScopeId (known (mkLogicalKey "data")) (known (mkName "configmap"))

-- | A release-only Application named @name@ at @tag@ whose every hook declares
-- that it changes the shared data. The shared object is bound for observation
-- but its scope is not part of the deploy.
releaseOf :: Text -> Text -> IO ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString))
releaseOf name tag = withShared (compileApplicationDeployment (releaseInput name tag))

withShared :: (Show e) => Either e ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString)) -> IO ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString))
withShared = fmap (_2 %~ (`Map.union` snd sharedData)) . either (assertFailure . show) pure

releaseInput :: Text -> Text -> ApplicationScopeInput
releaseInput name tag =
  base
    { scopeRollout = (scopeRollout base) {appName = name, imageTag = tag, effectiveTag = tag, taggedAppImage = "registry.example.com/scoped:" <> tag}
    , scopeRelease = scopeRelease base & _2 %~ ((#releaseId .~ tag) . (#siteName .~ (name <> "-web")) . (#imageTag .~ tag))
    , scopeHookEffects = Map.fromList [(hook, [sharedId]) | hook <- hooks]
    , scopeInputOverrides =
        Map.fromList [("tag", tag)]
          <> Map.fromList [("hook/" <> hook, resourceIdText sharedId) | hook <- hooks]
          <> scopeInputOverrides base
          <> hookTriggerOverrides app
    }
  where
    app = renamed (scopedApp Dsl.NoManagedEnv & #tasks %~ map (#trigger .~ ReleaseOnly))
    base = input app
    hooks = [Dsl.serviceNameText (hook ^. #name) | hook <- app ^. #tasks]
    named suffix = known (Dsl.mkServiceName (name <> suffix))
    renamed fixture
      | name == "scoped" = fixture
      | otherwise =
          fixture
            & #name
            .~ named ""
            & #service
            %~ fmap (#name .~ named "-web")
            & #workers
            %~ map (#name .~ named "-worker")
            & #tasks
            %~ map ((#name .~ named "-migrate") . (#app .~ Just (named "")))

reviewDigestFor :: ReviewedPlan -> ContentDigest
reviewDigestFor = contentDigest . encodeReviewDocument . reviewedDocument

-- | BUG-10: release v2's hook fails and is closed. Its scope keeps the desired
-- revision (the Job is an effect), so its operation is never proven; a later
-- review whose hook names the same data must not plan it again.
closedHookUnblocksReviews :: Assertion
closedHookUnblocksReviews = do
  run <- newRun
  converged . snd =<< deploy run sharedData
  v1 <- releaseOf "scoped" "v1"
  converged . snd =<< deploy run v1
  appScope <- case fst v1 of
    scope : _ -> pure (scopeId scope)
    [] -> assertFailure "the release compiled no scope" >> error "unreachable"
  let convergedRevision = Map.lookup appScope . historyConverged <$> (loadInventoryHistory (store run) >>= expectRight)
  servingV1 <- convergedRevision
  jobsV1 <- live run "job"
  v2 <- releaseOf "scoped" "v2"
  let v2Members = Set.fromList [declarationId declaration | scope <- drop 1 (fst v2), bundle <- scopeBundles scope, declaration <- declarations bundle]
      v2HookScopes = Set.fromList (map scopeId (drop 1 (fst v2)))
  modifyIORef' (world run) (#server . #outcomes %~ Map.union (Map.fromList [(digestText (contentDigest bytes), Failed) | (identity, (_, bytes)) <- Map.toList (snd v2), Set.member identity v2Members]))
  (_, reviewed, registry', result) <- deployReviewed run v2
  transaction <- case result of
    StoppedFailed tx _ _ -> pure tx
    StoppedAmbiguous tx _ _ -> pure tx
    other -> assertFailure ("the failed hook did not stop its transaction: " <> show other) >> error "unreachable"
  _ <- closeTransaction (store run) registry' (CloseInput transaction (reviewDigestFor reviewed) False Nothing) >>= expectRight
  readHead (store run) >>= expectRight >>= (@?= Just Nothing) . fmap headActiveTransaction
  convergedRevision >>= (@?= servingV1)
  failedJob <- Map.difference <$> live run "job" <*> pure jobsV1
  Map.size failedJob @?= 1
  -- The corrected release, the rollback, and another application.
  followUps <- sequence [releaseOf "scoped" "v3", releaseOf "scoped" "v1", releaseOf "other" "v1"]
  iforM_ followUps $ \position next -> do
    (proposal', result') <- deploy run next
    converged result'
    operationsOn v2Members proposal' @?= []
    when (position == (0 :: Int)) (convergedRevision >>= \revision -> assertBool "the corrected release did not converge the Application" (revision /= servingV1))
  Map.map (^. #uid) . (`Map.intersection` failedJob) <$> live run "job" >>= (@?= Map.map (^. #uid) failedJob)
  history <- loadInventoryHistory (store run) >>= expectRight
  -- EP-287 M3: the corrected release retired the failed hook's scope, so no scope is left unconverged.
  Map.keysSet (Map.restrictKeys (historyAccepted history) v2HookScopes) @?= Set.empty
  Map.map fst (historyAccepted history) @?= historyConverged history

-- | EP-287 M1: release v2's hook fails and is closed. Deploying v2 again, the
-- recovery after a fix outside the release, compiles the hook under a new
-- attempt: a new Job and scope, with the failed Job left as it was.
sameTagRetries :: Assertion
sameTagRetries = do
  run <- newRun
  converged . snd =<< deploy run sharedData
  converged . snd =<< deploy run =<< releaseOf "scoped" "v1"
  v2 <- releaseOf "scoped" "v2"
  let v2Members = Set.fromList [declarationId declaration | scope <- drop 1 (fst v2), bundle <- scopeBundles scope, declaration <- declarations bundle]
      v2HookScopes = Set.fromList (map scopeId (drop 1 (fst v2)))
  modifyIORef' (world run) (#server . #outcomes %~ Map.union (Map.fromList [(digestText (contentDigest bytes), Failed) | (identity, (_, bytes)) <- Map.toList (snd v2), Set.member identity v2Members]))
  (_, reviewed, registry', result) <- deployReviewed run v2
  transaction <- case result of
    StoppedFailed tx _ _ -> pure tx
    StoppedAmbiguous tx _ _ -> pure tx
    other -> assertFailure ("the failed hook did not stop its transaction: " <> show other) >> error "unreachable"
  -- EP-287 M2: the stopped review is this application's own deploy, so a new deploy of it may
  -- close the transaction; another application's deploy, or a review that also changes
  -- another scope, may not.
  stopped <- loadInventoryHistory (store run) >>= expectRight
  let document = reviewedDocument reviewed
      own app desired = ownStoppedDeploy app (hookScopeMembers (historyAccepted stopped) []) (reviewBaseRevisions document) desired
      appScope = scopeId (head (fst v2))
  other <- scopeId . head . fst <$> releaseOf "other" "v1"
  own appScope (reviewDesiredRevisions document) @?= True
  own other (reviewDesiredRevisions document) @?= False
  own appScope (Map.insert sharedScopeId (snd (Map.findMin (reviewDesiredRevisions document))) (reviewDesiredRevisions document)) @?= False
  -- Only the hook scopes changed, as in a failed retry of the same tag: still this application's.
  own appScope (Map.union (Map.restrictKeys (reviewDesiredRevisions document) v2HookScopes) (reviewBaseRevisions document)) @?= True
  _ <- closeTransaction (store run) registry' (CloseInput transaction (reviewDigestFor reviewed) False Nothing) >>= expectRight
  failedJobs <- live run "job"
  history <- loadInventoryHistory (store run) >>= expectRight
  let spent from = spentHookScope (historyAccepted from) (historyConverged from) (map ((^. #owner) . snd) (Map.elems (historyRetained from)))
  retry <- withShared (compileApplicationRetry (spent history) (releaseInput "scoped" "v2"))
  let retryHookScopes = Set.fromList (map scopeId (drop 1 (fst retry)))
  assertBool "the retry reuses the failed hook's scope" (not (Set.null retryHookScopes) && Set.disjoint retryHookScopes v2HookScopes)
  (proposal', retried) <- deploy run retry
  converged retried
  operationsOn v2Members proposal' @?= []
  jobs <- live run "job"
  Map.map (^. #uid) (jobs `Map.intersection` failedJobs) @?= Map.map (^. #uid) failedJobs
  Map.size jobs @?= Map.size failedJobs + Set.size retryHookScopes
  after <- loadInventoryHistory (store run) >>= expectRight
  mapM_ (\scope -> Map.lookup scope (historyConverged after) @?= fmap fst (Map.lookup scope (historyAccepted after))) (Set.toList retryHookScopes <> take 1 (map scopeId (fst retry)))
  -- EP-287 M3: the retry retired the failed attempt's scope, and nothing is left unconverged.
  Map.keysSet (Map.restrictKeys (historyAccepted after) v2HookScopes) @?= Set.empty
  Map.map fst (historyAccepted after) @?= historyConverged after
  -- A hook that completed is not run again: the same compile keeps the attempt, past the
  -- retired attempt whose retained Job still holds its name.
  again <- withShared (compileApplicationRetry (spent after) (releaseInput "scoped" "v2"))
  Set.fromList (map scopeId (drop 1 (fst again))) @?= retryHookScopes

-- | EP-287 M3: the retry's hook fails too. Its stopped review also retires the first
-- attempt's scope and is still the application's own deploy, so the next deploy may close
-- it; the third attempt converges with every failed Job kept and no scope left unconverged.
retryFailsAgain :: Assertion
retryFailsAgain = do
  run <- newRun
  converged . snd =<< deploy run sharedData
  converged . snd =<< deploy run =<< releaseOf "scoped" "v1"
  jobsV1 <- live run "job"
  let attempt = do
        history <- loadInventoryHistory (store run) >>= expectRight
        withShared (compileApplicationRetry (spentHookScope (historyAccepted history) (historyConverged history) (map ((^. #owner) . snd) (Map.elems (historyRetained history)))) (releaseInput "scoped" "v2"))
      failing release = do
        let hooks = Set.fromList [declarationId declaration | scope <- drop 1 (fst release), bundle <- scopeBundles scope, declaration <- declarations bundle]
        modifyIORef' (world run) (#server . #outcomes %~ Map.union (Map.fromList [(digestText (contentDigest bytes), Failed) | (identity, (_, bytes)) <- Map.toList (snd release), Set.member identity hooks]))
        (_, reviewed, registry', result) <- deployReviewed run release
        transaction <- case result of
          StoppedFailed tx _ _ -> pure tx
          StoppedAmbiguous tx _ _ -> pure tx
          other -> assertFailure ("the failed hook did not stop its transaction: " <> show other) >> error "unreachable"
        stopped <- loadInventoryHistory (store run) >>= expectRight
        let document = reviewedDocument reviewed
        ownStoppedDeploy (scopeId (head (fst release))) (hookScopeMembers (historyAccepted stopped) (map snd (Map.elems (historyRetained stopped)))) (reviewBaseRevisions document) (reviewDesiredRevisions document) @?= True
        _ <- closeTransaction (store run) registry' (CloseInput transaction (reviewDigestFor reviewed) False Nothing) >>= expectRight
        pure ()
  attempt >>= failing
  attempt >>= failing
  failedJobs <- (`Map.difference` jobsV1) <$> live run "job"
  Map.size failedJobs @?= 2
  converged . snd =<< deploy run =<< attempt
  jobs <- live run "job"
  Map.map (^. #uid) (jobs `Map.intersection` failedJobs) @?= Map.map (^. #uid) failedJobs
  Map.size jobs @?= Map.size jobsV1 + 3
  after <- loadInventoryHistory (store run) >>= expectRight
  Map.map fst (historyAccepted after) @?= historyConverged after

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure
