-- | F54: a landed application Service update that never becomes Ready has a
-- reviewed exit. The adapter proves the landing exactly; the stop keeps the
-- accepted ownership; a corrected review updates the same Service.
module InventoryLandedUpdateStopSpec (inventoryLandedUpdateStopTests) where

import Control.Monad (forM_)
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Kubernetes qualified as K
import Test.Tasty
import Test.Tasty.HUnit

inventoryLandedUpdateStopTests :: TestTree
inventoryLandedUpdateStopTests =
  testGroup
    "landed unready application update (F54)"
    [ testCase "adapter proves a landed Knative update only when exact, observed, exclusive and unready" adapterProof
    , testCase "landed update stops with ownership retained and a corrected review updates the same Service" stopThenCorrect
    , testCase "a landed update with only readiness pending closes, keeping the scope (ADR 26)" pendingReadinessCloses
    , testCase "resume of a landed unready update stops ambiguous without a second write" resumeStopsAmbiguous
    ]

adapterProof :: Assertion
adapterProof = do
  let value =
        object
          [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
          , "kind" .= ("Service" :: Text)
          , "metadata" .= object ["name" .= ("web" :: Text), "namespace" .= ("personal" :: Text)]
          ]
      bytes = K.ok (canonicalValue value)
      bound = Map.singleton K.resource (K.ok (bindKubernetesObject (K.input {inputObject = value, objectDigest = contentDigest bytes})))
      before = KubernetesNotReady K.physical "4" (Just K.resource) (contentDigest "old-configuration")
      landed = KubernetesNotReady K.physical "6" (Just K.resource) (contentDigest bytes)
      uid = physicalIdentityText K.physical
      exact = liveService uid "6" 2 2 "False" [inventoryEntry]
  state <- newIORef before
  live <- newIORef exact
  calls <- newIORef (0 :: Int)
  let runtime = K.ops state calls
      adapter =
        mkKubernetesAdapterWithConfigurationObservation
          bound
          runtime
          (traverse (kubernetesObserve runtime))
          (kubernetesObserve runtime)
          (\_ _ -> pure (Left "not a backup"))
          (\_ _ -> pure (Right False))
          (\_ -> Right <$> readIORef live)
      legacy = mkKubernetesAdapter bound runtime
  reviewed <- adapterPrepare adapter K.updateOperation >>= K.expectRight
  legacyReviewed <- adapterPrepare legacy K.updateOperation >>= K.expectRight
  writeIORef state landed
  adapterRecover adapter K.updateOperation reviewed >>= (@?= RecoveryLandedUnready K.physical)
  -- Without a live reader no landing is proved; resume semantics stay as before.
  adapterRecover legacy K.updateOperation legacyReviewed >>= (@?= RecoveryAwaitingReadiness K.physical)
  let replacement = K.ok (mkPhysicalIdentity "replacement-uid")
      foreignOwner = object ["manager" .= ("kubectl-edit" :: Text), "operation" .= ("Update" :: Text), "fieldsV1" .= object ["f:spec" .= object ["f:template" .= object []]]]
  forM_
    [ ("changed spec", KubernetesNotReady K.physical "6" (Just K.resource) (contentDigest "other-configuration"), exact)
    , ("unowned object", KubernetesNotReady K.physical "6" Nothing (contentDigest bytes), exact)
    , ("another owner", KubernetesNotReady K.physical "6" (Just K.cluster) (contentDigest bytes), exact)
    , ("foreign field appScope", landed, liveService uid "6" 2 2 "False" [inventoryEntry, foreignOwner])
    , ("unobserved generation", landed, liveService uid "6" 3 2 "False" [inventoryEntry])
    , ("moved between reads", landed, liveService uid "7" 2 2 "False" [inventoryEntry])
    , ("ready", landed, liveService uid "6" 2 2 "True" [inventoryEntry])
    ]
    $ \(label, observedState, liveObject) -> do
      writeIORef state observedState
      writeIORef live liveObject
      adapterRecover adapter K.updateOperation reviewed >>= \case
        RecoveryUnresolved _ -> pure ()
        other -> assertFailure (label <> " was not refused: " <> show other)
  -- F56: a replaced object is never a proved landing, but its reviewed target
  -- is gone, so only the reviewed stop may end the update.
  writeIORef state (KubernetesNotReady replacement "6" (Just K.resource) (contentDigest bytes))
  writeIORef live (liveService (physicalIdentityText replacement) "6" 2 2 "False" [inventoryEntry])
  adapterRecover adapter K.updateOperation reviewed >>= (@?= RecoveryTargetReplaced replacement)
  readIORef calls >>= (@?= 0)

-- | The live object a reader returns: Nagare owns the spec, the controller
-- owns status through the status subresource.
liveService :: Text -> Text -> Int -> Int -> Text -> [Value] -> Value
liveService uid revision generation observedGeneration ready owners =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata"
        .= object
          [ "name" .= ("web" :: Text)
          , "namespace" .= ("personal" :: Text)
          , "uid" .= uid
          , "resourceVersion" .= revision
          , "generation" .= generation
          , "managedFields" .= (owners <> [statusEntry])
          ]
    , "spec" .= object ["template" .= object []]
    , "status"
        .= object
          [ "observedGeneration" .= observedGeneration
          , "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= ready]]
          ]
    ]

