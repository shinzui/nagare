module InventoryCloudSpec (inventoryCloudTests) where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isRight)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Infra.Plan (StepOp (OpCreate))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Pulumi
import Nagare.Inventory.Adapters.PulumiRuntime
import Nagare.Inventory.Cloud
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryCloudTests :: TestTree
inventoryCloudTests =
  testGroup
    "cloud inventory adapter"
    [ testCase "cloud bundle round-trips and compiles one authoritative bucket owner" $ do
        let bytes = encodeCloudDeclarationBundle bundle
        decoded <- expectRight (decodeCloudDeclarationBundle bytes)
        decoded @?= bundle
        declaration <- expectRight (compileCloudScope decoded)
        length (scopeBundles declaration) @?= 1
        expectedRegistrations decoded @?= [registration]
        registrationsFromDeclarations [managed | resourceBundle <- scopeBundles declaration, managed <- declarations resourceBundle] @?= Right [registration]
        let nestedUrn = "urn:pulumi:dev::nagare::nagare:env:NagarePerimeter$gcp:storage/bucket:Bucket::nagare-images"
            nestedResource = (head (cloudResources bundle)) {cloudNativeUrn = nestedUrn}
            nestedBundle = bundle {cloudResources = [nestedResource]}
        nestedScope <- expectRight (compileCloudScope nestedBundle)
        registrationsFromDeclarations [managed | resourceBundle <- scopeBundles nestedScope, managed <- declarations resourceBundle]
          @?= Right [registration {registrationPulumiUrn = nestedUrn}]
    , testCase "registration parity refuses an undeclared native object" $ do
        let foreignRegistration = registration {registrationResource = resource "platform:cloud/foreign/bucket"}
        case validateNativeRegistrationParity [registration] [registration, foreignRegistration] of
          Left _ -> pure ()
          Right () -> assertFailure "undeclared native registration was accepted"
    , testCase "Pulumi preparation binds the exact saved plan and rejects unknown URNs" $ do
        let prepared =
              PulumiPreparation
                { preparationIdentity = pulumiIdentityFixture
                , preparationPreview = preview (registrationPulumiUrn registration)
                , preparationSavedPlan = "opaque-pulumi-plan"
                , preparationRegistrations = [registration]
                }
        case validatePulumiPreparation [registration] operation prepared of
          Left err -> assertFailure (show err)
          Right _ -> pure ()
        let unknown = prepared {preparationPreview = preview "urn:pulumi:dev::nagare::gcp:storage/bucket:Bucket::foreign"}
        case validatePulumiPreparation [registration] operation unknown of
          Left (PulumiUnknownMutation _) -> pure ()
          other -> assertFailure ("expected unknown-mutation refusal, got " <> show other)
    , testCase "Pulumi action classification refuses review/native disagreement" $ do
        let wrong = operation {plannedAction = RetireResource}
            prepared = PulumiPreparation pulumiIdentityFixture (preview (registrationPulumiUrn registration)) "plan" [registration]
        case validatePulumiPreparation [registration] wrong prepared of
          Left (PulumiActionMismatch _ RetireResource OpCreate) -> pure ()
          other -> assertFailure ("expected action mismatch, got " <> show other)
    , testCase "Pulumi runtime applies retained plan bytes and verifies convergence" $
        withSystemTempDirectory "pulumi-inventory-runtime" $ \temporary -> do
          let program = temporary </> "program"
              executable = temporary </> "pulumi"
              stackConfig = temporary </> "Pulumi.dev.yaml"
              logPath = temporary </> "calls.log"
          createDirectory program
          writeFile (program </> "index.ts") "export {};\n"
          writeFile stackConfig "config: {}\n"
          writeFile executable (fakePulumi logPath)
          setFileMode executable 0o700
          let config =
                PulumiRuntimeConfig
                  { runtimeContext = "dev"
                  , runtimeProject = "example-project"
                  , runtimeStack = "dev"
                  , runtimeBackend = "gs://example-state"
                  , runtimePayloadId = "payload-v1"
                  , runtimePayloadDigest = contentDigest "payload"
                  , runtimePulumiExecutable = executable
                  , runtimePulumiDirectory = program
                  , runtimeStackConfig = stackConfig
                  , runtimeDeclarationBundle = encodeCloudDeclarationBundle bundle
                  , runtimeRegistrations = [registration]
                  }
              adapter = mkPulumiAdapter [registration] (mkPulumiRuntimeOps config)
          prepared <- adapterPrepare adapter operation >>= expectRight
          adapterPreflight adapter operation prepared >>= expectRight
          adapterExecute adapter operation prepared >>= (@?= AdapterEffectCompleted)
          proofResult <- adapterVerify adapter operation prepared
          assertBool "convergence produced a proof" (isRight proofResult)
          observations <- adapterObserve adapter [registrationResource registration] >>= expectRight
          case Map.lookup (registrationResource registration) (observationMap observations) of
            Just ObservedPresent {} -> pure ()
            other -> assertFailure ("expected physical Pulumi observation, got " <> show other)
          calls <- readFile logPath
          assertBool "saved plan bytes reached pulumi up" (" up --plan " `isInfixOf` calls)
          length (filter (isInfixOf "--save-plan") (lines calls)) @?= 1
    ]

