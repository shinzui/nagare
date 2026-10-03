module InventoryArtifactSpec (inventoryArtifactTests) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkSecretName)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Artifact
import Nagare.Inventory.Adapters.ArtifactRuntime
import Nagare.Inventory.Application (acceptedApplicationImage, acceptedImageBuildSecrets, acceptedImageResourceForDestination)
import Nagare.Inventory.Artifact
import Nagare.Inventory.Digest
import Nagare.Inventory.Environment (compileBuildSecretChannel)
import Nagare.Inventory.ImageBuild (buildDockerArchiveWith, dockerBuildArguments, validateSecretMounts)
import Nagare.Inventory.Journal
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import System.Directory (doesPathExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryArtifactTests :: TestTree
inventoryArtifactTests =
  testGroup
    "artifact inventory adapter"
    [ testCase "projection observation uses current bytes without reading or mutating the old envelope" $
        withSystemTempDirectory "nagare-kubeconfig-projection" $ \temporary -> do
          let current = temporary </> "current.yaml"
              old = temporary </> "absent-old-root.yaml"
              accepted =
                ArtifactExecutionSpec
                  KubeconfigArtifact
                  (Text.pack old)
                  expectedDigest
                  expectedDigest
                  False
                  (Just (temporary </> "absent-old-source.yaml"))
          BS.writeFile current "published-content"
          observed <- observeKubeconfigProjectionAt current accepted >>= expectRight
          observed @?= ObservedPresent (ok (mkPhysicalIdentity ("kubeconfig://" <> Text.pack current)))
          executionArtifactDestination accepted @?= Text.pack old
          doesPathExist old >>= (@?= False)
          BS.writeFile current "changed"
          observeKubeconfigProjectionAt current accepted >>= assertBool "changed bytes accepted" . either (const True) (const False)
          observeKubeconfigProjectionAt old accepted >>= assertBool "missing bytes accepted" . either (const True) (const False)
    , testCase "accepted kubeconfig projection relocates paths but rejects identity, bytes and producer changes" $ do
        let owner = ok (mkScopeId Platform "kubeconfig")
            credential =
              imageSpec
                { artifactKind = KubeconfigArtifact
                , artifactPublishOperation = False
                , artifactSource = SourceLocation "/first/prepared.yaml" "kubeconfig-prepared-v1"
                , artifactDestination = "/first/kubeconfig.yaml"
                }
            compile resource = expectRight (compileArtifactScope (ArtifactDeclarationBundle 1 owner (resource :| [])))
        accepted <- compile credential
        relocated <-
          compile
            credential
              { artifactDestination = "/second/kubeconfig.yaml"
              , artifactSource = SourceLocation "/second/prepared.yaml" "kubeconfig-prepared-v1"
              }
        assertBool "relocation rejected" (sameKubeconfigProjection accepted relocated)
        forM_
          [ credential {artifactContentDigest = contentDigest "different"}
          , credential {artifactSpecDigest = contentDigest "different"}
          , credential {artifactRole = name "different"}
          , credential {artifactDependencies = [OrderedAfter artifactResource]}
          , credential {artifactPublishOperation = True}
          , credential {artifactSource = SourceLocation "/second" "different"}
          , credential {artifactLifecycle = Protect}
          ]
          $ \changed -> do
            candidate <- compile changed
            assertBool "changed credential accepted" (not (sameKubeconfigProjection accepted candidate))
    , testCase "local BuildKit archive uses required secret mounts without argv values" $ do
        validateSecretMounts
          "FROM alpine\nRUN --mount=type=secret,id=TOKEN,required=true cat /run/secrets/TOKEN >/dev/null\n"
          ["TOKEN"]
          @?= Right ()
        case validateSecretMounts "FROM alpine\nRUN echo ready\n" ["TOKEN"] of
          Left _ -> pure ()
          Right _ -> assertFailure "Dockerfile omitted the required Build Secret mount"
        args <-
          expectRight
            ( dockerBuildArguments
                "linux/amd64"
                "registry.example/app:v1"
                "Dockerfile"
                "."
                (Map.singleton "PUBLIC" "shown")
                (Map.singleton "TOKEN" "/private/0")
            )
        assertBool
          "BuildKit secret value entered Docker argv"
          (not (any (Text.isInfixOf "secret-value" . Text.pack) args))
        assertBool
          "BuildKit secret file was not mounted"
          ("type=file,id=TOKEN,src=/private/0" `elem` args)
        case dockerBuildArguments
          "linux/amd64"
          "registry.example/app:v1"
          "Dockerfile"
          "."
          (Map.singleton "TOKEN" "shown")
          (Map.singleton "TOKEN" "/private/0") of
          Left _ -> pure ()
          Right _ -> assertFailure "Build ConfigMap and Secret key collision was accepted"
    , testCase "local builder gives exact Secret bytes only through a temporary mount" $
        withSystemTempDirectory "nagare-image-build-test" $ \temporary -> do
          let dockerfile = temporary </> "Dockerfile"
              archive = temporary </> "image.tar"
              mountPrefix = "type=file,id=TOKEN,src="
          BS.writeFile
            dockerfile
            "FROM alpine\nRUN --mount=type=secret,id=TOKEN,required=true cat /run/secrets/TOKEN >/dev/null\n"
          mounted <- newIORef []
          let fakeDocker args = case args of
                "buildx" : _ -> case [ drop (length mountPrefix) arg
                                     | arg <- args
                                     , mountPrefix `isPrefixOf` arg
                                     ] of
                  [path] -> do
                    BS.readFile path >>= (@?= "private-value")
                    assertBool
                      "Secret value entered Docker argv"
                      (not ("private-value" `elem` args))
                    writeIORef mounted [path]
                    pure True
                  _ -> assertFailure "BuildKit mount is absent or duplicated" >> pure False
                ["image", "save", "--output", output, _] ->
                  BS.writeFile output "fake-archive" >> pure True
                _ -> assertFailure "unexpected Docker command" >> pure False
          result <-
            buildDockerArchiveWith
              fakeDocker
              "linux/amd64"
              "registry.example/app:v1"
              dockerfile
              temporary
              archive
              Map.empty
              (Map.singleton "TOKEN" "private-value")
          result @?= Right ()
          BS.readFile archive >>= (@?= "fake-archive")
          paths <- readIORef mounted
          case paths of
            [path] -> doesPathExist path >>= (@?= False)
            _ -> assertFailure "builder did not receive one private Secret file"
    , testCase "artifact scope distinguishes owned publications from external release references" $ do
        declaration <- expectRight (compileArtifactScope artifactBundle)
        case scopeBundles declaration of
          [ResourceBundle declared _ _ _ declaredOperations _] -> do
            length declared @?= 3
            length declaredOperations @?= 1
            any isExternal declared @? "release payload should remain an external reference in a deployment context"
            reconstructed <- expectRight (artifactExecutionSpecsFromDeclarations declared)
            Map.lookup artifactResource reconstructed @?= Map.lookup artifactResource specs
          values -> assertFailure ("expected one artifact bundle, got " <> show (length values))
    , testCase "OCI archive source survives accepted declaration reconstruction" $ do
        let archived =
              imageSpec
                { artifactKind = OciImageArtifact
                , artifactSource = SourceLocation "/tmp/reviewed-image.tar" "oci-archive-v1"
                }
        declaration <-
          expectRight
            ( compileArtifactScope
                (ArtifactDeclarationBundle 1 scope (archived :| []))
            )
        rebuilt <-
          expectRight
            ( artifactExecutionSpecsFromDeclarations
                [member | bundle <- scopeBundles declaration, member <- declarations bundle]
            )
        Map.lookup artifactResource rebuilt
          @?= Just
            ( ( artifactExecutionSpecs
                  (ArtifactDeclarationBundle 1 scope (archived :| []))
                  Map.! artifactResource
              )
            )
        fmap executionArtifactArchive (Map.lookup artifactResource rebuilt)
          @?= Just (Just "/tmp/reviewed-image.tar")
    , testCase "application review requires the exact accepted OCI publication" $ do
        let oci =
              imageSpec
                { artifactLogicalKey = logicalKey "app-image"
                , artifactRole = name "oci-image"
                , artifactName = name "app-image"
                , artifactDestination = "registry.example/app:v1"
                , artifactKind = OciImageArtifact
                }
            imageId = mintResourceId scope (artifactLogicalKey oci) (artifactRole oci)
            binding = ContextBinding (either (error . Text.unpack) id (mkContextId "test")) (name "project")
        declared <- expectRight (compileArtifactScope (ArtifactDeclarationBundle 1 scope (oci :| [])))
        snapshot <-
          expectRight
            ( mkScopeSnapshot
                binding
                (Map.singleton scope (either (error . Text.unpack) id (mkScopeGeneration 1), declared))
                Map.empty
            )
        acceptedApplicationImage snapshot imageId "registry.example/app:v1" @?= Right ()
        acceptedImageResourceForDestination snapshot "registry.example/app:v1"
          @?= Right imageId
        case acceptedImageResourceForDestination snapshot "registry.example/app:v2" of
          Left _ -> pure ()
          Right _ -> assertFailure "webhook selected an unrelated image publication"
        case acceptedApplicationImage snapshot imageId "registry.example/app:v2" of
          Left _ -> pure ()
          Right () -> assertFailure "a different image tag was accepted"
        case acceptedApplicationImage snapshot artifactResource "registry.example/app:v1" of
          Left _ -> pure ()
          Right () -> assertFailure "an absent image identity was accepted"
    , testCase "accepted image pins its Build Secret channel without making it runtime input" $ do
        let foundation = either (error . Text.unpack) id (mkScopeId Platform "foundation")
            cluster = mintResourceId foundation (logicalKey "cluster") (name "cluster")
            namespaceId =
              mintResourceId
                foundation
                (logicalKey "foundation")
                (name "namespace-personal")
        (buildScope, _) <-
          expectRight
            ( compileBuildSecretChannel
                "kizashi"
                "personal"
                cluster
                namespaceId
                (name "v1")
                (Map.singleton "TOKEN" "private")
                (SourceLocation "test" "build-secret")
            )
        buildId <- case [ member ^. #identity
                        | bundle <- scopeBundles buildScope
                        , Managed member <- declarations bundle
                        ] of
          [single] -> pure single
          _ -> assertFailure "Build channel has no unique Secret" >> fail "missing Build Secret"
        let oci =
              imageSpec
                { artifactLogicalKey = logicalKey "app-image"
                , artifactRole = name "oci-image"
                , artifactName = name "app-image"
                , artifactDestination = "registry.example/app:v1"
                , artifactKind = OciImageArtifact
                , artifactDependencies = [OrderedAfter buildId]
                }
            imageId = mintResourceId scope (artifactLogicalKey oci) (artifactRole oci)
            pin = "build-input." <> resourceIdText buildId
            binding = ContextBinding (either (error . Text.unpack) id (mkContextId "test")) (name "project")
        base <- expectRight (compileArtifactScope (ArtifactDeclarationBundle 1 scope (oci :| [])))
        let declared =
              withScopeOverrides
                (Map.singleton pin (digestText (contentDigest "accepted-build-revision")))
                base
            published =
              withScopeOverrides
                ( Map.insert
                    "build-method"
                    "dockerfile-buildkit-v1"
                    (scopeOverrides declared)
                )
                base
        snapshot <-
          expectRight
            ( mkScopeSnapshot
                binding
                ( Map.fromList
                    [ (scope, (either (error . Text.unpack) id (mkScopeGeneration 1), published))
                    , (scopeId buildScope, (either (error . Text.unpack) id (mkScopeGeneration 1), buildScope))
                    ]
                )
                Map.empty
            )
        acceptedImageBuildSecrets snapshot imageId cluster "kizashi" "personal"
          @?= Right
            ( Set.singleton
                ( either
                    (error . Text.unpack)
                    id
                    (mkSecretName "nagare-secret-kizashi-build")
                )
            )
        case acceptedImageBuildSecrets snapshot imageId cluster "another-app" "personal" of
          Left _ -> pure ()
          Right _ -> assertFailure "image Build input was borrowed by another app"
        case acceptedImageBuildSecrets snapshot imageId cluster "kizashi" "other" of
          Left _ -> pure ()
          Right _ -> assertFailure "image Build input was borrowed by another namespace"
        declaredSnapshot <-
          expectRight
            ( mkScopeSnapshot
                binding
                ( Map.fromList
                    [ (scope, (either (error . Text.unpack) id (mkScopeGeneration 1), declared))
                    , (scopeId buildScope, (either (error . Text.unpack) id (mkScopeGeneration 1), buildScope))
                    ]
                )
                Map.empty
            )
        case acceptedImageBuildSecrets declaredSnapshot imageId cluster "kizashi" "personal" of
          Left _ -> pure ()
          Right _ -> assertFailure "unbuilt external archive authorized Build Secret use"
        unpinned <-
          expectRight
            ( mkScopeSnapshot
                binding
                ( Map.fromList
                    [ (scope, (either (error . Text.unpack) id (mkScopeGeneration 1), base))
                    , (scopeId buildScope, (either (error . Text.unpack) id (mkScopeGeneration 1), buildScope))
                    ]
                )
                Map.empty
            )
        case acceptedImageBuildSecrets unpinned imageId cluster "kizashi" "personal" of
          Left _ -> pure ()
          Right _ -> assertFailure "image dependency without a revision pin was accepted"
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
    , testCase "build observe and publish require outer protocol v2 while other artifacts retain v1" $
        withSystemTempDirectory "artifact-read-only-protocol" $ \temporary -> do
          let executable = temporary </> "transport"
              absent = contentDigest "protocol-absence"
          writeFile executable $
            unlines
              [ "#!/bin/sh"
              , "set -eu"
              , "request=$(cat)"
              , "test \"$(printf '%s' \"$request\" | jq -er .version)\" = \"$EXPECTED_VERSION\""
              , "if [ \"$1\" = publish ]; then"
              , "  jq -nc --arg physical \"$EXPECTED_PHYSICAL\" --arg digest \"$(printf '%s' \"$request\" | jq -er .expectedDigest)\" '{tag:\"TransportPresent\",contents:[$physical,$digest]}'"
              , "else"
              , "printf '%s\\n' '{\"tag\":\"TransportMissing\",\"contents\":\"" <> Text.unpack (digestText absent) <> "\"}'"
              , "fi"
              ]
          setFileMode executable 0o700
          forM_ [(BuildJobArtifact, "2", "build-job:///fixture/output"), (GceImageArtifact, "1", "gce:///fixture/output")] $ \(kind, version, physicalValue) -> do
            let selected =
                  Map.singleton
                    artifactResource
                    (ArtifactExecutionSpec kind "/fixture/output" expectedDigest expectedDigest False Nothing)
                runtime = ArtifactRuntimeConfig executable [("EXPECTED_VERSION", version), ("EXPECTED_PHYSICAL", physicalValue)] selected
            observed <- artifactObserveResources (mkArtifactRuntimeOps runtime) [artifactResource] >>= expectRight
            Map.lookup artifactResource (observationMap observed) @?= Just (ConfirmedAbsent absent)
            artifactPublish (mkArtifactRuntimeOps runtime) mutationPlan {artifactPlanKind = kind, artifactPlanDestination = "/fixture/output"} >>= (@?= AdapterEffectCompleted)
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
