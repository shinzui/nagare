-- | Tests for the EP-55 typed CDN model, its combinators, and the JSON
-- transport / loader round-trip.
module CdnSpec (cdnTests) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy (toStrict)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Cdn.Types
import Nagare.Dsl.Config (encodeDeployment)
import Nagare.Dsl.Load (LoadError (..), decodeDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..))
import Test.Tasty
import Test.Tasty.HUnit

cdnTests :: TestTree
cdnTests =
  testGroup
    "Nagare.Dsl.Cdn"
    [ testGroup "mkCdnCacheRule" cacheRuleTests
    , testGroup "presets" presetTests
    , testGroup "combinators" combinatorTests
    , testGroup "JSON round-trip" roundTripTests
    , testGroup "decode failure modes" decodeFailureTests
    , testGroup "backward compatibility" backwardCompatTests
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
-- Milestone 2: the CDN survives emit -> decode through the deployment transport
-- (the same shared cdnJSON / toCdn the three shapes use). A Cloudflare config
-- with an /assets/ year rule and an /api/ never-cache (null TTL) rule proves the
-- Nothing TTL survives as JSON null and back.

cloudflareWithRules :: Cdn
cloudflareWithRules =
  unsafe
    ( withCacheRule "/api/" Nothing
        =<< withCacheRule "/assets/" (Just 31536000) (withDefaultTtl 3600 cloudflareCdn)
    )

-- | A canonical deployment with the given CDN attached. 'cdn' is unambiguous
-- here because only 'Deployment''s field is imported.
depWithCdn :: Cdn -> Deployment
depWithCdn c = (unsafe (webService "notes" "gcr.io/myproject/notes")) {cdn = Just c}

depNoCdn :: Deployment
depNoCdn = unsafe (webService "notes" "gcr.io/myproject/notes")

roundTripTests :: [TestTree]
roundTripTests =
  [ testCase "Cloudflare CDN (default TTL + /assets/ + /api/ null) round-trips" $
      let dep = depWithCdn cloudflareWithRules
       in decodeDeployment (toStrict (encodeDeployment dep)) @?= Right dep
  , testCase "Google Cloud CDN (default TTL) round-trips" $
      let dep = depWithCdn (withDefaultTtl 600 gcpCloudCdn)
       in decodeDeployment (toStrict (encodeDeployment dep)) @?= Right dep
  , testCase "CDN with static-asset caching off round-trips" $
      let dep = depWithCdn (withoutStaticAssetCache cloudflareCdn)
       in decodeDeployment (toStrict (encodeDeployment dep)) @?= Right dep
  ]

-- ---------------------------------------------------------------------------
-- Negative: a hand-written cdn block with a bad value is rejected with a precise
-- MarshalError keyed by the dotted field path. Exercised through decodeDeployment
-- (the cdn block is shared by all three shapes).

decodeFailureTests :: [TestTree]
decodeFailureTests =
  [ testCase "valid cdn block decodes to Right" $
      case decodeDeployment (depWithCdnJson cloudflareBlock) of
        Right _ -> pure ()
        other -> assertFailure ("expected Right, got: " <> show other)
  , testCase "unknown provider returns MarshalError cdn.provider" $
      assertMarshal "cdn.provider" (depWithCdnJson "{\"provider\":\"Fastly\",\"cacheRules\":[]}")
  , testCase "negative defaultTtlSeconds returns MarshalError cdn.defaultTtlSeconds" $
      assertMarshal
        "cdn.defaultTtlSeconds"
        (depWithCdnJson "{\"provider\":\"Cloudflare\",\"defaultTtlSeconds\":-1,\"cacheRules\":[]}")
  , testCase "negative rule edgeTtlSeconds returns MarshalError cdn.cacheRules" $
      assertMarshal
        "cdn.cacheRules"
        ( depWithCdnJson
            "{\"provider\":\"Cloudflare\",\"cacheRules\":[{\"pathPrefix\":\"/x/\",\"edgeTtlSeconds\":-5}]}"
        )
  , testCase "a rule with edgeTtlSeconds null decodes to Nothing" $
      case decodeDeployment
        ( depWithCdnJson
            "{\"provider\":\"Cloudflare\",\"cacheRules\":[{\"pathPrefix\":\"/api/\",\"edgeTtlSeconds\":null}]}"
        ) of
        Right dep -> case cdn dep of
          Just c -> map edgeTtlSeconds (cacheRules c) @?= [Nothing]
          Nothing -> assertFailure "expected a cdn, got Nothing"
        other -> assertFailure ("expected Right, got: " <> show other)
  ]
  where
    assertMarshal field bs =
      case decodeDeployment bs of
        Left (MarshalError f _) | f == field -> pure ()
        other -> assertFailure ("expected MarshalError " <> show field <> ", got: " <> show other)

-- ---------------------------------------------------------------------------
-- Backward compatibility: a config with no CDN is byte-for-byte unchanged (no
-- "cdn" key emitted), and a JSON body with no "cdn" key decodes to Nothing.

backwardCompatTests :: [TestTree]
backwardCompatTests =
  [ testCase "a cdn = Nothing deployment emits no \"cdn\" key" $ do
      let encoded = TE.decodeUtf8 (toStrict (encodeDeployment depNoCdn))
      assertBool
        ("expected no \"cdn\" substring in:\n" <> Text.unpack encoded)
        (not ("cdn" `Text.isInfixOf` encoded))
  , testCase "a cdn = Nothing deployment round-trips" $
      decodeDeployment (toStrict (encodeDeployment depNoCdn)) @?= Right depNoCdn
  , testCase "deployment JSON with no cdn key decodes to cdn == Nothing" $
      case decodeDeployment depNoCdnJson of
        Right dep -> cdn dep @?= Nothing
        other -> assertFailure ("expected Right, got: " <> show other)
  ]

-- ---------------------------------------------------------------------------
-- JSON fixtures: a minimal valid deployment body, with or without a cdn block.

cloudflareBlock :: String
cloudflareBlock =
  "{\"provider\":\"Cloudflare\",\"defaultTtlSeconds\":3600,\"cacheStaticAssets\":true"
    <> ",\"cacheRules\":[{\"pathPrefix\":\"/assets/\",\"edgeTtlSeconds\":31536000}"
    <> ",{\"pathPrefix\":\"/api/\",\"edgeTtlSeconds\":null}]}"

deploymentBase :: String
deploymentBase =
  "{\"name\":\"notes\",\"namespace\":\"personal\""
    <> ",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[]"

depWithCdnJson :: String -> ByteString
depWithCdnJson cdnBlock = BC.pack (deploymentBase <> ",\"cdn\":" <> cdnBlock <> "}")

depNoCdnJson :: ByteString
depNoCdnJson = BC.pack (deploymentBase <> "}")

-- ---------------------------------------------------------------------------
-- Helpers (house pattern: each spec defines its own).

unsafe :: (Show e) => Either e a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> show e)

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
