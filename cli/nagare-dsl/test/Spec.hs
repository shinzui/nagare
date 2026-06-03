module Main (main) where

import Data.ByteString.Lazy (fromStrict)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Render (renderDomainMapping, renderService)
import Nagare.Dsl.Types
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain $
    testGroup
      "nagare-dsl"
      [ testGroup "Nagare.Dsl.Types" unitTests
      , testGroup "Nagare.Dsl.Render" goldenTests
      ]

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
  ]

-- | The canonical hello deployment, assembled entirely through smart
-- constructors. Mirrors cluster/examples/hello-knative-service/nagare.yaml.
helloDep :: Deployment
helloDep =
  Deployment
    { name = unsafe (mkServiceName "hello")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go")
    , domain = Just (unsafe (mkDomain "hello.example.com"))
    , port = unsafe (mkPort 8080)
    , env = Map.fromList [(unsafe (mkEnvName "TARGET"), EnvLiteral "Nagare")]
    , resources =
        Just
          Resources
            { cpu = Just (unsafe (mkQuantity "250m"))
            , memory = Just (unsafe (mkQuantity "128Mi"))
            }
    , scale = Just (unsafe (mkScale 0 3))
    }

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
