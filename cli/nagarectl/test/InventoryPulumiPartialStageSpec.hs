-- | F113 and F114: a Pulumi stage the provider refuses partway has a reviewed,
-- proof-based exit. Real planning, the real driver, close and the real Pulumi
-- adapter run over a fake stack: the apply creates some members and stops
-- ambiguous, close settles the create from the stack without an attestation,
-- and the replan, which verifies the members that exist, admits without a
-- dependency cycle and converges.
module InventoryPulumiPartialStageSpec (inventoryPulumiPartialStageTests) where

import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Pulumi
import Nagare.Inventory.Adapters.PulumiRuntime (decodePendingOperations)
import Nagare.Inventory.Cloud
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

inventoryPulumiPartialStageTests :: TestTree
inventoryPulumiPartialStageTests =
  testGroup
    "a Pulumi stage the provider refuses partway (F113, F114)"
    [ testCase "close settles the partial create from the stack, and the replan converges" partialStage
    , testCase "a create that left nothing in the stack closes as no effect and reverts its scope" emptyStage
    , testCase "a pending operation in the stack export is read as unproved" $ do
        let exported = BC.pack "{\"deployment\":{\"resources\":[],\"pending_operations\":[{\"resource\":{\"urn\":\"urn:zone\"},\"type\":\"creating\"}]}}"
        decodePendingOperations exported @?= Right (Map.singleton "urn:zone" "creating")
        decodePendingOperations (BC.pack "{\"deployment\":{\"resources\":[]}}") @?= Right Map.empty
    , testCase "a saved plan with no mutation runs no pulumi up (F128)" noMutationPlan
    ]

-- | The intranet's 0.6.5 stage 1: a zero-mutation update's targeted
-- @pulumi up@ failed the plan check on the reader resources it skipped.
noMutationPlan :: IO ()
noMutationPlan = do
  applied <- newIORef (0 :: Int)
  let registration = head registrations
      operation =
        PlannedOperation
          (ok (mkOperationId "op-same"))
          UpdateResource
          PulumiExecutor
          (registrationResource registration :| [])
          (contentDigest "spec")
          []
          Idempotent
      plan verb =
        PulumiAdapterOps
          { pulumiObserveResources = \_ -> pure (observationSet [])
          , pulumiPrepareSavedPlan = \_ ->
              pure
                ( Right
                    PulumiPreparation
                      { preparationIdentity = stackIdentity
                      , preparationPreview = TE.encodeUtf8 ("{\"steps\":[{\"op\":\"" <> verb <> "\",\"urn\":\"" <> registrationPulumiUrn registration <> "\"}]}")
                      , preparationSavedPlan = "plan"
                      , preparationRegistrations = registrations
                      }
                )
          , pulumiReadIdentity = \_ -> pure (Right stackIdentity)
          , pulumiApplySavedPlan = \_ _ -> modifyIORef' applied (+ 1) >> pure (AdapterEffectAmbiguous "violates plan: dependencies changed")
          , pulumiVerifyResources = \_ _ -> pure (Right (contentDigest "converged"))
          , pulumiRecoverSavedPlan = \_ _ -> pure (RecoveryUnresolved "unused")
          }
      execute verb = do
        let adapter = mkPulumiAdapter registrations (plan verb)
        prepared <- adapterPrepare adapter operation >>= expectRight
        adapterExecute adapter operation prepared
  execute "same" >>= (@?= AdapterEffectCompleted)
  readIORef applied >>= (@?= 0)
  execute "update" >>= (@?= AdapterEffectAmbiguous "violates plan: dependencies changed")
  readIORef applied >>= (@?= 1)

