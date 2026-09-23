module InventoryArtifactSpec (inventoryArtifactTests) where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Artifact
import Nagare.Inventory.Adapters.ArtifactRuntime
import Nagare.Inventory.Artifact
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryArtifactTests :: TestTree
inventoryArtifactTests =
  testGroup
    "artifact inventory adapter"
    [ testCase "artifact scope distinguishes owned publications from external release references" $ do
        declaration <- expectRight (compileArtifactScope artifactBundle)
        case scopeBundles declaration of
          [ResourceBundle declared _ _ _ declaredOperations _] -> do
            length declared @?= 3
            length declaredOperations @?= 1
            any isExternal declared @? "release payload should remain an external reference in a deployment context"
            reconstructed <- expectRight (artifactExecutionSpecsFromDeclarations declared)
            Map.lookup artifactResource reconstructed @?= Map.lookup artifactResource specs
          values -> assertFailure ("expected one artifact bundle, got " <> show (length values))
    , testCase "matching immutable content resumes without republishing" $ do
        calls <- newIORef (0 :: Int)
        state <- newIORef (ArtifactPresent physical expectedDigest)
        let adapter = mkArtifactAdapter specs (ops calls state)
        prepared <- adapterPrepare adapter publishOperation >>= expectRight
        adapterPreflight adapter publishOperation prepared >>= expectRight
        adapterExecute adapter publishOperation prepared >>= (@?= AdapterEffectCompleted)
        readIORef calls >>= (@?= 0)
        adapterVerify adapter publishOperation prepared >>= expectRight >>= (@?= artifactCompletionProof mutationPlan physical)
        adapterRecover adapter publishOperation prepared >>= (@?= RecoveryProvedComplete (artifactCompletionProof mutationPlan physical))
    , testCase "wrong remote digest refuses before publication" $ do
        calls <- newIORef (0 :: Int)
        state <- newIORef (ArtifactPresent physical (contentDigest "wrong"))
        let adapter = mkArtifactAdapter specs (ops calls state)
        prepared <- adapterPrepare adapter publishOperation >>= expectRight
        result <- adapterPreflight adapter publishOperation prepared
        case result of
          Left _ -> pure ()
          Right () -> assertFailure "wrong remote digest was accepted"
        readIORef calls >>= (@?= 0)
    , testCase "missing artifact is retryable but unknown consumers block collection" $ do
        calls <- newIORef (0 :: Int)
        state <- newIORef (ArtifactMissing (contentDigest "absence"))
        let adapter = mkArtifactAdapter specs (ops calls state)
        prepared <- adapterPrepare adapter publishOperation >>= expectRight
        adapterRecover adapter publishOperation prepared >>= (@?= RecoverySafeToRetry)
        retirement <- adapterPrepare adapter retireOperation
        case retirement of
          Left (PrepareRefused _ message) | "consumer completeness is unknown" `Text.isInfixOf` message -> pure ()
          other -> assertFailure ("expected collection refusal, got " <> show other)
    , testCase "subprocess runtime binds the reviewed destination and digest" $
        withSystemTempDirectory "nagare-artifact-runtime-test" $ \temporary -> do
          let executable = temporary </> "artifact-transport"
              absent = contentDigest "runtime-absence"
              body =
                unlines
                  [ "#!/bin/sh"
                  , "set -eu"
                  , "test \"${NAGARE_INVENTORY_ADAPTER_CHILD:-}\" = artifact"
                  , "request=$(cat)"
                  , "printf '%s' \"$request\" | grep -F 'projects/example/global/images/nagare-image-abc' >/dev/null"
                  , "printf '%s' \"$request\" | grep -F '" <> Text.unpack (digestText expectedDigest) <> "' >/dev/null"
                  , "if [ \"$1\" = publish ]; then"
                  , "  printf '%s\\n' '{\"tag\":\"TransportPresent\",\"contents\":[\"gce://projects/example/global/images/nagare-image-abc\",\"" <> Text.unpack (digestText expectedDigest) <> "\"]}'"
                  , "else"
                  , "  printf '%s\\n' '{\"tag\":\"TransportMissing\",\"contents\":\"" <> Text.unpack (digestText absent) <> "\"}'"
                  , "fi"
                  ]
          writeFile executable body
          setFileMode executable 0o700
          let runtime = ArtifactRuntimeConfig executable [] specs
              adapter = mkArtifactAdapter specs (mkArtifactRuntimeOps runtime)
          observed <- adapterObserve adapter [artifactResource] >>= expectRight
          Map.lookup artifactResource (observationMap observed) @?= Just (ConfirmedAbsent absent)
          let createOperation = operation CreateResource
          created <- adapterPrepare adapter createOperation >>= expectRight
          adapterPreflight adapter createOperation created >>= expectRight
          adapterExecute adapter createOperation created >>= (@?= AdapterEffectCompleted)
          prepared <- adapterPrepare adapter publishOperation >>= expectRight
          adapterPreflight adapter publishOperation prepared >>= expectRight
          adapterExecute adapter publishOperation prepared >>= (@?= AdapterEffectCompleted)
    ]
  where
    isExternal External {} = True
    isExternal _ = False

