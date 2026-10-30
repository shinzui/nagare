-- | EP-228 M2: independent stateless updates await readiness together.
-- Through the production planner, driver and Kubernetes runtime over the fake
-- API server, each Deployment's rollout takes 300 ms of real time: four
-- independent updates overlap, a dependency chain stays sequential, and a
-- stuck update stops the transaction with the others completed once.
module PlatformRolloutSpec (platformRolloutTests) where

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Contract.Trace (OperationRecord (RecordExecuted), TraceOutcome (OutcomeCompleted), operationTotal)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterRegistry, OperationAction (CreateResource, RetireResource, UpdateResource), PlannedOperation (..), mkAdapterRegistry, withOverlapCapability)
import Nagare.Inventory.Adapters.KubernetesApplication (kubernetesExecutionAdapter, kubernetesOverlapAddress, kubernetesPlanningAdapter)
import Nagare.Inventory.Command (convergeInventoryCandidateResult, loadTargetSnapshot, openTargetStore)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..))
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.KubernetesTransport (KubectlRequest, KubectlResult, KubernetesRuntimeConfig (..), countedTransport, runKubectlWith, withKubectlInterpreter)
import Nagare.Inventory.Plan (ReviewBundle, reviewBundleDocument, reviewPlannedOperation, reviewValidations)
import Nagare.Inventory.Store (initializeStore)
import Nagare.Inventory.Store.Counters (collectCommandTrace)
import Nagare.Inventory.Trace (commandTraceDocument)
import Nagare.Resource.Inventory (Declaration (..), Executor (KubernetesExecutor), ManagedResource, ResourceBundle (..), ScopeChange (ReplaceScope), composeInventory, mkScopeDeclaration)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced, Retain), RecoveryClass (Idempotent), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target (ActiveTarget (..), Mode (Local), mkContextName)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.World.Adversary (Adversary (..), Boundary (..), Call (MutateCall), Fault (LandsUnready), newAdversary)
import Nagare.Test.World.ApiServer (emptyServer)
import Nagare.Test.World.Cluster (Cluster, clusterAnswer, newCluster)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

platformRolloutTests :: TestTree
platformRolloutTests =
  testGroup
    "PlatformRollout (EP-228 M2)"
    [ testCase "four independent Deployment updates await readiness together" $ do
        (elapsed, highest, result, _) <- updateDeployments False 0
        assertConverged result
        highest @?= 4
        -- Serially, four 300 ms rollouts take 1.2 s.
        assertBool ("four overlapped rollouts took " <> show elapsed <> " ms") (elapsed < 900)
    , testCase "a dependency chain of four Deployments rolls out one at a time" $ do
        (elapsed, highest, result, _) <- updateDeployments True 0
        assertConverged result
        highest @?= 1
        assertBool ("a chain took only " <> show elapsed <> " ms") (elapsed >= 1200)
    , testCase "a stuck update stops the transaction; the others complete exactly once" $ do
        (_, _, result, executed) <- updateDeployments False 2
        case result of
          StoppedAmbiguous {} -> pure ()
          other -> assertFailure ("a stuck rollout did not stop the transaction: " <> show other)
        executed @?= 4
    , testCase "only stateless workload creates and updates may overlap" $ do
        let operation kind policy action = (specs, PlannedOperation (ok (mkOperationId "op-eligible")) action KubernetesExecutor (identity :| []) (contentDigest "input") [] Idempotent)
              where
                specs = Map.singleton identity (resourceOf kind policy, "")
                identity = resourceOf kind policy ^. #identity
            eligible kind policy action = isJust (uncurry kubernetesOverlapAddress (operation kind policy action))
        eligible ("apps", "deployment") Stateless UpdateResource @?= True
        eligible ("apps", "deployment") Stateless CreateResource @?= True
        eligible ("apps", "statefulset") Stateless UpdateResource @?= False
        eligible ("batch", "job") Stateless UpdateResource @?= False
        eligible ("apps", "deployment") Stateless RetireResource @?= False
    ]

