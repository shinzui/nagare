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
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.App.Deploy
import Nagare.Dsl.Load (loadApplication)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (mkImageRef)
import Nagare.Target (Mode (..), PulumiBackendKind (..), TargetProfile (..))
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

appDeployTests :: TestTree
appDeployTests =
  testGroup
    "Nagare.App.Deploy (EP-2)"
    [ testGroup "render + shared label (M1)" renderTests
    , testGroup "rollout phases (M2)" phaseTests
    , testGroup "machine-readable plan (M3)" planTests
    , testGroup "remediation guardrails (EP-6)" remediationTests
    ]

fixturePath :: FilePath
fixturePath = "test/fixtures/app/kizashi/Config.hs"

-- | A deterministic rollout context (fixed tag, unqualified shared image) so the
-- rendered bytes are stable.
testEnv :: RolloutEnv
testEnv =
  RolloutEnv
    { appName = "kizashi"
    , qualifiedImage = unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go")
    , imageTag = "20260619-120000"
    , effectiveTag = "20260619-120000"
    , taggedAppImage = "gcr.io/knative-samples/helloworld-go:20260619-120000"
    , appEnv = Map.empty
    , namespace = "personal"
    , baseDomain = "apps.example.com"
    , targetProfile = testProfile
    }

testProfile :: TargetProfile
testProfile =
  TargetProfile
    { project = "tan-nb-exp"
    , region = "us-west1"
    , zone = "us-west1-a"
    , registryHost = "us-west1-docker.pkg.dev"
    , artifactRegistryId = "nagare"
    , imageBucket = "tan-nb-exp-nagare-images"
    , backupBucket = "tan-nb-exp-nagare-backups"
    , nixCacheEnabled = False
    , nixCacheBucket = "tan-nb-exp-nagare-nix-cache"
    , baseDomain = "apps.example.com"
    , instanceName = "nagare-01"
    , machineType = "e2-standard-2"
    , bootDiskType = "pd-balanced"
    , bootDiskSizeGb = "100"
    , dataDiskSizeGb = "100"
    , targetPlatform = "linux/amd64"
    , mode = Cloud
    , localObjectStore = ""
    , pulumiBackend = PulumiBackendLocal
    , pulumiBackendUrl = ""
    , acmeEmail = "ops@example.com"
    , acmeDirectory = "production"
    , platformVersion = Nothing
    }

renderTests :: [TestTree]
renderTests =
  [ testCase "renders hook, databases, service, and workers in rollout order" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          objects <- unwrapRender (renderAppObjects testEnv app)
          map fst objects
            @?= ["namespace", "hook", "database", "database", "database", "service", "worker", "worker", "worker"]
  , testCase "the rollout begins with the public-certificate namespace opt-in" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          objects <- unwrapRender (renderAppObjects testEnv app)
          case objects of
            (("namespace", manifest) : _) -> do
              assertBool "is a Namespace" (BS.isInfixOf "\"kind\":\"Namespace\"" manifest)
              assertBool "opts into wildcard TLS" (BS.isInfixOf "\"nagare.dev/app-namespace\":\"true\"" manifest)
            _ -> assertFailure "namespace action was not first"
  , testCase "every rendered workload object carries the shared nagare.dev/app label" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          objects <- unwrapRender (renderAppObjects testEnv app)
          forM_ (filter ((/= "namespace") . fst) objects) $ \(ph, bs) ->
            assertBool
              ("object in phase '" <> T.unpack ph <> "' is missing nagare.dev/app: kizashi")
              (BS.isInfixOf "nagare.dev/app: kizashi" bs)
  , testCase "the rendered service is the kizashi-serve Knative Service" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          objects <- unwrapRender (renderAppObjects testEnv app)
          let svcBytes = [bs | (ph, bs) <- objects, ph == "service"]
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
          plan <- unwrapRender (renderPlan testEnv app)
          plan ^. #app @?= "kizashi"
          plan ^. #image @?= "gcr.io/knative-samples/helloworld-go:20260619-120000"
          map (^. #phase) (plan ^. #objects)
            @?= ["namespace", "hook", "database", "database", "database", "service", "worker", "worker", "worker"]
  , testCase "every plan object's labels carry nagare.dev/app = the app" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          plan <- unwrapRender (renderPlan testEnv app)
          forM_ (filter ((/= "namespace") . (^. #phase)) (plan ^. #objects)) $ \o ->
            Map.lookup "nagare.dev/app" (o ^. #labels) @?= Just "kizashi"
  , testCase "the plan encodes to a single parseable JSON document" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          plan <- unwrapRender (renderPlan testEnv app)
          let bytes = LBS.toStrict (Aeson.encode plan)
          case Aeson.eitherDecodeStrict bytes :: Either String Aeson.Value of
            Left e -> assertFailure ("plan JSON did not parse: " <> e)
            Right _ -> pure ()
          assertBool "JSON names the app" (BS.isInfixOf "\"app\":\"kizashi\"" bytes)
  ]

remediationTests :: [TestTree]
remediationTests =
  [ testCase "waitResult converts readiness failures to PhaseFailed" $ do
      waitResult "service 'kizashi-serve'" ExitSuccess @?= PhaseOk
      case waitResult "service 'kizashi-serve'" (ExitFailure 1) of
        PhaseFailed message ->
          assertBool "failure names the readiness problem" ("did not become Ready" `T.isInfixOf` message)
        PhaseOk -> assertFailure "non-zero readiness wait unexpectedly succeeded"
  , testCase "stampAppLabel fails loudly when the managed-by anchor is absent" $ do
      let unstamped = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n"
          result = stampAppLabel "kizashi" unstamped
      assertBool "anchor-less manifest is rejected" (isLeft result)
      case result of
        Left message ->
          assertBool "error identifies the missing anchor" ("nagare.dev/managed-by" `T.isInfixOf` message)
        Right _ -> assertFailure "anchor-less manifest unexpectedly stamped"
  , testCase "stampAppLabel verifies the top-level metadata label structurally" $ do
      let unstamped =
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n  labels:\n    nagare.dev/managed-by: nagarectl\n"
      stamped <- unwrapRender (stampAppLabel "kizashi" unstamped)
      topLevelAppLabel stamped @?= Just "kizashi"
  , testCase "stampAppLabel is byte-identical when already stamped" $ do
      let stamped =
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n  labels:\n    nagare.dev/managed-by: nagarectl\n    nagare.dev/app: kizashi\n"
      stampAppLabel "kizashi" stamped @?= Right stamped
  ]

unwrapRender :: Either Text a -> IO a
unwrapRender (Right value) = pure value
unwrapRender (Left message) = do
  _ <- assertFailure (T.unpack message)
  pure (error "unreachable after assertFailure")

topLevelAppLabel :: BS.ByteString -> Maybe Text
topLevelAppLabel bytes = do
  Aeson.Object top <- either (const Nothing) Just (Yaml.decodeEither' bytes)
  Aeson.Object metadata <- KeyMap.lookup "metadata" top
  Aeson.Object labels <- KeyMap.lookup "labels" metadata
  Aeson.String value <- KeyMap.lookup "nagare.dev/app" labels
  pure value

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> T.unpack e)
