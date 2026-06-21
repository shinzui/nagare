-- | Tests for the EP-71 long-running-worker model, renderer, and round-trip.
--
-- M1: the smart constructors ('mkReplicas', 'mkCommand') reject invalid input
-- and the 'webWorker' preset yields a runnable default. M2 (renderer goldens)
-- and M3 (emit/decode round-trip + kind discrimination) are added to the groups
-- below as those milestones land.
module WorkerSpec (workerTests) where

import Control.Lens ((&), (.~))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Broker
import Nagare.Dsl.Build
import Nagare.Dsl.Config (encodeDeployment, encodeWorker)
import Nagare.Dsl.Load (LoadError (..), decodeDeployment, decodeWorker, loadWorker)
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Types
import Nagare.Dsl.Worker
import Nagare.Dsl.Worker.Render (renderWorker, renderWorkerDeployment)
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit

workerTests :: TestTree
workerTests =
  testGroup
    "Nagare.Dsl.Worker (EP-71)"
    [ testGroup "mkReplicas" replicasTests
    , testGroup "mkCommand" commandTests
    , testGroup "WorkerProbe" probeTests
    , testGroup "webWorker preset" presetTests
    , testGroup "renderer goldens" renderTests
    , testGroup "JSON round-trip and kind discrimination" roundTripTests
    , testGroup "loadWorker (config-as-program)" loadTests
    ]

replicasTests :: [TestTree]
replicasTests =
  [ testCase "rejects -1" $ assertBool "Left on -1" (isLeft (mkReplicas (-1)))
  , testCase "accepts 0 (paused)" $ assertRight (mkReplicas 0)
  , testCase "accepts 3" $ assertRight (mkReplicas 3)
  , testCase "defaultReplicas is 1" $ replicasInt defaultReplicas @?= 1
  ]

commandTests :: [TestTree]
commandTests =
  [ testCase "rejects []" $ assertBool "Left on empty argv" (isLeft (mkCommand []))
  , testCase "accepts a non-empty argv" $ assertRight (mkCommand ["python", "-m", "worker"])
  , testCase "rejects a NUL in an argument" $
      assertBool "Left on NUL" (isLeft (mkCommand ["bad\NULarg"]))
  , testCase "commandArgvList round-trips the argv" $
      fmap commandArgvList (mkCommand ["sh", "-c", "echo hi"])
        @?= Right ["sh", "-c", "echo hi"]
  ]

-- | EP-74 M1: probe-timing range validation, the exec-argv invariant, the
-- default-timing convenience, and the optional field defaulting to 'Nothing'.
probeTests :: [TestTree]
probeTests =
  [ testCase "mkProbeTiming accepts the defaults" $ assertRight (mkProbeTiming defaultProbeTiming)
  , testCase "mkProbeTiming rejects period 0" $
      assertBool "Left on period 0" (isLeft (mkProbeTiming (timingWith 0 0 1 3)))
  , testCase "mkProbeTiming rejects failureThreshold 0" $
      assertBool "Left on failureThreshold 0" (isLeft (mkProbeTiming (timingWith 0 10 1 0)))
  , testCase "mkProbeTiming rejects negative initialDelay" $
      assertBool "Left on initialDelay -1" (isLeft (mkProbeTiming (timingWith (-1) 10 1 3)))
  , testCase "mkExecProbe rejects empty argv" $
      assertBool "Left on empty argv" (isLeft (mkExecProbe [] defaultProbeTiming))
  , testCase "mkExecProbe rejects a NUL argument" $
      assertBool "Left on NUL" (isLeft (mkExecProbe ["bad\NULarg"] defaultProbeTiming))
  , testCase "mkExecProbe accepts a healthcheck argv" $
      assertRight (mkExecProbe ["/app/healthcheck"] defaultProbeTiming)
  , testCase "execProbe yields the default timing" $
      fmap probeTiming (execProbe ["/app/healthcheck"]) @?= Right defaultProbeTiming
  , testCase "mkHttpProbe rejects a path without a leading slash" $
      assertBool "Left on bad path" (isLeft (mkHttpProbe "healthz" Nothing HTTP defaultProbeTiming))
  , testCase "webWorker preset has no probe (liveness = Nothing)" $
      case webWorker "queue-consumer" "registry/x" of
        Right Worker {liveness = l} -> l @?= Nothing
        Left e -> assertFailure ("expected Right, got Left: " <> e)
  ]
  where
    timingWith d p t f =
      ProbeTiming {initialDelay = d, period = p, timeout = t, failureThreshold = f, asStartup = False}

