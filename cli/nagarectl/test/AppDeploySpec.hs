-- | Tests for @nagarectl app deploy@ orchestration (MasterPlan 14, EP-2).
--
-- M1: rendering an 'Application' fans it out into the right objects, in rollout
-- order, each stamped with the shared @nagare.dev/app@ label. M2: the rollout
-- phase plan is in the fixed order, and a failed pre-deploy hook aborts before any
-- later phase runs. These are offline (the load test spawns @runghc@, exactly as
-- the nagare-dsl loader tests do).
module AppDeploySpec (appDeployTests) where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.App.Deploy
import Nagare.Dsl.Load (loadApplication)
import Nagare.Dsl.Types (mkImageRef)
import Test.Tasty
import Test.Tasty.HUnit

appDeployTests :: TestTree
appDeployTests =
  testGroup
    "Nagare.App.Deploy (EP-2)"
    [ testGroup "render + shared label (M1)" renderTests
    , testGroup "rollout phases (M2)" phaseTests
    , testGroup "machine-readable plan (M3)" planTests
    ]

fixturePath :: FilePath
fixturePath = "test/fixtures/app/kizashi/Config.hs"

-- | A deterministic rollout context (fixed tag, unqualified shared image) so the
-- rendered bytes are stable.
testEnv :: RolloutEnv
testEnv =
  RolloutEnv
    { reAppName = "kizashi"
    , reQualImage = unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go")
    , reImageTag = "20260619-120000"
    , reEffTag = "20260619-120000"
    , reAppImageTagged = "gcr.io/knative-samples/helloworld-go:20260619-120000"
    , reAppEnv = Map.empty
    , reNamespace = "personal"
    , reBaseDomain = "apps.example.com"
    }

renderTests :: [TestTree]
renderTests =
  [ testCase "renders hook, databases, service, and workers in rollout order" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app ->
          map fst (renderAppObjects testEnv app)
            @?= ["hook", "database", "database", "database", "service", "worker", "worker", "worker"]
  , testCase "every rendered object carries the shared nagare.dev/app label" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app ->
          forM_ (renderAppObjects testEnv app) $ \(ph, bs) ->
            assertBool
              ("object in phase '" <> T.unpack ph <> "' is missing nagare.dev/app: kizashi")
              (BS.isInfixOf "nagare.dev/app: kizashi" bs)
  , testCase "the rendered service is the kizashi-serve Knative Service" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          let svcBytes = [bs | (ph, bs) <- renderAppObjects testEnv app, ph == "service"]
          assertBool "one service object" (length svcBytes == 1)
          forM_ svcBytes $ \bs -> do
            assertBool "is a Knative Service" (BS.isInfixOf "kind: Service" bs)
            assertBool "named kizashi-serve" (BS.isInfixOf "name: kizashi-serve" bs)
  ]

phaseTests :: [TestTree]
phaseTests =
  [ testCase "planPhases is hooks, databases, service, workers" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app ->
          map phaseTag (planPhases app) @?= ["hook", "database", "service", "worker"]
  , testCase "a failed hook aborts before any later phase runs" $ do
      ran <- newIORef ([] :: [Text])
      let phases =
            [ PhaseHooks []
            , PhaseDatabases []
            , PhaseWorkers []
            ]
          exec p = do
            modifyIORef' ran (<> [phaseTag p])
            pure $ case p of
              PhaseHooks _ -> PhaseFailed "migration failed"
              _ -> PhaseOk
      result <- runPhases exec phases
      order <- readIORef ran
      result @?= PhaseFailed "migration failed"
      -- only the hook phase ran; databases/workers were never invoked.
      order @?= ["hook"]
  , testCase "all phases run in order when each succeeds" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          ran <- newIORef ([] :: [Text])
          let exec p = modifyIORef' ran (<> [phaseTag p]) >> pure PhaseOk
          r <- runPhases exec (planPhases app)
          order <- readIORef ran
          r @?= PhaseOk
          order @?= ["hook", "database", "service", "worker"]
  ]

planTests :: [TestTree]
planTests =
  [ testCase "renderPlan lists every object in rollout order with the app identity" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          let plan = renderPlan testEnv app
          adpApp plan @?= "kizashi"
          adpImage plan @?= "gcr.io/knative-samples/helloworld-go:20260619-120000"
          map roPhase (adpObjects plan)
            @?= ["hook", "database", "database", "database", "service", "worker", "worker", "worker"]
  , testCase "every plan object's labels carry nagare.dev/app = the app" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app ->
          forM_ (adpObjects (renderPlan testEnv app)) $ \o ->
            Map.lookup "nagare.dev/app" (roLabels o) @?= Just "kizashi"
  , testCase "the plan encodes to a single parseable JSON document" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          let bytes = LBS.toStrict (Aeson.encode (renderPlan testEnv app))
          case Aeson.eitherDecodeStrict bytes :: Either String Aeson.Value of
            Left e -> assertFailure ("plan JSON did not parse: " <> e)
            Right _ -> pure ()
          assertBool "JSON names the app" (BS.isInfixOf "\"app\":\"kizashi\"" bytes)
  ]

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> T.unpack e)