assertConverged :: TransactionResult -> Assertion
assertConverged = \case
  Converged _ -> pure ()
  other -> assertFailure ("the rollout did not converge: " <> show other)

-- | Converge four Deployments at image v1, then update them to v2: the
-- update's wall time in milliseconds, the most rollouts in flight at once,
-- its result and its executed updates. @chained@ orders each after the
-- previous; @stuckAt@, when positive, makes that update write land unready.
updateDeployments :: Bool -> Int -> IO (Integer, Int, TransactionResult, Int)
updateDeployments chained stuckAt = withSystemTempDirectory "platform-rollout" $ \root -> do
  previous <- lookupEnv "XDG_STATE_HOME"
  setEnv "XDG_STATE_HOME" root
  flip finally (maybe (unsetEnv "XDG_STATE_HOME") (setEnv "XDG_STATE_HOME") previous) $ do
    adversary <- newAdversary []
    cluster <- newCluster emptyServer adversary
    store <- openTargetStore target
    _ <- initializeStore store (Resource.ContextBinding context (ok (Resource.mkName "project"))) "platform-rollout" >>= either (fail . show) pure
    inFlight <- newIORef (0 :: Int)
    highest <- newIORef (0 :: Int)
    let config = worldConfig cluster inFlight highest
        declared image = [deployment chained n image | n <- [1 .. 4 :: Int]]
        planning image = do
          adapter <- kubernetesPlanningAdapter False config noCache (Map.fromList [(member ^. #identity, (member, native)) | (member, native) <- declared image])
          either (fail . show) pure (mkAdapterRegistry [adapter])
        converge image = do
          before <- loadTargetSnapshot target
          let candidate = ok (composeInventory before (ReplaceScope (ok (mkScopeDeclaration owner [ResourceBundle [Managed member | (member, _) <- declared image] [] [] [] [] []])) :| []))
          convergeInventoryCandidateResult (\_ _ -> planning image) (\_ -> execution config) target candidate
    (_, initial) <- converge "v1"
    assertConverged initial
    modifyIORef' highest (const 0)
    when (stuckAt > 0) $ modifyIORef' adversary $ \current ->
      current {schedule = [(Boundary MutateCall (Map.findWithDefault 0 MutateCall (counts current) + stuckAt), LandsUnready)]}
    started <- getMonotonicTimeNSec
    ((_, result), traced) <- collectCommandTrace (converge "v2")
    finished <- getMonotonicTimeNSec
    document <- commandTraceDocument "rollout" OutcomeCompleted traced
    (,,,) (fromIntegral ((finished - started) `div` 1000000)) <$> readIORef highest <*> pure result <*> pure (operationTotal RecordExecuted "UpdateResource" document)

-- | An admitted review's registry as the CLI builds it, with the overlap
-- capability.
execution :: KubernetesRuntimeConfig -> ReviewBundle -> IO AdapterRegistry
execution config bundle = do
  specs <- either (fail . T.unpack) pure (kubernetesSpecsFromReview bundle)
  adapter <- kubernetesExecutionAdapter False config noCache specs (map reviewPlannedOperation (reviewValidations (reviewBundleDocument bundle)))
  either (fail . show) pure (mkAdapterRegistry [adapter] >>= withOverlapCapability KubernetesExecutor (kubernetesOverlapAddress specs))

noCache :: Resource.ResourceId -> IO (Either Text Text)
noCache = const (pure (Left "no cache"))

-- | The fake API server behind a transport whose Deployment rollouts take
-- 300 ms, counting how many are in flight.
worldConfig :: Cluster -> IORef Int -> IORef Int -> KubernetesRuntimeConfig
worldConfig cluster inFlight highest =
  withKubectlInterpreter
    (runKubectlWith (countedTransport answer))
    (KubernetesRuntimeConfig context "world" (pure (Right ())))
  where
    answer :: KubectlRequest -> IO KubectlResult
    answer request = case request ^. #arguments of
      "rollout" : "status" : _ -> do
        now <- atomicModifyIORef' inFlight (\n -> (n + 1, n + 1))
        atomicModifyIORef' highest (\h -> (max h now, ()))
        threadDelay 300000
        atomicModifyIORef' inFlight (\n -> (n - 1, ()))
        clusterAnswer cluster request
      _ -> clusterAnswer cluster request

target :: ActiveTarget
target = ActiveTarget (ok (mkContextName "platform-rollout")) (initProfile & #project .~ "project" & #mode .~ Local)

context :: Resource.ContextId
context = ok (Resource.mkContextId "platform-rollout")

owner :: Resource.ScopeId
owner = ok (Resource.mkScopeId Resource.Application "rollout-fixture")

-- | Deployment @n@ at @image@; in a chain it is ordered after @n - 1@.
deployment :: Bool -> Int -> Text -> (ManagedResource, ByteString)
deployment chained n image =
  let name = "web-" <> T.pack (show n)
      (member, native) = bound name (deploymentObject name image) Stateless DeleteWhenUnreferenced
      previousName = "web-" <> T.pack (show (n - 1))
      before = fst (bound previousName (deploymentObject previousName image) Stateless DeleteWhenUnreferenced) ^. #identity
   in (if chained && n > 1 then member & #dependencies .~ [OrderedAfter before] else member, native)

-- | A member of the given kind and data policy, for the eligibility rule.
resourceOf :: (Text, Text) -> DataPolicy -> ManagedResource
resourceOf (group, kind) policy =
  fst
    ( bound
        "member"
        ( Aeson.object
            [ "apiVersion" Aeson..= (if T.null group then "v1" else group <> "/v1")
            , "kind" Aeson..= T.toTitle kind
            , "metadata" Aeson..= Aeson.object ["name" Aeson..= ("member" :: Text), "namespace" Aeson..= ("default" :: Text)]
            , "spec" Aeson..= Aeson.object []
            ]
        )
        policy
        (case policy of Stateless -> DeleteWhenUnreferenced; _ -> Retain)
    )

bound :: Text -> Aeson.Value -> DataPolicy -> LifecyclePolicy -> (ManagedResource, ByteString)
bound name object policy lifecycle =
  ok
    ( bindKubernetesObject
        ( KubernetesInput
            (Resource.mintResourceId owner (ok (Resource.mkLogicalKey name)) (ok (Resource.mkName "workload")))
            owner
            (Resource.mintResourceId (ok (Resource.mkScopeId Resource.Platform "foundation")) (ok (Resource.mkLogicalKey "cluster")) (ok (Resource.mkName "resource")))
            object
            (contentDigest (ok (canonicalValue object)))
            lifecycle
            policy
            Private
            (Resource.SourceLocation "fixture/Rollout.hs" "fixture")
        )
    )

deploymentObject :: Text -> Text -> Aeson.Value
deploymentObject name image =
  Aeson.object
    [ "apiVersion" Aeson..= ("apps/v1" :: Text)
    , "kind" Aeson..= ("Deployment" :: Text)
    , "metadata" Aeson..= Aeson.object ["name" Aeson..= name, "namespace" Aeson..= ("default" :: Text)]
    , "spec"
        Aeson..= Aeson.object
          [ "replicas" Aeson..= (1 :: Int)
          , "selector" Aeson..= Aeson.object ["matchLabels" Aeson..= Aeson.object ["app" Aeson..= name]]
          , "template"
              Aeson..= Aeson.object
                [ "metadata" Aeson..= Aeson.object ["labels" Aeson..= Aeson.object ["app" Aeson..= name]]
                , "spec" Aeson..= Aeson.object ["containers" Aeson..= [Aeson.object ["name" Aeson..= ("app" :: Text), "image" Aeson..= ("registry.local/app:" <> image)]]]
                ]
          ]
    ]

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