-- | The intranet's stage 2 in small: the provider refuses the zone, the
-- network is created beside it, and the subnet never starts. The network is
-- ordered after the zone, so on the replan it verifies after a create that
-- itself waits for it.
partialStage :: IO ()
partialStage = do
  stack <- newIORef Set.empty
  refused <- newIORef (Set.fromList [urnOf "zone", urnOf "subnet"])
  store <- newMemoryStore
  let registry = pulumiRegistry stack refused
  _ <- initializeStore store fixtureBinding "pulumi-partial" >>= expectRight
  _ <- seedInventoryHistory store seed >>= expectRight
  reviewed <- reviewStage store registry
  map (\operation -> (plannedAction operation, NE.toList (plannedResources operation))) (operationsOf reviewed)
    @?= [(CreateResource, map resourceOf ["net", "root", "subnet", "zone"])]
  (transaction, stopped) <-
    applyReviewed store registry reviewed >>= expectRight >>= \case
      StoppedAmbiguous tx op _ -> pure (tx, op)
      other -> assertFailure ("the refused apply did not stop ambiguous: " <> show other) >> undefined
  readIORef stack >>= (@?= Set.fromList [urnOf "net", urnOf "root"])
  record <- closeTransaction store registry (CloseInput transaction (reviewDigestFor reviewed) False Nothing) >>= expectRight
  Map.lookup stopped (closedClasses record) @?= Just (ClassPartial (map resourceOf ["net", "root"]) (map resourceOf ["subnet", "zone"]))
  closedScopes record @?= Map.singleton scope KeepDesired
  closedNeverStarted record @?= Set.fromList (map resourceOf ["subnet", "zone"])
  -- The operator fixed what the provider refused; the replan re-observes
  -- the stack.
  writeIORef refused Set.empty
  replanned <- reviewStage store registry
  Set.fromList (map (\operation -> (plannedAction operation, NE.toList (plannedResources operation))) (operationsOf replanned))
    @?= Set.fromList
      [ (VerifyResource, [resourceOf "root"])
      , (CreateResource, map resourceOf ["net", "subnet", "zone"])
      ]
  applyReviewed store registry replanned >>= expectRight >>= \case
    Converged _ -> pure ()
    other -> assertFailure ("the replan did not converge: " <> show other)
  readIORef stack >>= (@?= Set.fromList (map urnOf ["net", "root", "subnet", "zone"]))

emptyStage :: IO ()
emptyStage = do
  stack <- newIORef Set.empty
  refused <- newIORef (Set.fromList (map urnOf ["net", "root", "subnet", "zone"]))
  store <- newMemoryStore
  let registry = pulumiRegistry stack refused
  _ <- initializeStore store fixtureBinding "pulumi-empty" >>= expectRight
  _ <- seedInventoryHistory store seed >>= expectRight
  reviewed <- reviewStage store registry
  (transaction, stopped) <-
    applyReviewed store registry reviewed >>= expectRight >>= \case
      StoppedAmbiguous tx op _ -> pure (tx, op)
      other -> assertFailure ("the refused apply did not stop ambiguous: " <> show other) >> undefined
  record <- closeTransaction store registry (CloseInput transaction (reviewDigestFor reviewed) False Nothing) >>= expectRight
  Map.lookup stopped (closedClasses record) @?= Just (ClassNoEffect "the Pulumi stack holds no resource the saved plan creates")
  closedScopes record @?= Map.singleton scope (RevertTo Nothing)

