module InventoryApplicationUpdateRecoverySpec (inventoryApplicationUpdateRecoveryTests) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
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

inventoryApplicationUpdateRecoveryTests :: TestTree
inventoryApplicationUpdateRecoveryTests =
  testGroup
    "application update recovery"
    [ companionRules
    , testCase "a durable member only verified by a stopped update is never replanned as a fresh create (F55)" durableVerifyNotRecreated
    ]

companionRules :: TestTree
companionRules = testCase "pending application update stop preserves authority and rejects intended or wrong-kind companions" $
  forM_ [(False, False), (True, False), (False, True)] $ \(intended, wrongKind) -> do
    store <- newMemoryStore
    let owner = ok (mkScopeId Application "web")
        cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
        service digest = case member owner cluster "service" of
          Managed resource ->
            Managed
              ( resource
                  { address = Kubernetes cluster "serving.knative.dev" (ok (mkName "service")) (Just (ok (mkName "personal"))) (ok (mkName "web"))
                  , spec = KnativeService (contentDigest digest)
                  }
              )
          _ -> error "fixture"
        oldService = service "old"
        newService = service "new"
        historyMember = case member owner cluster "history" of
          Managed resource ->
            Managed
              ( resource
                  { address = Kubernetes cluster "" (ok (mkName (if wrongKind then "secret" else "configmap"))) (Just (ok (mkName "personal"))) (ok (mkName "history"))
                  , dependencies = [OrderedAfter (declarationId newService)]
                  }
              )
          _ -> error "fixture"
        scope members = ok (mkScopeDeclaration owner [ResourceBundle members [] [] [] [] []])
        base = ok (mkScopeSnapshot fixtureBinding (Map.singleton owner (ok (mkScopeGeneration 1), scope [oldService])) Map.empty)
        dummy = ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])
        seed = ok (composeInventory base (ReplaceScope dummy :| []))
        candidate = ok (composeInventory base (ReplaceScope (scope [newService, historyMember]) :| []))
        registry =
          recordingRegistryWith
            (\operation _ -> pure (if plannedAction operation == UpdateResource && not intended then Left "status-only revision drift" else Right ()))
            (\_ _ -> pure (AdapterEffectAmbiguous "update interrupted"))
            (\_ _ -> pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "original-service"))))
    _ <- initializeStore store fixtureBinding "application-update-stop" >>= expectRight
    _ <- seedInventoryHistory store seed >>= expectRight
    history <- loadInventoryHistory store >>= expectRight
    let observations =
          ok
            ( observationSet
                [ (declarationId newService, ObservedPresent (ok (mkPhysicalIdentity "original-service")))
                , (declarationId historyMember, ConfirmedAbsent (contentDigest "absent"))
                ]
            )
        proposal = ok (planChanges candidate noLifecycleDecisions history observations)
    beforeReview <- readStoreSnapshot store >>= expectRight
    bundle <- prepareReview registry beforeReview proposal >>= expectRight
    _ <- publishReview store bundle >>= expectRight
    published <- readStoreSnapshot store >>= expectRight
    reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
    (transaction, selected) <-
      applyReviewed store registry reviewed >>= expectRight >>= \case
        StoppedFailed tx op _ -> pure (tx, op)
        StoppedAmbiguous tx op -> pure (tx, op)
        other -> assertFailure (show other) >> undefined
    before <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
    stopped <-
      recordOperatorRecovery
        store
        registry
        (OperatorRecoveryInput transaction selected (reviewDigestFor reviewed) StopIncompleteApplication)
        False
    after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
    headAccepted after @?= headAccepted before
    headConverged after @?= headConverged before
    if intended || wrongKind
      then do
        assertBool "unsafe stop accepted" (isLeft stopped)
        headActiveTransaction after @?= Just (transactionIdText transaction)
      else do
        void (expectRight stopped)
        headActiveTransaction after @?= Nothing
        headExecutorClaim after @?= Nothing
        void (loadInventoryPlanningHistory store candidate >>= expectRight)

-- | F55: a never-intended update stopped as F30's never-started stop (the
-- adapter reports readiness pending after status-only churn) may now carry a
-- never-started verify of a durable member. If that member is later deleted
-- out of band, planning must refuse; it must not plan a fresh, empty create.
durableVerifyNotRecreated :: Assertion
durableVerifyNotRecreated = do
  store <- newMemoryStore
  let owner = ok (mkScopeId Application "web")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      service digest = case member owner cluster "service" of
        Managed resource ->
          Managed
            ( resource
                { address = Kubernetes cluster "serving.knative.dev" (ok (mkName "service")) (Just (ok (mkName "personal"))) (ok (mkName "web"))
                , spec = KnativeService (contentDigest digest)
                }
            )
        _ -> error "fixture"
      oldService = service "old"
      newService = service "new"
      volume = case member owner cluster "uploads" of
        Managed resource ->
          Managed
            ( resource
                { address = Kubernetes cluster "" (ok (mkName "persistentvolumeclaim")) (Just (ok (mkName "personal"))) (ok (mkName "uploads"))
                , dataPolicy = Durable (RecoveryIntent (ok (mkName "uploads")) (mkSecretRef (ok (mkName "uploads-key")) (ok (mkName "v1")) :| []))
                , dependencies = [OrderedAfter (declarationId newService)]
                }
            )
        _ -> error "fixture"
      scope members = ok (mkScopeDeclaration owner [ResourceBundle members [] [] [] [] []])
      base = ok (mkScopeSnapshot fixtureBinding (Map.singleton owner (ok (mkScopeGeneration 1), scope [oldService, volume])) Map.empty)
      dummy = ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])
      seed = ok (composeInventory base (ReplaceScope dummy :| []))
      volumeUid = ok (mkPhysicalIdentity "uploads-pvc")
      registry =
        recordingRegistryWith
          (\operation _ -> pure (if plannedAction operation == UpdateResource then Left "status-only revision drift" else Right ()))
          (\_ _ -> pure (AdapterEffectAmbiguous "unexpected effect"))
          (\_ _ -> pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "original-service"))))
  _ <- initializeStore store fixtureBinding "durable-verify-stop" >>= expectRight
  _ <- seedInventoryHistory store seed >>= expectRight
  let present serviceMember =
        ok
          ( observationSet
              [ (declarationId serviceMember, ObservedPresent (ok (mkPhysicalIdentity "original-service")))
              , (declarationId volume, ObservedPresent volumeUid)
              ]
          )
      -- Review an update of the Service, refused at preflight so it is never
      -- intended, and stop it as F30's never-started stop.
      stopUpdate serviceMember = do
        history <- loadInventoryHistory store >>= expectRight
        let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
            snapshot = ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))
            next = ok (composeInventory snapshot (ReplaceScope (scope [serviceMember, volume]) :| []))
        planning <- loadInventoryPlanningHistory store next >>= expectRight
        let proposal = ok (planChanges next noLifecycleDecisions planning (present serviceMember))
        beforeReview <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry beforeReview proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
        (transaction, selected) <-
          applyReviewed store registry reviewed >>= expectRight >>= \case
            StoppedFailed tx op _ -> pure (tx, op)
            StoppedAmbiguous tx op -> pure (tx, op)
            other -> assertFailure (show other) >> undefined
        recordOperatorRecovery store registry (OperatorRecoveryInput transaction selected (reviewDigestFor reviewed) StopIncompleteApplication) False
          >>= expectRight
        pure [(plannedAction o, NE.toList (plannedResources o)) | entry <- reviewOperations (reviewBundleDocument bundle), let o = reviewPlannedOperation entry]
  -- The first stop leaves the scope accepted but not converged, so the next
  -- review also verifies its unchanged durable volume, which stays pending.
  _ <- stopUpdate (service "middle")
  actions <- stopUpdate newService
  assertBool ("the review does not verify the durable member: " <> show actions) ((VerifyResource, [declarationId volume]) `elem` actions)
  -- The volume is deleted out of band; a corrected review observes it absent.
  history <- loadInventoryHistory store >>= expectRight
  let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))) (ReplaceScope (scope [service "fixed", volume]) :| []))
  planning <- loadInventoryPlanningHistory store candidate >>= expectRight
  let absent =
        ok
          ( observationSet
              [ (declarationId (service "fixed"), ObservedPresent (ok (mkPhysicalIdentity "original-service")))
              , (declarationId volume, ConfirmedAbsent (contentDigest "deleted-out-of-band"))
              ]
          )
  case planChanges candidate noLifecycleDecisions planning absent of
    Left errors -> assertBool ("unexpected refusal: " <> show errors) (any ((== "durable-resource-missing") . planErrorCode) (NE.toList errors))
    Right replanned ->
      assertFailure ("a deleted durable member was replanned instead of refused: " <> show (proposalOperations replanned))

member :: ScopeId -> ResourceId -> Text -> Declaration
member owner cluster role =
  Managed
    ManagedResource
      { identity = mintResourceId owner (ok (mkLogicalKey role)) (ok (mkName "resource"))
      , owner = owner
      , executor = KubernetesExecutor
      , address = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "system"))) (ok (mkName role))
      , aliases = []
      , spec = NativeObject (contentDigest (TE.encodeUtf8 role))
      , lifecycle = Retain
      , dataPolicy = Stateless
      , sensitivity = Public
      , dependencies = []
      , delegations = []
      , source = SourceLocation "test" role
      }

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

reviewDigestFor :: ReviewedPlan -> ContentDigest
reviewDigestFor = contentDigest . encodeReviewDocument . reviewedDocument

recordingRegistry :: (PlannedOperation -> PreparedNative -> IO AdapterExecution) -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision) -> AdapterRegistry
recordingRegistry = recordingRegistryWith (\_ _ -> pure (Right ()))
