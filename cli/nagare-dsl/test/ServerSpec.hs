-- | Tests for the EP-18 server-site model, loader, and renderers.
--
-- Positive path: the @server-site@ fixture loads through 'loadServerSite' and
-- through the dispatching 'loadSite' (as 'SiteServer') to the same 'ServerSite'
-- assembled here, and renders to golden Dockerfile, Knative Service, and
-- DomainMapping artifacts. Negative path: invalid leaves are rejected, and a
-- config of the wrong @kind@ is reported as 'UnexpectedKind'.
module ServerSpec (serverTests) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy (fromStrict)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Cdn.Types
import Nagare.Dsl.Load
import Nagare.Dsl.Server.Render
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types (mkSiteName)
import Nagare.Dsl.Types
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit

serverTests :: TestTree
serverTests =
  testGroup
    "Nagare.Dsl.Server"
    [ testGroup "RuntimeImage" runtimeImageTests
    , testGroup "loadServerSite + render goldens" loadAndGoldenTests
    , testGroup "decodeServerSite failure modes" decodeFailureTests
    , testGroup "volume render parity (EP-34)" volumeParityTests
    ]

ctx :: ServerDeployContext
ctx = ServerDeployContext {imageTag = "20260607-120000", previewName = Nothing}

notesApp :: ServerSite
notesApp =
  ServerSite
    { name = unsafe (mkSiteName "notes-app")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "notes-app")
    , build = tanstackStartBuild
    , runtime = defaultServerRuntime
    , port = defaultPort
    , env =
        Map.fromList
          [ (unsafe (mkEnvName "HOSTNAME"), runtimeScoped (EnvLiteral "0.0.0.0"))
          , (unsafe (mkEnvName "API_BASE"), runtimeScoped (EnvLiteral "https://api.example.com"))
          ]
    , resources =
        Just Resources {cpu = Just (unsafe (mkQuantity "500m")), memory = Just (unsafe (mkQuantity "256Mi")), cpuLimit = Nothing, memoryLimit = Nothing}
    , scale = Just (unsafe (mkScale 1 3))
    , domains = [unsafe (mkDomain "notes-app.example.com")]
    , volumes = []
    , cdn = Just (withDefaultTtl 600 gcpCloudCdn)
    }

loadAndGoldenTests :: [TestTree]
loadAndGoldenTests =
  [ testCase "loadServerSite notes-app returns Right notesApp" $ do
      result <- loadServerSite fixturePath
      case result of
        Left err -> assertFailure ("loadServerSite returned Left: " <> show err)
        Right site -> site @?= notesApp
  , testCase "loadSite notes-app returns Right (SiteServer notesApp)" $ do
      result <- loadSite fixturePath
      case result of
        Right (SiteServer site) -> site @?= notesApp
        other -> assertFailure ("expected SiteServer, got: " <> show other)
  , goldenVsString
      "renderServerDockerfile notes-app"
      "test/golden/server-site.dockerfile"
      (pure (fromStrict (TE.encodeUtf8 (renderServerDockerfile notesApp))))
  , goldenVsString
      "renderServerService notes-app"
      "test/golden/server-site.service.yaml"
      (pure (fromStrict (renderServerService notesApp ctx)))
  , goldenVsString
      "renderServerDomainMappings notes-app"
      "test/golden/server-site.domainmapping.yaml"
      (pure (fromStrict (BS.intercalate (BC.pack "---\n") (renderServerDomainMappings notesApp ctx))))
  ]
  where
    fixturePath = "test/fixtures/server-site/nagare/Config.hs"

-- | 'notesApp' with one durable volume, proving the 'ServerSite' renderer emits
-- the same PVC / volumeMount / volume / rollout-annotation shape as the
-- 'Deployment' renderer (EP-34 IP2 parity).
notesVolApp :: ServerSite
notesVolApp =
  notesApp
    { volumes =
        [ Volume
            { volName = unsafe (mkVolumeName "uploads")
            , size = unsafe (mkQuantity "2Gi")
            , mountPath = unsafe (mkMountPath "/data/uploads")
            , accessMode = ReadWriteOnce
            , readOnly = False
            , retention = Retain
            }
        ]
    }

volumeParityTests :: [TestTree]
volumeParityTests =
  [ goldenVsString
      "renderServerService notes-app with volume"
      "test/golden/server-site-volume.service.yaml"
      (pure (fromStrict (renderServerService notesVolApp ctx)))
  , goldenVsString
      "renderServerVolumeClaims notes-app volume"
      "test/golden/server-site-volume.pvc.yaml"
      (pure (fromStrict (BS.intercalate (BC.pack "---\n") (renderServerVolumeClaims notesVolApp ctx))))
  ]

