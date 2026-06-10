-- | Tests for the EP-13 static-site model, loader, and renderers.
--
-- Positive path: the @static-site@ config-as-program fixture loads through
-- 'loadStaticSite' to the very same 'StaticSite' assembled here, and renders to
-- golden Nginx config, Knative Service, and DomainMapping artifacts. Negative
-- path: invalid leaves are rejected at construction, and a config that emits the
-- wrong @kind@ (or none) is reported as 'UnexpectedKind' rather than misread.
module StaticSpec (staticTests) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy (fromStrict)
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Cdn.Types
import Nagare.Dsl.Load
import Nagare.Dsl.Static.Render
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkDomain, mkImageRef, mkNamespace)
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit

staticTests :: TestTree
staticTests =
  testGroup
    "Nagare.Dsl.Static"
    [ testGroup "smart constructors" constructorTests
    , testGroup "loadStaticSite + render goldens" loadAndGoldenTests
    , testGroup "decodeStaticSite failure modes" decodeFailureTests
    ]

-- ---------------------------------------------------------------------------
-- The expected fixture site, assembled through smart constructors.

ctx :: StaticDeployContext
ctx = StaticDeployContext {imageTag = "20260607-120000", previewName = Nothing}

notesSite :: StaticSite
notesSite =
  StaticSite
    { name = unsafe (mkSiteName "notes")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes")
    , build =
        BuildCommand
          { command = "npm run build"
          , outputDirectory = unsafe (mkFilePathText "dist")
          }
    , domains = [unsafe (mkDomain "notes.example.com")]
    , redirects = [unsafe (mkRedirectRule "/old" "/new" 301)]
    , headers = [unsafe (mkHeaderRule "/assets/" "X-Frame-Options" "DENY")]
    , cache = unsafe (mkCachePolicy True (Just 3600))
    , notFound = Just (unsafe (mkFilePathText "404.html"))
    , cdn =
        Just
          ( unsafe
              ( withCacheRule "/api/" Nothing
                  =<< withCacheRule "/assets/" (Just 31536000) (withDefaultTtl 3600 cloudflareCdn)
              )
          )
    }

-- ---------------------------------------------------------------------------
-- Positive: load + render goldens

loadAndGoldenTests :: [TestTree]
loadAndGoldenTests =
  [ testCase "loadStaticSite notes returns Right notesSite" $ do
      result <- loadStaticSite fixturePath
      case result of
        Left err -> assertFailure ("loadStaticSite returned Left: " <> show err)
        Right site -> site @?= notesSite
  , goldenVsString
      "renderNginxConfig notes"
      "test/golden/static-site.nginx.conf"
      (pure (fromStrict (renderNginxConfig notesSite)))
  , goldenVsString
      "renderStaticService notes"
      "test/golden/static-site.service.yaml"
      (pure (fromStrict (renderStaticService notesSite ctx)))
  , goldenVsString
      "renderStaticDomainMappings notes"
      "test/golden/static-site.domainmapping.yaml"
      (pure (fromStrict (joinDocs (renderStaticDomainMappings notesSite ctx))))
  ]
  where
    fixturePath = "test/fixtures/static-site/nagare/Config.hs"

-- | Concatenate YAML documents with a @---@ separator. The fixture has one
-- domain, so this is a single document; the join keeps the test honest if a
-- future fixture adds domains.
joinDocs :: [ByteString] -> ByteString
joinDocs = BS.intercalate (BC.pack "---\n")

-- ---------------------------------------------------------------------------
-- Negative: constructor-level rejections

constructorTests :: [TestTree]
constructorTests =
  [ testGroup
      "mkSiteName"
      [ testCase "accepts notes" $ assertRight (mkSiteName "notes")
      , testCase "rejects uppercase" $ assertLeftContains "invalid" (mkSiteName "Notes")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkSiteName "")
      ]
  , testGroup
      "mkFilePathText"
      [ testCase "accepts dist" $ assertRight (mkFilePathText "dist")
      , testCase "accepts nested" $ assertRight (mkFilePathText "build/client")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkFilePathText "")
      , testCase "rejects absolute" $ assertLeftContains "relative" (mkFilePathText "/etc/passwd")
      , testCase "rejects parent segment" $ assertLeftContains ".." (mkFilePathText "a/../b")
      ]
  , testGroup
      "mkRedirectRule"
      [ testCase "accepts 301" $ assertRight (mkRedirectRule "/old" "/new" 301)
      , testCase "accepts 308" $ assertRight (mkRedirectRule "/old" "/new" 308)
      , testCase "rejects 418" $ assertLeftContains "status" (mkRedirectRule "/old" "/new" 418)
      , testCase "rejects 200" $ assertLeftContains "status" (mkRedirectRule "/old" "/new" 200)
      , testCase "rejects whitespace in from" $
          assertLeftContains "whitespace" (mkRedirectRule "/a b" "/new" 301)
      ]
  , testGroup
      "mkHeaderRule"
      [ testCase "accepts X-Frame-Options" $
          assertRight (mkHeaderRule "/assets/" "X-Frame-Options" "DENY")
      , testCase "rejects colon in name" $
          assertLeftContains "colon" (mkHeaderRule "/x" "X:Bad" "v")
      , testCase "rejects whitespace in name" $
          assertLeftContains "whitespace" (mkHeaderRule "/x" "X Bad" "v")
      , testCase "rejects empty name" $ assertLeftContains "empty" (mkHeaderRule "/x" "" "v")
      ]
  , testGroup
      "mkCachePolicy"
      [ testCase "accepts immutable + max-age" $ assertRight (mkCachePolicy True (Just 3600))
      , testCase "accepts neutral" $ assertRight (mkCachePolicy False Nothing)
      , testCase "rejects negative max-age" $
          assertLeftContains ">= 0" (mkCachePolicy False (Just (-1)))
      ]
  ]

