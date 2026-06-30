module Main (main) where

import ApplicationSpec (applicationTests)
import CdnSpec (cdnTests)
import Control.Lens ((&), (.~))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import LoadSpec (loadTests)
import Nagare.Dsl.Access
import Nagare.Dsl.Broker
import Nagare.Dsl.Broker.Render
  ( renderBrokerPvc
  , renderBrokerService
  , renderBrokerStatefulSet
  )
import Nagare.Dsl.Build
import Nagare.Dsl.Config (encodeBroker, encodeDatabase, encodeDeployment, encodeTask)
import Nagare.Dsl.Database
import Nagare.Dsl.Database.Render
  ( renderDatabaseConfigMap
  , renderDatabasePvc
  , renderDatabaseService
  , renderStatefulSet
  )
import Nagare.Dsl.Image (imageRefFromName, mkImageName)
import Nagare.Dsl.Load (LoadError (..), decodeBroker, decodeDatabase, decodeDeployment, decodeTask, loadBroker, loadDeployment)
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (attachVolume, development, production, secretEnv, webService)
import Nagare.Dsl.Render (renderDomainMappings, renderService, renderVolumeClaims)
import Nagare.Dsl.Task
import Nagare.Dsl.Task.Render (renderTask)
import Nagare.Dsl.Types
import ServerSpec (serverTests)
import StaticSpec (staticTests)
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (Gen, Property, choose, elements, forAll, testProperty)
import WorkerSpec (workerTests)

main :: IO ()
main =
  defaultMain $
    testGroup
      "nagare-dsl"
      [ testGroup "Nagare.Dsl.Types" unitTests
      , testGroup "Nagare.Dsl.Render" goldenTests
      , testGroup "Nagare.Dsl volumes (EP-34)" volumeTests
      , testGroup "Nagare.Dsl.Types scoped env" scopedEnvTests
      , testGroup "Nagare.Dsl extended model (EP-29)" extendedModelTests
      , testGroup "Nagare.Dsl.Build" buildSpecTests
      , testGroup "Nagare.Dsl.Load" loadGoldenTests
      , testGroup "Nagare.Dsl.Access" accessTests
      , testGroup "Nagare.Dsl.Broker (EP-76)" brokerTests
      , testGroup "Nagare.Dsl.Database (EP-44)" databaseTests
      , testGroup "Nagare.Dsl.Task (EP-50)" taskTests
      , testGroup "Nagare.Dsl Deployment tasks (EP-52)" deploymentTaskTests
      , testGroup "Nagare.Dsl.Image (EP-62)" imageDerivationTests
      , loadTests
      , testGroup "Nagare.Dsl.Presets" (presetsGoldenTests <> presetsPropertyTests)
      , staticTests
      , serverTests
      , cdnTests
      , workerTests
      , applicationTests
      ]

