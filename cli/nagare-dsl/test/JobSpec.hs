module JobSpec (jobTests) where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy (toStrict)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Command
import Nagare.Dsl.Config (encodeJob, encodeWorker)
import Nagare.Dsl.Job
import Nagare.Dsl.Load (LoadError (..), decodeJob, loadJob)
import Nagare.Dsl.Types
import Nagare.Dsl.Worker (webWorker)
import Test.Tasty
import Test.Tasty.HUnit

jobTests :: TestTree
jobTests =
  testGroup
    "Nagare.Dsl.Job"
    [ testGroup "constructors and preset" constructorTests
    , testGroup "JSON round-trip and kind discrimination" roundTripTests
    , testGroup "loadJob (config-as-program)" loadTests
    ]

constructorTests :: [TestTree]
constructorTests =
  [ testCase "oneShotJob supplies bounded hardened defaults" $ do
      let job = fixtureJob
      jobNamespace job @?= defaultNamespace
      jobBackoffLimit job @?= 0
      jobActiveDeadlineSeconds job @?= Just 1800
      jobTtlSecondsAfterFinished job @?= Just 3600
      quantityText (jobScratchSize job) @?= "2Gi"
      jobResources job @?= Nothing
  , testCase "jobResourceName prefixes the logical name" $
      jobResourceName "agent-run" @?= "nagare-job-agent-run"
  , testCase "ConfigMapName round-trips its validated text" $
      fmap configMapNameText (mkConfigMapName "nagare-nix-cache-client")
        @?= Right "nagare-nix-cache-client"
  , testCase "ConfigMapName rejects uppercase" $
      assertLeft (mkConfigMapName "Nix-Cache")
  , testCase "mkJob rejects a negative backoff" $
      assertLeft (mkJob fixtureJob {jobBackoffLimit = -1})
  , testCase "mkJob rejects a zero deadline" $
      assertLeft (mkJob fixtureJob {jobActiveDeadlineSeconds = Just 0})
  , testCase "mkJob rejects a zero finished TTL" $
      assertLeft (mkJob fixtureJob {jobTtlSecondsAfterFinished = Just 0})
  , testCase "mkJob accepts no deadline for a general Job" $
      assertRight (mkJob fixtureJob {jobActiveDeadlineSeconds = Nothing})
  , testCase "mkJob rejects incomplete explicit resources" $
      assertLeft
        ( mkJob
            fixtureJob
              { jobResources =
                  Just
                    completeResources
                      { memoryLimit = Nothing
                      }
              }
        )
  , testCase "mkJob accepts complete explicit resources" $
      assertRight (mkJob fixtureJob {jobResources = Just completeResources})
  ]

roundTripTests :: [TestTree]
roundTripTests =
  [ testCase "representative Job survives emit -> decode round-trip" $
      decodeJob (toStrict (encodeJob richJob)) @?= Right richJob
  , testCase "preset Job survives emit -> decode round-trip" $
      decodeJob (toStrict (encodeJob fixtureJob)) @?= Right fixtureJob
  , testCase "decoding a Worker as a Job is UnexpectedKind" $
      case webWorker "queue-consumer" "registry/example" of
        Left err -> assertFailure err
        Right worker ->
          decodeJob (toStrict (encodeWorker worker))
            @?= Left (UnexpectedKind "Job" "Worker")
  , testCase "invalid decoded command reports its field" $
      case decodeJob invalidCommandJson of
        Left (MarshalError "command" _) -> pure ()
        other -> assertFailure ("expected MarshalError command, got: " <> show other)
  , testCase "incomplete decoded resources are rejected by mkJob" $
      case decodeJob incompleteResourcesJson of
        Left (MarshalError "job" "resources.memoryLimit must be set") -> pure ()
        other -> assertFailure ("expected incomplete-resource error, got: " <> show other)
  ]

loadTests :: [TestTree]
loadTests =
  [ testCase "loadJob fixture returns the expected Job" $ do
      result <- loadJob "test/fixtures/job/nagare/Config.hs"
      case result of
        Left err -> assertFailure ("loadJob returned Left: " <> show err)
        Right job -> job @?= fixtureJobWithCommand
  ]

fixtureJob :: Job
fixtureJob =
  case oneShotJob "agent-run" "busybox" of
    Left err -> error ("test fixture invalid: " <> err)
    Right job -> job

fixtureJobWithCommand :: Job
fixtureJobWithCommand =
  fixtureJob
    { jobCommand = Just (unsafe (mkCommand ["sh", "-c", "echo one-shot job"]))
    }

richJob :: Job
richJob =
  fixtureJobWithCommand
    { jobEnv =
        Map.fromList
          [ (unsafe (mkEnvName "REPO_REF"), runtimeScoped (EnvLiteral "repo_example@0123456789012345678901234567890123456789"))
          , (unsafe (mkEnvName "FORGE_TOKEN"), runtimeScoped (EnvSecretRef (unsafe (mkSecretName "forge-token"))))
          ]
    , jobResources = Just completeResources
    , jobNixConfigMap = Just (unsafe (mkConfigMapName "nagare-nix-cache-client"))
    }

completeResources :: Resources
completeResources =
  Resources
    { cpu = Just (unsafe (mkQuantity "250m"))
    , memory = Just (unsafe (mkQuantity "512Mi"))
    , cpuLimit = Just (unsafe (mkQuantity "1"))
    , memoryLimit = Just (unsafe (mkQuantity "1Gi"))
    }

invalidCommandJson :: ByteString
invalidCommandJson =
  "{\"kind\":\"Job\",\"name\":\"agent-run\",\"namespace\":\"personal\",\"image\":\"busybox\",\"command\":[],\"scratchSize\":\"2Gi\"}"

incompleteResourcesJson :: ByteString
incompleteResourcesJson =
  "{\"kind\":\"Job\",\"name\":\"agent-run\",\"namespace\":\"personal\",\"image\":\"busybox\",\"scratchSize\":\"2Gi\",\"cpuRequest\":\"250m\",\"memoryRequest\":\"512Mi\",\"cpuLimit\":\"1\"}"

unsafe :: Either Text a -> a
unsafe (Right value) = value
unsafe (Left err) = error ("test fixture invalid: " <> Text.unpack err)

assertLeft :: (Show b) => Either a b -> Assertion
assertLeft (Left _) = pure ()
assertLeft (Right value) = assertFailure ("expected Left, got Right: " <> show value)

assertRight :: (Show a) => Either a b -> Assertion
assertRight (Right _) = pure ()
assertRight (Left err) = assertFailure ("expected Right, got Left: " <> show err)
