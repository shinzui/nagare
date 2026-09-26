module InventoryIntegrationSpec (inventoryIntegrationTests) where

import Control.Monad (forM_)
import Data.Aeson (toJSON)
import Data.IORef
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal (OperationId, operationIdText)
import Nagare.Inventory.Lifecycle (decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Bootstrap (composePlatformChanges)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

inventoryIntegrationTests :: TestTree
inventoryIntegrationTests =
  testGroup
    "inventory integration"
    [ testCase "multiple scopes resume each completed effect once, rerun without writes, and retain one app" $ do
        operationCount <- runScenario Nothing
        assertBool "fixture has several independent component operations" (operationCount >= 4)
        forM_ [1 .. operationCount] (runScenario . Just)
    , testCase "partial-retirement keeps sibling application members accepted" partialScopeRetirementProof
    ]

partialScopeRetirementProof :: IO ()
partialScopeRetirementProof = do
  let binding = ContextBinding (known (mkContextId "partial-retirement"))
        (known (mkName "project"))
      owner = known (mkScopeId Application "tasks")
      cluster = mintResourceId owner (known (mkLogicalKey "cluster"))
        (known (mkName "cluster"))
      schedule = member owner cluster "schedule"
      workload = member owner cluster "workload"
      scheduleId = declarationId schedule
      scope declarations = known (mkScopeDeclaration owner
        [ResourceBundle declarations [] [] [] [] []])
      initialScope = scope [schedule, workload]
      remainingScope = scope [workload]
      emptySnapshot = known (mkScopeSnapshot binding Map.empty Map.empty)
      firstCandidate = known (composeInventory emptySnapshot
        (ReplaceScope initialScope :| []))
      physical resource = known (mkPhysicalIdentity
        ("uid:" <> resourceIdText resource))
      absent resource = ConfirmedAbsent
        (contentDigest (TE.encodeUtf8 ("absent:" <> resourceIdText resource)))
  present <- newIORef Set.empty
  writes <- newIORef (0 :: Int)
  let adapter = Adapter
        { adapterExecutor = KubernetesExecutor
        , adapterIdentity = "partial-retirement-recorder"
        , adapterVersion = "1"
        , adapterObserve = \resources -> do
            current <- readIORef present
            pure (observationSet
              [(resource, if Set.member resource current
                then ObservedPresent (physical resource) else absent resource)
              | resource <- resources])
        , adapterPrepare = \operation -> pure (Right
            (PreparedNative (known (canonicalValue (toJSON operation))) "recorder"))
        , adapterPreflight = \_ _ -> pure (Right ())
        , adapterExecute = \operation _ -> do
            modifyIORef' writes (+ 1)
            modifyIORef' present (Set.union
              (Set.fromList (NE.toList (plannedResources operation))))
            pure AdapterEffectCompleted
        , adapterVerify = \_ _ -> pure (Right (contentDigest "verified"))
        , adapterRecover = \_ _ -> pure (RecoveryUnresolved "unused")
        }
      registry = known (mkAdapterRegistry [adapter])
      observe candidate history = observeWithRegistry registry
        (requirementsByExecutor (observationRequirements candidate history))
        >>= expectRight
      applyProposal store proposal = do
        before <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        reviewed <- expectRight (verifyReview published bundle)
        applyReviewed store registry reviewed >>= expectRight >>= \case
          Converged _ -> pure bundle
          other -> assertFailure ("partial retirement did not converge: " <> show other)
  store <- newMemoryStore
  _ <- initializeStore store binding "partial-retirement-client" >>= expectRight
  initialHistory <- loadInventoryHistory store >>= expectRight
  initialFacts <- observe firstCandidate initialHistory
  initialPlan <- expectRight (planChanges firstCandidate noLifecycleDecisions
    initialHistory initialFacts)
  _ <- applyProposal store initialPlan
  accepted <- loadInventoryHistory store >>= expectRight
  let acceptedSnapshot = known (mkScopeSnapshot binding
        (Map.map (\(revision, declared) -> (revisionGeneration revision, declared))
          (historyAccepted accepted)) (historyReservations accepted))
      candidate = known (composeInventory acceptedSnapshot
        (ReplaceScope remainingScope :| []))
  observations <- observe candidate accepted
  case planChanges candidate noLifecycleDecisions accepted observations of
    Left _ -> pure ()
    Right _ -> assertFailure "scope replacement removed a member without a retirement decision"
  let fact = known (observationSet [(scheduleId, ObservedPresent (physical scheduleId))])
      proposal = LifecycleProposal scheduleId ApproveRetirement
        (lifecycleObservationDigest binding scheduleId
          (observationMap fact Map.! scheduleId))
      workloadId = declarationId workload
      stillDesired = LifecycleProposal workloadId ApproveRetirement
        (lifecycleObservationDigest binding workloadId
          (observationMap observations Map.! workloadId))
  case validateLifecycleDecisions candidate accepted observations [stillDesired] of
    Left _ -> pure ()
    Right _ -> assertFailure "retirement decision selected a still-desired sibling"
  decisions <- expectRight (validateLifecycleDecisions candidate accepted observations [proposal])
  retirement <- expectRight (planChanges candidate decisions accepted observations)
  proposalOperations retirement @?= []
  beforeWrites <- readIORef writes
  bundle <- applyProposal store retirement
  Map.keysSet (reviewRetentions (reviewBundleDocument bundle)) @?= Set.singleton scheduleId
  readIORef writes >>= (@?= beforeWrites)
  final <- loadInventoryHistory store >>= expectRight
  Map.member scheduleId (historyRetained final) @?= True
  fmap snd (Map.lookup owner (historyAccepted final)) @?= Just remainingScope
  Map.member (declarationId workload) (historyRetained final) @?= False