-- | EP-62 M3: the registry-prefix derivation that turns a short image NAME plus
-- a deploy-time prefix into a fully-qualified 'ImageRef'. The prefix is supplied
-- by nagarectl from the target profile; the DSL stays environment-agnostic.
imageDerivationTests :: [TestTree]
imageDerivationTests =
  [ testCase "imageRefFromName joins <prefix>/<name>" $
      fmap imageRefText (imageRefFromName "us-west1-docker.pkg.dev/tan-nb-exp/nagare" "notes")
        @?= Right "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
  , testCase "imageRefFromName tolerates a trailing slash on the prefix" $
      fmap imageRefText (imageRefFromName "host/proj/repo/" "app")
        @?= Right "host/proj/repo/app"
  , testCase "imageRefFromName derives a different prefix purely from inputs" $
      fmap imageRefText (imageRefFromName "europe-west1-docker.pkg.dev/acme-prod/nagare" "notes")
        @?= Right "europe-west1-docker.pkg.dev/acme-prod/nagare/notes"
  , testCase "mkImageName accepts a bare name (deferring the prefix)" $
      fmap imageRefText (mkImageName "notes") @?= Right "notes"
  , testCase "mkImageName rejects a tagged name (no ':' allowed)" $
      assertBool "Left on a tag" (isLeft (mkImageName "notes:tag"))
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
      , -- EP-83: a ported registry host (k3d local registry) has a colon BEFORE the
        -- first '/', which is the port, not a tag — it must be accepted.
        testCase "accepts ported registry host" $
          assertRight (mkImageRef "k3d-registry.localhost:5000/tan-nb-exp/nagare/dockerfile-app")
      , testCase "rejects tag even with a ported registry host" $
          assertLeftContains "tag" (mkImageRef "k3d-registry.localhost:5000/foo/bar:latest")
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
      "mkHealthCheck / httpHealthCheck"
      [ testCase "httpHealthCheck accepts a slash path with defaults" $
          case httpHealthCheck "/healthz" of
            Right hc -> do
              path hc @?= "/healthz"
              period hc @?= 10
              timeout hc @?= 1
              failureThreshold hc @?= 3
              expectedStatus hc @?= 200
              asLiveness hc @?= False
              asStartup hc @?= False
            Left e -> assertFailure ("expected Right, got Left: " <> Text.unpack e)
      , testCase "rejects path without leading slash" $
          assertLeftContains "/" (httpHealthCheck "healthz")
      , testCase "rejects empty path" $
          assertLeftContains "empty" (httpHealthCheck "")
      , testCase "rejects period of 0" $
          assertLeftContains "period" (mkHealthCheck (unsafe (httpHealthCheck "/h")) {period = 0})
      , testCase "rejects timeout of 0" $
          assertLeftContains "timeout" (mkHealthCheck (unsafe (httpHealthCheck "/h")) {timeout = 0})
      , testCase "rejects out-of-range expectedStatus" $
          assertLeftContains "expectedStatus" (mkHealthCheck (unsafe (httpHealthCheck "/h")) {expectedStatus = 99})
      ]
  , testGroup
      "mkDomains / canonicalDomain"
      [ testCase "empty list is allowed" $ mkDomains [] @?= Right []
      , testCase "single canonical domain accepted" $
          assertRight (mkDomains [("a.example.com", True)])
      , testCase "rejects non-empty list with no canonical" $
          assertLeftContains "exactly one" (mkDomains [("a.example.com", False)])
      , testCase "rejects two canonical domains" $
          assertLeftContains "exactly one" (mkDomains [("a.example.com", True), ("b.example.com", True)])
      , testCase "rejects an invalid hostname" $
          assertLeftContains "space" (mkDomains [("bad host.com", True)])
      , testCase "canonicalDomain returns the canonical entry" $
          fmap domainText (canonicalDomain (unsafe (mkDomains [("a.example.com", False), ("b.example.com", True)])))
            @?= Just "b.example.com"
      , testCase "canonicalDomain of empty list is Nothing" $
          canonicalDomain [] @?= Nothing
      ]
  , testGroup
      "EnvVar sum type"
      [ testCase "EnvLiteral constructs" $ EnvLiteral "info" @?= EnvLiteral "info"
      , testCase "EnvSecretRef constructs" $
          case mkSecretName "db-url" of
            Right sn -> EnvSecretRef sn @?= EnvSecretRef sn
            Left e -> assertFailure ("mkSecretName failed: " <> Text.unpack e)
      ]
  , testGroup
      "mkVolumeName"
      [ testCase "accepts data" $ assertRight (mkVolumeName "data")
      , testCase "accepts hyphenated" $ assertRight (mkVolumeName "uploads-1")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkVolumeName "")
      , testCase "rejects uppercase" $ assertLeftContains "invalid" (mkVolumeName "Data")
      , testCase "rejects leading hyphen" $ assertLeftContains "hyphen" (mkVolumeName "-x")
      , testCase "rejects 64 chars" $ assertLeftContains "long" (mkVolumeName (Text.replicate 64 "a"))
      ]
  , testGroup
      "mkMountPath"
      [ testCase "accepts /data" $ assertRight (mkMountPath "/data")
      , testCase "accepts nested" $ assertRight (mkMountPath "/var/lib/app")
      , testCase "rejects relative" $ assertLeftContains "absolute" (mkMountPath "data")
      , testCase "rejects parent segment" $ assertLeftContains ".." (mkMountPath "/a/../b")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkMountPath "")
      ]
  ]

goldenTests :: [TestTree]
goldenTests =
  [ goldenVsString
      "renderService hello"
      "test/golden/hello.service.yaml"
      (pure (fromStrict (renderService helloDep "20260602-120000")))
  , goldenVsString
      "renderDomainMappings hello"
      "test/golden/hello.domainmapping.yaml"
      ( case renderDomainMappings helloDep of
          [bs] -> pure (fromStrict bs)
          other ->
            fail
              ( "renderDomainMappings hello expected exactly one document, got "
                  <> show (length other)
              )
      )
  , -- EP-23 M3: a {Build}-only variable is excluded from the inline env: of the
    -- running container, while a Runtime variable and the envFrom references to
    -- the managed store remain.
    goldenVsString
      "renderService build-only exclusion"
      "test/golden/build-only.service.yaml"
      (pure (fromStrict (renderService buildOnlyDep "20260602-120000")))
  , -- EP-29: a config that declares a health check (liveness+startup), resource
    -- limits, and two domains renders probe/limits/label YAML and one mapping
    -- per domain. See 'richDep'.
    goldenVsString
      "renderService rich (health check + limits + domains)"
      "test/golden/rich.service.yaml"
      (pure (fromStrict (renderService richDep "20260602-120000")))
  , goldenVsString
      "renderDomainMappings rich (one document per domain)"
      "test/golden/rich.domainmapping.yaml"
      (pure (fromStrict (BS.intercalate "---\n" (renderDomainMappings richDep))))
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
    , domains = unsafe (mkDomains [("hello.example.com", True)])
    , port = unsafe (mkPort 8080)
    , env = Map.fromList [(unsafe (mkEnvName "TARGET"), runtimeScoped (EnvLiteral "Nagare"))]
    , resources =
        Just
          Resources
            { cpu = Just (unsafe (mkQuantity "250m"))
            , memory = Just (unsafe (mkQuantity "128Mi"))
            , cpuLimit = Nothing
            , memoryLimit = Nothing
            }
    , scale = Just (unsafe (mkScale 0 3))
    , healthCheck = Nothing
    , volumes = []
    , databases = []
    , brokers = []
    , access = Nothing
    , tasks = []
    , cdn = Nothing
    }

