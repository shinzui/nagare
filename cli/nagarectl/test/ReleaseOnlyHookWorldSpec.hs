-- | EP-269 M3: a release-only pre-deploy hook through review, the journal and
-- the model world. The members are the compiled Application's own bytes and
-- ordering edges (its Kubernetes members, with references to the foundation's
-- external objects dropped), executed by the production adapter over the fake
-- API server, where a CronJob's schedule ticks as status writes.
module ReleaseOnlyHookWorldSpec (releaseOnlyHookWorldTests) where

import Data.Aeson (Value (Bool, Object))
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
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.Prelude
import Nagare.Dsl.Task (TaskTrigger (..), scheduledTask)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapter (OperationAction (..), PlannedOperation (..), mkAdapterRegistry, observeWithRegistry)
import Nagare.Inventory.Application (ApplicationScopeInput (..), compileApplicationDeployment, hookTriggerOverrides)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed)
import Nagare.Inventory.Journal (OperationId)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (kubernetesMembersForReview)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (..), SomeRef (..), refProducer)
import Nagare.Resource.Types
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
  }

newRun :: IO Run
newRun = do
  store' <- newMemoryStore
  _ <- initializeStore store' fixtureBinding "release-only-hook" >>= expectRight
  Run store' <$> newKubeWorld Set.empty <*> newAdversary []

-- | Load accepted history, prepare a fresh review of the compiled scopes, and
-- apply it, as @app deploy --save-plan@ then @inventory apply@ do.
deploy :: Run -> ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString)) -> IO (ChangeProposal, TransactionResult)
deploy run compiledScopes = do
  let (scopes, members) = forWorld compiledScopes
  history <- loadInventoryHistory (store run) >>= expectRight
  let base = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding base Map.empty)) (NE.fromList (map ReplaceScope scopes)))
  planning <- loadInventoryPlanningHistory (store run) candidate >>= expectRight
  adapter <- worldKubernetesAdapter (fixtureBinding ^. #identity) members (world run) (adversary run)
  let registry' = ok (mkAdapterRegistry [adapter])
  observations <- observeWithRegistry registry' (requirementsByExecutor (observationRequirements candidate planning)) >>= expectRight
  before <- readStoreSnapshot (store run) >>= expectRight
  let proposal' = ok (planChanges candidate noLifecycleDecisions planning observations)
  reviewBundle <- prepareReview registry' before proposal' >>= expectRight
  _ <- publishReview (store run) reviewBundle >>= expectRight
  snapshot <- readStoreSnapshot (store run) >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshot reviewBundle)
  reviewMembers <- kubernetesMembersForReview (store run) reviewBundle Map.empty >>= expectRight
  executor <- worldKubernetesAdapter (fixtureBinding ^. #identity) reviewMembers (world run) (adversary run)
  result <- applyReviewed (store run) (ok (mkAdapterRegistry [executor])) reviewed >>= expectRight
  pure (proposal', result)

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

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure
