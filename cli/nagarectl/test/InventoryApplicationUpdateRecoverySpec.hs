module InventoryApplicationUpdateRecoverySpec (inventoryApplicationUpdateRecoveryTests) where

import Control.Monad (forM_)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict, fromJSON, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Lifecycle (decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryApplicationUpdateRecoveryTests :: TestTree
inventoryApplicationUpdateRecoveryTests =
  testGroup
    "application update recovery"
    [ companionRules
    , testCase "a durable member only verified by a stopped update is never replanned or retired as absent (F55, F58)" durableVerifyNotRecreated
    , testCase "retirement drops a confirmed-absent stateless member only while it stays absent (F58)" absentMemberRecheckedAtAdmission
    , testCase "admission refuses an absence proof for a member that holds data (F58)" durableAbsenceRefusedAtAdmission
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
  -- Retiring the scope does not drop it as an absent member either (F58):
  -- only a stateless member or a never-started create holds no data.
  let retirement = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))) (RetireScope owner RetainResources :| []))
      retiringFacts =
        ok
          ( observationSet
              [ (declarationId newService, ObservedPresent (ok (mkPhysicalIdentity "original-service")))
              , (declarationId volume, ConfirmedAbsent (contentDigest "deleted-out-of-band"))
              ]
          )
  retiring <- loadInventoryPlanningHistory store retirement >>= expectRight
  case decideRetirement retirement retiring retiringFacts >>= \decisions -> planChanges retirement decisions retiring retiringFacts of
    Left errors ->
      assertBool
        ("unexpected refusal: " <> show errors)
        (any (\err -> planErrorCode err == "durable-resource-missing" && planErrorResources err == [declarationId volume]) (NE.toList errors))
    Right retired ->
      assertFailure ("a deleted durable member was retired as absent: " <> show (proposalAbsences retired))

-- | F58: retirement records a confirmed-absent stateless member as absent
-- rather than retained. Admission re-observes it, and refuses if it has
-- reappeared since review, so no live object leaves history unretained.
absentMemberRecheckedAtAdmission :: Assertion
absentMemberRecheckedAtAdmission = do
  let owner = ok (mkScopeId Platform "retiring")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      kept = member owner cluster "kept"
      vanished = member owner cluster "vanished"
      keptUid = ok (mkPhysicalIdentity "kept-uid")
      scope = ok (mkScopeDeclaration owner [ResourceBundle [kept, vanished] [] [] [] [] []])
      initial = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope scope :| []))
      facts entries = ok (observationSet entries)
  world <- newIORef (Map.fromList [(declarationId kept, ConfirmedAbsent (contentDigest "absent")), (declarationId vanished, ConfirmedAbsent (contentDigest "absent"))])
  let registry = observingRegistry world
      observeAll = facts . Map.toList <$> readIORef world
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "absent-retirement" >>= expectRight
  emptyHistory <- loadInventoryHistory store >>= expectRight
  created <- observeAll
  createReview <- readStoreSnapshot store >>= expectRight >>= \snapshot -> prepareReview registry snapshot (ok (planChanges initial noLifecycleDecisions emptyHistory created)) >>= expectRight
  _ <- publishReview store createReview >>= expectRight
  createReviewed <- readStoreSnapshot store >>= expectRight >>= \snapshot -> expectRight (verifyReview snapshot createReview)
  writeIORef world (Map.fromList [(declarationId kept, ObservedPresent keptUid), (declarationId vanished, ObservedPresent (ok (mkPhysicalIdentity "vanished-uid")))])
  _ <- applyReviewed store registry createReviewed >>= expectRight
  -- The stateless member is deleted out of band; retirement observes it absent.
  writeIORef world (Map.fromList [(declarationId kept, ObservedPresent keptUid), (declarationId vanished, ConfirmedAbsent (contentDigest "deleted"))])
  history <- loadInventoryHistory store >>= expectRight
  let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      retirement = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted Map.empty)) (RetireScope owner RetainResources :| []))
  planning <- loadInventoryPlanningHistory store retirement >>= expectRight
  retiring <- observeAll
  let proposal = ok (decideRetirement retirement planning retiring >>= \decisions -> planChanges retirement decisions planning retiring)
  bundle <- readStoreSnapshot store >>= expectRight >>= \snapshot -> prepareReview registry snapshot proposal >>= expectRight
  Map.keys (reviewAbsences (reviewBundleDocument bundle)) @?= [declarationId vanished]
  Map.keys (reviewRetentions (reviewBundleDocument bundle)) @?= [declarationId kept]
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- expectRight (verifyReview published bundle)
  -- It reappears after review: admission must refuse, leaving history as it was.
  modifyIORef' world (Map.insert (declarationId vanished) (ObservedPresent (ok (mkPhysicalIdentity "reappeared-uid"))))
  applyReviewed store registry reviewed >>= \case
    Left failures -> assertBool ("unexpected refusal: " <> show failures) ("retention-observation" `elem` map admissionErrorCode (NE.toList failures))
    Right outcome -> assertFailure ("a reappeared member was dropped as absent: " <> show outcome)
  unchanged <- readHead store >>= expectRight
  fmap headAccepted unchanged @?= Just (headAccepted (storeSnapshotHead published))
  -- Absent again, the same review is admitted: one member retained, one gone.
  modifyIORef' world (Map.insert (declarationId vanished) (ConfirmedAbsent (contentDigest "deleted")))
  _ <- applyReviewed store registry reviewed >>= expectRight
  retired <- loadInventoryHistory store >>= expectRight
  Map.null (historyAccepted retired) @?= True
  Map.keys (historyRetained retired) @?= [declarationId kept]

