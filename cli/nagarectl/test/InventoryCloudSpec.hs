module InventoryCloudSpec (inventoryCloudTests) where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isRight)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding (preview, (.=))
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
    , testCase "cloud catalog builds nested URNs and excludes admitted registrations" $ do
        catalog <-
          expectRight
            ( decodeCloudCatalog
                ( BC.pack
                    "{\"version\":1,\"project\":\"nagare\",\"foundationManaged\":[{\"type\":\"nagare:env:NagarePerimeter\",\"name\":\"nagare\",\"parent\":null,\"layer\":0},{\"type\":\"gcp:storage/bucket:Bucket\",\"name\":\"nagare-images\",\"parent\":\"nagare\",\"layer\":1}],\"nixCacheEnabled\":[{\"type\":\"nagare:env:NagareNixCache\",\"name\":\"nagare-nix-cache\",\"parent\":null,\"layer\":2}]}"
                )
            )
        length (selectedCloudCatalog False False False catalog) @?= 2
        length (selectedCloudCatalog True False False catalog) @?= 3
        let image = last (catalogFoundationManaged catalog)
        imageUrn <- expectRight (cloudCatalogUrn (name "dev") catalog image)
        imageUrn @?= "urn:pulumi:dev::nagare::nagare:env:NagarePerimeter$gcp:storage/bucket:Bucket::nagare-images"
        let admitted = registration {registrationPulumiUrn = imageUrn}
        bookkeeping <-
          expectRight
            ( cloudBookkeepingRegistrations
                (name "dev")
                False
                False
                False
                catalog
                (contentDigest "catalog")
                [admitted]
            )
        length bookkeeping @?= 1
        map registrationPulumiName bookkeeping @?= [name "nagare"]
    , testCase "image catalog keeps distinct keys for component and VM with one native name" $ do
        catalog <-
          expectRight
            ( decodeCloudCatalog
                ( BC.pack
                    "{\"version\":1,\"project\":\"nagare\",\"foundationManaged\":[{\"type\":\"nagare:env:NagarePerimeter\",\"name\":\"nagare\",\"parent\":null,\"layer\":0}],\"nixCacheEnabled\":[],\"imageEnabled\":[{\"key\":\"nagare-instance\",\"type\":\"nagare:compute:NagareInstance\",\"name\":\"nagare-01\",\"parent\":\"nagare\",\"layer\":4},{\"key\":\"nagare-instance-vm\",\"type\":\"gcp:compute/instance:Instance\",\"name\":\"nagare-01\",\"parent\":\"nagare-instance\",\"layer\":5}]}"
                )
            )
        let selected = selectedCloudCatalog False True False (withCloudInstanceName (name "custom-host") catalog)
        length selected @?= 3
        let vm = last selected
        catalogNativeName vm @?= name "custom-host"
        catalogKey vm @?= name "nagare-instance-vm"
        urn <- expectRight (cloudCatalogUrn (name "dev") catalog vm)
        urn @?= "urn:pulumi:dev::nagare::nagare:env:NagarePerimeter$nagare:compute:NagareInstance$gcp:compute/instance:Instance::custom-host"
    , testCase "CDN catalog entries are admitted only with the image-enabled VM (F43)" $ do
        catalog <-
          expectRight
            ( decodeCloudCatalog
                ( BC.pack
                    "{\"version\":1,\"project\":\"nagare\",\"foundationManaged\":[{\"type\":\"nagare:env:NagarePerimeter\",\"name\":\"nagare\",\"parent\":null,\"layer\":0}],\"nixCacheEnabled\":[],\"imageEnabled\":[{\"key\":\"nagare-instance\",\"type\":\"nagare:compute:NagareInstance\",\"name\":\"nagare-01\",\"parent\":\"nagare\",\"layer\":4}],\"cdnEnabled\":[{\"type\":\"nagare:cdn:NagareCdn\",\"name\":\"nagare-cdn\",\"parent\":\"nagare\",\"layer\":6},{\"type\":\"gcp:compute/backendService:BackendService\",\"name\":\"nagare-cdn-backend\",\"parent\":\"nagare-cdn\",\"layer\":8}]}"
                )
            )
        length (selectedCloudCatalog False False True catalog) @?= 1
        length (selectedCloudCatalog False True False catalog) @?= 2
        length (selectedCloudCatalog False True True catalog) @?= 4
        urn <- expectRight (cloudCatalogUrn (name "dev") catalog (last (catalogCdnEnabled catalog)))
        urn @?= "urn:pulumi:dev::nagare::nagare:env:NagarePerimeter$nagare:cdn:NagareCdn$gcp:compute/backendService:BackendService::nagare-cdn-backend"
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
    , testCase "Pulumi accepts only the exact implicit stack bookkeeping mutation" $ do
        let stackUrn = "urn:pulumi:dev::nagare::pulumi:pulumi:Stack::nagare-dev"
            withStack rootUrn =
              BC.pack
                ( "{\"steps\":[{\"op\":\"create\",\"urn\":\""
                    <> T.unpack rootUrn
                    <> "\"},{\"op\":\"create\",\"urn\":\""
                    <> T.unpack (registrationPulumiUrn registration)
                    <> "\"}]}"
                )
            prepared rootUrn =
              PulumiPreparation
                pulumiIdentityFixture
                (withStack rootUrn)
                "plan"
                [registration]
        case validatePulumiPreparation [registration] operation (prepared stackUrn) of
          Right _ -> pure ()
          Left err -> assertFailure ("exact implicit stack was refused: " <> show err)
        case validatePulumiPreparation
          [registration]
          operation
          (prepared "urn:pulumi:other::nagare::pulumi:pulumi:Stack::nagare-other") of
          Left (PulumiUnknownMutation _) -> pure ()
          other -> assertFailure ("foreign stack mutation was accepted: " <> show other)
    , testCase "new Pulumi stack export has no resources yet" $ do
        let emptyExport = BC.pack "{\"version\":3,\"deployment\":{\"manifest\":{},\"metadata\":{}}}"
        decodePhysicalResources emptyExport @?= Right Map.empty
        decodePhysicalResources (BC.pack "{\"deployment\":{\"resources\":null}}") @?= Right Map.empty
    , testCase "a targeted Pulumi operation refuses a second declared mutation" $ do
        let otherRegistration =
              registration
                { registrationResource = resource "platform:cloud/other/bucket"
                , registrationPulumiName = name "other-bucket"
                , registrationPulumiUrn = "urn:pulumi:dev::nagare::gcp:storage/bucket:Bucket::other-bucket"
                }
            prepared =
              PulumiPreparation
                pulumiIdentityFixture
                ( BC.pack
                    ( "{\"steps\":[{\"op\":\"create\",\"urn\":\""
                        <> T.unpack (registrationPulumiUrn registration)
                        <> "\",\"replaceReasons\":[]},{\"op\":\"create\",\"urn\":\""
                        <> T.unpack (registrationPulumiUrn otherRegistration)
                        <> "\",\"replaceReasons\":[]}]}"
                    )
                )
                "plan"
                [registration, otherRegistration]
        case validatePulumiPreparation [registration, otherRegistration] operation prepared of
          Left (PulumiUnexpectedMutation urn) -> urn @?= registrationPulumiUrn otherRegistration
          other -> assertFailure ("expected unrelated Pulumi mutation refusal, got " <> show other)
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
                  , runtimeCollectionPhysical = Map.empty
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
          assertBool
            "Pulumi preview and up did not target the reviewed resource"
            ( all
                (isInfixOf ("--target " <> T.unpack (registrationPulumiUrn registration)))
                (filter (\line -> " preview " `isInfixOf` line || " up " `isInfixOf` line) (lines calls))
            )
          length (filter (isInfixOf "--save-plan") (lines calls)) @?= 1
    , testCase "an unchanged targeted Pulumi resource prepares from its same step (F39)" $
        withSystemTempDirectory "pulumi-inventory-sames" $ \temporary -> do
          let program = temporary </> "program"
              executable = temporary </> "pulumi"
              stackConfig = temporary </> "Pulumi.dev.yaml"
              logPath = temporary </> "calls.log"
              verifyOperation = operation {plannedOperationId = ok (mkOperationId "op-cloud-verify"), plannedAction = VerifyResource}
          createDirectory program
          writeFile (program </> "index.ts") "export {};\n"
          writeFile stackConfig "config: {}\n"
          writeFile executable (fakePulumiOmittingSames logPath)
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
                  , runtimeCollectionPhysical = Map.empty
                  }
              adapter = mkPulumiAdapter [registration] (mkPulumiRuntimeOps config)
          _ <- adapterPrepare adapter verifyOperation >>= expectRight
          calls <- readFile logPath
          assertBool "the saved-plan preview asked Pulumi to report unchanged resources" (" --show-sames " `isInfixOf` calls)
    ]

