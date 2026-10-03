module InventoryCloudCollectionSpec (cloudCollectionTests) where

import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Pulumi
import Nagare.Inventory.Adapters.PulumiRuntime
import Nagare.Inventory.Cloud
import Nagare.Inventory.CloudCollection
import Nagare.Inventory.CollectionPolicy
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty
import Test.Tasty.HUnit

cloudCollectionTests :: TestTree
cloudCollectionTests =
  testGroup
    "reviewed cloud collection"
    [ testCase "policy changes only finite stateless members and preserves dependencies and authority" $ do
        original <- expectRight (compileCloudScope fixture)
        let configured = withScopeOverrides (Map.singleton "existing" "value") (withScopeConfigDigest (contentDigest "config") original)
        changed <- expectRight (compileCloudCollectionPolicy configured)
        let before = members configured
            afterMembers = members changed
        length before @?= length afterMembers
        map (^. #lifecycle) afterMembers @?= [DeleteWhenUnreferenced, Protect, Protect]
        scopeConfigDigest changed @?= scopeConfigDigest configured
        Map.lookup "existing" (scopeOverrides changed) @?= Just "value"
        map (^. #dependencies) afterMembers @?= map (^. #dependencies) before
        map (^. #spec) afterMembers @?= map (^. #spec) before
        cloudCollectionPolicyOnly (head before) (head afterMembers) @?= True
        cloudCollectionPolicyOnly (head before) (head afterMembers & #spec .~ NativeObject (contentDigest "other")) @?= False
        map supportsRetainedCollection afterMembers @?= [True, False, False]
        compileCloudCollectionPolicy changed @?= Right changed
    , testCase "policy review verifies every selected resource without native update authority" $ do
        store <- newMemoryStore
        let binding = ContextBinding (ok (mkContextId "dev")) (name "project")
            original = ok (compileCloudScope fixture)
            base = ok (mkScopeSnapshot binding (Map.singleton (scopeId original) (ok (mkScopeGeneration 1), original)) Map.empty)
            dummy = ok (mkScopeDeclaration (ok (mkScopeId Standalone "unused")) [])
            seed = ok (composeInventory base (ReplaceScope dummy :| []))
        _ <- initializeStore store binding "cloud-policy" >>= expectRight
        _ <- seedInventoryHistory store seed >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let snapshot =
              ok
                ( mkScopeSnapshot
                    binding
                    (Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history))
                    Map.empty
                )
            revised = ok (compileCloudCollectionPolicy original)
            candidate = ok (composeInventory snapshot (ReplaceScope revised :| []))
            observations = ok (observationSet [(resource ^. #identity, ObservedPresent (ok (mkPhysicalIdentity "native"))) | resource <- members original])
        proposal <- expectRight (planChanges candidate noLifecycleDecisions history observations)
        assertBool "policy update emitted provider mutation" (all ((== VerifyResource) . plannedAction) (proposalOperations proposal))
        assertBool "policy change was not verified" (not (null (proposalOperations proposal)))
    , testCase "VM collection cannot clear independent native deletion protection" $ do
        let registration = last (expectedRegistrations fixture)
            exported flag = BS.pack ("{\"deployment\":{\"resources\":[{\"urn\":\"" <> T.unpack (registrationPulumiUrn registration) <> "\",\"inputs\":{\"deletionProtection\":" <> flag <> "}}]}}")
        validateCloudCollectionProtection [registration] (exported "false") @?= Right ()
        forM_ ["true", "null", "\"false\""] $ \flag ->
          assertBool "protected/unknown VM accepted" (isLeft (validateCloudCollectionProtection [registration] (exported flag)))
    , testCase "omission set rejects unknown, protected, duplicate and bookkeeping registrations" $ do
        let wire = encodeCloudDeclarationBundle fixture
            registrations = expectedRegistrations fixture
            selected = registrationPulumiUrn (head registrations)
            bucket = registrationPulumiUrn (registrations !! 1)
        _ <- expectRight (encodeCloudCollectionBundle wire [selected])
        assertBool "unknown accepted" (isLeft (encodeCloudCollectionBundle wire ["foreign"]))
        assertBool "duplicate accepted" (isLeft (encodeCloudCollectionBundle wire [selected, selected]))
        assertBool "bucket accepted" (isLeft (encodeCloudCollectionBundle wire [bucket]))
        let bookkeeping = (head (cloudResources fixture)) {cloudRegistrationClass = NativeBookkeeping "provider"}
        assertBool
          "bookkeeping accepted"
          ( isLeft
              ( encodeCloudCollectionBundle
                  (encodeCloudDeclarationBundle (fixture {cloudResources = [bookkeeping]}))
                  [selected]
              )
          )
    , testCase "ordinary fingerprint stays compatible while exact collection changes it" $ do
        let wire = encodeCloudDeclarationBundle fixture
            base = contentDigest "program"
            selected = registrationPulumiUrn (head (expectedRegistrations fixture))
        cloudCollectionProgramDigest base wire @?= Right base
        assertBool "v1 omission field accepted" (isLeft (cloudCollectionProgramDigest base "{\"version\":1,\"collections\":[]}"))
        omitted <- expectRight (encodeCloudCollectionBundle wire [selected])
        fingerprint <- expectRight (cloudCollectionProgramDigest base omitted)
        assertBool "collection did not bind program" (fingerprint /= base)
        assertBool "unsupported version accepted" (isLeft (cloudCollectionProgramDigest base "{\"version\":3}"))
    , testCase "collection recovery requires exact absence, never a no-change preview" $
        withSystemTempDirectory "cloud-collection" $ \temporary -> do
          let program = temporary </> "program"
              executable = temporary </> "pulumi"
              exported = temporary </> "export.json"
              calls = temporary </> "calls"
              config =
                PulumiRuntimeConfig
                  "dev"
                  "project"
                  "dev"
                  "gs://state"
                  "payload"
                  (contentDigest "payload")
                  executable
                  program
                  (temporary </> "Pulumi.dev.yaml")
                  (encodeCloudDeclarationBundle fixture)
                  (expectedRegistrations fixture)
              registration = head (expectedRegistrations fixture)
              operation =
                PlannedOperation
                  (ok (mkOperationId "op-collect"))
                  RetireResource
                  PulumiExecutor
                  (registrationResource registration :| [])
                  (contentDigest "spec")
                  []
                  Idempotent
              ops = mkPulumiRuntimeOps config
          createDirectory program
          writeFile
            executable
            ( unlines
                [ "#!/bin/sh"
                , "echo \"$*\" >> " <> show calls
                , "case \" $* \" in"
                , "*' stack export '*) cat " <> show exported <> ";;"
                , "*) exit 99;;"
                , "esac"
                ]
            )
          setFileMode executable 0o700
          writeFile exported ("{\"deployment\":{\"resources\":[{\"urn\":\"" <> T.unpack (registrationPulumiUrn registration) <> "\",\"id\":\"same-resource\"}]}}")
          pulumiVerifyResources ops operation "plan" >>= assertBool "present resource verified" . isLeft
          recoveredPresent <- pulumiRecoverSavedPlan ops operation "plan"
          case recoveredPresent of RecoveryUnresolved _ -> pure (); other -> assertFailure (show other)
          writeFile exported "{\"deployment\":{\"resources\":[]}}"
          _ <- pulumiVerifyResources ops operation "plan" >>= expectRight
          recoveredAbsent <- pulumiRecoverSavedPlan ops operation "plan"
          case recoveredAbsent of RecoveryProvedComplete _ -> pure (); other -> assertFailure (show other)
          writeFile exported "unreadable export"
          pulumiVerifyResources ops operation "plan" >>= assertBool "unreadable export verified" . isLeft
          pulumiApplySavedPlan ops (operation {plannedAction = VerifyResource}) "plan" >>= (@?= AdapterEffectCompleted)
          invoked <- BS.readFile calls
          assertBool "recovery sent mutation/preview" (not (" up " `BS.isInfixOf` invoked || " preview " `BS.isInfixOf` invoked))
    ]

fixture :: CloudDeclarationBundle
fixture =
  CloudDeclarationBundle
    1
    (ok (mkContextId "dev"))
    (name "project")
    (name "dev")
    owner
    [ member "a-firewall" "gcp:compute/firewall:Firewall" Stateless
    , member "b-bucket" "gcp:storage/bucket:Bucket" Stateless
    , member "c-durable" "gcp:compute/instance:Instance" (Durable (RecoveryIntent (name "data") (mkSecretRef (name "credential") (name "v1") :| [])))
    ]
  where
    owner = ok (mkScopeId Platform "cloud")
    member key kind policy =
      CloudResource
        (ok (mkLogicalKey key))
        (name "resource")
        (PulumiAddress (urn kind key))
        []
        (contentDigest "spec")
        Protect
        policy
        Private
        []
        (SourceLocation "fixture" key)
        kind
        (name key)
        (urn kind key)
        ManagedRegistration
    urn kind key = "urn:pulumi:dev::nagare::" <> kind <> "::" <> key

members :: ScopeDeclaration -> [ManagedResource]
members scope = [resource | bundle <- scopeBundles scope, Managed resource <- declarations bundle]

name :: Text -> Name
name = ok . mkName

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure
