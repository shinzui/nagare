-- | Context responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Context
  ( contextGuardTests
  , contextResolutionTests
  , modeResolutionTests
  , targetProfileTests
  )
where

import Control.Exception (IOException, finally, try)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cluster.GcsJob (StoreBackend (MinioBackend))
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Gcp.Adc
  ( AdcObservation
      ( AdcObservation
      , credentialKind
      , principal
      , quotaProject
      , source
      )
  , AdcSource (AdcEnvironmentFile)
  )
import Nagare.Ops.ContextGuard
  ( ProjectGuardInputs (..)
  , PulumiProjectObservation (..)
  , parsePulumiProjectConfig
  , projectGuardObservationsValue
  , projectGuardVerdict
  , renderProjectGuard
  )
import Nagare.Target
  ( ContextName
  , InventoryStoreKind (InventoryStoreLocal)
  , Mode (Cloud, Local)
  , PulumiBackendKind (PulumiBackendLocal)
  , TargetProfile
  , clearCurrentContext
  , contextExists
  , contextFilePath
  , contextNameText
  , deleteContext
  , listContexts
  , mkContextName
  , parseContextEnv
  , parseMode
  , profileFromContextMap
  , readContextProfile
  , readCurrentContext
  , registryPrefix
  , resolveActiveContext
  , resolveActiveTarget
  , resolveTargetProfile
  , setCurrentContext
  , storeBackendFor
  , writeContextPlatformVersion
  )