fakePulumi :: FilePath -> String
fakePulumi logPath =
  unlines
    [ "#!/bin/sh"
    , "set -euo pipefail"
    , "test \"${PULUMI_BACKEND_URL:-}\" = gs://example-state"
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

-- | Pulumi 3.255 omits unchanged resources from @preview --json@ unless
-- @--show-sames@ is passed; only the implicit stack step remains.
fakePulumiOmittingSames :: FilePath -> String
fakePulumiOmittingSames logPath =
  unlines
    [ "#!/bin/sh"
    , "set -euo pipefail"
    , "printf '%s\\n' \"$*\" >> " <> show logPath
    , "case \" $* \" in"
    , "  *\" version \"*) printf '%s\\n' 'v3.255.0' ;;"
    , "  *\" stack export \"*) printf '%s\\n' '" <> stackExport <> "' ;;"
    , "  *\" preview \"*\" --save-plan \"*)"
    , "    sames=false; case \" $* \" in *\" --show-sames \"*) sames=true ;; esac"
    , "    while [ \"$#\" -gt 0 ]; do if [ \"$1\" = --save-plan ]; then shift; printf '%s' 'opaque-pulumi-plan' > \"$1\"; break; fi; shift; done"
    , "    if $sames; then printf '%s\\n' '" <> sameStep <> "'; else printf '%s\\n' '{\"steps\":[]}'; fi"
    , "    ;;"
    , "  *) exit 64 ;;"
    , "esac"
    ]
  where
    urn = T.unpack (registrationPulumiUrn registration)
    stackExport = "{\"deployment\":{\"resources\":[{\"urn\":\"" <> urn <> "\",\"id\":\"bucket-123\"}]}}"
    sameStep = "{\"steps\":[{\"op\":\"same\",\"urn\":\"" <> urn <> "\",\"replaceReasons\":[]}]}"

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
