-- | Tests for the EP-55 typed CDN model, its combinators, and the JSON
-- transport / loader round-trip (Milestone 2 groups are appended here).
module CdnSpec (cdnTests) where

import Data.ByteString.Lazy (toStrict)
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Cdn.Types
import Test.Tasty
import Test.Tasty.HUnit

cdnTests :: TestTree
cdnTests =
  testGroup
    "Nagare.Dsl.Cdn"
    [ testGroup "mkCdnCacheRule" cacheRuleTests
    , testGroup "presets" presetTests
    , testGroup "combinators" combinatorTests
    ]

cacheRuleTests :: [TestTree]
cacheRuleTests =
  [ testCase "accepts /assets/ with a year TTL" $
      assertRight (mkCdnCacheRule "/assets/" (Just 31536000))
  , testCase "rejects empty prefix" $
      assertLeftContains "empty" (mkCdnCacheRule "" (Just 1))
  , testCase "rejects all-whitespace prefix" $
      assertLeftContains "whitespace" (mkCdnCacheRule "   " (Just 1))
  , testCase "rejects negative TTL" $
      assertLeftContains ">= 0" (mkCdnCacheRule "/x" (Just (-1)))
  , testCase "allows null TTL (never cache)" $
      case mkCdnCacheRule "/api/" Nothing of
        Right r -> edgeTtlSeconds r @?= Nothing
        Left e -> assertFailure ("expected Right, got Left: " <> Text.unpack e)
  , testCase "mkCacheRules builds a validated list" $
      case mkCacheRules [("/assets/", Just 10), ("/api/", Nothing)] of
        Right rs -> map pathPrefix rs @?= ["/assets/", "/api/"]
        Left e -> assertFailure ("expected Right, got Left: " <> Text.unpack e)
  , testCase "mkCacheRules rejects a bad entry" $
      assertLeftContains "empty" (mkCacheRules [("/ok/", Just 1), ("", Just 1)])
  ]

presetTests :: [TestTree]
presetTests =
  [ testCase "cloudflareCdn defaults" $ do
      provider cloudflareCdn @?= CloudflareCdn
      cacheStaticAssets cloudflareCdn @?= True
      defaultTtlSeconds cloudflareCdn @?= Nothing
      cacheRules cloudflareCdn @?= []
  , testCase "gcpCloudCdn differs only in provider" $ do
      provider gcpCloudCdn @?= GcpCloudCdn
      gcpCloudCdn @?= cloudflareCdn {provider = GcpCloudCdn}
  ]

combinatorTests :: [TestTree]
combinatorTests =
  [ testCase "withDefaultTtl sets the TTL" $
      defaultTtlSeconds (withDefaultTtl 3600 cloudflareCdn) @?= Just 3600
  , testCase "withoutStaticAssetCache clears the flag" $
      cacheStaticAssets (withoutStaticAssetCache cloudflareCdn) @?= False
  , testCase "withCacheRule appends a validated rule" $
      case withCacheRule "/api/" Nothing cloudflareCdn of
        Right c -> map edgeTtlSeconds (cacheRules c) @?= [Nothing]
        Left e -> assertFailure ("expected Right, got Left: " <> Text.unpack e)
  , testCase "withCacheRule rejects an invalid rule" $
      assertLeftContains "empty" (withCacheRule "" (Just 1) cloudflareCdn)
  ]

-- ---------------------------------------------------------------------------
-- Helpers (house pattern: each spec defines its own).

assertRight :: (Show e) => Either e a -> Assertion
assertRight (Right _) = pure ()
assertRight (Left err) = assertFailure ("expected Right, got Left: " <> show err)

assertLeftContains :: Text -> Either Text a -> Assertion
assertLeftContains needle (Left msg)
  | needle `Text.isInfixOf` msg = pure ()
  | otherwise =
      assertFailure ("expected Left containing " <> show needle <> ", got: " <> Text.unpack msg)
assertLeftContains needle (Right _) =
  assertFailure ("expected Left containing " <> show needle <> ", got Right")