-- ---------------------------------------------------------------------------
-- EP-76: typed brokers (model, JSON round-trip, renderer goldens).

redpandaBroker :: Broker
redpandaBroker =
  Broker
    { name = unsafe (mkBrokerName "events")
    , provider = Redpanda
    , version = unsafe (mkBrokerVersion Redpanda "v26.1.8")
    , namespace = unsafe (mkNamespace "personal")
    , storageSize = unsafe (mkQuantity "5Gi")
    , sizing = defaultBrokerSizing
    , topics =
        [ unsafe
            ( mkBrokerTopic
                (unsafe (mkTopicName "jobs"))
                1
                1
                (Just 86400000)
            )
        ]
    }

largeRedpandaBroker :: Broker
largeRedpandaBroker =
  Broker
    { name = unsafe (mkBrokerName "events")
    , provider = Redpanda
    , version = unsafe (mkBrokerVersion Redpanda "v26.1.8")
    , namespace = unsafe (mkNamespace "personal")
    , storageSize = unsafe (mkQuantity "20Gi")
    , sizing =
        unsafe
          ( mkBrokerSizing
              (Just (unsafe (mkQuantity "20Gi")))
              ( Just
                  Resources
                    { cpu = Just (unsafe (mkQuantity "1"))
                    , memory = Just (unsafe (mkQuantity "2Gi"))
                    , cpuLimit = Just (unsafe (mkQuantity "2"))
                    , memoryLimit = Just (unsafe (mkQuantity "3Gi"))
                    }
              )
              (Just 2)
              (Just (unsafe (mkQuantity "2G")))
          )
    , topics =
        [ unsafe
            ( mkBrokerTopic
                (unsafe (mkTopicName "jobs"))
                1
                1
                (Just 86400000)
            )
        ]
    }

brokerTests :: [TestTree]
brokerTests =
  [ testGroup
      "constructors"
      [ testCase "mkBrokerName accepts events" $ assertRight (mkBrokerName "events")
      , testCase "mkBrokerName rejects uppercase" $ assertLeftContains "invalid" (mkBrokerName "Events")
      , testCase "mkTopicName accepts dots and hyphens" $ assertRight (mkTopicName "jobs.created")
      , testCase "mkTopicName rejects leading dot" $ assertLeftContains "dot" (mkTopicName ".hidden")
      , testCase "mkTopicName rejects slash" $ assertLeftContains "/" (mkTopicName "bad/topic")
      , testCase "mkBrokerVersion rejects latest" $
          assertLeftContains "pinned" (mkBrokerVersion Redpanda "latest")
      , testCase "mkBrokerSizing rejects non-positive smp" $
          assertLeftContains ">= 1" (mkBrokerSizing Nothing Nothing (Just 0) Nothing)
      , testCase "mkBrokerTopic rejects zero partitions" $
          assertLeftContains
            "partitions"
            (mkBrokerTopic (unsafe (mkTopicName "jobs")) 0 1 Nothing)
      ]
  , testGroup
      "provider facts"
      [ testCase "provider token round-trips through parseBrokerProvider" $
          mapM (\p -> parseBrokerProvider (brokerProviderToken p)) [minBound .. maxBound]
            @?= Just [Redpanda, Tansu]
      , testCase "redpanda exposes kafka/admin/metrics facts" $ do
          brokerProviderKafkaPort Redpanda @?= 9092
          brokerProviderAdminPort Redpanda @?= Just 9644
          brokerProviderMetricsPath Redpanda @?= Just "/public_metrics"
      ]
  , testGroup
      "JSON round-trip and kind discrimination"
      [ testCase "broker survives emit -> decode round-trip" $
          decodeBroker (toStrict (encodeBroker redpandaBroker)) @?= Right redpandaBroker
      , testCase "loadBroker redpanda fixture returns Right redpandaBroker" $ do
          result <- loadBroker "test/fixtures/broker/redpanda/nagare/Config.hs"
          case result of
            Left err -> assertFailure ("loadBroker returned Left: " <> show err)
            Right broker -> broker @?= redpandaBroker
      , testCase "large broker sizing survives emit -> decode round-trip" $
          decodeBroker (toStrict (encodeBroker largeRedpandaBroker)) @?= Right largeRedpandaBroker
      , testCase "deployment broker bindings survive emit -> decode round-trip" $
          let boundDep = helloDep & #brokers .~ [eventsBinding]
           in decodeDeployment (toStrict (encodeDeployment boundDep)) @?= Right boundDep
      , testCase "decoding a Broker as a Deployment is UnexpectedKind" $
          case decodeDeployment (toStrict (encodeBroker redpandaBroker)) of
            Left (UnexpectedKind "Deployment" "Broker") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "decoding a Deployment as a Broker is UnexpectedKind" $
          case decodeBroker (toStrict (encodeDeployment helloDep)) of
            Left (UnexpectedKind "Broker" "<none>") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "unknown provider rejected as MarshalError provider" $
          case decodeBroker
            "{\"kind\":\"Broker\",\"name\":\"events\",\"provider\":\"kafka\",\"version\":\"1\",\"namespace\":\"personal\",\"storageSize\":\"1Gi\"}" of
            Left (MarshalError "provider" _) -> pure ()
            other -> assertFailure ("expected MarshalError provider, got: " <> show other)
      ]
  , testGroup
      "renderer goldens"
      [ goldenVsString "renderBrokerStatefulSet redpanda" "test/golden/broker-redpanda.statefulset.yaml" $
          pure (fromStrict (renderBrokerStatefulSet redpandaBroker))
      , goldenVsString "renderBrokerService redpanda" "test/golden/broker-redpanda.service.yaml" $
          pure (fromStrict (renderBrokerService redpandaBroker))
      , goldenVsString "renderBrokerPvc redpanda" "test/golden/broker-redpanda.pvc.yaml" $
          pure (fromStrict (renderBrokerPvc redpandaBroker))
      , goldenVsString "renderBrokerStatefulSet large redpanda" "test/golden/broker-redpanda-large.statefulset.yaml" $
          pure (fromStrict (renderBrokerStatefulSet largeRedpandaBroker))
      ]
  ]

eventsBinding :: BrokerBinding
eventsBinding =
  BrokerBinding
    { name = unsafe (mkBrokerName "events")
    , topics = [unsafe (mkTopicName "jobs")]
    }

-- ---------------------------------------------------------------------------
-- EP-81 M2: identity-aware access policy (model and JSON round-trip only).

accessTests :: [TestTree]
accessTests =
  [ testGroup
      "constructors"
      [ testCase "requireLogin uses the default access permission and no custom audience" $ do
          audience requireLogin @?= Nothing
          accessPermissionText (permission requireLogin) @?= "access"
      , testCase "mkAudience accepts a simple audience" $
          fmap audienceText (mkAudience "nagare") @?= Right "nagare"
      , testCase "mkAudience rejects empty" $
          assertLeftContains "empty" (mkAudience "")
      , testCase "mkAudience rejects whitespace" $
          assertLeftContains "whitespace" (mkAudience "nagare apps")
      , testCase "mkAudience rejects URI schemes" $
          assertLeftContains "scheme" (mkAudience "https://nagare")
      , testCase "mkAccessPermission accepts lowercase identifier tokens" $
          fmap accessPermissionText (mkAccessPermission "site_access") @?= Right "site_access"
      , testCase "mkAccessPermission rejects uppercase" $
          assertLeftContains "invalid" (mkAccessPermission "Access")
      ]
  , testGroup
      "deployment contract"
      [ testCase "deployment access policy survives emit -> decode round-trip" $
          let protected = helloDep & #access .~ Just requireLogin
           in decodeDeployment (toStrict (encodeDeployment protected)) @?= Right protected
      , testCase "deployment access is invisible to the Knative renderer" $
          renderService (helloDep & #access .~ Just requireLogin) "20260602-120000"
            @?= renderService helloDep "20260602-120000"
      , testCase "invalid decoded access permission is a precise MarshalError" $
          case decodeDeployment
            "{\"name\":\"hello\",\"namespace\":\"personal\",\"image\":\"gcr.io/x/y\",\"build\":{\"kind\":\"PrebuiltImage\",\"tag\":\"v1\"},\"domains\":[],\"port\":8080,\"env\":[],\"brokers\":[],\"access\":{\"permission\":\"Access\"}}" of
            Left (MarshalError "access.permission" _) -> pure ()
            other -> assertFailure ("expected MarshalError access.permission, got: " <> show other)
      ]
  ]

-- ---------------------------------------------------------------------------
-- EP-44: managed databases (model, JSON round-trip, renderer goldens).

pgDb :: Database
pgDb =
  Database
    { dbName = unsafe (mkDatabaseName "pg-main")
    , engine = Postgres
    , version = unsafe (mkEngineVersion Postgres "18")
    , namespace = unsafe (mkNamespace "personal")
    , size = unsafe (mkQuantity "10Gi")
    , resources = Nothing
    , retention = Retain
    }

redisDb :: Database
redisDb =
  Database
    { dbName = unsafe (mkDatabaseName "redis-cache")
    , engine = Redis
    , version = unsafe (mkEngineVersion Redis "8")
    , namespace = unsafe (mkNamespace "personal")
    , size = unsafe (mkQuantity "2Gi")
    , resources = Nothing
    , retention = Retain
    }

clickhouseDb :: Database
clickhouseDb =
  Database
    { dbName = unsafe (mkDatabaseName "analytics")
    , engine = ClickHouse
    , version = unsafe (mkEngineVersion ClickHouse "25.8")
    , namespace = unsafe (mkNamespace "personal")
    , size = unsafe (mkQuantity "5Gi")
    , resources = Nothing
    , retention = Retain
    }

databaseTests :: [TestTree]
databaseTests =
  [ testGroup
      "mkDatabaseName"
      [ testCase "accepts pg-main" $ assertRight (mkDatabaseName "pg-main")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkDatabaseName "")
      , testCase "rejects uppercase" $ assertLeftContains "invalid" (mkDatabaseName "PG")
      , testCase "rejects leading hyphen" $ assertLeftContains "hyphen" (mkDatabaseName "-x")
      ]
  , testGroup
      "mkEngineVersion"
      [ testCase "accepts 18 for Postgres" $ assertRight (mkEngineVersion Postgres "18")
      , testCase "accepts 25.8 for ClickHouse" $ assertRight (mkEngineVersion ClickHouse "25.8")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkEngineVersion Postgres "")
      , testCase "rejects latest" $ assertLeftContains "pinned" (mkEngineVersion Redis "latest")
      , testCase "rejects a tag with a colon" $
          assertLeftContains "':'" (mkEngineVersion Postgres "16:beta")
      ]
  , testGroup
      "engine facts"
      [ testCase "engineToken round-trips through parseEngine" $
          mapM (\e -> parseEngine (engineToken e)) [minBound .. maxBound]
            @?= Just [Postgres, Redis, ClickHouse]
      , testCase "parseEngine rejects an unknown token" $
          parseEngine "mysql" @?= Nothing
      , testCase "ClickHouse exposes the native and HTTP ports" $
          enginePorts ClickHouse @?= [("native", 9000), ("http", 8123)]
      ]
  , testGroup
      "JSON round-trip and kind discrimination"
      [ testCase "database survives emit -> decode round-trip" $
          decodeDatabase (toStrict (encodeDatabase pgDb)) @?= Right pgDb
      , testCase "redis database round-trips" $
          decodeDatabase (toStrict (encodeDatabase redisDb)) @?= Right redisDb
      , testCase "clickhouse database round-trips" $
          decodeDatabase (toStrict (encodeDatabase clickhouseDb)) @?= Right clickhouseDb
      , testCase "decoding a Database as a Deployment is UnexpectedKind" $
          case decodeDeployment (toStrict (encodeDatabase pgDb)) of
            Left (UnexpectedKind "Deployment" "Database") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "decoding a Deployment as a Database is UnexpectedKind" $
          case decodeDatabase (toStrict (encodeDeployment helloDep)) of
            Left (UnexpectedKind "Database" "<none>") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "unknown engine rejected as MarshalError engine" $
          case decodeDatabase
            "{\"kind\":\"Database\",\"name\":\"x\",\"engine\":\"mysql\",\"version\":\"8\",\"namespace\":\"personal\",\"size\":\"1Gi\"}" of
            Left (MarshalError "engine" _) -> pure ()
            other -> assertFailure ("expected MarshalError engine, got: " <> show other)
      , testCase "deployment with a database reference round-trips (IP5)" $ do
          let dep = helloDep {databases = [unsafe (mkDatabaseName "pg-main")]}
          decodeDeployment (toStrict (encodeDeployment dep)) @?= Right dep
      ]
  , testGroup
      "renderer goldens"
      [ goldenVsString "renderStatefulSet postgres" "test/golden/db-postgres.statefulset.yaml" $
          pure (fromStrict (renderStatefulSet pgDb))
      , goldenVsString "renderDatabaseService postgres" "test/golden/db-postgres.service.yaml" $
          pure (fromStrict (renderDatabaseService pgDb))
      , goldenVsString "renderDatabasePvc postgres" "test/golden/db-postgres.pvc.yaml" $
          pure (fromStrict (renderDatabasePvc pgDb))
      , goldenVsString "renderStatefulSet redis" "test/golden/db-redis.statefulset.yaml" $
          pure (fromStrict (renderStatefulSet redisDb))
      , goldenVsString "renderDatabaseService redis" "test/golden/db-redis.service.yaml" $
          pure (fromStrict (renderDatabaseService redisDb))
      , goldenVsString "renderDatabasePvc redis" "test/golden/db-redis.pvc.yaml" $
          pure (fromStrict (renderDatabasePvc redisDb))
      , goldenVsString "renderStatefulSet clickhouse" "test/golden/db-clickhouse.statefulset.yaml" $
          pure (fromStrict (renderStatefulSet clickhouseDb))
      , goldenVsString "renderDatabaseService clickhouse" "test/golden/db-clickhouse.service.yaml" $
          pure (fromStrict (renderDatabaseService clickhouseDb))
      , goldenVsString "renderDatabasePvc clickhouse" "test/golden/db-clickhouse.pvc.yaml" $
          pure (fromStrict (renderDatabasePvc clickhouseDb))
      , goldenVsString "renderDatabaseConfigMap clickhouse" "test/golden/db-clickhouse.configmap.yaml" $
          pure (fromStrict (renderDatabaseConfigMap clickhouseDb))
      ]
  ]

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
-- EP-34: typed volumes — attachVolume, JSON round-trip, load-time uniqueness,
-- and the PVC / volumeMount / volume render goldens (IP1/IP2/IP3).

-- | 'helloDep' with one durable volume @data@ (1Gi at @/data@), built through
-- the 'attachVolume' overlay. Kept separate from 'helloDep' so the stateless
-- goldens are unaffected.
volumeDep :: Deployment
volumeDep = unsafe (attachVolume "data" "1Gi" "/data" helloDep)

volumeTests :: [TestTree]
volumeTests =
  [ testCase "attachVolume appends exactly one volume" $
      length (volumes volumeDep) @?= 1
  , testCase "deployment with a volume survives emit -> decode round-trip" $
      decodeDeployment (toStrict (encodeDeployment volumeDep)) @?= Right volumeDep
  , testCase "duplicate volume name rejected as MarshalError volumes" $
      case decodeDeployment
        (jsonWithVolumes "[{\"name\":\"d\",\"size\":\"1Gi\",\"mountPath\":\"/a\"},{\"name\":\"d\",\"size\":\"1Gi\",\"mountPath\":\"/b\"}]") of
        Left (MarshalError "volumes" msg) -> assertContains "duplicate volume name" msg
        other -> assertFailure ("expected MarshalError volumes, got: " <> show other)
  , testCase "duplicate mount path rejected as MarshalError volumes" $
      case decodeDeployment
        (jsonWithVolumes "[{\"name\":\"a\",\"size\":\"1Gi\",\"mountPath\":\"/x\"},{\"name\":\"b\",\"size\":\"1Gi\",\"mountPath\":\"/x\"}]") of
        Left (MarshalError "volumes" msg) -> assertContains "duplicate mount path" msg
        other -> assertFailure ("expected MarshalError volumes, got: " <> show other)
  , testCase "relative mount path rejected as MarshalError volumes.mountPath" $
      case decodeDeployment
        (jsonWithVolumes "[{\"name\":\"a\",\"size\":\"1Gi\",\"mountPath\":\"data\"}]") of
        Left (MarshalError "volumes.mountPath" msg) -> assertContains "absolute" msg
        other -> assertFailure ("expected MarshalError volumes.mountPath, got: " <> show other)
  , testCase "bad size rejected as MarshalError volumes.size" $
      case decodeDeployment
        (jsonWithVolumes "[{\"name\":\"a\",\"size\":\"1Gigs\",\"mountPath\":\"/a\"}]") of
        Left (MarshalError "volumes.size" _) -> pure ()
        other -> assertFailure ("expected MarshalError volumes.size, got: " <> show other)
  , testCase "unknown retention rejected as MarshalError volumes.retention" $
      case decodeDeployment
        (jsonWithVolumes "[{\"name\":\"a\",\"size\":\"1Gi\",\"mountPath\":\"/a\",\"retention\":\"Forever\"}]") of
        Left (MarshalError "volumes.retention" _) -> pure ()
        other -> assertFailure ("expected MarshalError volumes.retention, got: " <> show other)
  , goldenVsString
      "renderService hello with volume"
      "test/golden/hello-volume.service.yaml"
      (pure (fromStrict (renderService volumeDep "20260602-120000")))
  , goldenVsString
      "renderVolumeClaims hello volume"
      "test/golden/hello-volume.pvc.yaml"
      (pure (fromStrict (BS.intercalate "---\n" (renderVolumeClaims volumeDep))))
  ]
  where
    jsonWithVolumes volsArr =
      TE.encodeUtf8 $
        "{\"name\":\"hello\",\"namespace\":\"personal\""
          <> ",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[]"
          <> ",\"volumes\":"
          <> volsArr
          <> "}"
    assertContains needle haystack
      | needle `Text.isInfixOf` haystack = pure ()
      | otherwise = assertFailure ("expected " <> show needle <> " in: " <> Text.unpack haystack)

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
-- EP-29: extended model — health check, resource limits, multiple domains