ops :: IORef Int -> IORef ArtifactObservation -> ArtifactAdapterOps
ops calls state =
  ArtifactAdapterOps
    { artifactObserveResources = \resources -> pure (observationSet [(resource, ObservedPresent physical) | resource <- resources])
    , artifactPrepareMutation = \operationValue -> pure (Right mutationPlan {artifactPlanOperation = plannedOperationId operationValue, artifactPlanInputDigest = plannedInputDigest operationValue})
    , artifactInspectRemote = \_ -> readIORef state
    , artifactPublish = \_ -> modifyIORef' calls (+ 1) >> writeIORef state (ArtifactPresent physical expectedDigest) >> pure AdapterEffectCompleted
    }

artifactBundle :: ArtifactDeclarationBundle
artifactBundle = ArtifactDeclarationBundle 1 scope (imageSpec :| [releaseSpec, controlSpec])

imageSpec :: ArtifactResourceSpec
imageSpec =
  ArtifactResourceSpec
    { artifactLogicalKey = logicalKey "host-image"
    , artifactRole = name "gce-image"
    , artifactName = name "nagare-image-abc"
    , artifactDestination = "projects/example/global/images/nagare-image-abc"
    , artifactContentDigest = expectedDigest
    , artifactSpecDigest = contentDigest "image-spec"
    , artifactKind = GceImageArtifact
    , artifactOwnership = OwnedArtifact
    , artifactLifecycle = Retain
    , artifactDataPolicy = Stateless
    , artifactSensitivity = Private
    , artifactDependencies = []
    , artifactConsumers = ConsumerCompletenessUnknown
    , artifactPublishOperation = True
    , artifactSource = SourceLocation "scripts/upload-images.sh" "gce-image"
    }

releaseSpec :: ArtifactResourceSpec
releaseSpec =
  imageSpec
    { artifactLogicalKey = logicalKey "platform-release"
    , artifactRole = name "payload"
    , artifactName = name "nagare-v1"
    , artifactKind = ReleasePayloadArtifact
    , artifactOwnership = ExternalArtifact
    , artifactPublishOperation = False
    , artifactSource = SourceLocation ".github/workflows/release.yml" "release-payload"
    }

controlSpec :: ArtifactResourceSpec
controlSpec =
  imageSpec
    { artifactLogicalKey = logicalKey "context-pin"
    , artifactRole = name "control"
    , artifactName = name "platform-version"
    , artifactKind = ControlMetadataArtifact
    , artifactConsumers = KnownConsumers []
    , artifactPublishOperation = False
    , artifactSource = SourceLocation "cli/nagarectl/src/Nagare/Platform/Deployment.hs" "version-marker"
    }

specs :: Map.Map ResourceId ArtifactExecutionSpec
specs = artifactExecutionSpecs artifactBundle

artifactResource :: ResourceId
artifactResource = mintResourceId scope (artifactLogicalKey imageSpec) (artifactRole imageSpec)

publishOperation :: PlannedOperation
publishOperation = operation RunDeclaredOperation

retireOperation :: PlannedOperation
retireOperation = operation RetireResource

operation :: OperationAction -> PlannedOperation
operation action =
  PlannedOperation
    { plannedOperationId = ok (mkOperationId (if action == RetireResource then "op-artifact-retire" else "op-artifact-publish"))
    , plannedAction = action
    , plannedExecutor = ArtifactExecutor
    , plannedResources = artifactResource :| []
    , plannedInputDigest = contentDigest (if action == RetireResource then "retire-input" else "publish-input")
    , plannedDependencies = []
    , plannedRecovery = VerifyBeforeRetry
    }

mutationPlan :: ArtifactMutationPlan
mutationPlan =
  ArtifactMutationPlan
    { artifactPlanVersion = 1
    , artifactPlanOperation = plannedOperationId publishOperation
    , artifactPlanInputDigest = plannedInputDigest publishOperation
    , artifactPlanResource = artifactResource
    , artifactPlanKind = GceImageArtifact
    , artifactPlanDestination = "projects/example/global/images/nagare-image-abc"
    , artifactPlanExpectedDigest = expectedDigest
    , artifactPlanSourceDigest = contentDigest "source-tarball"
    , artifactPlanConfigurationDigest = Just (contentDigest "pulumi-config-before")
    }

scope :: ScopeId
scope = ok (mkScopeId Publication "context-artifacts")

physical :: PhysicalIdentity
physical = ok (mkPhysicalIdentity "gce://projects/example/global/images/nagare-image-abc")

expectedDigest :: ContentDigest
expectedDigest = contentDigest "published-content"

name :: Text -> Name
name = ok . mkName

logicalKey :: Text -> LogicalKey
logicalKey = ok . mkLogicalKey

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