inventoryEntry, statusEntry :: Value
inventoryEntry = object ["manager" .= ("nagare-inventory" :: Text), "operation" .= ("Apply" :: Text), "fieldsV1" .= object ["f:spec" .= object ["f:template" .= object []]]]
statusEntry = object ["manager" .= ("controller" :: Text), "operation" .= ("Update" :: Text), "subresource" .= ("status" :: Text), "fieldsV1" .= object ["f:status" .= object []]]

data Stopped = Stopped
  { store :: !InventoryStore
  , bundle :: !ReviewBundle
  , reviewed :: !ReviewedPlan
  , transaction :: !TransactionId
  , selected :: !OperationId
  , history :: !InventoryHistory
  , registry :: !AdapterRegistry
  , updateWrites :: !(IORef Int)
  }
  deriving stock (Generic)

-- | Seed an application with one Service, review an update of it plus a
-- release-history ConfigMap ordered after it, and apply: the update is
-- intended, lands, and its readiness wait ends ambiguous.
landedUpdate :: RecoveryDecision -> IO Stopped
landedUpdate decision = do
  memory <- newMemoryStore
  writes <- newIORef (0 :: Int)
  let registry =
        recordingRegistryWith
          (\_ _ -> pure (Right ()))
          ( \operation _ ->
              if plannedAction operation == UpdateResource
                then modifyIORef' writes (+ 1) >> pure (AdapterEffectAmbiguous "readiness wait ended")
                else pure AdapterEffectCompleted
          )
          (\_ _ -> pure decision)
      base = ok (mkScopeSnapshot fixtureBinding (Map.singleton appScope (ok (mkScopeGeneration 1), scope [service "old"])) Map.empty)
      dummy = ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])
      candidate = ok (composeInventory base (ReplaceScope (scope [service "crashing", historyMember]) :| []))
  _ <- initializeStore memory fixtureBinding "landed-update-stop" >>= expectRight
  _ <- seedInventoryHistory memory (ok (composeInventory base (ReplaceScope dummy :| []))) >>= expectRight
  seeded <- loadInventoryHistory memory >>= expectRight
  let observations = ok (observationSet [(serviceId, ObservedPresent serviceUid), (historyId, ConfirmedAbsent (contentDigest "absent"))])
  proposal <- expectRight (planChanges candidate noLifecycleDecisions seeded observations)
  beforeReview <- readStoreSnapshot memory >>= expectRight
  prepared <- prepareReview registry beforeReview proposal >>= expectRight
  _ <- publishReview memory prepared >>= expectRight
  published <- readStoreSnapshot memory >>= expectRight
  checked <- either (assertFailure . show . NE.toList) pure (verifyReview published prepared)
  applyReviewed memory registry checked >>= expectRight >>= \case
    StoppedAmbiguous stoppedTransaction stoppedOperation -> pure (Stopped memory prepared checked stoppedTransaction stoppedOperation seeded registry writes)
    other -> assertFailure (show other) >> undefined

