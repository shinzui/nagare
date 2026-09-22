module InventoryCloudSpec (inventoryCloudTests) where

import Data.ByteString.Char8 qualified as BC
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Infra.Plan (StepOp (OpCreate))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Pulumi
import Nagare.Inventory.Cloud
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
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
    ]

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
