-- | Gcp responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Gcp
  ( adcTests
  )
where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Gcp.Adc
  ( AdcEnv (..)
  , AdcError (..)
  , AdcObservation (..)
  , AdcSource (..)
  , adcEvidenceValue
  , observeAdc
  , parseAdc
  , resolveAdcSource
  , validateAdc
  )
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

adcTests :: TestTree
adcTests =
  testGroup
    "Nagare.Gcp.Adc (EP-135)"
    [ testCase "credential path precedence is explicit, CLOUDSDK_CONFIG, then HOME" $ do
        resolveAdcSource (AdcEnv (Just "/explicit.json") (Just "/cloudsdk") (Just "/home"))
          @?= Right (AdcEnvironmentFile "/explicit.json")
        resolveAdcSource (AdcEnv Nothing (Just "/cloudsdk") (Just "/home"))
          @?= Right (AdcCloudSdkConfigFile "/cloudsdk/application_default_credentials.json")
        resolveAdcSource (AdcEnv Nothing Nothing (Just "/home"))
          @?= Right (AdcGcloudDefaultFile "/home/.config/gcloud/application_default_credentials.json")
        resolveAdcSource (AdcEnv Nothing Nothing Nothing) @?= Left AdcPathUnavailable
    , testCase "authorized-user and service-account fixtures expose only identity metadata" $ do
        matchingAdc <- observeFixture "authorized-matching.json"
        matchingAdc
          @?= Right
            AdcObservation
              { source = AdcEnvironmentFile (fixturePath "authorized-matching.json")
              , credentialKind = "authorized_user"
              , principal = Just "operator@example.com"
              , quotaProject = Just "labs-project"
              }
        service <- observeFixture "service-account.json"
        service
          @?= Right
            AdcObservation
              { source = AdcEnvironmentFile (fixturePath "service-account.json")
              , credentialKind = "service_account"
              , principal = Just "nagare-operator@labs-project.iam.gserviceaccount.com"
              , quotaProject = Just "labs-project"
              }
    , testCase "matching, foreign, absent, and unknowable ADC policy is explicit" $ do
        matchingAdc <- observeFixture "authorized-matching.json"
        validateAdc "labs-project" (Just "operator@example.com") matchingAdc @?= Right []
        foreignAdc <- observeFixture "authorized-foreign.json"
        case validateAdc "labs-project" (Just "operator@example.com") foreignAdc of
          Left message -> do
            assertBool "foreign quota named" ("production-project" `T.isInfixOf` message)
            assertBool "repair command exact" ("gcloud auth application-default set-quota-project labs-project" `T.isInfixOf` message)
          Right _ -> assertFailure "foreign quota project was accepted"
        noQuota <- observeFixture "authorized-no-quota.json"
        case validateAdc "labs-project" (Just "operator@example.com") noQuota of
          Right [warning] -> assertBool "absent quota warned" ("no quota_project_id" `T.isInfixOf` warning)
          other -> assertFailure ("expected one quota warning, got " <> show other)
        noAccount <- observeFixture "authorized-no-account.json"
        case validateAdc "labs-project" (Just "operator@example.com") noAccount of
          Right [warning] -> assertBool "unknown principal warned" ("do not expose a principal" `T.isInfixOf` warning)
          other -> assertFailure ("expected one principal warning, got " <> show other)
    , testCase "a known principal mismatch warns without overriding matching quota policy" $ do
        matchingAdc <- observeFixture "authorized-matching.json"
        case validateAdc "labs-project" (Just "other@example.com") matchingAdc of
          Right [warning] -> do
            assertBool "ADC principal named" ("operator@example.com" `T.isInfixOf` warning)
            assertBool "gcloud account named" ("other@example.com" `T.isInfixOf` warning)
          other -> assertFailure ("expected one principal mismatch warning, got " <> show other)
    , testCase "missing, malformed, and invalid-shape credentials fail without secret content" $ do
        missing <- observeAdc (AdcEnv (Just (fixturePath "missing.json")) Nothing Nothing)
        assertBool "missing classified" $ case missing of
          Left (AdcFileMissing _) -> True
          _ -> False
        malformed <- observeFixture "malformed.json"
        assertBool "malformed classified" $ case malformed of
          Left (AdcInvalidJson _) -> True
          _ -> False
        let invalid = parseAdc (AdcEnvironmentFile "inline.json") "{\"type\":7,\"refresh_token\":\"inline-token-sentinel\"}"
        assertBool "invalid shape classified" $ case invalid of
          Left (AdcInvalidShape _ _) -> True
          _ -> False
        forM_
          [ T.pack (show missing)
          , T.pack (show malformed)
          , T.pack (show invalid)
          , TE.decodeUtf8 (LBS.toStrict (Aeson.encode (adcEvidenceValue "labs-project" Nothing malformed)))
          ]
          ( \rendered -> do
              assertBool "refresh token redacted" (not ("refresh-token-sentinel" `T.isInfixOf` rendered))
              assertBool "inline token redacted" (not ("inline-token-sentinel" `T.isInfixOf` rendered))
          )
    ]
  where
    fixturePath name = "test/fixtures/adc" </> name
    observeFixture name = observeAdc (AdcEnv (Just (fixturePath name)) Nothing Nothing)