import Nagare.Test.Support.Assertions (unsafe)
import System.Directory
  ( createDirectoryIfMissing
  , createFileLink
  , getCurrentDirectory
  , pathIsSymbolicLink
  , setCurrentDirectory
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((<.>), (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- ---------------------------------------------------------------------------
-- EP-93: the GCS Pulumi state-bucket bootstrap. Pure bucket derivation + the
-- exact `gcloud storage` argv the idempotent runner (and its dry-run) emit.

-- EP-113: the pure project-confinement comparison behind `nagarectl context
-- guard`. It fails closed on ANY disagreement about which project the next
-- Pulumi operation would write to.
contextGuardTests :: TestTree
contextGuardTests =
  testGroup
    "Nagare.Ops.ContextGuard (EP-113)"
    [ testCase "all three sources agreeing is accepted" $
        projectGuardVerdict (guardInputs (PulumiProjectFound "acme-prod") (Just "acme-prod") (Just "acme-prod"))
          @?= Right ()
    , testCase "an unset stack gcp:project refuses" $
        assertRefusal
          "gcp:project"
          (guardInputs PulumiProjectMissing (Just "acme-prod") (Just "acme-prod"))
    , testCase "a missing Pulumi executable has a tool remedy, not a projection remedy" $ do
        let pgi = guardInputs PulumiToolNotFound (Just "acme-prod") (Just "acme-prod")
        assertRefusal "pulumi was not found on PATH" pgi
        assertRefusal "nagarectl version --tools" pgi
        assertNoRefusal "declares no gcp:project" pgi
        assertNoRefusal "nagarectl context use" pgi
    , testCase "a failed Pulumi command preserves its status and stderr" $ do
        let pgi = guardInputs (PulumiCommandFailed 42 "backend authentication failed") (Just "acme-prod") (Just "acme-prod")
        assertRefusal "status 42" pgi
        assertRefusal "backend authentication failed" pgi
        assertRefusal "nagarectl context env" pgi
        assertNoRefusal "declares no gcp:project" pgi
        assertNoRefusal "nagarectl context use" pgi
    , testCase "invalid Pulumi JSON is diagnosed distinctly" $ do
        let pgi = guardInputs (PulumiProjectInvalidOutput "invalid JSON") (Just "acme-prod") (Just "acme-prod")
        assertRefusal "could not be interpreted" pgi
        assertRefusal "invalid JSON" pgi
        assertNoRefusal "declares no gcp:project" pgi
    , testCase "a Pulumi startup failure preserves the exception" $
        assertRefusal
          "permission denied"
          (guardInputs (PulumiToolStartFailed "permission denied") (Just "acme-prod") (Just "acme-prod"))
    , testCase "a stack targeting another project refuses, naming both" $ do
        let pgi = guardInputs (PulumiProjectFound "some-other-project") (Just "acme-prod") (Just "acme-prod")
        assertRefusal "some-other-project" pgi
        assertRefusal "acme-prod" pgi
    , testCase "an ambient CLOUDSDK_CORE_PROJECT override refuses" $
        assertRefusal
          "CLOUDSDK_CORE_PROJECT"
          (guardInputs (PulumiProjectFound "acme-prod") (Just "some-production-project") (Just "acme-prod"))
    , testCase "a foreign ADC quota project refuses before a skipped Pulumi probe" $ do
        let pgi =
              (guardInputs PulumiProbeSkipped (Just "acme-prod") (Just "acme-prod"))
                { adc =
                    Right
                      AdcObservation
                        { source = AdcEnvironmentFile "/credentials.json"
                        , credentialKind = "authorized_user"
                        , principal = Just "operator@example.com"
                        , quotaProject = Just "foreign-prod"
                        }
                }
        case projectGuardVerdict pgi of
          Right () -> assertFailure "foreign ADC was accepted"
          Left msg -> do
            assertBool "foreign quota" ("foreign-prod" `T.isInfixOf` msg)
            assertBool "repair" ("set-quota-project acme-prod" `T.isInfixOf` msg)
            assertBool "not a Pulumi refusal" (not ("Pulumi inspection was skipped" `T.isInfixOf` msg))
    , testCase "with no ambient override, a disagreeing gcloud config refuses" $
        assertRefusal
          "gcloud's configured project"
          (guardInputs (PulumiProjectFound "acme-prod") Nothing (Just "some-production-project"))
    , testCase "with no ambient override and no gcloud, the stack alone decides" $
        projectGuardVerdict (guardInputs (PulumiProjectFound "acme-prod") Nothing Nothing) @?= Right ()
    , testCase "a missing gcloud alongside a correct ambient value is not a refusal" $
        -- gcloud need not be installed on a machine that only previews.
        projectGuardVerdict (guardInputs (PulumiProjectFound "acme-prod") (Just "acme-prod") Nothing) @?= Right ()
    , testCase "the success line names the context, project and stack" $
        renderProjectGuard (guardInputs (PulumiProjectFound "acme-prod") (Just "acme-prod") (Just "acme-prod"))
          @?= "context guard: labs confined to project acme-prod (stack labs)"
    , testCase "the parser distinguishes found and genuinely absent projects" $ do
        parsePulumiProjectConfig "{\"gcp:project\":{\"value\":\" acme-prod \",\"secret\":false}}"
          @?= Right (PulumiProjectFound "acme-prod")
        parsePulumiProjectConfig "{\"nagare:machineType\":{\"value\":\"e2-standard-2\"}}"
          @?= Right PulumiProjectMissing
    , testCase "the parser rejects malformed JSON and invalid config shapes" $ do
        assertBool "malformed JSON" (isLeft (parsePulumiProjectConfig "{"))
        assertBool "non-object top level" (isLeft (parsePulumiProjectConfig "[]"))
        assertBool "non-object entry" (isLeft (parsePulumiProjectConfig "{\"gcp:project\":\"acme-prod\"}"))
        assertBool "missing value" (isLeft (parsePulumiProjectConfig "{\"gcp:project\":{}}"))
        assertBool "non-text value" (isLeft (parsePulumiProjectConfig "{\"gcp:project\":{\"value\":7}}"))
        assertBool "blank value" (isLeft (parsePulumiProjectConfig "{\"gcp:project\":{\"value\":\"  \"}}"))
    , testCase "JSON observations preserve compatibility and report every probe status" $ do
        let cases =
              [ (PulumiProjectFound "acme-prod", "found", Just (Aeson.String "acme-prod"))
              , (PulumiProjectMissing, "missing", Nothing)
              , (PulumiToolNotFound, "tool-not-found", Nothing)
              , (PulumiCommandFailed 23 "sentinel stderr", "command-failed", Nothing)
              , (PulumiProjectInvalidOutput "bad shape", "invalid-output", Nothing)
              ]
        forM_ cases $ \(observation, status, found) -> do
          let pgi = guardInputs observation (Just "acme-prod") (Just "acme-prod")
          topField "stack" pgi @?= Just (Aeson.String "labs")
          topField "pulumiBackendUrl" pgi @?= Just (Aeson.String "file:///state/labs")
          topField "stackProject" pgi @?= maybe (Just Aeson.Null) Just found
          probeField "status" pgi @?= Just (Aeson.String status)
        let failed = guardInputs (PulumiCommandFailed 23 "sentinel stderr") Nothing Nothing
        probeField "exitCode" failed @?= Just (Aeson.Number 23)
        probeField "stderr" failed @?= Just (Aeson.String "sentinel stderr")
        let invalid = guardInputs (PulumiProjectInvalidOutput "bad shape") Nothing Nothing
        probeField "error" invalid @?= Just (Aeson.String "bad shape")
    ]
  where
    guardInputs stackProject ambient configured =
      ProjectGuardInputs
        { context = "labs"
        , declared = "acme-prod"
        , stack = "labs"
        , pulumiBackendUrl = "file:///state/labs"
        , stackProject = stackProject
        , ambient = ambient
        , configured = configured
        , gcloudAccount = Just "operator@example.com"
        , adc =
            Right
              AdcObservation
                { source = AdcEnvironmentFile "/credentials.json"
                , credentialKind = "authorized_user"
                , principal = Just "operator@example.com"
                , quotaProject = Just "acme-prod"
                }
        }
    assertRefusal needle pgi = case projectGuardVerdict pgi of
      Right () -> assertFailure ("expected a refusal mentioning " <> T.unpack needle)
      Left msg ->
        do
          assertBool
            ("refusal should mention " <> T.unpack needle <> "; got: " <> T.unpack msg)
            (needle `T.isInfixOf` msg)
          assertBool "refusal should name the stack" ("labs" `T.isInfixOf` msg)
          assertBool "refusal should name the backend" ("file:///state/labs" `T.isInfixOf` msg)
    assertNoRefusal needle pgi = case projectGuardVerdict pgi of
      Right () -> assertFailure ("expected a refusal without " <> T.unpack needle)
      Left msg ->
        assertBool
          ("refusal should not mention " <> T.unpack needle <> "; got: " <> T.unpack msg)
          (not (needle `T.isInfixOf` msg))
    topField field pgi = case projectGuardObservationsValue pgi of
      Aeson.Object value -> KeyMap.lookup (Key.fromText field) value
      _ -> Nothing
    probeField field pgi = case topField "stackProjectProbe" pgi of
      Just (Aeson.Object value) -> KeyMap.lookup (Key.fromText field) value
      _ -> Nothing

targetProfileTests :: TestTree
targetProfileTests =
  testCase "resolveTargetProfile honors env vars and falls back to defaults" $ do
    saved <- traverse (\v -> (,) v <$> lookupEnv v) savedVars
    let restore =
          mapM_
            (\(v, m) -> maybe (unsetEnv v) (setEnv v) m)
            saved
    withSystemTempDirectory "nagare-target-store" $ \xdg ->
      flip finally restore $ do
        let clearTargetEnv = do
              mapM_ unsetEnv targetFieldVars
              unsetEnv "NAGARE_MODE"
              unsetEnv "NAGARE_CONTEXT"
              setEnv "XDG_CONFIG_HOME" xdg
        -- (1) nothing set: defaults reproduce the tan-nb-exp worked example.
        clearTargetEnv
        tp0 <- resolveTargetProfile
        tp0 ^. #project @?= "tan-nb-exp"
        tp0 ^. #region @?= "us-west1"
        tp0 ^. #zone @?= "us-west1-a"
        tp0 ^. #registryHost @?= "us-west1-docker.pkg.dev"
        tp0 ^. #imageBucket @?= "tan-nb-exp-nagare-images"
        tp0 ^. #backupBucket @?= "tan-nb-exp-nagare-backups"
        tp0 ^. #nixCacheEnabled @?= False
        tp0 ^. #nixCacheBucket @?= "tan-nb-exp-nagare-nix-cache"
        registryPrefix tp0 @?= "us-west1-docker.pkg.dev/tan-nb-exp/nagare"
        tp0 ^. #targetPlatform @?= "linux/amd64" -- EP-3: default is the node's arch
        tp0 ^. #localObjectStore @?= "" -- EP-84: unset unless local profile sets it
        tp0 ^. #inventoryStore @?= InventoryStoreLocal
        tp0 ^. #machineType @?= "e2-standard-2"
        tp0 ^. #bootDiskType @?= "pd-balanced"
        -- (2) project + region override; host derives from region, buckets from project.
        clearTargetEnv
        setEnv "CLOUDSDK_CORE_PROJECT" "acme-prod"
        setEnv "CLOUDSDK_COMPUTE_REGION" "europe-west1"
        tp1 <- resolveTargetProfile
        tp1 ^. #project @?= "acme-prod"
        tp1 ^. #registryHost @?= "europe-west1-docker.pkg.dev"
        tp1 ^. #backupBucket @?= "acme-prod-nagare-backups"
        registryPrefix tp1 @?= "europe-west1-docker.pkg.dev/acme-prod/nagare"
        -- (3) explicit derived vars win over the derivation.
        clearTargetEnv
        setEnv "CLOUDSDK_CORE_PROJECT" "acme-prod"
        setEnv "NAGARE_REGISTRY_HOST" "custom.registry.example"
        setEnv "NAGARE_BACKUP_BUCKET" "my-bucket"
        tp2 <- resolveTargetProfile
        tp2 ^. #registryHost @?= "custom.registry.example"
        tp2 ^. #backupBucket @?= "my-bucket"
        -- (4) EP-3: NAGARE_TARGET_PLATFORM override wins (env > profile > default),
        -- and an empty value falls back to the default (envOr's empty-is-unset rule).
        clearTargetEnv
        setEnv "NAGARE_TARGET_PLATFORM" "linux/arm64"
        tp3 <- resolveTargetProfile
        tp3 ^. #targetPlatform @?= "linux/arm64"
        setEnv "NAGARE_TARGET_PLATFORM" ""
        tp4 <- resolveTargetProfile
        tp4 ^. #targetPlatform @?= "linux/amd64"
        -- (5) EP-84: NAGARE_LOCAL_OBJECT_STORE resolves verbatim when set.
        clearTargetEnv
        setEnv "NAGARE_LOCAL_OBJECT_STORE" "http://minio:9000/nagare-backups"
        tp5 <- resolveTargetProfile
        tp5 ^. #localObjectStore @?= "http://minio:9000/nagare-backups"
  where
    savedVars = targetFieldVars <> ["NAGARE_MODE", "NAGARE_CONTEXT", "XDG_CONFIG_HOME"]
    targetFieldVars =
      [ "CLOUDSDK_CORE_PROJECT"
      , "CLOUDSDK_COMPUTE_REGION"
      , "CLOUDSDK_COMPUTE_ZONE"
      , "NAGARE_REGISTRY_HOST"
      , "NAGARE_ARTIFACT_REGISTRY_ID"
      , "NAGARE_IMAGE_BUCKET"
      , "NAGARE_BACKUP_BUCKET"
      , "NAGARE_NIX_CACHE_ENABLED"
      , "NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED"
      , "NAGARE_NIX_CACHE_BUCKET"
      , "NAGARE_BASE_DOMAIN"
      , "NAGARE_INSTANCE_NAME"
      , "NAGARE_MACHINE_TYPE"
      , "NAGARE_BOOT_DISK_TYPE"
      , "NAGARE_BOOT_DISK_SIZE_GB"
      , "NAGARE_DATA_DISK_SIZE_GB"
      , "NAGARE_TARGET_PLATFORM"
      , "NAGARE_LOCAL_OBJECT_STORE"
      , "NAGARE_PULUMI_BACKEND"
      , "NAGARE_PULUMI_BACKEND_URL"
      , "NAGARE_PULUMI_BACKEND_MEMBER"
      , "NAGARE_INVENTORY_STORE"
      , "NAGARE_INVENTORY_STORE_URL"
      , "NAGARE_PLATFORM_VERSION"
      ]

contextResolutionTests :: TestTree
contextResolutionTests =
  testGroup
    "Nagare.Target contexts (EP-87)"
    [ testCase "writeContextPlatformVersion keeps a symlinked context file a symlink (EP-116)" $ do
        saved <- lookupEnv "XDG_CONFIG_HOME"
        withSystemTempDirectory "nagare-context-link" $ \root ->
          flip finally (maybe (unsetEnv "XDG_CONFIG_HOME") (setEnv "XDG_CONFIG_HOME") saved) $ do
            let xdg = root </> "config"
                ops = root </> "ops"
                name = either (error . T.unpack) id (mkContextName "labs")
            createDirectoryIfMissing True (xdg </> "nagare" </> "contexts")
            createDirectoryIfMissing True ops
            writeFile (ops </> "labs.env") "export CLOUDSDK_CORE_PROJECT=labs-proj\n"
            setEnv "XDG_CONFIG_HOME" xdg
            link <- contextFilePath name
            createFileLink (ops </> "labs.env") link
            result <- writeContextPlatformVersion name "9.9.9"
            result @?= Right ()
            stillLink <- pathIsSymbolicLink link
            assertBool "context file is still a symlink" stillLink
            target <- TIO.readFile (ops </> "labs.env")
            assertBool "target keeps project" (T.isInfixOf "export CLOUDSDK_CORE_PROJECT=labs-proj\n" target)
            assertBool "target gains version" (T.isInfixOf "export NAGARE_PLATFORM_VERSION=9.9.9\n" target)
    , testCase "resolveActiveContext honors store, pointer, env overrides, local mode, and back-compat" $ do
        saved <- traverse (\v -> (,) v <$> lookupEnv v) savedVars
        originalCwd <- getCurrentDirectory
        let restore = do
              setCurrentDirectory originalCwd
              mapM_ (\(v, m) -> maybe (unsetEnv v) (setEnv v) m) saved
        withSystemTempDirectory "nagare-context-store" $ \xdg ->
          withSystemTempDirectory "nagare-context-cwd" $ \cwd ->
            flip finally restore $ do
              setCurrentDirectory cwd
              setEnv "XDG_CONFIG_HOME" xdg
              createDirectoryIfMissing True (xdg </> "nagare" </> "contexts")
              let clearResolutionEnv = do
                    mapM_ unsetEnv targetFieldVars
                    unsetEnv "NAGARE_MODE"
                    unsetEnv "NAGARE_CONTEXT"
                    setEnv "XDG_CONFIG_HOME" xdg
                  writeContext name body =
                    writeFile (xdg </> "nagare" </> "contexts" </> name <.> "env") body

              writeContext "labs" $
                unlines
                  [ "export CLOUDSDK_CORE_PROJECT=labs-proj"
                  , "export CLOUDSDK_COMPUTE_REGION=europe-west1"
                  , "export NAGARE_PULUMI_BACKEND=local"
                  , "export NAGARE_PULUMI_BACKEND_URL=file:///labs/state"
                  ]
              writeContext "prod" "export CLOUDSDK_CORE_PROJECT=prod-proj\n"

              clearResolutionEnv
              setEnv "NAGARE_CONTEXT" "labs"
              tpLabs <- resolveActiveContext Nothing
              tpLabs ^. #project @?= "labs-proj"
              tpLabs ^. #registryHost @?= "europe-west1-docker.pkg.dev"
              tpLabs ^. #imageBucket @?= "labs-proj-nagare-images"
              atLabs <- resolveActiveTarget Nothing
              contextNameText (atLabs ^. #contextName) @?= "labs"
              atLabs ^. #profile . #project @?= "labs-proj"
              setEnv "NAGARE_PULUMI_BACKEND" "gcs"
              setEnv "NAGARE_PULUMI_BACKEND_URL" "gs://foreign-state/nagare/labs"
              setEnv "NAGARE_NIX_CACHE_ENABLED" "1"
              setEnv "NAGARE_NIX_CACHE_BUCKET" "foreign-cache"
              pinned <- resolveActiveTarget Nothing
              pinned ^. #profile . #pulumiBackend @?= PulumiBackendLocal
              pinned ^. #profile . #pulumiBackendUrl @?= "file:///labs/state"
              pinned ^. #profile . #nixCacheEnabled @?= False
              pinned ^. #profile . #nixCacheBucket @?= "labs-proj-nagare-nix-cache"
              clearResolutionEnv
              setEnv "NAGARE_CONTEXT" "labs"

              tpProd <- resolveActiveContext (Just "prod")
              tpProd ^. #project @?= "prod-proj"

              clearResolutionEnv
              writeFile (xdg </> "nagare" </> "current-context") "labs\n"
              tpPointer <- resolveActiveContext Nothing
              tpPointer ^. #project @?= "labs-proj"

              clearResolutionEnv
              setEnv "NAGARE_CONTEXT" "labs"
              setEnv "CLOUDSDK_CORE_PROJECT" "override-proj"
              tpOverride <- resolveActiveContext Nothing
              tpOverride ^. #project @?= "override-proj"
              tpOverride ^. #region @?= "europe-west1"

              withSystemTempDirectory "nagare-empty-store" $ \emptyXdg -> do
                clearResolutionEnv
                setEnv "XDG_CONFIG_HOME" emptyXdg
                tpDefault <- resolveActiveContext Nothing
                tpDefault ^. #project @?= "tan-nb-exp"
                tpDefault ^. #registryHost @?= "us-west1-docker.pkg.dev"
                setEnv "NAGARE_CONTEXT" "default"
                atDefault <- resolveActiveTarget Nothing
                contextNameText (atDefault ^. #contextName) @?= "default"
                atDefault ^. #profile . #project @?= "tan-nb-exp"

              clearResolutionEnv
              writeContext "local" $
                unlines
                  [ "export NAGARE_MODE=local"
                  , "export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000"
                  , "export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io"
                  , "export NAGARE_LOCAL_OBJECT_STORE=http://minio:9000/nagare-backups"
                  ]
              setEnv "NAGARE_CONTEXT" "local"
              tpLocal <- resolveActiveContext Nothing
              tpLocal ^. #mode @?= Local
              tpLocal ^. #registryHost @?= "k3d-registry.localhost:5000"
              tpLocal ^. #baseDomain @?= "127-0-0-1.sslip.io"
              case storeBackendFor tpLocal (tpLocal ^. #backupBucket) of
                Right MinioBackend {} -> pure ()
                other -> assertFailure ("expected MinioBackend, got " <> show other)

              clearResolutionEnv
              setEnv "NAGARE_CONTEXT" "ghost"
              missing <- try (resolveActiveContext Nothing) :: IO (Either IOException TargetProfile)
              case missing of
                Left _ -> pure ()
                Right tp -> assertFailure ("expected missing context to fail, got " <> show tp)

              parseContextEnv "# comment\n\nexport A=1\nB=two\nC=\"three\"\nD=\n"
                @?= Map.fromList [("A", "1"), ("B", "two"), ("C", "three"), ("D", "")]

              withSystemTempDirectory "nagare-empty-context-value" $ \emptyValueXdg -> do
                setEnv "XDG_CONFIG_HOME" emptyValueXdg
                createDirectoryIfMissing True (emptyValueXdg </> "nagare" </> "contexts")
                writeFile
                  (emptyValueXdg </> "nagare" </> "contexts" </> "empty" <.> "env")
                  "export CLOUDSDK_CORE_PROJECT=\n"
                mapM_ unsetEnv targetFieldVars
                unsetEnv "NAGARE_MODE"
                setEnv "NAGARE_CONTEXT" "empty"
                tpEmpty <- resolveActiveContext Nothing
                tpEmpty ^. #project @?= "tan-nb-exp"

              withSystemTempDirectory "nagare-repo-profile" $ \repoXdg -> do
                clearResolutionEnv
                setEnv "XDG_CONFIG_HOME" repoXdg
                writeFile "nagare.target.env" "export CLOUDSDK_CORE_PROJECT=repo-proj\n"
                tpRepo <- resolveActiveContext Nothing
                tpRepo ^. #project @?= "repo-proj"
    , testCase "store helpers list, read, set current, clear, and delete contexts" $ do
        saved <- traverse (\v -> (,) v <$> lookupEnv v) savedVars
        let restore = mapM_ (\(v, m) -> maybe (unsetEnv v) (setEnv v) m) saved
        withSystemTempDirectory "nagare-context-store-helpers" $ \xdg ->
          flip finally restore $ do
            setEnv "XDG_CONFIG_HOME" xdg
            mapM_ unsetEnv targetFieldVars
            unsetEnv "NAGARE_MODE"
            unsetEnv "NAGARE_CONTEXT"
            let labs = contextName "labs"
                prod = contextName "prod"
            labsPath <- contextFilePath labs
            prodPath <- contextFilePath prod
            createDirectoryIfMissing True (xdg </> "nagare" </> "contexts")
            writeFile labsPath "export CLOUDSDK_CORE_PROJECT=labs-proj\nexport NAGARE_BASE_DOMAIN=labs.example.test\n"
            writeFile prodPath "export CLOUDSDK_CORE_PROJECT=prod-proj\n"
            writeFile (xdg </> "nagare" </> "contexts" </> ".hidden.env") "export CLOUDSDK_CORE_PROJECT=bad\n"

            names <- listContexts
            map contextNameText names @?= ["labs", "prod"]
            contextExists labs >>= (@?= True)
            contextExists (contextName "ghost") >>= (@?= False)

            eLabs <- readContextProfile labs
            case eLabs of
              Left err -> assertFailure (T.unpack err)
              Right tp -> do
                tp ^. #project @?= "labs-proj"
                tp ^. #baseDomain @?= "labs.example.test"

            setCurrentContext labs
            readCurrentContext >>= (@?= Just labs)
            deleteContext labs
            contextExists labs >>= (@?= False)
            readCurrentContext >>= (@?= Just labs)
            clearCurrentContext
            readCurrentContext >>= (@?= Nothing)

            let derived =
                  profileFromContextMap
                    (Map.fromList [("CLOUDSDK_CORE_PROJECT", "derived-proj"), ("CLOUDSDK_COMPUTE_REGION", "asia-northeast1")])
            derived ^. #registryHost @?= "asia-northeast1-docker.pkg.dev"
            derived ^. #imageBucket @?= "derived-proj-nagare-images"
    ]
  where
    savedVars = targetFieldVars <> ["NAGARE_MODE", "NAGARE_CONTEXT", "XDG_CONFIG_HOME"]
    targetFieldVars =
      [ "CLOUDSDK_CORE_PROJECT"
      , "CLOUDSDK_COMPUTE_REGION"
      , "CLOUDSDK_COMPUTE_ZONE"
      , "NAGARE_REGISTRY_HOST"
      , "NAGARE_ARTIFACT_REGISTRY_ID"
      , "NAGARE_IMAGE_BUCKET"
      , "NAGARE_BACKUP_BUCKET"
      , "NAGARE_BASE_DOMAIN"
      , "NAGARE_INSTANCE_NAME"
      , "NAGARE_MACHINE_TYPE"
      , "NAGARE_BOOT_DISK_TYPE"
      , "NAGARE_BOOT_DISK_SIZE_GB"
      , "NAGARE_DATA_DISK_SIZE_GB"
      , "NAGARE_TARGET_PLATFORM"
      , "NAGARE_LOCAL_OBJECT_STORE"
      , "NAGARE_PULUMI_BACKEND"
      , "NAGARE_PULUMI_BACKEND_URL"
      , "NAGARE_PULUMI_BACKEND_MEMBER"
      , "NAGARE_INVENTORY_STORE"
      , "NAGARE_INVENTORY_STORE_URL"
      ]
    contextName :: Text -> ContextName
    contextName = unsafe . mkContextName

-- ---------------------------------------------------------------------------
-- Nagare.Target mode (MasterPlan 16, EP-83): NAGARE_MODE resolves into a typed
-- Mode on the profile. The pure parseMode table needs no environment; the
-- resolveTargetProfile case mutates NAGARE_MODE and restores it with finally.

modeResolutionTests :: TestTree
modeResolutionTests =
  testGroup
    "Nagare.Target mode (EP-83)"
    [ testCase "parseMode: local (any case) is Local, else Cloud" $ do
        parseMode (Just "local") @?= Local
        parseMode (Just "LOCAL") @?= Local
        parseMode (Just "Local") @?= Local
        parseMode (Just "cloud") @?= Cloud
        parseMode (Just "") @?= Cloud
        parseMode (Just "prod") @?= Cloud
        parseMode Nothing @?= Cloud
    , testCase "resolveTargetProfile reads NAGARE_MODE" $ do
        saved <- traverse (\v -> (,) v <$> lookupEnv v) ["NAGARE_MODE", "NAGARE_CONTEXT", "XDG_CONFIG_HOME"]
        let restore =
              mapM_
                (\(v, m) -> maybe (unsetEnv v) (setEnv v) m)
                saved
        withSystemTempDirectory "nagare-mode-store" $ \xdg ->
          flip finally restore $ do
            setEnv "XDG_CONFIG_HOME" xdg
            unsetEnv "NAGARE_CONTEXT"
            unsetEnv "NAGARE_MODE"
            tpC <- resolveTargetProfile
            tpC ^. #mode @?= Cloud
            setEnv "NAGARE_MODE" "local"
            tpL <- resolveTargetProfile
            tpL ^. #mode @?= Local
    ]
