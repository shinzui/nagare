-- | EP-183 M4 (ADR 27 amendment): a reviewed rebuild recreates an accepted
-- durable member whose object is gone as a new incarnation, naming the
-- predecessor it succeeds and where the new incarnation's data comes from.
module InventoryRebuildSpec (inventoryRebuildTests) where

import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend), storeObjectUrl)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Inventory.Lineage
import Nagare.Inventory.LineageHistory (RebuildLineage (..), memberLineage)
import Nagare.Inventory.Plan
import Nagare.Inventory.Rebuild (RebuildInput (..), RebuildTarget (..), decideRebuild, rebuildTargets)
import Nagare.Inventory.RebuildRestore (RebuildRestoreRequest (..), compileRebuildRestoreScope)
import Nagare.Inventory.Restore (manualRestoreJobTargetPins)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures qualified as Fixtures
import Test.Tasty
import Test.Tasty.HUnit

inventoryRebuildTests :: TestTree
inventoryRebuildTests =
  testGroup
    "reviewed rebuild of a missing durable member (EP-183 M4)"
    [ testCase "a rebuild recreates a confirmed-absent volume as a new incarnation and records its lineage in the review" $ do
        (store, live) <- acceptedVolume
        writeIORef (live ^. #current) Nothing
        -- Without a decision, planning still refuses the missing durable member.
        refused <- try @SomeException (convergeDeciding store live (\_ _ _ -> Right noLifecycleDecisions))
        assertBool "a missing volume was recreated without a decision" (refusedWith "durable-resource-missing" refused)
        writeIORef (live ^. #nextUid) "uid-rebuilt"
        document <- convergeDeciding store live (rebuild accepted (FromRecoveryPoint point))
        incarnations store >>= (@?= Map.singleton volumeId (uid "uid-rebuilt"))
        reviewRebuilds document @?= Map.singleton volumeId (RebuildProof accepted (FromRecoveryPoint point))
        [plannedAction (reviewPlannedOperation entry) | entry <- reviewOperations document] @?= [CreateResource]
    , testCase "a rebuild names the recorded incarnation, a recovery point only of a recorded predecessor, and an absent member" $ do
        (store, live) <- acceptedVolume
        writeIORef (live ^. #current) Nothing
        wrong <- try @SomeException (convergeDeciding store live (rebuild (Just (uid "uid-other")) (FromRecoveryPoint point)))
        assertBool ("a rebuild naming another incarnation was approved: " <> show wrong) (refusedWith "invalid-rebuild" wrong)
        unrecorded <- try @SomeException (convergeDeciding store live (rebuild Nothing (FromRecoveryPoint point)))
        assertBool "a recorded member was rebuilt as unrecorded" (refusedWith "invalid-rebuild" unrecorded)
        writeIORef (live ^. #current) (Just (uid "uid-accepted"))
        present <- try @SomeException (convergeDeciding store live (rebuild accepted (FromRecoveryPoint point)))
        assertBool "a present member was rebuilt" (refusedWith "rebuild-incarnation" present)
        writeIORef (live ^. #current) Nothing
        twice <- try @SomeException (convergeDeciding store live (decideWith [target accepted (FromRecoveryPoint point), target accepted Fresh]))
        assertBool "a member was rebuilt twice in one input" (refusedWith "duplicate-rebuild" twice)
        incarnations store >>= (@?= Map.singleton volumeId (uid "uid-accepted"))
        -- A volume may start fresh, by the operator's explicit choice.
        writeIORef (live ^. #nextUid) "uid-fresh"
        _ <- convergeDeciding store live (rebuild accepted Fresh)
        incarnations store >>= (@?= Map.singleton volumeId (uid "uid-fresh"))
    , testCase "a member with no recorded incarnation is rebuilt only fresh" $ do
        (store, live) <- acceptedVolume
        clearIncarnations store
        writeIORef (live ^. #current) Nothing
        withPoint <- try @SomeException (convergeDeciding store live (rebuild Nothing (FromRecoveryPoint point)))
        assertBool "an unrecorded member received a recovery point" (refusedWith "invalid-rebuild" withPoint)
        writeIORef (live ^. #nextUid) "uid-fresh"
        _ <- convergeDeciding store live (rebuild Nothing Fresh)
        incarnations store >>= (@?= Map.singleton volumeId (uid "uid-fresh"))
    , testCase "admission refuses a rebuild whose member reappeared after review" $ do
        (store, live) <- acceptedVolume
        writeIORef (live ^. #current) Nothing
        reviewed <- reviewDeciding store live (rebuild accepted (FromRecoveryPoint point))
        writeIORef (live ^. #current) (Just (uid "uid-out-of-band"))
        applied <- applyReviewed store (registryOf live) reviewed
        case applied of
          Left errors -> assertBool (show errors) (any (("no longer confirmed absent" `T.isInfixOf`) . admissionErrorMessage) errors)
          Right other -> assertFailure ("a reappeared member was rebuilt: " <> show other)
        incarnations store >>= (@?= Map.singleton volumeId (uid "uid-accepted"))
    , testCase "rebuild targets name each missing durable member's recorded incarnation" $ do
        (store, live) <- acceptedVolume
        writeIORef (live ^. #current) Nothing
        history <- loadInventoryHistory store >>= expectRight
        let candidate = candidateFor history
            absent = expectOk (observationSet [(volumeId, ConfirmedAbsent (contentDigest "absent"))])
            choose _ predecessor = Right (maybe Fresh (const (FromRecoveryPoint point)) predecessor)
        fmap (map (^. #proof)) (rebuildTargets candidate history absent choose) @?= Right [RebuildProof accepted (FromRecoveryPoint point)]
        either (map planErrorCode . NE.toList) (const []) (rebuildTargets candidate history absent (\member _ -> Left (PlanError "rebuild-recovery-point" "none" [member]))) @?= ["rebuild-recovery-point"]
        -- A present member is not rebuilt.
        rebuildTargets candidate history (expectOk (observationSet [(volumeId, ObservedPresent (uid "uid-accepted"))])) choose @?= Right []
    , testCase "a rebuild input and review proof round-trip, with exactly one source" $ do
        let input = RebuildInput fixtureBinding [target accepted (FromRecoveryPoint point), target Nothing Fresh]
        Aeson.eitherDecode (Aeson.encode input) @?= Right input
        assertBool "a rebuild with two sources decoded" (isLeftOf (Aeson.eitherDecode @RebuildProof "{\"fresh\":true,\"recoveryPoint\":{\"kind\":\"manual\",\"receipt\":\"r\",\"receiptDigest\":\"0000000000000000000000000000000000000000000000000000000000000000\"}}"))
        assertBool "a rebuild with fresh false decoded" (isLeftOf (Aeson.eitherDecode @RebuildProof "{\"fresh\":false}"))
        assertBool "a rebuild with an unknown field decoded" (isLeftOf (Aeson.eitherDecode @RebuildProof "{\"fresh\":true,\"rebind\":true}"))
    , testCase "the journal records the rebuilt incarnation's lineage, and only a rebuild's create has one" $ do
        (store, live) <- acceptedVolume
        lineageOf store >>= (@?= Right Nothing)
        writeIORef (live ^. #current) Nothing
        writeIORef (live ^. #nextUid) "uid-rebuilt"
        document <- convergeDeciding store live (rebuild accepted (FromRecoveryPoint point))
        rebuilt <- lineageOf store
        fmap (fmap (\found -> (found ^. #incarnation, found ^. #proof, found ^. #review))) rebuilt
          @?= Right (Just (uid "uid-rebuilt", RebuildProof accepted (FromRecoveryPoint point), contentDigest (encodeReviewDocument document)))
        -- A later review that only verifies the member keeps the lineage.
        _ <- convergeDeciding store live (\_ _ _ -> Right noLifecycleDecisions)
        lineageOf store >>= (@?= rebuilt)
    , testCase "a rebuild restore loads only the named recovery point into the incarnation the rebuild created (ADR 27 amendment)" $ do
        let compiled request = compileRebuildRestoreScope request Fixtures.databaseScope Fixtures.databaseNative
            refusal request = either (\errors -> T.intercalate "; " [err ^. #message | err <- NE.toList errors]) (const "") (compiled request)
        case compiled restoreRequest of
          Left errors -> assertFailure (show errors)
          Right (scope, native) -> do
            Map.lookup "restore.target.pvc.uid" (scopeOverrides scope) @?= Just "uid-rebuilt-pvc"
            Map.lookup "restore.rebuild.predecessor" (scopeOverrides scope) @?= Just "uid-old-pvc"
            [pins | (_, bytes) <- Map.elems native, Right (Just pins) <- [manualRestoreJobTargetPins bytes]]
              @?= [[(Fixtures.statefulId, uid "uid-live-sts"), (Fixtures.pvcId, uid "uid-rebuilt-pvc")]]
            assertBool "the Job does not refuse a non-empty database" (any (\(_, bytes) -> "refusing to restore over data" `T.isInfixOf` TE.decodeUtf8 bytes) (Map.elems native))
        assertBool "a restore into the predecessor's incarnation compiled" ("not the incarnation a reviewed rebuild created" `T.isInfixOf` refusal restoreRequest {targetPvcUid = uid "uid-old-pvc"})
        assertBool "a restore into an incarnation no rebuild named compiled" ("not the incarnation a reviewed rebuild created" `T.isInfixOf` refusal restoreRequest {targetPvcUid = uid "uid-other-pvc"})
        assertBool "a rebuild of another member authorized the volume" ("not the incarnation a reviewed rebuild created" `T.isInfixOf` refusal restoreRequest {lineage = restoreLineage & #resource .~ Fixtures.statefulId})
        assertBool "a receipt verified with another incarnation's escrow compiled" ("escrow of another incarnation" `T.isInfixOf` refusal restoreRequest {escrowPvcUid = uid "uid-other-pvc"})
        assertBool "another receipt than the named recovery point compiled" ("not the recovery point the rebuild named" `T.isInfixOf` refusal restoreRequest {evidence = restoreEvidence {scheduledReceiptDigest = contentDigest "another receipt"}})
        assertBool "a fresh rebuild authorized a restore" ("names no recovery point" `T.isInfixOf` refusal restoreRequest {lineage = restoreLineage & #proof . #source .~ Fresh})
    ]
  where
    accepted = Just (uid "uid-accepted")
    point = RecoveryPoint ScheduledRecoveryPoint "gs://bucket/databases/pg/job-1.sql.gz.receipt.json" (contentDigest "receipt")
    rebuild predecessor source' = decideWith [target predecessor source']
    decideWith targets candidate history observations = decideRebuild candidate history observations (RebuildInput fixtureBinding targets)
    target predecessor source' = RebuildTarget volumeId volumeAddress (RebuildProof predecessor source')
    refusedWith code = either ((code `T.isInfixOf`) . T.pack . show) (const False)
    isLeftOf = either (const True) (const False)

lineageOf :: InventoryStore -> IO (Either Text (Maybe RebuildLineage))
lineageOf store = do
  current <- readHead store >>= expectRight >>= maybe (assertFailure "no head" >> pure (error "unreachable")) pure
  memberLineage store current volumeId

restoreObject :: Text
restoreObject = storeObjectUrl restoreBackend "databases/pg/job-1.sql.gz"

restoreBackend :: StoreBackend
restoreBackend = GcsBackend "project" "bucket"

restoreEvidence :: ScheduledReceiptEvidence
restoreEvidence = ScheduledReceiptEvidence (ScheduledBackupReceipt (uid "job-1") restoreObject (T.replicate 64 "a") (contentDigest "schedule") Nothing) "11" "12" 100 10 (contentDigest "receipt bytes")

restoreLineage :: RebuildLineage
restoreLineage =
  RebuildLineage
    Fixtures.pvcId
    (uid "uid-rebuilt-pvc")
    (RebuildProof (Just (uid "uid-old-pvc")) (FromRecoveryPoint (RecoveryPoint ScheduledRecoveryPoint (restoreObject <> ".receipt.json") (contentDigest "receipt bytes"))))
    (contentDigest "rebuild review")

restoreRequest :: RebuildRestoreRequest
restoreRequest =
  RebuildRestoreRequest
    { database = "pg"
    , namespace = "personal"
    , restoreId = "rebuild-1"
    , targetRevision = ScopeRevision (expectOk (mkScopeGeneration 2)) (contentDigest "database revision")
    , targetStatefulUid = uid "uid-live-sts"
    , targetPvcUid = uid "uid-rebuilt-pvc"
    , lineage = restoreLineage
    , escrowPvcUid = uid "uid-old-pvc"
    , evidence = restoreEvidence
    , backend = restoreBackend
    , source = SourceLocation "test" "rebuild-restore"
    }

-- | Drop every recorded incarnation, as a store whose create lost its response has none.
clearIncarnations :: InventoryStore -> IO ()
clearIncarnations store = do
  current <- readHead store >>= expectRight >>= maybe (assertFailure "no head" >> pure (error "unreachable")) pure
  _ <- replaceHeadIfGenerationMatches store (Just (headGeneration current)) current {headGeneration = headGeneration current + 1, headIncarnations = Map.empty} >>= expectRight
  pure ()

-- | A store whose volume converged as uid-accepted, and the adapter's live object.
acceptedVolume :: IO (InventoryStore, Live)
acceptedVolume = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "rebuild-test" >>= expectRight
  live <- Live <$> newIORef Nothing <*> newIORef "uid-accepted"
  _ <- convergeDeciding store live (\_ _ _ -> Right noLifecycleDecisions)
  incarnations store >>= (@?= Map.singleton volumeId (uid "uid-accepted"))
  pure (store, live)

-- | The member's live object, and the UID the adapter's next create returns.
data Live = Live
  { current :: !(IORef (Maybe PhysicalIdentity))
  , nextUid :: !(IORef Text)
  }
  deriving stock (Generic)

type Decide = CompositionCandidate -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions

candidateFor :: InventoryHistory -> CompositionCandidate
candidateFor history =
  expectOk (composeInventory (expectOk (mkScopeSnapshot fixtureBinding (Map.map (\(revision, scope) -> (revisionGeneration revision, scope)) (historyAccepted history)) (historyReservations history))) (ReplaceScope volumeScope :| []))

reviewDeciding :: InventoryStore -> Live -> Decide -> IO ReviewedPlan
reviewDeciding store live decide = do
  history <- loadInventoryHistory store >>= expectRight
  let candidate = candidateFor history
      registry = registryOf live
  observations <- observeWithRegistry registry (Map.singleton KubernetesExecutor (Set.toList (requiredResources (observationRequirements candidate history)))) >>= expectRight
  decisions <- either (assertFailure . show) pure (decide candidate history observations)
  proposal <- either (assertFailure . show) pure (planChanges candidate decisions history observations)
  before <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry before proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  after <- readStoreSnapshot store >>= expectRight
  either (assertFailure . show) pure (verifyReview after bundle)

convergeDeciding :: InventoryStore -> Live -> Decide -> IO ReviewDocument
convergeDeciding store live decide = do
  reviewed <- reviewDeciding store live decide
  applied <- applyReviewed store (registryOf live) reviewed >>= expectRight
  case applied of
    Converged _ -> pure (reviewedDocument reviewed)
    other -> assertFailure ("expected convergence, got " <> show other) >> pure (reviewedDocument reviewed)

incarnations :: InventoryStore -> IO (Map ResourceId PhysicalIdentity)
incarnations store = readHead store >>= expectRight >>= maybe (assertFailure "no head" >> pure Map.empty) (pure . headIncarnations)

-- | A Kubernetes adapter over one member: absent until a create returns
-- 'nextUid', as the API server does.
registryOf :: Live -> AdapterRegistry
registryOf live =
  expectOk
    ( mkAdapterRegistry
        [ Adapter
            { adapterExecutor = KubernetesExecutor
            , adapterIdentity = "rebuild"
            , adapterVersion = "1"
            , adapterObserve = \resources -> do
                observed <- readIORef (live ^. #current)
                pure (observationSet [(resource, maybe (ConfirmedAbsent (contentDigest "absent")) ObservedPresent observed) | resource <- resources])
            , adapterPrepare = \operation -> pure (Right (PreparedNative (BL.toStrict (Aeson.encode (operationIdText (plannedOperationId operation)))) "rebuild adapter"))
            , adapterPreflight = \_ _ -> pure (Right ())
            , adapterExecute = \_ _ -> do
                created <- uid <$> readIORef (live ^. #nextUid)
                writeIORef (live ^. #current) (Just created)
                pure (AdapterEffectIdentified created AdapterEffectCompleted)
            , adapterVerify = \operation _ -> pure (Right (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
            , adapterSettle = Nothing
            , adapterRecover = \_ _ -> pure RecoverySafeToRetry
            }
        ]
    )

rebuildOwner :: ScopeId
rebuildOwner = expectOk (mkScopeId Standalone "rebuild-db")

volumeId :: ResourceId
volumeId = mintResourceId rebuildOwner (expectOk (mkLogicalKey "data")) (expectOk (mkName "resource"))

volumeAddress :: ProviderAddress
volumeAddress = Kubernetes (mintResourceId rebuildOwner (expectOk (mkLogicalKey "cluster")) (expectOk (mkName "cluster"))) "" (expectOk (mkName "persistentvolumeclaim")) (Just (expectOk (mkName "personal"))) (expectOk (mkName "data"))

volumeScope :: ScopeDeclaration
volumeScope =
  expectOk
    ( mkScopeDeclaration
        rebuildOwner
        [ ResourceBundle
            [ Managed
                ManagedResource
                  { identity = volumeId
                  , owner = rebuildOwner
                  , executor = KubernetesExecutor
                  , address = volumeAddress
                  , aliases = []
                  , spec = NativeObject (contentDigest "volume")
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

uid :: Text -> PhysicalIdentity
uid = expectOk . mkPhysicalIdentity

expectOk :: (Show e) => Either e a -> a
expectOk = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