presetTests :: [TestTree]
presetTests =
  [ testCase "webService-style preset yields Right" $
      assertBool "Right" (isRight (webWorker "queue-consumer" "registry/x"))
  , testCase "preset defaults to defaultReplicas" $
      case webWorker "queue-consumer" "registry/x" of
        Right Worker {replicas = r} -> r @?= defaultReplicas
        Left e -> assertFailure ("expected Right, got Left: " <> e)
  , testCase "preset uses a prebuilt 'latest' build (runnable alone)" $
      case webWorker "queue-consumer" "registry/x" of
        Right Worker {build = b} -> case b of
          PrebuiltImage t -> tagText t @?= "latest"
          other -> assertFailure ("expected PrebuiltImage, got: " <> show other)
        Left e -> assertFailure ("expected Right, got Left: " <> e)
  , testCase "preset rejects a bad name" $
      assertBool "Left on bad name" (isLeft (webWorker "Bad Name" "registry/x"))
  ]

-- ---------------------------------------------------------------------------
-- M2: renderer goldens. 'minimalWorker' is a volume-free worker (one document);
-- 'richWorker' adds a command override, two Runtime env vars (one literal, one
-- secret ref), resource requests+limits, and one volume (PVC + Deployment).

minimalWorker :: Worker
minimalWorker =
  case webWorker "queue-consumer" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/queue-consumer" of
    Right w -> w {replicas = unsafe (mkReplicas 2)}
    Left e -> error ("test fixture invalid: " <> e)

richWorker :: Worker
richWorker =
  minimalWorker
    { command = Just (unsafe (mkCommand ["python", "-m", "worker"]))
    , env =
        Map.fromList
          [ (unsafe (mkEnvName "LOG_LEVEL"), runtimeScoped (EnvLiteral "info"))
          , (unsafe (mkEnvName "API_TOKEN"), runtimeScoped (EnvSecretRef (unsafe (mkSecretName "queue-secret"))))
          ]
    , resources =
        Just
          Resources
            { cpu = Just (unsafe (mkQuantity "100m"))
            , memory = Just (unsafe (mkQuantity "128Mi"))
            , cpuLimit = Just (unsafe (mkQuantity "500m"))
            , memoryLimit = Just (unsafe (mkQuantity "256Mi"))
            }
    , volumes =
        [ Volume
            { volName = unsafe (mkVolumeName "scratch")
            , size = unsafe (mkQuantity "1Gi")
            , mountPath = unsafe (mkMountPath "/scratch")
            , accessMode = ReadWriteOnce
            , readOnly = False
            , retention = Retain
            }
        ]
    }

renderTests :: [TestTree]
renderTests =
  [ goldenVsString
      "renderWorkerDeployment minimal"
      "test/golden/worker-minimal.deployment.yaml"
      (pure (fromStrict (renderWorkerDeployment minimalWorker "20260602-120000")))
  , goldenVsString
      "renderWorkerDeployment rich"
      "test/golden/worker-rich.deployment.yaml"
      (pure (fromStrict (renderWorkerDeployment richWorker "20260602-120000")))
  , goldenVsString
      "renderWorker rich (PVC then Deployment)"
      "test/golden/worker-rich.manifests.yaml"
      (pure (fromStrict (BS.intercalate "---\n" (renderWorker richWorker "20260602-120000"))))
  , testCase "minimal worker renders exactly one document (no volumes)" $
      length (renderWorker minimalWorker "20260602-120000") @?= 1
  , testCase "rich worker renders two documents (PVC + Deployment)" $
      length (renderWorker richWorker "20260602-120000") @?= 2
  , -- EP-74 M3: a probe-bearing worker renders a livenessProbe; a no-probe worker
    -- is byte-identical to today (the minimal/rich goldens above do not change).
    goldenVsString
      "renderWorkerDeployment exec probe"
      "test/golden/worker-exec-probe.deployment.yaml"
      (pure (fromStrict (renderWorkerDeployment execProbeWorker "20260602-120000")))
  , testCase "a no-probe worker renders no livenessProbe" $
      assertBool
        "no livenessProbe"
        (not (BS.isInfixOf "livenessProbe" (renderWorkerDeployment minimalWorker "20260602-120000")))
  , testCase "an exec probe renders livenessProbe.exec.command and no startupProbe" $ do
      let yaml = renderWorkerDeployment execProbeWorker "20260602-120000"
      assertBool "livenessProbe present" (BS.isInfixOf "livenessProbe:" yaml)
      assertBool "exec command present" (BS.isInfixOf "/app/healthcheck" yaml)
      assertBool "no startupProbe" (not (BS.isInfixOf "startupProbe" yaml))
  , testCase "a tcp probe renders tcpSocket.port" $
      assertBool
        "tcpSocket present"
        (BS.isInfixOf "tcpSocket:" (renderWorkerDeployment tcpProbeWorker "20260602-120000"))
  , testCase "asStartup renders both a livenessProbe and a startupProbe" $ do
      let yaml = renderWorkerDeployment startupProbeWorker "20260602-120000"
      assertBool "livenessProbe present" (BS.isInfixOf "livenessProbe:" yaml)
      assertBool "startupProbe present" (BS.isInfixOf "startupProbe:" yaml)
  ]

-- ---------------------------------------------------------------------------
-- M3: emit -> decode round-trip and kind discrimination.

