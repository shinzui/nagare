-- | Infrastructure responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Infrastructure
  ( infraPlanTests
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Infra.Plan
  ( CurrentInfraIdentity (CurrentInfraIdentity)
  , PlanVerdict (PlanAllowed, PlanReplacesProtected)
  , SavedPlanMetadata (SavedPlanMetadata)
  , SavedPlanReview (SavedPlanReview)
  , classifyPlan
  , parsePreview
  , previewErrors
  , protectedResourceTypes
  , renderPlanBindingError
  , renderVerdict
  , reviewVerdict
  , verifySavedPlan
  )
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

infraPlanTests :: TestTree
infraPlanTests =
  testGroup
    "Nagare.Infra.Plan"
    [ testCase "an instance replacement is refused" $ do
        steps <- parseFixture "replace-instance.json"
        case classifyPlan protectedResourceTypes steps of
          PlanReplacesProtected replacing -> length replacing @?= 1
          PlanAllowed -> assertFailure "replacement fixture was allowed"
    , testCase "an in-place machine-type update is allowed" $ do
        steps <- parseFixture "update-machine-type.json"
        classifyPlan protectedResourceTypes steps @?= PlanAllowed
    , testCase "a fresh instance creation is allowed" $ do
        steps <- parseFixture "create-fresh.json"
        classifyPlan protectedResourceTypes steps @?= PlanAllowed
    , testCase "an apex DNS record target update is allowed" $ do
        steps <- parseFixture "update-apex-record.json"
        classifyPlan protectedResourceTypes steps @?= PlanAllowed
    , testCase "malformed JSON is refused" $
        assertBool "malformed preview rejected" (isLeft (parsePreview "{"))
    , testCase "an unknown operation is refused" $
        assertBool
          "unknown operation rejected"
          (isLeft (parsePreview "{\"steps\":[{\"op\":\"mystery\",\"urn\":\"urn:test\"}]}"))
    , testCase "the refusal explains the full boot-disk loss" $ do
        steps <- parseFixture "replace-instance.json"
        let rendered = renderVerdict "nagare-01" (classifyPlan protectedResourceTypes steps)
        assertBool "k3s datastore" (T.isInfixOf "/var/lib/rancher" rendered)
        assertBool "ACME key" (T.isInfixOf "ACME account key" rendered)
        assertBool "instance" (T.isInfixOf "nagare-01" rendered)
        assertBool "reason" (T.isInfixOf "bootDisk" rendered)
    , testCase "a preview with no steps is allowed" $
        (parsePreview "{}" >>= Right . classifyPlan protectedResourceTypes) @?= Right PlanAllowed
    , testCase "EP-121: a DNS managed zone replacement is refused and explains the name servers" $ do
        steps <- parseFixture "replace-dns-zone.json"
        let verdict = classifyPlan protectedResourceTypes steps
            rendered = renderVerdict "nagare-01" verdict
        case verdict of
          PlanReplacesProtected replacing -> length replacing @?= 1
          PlanAllowed -> assertFailure "zone replacement fixture was allowed"
        assertBool "name servers" (T.isInfixOf "new name servers" rendered)
        assertBool "base domain" (T.isInfixOf "NAGARE_BASE_DOMAIN" rendered)
        assertBool "no instance paragraph" (not (T.isInfixOf "/var/lib/rancher" rendered))
    , testCase "EP-121: a bucket replacement is refused and explains the object loss" $ do
        steps <- parseFixture "replace-bucket.json"
        let verdict = classifyPlan protectedResourceTypes steps
        assertBool "refused" (verdict /= PlanAllowed)
        assertBool "objects" (T.isInfixOf "every object" (renderVerdict "nagare-01" verdict))
    , testCase "EP-121: a failed preview's error diagnostics are surfaced" $ do
        bytes <- BS.readFile "test/fixtures/pulumi-preview/program-error.json"
        case previewErrors bytes of
          [message] -> assertBool "SDK message" (T.isInfixOf "Pulumi SDK has not been installed" message)
          other -> assertFailure ("expected one error diagnostic, got " <> show other)
    , testCase "a saved review round-trips only classified operations and approval" $ do
        steps <- parseFixture "replace-instance.json"
        let original = SavedPlanReview 1 True steps
        decoded <- either assertFailure pure (Aeson.eitherDecode (Aeson.encode original))
        decoded @?= original
        case reviewVerdict decoded of
          PlanReplacesProtected replacing -> length replacing @?= 1
          PlanAllowed -> assertFailure "round-tripped replacement review was allowed"
    , testCase "saved-plan bindings fail closed on another context" $ do
        let current = currentIdentity
            metadata = savedMetadata
        verifySavedPlan current metadata @?= Right ()
        case verifySavedPlan (current & #currentContext .~ "prod") metadata of
          Left err -> assertBool "context mismatch named" (T.isInfixOf "context" (renderPlanBindingError err))
          Right () -> assertFailure "another context accepted the saved plan"
    , testCase "saved-plan bindings include backend, program, config, payload, and Pulumi version" $ do
        let mismatches =
              [ currentIdentity & #currentBackend .~ "gs://other/state"
              , currentIdentity & #currentProgramDigest .~ "other-program"
              , currentIdentity & #currentConfigDigest .~ "other-config"
              , currentIdentity & #currentPayloadDigest .~ "other-payload"
              , currentIdentity & #currentPulumiVersion .~ "v0.0.0"
              ]
        assertBool "every changed binding refuses" (all (isLeft . (`verifySavedPlan` savedMetadata)) mismatches)
    ]
  where
    parseFixture name = do
      bytes <- BS.readFile ("test/fixtures/pulumi-preview" </> name)
      either (assertFailure . T.unpack) pure (parsePreview bytes)
    currentIdentity =
      CurrentInfraIdentity
        "labs"
        "acme-prod"
        "labs"
        "file:///state/labs"
        "nagare-0.2.2"
        "payload-digest"
        "program-digest"
        "config-digest"
        "v3.255.0"
    savedMetadata =
      SavedPlanMetadata
        1
        "labs"
        "acme-prod"
        "labs"
        "file:///state/labs"
        "nagare-0.2.2"
        "payload-digest"
        "program-digest"
        "config-digest"
        "v3.255.0"
        "2026-09-14T00:00:00Z"
        "plan-digest"
        "review-digest"
