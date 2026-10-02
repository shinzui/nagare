-- | Environment responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Environment
  ( buildArgsTests
  , dotenvTests
  , envStoreTests
  , eventsBinding
  , eventsConn
  , genLit
  , generatedEnvTests
  , mkDemoDep
  , previewOverlayTests
  , reconcileModeTests
  , renderDemonstrationTests
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Broker.Connection (BrokerConn (..))
import Nagare.Dsl.Broker
  ( BrokerBinding (..)
  , BrokerProvider (Redpanda)
  , mkBrokerName
  , mkTopicName
  )
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Render (renderService)
import Nagare.Dsl.Types
  ( Deployment (..)
  , EnvName
  , EnvScope (Build, Runtime)
  , EnvVar (EnvLiteral, EnvSecretRef)
  , ScopedEnvVar (ScopedEnvVar, value)
  , defaultPort
  , envNameText
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , mkSecretName
  , mkServiceName
  , runtimeScoped
  , scopedEnv
  )
import Nagare.Env.BuildArgs
  ( BuildArgWarning (..)
  , assembleBuildArgs
  )
import Nagare.Env.Dotenv (parseDotenv)
import Nagare.Env.Generated (generatedEnv, mergeGenerated)
import Nagare.Env.Generated qualified as Gen
import Nagare.Env.PreviewOverlay (withPreviewEnvFrom)
import Nagare.Env.Store
  ( ReconcileMode (Merge, ReconcileExact)
  , decodeStoreRead
  , extractConfigMapData
  , extractSecretData
  , reconcile
  , renderEnvConfigMap
  , renderEnvSecret
  , renderEnvSecretPreview
  )
import Nagare.Test.Application (staticServiceYaml)
import Nagare.Test.Support.Assertions
  ( assertBefore
  , assertInfix
  , assertLeftText
  , unsafe
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Tasty (TestTree)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

previewOverlayTests :: [TestTree]
previewOverlayTests =
  [ testCase "preview Service gains four envFrom entries in runtime-then-preview order" $ do
      let out = withPreviewEnvFrom "demo" staticServiceYaml
      assertInfix "nagare-env-demo-runtime" out
      assertInfix "nagare-secret-demo-runtime" out
      assertInfix "nagare-env-demo-preview" out
      assertInfix "nagare-secret-demo-preview" out
      assertBefore "nagare-env-demo-runtime" "nagare-secret-demo-runtime" out
      assertBefore "nagare-secret-demo-runtime" "nagare-env-demo-preview" out
      assertBefore "nagare-env-demo-preview" "nagare-secret-demo-preview" out
  , testCase "overlaid Service carries envFrom with optional: true" $ do
      let out = withPreviewEnvFrom "demo" staticServiceYaml
      assertInfix "envFrom" out
      assertInfix "optional: true" out
      assertInfix "image: gcr.io/p/demo:20260609-120000" out -- container preserved
  , testCase "the un-overlaid (production) Service carries no preview envFrom" $
      assertBool
        "preview pair absent from production"
        (not ("nagare-env-demo-preview" `BC.isInfixOf` staticServiceYaml))
  ]

-- ---------------------------------------------------------------------------
-- Nagare.Env.BuildArgs (EP-27 M1)

buildArgsTests :: [TestTree]
buildArgsTests =
  [ testCase "inline Build overrides managed; Runtime-only excluded" $
      let (args, _) =
            assembleBuildArgs
              (Map.fromList [("A", "1")])
              (Map.fromList [("B", "2")])
              ( Map.fromList
                  [ (unsafe (mkEnvName "A"), unsafe (scopedEnv (Set.fromList [Build]) (EnvLiteral "9")))
                  , (unsafe (mkEnvName "C"), runtimeScoped (EnvLiteral "x"))
                  ]
              )
       in args @?= [("A", "9"), ("B", "2")]
  , testCase "managed-only when no inline Build" $
      let (args, _) = assembleBuildArgs (Map.fromList [("A", "1")]) Map.empty Map.empty
       in args @?= [("A", "1")]
  , testCase "managed secret value passed; config value kept" $
      let (args, _) =
            assembleBuildArgs
              (Map.fromList [("CFG", "c")])
              (Map.fromList [("SEC", "s")])
              Map.empty
       in args @?= [("CFG", "c"), ("SEC", "s")]
  , testCase "build-scoped secret-ref warns" $
      let (_, warns) =
            assembleBuildArgs
              Map.empty
              (Map.fromList [("TOKEN", "s3cr3t")])
              ( Map.singleton
                  (unsafe (mkEnvName "TOKEN"))
                  (unsafe (scopedEnv (Set.fromList [Build]) (EnvSecretRef (unsafe (mkSecretName "tok")))))
              )
       in warns @?= [BuildArgSecretRef "TOKEN"]
  , testCase "build-scoped secret-ref resolves to its stored value" $
      let (args, _) =
            assembleBuildArgs
              Map.empty
              (Map.fromList [("TOKEN", "s3cr3t")])
              ( Map.singleton
                  (unsafe (mkEnvName "TOKEN"))
                  (unsafe (scopedEnv (Set.fromList [Build]) (EnvSecretRef (unsafe (mkSecretName "tok")))))
              )
       in args @?= [("TOKEN", "s3cr3t")]
  ]

-- ---------------------------------------------------------------------------
-- Nagare.Env.Generated (EP-26)

sampleCtx :: Gen.GeneratedContext
sampleCtx =
  Gen.GeneratedContext
    { Gen.serviceName = "notes"
    , Gen.namespace = "personal"
    , Gen.serviceUrl = "https://notes.personal.apps.example.com"
    , Gen.baseDomain = "apps.example.com"
    , Gen.releaseId = "20260602-120000"
    , Gen.source = Just "main"
    }

-- | Look up a generated value by name, as plain Text (asserts it is a literal).
genLit :: Map.Map EnvName ScopedEnvVar -> Text -> Maybe Text
genLit m name = do
  en <- either (const Nothing) Just (mkEnvName name)
  ScopedEnvVar {value = v} <- Map.lookup en m
  case v of
    EnvLiteral t -> Just t
    _ -> Nothing

generatedEnvTests :: [TestTree]
generatedEnvTests =
  [ testCase "produces the six NAGARE_* keys when source is Just" $ do
      let m = generatedEnv sampleCtx
      map envNameText (Map.keys m)
        @?= [ "NAGARE_BASE_DOMAIN"
            , "NAGARE_NAMESPACE"
            , "NAGARE_RELEASE_ID"
            , "NAGARE_SERVICE_NAME"
            , "NAGARE_SERVICE_URL"
            , "NAGARE_SOURCE"
            ]
  , testCase "values match the context" $ do
      let m = generatedEnv sampleCtx
      genLit m "NAGARE_SERVICE_URL" @?= Just "https://notes.personal.apps.example.com"
      genLit m "NAGARE_SERVICE_NAME" @?= Just "notes"
      genLit m "NAGARE_NAMESPACE" @?= Just "personal"
      genLit m "NAGARE_BASE_DOMAIN" @?= Just "apps.example.com"
      genLit m "NAGARE_RELEASE_ID" @?= Just "20260602-120000"
      genLit m "NAGARE_SOURCE" @?= Just "main"
  , testCase "omits NAGARE_SOURCE when source is Nothing" $ do
      let m = generatedEnv (sampleCtx & #source .~ Nothing)
      genLit m "NAGARE_SOURCE" @?= Nothing
      length (Map.keys m) @?= 5
  , testCase "every generated entry is Runtime-scoped" $ do
      let m = generatedEnv sampleCtx
      mapM_ (\sev -> sev ^. #scopes @?= runtimeScoped (EnvLiteral "x") ^. #scopes) (Map.elems m)
  , testCase "mergeGenerated overrides a user var of the same name" $ do
      let user =
            Map.singleton
              (unsafe (mkEnvName "NAGARE_SERVICE_URL"))
              (runtimeScoped (EnvLiteral "https://evil.example"))
          merged = mergeGenerated (generatedEnv sampleCtx) user
      genLit merged "NAGARE_SERVICE_URL" @?= Just "https://notes.personal.apps.example.com"
  , testCase "mergeGenerated keeps unrelated user vars" $ do
      let user =
            Map.singleton
              (unsafe (mkEnvName "API_BASE"))
              (runtimeScoped (EnvLiteral "https://api.example.com"))
          merged = mergeGenerated (generatedEnv sampleCtx) user
      genLit merged "API_BASE" @?= Just "https://api.example.com"
  ]

-- ---------------------------------------------------------------------------
-- Nagare.Broker.Connection (EP-77)

eventsBinding :: BrokerBinding
eventsBinding =
  BrokerBinding
    { name = unsafe (mkBrokerName "events")
    , topics = [unsafe (mkTopicName "jobs"), unsafe (mkTopicName "user.created")]
    }

eventsConn :: BrokerConn
eventsConn =
  BrokerConn
    { provider = Redpanda
    , bootstrapServers = "events.personal.svc.cluster.local:9092"
    , topics = [unsafe (mkTopicName "jobs"), unsafe (mkTopicName "user.created")]
    }

-- ---------------------------------------------------------------------------
-- EP-26 render demonstration: the generated vars actually appear in a
-- deployed Service's inline env: (mirrors what runDeploy does).

demoEnv :: Map.Map EnvName ScopedEnvVar
demoEnv =
  Map.singleton
    (unsafe (mkEnvName "API_BASE"))
    (runtimeScoped (EnvLiteral "https://api.example.com"))

-- | A demo Deployment carrying the given env map. Built via record construction
-- (the constructor names the type, so the 'env' field is unambiguous, unlike a
-- record /update/ which clashes with ServerSite.env).
mkDemoDep :: Map.Map EnvName ScopedEnvVar -> Deployment
mkDemoDep envMap =
  Deployment
    { name = unsafe (mkServiceName "notes")
    , logicalKey = Nothing
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes")
    , build = unsafe defaultBuild
    , domains = []
    , port = defaultPort
    , env = envMap
    , resources = Nothing
    , scale = Nothing
    , healthCheck = Nothing
    , volumes = []
    , databases = []
    , brokers = []
    , access = Nothing
    , tasks = []
    , cdn = Nothing
    }

renderDemonstrationTests :: [TestTree]
renderDemonstrationTests =
  [ testCase "deployed Service inline env contains the generated NAGARE_* vars" $ do
      let dep' = mkDemoDep (mergeGenerated (generatedEnv sampleCtx) demoEnv)
          yaml = renderService dep' "20260602-120000"
      assertInfix "NAGARE_SERVICE_URL" yaml
      assertInfix "https://notes.personal.apps.example.com" yaml
      assertInfix "NAGARE_RELEASE_ID" yaml
      assertInfix "NAGARE_SOURCE" yaml
      assertInfix "main" yaml
      assertInfix "API_BASE" yaml -- user var preserved
  , testCase "without --source, NAGARE_SOURCE is absent from the rendered Service" $ do
      let gctx = sampleCtx & #source .~ Nothing
          dep' = mkDemoDep (mergeGenerated (generatedEnv gctx) demoEnv)
          yaml = renderService dep' "20260602-120000"
      assertBool "NAGARE_SOURCE absent" (not ("NAGARE_SOURCE" `BC.isInfixOf` yaml))
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
  , testCase "public Secret preview exposes keys without reusable values" $ do
      let previewBytes =
            renderEnvSecretPreview
              "notes"
              "personal"
              Runtime
              (Map.singleton "API_KEY" "topsecret")
      case Aeson.eitherDecodeStrict previewBytes of
        Right (Aeson.Object fields) -> do
          KeyMap.lookup (Key.fromText "name") fields
            @?= Just (Aeson.String "nagare-secret-notes-runtime")
          KeyMap.lookup (Key.fromText "keys") fields
            @?= Just (Aeson.toJSON (["API_KEY"] :: [Text]))
          KeyMap.lookup (Key.fromText "data") fields @?= Nothing
          assertBool
            "preview exposed plaintext or base64 Secret data"
            ( not
                ( "topsecret" `BS.isInfixOf` previewBytes
                    || "dG9wc2VjcmV0" `BS.isInfixOf` previewBytes
                )
            )
        other -> assertFailure ("unexpected Secret preview: " <> show other)
  , testCase "extractConfigMapData of missing data yields empty map" $
      extractConfigMapData "{\"kind\":\"ConfigMap\"}" @?= Right Map.empty
  , testCase "extractConfigMapData of malformed JSON is Left" $
      case extractConfigMapData "not json" of
        Left _ -> pure ()
        Right _ -> assertFailure "expected Left for malformed JSON"
  , testCase "env and Secret reads distinguish absence from provider failure" $ do
      decodeStoreRead "configmap" extractConfigMapData ExitSuccess "" @?= Right Map.empty
      decodeStoreRead "secret" extractSecretData ExitSuccess "" @?= Right Map.empty
      let config = renderEnvConfigMap "notes" "personal" Runtime (Map.singleton "KEEP" "old")
          secret = renderEnvSecret "notes" "personal" Runtime (Map.singleton "KEEP" "private")
      assertLeftText (decodeStoreRead "configmap" extractConfigMapData (ExitFailure 1) config)
      assertLeftText (decodeStoreRead "secret" extractSecretData (ExitFailure 1) secret)
  , testCase "malformed environment data cannot silently drop keys" $ do
      assertLeftText (extractConfigMapData "{\"kind\":\"ConfigMap\",\"data\":{\"KEEP\":\"old\",\"BROKEN\":3}}")
      assertLeftText (extractSecretData "{\"kind\":\"Secret\",\"data\":{\"KEEP\":\"cHJpdmF0ZQ==\",\"BROKEN\":null}}")
      assertLeftText (extractConfigMapData "{\"kind\":\"ConfigMap\",\"data\":null}")
  , testCase "extractSecretData rejects malformed base64 (no silent loss)" $
      case extractSecretData "{\"kind\":\"Secret\",\"data\":{\"K\":\"!!!notb64!!!\"}}" of
        Left _ -> pure ()
        Right _ -> assertFailure "expected Left for malformed base64"
  ]
  where
    metaName o = do
      Aeson.Object m <- KeyMap.lookup (Key.fromText "metadata") o
      KeyMap.lookup (Key.fromText "name") m