-- | 'helloDep' enriched with a liveness/startup health check, resource limits
-- on top of requests, and two custom domains (one canonical). Exercises every
-- new field at once.
richDep :: Deployment
richDep =
  helloDep
    { domains =
        unsafe (mkDomains [("notes.example.com", True), ("www.example.com", False)])
    , resources =
        Just
          Resources
            { cpu = Just (unsafe (mkQuantity "250m"))
            , memory = Just (unsafe (mkQuantity "128Mi"))
            , cpuLimit = Just (unsafe (mkQuantity "500m"))
            , memoryLimit = Just (unsafe (mkQuantity "512Mi"))
            }
    , healthCheck =
        Just
          (unsafe (httpHealthCheck "/healthz")) {asLiveness = True, asStartup = True}
    }

extendedModelTests :: [TestTree]
extendedModelTests =
  [ testCase "rich deployment (health check + limits + two domains) round-trips" $
      decodeDeployment (toStrict (encodeDeployment richDep)) @?= Right richDep
  , testCase "renderService emits the managed-by label" $
      assertInfix "nagare.dev/managed-by: nagarectl" (renderService helloDep "20260602-120000")
  , testCase "renderService emits a resources.limits block when limits are set" $ do
      let yaml = renderService richDep "20260602-120000"
      assertInfix "limits:" yaml
      assertInfix "readinessProbe:" yaml
      assertInfix "livenessProbe:" yaml
      assertInfix "startupProbe:" yaml
      assertInfix "/healthz" yaml
  , testCase "renderDomainMappings emits one document per domain" $
      length (renderDomainMappings richDep) @?= 2
  , testCase "a deployment with no new fields renders no probe or limits YAML" $ do
      let yaml = renderService helloDep "20260602-120000"
      assertBool "no readinessProbe" (not ("readinessProbe" `Text.isInfixOf` TE.decodeUtf8 yaml))
      assertBool "no limits" (not ("limits:" `Text.isInfixOf` TE.decodeUtf8 yaml))
  ]
  where
    assertInfix needle hay =
      assertBool
        ("expected " <> show needle <> " in rendered YAML:\n" <> Text.unpack (TE.decodeUtf8 hay))
        (needle `Text.isInfixOf` TE.decodeUtf8 hay)

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
-- | A standalone scheduled task, assembled through smart constructors. Mirrors
-- test/fixtures/task/standalone/nagare/Config.hs.
standaloneTask :: Task
standaloneTask =
  unsafe $
    mkTask
      Task
        { taskName = unsafe (mkServiceName "cleanup")
        , taskNamespace = unsafe (mkNamespace "personal")
        , taskSchedule = unsafe (mkSchedule "0 3 * * *")
        , taskImage = Just (unsafe (mkImageRef "gcr.io/myproject/notes"))
        , taskApp = Nothing
        , taskCommand = ["python", "manage.py", "cleanup"]
        , taskArgs = []
        , taskEnv =
            Map.fromList
              [(unsafe (mkEnvName "DRY_RUN"), runtimeScoped (EnvLiteral "false"))]
        , taskResources = Nothing
        , taskTimeoutSeconds = Just 600
        , taskConcurrencyPolicy = Forbid
        , taskRestartPolicy = Never
        , taskBackoffLimit = 0
        , taskSuccessfulJobsHistoryLimit = 3
        , taskFailedJobsHistoryLimit = 1
        , taskStartingDeadlineSeconds = Nothing
        }

-- | A task associated with the @notes@ app: it inherits @notes@'s image
-- (taskImage = Nothing) and its runtime env/secret (rendered as envFrom), and
-- carries the nagare.dev/app label.
appTask :: Task
appTask =
  unsafe $
    mkTask
      Task
        { taskName = unsafe (mkServiceName "sync")
        , taskNamespace = unsafe (mkNamespace "personal")
        , taskSchedule = unsafe (mkSchedule "*/15 * * * *")
        , taskImage = Nothing
        , taskApp = Just (unsafe (mkServiceName "notes"))
        , taskCommand = ["python", "manage.py", "sync"]
        , taskArgs = []
        , taskEnv = Map.empty
        , taskResources = Nothing
        , taskTimeoutSeconds = Nothing
        , taskConcurrencyPolicy = Forbid
        , taskRestartPolicy = Never
        , taskBackoffLimit = 2
        , taskSuccessfulJobsHistoryLimit = 3
        , taskFailedJobsHistoryLimit = 1
        , taskStartingDeadlineSeconds = Nothing
        }