-- | EP-74 M2: probe-bearing workers for the round-trip. Exec is the primary
-- case; TCP and HTTP exercise the other two branches.
execProbeWorker :: Worker
execProbeWorker = minimalWorker {liveness = Just (unsafe (execProbe ["/app/healthcheck"]))}

tcpProbeWorker :: Worker
tcpProbeWorker = minimalWorker {liveness = Just (mkTcpProbe (unsafe (mkPort 9000)) defaultProbeTiming)}

httpProbeWorker :: Worker
httpProbeWorker =
  minimalWorker
    { liveness = Just (unsafe (mkHttpProbe "/healthz" (Just (unsafe (mkPort 8080))) HTTP defaultProbeTiming))
    }

-- | Default timing with @asStartup = True@, built as a full literal so the field
-- update is not ambiguous between 'ProbeTiming' and the app 'HealthCheck'.
startupTiming :: ProbeTiming
startupTiming =
  ProbeTiming {initialDelay = 0, period = 10, timeout = 1, failureThreshold = 3, asStartup = True}

startupProbeWorker :: Worker
startupProbeWorker = minimalWorker {liveness = Just (unsafe (mkExecProbe ["/app/healthcheck"] startupTiming))}

roundTripTests :: [TestTree]
roundTripTests =
  [ testCase "rich worker survives emit -> decode round-trip" $
      decodeWorker (toStrict (encodeWorker richWorker)) @?= Right richWorker
  , testCase "minimal worker round-trips" $
      decodeWorker (toStrict (encodeWorker minimalWorker)) @?= Right minimalWorker
  , testCase "worker broker bindings round-trip" $
      let boundWorker = minimalWorker & #brokers .~ [workerBrokerBinding]
       in decodeWorker (toStrict (encodeWorker boundWorker)) @?= Right boundWorker
  , testCase "exec-probe worker round-trips" $
      decodeWorker (toStrict (encodeWorker execProbeWorker)) @?= Right execProbeWorker
  , testCase "tcp-probe worker round-trips" $
      decodeWorker (toStrict (encodeWorker tcpProbeWorker)) @?= Right tcpProbeWorker
  , testCase "http-probe worker round-trips" $
      decodeWorker (toStrict (encodeWorker httpProbeWorker)) @?= Right httpProbeWorker
  , testCase "decoding a Worker as a Deployment is UnexpectedKind" $
      case decodeDeployment (toStrict (encodeWorker minimalWorker)) of
        Left (UnexpectedKind "Deployment" "Worker") -> pure ()
        other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
  , testCase "decoding a Deployment as a Worker is UnexpectedKind" $
      case decodeWorker (toStrict (encodeDeployment helloDep)) of
        Left (UnexpectedKind "Worker" "<none>") -> pure ()
        other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
  ]

workerBrokerBinding :: BrokerBinding
workerBrokerBinding =
  BrokerBinding
    { name = unsafe (mkBrokerName "events")
    , topics = [unsafe (mkTopicName "jobs")]
    }

-- ---------------------------------------------------------------------------
-- M4 acceptance: the config-as-program fixture loads to the expected Worker via
-- the runghc harness (the same harness the request-driven loadDeployment test
-- uses). The fixture is the queue-worker shape nagarectl's `worker deploy`
-- loads; this proves the full Config.hs -> emitWorker -> loadWorker path.

fixtureWorker :: Worker
fixtureWorker =
  case webWorker "queue-consumer" "gcr.io/knative-samples/helloworld-go" of
    Right w ->
      w
        { command = Just (unsafe (mkCommand ["sh", "-c", "while true; do echo working; sleep 5; done"]))
        , replicas = unsafe (mkReplicas 2)
        }
    Left e -> error ("test fixture invalid: " <> e)

loadTests :: [TestTree]
loadTests =
  [ testCase "loadWorker fixture returns the expected Worker" $ do
      result <- loadWorker "test/fixtures/worker/nagare/Config.hs"
      case result of
        Left err -> assertFailure ("loadWorker returned Left: " <> show err)
        Right w -> w @?= fixtureWorker
  ]

-- | A minimal request-driven 'Deployment' used only to prove kind discrimination
-- (a Deployment carries no top-level "kind", so decoding it as a Worker is
-- 'UnexpectedKind "Worker" "<none>"').
helloDep :: Deployment
helloDep =
  Deployment
    { name = unsafe (mkServiceName "hello")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go")
    , build = unsafe defaultBuild
    , domains = []
    , port = unsafe (mkPort 8080)
    , env = Map.empty
    , resources = Nothing
    , scale = Nothing
    , healthCheck = Nothing
    , volumes = []
    , databases = []
    , brokers = []
    , tasks = []
    , cdn = Nothing
    }

-- ---------------------------------------------------------------------------
-- Helpers (mirroring the other spec modules).

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> Text.unpack e)

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

assertRight :: (Show e) => Either e a -> Assertion
assertRight (Right _) = pure ()
assertRight (Left err) = assertFailure ("expected Right, got Left: " <> show err)
