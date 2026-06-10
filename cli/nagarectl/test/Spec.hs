-- | Tests for nagarectl's static-site helpers (EP-14).
--
-- The CLI proper (load → render → build → push → apply → wait) is validated
-- behaviourally by @nagarectl site deploy --dry-run@ against
-- @cluster/examples/static-site@; the renderer goldens live in
-- @nagare-dsl-test@ (EP-13). These unit tests cover the pure/helper logic that
-- is awkward to exercise through the dry-run: the generated Dockerfile and the
-- build/output-preparation state machine.
module Main (main) where

import Data.Aeson (eitherDecodeStrict, encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Nagare.Build (applyBuildOverrides, describeBuild)
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (EnvScope (..), defaultPort, mkImageRef, mkNamespace)
import Nagare.Env.Dotenv (parseDotenv)
import Nagare.Env.Store
import Nagare.Image (dockerBuildArgs, nixpacksBuildArgs)
import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Nagare.Server.Build
import Nagare.Static.Build
import Nagare.Static.Image (staticDockerfile)
import Nagare.Static.Preview
import Nagare.Static.Release
import Nagare.Static.Webhook
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain $
    testGroup
      "nagarectl"
      [ testGroup "Nagare.Static.Image" dockerfileTests
      , testGroup "Nagare.Static.Build" prepareTests
      , testGroup "Nagare.Static.Release" releaseTests
      , testGroup "Nagare.Static.Preview" previewTests
      , testGroup "Nagare.Static.Webhook" webhookTests
      , testGroup "Nagare.Server.Build" serverBuildTests
      , testGroup "Nagare.Build" buildModeTests
      , testGroup "Nagare.Env.Store" envStoreTests
      , testGroup "Nagare.Env.Dotenv" dotenvTests
      , testGroup "Nagare.Env reconcile mode" reconcileModeTests
      ]

-- ---------------------------------------------------------------------------
-- Nagare.Env.Dotenv (EP-25 M1)

dotenvTests :: [TestTree]
dotenvTests =
  [ testCase "parses KEY=VALUE lines" $
      parseDotenv "A=1\nB=2"
        @?= Right (Map.fromList [("A", "1"), ("B", "2")])
  , testCase "ignores blank lines and # comments" $
      parseDotenv "# a comment\n\nA=1\n   \n# another\nB=2"
        @?= Right (Map.fromList [("A", "1"), ("B", "2")])
  , testCase "strips a leading export" $
      parseDotenv "export A=1"
        @?= Right (Map.fromList [("A", "1")])
  , testCase "trims whitespace around key and unquoted value" $
      parseDotenv "  A =  hello "
        @?= Right (Map.fromList [("A", "hello")])
  , testCase "double-quoted value keeps inner # and spaces" $
      parseDotenv "A=\"a # b c\""
        @?= Right (Map.fromList [("A", "a # b c")])
  , testCase "single-quoted value is literal" $
      parseDotenv "A='x y'"
        @?= Right (Map.fromList [("A", "x y")])
  , testCase "multiline quoted value spans lines" $
      parseDotenv "A=\"line1\nline2\"\nB=2"
        @?= Right (Map.fromList [("A", "line1\nline2"), ("B", "2")])
  , testCase "a line with no = is an error" $
      assertLeftText (parseDotenv "A=1\nNOEQUALS\nB=2")
  , testCase "an empty key is an error" $
      assertLeftText (parseDotenv "=value")
  ]

-- ---------------------------------------------------------------------------
-- Reconcile-mode selection (EP-25 M2): the behavior env sync --merge vs
-- --reconcile-exact selects, proven against the exact function the CLI calls.

reconcileModeTests :: [TestTree]
reconcileModeTests =
  [ testCase "merge keeps a key absent from the incoming set" $
      reconcile Merge (Map.fromList [("KEEP", "1")]) (Map.fromList [("NEW", "2")])
        @?= Map.fromList [("KEEP", "1"), ("NEW", "2")]
  , testCase "reconcile-exact drops a key absent from the incoming set" $
      reconcile ReconcileExact (Map.fromList [("DROP", "1")]) (Map.fromList [("NEW", "2")])
        @?= Map.fromList [("NEW", "2")]
  ]

-- ---------------------------------------------------------------------------
-- Nagare.Env.Store (EP-24)

envStoreTests :: [TestTree]
envStoreTests =
  [ testCase "reconcile Merge unions, incoming wins, keeps existing-only keys" $
      reconcile Merge (Map.fromList [("A", "1"), ("B", "2")]) (Map.fromList [("B", "9"), ("C", "3")])
        @?= Map.fromList [("A", "1"), ("B", "9"), ("C", "3")]
  , testCase "reconcile ReconcileExact replaces the whole set" $
      reconcile ReconcileExact (Map.fromList [("A", "1"), ("B", "2")]) (Map.fromList [("B", "9"), ("C", "3")])
        @?= Map.fromList [("B", "9"), ("C", "3")]
  , testCase "renderEnvSecret/extractSecretData round-trip base64 values" $ do
      let kvs = Map.fromList [("DATABASE_URL", "postgres://u:p@h/db"), ("API_KEY", "s3cr3t==")]
      case extractSecretData (renderEnvSecret "notes" "personal" Runtime kvs) of
        Right back -> back @?= kvs
        Left e -> assertFailure ("extract failed: " <> T.unpack e)
  , testCase "renderEnvConfigMap round-trips plaintext values" $ do
      let kvs = Map.fromList [("LOG_LEVEL", "info"), ("REGION", "us-west1")]
      case extractConfigMapData (renderEnvConfigMap "notes" "personal" Runtime kvs) of
        Right back -> back @?= kvs
        Left e -> assertFailure ("extract failed: " <> T.unpack e)
  , testCase "renderEnvConfigMap is apply-able JSON named per IP2" $ do
      let bs = renderEnvConfigMap "notes" "personal" Runtime (Map.singleton "K" "v")
      case Aeson.eitherDecodeStrict bs of
        Right (Aeson.Object o) -> do
          KeyMap.lookup (Key.fromText "kind") o @?= Just (Aeson.String "ConfigMap")
          metaName o @?= Just (Aeson.String "nagare-env-notes-runtime")
        other -> assertFailure ("not a JSON object: " <> show other)
  , testCase "renderEnvSecret is named per IP2 and typed Opaque" $ do
      let bs = renderEnvSecret "notes" "personal" Build (Map.singleton "K" "v")
      case Aeson.eitherDecodeStrict bs of
        Right (Aeson.Object o) -> do
          KeyMap.lookup (Key.fromText "kind") o @?= Just (Aeson.String "Secret")
          KeyMap.lookup (Key.fromText "type") o @?= Just (Aeson.String "Opaque")
          metaName o @?= Just (Aeson.String "nagare-secret-notes-build")
        other -> assertFailure ("not a JSON object: " <> show other)
  , testCase "renderEnvSecret base64-encodes values on the wire" $ do
      -- aGVsbG8= is base64 of "hello"; prove values are encoded, not plaintext.
      let bs = renderEnvSecret "notes" "personal" Runtime (Map.singleton "API_KEY" "hello")
      case Aeson.eitherDecodeStrict bs of
        Right (Aeson.Object o)
          | Just (Aeson.Object d) <- KeyMap.lookup (Key.fromText "data") o ->
              KeyMap.lookup (Key.fromText "API_KEY") d @?= Just (Aeson.String "aGVsbG8=")
        other -> assertFailure ("unexpected secret JSON: " <> show other)
  , testCase "extractConfigMapData of missing data yields empty map" $
      extractConfigMapData "{\"kind\":\"ConfigMap\"}" @?= Right Map.empty
  , testCase "extractConfigMapData of malformed JSON is Left" $
      case extractConfigMapData "not json" of
        Left _ -> pure ()
        Right _ -> assertFailure "expected Left for malformed JSON"
  , testCase "extractSecretData rejects malformed base64 (no silent loss)" $
      case extractSecretData "{\"kind\":\"Secret\",\"data\":{\"K\":\"!!!notb64!!!\"}}" of
        Left _ -> pure ()
        Right _ -> assertFailure "expected Left for malformed base64"
  ]
  where
    metaName o = do
      Aeson.Object m <- KeyMap.lookup (Key.fromText "metadata") o
      KeyMap.lookup (Key.fromText "name") m

-- ---------------------------------------------------------------------------
-- Dockerfile

dockerfileTests :: [TestTree]
dockerfileTests =
  [ testCase "staticDockerfile uses the nginx base and 8080 layout" $ do
      let df = staticDockerfile
      assertInfix "FROM nginx:1.27-alpine" df
      assertInfix "COPY nginx.conf /etc/nginx/conf.d/default.conf" df
      assertInfix "COPY site/ /usr/share/nginx/html/" df
      assertInfix "EXPOSE 8080" df
  ]

assertInfix :: ByteString -> ByteString -> Assertion
assertInfix needle hay
  | needle `BC.isInfixOf` hay = pure ()
  | otherwise =
      assertFailure ("expected " <> show needle <> " in:\n" <> BC.unpack hay)

-- ---------------------------------------------------------------------------
-- prepareStaticOutput

prepareTests :: [TestTree]
prepareTests =
  [ testCase "NoBuild + existing dir + skipBuild returns the resolved output dir" $
      withSystemTempDirectory "nagare-prep" $ \root -> do
        createDirectoryIfMissing True (root </> "public")
        result <- prepareStaticOutput True (noBuildSite "public") root
        case result of
          Right (PreparedStaticOutput out) -> assertInfixStr "public" out
          other -> assertFailure ("expected Right, got: " <> show other)
  , testCase "NoBuild + missing dir returns OutputDirectoryMissing" $
      withSystemTempDirectory "nagare-prep" $ \root -> do
        result <- prepareStaticOutput True (noBuildSite "dist") root
        case result of
          Left (OutputDirectoryMissing _) -> pure ()
          other -> assertFailure ("expected OutputDirectoryMissing, got: " <> show other)
  , testCase "missing project root returns ProjectRootMissing" $ do
      result <- prepareStaticOutput True (noBuildSite "public") "/no/such/root"
      case result of
        Left (ProjectRootMissing _) -> pure ()
        other -> assertFailure ("expected ProjectRootMissing, got: " <> show other)
  , testCase "BuildCommand that produces the output dir succeeds" $
      withSystemTempDirectory "nagare-prep" $ \root -> do
        result <- prepareStaticOutput False (buildSite "mkdir -p out" "out") root
        case result of
          Right (PreparedStaticOutput out) -> assertInfixStr "out" out
          other -> assertFailure ("expected Right, got: " <> show other)
  , testCase "BuildCommand that exits non-zero returns BuildCommandFailed" $
      withSystemTempDirectory "nagare-prep" $ \root -> do
        result <- prepareStaticOutput False (buildSite "exit 3" "out") root
        case result of
          Left (BuildCommandFailed _ 3) -> pure ()
          other -> assertFailure ("expected BuildCommandFailed _ 3, got: " <> show other)
  ]

assertInfixStr :: String -> FilePath -> Assertion
assertInfixStr needle hay
  | T.pack needle `T.isInfixOf` T.pack hay = pure ()
  | otherwise = assertFailure ("expected " <> show needle <> " in path: " <> hay)

-- ---------------------------------------------------------------------------
-- Release log

releaseTests :: [TestTree]
releaseTests =
  [ testCase "StaticReleaseLog JSON round-trips" $ do
      let logv = addRelease (release "20260101-000000" t1) emptyReleaseLog
          encoded = LBS.toStrict (encode logv)
      case eitherDecodeStrict encoded of
        Right back -> back @?= logv
        Left e -> assertFailure ("decode failed: " <> e)
  , testCase "addRelease puts newest first and marks it current" $ do
      let logv =
            addRelease (release "b" t2) $
              addRelease (release "a" t1) emptyReleaseLog
      current logv @?= Just "b"
      map releaseId (releases logv) @?= ["b", "a"]
  , testCase "addRelease dedupes a re-deployed id (no duplicate, becomes current)" $ do
      let logv =
            addRelease (release "a" t3) $
              addRelease (release "b" t2) $
                addRelease (release "a" t1) emptyReleaseLog
      map releaseId (releases logv) @?= ["a", "b"]
      current logv @?= Just "a"
  , testCase "addRelease caps history at historyCap" $ do
      let many' = foldr (\i l -> addRelease (release (T.pack (show i)) (tAt i)) l) emptyReleaseLog [1 .. historyCap + 10 :: Int]
      length (releases many') @?= historyCap
  , testCase "findRelease finds a recorded release" $ do
      let logv = addRelease (release "a" t1) emptyReleaseLog
      fmap releaseId (findRelease "a" logv) @?= Just "a"
      findRelease "missing" logv @?= Nothing
  , testCase "extractReleaseLog reads the ConfigMap data key" $ do
      let logv = addRelease (release "a" t1) emptyReleaseLog
          cm = renderReleaseConfigMap "notes" "personal" logv
      case extractReleaseLog cm of
        Right back -> back @?= logv
        Left e -> assertFailure ("extract failed: " <> T.unpack e)
  , testCase "extractReleaseLog of a ConfigMap with no data is empty" $
      case extractReleaseLog "{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{}}" of
        Right back -> back @?= emptyReleaseLog
        Left e -> assertFailure ("expected empty log, got error: " <> T.unpack e)
  , testCase "configMapName is prefixed per site" $
      configMapName "notes" @?= "nagare-static-releases-notes"
  ]

release :: Text -> UTCTime -> StaticRelease
release rid created =
  StaticRelease
    { releaseId = rid
    , siteName = "notes"
    , namespace = "personal"
    , image = "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
    , imageTag = rid
    , url = "https://notes.personal.apps.example.com"
    , source = Just "main"
    , createdAt = created
    }

t1, t2, t3 :: UTCTime
t1 = tAt 1
t2 = tAt 2
t3 = tAt 3

tAt :: Int -> UTCTime
tAt n = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime (fromIntegral n))

-- ---------------------------------------------------------------------------
-- Preview naming

previewTests :: [TestTree]
previewTests =
  [ testCase "normalizePreviewName lowercases and hyphenates" $
      normalizePreviewName "Feature/PR #12" @?= Right "feature-pr-12"
  , testCase "normalizePreviewName trims and collapses hyphens" $
      normalizePreviewName "--a__b--" @?= Right "a-b"
  , testCase "normalizePreviewName rejects all-punctuation" $
      assertLeftText (normalizePreviewName "@@@")
  , testCase "previewServiceName derives <site>-pr-<name>" $
      previewServiceName "notes" "feature-x" @?= Right "notes-pr-feature-x"
  , testCase "previewServiceName clips to 63 chars without trailing hyphen" $
      case previewServiceName "notes" (T.replicate 80 "a") of
        Right n -> do
          assertBool "<= 63 chars" (T.length n <= 63)
          assertBool "no trailing hyphen" (T.last n /= '-')
        Left e -> assertFailure ("expected Right, got: " <> T.unpack e)
  , testCase "previewDomain derives <preview>.<site>.preview.<base>" $
      previewDomain "notes" "feature-x" "apps.example.com"
        @?= Right "feature-x.notes.preview.apps.example.com"
  ]

assertLeftText :: Either Text a -> Assertion
assertLeftText (Left _) = pure ()
assertLeftText (Right _) = assertFailure "expected Left, got Right"

-- ---------------------------------------------------------------------------
-- Server build (EP-18)

serverBuildTests :: [TestTree]
serverBuildTests =
  [ testCase "skipBuild + existing .output resolves the output dir" $
      withSystemTempDirectory "nagare-srv" $ \root -> do
        createDirectoryIfMissing True (root </> ".output")
        result <- prepareServerOutput True demoServerSite root
        case result of
          Right (PreparedServerOutput outs) ->
            assertInfixStr ".output" (snd (head (toList' outs)))
          Left e -> assertFailure ("expected Right, got: " <> T.unpack e)
  , testCase "missing .output returns a clear error" $
      withSystemTempDirectory "nagare-srv" $ \root -> do
        result <- prepareServerOutput True demoServerSite root
        case result of
          Left _ -> pure ()
          Right _ -> assertFailure "expected Left for missing .output"
  , testCase "build command that exits non-zero is reported" $
      withSystemTempDirectory "nagare-srv" $ \root -> do
        result <- prepareServerOutput False (demoServerSiteWith "exit 4") root
        case result of
          Left e -> assertBool "mentions exit 4" (T.isInfixOf "exit 4" e)
          Right _ -> assertFailure "expected Left for failing build"
  ]
  where
    toList' ne = foldr (:) [] ne

demoServerSite :: ServerSite
demoServerSite = demoServerSiteWith "npm run build"

demoServerSiteWith :: Text -> ServerSite
demoServerSiteWith buildCmd =
  ServerSite
    { name = unsafeS (mkSiteName "demo")
    , namespace = unsafeS (mkNamespace "personal")
    , image = unsafeS (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo")
    , build = ServerBuild {command = buildCmd, outputDirs = unsafeS (mkFilePathText ".output") :| []}
    , runtime = defaultServerRuntime
    , port = defaultPort
    , env = Map.empty
    , resources = Nothing
    , scale = Nothing
    , domains = []
    }

unsafeS :: Either Text a -> a
unsafeS (Right a) = a
unsafeS (Left e) = error ("test fixture invalid: " <> T.unpack e)

-- ---------------------------------------------------------------------------
-- Webhook

webhookTests :: [TestTree]
webhookTests =
  [ testCase "verifySignature accepts the known HMAC-SHA256 test vector" $
      -- HMAC-SHA256(key="key", "The quick brown fox jumps over the lazy dog")
      assertBool "valid signature accepted" $
        verifySignature
          "key"
          "The quick brown fox jumps over the lazy dog"
          "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
  , testCase "verifySignature rejects a wrong signature" $
      assertBool "wrong signature rejected" $
        not (verifySignature "key" "body" "sha256=00000000")
  , testCase "decideWebhook rejects a missing signature" $
      case decideWebhook cfg (Just "push") Nothing pushMain of
        Rejected 401 _ -> pure ()
        other -> assertFailure ("expected Rejected 401, got: " <> show other)
  , testCase "decideWebhook rejects an invalid signature" $
      case decideWebhook cfg (Just "push") (Just "sha256=bad") pushMain of
        Rejected 401 _ -> pure ()
        other -> assertFailure ("expected Rejected 401, got: " <> show other)
  , testCase "decideWebhook acks a signed ping" $
      case decideWebhook cfg (Just "ping") (Just (sign "topsecret" ping)) ping of
        Ignored _ -> pure ()
        other -> assertFailure ("expected Ignored, got: " <> show other)
  , testCase "decideWebhook triggers production for a push to main" $
      case decideWebhook cfg (Just "push") (Just (sign "topsecret" pushMain)) pushMain of
        Triggered (DeployProduction co) -> repoFullName co @?= "o/x"
        other -> assertFailure ("expected DeployProduction, got: " <> show other)
  , testCase "decideWebhook ignores a push to a non-production branch" $
      case decideWebhook cfg (Just "push") (Just (sign "topsecret" pushDev)) pushDev of
        Ignored _ -> pure ()
        other -> assertFailure ("expected Ignored, got: " <> show other)
  , testCase "decideWebhook triggers a preview for a PR opened" $
      case decideWebhook cfg (Just "pull_request") (Just (sign "topsecret" prOpened)) prOpened of
        Triggered (DeployPreview name _) -> name @?= "pr-7"
        other -> assertFailure ("expected DeployPreview pr-7, got: " <> show other)
  , testCase "decideWebhook ignores a PR closed" $
      case decideWebhook cfg (Just "pull_request") (Just (sign "topsecret" prClosed)) prClosed of
        Ignored _ -> pure ()
        other -> assertFailure ("expected Ignored, got: " <> show other)
  , testCase "parseGitHubEvent push extracts branch and sha" $
      case parseGitHubEvent "push" pushMain of
        Right (PushEvent b co) -> do
          b @?= "main"
          sha co @?= "deadbeef"
        other -> assertFailure ("expected PushEvent, got: " <> show other)
  , testCase "parseGitHubEvent of an unknown type is OtherEvent" $
      parseGitHubEvent "issues" "{}" @?= Right (OtherEvent "issues")
  , testCase "previewNameForPr is pr-<n>" $
      previewNameForPr 42 @?= "pr-42"
  ]
  where
    cfg = WebhookConfig {secret = "topsecret", productionBranch = "main"}

sign :: ByteString -> ByteString -> ByteString
sign secret body =
  BC.pack ("sha256=" <> show (hmacGetDigest (hmac secret body :: HMAC SHA256)))

ping :: ByteString
ping = "{\"zen\":\"hi\"}"

pushMain :: ByteString
pushMain =
  "{\"ref\":\"refs/heads/main\",\"after\":\"deadbeef\",\"repository\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}"

pushDev :: ByteString
pushDev =
  "{\"ref\":\"refs/heads/dev\",\"after\":\"abc\",\"repository\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}"

prOpened :: ByteString
prOpened =
  "{\"action\":\"opened\",\"number\":7,\"pull_request\":{\"head\":{\"ref\":\"feature\",\"sha\":\"cafe\",\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}}}"

prClosed :: ByteString
prClosed =
  "{\"action\":\"closed\",\"number\":7,\"pull_request\":{\"head\":{\"ref\":\"feature\",\"sha\":\"cafe\",\"repo\":{\"clone_url\":\"https://e/x.git\",\"full_name\":\"o/x\"}}}}"

-- ---------------------------------------------------------------------------
-- Build modes (EP-20)

dockerfileSpec :: BuildSpec
dockerfileSpec =
  DockerfileBuild
    { dockerfile = unsafe (mkFilePathText "Dockerfile")
    , context = unsafe (mkFilePathText ".")
    , buildArgs = Map.fromList [("MODE", "release"), ("VERSION", "1.0")]
    }

nixpacksSpec :: BuildSpec
nixpacksSpec =
  NixpacksBuild
    { context = unsafe (mkFilePathText ".")
    , buildArgs = Map.empty
    }

prebuiltSpec :: BuildSpec
prebuiltSpec = PrebuiltImage (unsafe (mkTag "v1.2.3"))

buildModeTests :: [TestTree]
buildModeTests =
  [ testGroup
      "dockerBuildArgs"
      [ testCase "emits -f, -t, --build-arg, context in order" $
          dockerBuildArgs "r" "Dockerfile" "." [("A", "1")]
            @?= ["build", "-f", "Dockerfile", "-t", "r", "--build-arg", "A=1", "."]
      , testCase "no build args omits --build-arg" $
          dockerBuildArgs "ref:tag" "docker/Dockerfile" "svc" []
            @?= ["build", "-f", "docker/Dockerfile", "-t", "ref:tag", "svc"]
      , testCase "multiple build args each get their own --build-arg" $
          dockerBuildArgs "r" "Dockerfile" "." [("A", "1"), ("B", "2")]
            @?= [ "build", "-f", "Dockerfile", "-t", "r"
                , "--build-arg", "A=1", "--build-arg", "B=2", "."
                ]
      ]
  , testGroup
      "nixpacksBuildArgs"
      [ testCase "builds the context and tags with --name" $
          nixpacksBuildArgs "ref:tag" "." []
            @?= ["build", ".", "--name", "ref:tag"]
      , testCase "build args become --env KEY=VALUE" $
          nixpacksBuildArgs "r" "app" [("A", "1")]
            @?= ["build", "app", "--name", "r", "--env", "A=1"]
      , testCase "multiple build args each get their own --env" $
          nixpacksBuildArgs "r" "." [("A", "1"), ("B", "2")]
            @?= ["build", ".", "--name", "r", "--env", "A=1", "--env", "B=2"]
      ]
  , testGroup
      "describeBuild"
      [ testCase "prebuilt mentions no local build and the tag" $
          describeBuild prebuiltSpec @?= "prebuilt image (no local build), tag v1.2.3"
      , testCase "dockerfile shows the docker build command" $
          describeBuild dockerfileSpec @?= "docker build -f Dockerfile ."
      , testCase "nixpacks shows the nixpacks build command" $
          describeBuild nixpacksSpec @?= "nixpacks build ."
      ]
  , testGroup
      "applyBuildOverrides"
      [ testCase "no overrides leaves the spec unchanged" $
          applyBuildOverrides Nothing Nothing dockerfileSpec @?= Right dockerfileSpec
      , testCase "context override substitutes the Dockerfile build context" $
          case applyBuildOverrides (Just "services/web") Nothing dockerfileSpec of
            Right (DockerfileBuild _ ctx _) -> filePathText ctx @?= "services/web"
            other -> assertFailure ("expected DockerfileBuild, got: " <> show other)
      , testCase "dockerfile override substitutes the Dockerfile path" $
          case applyBuildOverrides Nothing (Just "docker/Dockerfile.prod") dockerfileSpec of
            Right (DockerfileBuild df _ _) -> filePathText df @?= "docker/Dockerfile.prod"
            other -> assertFailure ("expected DockerfileBuild, got: " <> show other)
      , testCase "an invalid (absolute) override path is rejected" $
          assertLeftText (applyBuildOverrides (Just "/abs") Nothing dockerfileSpec)
      , testCase "context override applies to a Nixpacks build" $
          case applyBuildOverrides (Just "app") Nothing nixpacksSpec of
            Right (NixpacksBuild ctx _) -> filePathText ctx @?= "app"
            other -> assertFailure ("expected NixpacksBuild, got: " <> show other)
      , testCase "dockerfile override against a Nixpacks build is an error" $
          assertLeftText (applyBuildOverrides Nothing (Just "Dockerfile") nixpacksSpec)
      , testCase "any override against a prebuilt config is an error" $ do
          assertLeftText (applyBuildOverrides (Just "x") Nothing prebuiltSpec)
          assertLeftText (applyBuildOverrides Nothing (Just "Dockerfile") prebuiltSpec)
      , testCase "no override against a prebuilt config is fine" $
          applyBuildOverrides Nothing Nothing prebuiltSpec @?= Right prebuiltSpec
      ]
  ]

-- ---------------------------------------------------------------------------
-- Fixtures

noBuildSite :: Text -> StaticSite
noBuildSite dir = baseSite (NoBuild (unsafe (mkFilePathText dir)))

buildSite :: Text -> Text -> StaticSite
buildSite command outDir =
  baseSite
    ( BuildCommand
        { command = command
        , outputDirectory = unsafe (mkFilePathText outDir)
        }
    )

baseSite :: StaticBuild -> StaticSite
baseSite b =
  StaticSite
    { name = unsafe (mkSiteName "demo")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo")
    , build = b
    , domains = []
    , redirects = []
    , headers = []
    , cache = defaultCachePolicy
    , notFound = Nothing
    }

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> T.unpack e)