fakePulumi :: FilePath -> String
fakePulumi logPath =
  unlines
    [ "#!/usr/bin/env bash"
    , "set -euo pipefail"
    , "printf '%s\\n' \"$*\" >> " <> show logPath
    , "case \" $* \" in"
    , "  *\" version \"*) printf '%s\\n' 'v3.255.0' ;;"
    , "  *\" stack export \"*) printf '%s\\n' '" <> stackExport <> "' ;;"
    , "  *\" preview \"*\" --expect-no-changes \"*) printf '%s\\n' '{\"steps\":[]}' ;;"
    , "  *\" preview \"*\" --save-plan \"*)"
    , "    test -s \"${NAGARE_RESOURCE_DECLARATIONS:?}\""
    , "    while [ \"$#\" -gt 0 ]; do if [ \"$1\" = --save-plan ]; then shift; printf '%s' 'opaque-pulumi-plan' > \"$1\"; break; fi; shift; done"
    , "    printf '%s\\n' '" <> T.unpack (TE.decodeUtf8 (preview (registrationPulumiUrn registration))) <> "'"
    , "    ;;"
    , "  *\" up \"*)"
    , "    test -s \"${NAGARE_RESOURCE_DECLARATIONS:?}\""
    , "    while [ \"$#\" -gt 0 ]; do if [ \"$1\" = --plan ]; then shift; test \"$(cat \"$1\")\" = opaque-pulumi-plan; printf '%s\\n' 'up retained-plan-ok'; exit 0; fi; shift; done"
    , "    exit 64"
    , "    ;;"
    , "  *) exit 64 ;;"
    , "esac"
    ]
  where
    stackExport = "{\"deployment\":{\"resources\":[{\"urn\":\"" <> T.unpack (registrationPulumiUrn registration) <> "\",\"id\":\"bucket-123\"}]}}"

bundle :: CloudDeclarationBundle
bundle =
  CloudDeclarationBundle
    { cloudBundleVersion = 1
    , cloudContext = ok (mkContextId "dev")
    , cloudProject = name "example-project"
    , cloudStack = name "dev"
    , cloudScope = scope
    , cloudResources =
        [ CloudResource
            { cloudLogicalKey = ok (mkLogicalKey "image-bucket")
            , cloudRole = name "bucket"
            , cloudAddress = BucketAddress (name "example-project-images")
            , cloudAliases = []
            , cloudSpecDigest = specDigest
            , cloudLifecycle = Retain
            , cloudDataPolicy = Stateless
            , cloudSensitivity = Private
            , cloudDependencies = []
            , cloudSource = SourceLocation "infra/pulumi/src/components/NagarePerimeter.ts" "nagare-images"
            , cloudNativeType = "gcp:storage/bucket:Bucket"
            , cloudNativeName = name "nagare-images"
            , cloudNativeUrn = "urn:pulumi:dev::nagare::gcp:storage/bucket:Bucket::nagare-images"
            , cloudRegistrationClass = ManagedRegistration
            }
        ]
    }

registration :: NativeRegistration
registration = head (expectedRegistrations bundle)

operation :: PlannedOperation
operation =
  PlannedOperation
    { plannedOperationId = ok (mkOperationId "op-cloud-create")
    , plannedAction = CreateResource
    , plannedExecutor = PulumiExecutor
    , plannedResources = registrationResource registration :| []
    , plannedInputDigest = specDigest
    , plannedDependencies = []
    , plannedRecovery = Idempotent
    }

pulumiIdentityFixture :: PulumiIdentity
pulumiIdentityFixture =
  PulumiIdentity
    { pulumiContext = "dev"
    , pulumiProject = "example-project"
    , pulumiStack = "dev"
    , pulumiBackend = "gs://example-state"
    , pulumiPayloadId = "payload-v1"
    , pulumiPayloadDigest = contentDigest "payload"
    , pulumiProgramDigest = contentDigest "program"
    , pulumiConfigDigest = contentDigest "config"
    , pulumiToolVersion = "3.140.0"
    }

preview :: Text -> BC.ByteString
preview urn = BC.pack ("{\"steps\":[{\"op\":\"create\",\"urn\":\"" <> T.unpack urn <> "\",\"replaceReasons\":[]}]}")

scope :: ScopeId
scope = ok (mkScopeId Platform "cloud")

resource :: Text -> ResourceId
resource = ok . mkResourceId

name :: Text -> Name
name = ok . mkName

specDigest :: ContentDigest
specDigest = contentDigest "cloud-spec"

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