runtimeImageTests :: [TestTree]
runtimeImageTests =
  [ testCase "accepts node:22-alpine" $ assertRight (mkRuntimeImage "node:22-alpine")
  , testCase "rejects empty" $ assertLeftContains "empty" (mkRuntimeImage "")
  , testCase "rejects spaces" $ assertLeftContains "spaces" (mkRuntimeImage "node 22")
  , testCase "rejects URI scheme" $ assertLeftContains "scheme" (mkRuntimeImage "docker://node")
  ]

decodeFailureTests :: [TestTree]
decodeFailureTests =
  [ testCase "valid JSON decodes to Right" $
      case decodeServerSite (BC.pack (serverJSON validParts)) of
        Right _ -> pure ()
        other -> assertFailure ("expected Right, got: " <> show other)
  , testCase "absolute output dir returns MarshalError build.outputDirs" $
      assertMarshal "build.outputDirs" (serverJSON validParts {pOutputDirs = "[\"/abs\"]"})
  , testCase "parent-dir output dir returns MarshalError build.outputDirs" $
      assertMarshal "build.outputDirs" (serverJSON validParts {pOutputDirs = "[\"a/../b\"]"})
  , testCase "invalid base image returns MarshalError runtime.baseImage" $
      assertMarshal "runtime.baseImage" (serverJSON validParts {pBaseImage = "\"node 22\""})
  , testCase "empty start command returns MarshalError runtime.startCommand" $
      assertMarshal "runtime.startCommand" (serverJSON validParts {pStartCommand = "[]"})
  , testCase "empty output dirs returns MarshalError build.outputDirs" $
      assertMarshal "build.outputDirs" (serverJSON validParts {pOutputDirs = "[]"})
  , testCase "no kind returns UnexpectedKind" $
      case decodeServerSite (BC.pack deploymentJSON) of
        Left (UnexpectedKind "ServerSite" "<none>") -> pure ()
        other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
  , testCase "StaticSite kind returns UnexpectedKind" $
      case decodeServerSite (BC.pack (serverJSON validParts {pKind = "StaticSite"})) of
        Left (UnexpectedKind "ServerSite" "StaticSite") -> pure ()
        other -> assertFailure ("expected UnexpectedKind StaticSite, got: " <> show other)
  ]
  where
    assertMarshal field json =
      case decodeServerSite (BC.pack json) of
        Left (MarshalError f _) | f == field -> pure ()
        other -> assertFailure ("expected MarshalError " <> show field <> ", got: " <> show other)

deploymentJSON :: String
deploymentJSON =
  "{\"name\":\"hello\",\"namespace\":\"personal\",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[]}"

data ServerParts = ServerParts
  { pKind :: String
  , pOutputDirs :: String
  , pBaseImage :: String
  , pStartCommand :: String
  }

validParts :: ServerParts
validParts =
  ServerParts
    { pKind = "ServerSite"
    , pOutputDirs = "[\".output\"]"
    , pBaseImage = "\"node:22-alpine\""
    , pStartCommand = "[\"node\",\".output/server/index.mjs\"]"
    }

serverJSON :: ServerParts -> String
serverJSON p =
  "{\"kind\":\""
    <> pKind p
    <> "\",\"name\":\"app\",\"namespace\":\"personal\",\"image\":\"gcr.io/foo/bar\",\"build\":{\"command\":\"npm run build\",\"outputDirs\":"
    <> pOutputDirs p
    <> "},\"runtime\":{\"baseImage\":"
    <> pBaseImage p
    <> ",\"startCommand\":"
    <> pStartCommand p
    <> "},\"port\":8080,\"env\":[],\"domains\":[]}"

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> Text.unpack e)

assertRight :: (Show e) => Either e a -> Assertion
assertRight (Right _) = pure ()
assertRight (Left err) = assertFailure ("expected Right, got Left: " <> show err)

assertLeftContains :: Text -> Either Text a -> Assertion
assertLeftContains needle (Left msg)
  | needle `Text.isInfixOf` msg = pure ()
  | otherwise = assertFailure ("expected Left containing " <> show needle <> ", got: " <> Text.unpack msg)
assertLeftContains needle (Right _) =
  assertFailure ("expected Left containing " <> show needle <> ", got Right")