-- | F58: only a stateless member or a never-started create may leave history
-- as absent. A saved review edited to carry an absence proof for a durable
-- volume (planning never produces one) is refused at admission, before any
-- observation, and history keeps the volume.
durableAbsenceRefusedAtAdmission :: Assertion
durableAbsenceRefusedAtAdmission = withSystemTempDirectory "durable-absence" $ \root -> do
  let owner = ok (mkScopeId Platform "retiring-data")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      kept = member owner cluster "kept"
      volume = case member owner cluster "volume" of
        Managed resource -> Managed (resource {dataPolicy = Durable (RecoveryIntent (ok (mkName "volume")) (mkSecretRef (ok (mkName "volume-key")) (ok (mkName "v1")) :| []))})
        other -> other
      scope = ok (mkScopeDeclaration owner [ResourceBundle [kept, volume] [] [] [] [] []])
      initial = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope scope :| []))
      present = Map.fromList [(declarationId kept, ObservedPresent (ok (mkPhysicalIdentity "kept-uid"))), (declarationId volume, ObservedPresent (ok (mkPhysicalIdentity "volume-uid")))]
  world <- newIORef (Map.map (const (ConfirmedAbsent (contentDigest "absent"))) present)
  let registry = observingRegistry world
      observeAll = ok . observationSet . Map.toList <$> readIORef world
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "durable-absence" >>= expectRight
  emptyHistory <- loadInventoryHistory store >>= expectRight
  created <- observeAll
  createReview <- readStoreSnapshot store >>= expectRight >>= \snapshot -> prepareReview registry snapshot (ok (planChanges initial noLifecycleDecisions emptyHistory created)) >>= expectRight
  _ <- publishReview store createReview >>= expectRight
  createReviewed <- readStoreSnapshot store >>= expectRight >>= \snapshot -> expectRight (verifyReview snapshot createReview)
  writeIORef world present
  _ <- applyReviewed store registry createReviewed >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
      retirement = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted Map.empty)) (RetireScope owner RetainResources :| []))
  planning <- loadInventoryPlanningHistory store retirement >>= expectRight
  retiring <- observeAll
  bundle <- readStoreSnapshot store >>= expectRight >>= \snapshot -> prepareReview registry snapshot (ok (decideRetirement retirement planning retiring >>= \decisions -> planChanges retirement decisions planning retiring)) >>= expectRight
  -- Edit the saved review: the volume's retention proof becomes an absence proof.
  _ <- writeReviewBundle (root </> "review") bundle >>= expectRight
  original <- BS.readFile (root </> "review" </> "review.json")
  edited <- case eitherDecodeStrict original of
    Right (Object document)
      | Just (Array retentions) <- KM.lookup "retentions" document -> do
          let isVolume entry = case entry of
                Object fields -> KM.lookup "resource" fields == Just (toJSON (declarationId volume))
                _ -> False
              (moved, keptRetentions) = (filter isVolume (toList retentions), filter (not . isVolume) (toList retentions))
              absence entry = case entry of
                Object fields
                  | Just (Object proof) <- KM.lookup "proof" fields ->
                      object
                        [ "resource" .= KM.lookup "resource" fields
                        , "proof" .= object ["owner" .= KM.lookup "owner" proof, "revision" .= KM.lookup "revision" proof, "evidence" .= contentDigest "deleted"]
                        ]
                _ -> entry
          assertBool "the review retains the volume" (length moved == 1)
          case fromJSON (Object (KM.insert "absences" (toJSON (map absence moved)) (KM.insert "retentions" (toJSON keptRetentions) document))) of
            Success value -> pure (encodeReviewDocument value)
            Error reason -> assertFailure reason >> pure original
    other -> assertFailure ("unexpected review document: " <> show other) >> pure original
  BS.writeFile (root </> "review" </> "review.json") edited
  BS.writeFile (root </> "review" </> "review.sha256") (BC.pack (T.unpack (digestText (contentDigest edited))) <> "\n")
  tampered <- loadReviewBundle (root </> "review") >>= expectRight
  _ <- publishReview store tampered >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- expectRight (verifyReview published tampered)
  -- The volume is now absent, as an operator deleting it out of band would make it.
  modifyIORef' world (Map.insert (declarationId volume) (ConfirmedAbsent (contentDigest "deleted")))
  applyReviewed store registry reviewed >>= \case
    Left failures -> assertBool ("unexpected refusal: " <> show failures) ("retention-coverage" `elem` map admissionErrorCode (NE.toList failures))
    Right outcome -> assertFailure ("a durable volume was dropped from history as absent: " <> show outcome)
  after <- loadInventoryHistory store >>= expectRight
  assertBool "the refused retirement changed accepted history" (Map.member owner (historyAccepted after))

-- | A Kubernetes adapter that reports the observations in the world map and
-- completes every operation.
observingRegistry :: IORef (Map.Map ResourceId ResourceObservation) -> AdapterRegistry
observingRegistry world =
  ok
    ( mkAdapterRegistry
        [ Adapter
            { adapterExecutor = KubernetesExecutor
            , adapterIdentity = "absence-observer"
            , adapterVersion = "1"
            , adapterObserve = \resources -> do
                current <- readIORef world
                pure (observationSet [(resource, fact) | resource <- resources, Just fact <- [Map.lookup resource current]])
            , adapterPrepare = \operation -> pure (Right (PreparedNative (ok (canonicalValue (toJSON operation))) "absence observer"))
            , adapterPreflight = \_ _ -> pure (Right ())
            , adapterExecute = \_ _ -> pure AdapterEffectCompleted
            , adapterVerify = \operation _ -> pure (Right (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
            , adapterRecover = \_ _ -> pure (RecoveryUnresolved "absence observer does not recover")
            }
        ]
    )

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
