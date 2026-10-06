-- | A Redis isolated restore whose scratch StatefulSet never becomes Ready
-- (its pinned download or load failed) must not wedge the store: the adapter
-- proves the pod failure. Since ADR 26 the legacy abandon decision is a close:
-- the failure is a terminal partial effect and earlier creates completed, so
-- the scope is kept (unconverged, its scratch objects still owned) whatever
-- else the review holds; no review-shape predicate decides it (F36).
module InventoryRedisRestoreRecoverySpec (inventoryRedisRestoreRecoveryTests) where

import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.RestoreScratch (restoreScratchFailureFromPodList)
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

inventoryRedisRestoreRecoveryTests :: TestTree
inventoryRedisRestoreRecoveryTests =
  testGroup
    "Redis restore scratch recovery"
    [ testCase "pod list proves only a failed container owned by the exact StatefulSet" $ do
        let uid = ok (mkPhysicalIdentity "11111111-1111-1111-1111-111111111111")
        restoreScratchFailureFromPodList uid (pods [pod "11111111-1111-1111-1111-111111111111" (initStatus 1 1)]) @?= Right True
        restoreScratchFailureFromPodList uid (pods [pod "11111111-1111-1111-1111-111111111111" (initStatus 0 0)]) @?= Right False
        restoreScratchFailureFromPodList uid (pods [pod "22222222-2222-2222-2222-222222222222" (initStatus 1 1)]) @?= Right False
        restoreScratchFailureFromPodList uid (pods []) @?= Right False
        assertBool "a malformed list was accepted" (isLeft (restoreScratchFailureFromPodList uid (object [])))
    , testCase "a failed scratch StatefulSet closes a Redis restore review, keeping its objects owned" (scenario False)
    , testCase "a review with an extra member closes the same way" (scenario True)
    ]

scenario :: Bool -> IO ()
scenario extraMember = do
  store <- newMemoryStore
  let owner = ok (mkScopeId Standalone "database-restore-personal-cache-r1")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      member role dependencies = scratchMember owner cluster role dependencies
      service = member "service" []
      pvc = member "pvc" []
      stateful = member "statefulset" [OrderedAfter (declarationId service), OrderedAfter (declarationId pvc)]
      job = member "job" [OrderedAfter (declarationId stateful)]
      extra = member "configmap" []
      members = [service, pvc, stateful, job] <> [extra | extraMember]
      overrides =
        Map.fromList
          [ ("restore.id", "r1")
          , ("restore.target.database", "cache")
          , ("restore.backup.scope", "standalone:database-scheduled-receipt-personal-cache-b1")
          , ("restore.target.statefulset.uid", "33333333-3333-3333-3333-333333333333")
          , ("restore.target.pvc.uid", "44444444-4444-4444-4444-444444444444")
          ]
      scope = withScopeOverrides overrides (ok (mkScopeDeclaration owner [ResourceBundle members [] [] [] [] []]))
      statefulId = declarationId stateful
      touches resource operation = resource `elem` NE.toList (plannedResources operation)
      base = ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)
      seed = ok (composeInventory base (ReplaceScope (ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])) :| []))
      candidate = ok (composeInventory base (ReplaceScope scope :| []))
      failed = ok (mkPhysicalIdentity "55555555-5555-5555-5555-555555555555")
      registry =
        recordingRegistryWith
          (\_ _ -> pure (Right ()))
          ( \operation _ ->
              pure
                ( if touches statefulId operation
                    then AdapterEffectAmbiguous "Kubernetes StatefulSet did not prove readiness"
                    else AdapterEffectCompleted
                )
          )
          ( \operation _ ->
              pure
                ( if touches statefulId operation
                    then RecoveryTerminalFailure failed
                    else RecoveryUnresolved "no proof"
                )
          )
  _ <- initializeStore store fixtureBinding "redis-restore-recovery" >>= expectRight
  _ <- seedInventoryHistory store seed >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let observations = ok (observationSet [(declarationId resource, ConfirmedAbsent (contentDigest "absent")) | resource <- members])
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
  let operations = map reviewPlannedOperation (reviewOperations (reviewedDocument reviewed))
      statefulOperation = maybe (error "fixture") plannedOperationId (find (touches statefulId) operations)
  transaction <-
    applyReviewed store registry reviewed >>= expectRight >>= \case
      StoppedAmbiguous tx op -> (op @?= statefulOperation) >> pure tx
      other -> assertFailure (show other) >> undefined
  before <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  recovered <-
    recordOperatorRecovery
      store
      registry
      (OperatorRecoveryInput transaction statefulOperation (reviewDigestFor reviewed) AbandonPartialDatabaseRestore)
      False
  after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  headConverged after @?= headConverged before
  void (expectRight recovered)
  headActiveTransaction after @?= Nothing
  headAccepted after @?= headAccepted before
  void (loadInventoryPlanningHistory store candidate >>= expectRight)

scratchMember :: ScopeId -> ResourceId -> Text -> [Dependency] -> Declaration
scratchMember owner cluster role dependencies =
  Managed
    ManagedResource
      { identity = mintResourceId owner (ok (mkLogicalKey "r1")) (ok (mkName role))
      , owner = owner
      , executor = KubernetesExecutor
      , address = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "personal"))) (ok (mkName ("cache-restore-r1-" <> role)))
      , aliases = []
      , spec = NativeObject (contentDigest (TE.encodeUtf8 role))
      , lifecycle = Retain
      , dataPolicy = Stateless
      , sensitivity = Public
      , dependencies = dependencies
      , delegations = []
      , source = SourceLocation "test" role
      }

pods :: [Value] -> Value
pods items = object ["items" .= items]

pod :: Text -> Value -> Value
pod ownerUid status =
  object
    [ "metadata"
        .= object
          [ "ownerReferences"
              .= [object ["kind" .= ("StatefulSet" :: Text), "uid" .= ownerUid, "controller" .= True]]
          ]
    , "status" .= status
    ]

initStatus :: Int -> Int -> Value
initStatus exitCode restarts =
  object
    [ "initContainerStatuses"
        .= [ object
               [ "name" .= ("download" :: Text)
               , "restartCount" .= restarts
               , "state" .= object ["waiting" .= object ["reason" .= (if exitCode == 0 then "PodInitializing" else "CrashLoopBackOff" :: Text)]]
               , "lastState" .= object ["terminated" .= object ["exitCode" .= exitCode]]
               ]
           ]
    ]

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

reviewDigestFor :: ReviewedPlan -> ContentDigest
reviewDigestFor = contentDigest . encodeReviewDocument . reviewedDocument
