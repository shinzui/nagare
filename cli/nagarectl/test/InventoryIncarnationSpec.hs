module InventoryIncarnationSpec (inventoryIncarnationTests) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.KubernetesRuntime (identified)
import Nagare.Inventory.Backup (ManualBackupRequest (..), compileManualBackupScope)
import Nagare.Inventory.BackupReceipt (ScheduledBackupReceipt (..))
import Nagare.Inventory.DataFence (DataFenceControls (..), WriterReleaseState (..), acquireDataFence)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Inventory.Plan
import Nagare.Inventory.ScheduledIngest (ScheduledIngestRequest (..), compileScheduledIngestScope)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

-- | F49: an out-of-band replacement of an accepted durable member is reported
-- and cannot become a recovery point.
inventoryIncarnationTests :: TestTree
inventoryIncarnationTests =
  testGroup
    "accepted incarnations (F49)"
    [ testCase "convergence records a created durable member and never rebinds it to a later object" $ do
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "incarnation-test" >>= expectRight
        live <- newIORef (uid "uid-accepted")
        let registry = observingRegistry live
        converge store registry (ReplaceScope (scopeWith "v1") :| []) (ConfirmedAbsent (contentDigest "absent"))
        incarnations store >>= (@?= Map.singleton durableId (uid "uid-accepted"))
        -- The object is replaced outside Nagare; a later reviewed update proves
        -- the new object but must not launder it into the accepted record.
        writeIORef live (uid "uid-replacement")
        converge store registry (ReplaceScope (scopeWith "v2") :| []) (ObservedDrifted (uid "uid-replacement") (contentDigest "v1"))
        incarnations store >>= (@?= Map.singleton durableId (uid "uid-accepted"))
    , testCase "convergence records a StatefulSet, the stateless controller of the data" $ do
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "incarnation-test" >>= expectRight
        live <- newIORef (uid "uid-statefulset")
        converge store (observingRegistry live) (ReplaceScope statefulScope :| []) (ConfirmedAbsent (contentDigest "absent"))
        recorded <- incarnations store
        Map.lookup statefulId recorded @?= Just (uid "uid-statefulset")
    , testCase "convergence binds the object the create returned, not one that replaced it before convergence (F60)" $ do
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "incarnation-test" >>= expectRight
        live <- newIORef (uid "uid-created")
        -- The object is replaced outside Nagare after the create returned and
        -- before convergence observes anything.
        let replacing = (incarnationAdapter live) {adapterVerify = \operation native -> writeIORef live (uid "uid-replacement") >> adapterVerify (incarnationAdapter live) operation native}
        converge store (expectOk (mkAdapterRegistry [replacing])) (ReplaceScope (scopeWith "v1") :| []) (ConfirmedAbsent (contentDigest "absent"))
        incarnations store >>= (@?= Map.singleton durableId (uid "uid-created"))
    , testCase "a Kubernetes write's returned object names the identity the journal records" $ do
        identified "{\"metadata\":{\"uid\":\"uid-returned\"}}" AdapterEffectCompleted @?= AdapterEffectIdentified (uid "uid-returned") AdapterEffectCompleted
        identified "{\"metadata\":{\"uid\":\"uid-returned\"}}" (AdapterEffectAmbiguous "readiness") @?= AdapterEffectIdentified (uid "uid-returned") (AdapterEffectAmbiguous "readiness")
        identified "" AdapterEffectCompleted @?= AdapterEffectCompleted
    , testCase "a data fence binds only the recorded incarnation of its target (ADR 27, N7)" $ do
        let target = mintResourceId incarnationOwner (expectOk (mkLogicalKey "data")) (expectOk (mkName "pvc"))
            physical = Map.singleton target (uid "uid-accepted")
            fenced recorded = do
              store <- newMemoryStore
              initial <- initializeStore store fixtureBinding "fence" >>= expectRight
              _ <- replaceHeadIfGenerationMatches store (Just (headGeneration initial)) initial {headGeneration = headGeneration initial + 1, headIncarnations = recorded} >>= expectRight
              let request = DataFenceRecord fixtureBinding "session" Nothing (headAccepted initial) physical (Set.singleton target) Set.empty "gs://fixture/recovery" (contentDigest "recovery") Map.empty Nothing FenceAcquiring ""
                  controls = DataFenceControls (\_ -> pure (Right ())) (\_ -> pure (Right ())) (\_ -> pure (Right physical)) (\_ -> pure (Right True)) (\_ -> pure (Right True)) (\_ -> pure (Right ())) (\_ -> pure (Right WritersFullyReleased)) Nothing
              either (const False) (const True) <$> (withProcessLock store (\locked -> acquireDataFence locked controls request) >>= expectRight)
        fenced physical >>= assertBool "the recorded target was refused"
        fenced Map.empty >>= assertBool "an unrecorded target was fenced" . not
        fenced (Map.singleton target (uid "uid-replacement")) >>= assertBool "a replaced target was fenced" . not
    , testCase "a manual backup refuses a source that is not the recorded incarnation (ADR 27, N3)" $ do
        let attempt recorded = case compileManualBackupScope (ManualBackupRequest "pg" "personal" "run-1" Nothing (ScopeRevision (expectOk (mkScopeGeneration 1)) (contentDigest "source")) (uid "uid-live-sts") (uid "uid-live-pvc") (GcsBackend "project" "bucket") (SourceLocation "test" "backup") recorded) databaseScope Map.empty of
              Left errors -> any (\err -> "backup source" `T.isInfixOf` (err ^. #message)) errors
              Right _ -> False
            live = Map.fromList [(databaseMember "statefulset", uid "uid-live-sts"), (databaseMember "pvc", uid "uid-live-pvc")]
        assertBool "a replaced StatefulSet was backed up" (attempt (Map.insert (databaseMember "statefulset") (uid "uid-accepted-sts") live))
        assertBool "a replaced PVC was backed up" (attempt (Map.insert (databaseMember "pvc") (uid "uid-accepted-pvc") live))
        assertBool "an unrecorded source was backed up" (attempt Map.empty)
        assertBool "the recorded source was refused for its identity" (not (attempt live))
    , testCase "status reports a member whose object is not the accepted incarnation as replaced" $ do
        let inventory = expectOk (composeInventory (expectOk (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope (scopeWith "v1") :| []))
            recorded = Map.singleton durableId (uid "uid-accepted")
            category fact = map Status.findingCategory (Status.classifyDriftWith recorded (candidateInventory inventory) (expectOk (observationSet [(durableId, fact)])))
        category (ObservedPresent (uid "uid-accepted")) @?= [Status.Converged]
        category (ObservedPresent (uid "uid-replacement")) @?= [Status.ReplacedIncarnation]
        category (ObservedDrifted (uid "uid-replacement") (contentDigest "changed")) @?= [Status.ReplacedIncarnation]
        -- N21: a replacement that also needs a reviewed replacement is reported replaced.
        category (ObservedReplacementRequired (uid "uid-replacement") (contentDigest "changed")) @?= [Status.ReplacedIncarnation]
        map Status.findingCategory (Status.classifyDriftWith Map.empty (candidateInventory inventory) (expectOk (observationSet [(durableId, ObservedPresent (uid "uid-replacement"))])))
          @?= [Status.Converged]
    , testCase "ingestion refuses a receipt whose source is not the accepted incarnation" $ do
        let refusal = "scheduled receipt source is not the accepted database incarnation"
            attempt recorded = case compileScheduledIngestScope (ingestRequest recorded) databaseScope Map.empty of
              Left errors -> any (\err -> refusal `T.isInfixOf` (err ^. #message)) errors
              Right _ -> False
        assertBool "a replaced StatefulSet must refuse" (attempt (Map.singleton (databaseMember "statefulset") (uid "uid-accepted-sts")))
        assertBool "a replaced PVC must refuse" (attempt (Map.singleton (databaseMember "pvc") (uid "uid-accepted-pvc")))
        assertBool "the accepted incarnation must not be refused for its identity" (not (attempt (Map.fromList [(databaseMember "statefulset", uid "uid-live-sts"), (databaseMember "pvc", uid "uid-live-pvc")])))
        assertBool "an unrecorded source is refused, never read as a match (ADR 27)" (attempt Map.empty)
    ]

-- Planning, review and application of one change against the accepted history.
converge :: InventoryStore -> AdapterRegistry -> NonEmpty ScopeChange -> ResourceObservation -> Assertion
converge store registry changes fact = do
  history <- loadInventoryHistory store >>= expectRight
  let snapshot =
        expectOk
          ( mkScopeSnapshot
              fixtureBinding
              (Map.map (\(revision, scope) -> (revisionGeneration revision, scope)) (historyAccepted history))
              (historyReservations history)
          )
      candidate = expectOk (composeInventory snapshot changes)
      required = Set.toList (requiredResources (observationRequirements candidate history))
      facts = [(resource, if resource `elem` [durableId, statefulId] then fact else ConfirmedAbsent (contentDigest "absent")) | resource <- required]
      proposal = expectOk (planChanges candidate noLifecycleDecisions history (expectOk (observationSet facts)))
  before <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry before proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  after <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show) pure (verifyReview after bundle)
  applied <- applyReviewed store registry reviewed >>= expectRight
  case applied of
    Converged _ -> pure ()
    other -> assertFailure ("expected convergence, got " <> show other)

incarnations :: InventoryStore -> IO (Map ResourceId PhysicalIdentity)
incarnations store = readHead store >>= expectRight >>= maybe (assertFailure "no head" >> pure Map.empty) (pure . headIncarnations)

-- A Kubernetes adapter whose observation reports the current live object,
-- and whose writes return it, as the API server does (ADR 27).
observingRegistry :: IORef PhysicalIdentity -> AdapterRegistry
observingRegistry live = expectOk (mkAdapterRegistry [incarnationAdapter live])

incarnationAdapter :: IORef PhysicalIdentity -> Adapter
incarnationAdapter live =
  Adapter
    { adapterExecutor = KubernetesExecutor
    , adapterIdentity = "incarnation"
    , adapterVersion = "1"
    , adapterObserve = \resources -> do
        current <- readIORef live
        pure (observationSet [(resource, ObservedPresent current) | resource <- resources])
    , adapterPrepare = \operation -> pure (Right (PreparedNative (BL.toStrict (Aeson.encode (operationIdText (plannedOperationId operation)))) "incarnation adapter"))
    , adapterPreflight = \_ _ -> pure (Right ())
    , adapterExecute = \_ _ -> (`AdapterEffectIdentified` AdapterEffectCompleted) <$> readIORef live
    , adapterVerify = \operation _ -> pure (Right (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
    , adapterSettle = Nothing
    , adapterRecover = \_ _ -> pure RecoverySafeToRetry
    }

incarnationOwner :: ScopeId
incarnationOwner = expectOk (mkScopeId Standalone "incarnation-db")

durableId :: ResourceId
durableId = mintResourceId incarnationOwner (expectOk (mkLogicalKey "data")) (expectOk (mkName "resource"))

scopeWith :: Text -> ScopeDeclaration
scopeWith version =
  expectOk
    ( mkScopeDeclaration
        incarnationOwner
        [ ResourceBundle
            [ Managed
                ManagedResource
                  { identity = durableId
                  , owner = incarnationOwner
                  , executor = KubernetesExecutor
                  , address = Kubernetes cluster "" (expectOk (mkName "persistentvolumeclaim")) (Just (expectOk (mkName "personal"))) (expectOk (mkName "data"))
                  , aliases = []
                  , spec = NativeObject (contentDigest (TE.encodeUtf8 version))
                  , lifecycle = Retain
                  , dataPolicy = Durable (RecoveryIntent (expectOk (mkName "backup")) (mkSecretRef (expectOk (mkName "credential")) (expectOk (mkName "v1")) :| []))
                  , sensitivity = Public
                  , dependencies = []
                  , delegations = []
                  , source = SourceLocation "test" "data"
                  }
            ]
            []
            []
            []
            []
            []
        ]
    )
  where
    cluster = mintResourceId incarnationOwner (expectOk (mkLogicalKey "cluster")) (expectOk (mkName "cluster"))

statefulId :: ResourceId
statefulId = mintResourceId incarnationOwner (expectOk (mkLogicalKey "statefulset")) (expectOk (mkName "resource"))

-- A database's StatefulSet is Stateless; its data lives on the durable PVC.
statefulScope :: ScopeDeclaration
statefulScope =
  expectOk
    ( mkScopeDeclaration
        incarnationOwner
        [ ResourceBundle
            [ Managed
                ManagedResource
                  { identity = statefulId
                  , owner = incarnationOwner
                  , executor = KubernetesExecutor
                  , address = Kubernetes cluster "apps" (expectOk (mkName "statefulset")) (Just (expectOk (mkName "personal"))) (expectOk (mkName "pg"))
                  , aliases = []
                  , spec = StatefulSet 1 [] (contentDigest "statefulset")
                  , lifecycle = Retain
                  , dataPolicy = Stateless
                  , sensitivity = Public
                  , dependencies = []
                  , delegations = []
                  , source = SourceLocation "test" "statefulset"
                  }
            ]
            []
            []
            []
            []
            []
        ]
    )
  where
    cluster = mintResourceId incarnationOwner (expectOk (mkLogicalKey "cluster")) (expectOk (mkName "cluster"))

-- The four accepted members that receipt ingestion binds before it reads any evidence.
databaseScope :: ScopeDeclaration
databaseScope =
  expectOk
    ( mkScopeDeclaration
        databaseOwner
        [ResourceBundle [Managed (kubernetes role group kind name) | (role, group, kind, name) <- members] [] [] [] [] []]
    )
  where
    members =
      [ ("statefulset", "apps", "statefulset", "pg")
      , ("pvc", "", "persistentvolumeclaim", dbPvcName "pg")
      , ("cronjob", "batch", "cronjob", "nagare-dbbackup-pg")
      , ("signing", "", "secret", "nagare-dbbackup-pg-signing")
      ]
    cluster = mintResourceId databaseOwner (expectOk (mkLogicalKey "cluster")) (expectOk (mkName "cluster"))
    kubernetes role group kind name =
      ManagedResource
        { identity = databaseMember role
        , owner = databaseOwner
        , executor = KubernetesExecutor
        , address = Kubernetes cluster group (expectOk (mkName kind)) (Just (expectOk (mkName "personal"))) (expectOk (mkName name))
        , aliases = []
        , spec = if kind == "statefulset" then StatefulSet 1 [] (contentDigest (TE.encodeUtf8 role)) else NativeObject (contentDigest (TE.encodeUtf8 role))
        , lifecycle = Retain
        , dataPolicy = Stateless
        , sensitivity = Public
        , dependencies = []
        , delegations = []
        , source = SourceLocation "test" role
        }

databaseOwner :: ScopeId
databaseOwner = expectOk (mkScopeId Standalone "database-pg")

databaseMember :: Text -> ResourceId
databaseMember role = mintResourceId databaseOwner (expectOk (mkLogicalKey role)) (expectOk (mkName "resource"))

-- A structurally valid request whose live source is uid-live-sts / uid-live-pvc.
ingestRequest :: Map ResourceId PhysicalIdentity -> ScheduledIngestRequest
ingestRequest recorded =
  ScheduledIngestRequest
    { ingestDatabase = "pg"
    , ingestNamespace = "personal"
    , ingestBackupId = "job-1"
    , ingestSourceRevision = ScopeRevision (expectOk (mkScopeGeneration 1)) (contentDigest "source")
    , ingestStatefulUid = uid "uid-live-sts"
    , ingestPvcUid = uid "uid-live-pvc"
    , ingestScheduleUid = uid "uid-cron"
    , ingestSigningUid = uid "uid-signing"
    , ingestEvidence =
        ScheduledReceiptEvidence
          { scheduledReceipt = ScheduledBackupReceipt (uid "job-1") "databases/pg/job-1.sql.gz" (T.replicate 64 "0") (contentDigest "schedule") Nothing
          , scheduledObjectVersion = "1"
          , scheduledReceiptVersion = "1"
          , scheduledObjectLength = 1
          , scheduledReceiptLength = 1
          , scheduledReceiptDigest = contentDigest "receipt"
          }
    , ingestBackend = GcsBackend "project" "bucket"
    , ingestSource = SourceLocation "test" "ingest"
    , ingestAcceptedIncarnations = recorded
    }

uid :: Text -> PhysicalIdentity
uid = expectOk . mkPhysicalIdentity

expectOk :: (Show e) => Either e a -> a
expectOk = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
