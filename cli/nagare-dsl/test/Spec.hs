module Main (main) where

import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import LoadSpec (loadTests)
import Nagare.Dsl.Build
import Nagare.Dsl.Config (encodeDeployment)
import Nagare.Dsl.Load (LoadError (..), decodeDeployment, loadDeployment)
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (development, production, secretEnv, webService)
import Nagare.Dsl.Render (renderDomainMapping, renderService)
import Nagare.Dsl.Types
import ServerSpec (serverTests)
import StaticSpec (staticTests)
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (Gen, Property, choose, elements, forAll, testProperty)

main :: IO ()
main =
  defaultMain $
    testGroup
      "nagare-dsl"
      [ testGroup "Nagare.Dsl.Types" unitTests
      , testGroup "Nagare.Dsl.Render" goldenTests
      , testGroup "Nagare.Dsl.Types scoped env" scopedEnvTests
      , testGroup "Nagare.Dsl.Build" buildSpecTests
      , testGroup "Nagare.Dsl.Load" loadGoldenTests
      , loadTests
      , testGroup "Nagare.Dsl.Presets" (presetsGoldenTests <> presetsPropertyTests)
      , staticTests
      , serverTests
      ]

-- | EP-10: the hello config-as-program file loads to the very same
-- 'Deployment' EP-9 constructs, and renders to the same golden Service YAML.
loadGoldenTests :: [TestTree]
loadGoldenTests =
  [ testCase "loadDeployment hello returns Right helloDep" $ do
      result <- loadDeployment "test/fixtures/nagare/Config.hs"
      case result of
        Left err -> assertFailure ("loadDeployment returned Left: " <> show err)
        Right dep -> dep @?= helloDep
  , goldenVsString
      "loadDeployment hello renders to golden service YAML"
      "test/golden/hello.service.yaml"
      ( do
          result <- loadDeployment "test/fixtures/nagare/Config.hs"
          case result of
            Left err -> fail ("loadDeployment returned Left: " <> show err)
            Right dep -> pure (fromStrict (renderService dep "20260602-120000"))
      )
  ]

-- | EP-11: two example apps share one preset library and one overlay. Each is
-- loaded end-to-end via 'loadDeployment' (presets -> loader -> renderer); the
-- goldens differ only in name/image/env, proving "shared, not copy-pasted".
presetsGoldenTests :: [TestTree]
presetsGoldenTests =
  [ goldenVsString
      "preset-app-a: notes service (webService + production)"
      "test/golden/preset-app-a.service.yaml"
      (loadAndRender "../../cluster/examples/preset-app-a/nagare/Config.hs")
  , goldenVsString
      "preset-app-b: tasks service (webService + secretEnv + production)"
      "test/golden/preset-app-b.service.yaml"
      (loadAndRender "../../cluster/examples/preset-app-b/nagare/Config.hs")
  ]
  where
    loadAndRender path = do
      result <- loadDeployment path
      case result of
        Left err -> fail ("loadDeployment " <> path <> ": " <> show err)
        Right dep -> pure (fromStrict (renderService dep "20260602-120000"))

-- | EP-11: composing valid presets/overlays always yields a valid 'Deployment',
-- and an overlay that forces @max < min@ is rejected (never silently applied).
presetsPropertyTests :: [TestTree]
presetsPropertyTests =
  [ testProperty "webService valid name+image yields Right" prop_webServiceValid
  , testProperty "webService >>= production yields Right" prop_productionOverlayValid
  , testProperty "webService >>= development yields Right" prop_developmentOverlayValid
  , testProperty "webService >>= secretEnv yields Right" prop_secretEnvValid
  , testProperty "overlay forcing max<min is rejected (Left)" prop_invalidScaleOverlayRejected
  ]

-- | Valid DNS-label-safe name: 1–10 lowercase letters.
genValidName :: Gen Text
genValidName = do
  len <- choose (1, 10)
  cs <- sequence (replicate len (elements ['a' .. 'z']))
  pure (Text.pack cs)

-- | Valid image path of the form @gcr.io/<proj>/<repo>@ (no tag).
genValidImage :: Gen Text
genValidImage = do
  proj <- genValidName
  repo <- genValidName
  pure ("gcr.io/" <> proj <> "/" <> repo)

prop_webServiceValid :: Property
prop_webServiceValid =
  forAll ((,) <$> genValidName <*> genValidImage) $ \(n, img) ->
    isRight (webService n img)

prop_productionOverlayValid :: Property
prop_productionOverlayValid =
  forAll ((,) <$> genValidName <*> genValidImage) $ \(n, img) ->
    isRight (webService n img >>= production)

prop_developmentOverlayValid :: Property
prop_developmentOverlayValid =
  forAll ((,) <$> genValidName <*> genValidImage) $ \(n, img) ->
    isRight (webService n img >>= development)

prop_secretEnvValid :: Property
prop_secretEnvValid =
  forAll ((,,) <$> genValidName <*> genValidImage <*> genValidName) $ \(n, img, sec) ->
    isRight (webService n img >>= secretEnv "MY_VAR" sec)

-- | An overlay author's mistake (max < min) is caught by 'mkScale', not stored.
prop_invalidScaleOverlayRejected :: Property
prop_invalidScaleOverlayRejected =
  forAll ((,) <$> genValidName <*> genValidImage) $ \(n, img) ->
    case webService n img of
      Left _ -> True -- construction failure is not what we test here
      Right dep -> isLeft (badScaleOverlay dep)
  where
    badScaleOverlay d = do
      sc <- mkScale 5 1 -- max=1 < min=5: must be rejected
      pure (d {scale = Just sc})

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

unitTests :: [TestTree]
unitTests =
  [ testGroup
      "mkServiceName"
      [ testCase "accepts valid name" $ assertRight (mkServiceName "hello")
      , testCase "accepts name with hyphens" $ assertRight (mkServiceName "my-app-123")
      , testCase "accepts single char" $ assertRight (mkServiceName "a")
      , testCase "accepts 63 chars" $ assertRight (mkServiceName (Text.replicate 63 "a"))
      , testCase "rejects empty" $ assertLeftContains "empty" (mkServiceName "")
      , testCase "rejects 64 chars" $ assertLeftContains "long" (mkServiceName (Text.replicate 64 "a"))
      , testCase "rejects leading hyphen" $ assertLeftContains "hyphen" (mkServiceName "-bad")
      , testCase "rejects trailing hyphen" $ assertLeftContains "hyphen" (mkServiceName "bad-")
      , testCase "rejects uppercase" $ assertLeftContains "invalid" (mkServiceName "Hello")
      , testCase "rejects space" $ assertLeftContains "invalid" (mkServiceName "my app")
      , testCase "rejects dot" $ assertLeftContains "invalid" (mkServiceName "my.app")
      ]
  , testGroup
      "mkNamespace"
      [ testCase "accepts personal" $ assertRight (mkNamespace "personal")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkNamespace "")
      , testCase "rejects uppercase" $ assertLeftContains "invalid" (mkNamespace "Personal")
      ]
  , testGroup
      "mkImageRef"
      [ testCase "accepts path" $ assertRight (mkImageRef "gcr.io/foo/bar")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkImageRef "")
      , testCase "rejects tagged path" $ assertLeftContains "tag" (mkImageRef "gcr.io/foo/bar:latest")
      ]
  , testGroup
      "mkPort"
      [ testCase "accepts 8080" $ assertRight (mkPort 8080)
      , testCase "accepts 1" $ assertRight (mkPort 1)
      , testCase "accepts 65535" $ assertRight (mkPort 65535)
      , testCase "rejects 0" $ assertLeftContains ">= 1" (mkPort 0)
      , testCase "rejects negative" $ assertLeftContains ">= 1" (mkPort (-1))
      , testCase "rejects 65536" $ assertLeftContains "<= 65535" (mkPort 65536)
      ]
  , testGroup
      "mkQuantity"
      [ testCase "accepts 250m" $ assertRight (mkQuantity "250m")
      , testCase "accepts 512Mi" $ assertRight (mkQuantity "512Mi")
      , testCase "accepts 1" $ assertRight (mkQuantity "1")
      , testCase "accepts 2Gi" $ assertRight (mkQuantity "2Gi")
      , testCase "accepts 1.5" $ assertRight (mkQuantity "1.5")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkQuantity "")
      , testCase "rejects abc" $ assertLeftContains "digit" (mkQuantity "abc")
      , testCase "rejects 100x" $ assertLeftContains "suffix" (mkQuantity "100x")
      , testCase "rejects space" $ assertLeftContains "suffix" (mkQuantity "100 Mi")
      ]
  , testGroup
      "mkScale"
      [ testCase "accepts 0 3" $ assertRight (mkScale 0 3)
      , testCase "accepts equal bounds" $ assertRight (mkScale 2 2)
      , testCase "rejects negative min" $ assertLeftContains ">= 0" (mkScale (-1) 3)
      , testCase "rejects negative max" $ assertLeftContains ">= 0" (mkScale 0 (-1))
      , testCase "rejects max < min" $ assertLeftContains ">=" (mkScale 3 1)
      ]
  , testGroup
      "mkDomain"
      [ testCase "accepts hostname" $ assertRight (mkDomain "hello.example.com")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkDomain "")
      , testCase "rejects space" $ assertLeftContains "space" (mkDomain "my domain.com")
      , testCase "rejects uri scheme" $ assertLeftContains "scheme" (mkDomain "https://foo.com")
      ]
  , testGroup
      "EnvVar sum type"
      [ testCase "EnvLiteral constructs" $ EnvLiteral "info" @?= EnvLiteral "info"
      , testCase "EnvSecretRef constructs" $
          case mkSecretName "db-url" of
            Right sn -> EnvSecretRef sn @?= EnvSecretRef sn
            Left e -> assertFailure ("mkSecretName failed: " <> Text.unpack e)
      ]
  ]

goldenTests :: [TestTree]
goldenTests =
  [ goldenVsString
      "renderService hello"
      "test/golden/hello.service.yaml"
      (pure (fromStrict (renderService helloDep "20260602-120000")))
  , goldenVsString
      "renderDomainMapping hello"
      "test/golden/hello.domainmapping.yaml"
      ( case renderDomainMapping helloDep of
          Just bs -> pure (fromStrict bs)
          Nothing -> fail "renderDomainMapping returned Nothing for hello (expected Just)"
      )
  , -- EP-23 M3: a {Build}-only variable is excluded from the inline env: of the
    -- running container, while a Runtime variable and the envFrom references to
    -- the managed store remain.
    goldenVsString
      "renderService build-only exclusion"
      "test/golden/build-only.service.yaml"
      (pure (fromStrict (renderService buildOnlyDep "20260602-120000")))
  ]

-- | The canonical hello deployment, assembled entirely through smart
-- constructors. Mirrors cluster/examples/hello-knative-service/nagare/Config.hs.
helloDep :: Deployment
helloDep =
  Deployment
    { name = unsafe (mkServiceName "hello")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go")
    , build = unsafe defaultBuild
    , domain = Just (unsafe (mkDomain "hello.example.com"))
    , port = unsafe (mkPort 8080)
    , env = Map.fromList [(unsafe (mkEnvName "TARGET"), runtimeScoped (EnvLiteral "Nagare"))]
    , resources =
        Just
          Resources
            { cpu = Just (unsafe (mkQuantity "250m"))
            , memory = Just (unsafe (mkQuantity "128Mi"))
            }
    , scale = Just (unsafe (mkScale 0 3))
    }

-- | 'helloDep' with a Runtime variable and a Build-only variable, used to prove
-- the M3 scope filter excludes the Build-only entry from the inline @env:@.
buildOnlyDep :: Deployment
buildOnlyDep =
  helloDep
    { env =
        Map.fromList
          [ (unsafe (mkEnvName "API_BASE"), runtimeScoped (EnvLiteral "https://api.example.com"))
          , (unsafe (mkEnvName "BUILD_TOKEN"), unsafe (scopedEnv (Set.singleton Build) (EnvLiteral "abc123")))
          ]
    }

-- ---------------------------------------------------------------------------
-- EP-23: scoped env — the scope set survives the JSON emit -> decode round-trip

scopedEnvTests :: [TestTree]
scopedEnvTests =
  [ testCase "multi-scope env survives emit -> decode round-trip" $ do
      let bothScopes = unsafe (scopedEnv (Set.fromList [Build, Runtime]) (EnvLiteral "x"))
          dep =
            helloDep
              { env = Map.fromList [(unsafe (mkEnvName "API_BASE"), bothScopes)]
              }
      decodeDeployment (toStrict (encodeDeployment dep)) @?= Right dep
  , testCase "default runtimeScoped env round-trips" $
      decodeDeployment (toStrict (encodeDeployment helloDep)) @?= Right helloDep
  ]

-- ---------------------------------------------------------------------------
-- EP-19: BuildSpec model — emit/decode round-trips, helpers, renderer, failures

-- | 'helloDep' with its build mode swapped for the given 'BuildSpec'.
depWithBuild :: BuildSpec -> Deployment
depWithBuild b = helloDep {build = b}

prebuiltSpec :: BuildSpec
prebuiltSpec = PrebuiltImage (unsafe (mkTag "v1.2.3"))

dockerfileSpec :: BuildSpec
dockerfileSpec =
  DockerfileBuild
    { dockerfile = unsafe (mkFilePathText "docker/Dockerfile.prod")
    , context = unsafe (mkFilePathText "app")
    , buildArgs = Map.fromList [("MODE", "release"), ("VERSION", "1.0")]
    }

nixpacksSpec :: BuildSpec
nixpacksSpec =
  NixpacksBuild
    { context = unsafe (mkFilePathText ".")
    , buildArgs = Map.fromList [("NIXPACKS_NODE_VERSION", "20")]
    }

prebuiltDep, dockerfileDep, nixpacksDep :: Deployment
prebuiltDep = depWithBuild prebuiltSpec
dockerfileDep = depWithBuild dockerfileSpec
nixpacksDep = depWithBuild nixpacksSpec

buildSpecTests :: [TestTree]
buildSpecTests =
  [ testGroup
      "mkTag"
      [ testCase "accepts v1.2.3" $ assertRight (mkTag "v1.2.3")
      , testCase "accepts 20260609-000000" $ assertRight (mkTag "20260609-000000")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkTag "")
      , testCase "rejects leading hyphen" $ assertLeftContains "'-'" (mkTag "-bad")
      , testCase "rejects leading dot" $ assertLeftContains "'.'" (mkTag ".bad")
      , testCase "rejects whitespace" $ assertLeftContains "whitespace" (mkTag "v1 2")
      , testCase "rejects colon (digest/tag separator)" $
          assertLeftContains "invalid" (mkTag "v1:2")
      ]
  , testGroup
      "resolveImageTag / requiresBuild"
      [ testCase "prebuilt resolves to its own tag" $
          resolveImageTag prebuiltSpec "deploytag" @?= "v1.2.3"
      , testCase "dockerfile build resolves to deploy tag" $
          resolveImageTag dockerfileSpec "deploytag" @?= "deploytag"
      , testCase "nixpacks build resolves to deploy tag" $
          resolveImageTag nixpacksSpec "deploytag" @?= "deploytag"
      , testCase "prebuilt does not require build" $ requiresBuild prebuiltSpec @?= False
      , testCase "dockerfile requires build" $ requiresBuild dockerfileSpec @?= True
      , testCase "nixpacks requires build" $ requiresBuild nixpacksSpec @?= True
      ]
  , testGroup
      "emit -> decode round-trip"
      [ testCase "prebuilt image round-trips" $ assertRoundTrips prebuiltDep
      , testCase "dockerfile build round-trips" $ assertRoundTrips dockerfileDep
      , testCase "nixpacks build round-trips" $ assertRoundTrips nixpacksDep
      , testCase "default (Dockerfile) build round-trips" $ assertRoundTrips helloDep
      ]
  , testGroup
      "renderer respects prebuilt tag"
      [ testCase "prebuilt renders with its own tag, not the deploy tag" $ do
          let yaml = TE.decodeUtf8 (renderService prebuiltDep "20260609-000000")
          assertBool
            ("expected ':v1.2.3' in rendered YAML, got:\n" <> Text.unpack yaml)
            ("helloworld-go:v1.2.3" `Text.isInfixOf` yaml)
          assertBool
            "deploy tag must not appear for a prebuilt image"
            (not ("20260609-000000" `Text.isInfixOf` yaml))
      , testCase "dockerfile build renders with the deploy tag" $ do
          let yaml = TE.decodeUtf8 (renderService dockerfileDep "20260609-000000")
          assertBool
            ("expected ':20260609-000000' in rendered YAML, got:\n" <> Text.unpack yaml)
            ("helloworld-go:20260609-000000" `Text.isInfixOf` yaml)
      ]
  , testGroup
      "decode failure cases"
      [ testCase "unknown build.kind reports MarshalError build.kind" $
          case decodeDeployment (jsonWithBuild "{\"kind\":\"Bogus\"}") of
            Left (MarshalError "build.kind" msg) -> assertContains "unknown build kind" msg
            other -> assertFailure ("expected MarshalError build.kind, got: " <> show other)
      , testCase "PrebuiltImage missing tag reports MarshalError build" $
          case decodeDeployment (jsonWithBuild "{\"kind\":\"PrebuiltImage\"}") of
            Left (MarshalError "build" msg) -> assertContains "tag" msg
            other -> assertFailure ("expected MarshalError build, got: " <> show other)
      , testCase "invalid prebuilt tag reports MarshalError build.tag" $
          case decodeDeployment (jsonWithBuild "{\"kind\":\"PrebuiltImage\",\"tag\":\"-bad\"}") of
            Left (MarshalError "build.tag" _) -> pure ()
            other -> assertFailure ("expected MarshalError build.tag, got: " <> show other)
      , testCase "absolute context reports MarshalError build.context" $
          case decodeDeployment
            (jsonWithBuild "{\"kind\":\"NixpacksBuild\",\"context\":\"/abs\"}") of
            Left (MarshalError "build.context" msg) -> assertContains "absolute" msg
            other -> assertFailure ("expected MarshalError build.context, got: " <> show other)
      ]
  ]
  where
    assertRoundTrips d =
      decodeDeployment (toStrict (encodeDeployment d)) @?= Right d
    -- A minimal valid Deployment JSON whose "build" object is the given literal.
    jsonWithBuild buildObj =
      TE.encodeUtf8 $
        "{\"name\":\"hello\",\"namespace\":\"personal\""
          <> ",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[]"
          <> ",\"build\":"
          <> buildObj
          <> "}"
    assertContains needle haystack
      | needle `Text.isInfixOf` haystack = pure ()
      | otherwise = assertFailure ("expected " <> show needle <> " in: " <> Text.unpack haystack)

-- | Unwrap a smart-constructor result in test fixtures (the inputs are all
-- known-valid). Errors loudly if a fixture is mistyped.
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