stopThenCorrect :: Assertion
stopThenCorrect = do
  stopped <- landedUpdate (RecoveryLandedUnready serviceUid)
  events <- journal (stopped ^. #store)
  assertBool
    "fixture did not intend the update"
    (any (\event -> eventOperation event == Just (stopped ^. #selected) && eventState event == IntentRecorded) events)
  before <- readHead (stopped ^. #store) >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  recordOperatorRecovery
    (stopped ^. #store)
    (recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure (RecoveryLandedUnready serviceUid)))
    (OperatorRecoveryInput (stopped ^. #transaction) (stopped ^. #selected) (stopReviewDigest (stopped ^. #reviewed)) StopIncompleteApplication)
    False
    >>= expectRight
  settled <- readHead (stopped ^. #store) >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  headAccepted settled @?= headAccepted before
  headConverged settled @?= headConverged before
  headActiveTransaction settled @?= Nothing
  headExecutorClaim settled @?= Nothing
  -- The corrected review starts from the stopped review's accepted revision.
  accepted <- historyAccepted <$> (loadInventoryHistory (stopped ^. #store) >>= expectRight)
  let snapshot = ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) accepted) Map.empty)
      corrected = ok (composeInventory snapshot (ReplaceScope (scope [service "fixed", historyMember]) :| []))
      observations = ok (observationSet [(serviceId, ObservedPresent serviceUid), (historyId, ConfirmedAbsent (contentDigest "absent"))])
      registry = recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\operation _ -> pure (RecoveryProvedComplete (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation))))))
  planning <- loadInventoryPlanningHistory (stopped ^. #store) corrected >>= expectRight
  proposal <- expectRight (planChanges corrected noLifecycleDecisions planning observations)
  snapshotBefore <- readStoreSnapshot (stopped ^. #store) >>= expectRight
  prepared <- prepareReview registry snapshotBefore proposal >>= expectRight
  _ <- publishReview (stopped ^. #store) prepared >>= expectRight
  published <- readStoreSnapshot (stopped ^. #store) >>= expectRight
  checked <- either (assertFailure . show . NE.toList) pure (verifyReview published prepared)
  let effects =
        [ (plannedAction operation, NE.toList (plannedResources operation))
        | entry <- reviewOperations (reviewBundleDocument prepared)
        , let operation = reviewPlannedOperation entry
        , plannedAction operation /= VerifyResource
        ]
  -- The same Service is updated in place, never recreated or replaced.
  length effects @?= 2
  assertBool "corrected review does not update the stopped Service" ((UpdateResource, [serviceId]) `elem` effects)
  assertBool "corrected review does not create the never-started member" ((CreateResource, [historyId]) `elem` effects)
  applyReviewed (stopped ^. #store) registry checked >>= expectRight >>= \case
    Converged _ -> pure ()
    other -> assertFailure (show other)
  converged <- loadInventoryHistory (stopped ^. #store) >>= expectRight
  Map.lookup appScope (historyConverged converged) @?= fmap fst (Map.lookup appScope (historyAccepted converged))

-- | ADR 26: the stop decision is a close. An intended update whose adapter
-- reports only that readiness is pending settles as landed, so the close keeps
-- the scope's admitted revision without converging it. An operation that
-- cannot be settled blocks the close (InventoryCloseSpec).
pendingReadinessCloses :: Assertion
pendingReadinessCloses = do
  weak <- landedUpdate (RecoveryAwaitingReadiness serviceUid)
  before <- readHead (weak ^. #store) >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  closed <-
    recordOperatorRecovery
      (weak ^. #store)
      (recordingRegistryWith (\_ _ -> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure (RecoveryAwaitingReadiness serviceUid)))
      (OperatorRecoveryInput (weak ^. #transaction) (weak ^. #selected) (stopReviewDigest (weak ^. #reviewed)) StopIncompleteApplication)
      False
  void (expectRight closed)
  after <- readHead (weak ^. #store) >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  headActiveTransaction after @?= Nothing
  headAccepted after @?= headAccepted before
  headConverged after @?= headConverged before

resumeStopsAmbiguous :: Assertion
resumeStopsAmbiguous = do
  stopped <- landedUpdate (RecoveryLandedUnready serviceUid)
  readIORef (stopped ^. #updateWrites) >>= (@?= 1)
  resumeTransaction (stopped ^. #store) (stopped ^. #registry) (stopped ^. #transaction) >>= expectRight >>= \case
    StoppedAmbiguous resumed operation -> (resumed, operation) @?= (stopped ^. #transaction, stopped ^. #selected)
    other -> assertFailure ("resume of a landed unready update: " <> show other)
  readIORef (stopped ^. #updateWrites) >>= (@?= 1)
  readHead (stopped ^. #store) >>= expectRight >>= maybe (assertFailure "head missing") (\value -> headActiveTransaction value @?= Just (transactionIdText (stopped ^. #transaction)))

journal :: InventoryStore -> IO [JournalEvent]
journal memory = do
  headValue <- readHead memory >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  raw <- readJournalPrefix memory (headSequence headValue) >>= expectRight
  either (assertFailure . show) pure (traverse decodeJournalEvent raw)

appScope :: ScopeId
appScope = ok (mkScopeId Application "web")

appCluster :: ResourceId
appCluster = mintResourceId appScope (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

serviceId, historyId :: ResourceId
serviceId = declarationId (service "old")
historyId = declarationId historyMember

serviceUid :: PhysicalIdentity
serviceUid = ok (mkPhysicalIdentity "original-service")

service :: ByteString -> Declaration
service digest =
  Managed
    ( (member "service")
        { address = Kubernetes appCluster "serving.knative.dev" (ok (mkName "service")) (Just (ok (mkName "personal"))) (ok (mkName "web"))
        , spec = KnativeService (contentDigest digest)
        }
    )

historyMember :: Declaration
historyMember =
  Managed
    ( (member "history")
        { address = Kubernetes appCluster "" (ok (mkName "configmap")) (Just (ok (mkName "personal"))) (ok (mkName "history"))
        , dependencies = [OrderedAfter serviceId]
        }
    )

member :: Text -> ManagedResource
member role =
  ManagedResource
    { identity = mintResourceId appScope (ok (mkLogicalKey role)) (ok (mkName "resource"))
    , owner = appScope
    , executor = KubernetesExecutor
    , address = Kubernetes appCluster "" (ok (mkName "configmap")) (Just (ok (mkName "system"))) (ok (mkName role))
    , aliases = []
    , spec = NativeObject (contentDigest (TE.encodeUtf8 role))
    , lifecycle = Retain
    , dataPolicy = Stateless
    , sensitivity = Public
    , dependencies = []
    , delegations = []
    , source = SourceLocation "test" role
    }

scope :: [Declaration] -> ScopeDeclaration
scope members = ok (mkScopeDeclaration appScope [ResourceBundle members [] [] [] [] []])

stopReviewDigest :: ReviewedPlan -> ContentDigest
stopReviewDigest = contentDigest . encodeReviewDocument . reviewedDocument

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