-- Each run starts with an empty store. The injected ambiguity happens after
-- the provider effect, so recovery must prove it without issuing that effect
-- again. Every operation position is exercised, including the last one.
runScenario :: Maybe Int -> IO Int
runScenario interruptedAt = do
  let binding = ContextBinding (known (mkContextId "integration")) (known (mkName "project"))
      platformOwner = known (mkScopeId Platform "foundation")
      appAOwner = known (mkScopeId Application "app-a")
      appBOwner = known (mkScopeId Application "app-b")
      cacheOwner = known (mkScopeId Platform "cache")
      cluster = mintResourceId platformOwner (known (mkLogicalKey "cluster")) (known (mkName "cluster"))
      cloud = change (member platformOwner cluster "cloud") $ \resource ->
        resource
          { executor = PulumiExecutor
          , address = GlobalBucket (known (mkName "integration-bucket"))
          }
      cloudId = declarationId cloud
      appA = change (member appAOwner cluster "app-a") $ \resource ->
        resource {dependencies = [OrderedAfter cloudId]}
      appB = change (member appBOwner cluster "app-b") $ \resource ->
        resource {dependencies = [OrderedAfter cloudId]}
      cache = change (member cacheOwner cluster "cache") $ \resource ->
        resource
          { executor = CacheExecutor
          , address = AtticCache cluster (known (mkName "integration-cache"))
          , spec = LogicalCache (contentDigest "cache-configuration")
          , dependencies = [OrderedAfter cloudId]
          }
      scope owner declarations =
        known
          ( mkScopeDeclaration
              owner
              [ResourceBundle declarations [] [] [] [] []]
          )
      platformScope = scope platformOwner [cloud]
      appAScope = scope appAOwner [appA]
      appBScope = scope appBOwner [appB]
      cacheScope = scope cacheOwner [cache]
      allScopes = [platformScope, appAScope, appBScope, cacheScope]
      initialSnapshot = known (mkScopeSnapshot binding Map.empty Map.empty)
      candidate =
        known
          ( composeInventory
              initialSnapshot
              (ReplaceScope platformScope :| map ReplaceScope [appAScope, appBScope, cacheScope])
          )
      physical resource = known (mkPhysicalIdentity ("uid:" <> resourceIdText resource))
      absent resource = ConfirmedAbsent (contentDigest (TE.encodeUtf8 ("absent:" <> resourceIdText resource)))
      operationProof operation = contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))
  present <- newIORef Set.empty
  calls <- newIORef ([] :: [OperationId])
  let adapter executor =
        Adapter
          { adapterExecutor = executor
          , adapterIdentity = "integration-recorder"
          , adapterVersion = "1"
          , adapterObserve = \resources -> do
              current <- readIORef present
              pure
                ( observationSet
                    [ (resource, if Set.member resource current then ObservedPresent (physical resource) else absent resource)
                    | resource <- resources
                    ]
                )
          , adapterPrepare = \operation ->
              pure
                ( Right
                    ( PreparedNative
                        (known (canonicalValue (toJSON operation)))
                        "integration recorder"
                    )
                )
          , adapterPreflight = \_ _ -> pure (Right ())
          , adapterExecute = \operation _ -> do
              modifyIORef' calls (<> [plannedOperationId operation])
              modifyIORef' present (Set.union (Set.fromList (NE.toList (plannedResources operation))))
              count <- length <$> readIORef calls
              pure
                ( if Just count == interruptedAt
                    then AdapterEffectAmbiguous "acknowledgement lost after effect"
                    else AdapterEffectCompleted
                )
          , adapterVerify = \operation _ -> pure (Right (operationProof operation))
          , adapterRecover = \operation _ -> pure (RecoveryProvedComplete (operationProof operation))
          }
      registry =
        known
          ( mkAdapterRegistry
              ( map
                  adapter
                  [PulumiExecutor, KubernetesExecutor, CacheExecutor]
              )
          )
      observe candidate' history =
        observeWithRegistry
          registry
          (requirementsByExecutor (observationRequirements candidate' history))
          >>= expectRight
      review store proposal = do
        before <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        after <- readStoreSnapshot store >>= expectRight
        expectRight (verifyReview after bundle)
  store <- newMemoryStore
  _ <- initializeStore store binding "integration-client" >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  observations <- observe candidate history
  proposal <- expectRight (planChanges candidate noLifecycleDecisions history observations)
  let operations = proposalOperations proposal
      expectedIds = map plannedOperationId operations
  length operations @?= 4
  reviewed <- review store proposal
  firstResult <- applyReviewed store registry reviewed >>= expectRight
  case (interruptedAt, firstResult) of
    (Nothing, Converged _) -> pure ()
    (Just _, StoppedAmbiguous transaction _) ->
      resumeTransaction store registry transaction >>= expectRight >>= \case
        Converged resumed | resumed == transaction -> pure ()
        other -> assertFailure ("resume did not converge: " <> show other)
    other -> assertFailure ("unexpected initial result: " <> show other)
  executed <- readIORef calls
  sort executed @?= sort expectedIds
  length executed @?= length operations
  converged <- loadInventoryHistory store >>= expectRight
  let accepted =
        Map.map
          (\(revision, declared) -> (revisionGeneration revision, declared))
          (historyAccepted converged)
      snapshot = known (mkScopeSnapshot binding accepted (historyReservations converged))
      unchanged =
        known
          ( composeInventory
              snapshot
              (ReplaceScope platformScope :| map ReplaceScope [appAScope, appBScope, cacheScope])
          )
  platformCandidate <- expectRight (composePlatformChanges snapshot (ReplaceScope platformScope :| []))
  forM_ [appAOwner, appBOwner] $ \owner -> do
    Map.lookup owner (inventoryScopes (candidateInventory platformCandidate))
      @?= Map.lookup owner (fmap snd accepted)
    Map.lookup owner (candidateGenerations platformCandidate)
      @?= Map.lookup owner (fmap fst accepted)
  case composePlatformChanges snapshot (ReplaceScope appAScope :| []) of
    Left _ -> pure ()
    Right _ -> assertFailure "platform bootstrap accepted an application change"
  case composePlatformChanges snapshot (CollectRetained (declarationId appA) :| []) of
    Left _ -> pure ()
    Right _ -> assertFailure "platform bootstrap collected an application resource"
  case composePlatformChanges snapshot (RetireScope platformOwner RetainResources :| []) of
    Left _ -> pure ()
    Right _ -> assertFailure "platform bootstrap severed accepted application dependencies"
  unchangedObservations <- observe unchanged converged
  noOp <- expectRight (planChanges unchanged noLifecycleDecisions converged unchangedObservations)
  proposalOperations noOp @?= []
  unchangedCalls <- readIORef calls
  unchangedCalls @?= executed
  let retired = known (composeInventory snapshot (RetireScope appBOwner RetainResources :| []))
  retirementObservations <- observe retired converged
  decisions <- expectRight (decideRetirement retired converged retirementObservations)
  retirement <- expectRight (planChanges retired decisions converged retirementObservations)
  proposalOperations retirement @?= []
  retirementReview <- review store retirement
  applyReviewed store registry retirementReview >>= expectRight >>= \case
    Converged _ -> pure ()
    other -> assertFailure ("retirement did not converge: " <> show other)
  final <- loadInventoryHistory store >>= expectRight
  Map.member (declarationId appB) (historyRetained final) @?= True
  Map.member appBOwner (historyAccepted final) @?= False
  forM_ [platformOwner, appAOwner, cacheOwner] $ \owner ->
    Map.lookup owner (historyAccepted final) @?= Map.lookup owner (historyAccepted converged)
  readIORef calls >>= (@?= executed)
  pure (length operations)

member :: ScopeId -> ResourceId -> Text -> Declaration
member owner cluster role =
  Managed
    ManagedResource
      { identity = mintResourceId owner (known (mkLogicalKey role)) (known (mkName "resource"))
      , owner = owner
      , executor = KubernetesExecutor
      , address =
          Kubernetes
            cluster
            ""
            (known (mkName "configmap"))
            (Just (known (mkName "system")))
            (known (mkName role))
      , aliases = []
      , spec = NativeObject (contentDigest (TE.encodeUtf8 role))
      , lifecycle = Retain
      , dataPolicy = Stateless
      , sensitivity = Public
      , dependencies = []
      , delegations = []
      , source = SourceLocation "inventory integration test" role
      }

change :: Declaration -> (ManagedResource -> ManagedResource) -> Declaration
change (Managed resource) edit = Managed (edit resource)
change _ _ = error "integration fixture expected a managed declaration"

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure

known :: (Show e) => Either e a -> a
known = either (error . show) id