taskTests :: [TestTree]
taskTests =
  [ testGroup
      "mkSchedule"
      [ testCase "accepts 0 3 * * *" $ assertRight (mkSchedule "0 3 * * *")
      , testCase "accepts a step */15 * * * *" $ assertRight (mkSchedule "*/15 * * * *")
      , testCase "accepts a list and range 1,15 0-6 * * 1-5" $
          assertRight (mkSchedule "1,15 0-6 * * 1-5")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkSchedule "")
      , testCase "rejects 4 fields" $ assertLeftContains "5" (mkSchedule "0 3 * *")
      , testCase "rejects out-of-range minute" $ assertLeftContains "minute" (mkSchedule "60 3 * * *")
      , testCase "rejects garbage" $ assertLeftContains "minute" (mkSchedule "x 3 * * *")
      ]
  , testGroup
      "mkTask invariants"
      [ testCase "rejects inheriting image with no app" $
          assertLeftContains "inherit" (mkTask standaloneTask {taskImage = Nothing, taskApp = Nothing})
      , testCase "rejects negative backoffLimit" $
          assertLeftContains ">= 0" (mkTask standaloneTask {taskBackoffLimit = -1})
      , testCase "rejects non-positive timeout" $
          assertLeftContains "> 0" (mkTask standaloneTask {taskTimeoutSeconds = Just 0})
      ]
  , testGroup
      "JSON round-trip and kind discrimination"
      [ testCase "standalone task survives emit -> decode round-trip" $
          decodeTask (toStrict (encodeTask standaloneTask)) @?= Right standaloneTask
      , testCase "app-associated task round-trips" $
          decodeTask (toStrict (encodeTask appTask)) @?= Right appTask
      , testCase "decoding a Task as a Deployment is UnexpectedKind" $
          case decodeDeployment (toStrict (encodeTask standaloneTask)) of
            Left (UnexpectedKind "Deployment" "Task") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "decoding a Deployment as a Task is UnexpectedKind" $
          case decodeTask (toStrict (encodeDeployment helloDep)) of
            Left (UnexpectedKind "Task" "<none>") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "a task with its own command and no app decodes" $
          case decodeTask
            "{\"kind\":\"Task\",\"name\":\"x\",\"namespace\":\"personal\",\"schedule\":\"0 3 * * *\",\"image\":\"gcr.io/p/x\",\"command\":[\"echo\"]}" of
            Right _ -> pure ()
            other -> assertFailure ("expected Right (own command, no app), got: " <> show other)
      , testCase "an inheriting task with no app fails to decode (MarshalError task)" $
          case decodeTask
            "{\"kind\":\"Task\",\"name\":\"x\",\"namespace\":\"personal\",\"schedule\":\"0 3 * * *\",\"command\":[\"echo\"]}" of
            Left (MarshalError "task" _) -> pure ()
            other -> assertFailure ("expected MarshalError task, got: " <> show other)
      ]
  , testGroup
      "renderer goldens"
      [ goldenVsString "renderTask standalone" "test/golden/task-standalone.cronjob.yaml" $
          pure (fromStrict (renderTask standaloneTask))
      , goldenVsString "renderTask app-associated" "test/golden/task-app-associated.cronjob.yaml" $
          pure (fromStrict (renderTask appTask))
      ]
  ]

-- | A `notes` deployment that co-locates EP-50's inheriting `sync` task
-- (MasterPlan 10 / EP-52). The task's `taskApp` is `notes`, matching the
-- enclosing app, so it satisfies the deploy-level association invariant.
notesWithTask :: Deployment
notesWithTask = helloDep {name = unsafe (mkServiceName "notes"), tasks = [appTask]}

deploymentTaskTests :: [TestTree]
deploymentTaskTests =
  [ testCase "deployment with a co-located task round-trips" $
      decodeDeployment (toStrict (encodeDeployment notesWithTask)) @?= Right notesWithTask
  , testCase "a co-located task naming a different app fails to load" $
      case decodeDeployment (toStrict (encodeDeployment badAppTaskDep)) of
        Left (MarshalError "tasks" _) -> pure ()
        other -> assertFailure ("expected MarshalError tasks, got: " <> show other)
  , testCase "two co-located tasks with the same name fail to load" $
      case decodeDeployment (toStrict (encodeDeployment dupTaskDep)) of
        Left (MarshalError "tasks" _) -> pure ()
        other -> assertFailure ("expected MarshalError tasks, got: " <> show other)
  ]
  where
    badAppTaskDep =
      helloDep
        { name = unsafe (mkServiceName "notes")
        , tasks = [appTask {taskApp = Just (unsafe (mkServiceName "other"))}]
        }
    dupTaskDep =
      helloDep
        { name = unsafe (mkServiceName "notes")
        , tasks = [appTask, appTask]
        }

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