-- ---------------------------------------------------------------------------
-- Negative: decode-level rejections (re-running the constructors over JSON)

decodeFailureTests :: [TestTree]
decodeFailureTests =
  [ testCase "valid JSON decodes to Right" $
      case decodeStaticSite (BC.pack (staticJSON validParts)) of
        Right _ -> pure ()
        other -> assertFailure ("expected Right, got: " <> show other)
  , testCase "bad site name returns MarshalError name" $
      assertMarshal "name" (staticJSON validParts {pName = "Notes"})
  , testCase "absolute output dir returns MarshalError build.outputDirectory" $
      assertMarshal
        "build.outputDirectory"
        (staticJSON validParts {pBuild = "{\"kind\":\"BuildCommand\",\"command\":\"x\",\"outputDirectory\":\"/dist\"}"})
  , testCase "parent-dir segment in notFound returns MarshalError notFound" $
      assertMarshal "notFound" (staticJSON validParts {pNotFound = "\"../secret\""})
  , testCase "invalid redirect status returns MarshalError redirect" $
      assertMarshal
        "redirect"
        (staticJSON validParts {pRedirects = "[{\"from\":\"/old\",\"to\":\"/new\",\"status\":418}]"})
  , testCase "invalid header name returns MarshalError header" $
      assertMarshal
        "header"
        (staticJSON validParts {pHeaders = "[{\"path\":\"/x\",\"name\":\"X:Bad\",\"value\":\"v\"}]"})
  , testCase "no kind (deployment-shaped) returns UnexpectedKind" $
      case decodeStaticSite (BC.pack deploymentJSON) of
        Left (UnexpectedKind "StaticSite" "<none>") -> pure ()
        other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
  , testCase "ServerSite kind returns UnexpectedKind" $
      case decodeStaticSite (BC.pack (staticJSON validParts {pKind = "ServerSite"})) of
        Left (UnexpectedKind "StaticSite" "ServerSite") -> pure ()
        other -> assertFailure ("expected UnexpectedKind ServerSite, got: " <> show other)
  ]
  where
    assertMarshal field json =
      case decodeStaticSite (BC.pack json) of
        Left (MarshalError f _) | f == field -> pure ()
        other -> assertFailure ("expected MarshalError " <> show field <> ", got: " <> show other)

-- | A deployment-shaped JSON (the shape 'Nagare.Dsl.Config.emitDeployment'
-- prints) — no @kind@ field, so 'decodeStaticSite' must reject it.
deploymentJSON :: String
deploymentJSON =
  "{\"name\":\"hello\",\"namespace\":\"personal\",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[]}"

-- ---------------------------------------------------------------------------
-- JSON template for the decode tests

data StaticParts = StaticParts
  { pKind :: String
  , pName :: String
  , pBuild :: String
  , pRedirects :: String
  , pHeaders :: String
  , pNotFound :: String
  }

validParts :: StaticParts
validParts =
  StaticParts
    { pKind = "StaticSite"
    , pName = "notes"
    , pBuild = "{\"kind\":\"NoBuild\",\"directory\":\"dist\"}"
    , pRedirects = "[]"
    , pHeaders = "[]"
    , pNotFound = "null"
    }

staticJSON :: StaticParts -> String
staticJSON p =
  "{\"kind\":\""
    <> pKind p
    <> "\",\"name\":\""
    <> pName p
    <> "\",\"namespace\":\"personal\",\"image\":\"gcr.io/foo/bar\",\"build\":"
    <> pBuild p
    <> ",\"domains\":[],\"redirects\":"
    <> pRedirects p
    <> ",\"headers\":"
    <> pHeaders p
    <> ",\"cache\":{\"immutableAssets\":false,\"defaultMaxAge\":null},\"notFound\":"
    <> pNotFound p
    <> "}"

-- ---------------------------------------------------------------------------
-- Helpers

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> Text.unpack e)

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