reviewStage :: InventoryStore -> AdapterRegistry -> IO ReviewedPlan
reviewStage store registry = do
  -- Each review starts from the scopes the store accepts now.
  accepted <- historyAccepted <$> (loadInventoryHistory store >>= expectRight)
  let current = ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) accepted) Map.empty)
      candidate = ok (composeInventory current (ReplaceScope (ok (compileCloudScope cloudBundle)) :| []))
  history <- loadInventoryPlanningHistory store candidate >>= expectRight
  adapter <- either (\err -> assertFailure (show err) >> undefined) pure (lookupAdapter registry PulumiExecutor)
  observations <- adapterObserve adapter (map registrationResource registrations) >>= expectRight
  proposal <- expectRight (planChanges candidate noLifecycleDecisions history observations)
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle' <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store bundle' >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  either (assertFailure . show . NE.toList) pure (verifyReview published bundle')

operationsOf :: ReviewedPlan -> [PlannedOperation]
operationsOf = map reviewPlannedOperation . reviewOperations . reviewedDocument

-- | A Pulumi stack in memory. Apply creates every absent target the provider
-- does not refuse and fails, as @pulumi up@ exits non-zero, when it refuses
-- any; verification is the convergence preview: every target is in the stack.
pulumiRegistry :: IORef (Set Text) -> IORef (Set Text) -> AdapterRegistry
pulumiRegistry stack refused = ok (mkAdapterRegistry [mkPulumiAdapter registrations ops])
  where
    ops =
      PulumiAdapterOps
        { pulumiObserveResources = \resources -> do
            present <- readIORef stack
            pure (observationSet [(resource, observe present resource) | resource <- resources])
        , pulumiPrepareSavedPlan = \operation -> do
            present <- readIORef stack
            let step resource = (if Set.member (urnFor resource) present then "same" else "create", urnFor resource)
            pure
              ( Right
                  PulumiPreparation
                    { preparationIdentity = stackIdentity
                    , preparationPreview = preview (map step (NE.toList (plannedResources operation)))
                    , preparationSavedPlan = TE.encodeUtf8 ("plan:" <> operationIdText (plannedOperationId operation))
                    , preparationRegistrations = registrations
                    }
              )
        , pulumiReadIdentity = \_ -> pure (Right stackIdentity)
        , pulumiApplySavedPlan = \operation _ ->
            if plannedAction operation == VerifyResource
              then pure AdapterEffectCompleted
              else do
                refusing <- readIORef refused
                let targets = map urnFor (NE.toList (plannedResources operation))
                modifyIORef' stack (Set.union (Set.fromList (filter (`Set.notMember` refusing) targets)))
                pure $
                  if any (`Set.member` refusing) targets
                    then AdapterEffectAmbiguous "Pulumi apply exited 255: the provider refused the zone"
                    else AdapterEffectCompleted
        , pulumiVerifyResources = converged
        , pulumiRecoverSavedPlan = \operation bytes -> either RecoveryUnresolved RecoveryProvedComplete <$> converged operation bytes
        }
    converged operation bytes = do
      present <- readIORef stack
      pure $
        if all ((`Set.member` present) . urnFor) (NE.toList (plannedResources operation))
          then Right (contentDigest (bytes <> TE.encodeUtf8 (operationIdText (plannedOperationId operation))))
          else Left "Pulumi convergence preview exited 7: no changes were expected for preview but changes were proposed"
    observe present resource
      | Set.member (urnFor resource) present = ObservedPresent (ok (mkPhysicalIdentity (urnFor resource)))
      | otherwise = ConfirmedAbsent (contentDigest (TE.encodeUtf8 ("pulumi-absence:" <> urnFor resource)))
    urnFor resource = maybe (error "fixture") registrationPulumiUrn (find ((== resource) . registrationResource) registrations)
    preview steps =
      TE.encodeUtf8
        ( "{\"steps\":["
            <> T.intercalate "," ["{\"op\":\"" <> verb <> "\",\"urn\":\"" <> urn <> "\"}" | (verb, urn) <- steps]
            <> "]}"
        )

stackIdentity :: PulumiIdentity
stackIdentity =
  PulumiIdentity
    { pulumiContext = "dev"
    , pulumiProject = "example-project"
    , pulumiStack = "dev"
    , pulumiBackend = "gs://example-state"
    , pulumiPayloadId = "payload-v1"
    , pulumiPayloadDigest = contentDigest "payload"
    , pulumiProgramDigest = contentDigest "program"
    , pulumiConfigDigest = contentDigest "config"
    , pulumiToolVersion = "3.255.0"
    }

-- | root, then the zone, then the network (ordered after the zone, as the
-- perimeter's layers order it), then the subnet.
cloudBundle :: CloudDeclarationBundle
cloudBundle =
  CloudDeclarationBundle
    { cloudBundleVersion = 1
    , cloudContext = ok (mkContextId "dev")
    , cloudProject = ok (mkName "example-project")
    , cloudStack = ok (mkName "dev")
    , cloudScope = scope
    , cloudResources =
        [ resource "root" []
        , resource "zone" ["root"]
        , resource "net" ["root", "zone"]
        , resource "subnet" ["root", "zone", "net"]
        ]
    }
  where
    resource key after =
      CloudResource
        { cloudLogicalKey = ok (mkLogicalKey key)
        , cloudRole = ok (mkName key)
        , cloudAddress = PulumiAddress (urnOf key)
        , cloudAliases = []
        , cloudSpecDigest = contentDigest (TE.encodeUtf8 key)
        , cloudLifecycle = Retain
        , cloudDataPolicy = Stateless
        , cloudSensitivity = Private
        , cloudDependencies = [OrderedAfter (resourceOf dependency) | dependency <- after]
        , cloudSource = SourceLocation "infra/pulumi/src/components/NagarePerimeter.ts" key
        , cloudNativeType = "gcp:test/resource:Resource"
        , cloudNativeName = ok (mkName key)
        , cloudNativeUrn = urnOf key
        , cloudRegistrationClass = ManagedRegistration
        }

urnOf :: Text -> Text
urnOf key = "urn:pulumi:dev::nagare::gcp:test/resource:Resource::" <> key

resourceOf :: Text -> ResourceId
resourceOf key = mintResourceId scope (ok (mkLogicalKey key)) (ok (mkName key))

registrations :: [NativeRegistration]
registrations = expectedRegistrations cloudBundle

scope :: ScopeId
scope = ok (mkScopeId Platform "cloud")

seed :: CompositionCandidate
seed = ok (composeInventory base (ReplaceScope (ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])) :| []))

base :: ScopeSnapshot
base = ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)

reviewDigestFor :: ReviewedPlan -> ContentDigest
reviewDigestFor = contentDigest . encodeReviewDocument . reviewedDocument

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
