module InventoryPreviewRecoverySpec (inventoryPreviewRecoveryTests) where

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

inventoryPreviewRecoveryTests :: TestTree
inventoryPreviewRecoveryTests =
  testCase "exact incomplete preview route stops only after every sibling create completed" $
    forM_ [(False, False), (True, False), (False, True)] $ \(malformed, pendingSibling) -> do
      store <- newMemoryStore
      (reviewed, registry) <- preparedPreviewStopFixture store malformed pendingSibling
      (transaction, selected) <-
        applyReviewed store registry reviewed >>= expectRight >>= \case
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
      if malformed || pendingSibling
        then do
          assertBool "incomplete or foreign preview contract accepted" (isLeft stopped)
          headActiveTransaction after @?= Just (transactionIdText transaction)
        else do
          void (expectRight stopped)
          headActiveTransaction after @?= Nothing
          headExecutorClaim after @?= Nothing

-- A route can fail after its Service and retained volume were created. The
-- stopped proof must retain that original admitted ownership without inventing
-- readiness or granting a generic standalone-resource abandonment capability.
preparedPreviewStopFixture :: InventoryStore -> Bool -> Bool -> IO (ReviewedPlan, AdapterRegistry)
preparedPreviewStopFixture store malformed pendingSibling = do
  let owner = ok (mkScopeId Standalone "site-preview-web")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      native group kind ns name = Kubernetes cluster group (ok (mkName kind)) (Just (ok (mkName ns))) (ok (mkName name))
      make role address policy lifecycle dependencies = case member owner cluster role of
        Managed resource ->
          Managed
            ( resource
                { address = address
                , dataPolicy = policy
                , lifecycle = lifecycle
                , dependencies = dependencies
                , spec = if role == "service" then KnativeService (contentDigest "service") else NativeObject (contentDigest "member")
                }
            )
        other -> other
      service =
        make
          "service"
          (native "serving.knative.dev" "service" "personal" "web")
          Stateless
          DeleteWhenUnreferenced
          [OrderedAfter (declarationId volume) | not pendingSibling]
      route =
        make
          "route"
          (native "serving.knative.dev" "domainmapping" (if malformed then "foreign" else "personal") "preview.example.test")
          Stateless
          DeleteWhenUnreferenced
          [OrderedAfter (declarationId service)]
      volume =
        make
          "volume"
          (native "" "persistentvolumeclaim" "personal" "nagare-vol-web-data")
          ( Durable
              ( RecoveryIntent
                  (ok (mkName "backup"))
                  (mkSecretRef (ok (mkName "password")) (ok (mkName "v1")) :| [])
              )
          )
          Retain
          [OrderedAfter (declarationId route) | pendingSibling]
      scope = ok (mkScopeDeclaration owner [ResourceBundle [service, route, volume] [] [] [] [] []])
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope scope :| []))
      registry =
        recordingRegistry
          ( \operation _ ->
              pure
                ( if declarationId route `elem` NE.toList (plannedResources operation)
                    then AdapterEffectAmbiguous "route DomainConflict"
                    else AdapterEffectCompleted
                )
          )
          (\_ _ -> pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "original-route-uid"))))
  _ <- initializeStore store fixtureBinding "stop-preview-test" >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let observations = ok (observationSet [(declarationId resource, ConfirmedAbsent (contentDigest "absent")) | resource <- [service, route, volume]])
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
  before <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry before proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  after <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview after bundle)
  pure (reviewed, registry)

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
