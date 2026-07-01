-- | Tests for nagarectl's static-site helpers (EP-14).
--
-- The CLI proper (load → render → build → push → apply → wait) is validated
-- behaviourally by @nagarectl site deploy --dry-run@ against
-- @cluster/examples/static-site@; the renderer goldens live in
-- @nagare-dsl-test@ (EP-13). These unit tests cover the pure/helper logic that
-- is awkward to exercise through the dry-run: the generated Dockerfile and the
-- build/output-preparation state machine.
module Main (main) where

import AccessGrantsSpec (accessGrantsTests)
import AccessResolveSpec (accessResolveTests)
import AppDeploySpec (appDeployTests)
import Control.Exception (IOException, finally, try)
import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson (eitherDecodeStrict, encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.List (isInfixOf, isSuffixOf, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Nagare.App
  ( AppSummary (..)
  , LogTarget (..)
  , extractAppSummaries
  , extractAppSummary
  , extractDomainsFor
  , formatAppList
  , logArgs
  , parseServiceNames
  , restartPatch
  )
import Nagare.App.Deployments (appConfigMapName, revisionForTag)
import Nagare.Broker.Connection
  ( BrokerConn (..)
  , brokerConnectionEnv
  , mergeBrokerConnectionEnvs
  )
import Nagare.Broker.Create (BrokerCreateParams (..), buildBroker)
import Nagare.Broker.Discover (BrokerRow (..), brokerLabelSelector, extractBrokerRows, formatBrokerTable)
import Nagare.Broker.Health (parsePodReady, parseVictoriaUp)
import Nagare.Broker.Topic (TopicStatus (..), parseTopicDescription, renderTopicPlan, rpkTopicCreateArgs)
import Nagare.Build (applyBuildOverrides, describeBuild)
import Nagare.Cdn.Cloudflare
import Nagare.Cdn.Provision
import Nagare.Cdn.Status
import Nagare.Cluster.GcsJob
  ( MinioRef (..)
  , StoreBackend (..)
  , parseLocalObjectStore
  )
import Nagare.Database.Backup
  ( BackupCronInputs (..)
  , BackupJobInputs (..)
  , backupExt
  , backupRawExt
  , dbBackupKeyPrefix
  , dbBackupObjectPath
  , defaultBackupSchedule
  , renderBackupCronJob
  , renderBackupJob
  )
import Nagare.Database.Connection (ConnIdentity (..), connectionEnv, mergeConnectionEnvs)
import Nagare.Database.Create (DbCreateParams (..), buildDatabase, passwordKey)
import Nagare.Database.Discover (DbRow (..), dbLabelSelector, extractDbRows, formatDbTable)
import Nagare.Database.Restore (RestoreJobInputs (..), isObjectUrl, renderRestoreJob, resolveBackupObject)
import Nagare.Database.Secret
  ( ConnectionParts (..)
  , composeConnectionUrl
  , secretKeysFor
  )
import Nagare.Dsl.Broker
  ( Broker (..)
  , BrokerBinding (..)
  , BrokerProvider (..)
  , BrokerSizing (..)
  , BrokerTopic (..)
  , brokerNameText
  , defaultBrokerSizing
  , defaultBrokerVersion
  , mkBrokerName
  , mkTopicName
  , topicNameText
  )
import Nagare.Dsl.Build (BuildSpec (..), defaultBuild, mkTag)
import Nagare.Dsl.Cdn.Types
import Nagare.Dsl.Database (Engine (..), engineToken, mkDatabaseName)
import Nagare.Dsl.Render (renderService)
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Task
  ( ConcurrencyPolicy (Forbid)
  , RestartPolicy (Never)
  , Task (..)
  , mkSchedule
  , mkTask
  )
import Nagare.Dsl.Types
  ( AccessMode (..)
  , Deployment (..)
  , EnvName
  , EnvScope (..)
  , EnvVar (..)
  , RetentionPolicy (..)
  , ScopedEnvVar (..)
  , Volume (..)
  , defaultPort
  , envNameText
  , mkEnvName
  , mkImageRef
  , mkMountPath
  , mkNamespace
  , mkQuantity
  , mkSecretName
  , mkServiceName
  , mkVolumeName
  , quantityText
  , runtimeScoped
  , scopedEnv
  , secretNameText
  )
import Nagare.Env.BuildArgs (BuildArgWarning (..), assembleBuildArgs)
import Nagare.Env.Dotenv (parseDotenv)
import Nagare.Env.Generated (generatedEnv, mergeGenerated)
import Nagare.Env.Generated qualified as Gen
import Nagare.Env.PreviewOverlay (withPreviewEnvFrom)
import Nagare.Env.Store
import Nagare.GhcEnv (findGhcEnvIn)
import Nagare.Image (DockerAuth (..), dockerAuthPlan, dockerBuildArgs, nixpacksBuildArgs, qualifyImage)
import Nagare.Init
  ( nextStepsText
  , operatorRoles
  , pulumiConfigSetArgs
  , renderTargetEnv
  , seedKeys
  )
import Nagare.Ops.Cleanup
  ( CleanupReport (..)
  , ImagePlan (..)
  , PreviewInfo (..)
  , formatCleanupReport
  , parseCrictlImages
  , pruneReleases
  , selectStalePreviews
  , sumReclaimableBytes
  )
import Nagare.Ops.Doctor
  ( Check (..)
  , Remediation (..)
  , doctorExitOk
  , formatDoctor
  , gradeChecks
  , remediationFor
  )
import Nagare.Ops.Domains
  ( CertState (..)
  , DnsExpectation (..)
  , DomainMapping (..)
  , DomainRow (..)
  , certStateFor
  , dnsExpectationFor
  , extractCertReadiness
  , extractDomainMappings
  , formatDomainList
  )
import Nagare.Ops.Probe
  ( KourierEvidence (..)
  , Probe (..)
  , ProbeStatus (..)
  , gradeArch
  , gradeKourier
  , parseClusterIssuerReady
  , parseConfigDomain
  , parseDeploymentReady
  , parseDfUsage
  , parseKourierIp
  , parseNewestBackupAge
  , parseNodeArch
  , parseNodeExternalIp
  , parseNodeReady
  , parseSkipTagResolvingHosts
  , renderInventory
  , statusLabel
  )
import Nagare.Server.Build
import Nagare.Static.Build
import Nagare.Static.Image (staticDockerfile)
import Nagare.Static.Preview
import Nagare.Static.Release
import Nagare.Static.Webhook
import Nagare.Storage.Discover
  ( PVCRow (..)
  , appPVCLabelSelector
  , extractPVCStatus
  , formatStorageTable
  , pvcName
  )
import Nagare.Storage.Restore (StorageRestoreJobInputs (..), renderStorageRestoreJob)
import Nagare.Storage.Snapshot
  ( SnapshotJobInputs (..)
  , backupExcludedWarnings
  , renderSnapshotJob
  , snapshotObjectPath
  , snapshotsToPrune
  )
import Nagare.Target
  ( ActiveTarget (..)
  , ContextName
  , Mode (..)
  , PulumiEnv (..)
  , TargetProfile (..)
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
  , pulumiEnvFor
  , readContextProfile
  , readCurrentContext
  , registryPrefix
  , resolveActiveContext
  , resolveActiveTarget
  , resolveTargetProfile
  , setCurrentContext
  , storeBackendFor
  )
import Nagare.Task.Discover
  ( AppScope (..)
  , TaskRow (..)
  , extractTaskRows
  , formatTaskTable
  , taskLabelSelector
  )
import Nagare.Task.Logs (TaskLogTarget (..), grafanaHint, taskLogArgs)
import Nagare.Task.Resolve (predefinedTaskEnv, renderResolvedTask, resolveTaskImage)
import Nagare.Task.Run (oneOffJobName, runArgs)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory, setCurrentDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((<.>), (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit
import Test.Tasty.Runners (NumThreads (..))

main :: IO ()
main = do
  taskFixture <- BS.readFile "test/fixtures/cronjob-list.json"
  defaultMain $
    localOption (NumThreads 1) $
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
      , testGroup "Nagare.Env.Generated" generatedEnvTests
      , testGroup "EP-26 render demonstration" renderDemonstrationTests
      , testGroup "Nagare.Env.BuildArgs" buildArgsTests
      , testGroup "Nagare.Env.PreviewOverlay" previewOverlayTests
      , testGroup "Nagare.Ops" opsTests
      , testGroup "Nagare.Ops.Doctor" doctorTests
      , testGroup "Nagare.Ops.Domains" domainsTests
      , testGroup "Nagare.Ops.Cleanup" cleanupTests
      , testGroup "Nagare.App" appTests
      , testGroup "Nagare.App.Deployments" deploymentsTests
      , testGroup "Nagare.Storage.Discover" storageDiscoverTests
      , testGroup "Nagare.Storage.Snapshot" storageSnapshotTests
      , testGroup "GCS data-movement Job hostAliases (EP-1)" gcsJobHostAliasesTests
      , testGroup "Data-movement Job store backend (EP-84)" storeBackendModeTests
      , testGroup "Nagare.GhcEnv (EP-6)" ghcEnvTests
      , testGroup "Nagare.Database (EP-45)" databaseTests
      , testGroup "Nagare.Broker (EP-78)" brokerTests
      , testGroup "Nagare.Broker.Connection (EP-77)" brokerConnectionEnvTests
      , testGroup "Nagare.Database.Connection (EP-46)" connectionEnvTests
      , testGroup "Nagare.Database.Backup/Restore (EP-47)" backupRestoreTests
      , testGroup "Nagare.Task.Discover (EP-51)" (taskDiscoverTests taskFixture)
      , testGroup "Nagare.Task.Run / Logs (EP-51)" taskRunTests
      , testGroup "Nagare.Task.Resolve (EP-52)" taskResolveTests
      , testGroup "Nagare.Cdn (EP-57)" cloudflareTests
      , testGroup "Nagare.Cdn.Provision (EP-58)" cdnProvisionTests
      , testGroup "Nagare.Cdn.Status (EP-58)" cdnStatusTests
      , testGroup "Nagare.Target (EP-62)" [targetProfileTests]
      , contextResolutionTests
      , testGroup "EP-62 rendered Job project" backupProjectTests
      , testGroup "EP-62 qualifyImage" qualifyImageTests
      , modeResolutionTests
      , dockerAuthPlanTests
      , initTests
      , accessGrantsTests
      , accessResolveTests
      , appDeployTests
      ]

-- ---------------------------------------------------------------------------
-- Nagare.Init (MasterPlan 12, EP-63): the pure pieces of `nagarectl init` — the
-- env-file rendering, the eight Pulumi seed keys, the config-set argv, the
-- operator-role list, and the next-steps text.

initProfile :: TargetProfile
initProfile =
  TargetProfile
    { tpProject = "acme-prod"
    , tpRegion = "us-west1"
    , tpZone = "us-west1-a"
    , tpRegistryHost = "us-west1-docker.pkg.dev"
    , tpArtifactRegistryId = "nagare"
    , tpImageBucket = "acme-prod-nagare-images"
    , tpBackupBucket = "acme-prod-nagare-backups"
    , tpBaseDomain = "apps.acme.com"
    , tpInstanceName = "nagare-01"
    , tpTargetPlatform = "linux/amd64"
    , tpMode = Cloud
    , tpLocalObjectStore = ""
    }

initTests :: TestTree
initTests =
  testGroup
    "Nagare.Init (EP-63)"
    [ testCase "renderTargetEnv emits the export lines with the right values" $ do
        let out = renderTargetEnv initProfile
        assertBool "project" (T.isInfixOf "export CLOUDSDK_CORE_PROJECT=acme-prod" out)
        assertBool "derived image bucket" (T.isInfixOf "export NAGARE_IMAGE_BUCKET=acme-prod-nagare-images" out)
        assertBool "base domain" (T.isInfixOf "export NAGARE_BASE_DOMAIN=apps.acme.com" out)
        assertBool "target platform (default)" (T.isInfixOf "export NAGARE_TARGET_PLATFORM=linux/amd64" out)
        assertBool "mode (default cloud)" (T.isInfixOf "export NAGARE_MODE=cloud" out)
        assertBool "local object store (empty for cloud)" (T.isInfixOf "export NAGARE_LOCAL_OBJECT_STORE=" out)
    , testCase "renderTargetEnv emits an overridden target platform (EP-3)" $ do
        let out = renderTargetEnv initProfile {tpTargetPlatform = "linux/arm64"}
        assertBool "target platform (override)" (T.isInfixOf "export NAGARE_TARGET_PLATFORM=linux/arm64" out)
    , testCase "renderTargetEnv emits local context fields for round-trip" $ do
        let out =
              renderTargetEnv
                initProfile
                  { tpMode = Local
                  , tpRegistryHost = "k3d-registry.localhost:5000"
                  , tpBaseDomain = "127-0-0-1.sslip.io"
                  , tpLocalObjectStore = "http://minio:9000/nagare-backups"
                  }
        assertBool "local mode" (T.isInfixOf "export NAGARE_MODE=local" out)
        assertBool "local registry" (T.isInfixOf "export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000" out)
        assertBool "local object store" (T.isInfixOf "export NAGARE_LOCAL_OBJECT_STORE=http://minio:9000/nagare-backups" out)
    , testCase "seedKeys covers the eight Pulumi keys incl. the required imageBucket" $
        map fst (seedKeys initProfile)
          @?= [ "gcp:project"
              , "gcp:region"
              , "gcp:zone"
              , "nagare:baseDomain"
              , "nagare:imageBucket"
              , "nagare:backupBucket"
              , "nagare:artifactRegistryId"
              , "nagare:instanceName"
              ]
    , testCase "pulumiConfigSetArgs targets the active context stack" $
        pulumiConfigSetArgs "labs" "gcp:project" "acme-prod"
          @?= ["-C", "infra/pulumi", "config", "set", "--stack", "labs", "gcp:project", "acme-prod"]
    , testCase "pulumiEnvFor derives per-context backend, home, and stack" $
        pulumiEnvFor "/tmp/nagare-state" "labs"
          @?= PulumiEnv
            { peHome = "/tmp/nagare-state/labs/home"
            , peBackendUrl = "file:///tmp/nagare-state/labs/state"
            , peStack = "labs"
            }
    , testCase "operatorRoles includes serviceUsageAdmin for the enable step" $
        assertBool "serviceUsageAdmin" ("roles/serviceusage.serviceUsageAdmin" `elem` operatorRoles)
    , testCase "nextStepsText names the ordered just targets" $ do
        assertBool "infra-up" (T.isInfixOf "just infra-up" nextStepsText)
        assertBool "host-image" (T.isInfixOf "just host-image" nextStepsText)
    ]

-- ---------------------------------------------------------------------------
-- EP-62 M3: the CLI-side image normalizer. A bare name (no '/') is prefixed
-- with the resolved registry prefix; an already-qualified ref is unchanged.

qualifyImageTests :: [TestTree]
qualifyImageTests =
  [ testCase "bare name is prefixed with the registry prefix" $
      qualifyImage tnbProfile (unsafe (mkImageRef "notes"))
        @?= Right (unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"))
  , testCase "bare name follows a different profile prefix" $
      qualifyImage acmeProfile (unsafe (mkImageRef "notes"))
        @?= Right (unsafe (mkImageRef "europe-west1-docker.pkg.dev/acme-prod/nagare/notes"))
  , testCase "already-qualified public ref is left untouched" $
      qualifyImage tnbProfile (unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go"))
        @?= Right (unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go"))
  ]
  where
    acmeProfile =
      tnbProfile
        { tpProject = "acme-prod"
        , tpRegistryHost = "europe-west1-docker.pkg.dev"
        }

-- ---------------------------------------------------------------------------
-- EP-62: the rendered backup Job's CLOUDSDK_CORE_PROJECT follows the GCS
-- backend's project (fail-before/pass-after evidence: before EP-62 the value was
-- the literal @tan-nb-exp@ regardless of inputs). EP-84 carries the project on
-- 'bjiBackend' ('GcsBackend' project bucket) instead of a separate field.

backupProjectTests :: [TestTree]
backupProjectTests =
  [ testCase "backup Job CLOUDSDK_CORE_PROJECT defaults to tan-nb-exp" $
      assertBool "tan-nb-exp present" ("tan-nb-exp" `T.isInfixOf` rendered "tan-nb-exp")
  , testCase "backup Job CLOUDSDK_CORE_PROJECT follows the resolved project" $ do
      assertBool "acme-prod present" ("acme-prod" `T.isInfixOf` rendered "acme-prod")
      assertBool
        "no tan-nb-exp project leaked"
        (not ("value: tan-nb-exp" `T.isInfixOf` rendered "acme-prod"))
  ]
  where
    rendered project =
      TE.decodeUtf8 (renderBackupJob (backupJobInputsPg {bjiBackend = GcsBackend project "tan-nb-exp-nagare-backups"}))

-- ---------------------------------------------------------------------------
-- Nagare.Target (MasterPlan 12, EP-62): the single GCP-target resolution layer.
-- These assertions mutate the process environment, so they run as ONE sequential
-- testCase (tasty runs cases in parallel) and restore the original environment at
-- the end so no other group observes the mutation.

-- | A fixed 'TargetProfile' carrying the tan-nb-exp worked-example values, for
-- tests that need a profile but assert against the historic defaults (EP-62).
tnbProfile :: TargetProfile
tnbProfile =
  TargetProfile
    { tpProject = "tan-nb-exp"
    , tpRegion = "us-west1"
    , tpZone = "us-west1-a"
    , tpRegistryHost = "us-west1-docker.pkg.dev"
    , tpArtifactRegistryId = "nagare"
    , tpImageBucket = "tan-nb-exp-nagare-images"
    , tpBackupBucket = "tan-nb-exp-nagare-backups"
    , tpBaseDomain = "apps.example.com"
    , tpInstanceName = "nagare-01"
    , tpTargetPlatform = "linux/amd64"
    , tpMode = Cloud
    , tpLocalObjectStore = ""
    }

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
        tpProject tp0 @?= "tan-nb-exp"
        tpRegion tp0 @?= "us-west1"
        tpZone tp0 @?= "us-west1-a"
        tpRegistryHost tp0 @?= "us-west1-docker.pkg.dev"
        tpImageBucket tp0 @?= "tan-nb-exp-nagare-images"
        tpBackupBucket tp0 @?= "tan-nb-exp-nagare-backups"
        registryPrefix tp0 @?= "us-west1-docker.pkg.dev/tan-nb-exp/nagare"
        tpTargetPlatform tp0 @?= "linux/amd64" -- EP-3: default is the node's arch
        tpLocalObjectStore tp0 @?= "" -- EP-84: unset unless local profile sets it
      -- (2) project + region override; host derives from region, buckets from project.
        clearTargetEnv
        setEnv "CLOUDSDK_CORE_PROJECT" "acme-prod"
        setEnv "CLOUDSDK_COMPUTE_REGION" "europe-west1"
        tp1 <- resolveTargetProfile
        tpProject tp1 @?= "acme-prod"
        tpRegistryHost tp1 @?= "europe-west1-docker.pkg.dev"
        tpBackupBucket tp1 @?= "acme-prod-nagare-backups"
        registryPrefix tp1 @?= "europe-west1-docker.pkg.dev/acme-prod/nagare"
      -- (3) explicit derived vars win over the derivation.
        clearTargetEnv
        setEnv "CLOUDSDK_CORE_PROJECT" "acme-prod"
        setEnv "NAGARE_REGISTRY_HOST" "custom.registry.example"
        setEnv "NAGARE_BACKUP_BUCKET" "my-bucket"
        tp2 <- resolveTargetProfile
        tpRegistryHost tp2 @?= "custom.registry.example"
        tpBackupBucket tp2 @?= "my-bucket"
      -- (4) EP-3: NAGARE_TARGET_PLATFORM override wins (env > profile > default),
      -- and an empty value falls back to the default (envOr's empty-is-unset rule).
        clearTargetEnv
        setEnv "NAGARE_TARGET_PLATFORM" "linux/arm64"
        tp3 <- resolveTargetProfile
        tpTargetPlatform tp3 @?= "linux/arm64"
        setEnv "NAGARE_TARGET_PLATFORM" ""
        tp4 <- resolveTargetProfile
        tpTargetPlatform tp4 @?= "linux/amd64"
      -- (5) EP-84: NAGARE_LOCAL_OBJECT_STORE resolves verbatim when set.
        clearTargetEnv
        setEnv "NAGARE_LOCAL_OBJECT_STORE" "http://minio:9000/nagare-backups"
        tp5 <- resolveTargetProfile
        tpLocalObjectStore tp5 @?= "http://minio:9000/nagare-backups"
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
      , "NAGARE_TARGET_PLATFORM"
      , "NAGARE_LOCAL_OBJECT_STORE"
      ]

contextResolutionTests :: TestTree
contextResolutionTests =
  testGroup
    "Nagare.Target contexts (EP-87)"
    [ testCase "resolveActiveContext honors store, pointer, env overrides, local mode, and back-compat" $ do
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
                  ]
              writeContext "prod" "export CLOUDSDK_CORE_PROJECT=prod-proj\n"

              clearResolutionEnv
              setEnv "NAGARE_CONTEXT" "labs"
              tpLabs <- resolveActiveContext Nothing
              tpProject tpLabs @?= "labs-proj"
              tpRegistryHost tpLabs @?= "europe-west1-docker.pkg.dev"
              tpImageBucket tpLabs @?= "labs-proj-nagare-images"
              atLabs <- resolveActiveTarget Nothing
              contextNameText (atContextName atLabs) @?= "labs"
              tpProject (atProfile atLabs) @?= "labs-proj"

              tpProd <- resolveActiveContext (Just "prod")
              tpProject tpProd @?= "prod-proj"

              clearResolutionEnv
              writeFile (xdg </> "nagare" </> "current-context") "labs\n"
              tpPointer <- resolveActiveContext Nothing
              tpProject tpPointer @?= "labs-proj"

              clearResolutionEnv
              setEnv "NAGARE_CONTEXT" "labs"
              setEnv "CLOUDSDK_CORE_PROJECT" "override-proj"
              tpOverride <- resolveActiveContext Nothing
              tpProject tpOverride @?= "override-proj"
              tpRegion tpOverride @?= "europe-west1"

              withSystemTempDirectory "nagare-empty-store" $ \emptyXdg -> do
                clearResolutionEnv
                setEnv "XDG_CONFIG_HOME" emptyXdg
                tpDefault <- resolveActiveContext Nothing
                tpProject tpDefault @?= "tan-nb-exp"
                tpRegistryHost tpDefault @?= "us-west1-docker.pkg.dev"
                setEnv "NAGARE_CONTEXT" "default"
                atDefault <- resolveActiveTarget Nothing
                contextNameText (atContextName atDefault) @?= "default"
                tpProject (atProfile atDefault) @?= "tan-nb-exp"

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
              tpMode tpLocal @?= Local
              tpRegistryHost tpLocal @?= "k3d-registry.localhost:5000"
              tpBaseDomain tpLocal @?= "127-0-0-1.sslip.io"
              case storeBackendFor tpLocal (tpBackupBucket tpLocal) of
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
                tpProject tpEmpty @?= "tan-nb-exp"

              withSystemTempDirectory "nagare-repo-profile" $ \repoXdg -> do
                clearResolutionEnv
                setEnv "XDG_CONFIG_HOME" repoXdg
                writeFile "nagare.target.env" "export CLOUDSDK_CORE_PROJECT=repo-proj\n"
                tpRepo <- resolveActiveContext Nothing
                tpProject tpRepo @?= "repo-proj"
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
                tpProject tp @?= "labs-proj"
                tpBaseDomain tp @?= "labs.example.test"

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
            tpRegistryHost derived @?= "asia-northeast1-docker.pkg.dev"
            tpImageBucket derived @?= "derived-proj-nagare-images"
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
      , "NAGARE_TARGET_PLATFORM"
      , "NAGARE_LOCAL_OBJECT_STORE"
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
            tpMode tpC @?= Cloud
            setEnv "NAGARE_MODE" "local"
            tpL <- resolveTargetProfile
            tpMode tpL @?= Local
    ]

-- ---------------------------------------------------------------------------
-- Nagare.Image.dockerAuthPlan (MasterPlan 16, EP-83): the pure Docker-auth
-- planner. Cloud mode builds the gcloud configure-docker argv; local mode skips
-- it entirely — the machine-checkable form of "zero gcloud calls in local mode".

dockerAuthPlanTests :: TestTree
dockerAuthPlanTests =
  testGroup
    "Nagare.Image.dockerAuthPlan (EP-83)"
    [ testCase "cloud mode builds the gcloud configure-docker argv" $
        dockerAuthPlan Cloud "us-west1-docker.pkg.dev"
          @?= GcloudConfigureDocker
            ["auth", "configure-docker", "us-west1-docker.pkg.dev", "--quiet"]
    , testCase "local mode skips auth — no gcloud argv is constructed" $
        dockerAuthPlan Local "k3d-registry.localhost:5000" @?= SkipDockerAuth
    ]

-- ---------------------------------------------------------------------------
-- Nagare.Task (MasterPlan 10, EP-51): the pure discovery/run/logs helpers.

taskDiscoverTests :: ByteString -> [TestTree]
taskDiscoverTests fixture =
  [ testCase "taskLabelSelector AnyApp omits the app term" $
      taskLabelSelector AnyApp
        @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task"
  , testCase "taskLabelSelector (App notes) appends the app term" $
      taskLabelSelector (App "notes")
        @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task,nagare.dev/app=notes"
  , testCase "taskLabelSelector NoApp appends the not-exists term" $
      taskLabelSelector NoApp
        @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task,!nagare.dev/app"
  , testCase "extractTaskRows parses both managed tasks" $
      case extractTaskRows fixture of
        Left e -> assertFailure (T.unpack e)
        Right rows -> map trName rows @?= ["cleanup", "nightly-report"]
  , testCase "extractTaskRows reads schedule, app, and active count" $
      case extractTaskRows fixture of
        Left e -> assertFailure (T.unpack e)
        Right rows -> do
          let byName n = head (filter ((== n) . trName) rows)
          trApp (byName "cleanup") @?= "notes"
          trSchedule (byName "cleanup") @?= "0 3 * * *"
          trActive (byName "cleanup") @?= 0
          trApp (byName "nightly-report") @?= "-"
          trLastRun (byName "nightly-report") @?= "never"
          trActive (byName "nightly-report") @?= 1
  , testCase "extractTaskRows on empty shape is Right []" $
      extractTaskRows "{\"items\":[]}" @?= Right []
  , testCase "formatTaskTable empty prints the placeholder" $
      formatTaskTable [] @?= "(no scheduled tasks)\n"
  ]

taskRunTests :: [TestTree]
taskRunTests =
  [ testCase "oneOffJobName is deterministic and prefixed" $
      oneOffJobName "cleanup" fixedTime
        @?= "nagare-task-cleanup-manual-20260610030012"
  , testCase "oneOffJobName lower-cases and truncates to 63 chars" $
      let n = oneOffJobName (T.replicate 80 "A") fixedTime
       in (T.length n <= 63 && n == T.toLower n) @?= True
  , testCase "runArgs builds the --from=cronjob create-job vector" $
      runArgs "personal" "cleanup" "nagare-task-cleanup-manual-20260610030012"
        @?= [ "create"
            , "job"
            , "nagare-task-cleanup-manual-20260610030012"
            , "--from=cronjob/nagare-task-cleanup"
            , "-n"
            , "personal"
            ]
  , testCase "taskLogArgs scopes by app and honours --tail/--follow" $
      taskLogArgs
        TaskLogTarget
          { tltNamespace = "personal"
          , tltTask = "cleanup"
          , tltScope = App "notes"
          , tltFollow = True
          , tltTail = Just 20
          }
        @?= [ "logs"
            , "-l"
            , "nagare.dev/task=cleanup,nagare.dev/app=notes"
            , "-n"
            , "personal"
            , "--tail"
            , "20"
            , "--follow"
            ]
  , testCase "taskLogArgs NoApp uses the not-exists term, no tail/follow" $
      taskLogArgs
        TaskLogTarget
          { tltNamespace = "personal"
          , tltTask = "nightly-report"
          , tltScope = NoApp
          , tltFollow = False
          , tltTail = Nothing
          }
        @?= [ "logs"
            , "-l"
            , "nagare.dev/task=nightly-report,!nagare.dev/app"
            , "-n"
            , "personal"
            ]
  , testCase "grafanaHint embeds the EP-49-verified LogsQL field" $
      grafanaHint "cleanup"
        @?= "For older runs, query VictoriaLogs in Grafana with: kubernetes.pod_labels.nagare.dev/task:=\"cleanup\""
  ]
  where
    fixedTime = UTCTime (fromGregorian 2026 6 10) (secondsToDiffTime (3 * 3600 + 12))

-- MasterPlan 10, EP-52: deploy-time image/env resolution for app-associated tasks.

taskResolveTests :: [TestTree]
taskResolveTests =
  [ testCase "inheriting task uses the app's resolved image:tag verbatim" $
      resolveTaskImage appImg tag inheritTask @?= "gcr.io/myproject/notes:20260602-120000"
  , testCase "explicit-image task is pinned to the deploy tag" $
      resolveTaskImage appImg tag ownImageTask @?= "gcr.io/myproject/other:20260602-120000"
  , testCase "predefined env keys for an app task" $
      Set.fromList (map envNameText (Map.keys (predefinedTaskEnv inheritTask)))
        @?= Set.fromList ["NAGARE_TASK_NAME", "NAGARE_NAMESPACE", "NAGARE_APP"]
  , testCase "standalone task gets no NAGARE_APP" $
      Map.member (unsafe (mkEnvName "NAGARE_APP")) (predefinedTaskEnv ownImageTask) @?= False
  , testCase "resolved CronJob shows tag, both envFrom, app label, NAGARE_RUN_ID" $ do
      let yaml = renderResolvedTask appImg tag withPredef inheritTask
      assertInfix "image: gcr.io/myproject/notes:20260602-120000" yaml
      assertInfix "nagare-env-notes-runtime" yaml
      assertInfix "nagare-secret-notes-runtime" yaml
      assertInfix "nagare.dev/app: notes" yaml
      assertInfix "NAGARE_TASK_NAME" yaml
      assertInfix "NAGARE_RUN_ID" yaml
      assertInfix "metadata.name" yaml
  , goldenVsString
      "renderResolvedTask app-associated"
      "test/golden/task-app-resolved.cronjob.yaml"
      (pure (LBS.fromStrict (renderResolvedTask appImg tag withPredef inheritTask)))
  ]
  where
    appImg = "gcr.io/myproject/notes:20260602-120000"
    tag = "20260602-120000"
    withPredef tk = tk {taskEnv = mergeGenerated (predefinedTaskEnv tk) (taskEnv tk)}
    assertInfix needle hay =
      assertBool
        ("expected " <> show needle <> " in:\n" <> T.unpack (TE.decodeUtf8 hay))
        (needle `T.isInfixOf` TE.decodeUtf8 hay)
    inheritTask =
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
    ownImageTask =
      unsafe $
        mkTask
          inheritTask
            { taskImage = Just (unsafe (mkImageRef "gcr.io/myproject/other"))
            , taskApp = Nothing
            }

-- ---------------------------------------------------------------------------
-- Nagare.Ops (MasterPlan 8, EP-38): the pure probe parsers and the formatter.

opsTests :: [TestTree]
opsTests =
  [ testCase "parseNodeReady: Ready=True node" $
      parseNodeReady nodeReadyJson @?= Just True
  , testCase "parseNodeReady: Ready=False node" $
      parseNodeReady nodeNotReadyJson @?= Just False
  , testCase "parseNodeReady: malformed JSON" $
      parseNodeReady "{not json" @?= Nothing
  , testCase "parseDeploymentReady: available single object" $
      parseDeploymentReady deployReadyJson "controller" @?= Just True
  , testCase "parseDeploymentReady: zero replicas" $
      parseDeploymentReady deployUnavailableJson "controller" @?= Just False
  , testCase "parseKourierIp: ingress present" $
      parseKourierIp kourierJson @?= Just "34.83.0.1"
  , testCase "parseKourierIp: no ingress yet" $
      parseKourierIp kourierPendingJson @?= Nothing
  , -- EP-4 M1: Kourier ingress correctness
    testCase "parseNodeExternalIp: extracts the ExternalIP address" $
      parseNodeExternalIp nodeAddrsJson @?= Just "34.145.74.203"
  , testCase "parseNodeExternalIp: Nothing when only InternalIP advertised" $
      parseNodeExternalIp nodeInternalOnlyJson @?= Nothing
  , testCase "gradeKourier: reachable (curl 404) -> OK" $
      probeStatus (gradeKourier (KourierEvidence (Just "10.10.0.4") (Just "34.145.74.203") (Just "404") Nothing)) @?= StatusOk
  , testCase "gradeKourier: no curl, node ExternalIP fronts publicIp -> OK" $
      probeStatus (gradeKourier (KourierEvidence (Just "10.10.0.4") (Just "34.145.74.203") Nothing (Just "34.145.74.203"))) @?= StatusOk
  , testCase "gradeKourier: no curl, node ExternalIP differs from publicIp -> FAIL" $
      probeStatus (gradeKourier (KourierEvidence (Just "10.10.0.4") (Just "34.145.74.203") Nothing (Just "9.9.9.9"))) @?= StatusFail
  , testCase "gradeKourier: inconclusive (no curl, no node ExternalIP) -> WARN not FAIL" $
      probeStatus (gradeKourier (KourierEvidence (Just "10.10.0.4") (Just "34.145.74.203") Nothing Nothing)) @?= StatusWarn
  , testCase "gradeKourier: no LB EXTERNAL-IP -> FAIL" $
      probeStatus (gradeKourier (KourierEvidence Nothing (Just "34.145.74.203") Nothing Nothing)) @?= StatusFail
  , -- EP-4 M2: private-image-pull check
    testCase "parseSkipTagResolvingHosts: host present" $
      parseSkipTagResolvingHosts configDeploymentJson @?= Just ["kind.local", "ko.local", "dev.local", "us-west1-docker.pkg.dev"]
  , testCase "parseSkipTagResolvingHosts: absent key -> Just []" $
      parseSkipTagResolvingHosts "{\"data\":{\"other\":\"x\"}}" @?= Just []
  , testCase "parseSkipTagResolvingHosts: malformed JSON -> Nothing" $
      parseSkipTagResolvingHosts "{not json" @?= Nothing
  , -- EP-4 M3: build/node architecture check
    testCase "parseNodeArch: extracts amd64" $
      parseNodeArch nodeArchJson @?= Just "amd64"
  , testCase "parseNodeArch: malformed JSON -> Nothing" $
      parseNodeArch "{not json" @?= Nothing
  , testCase "gradeArch: linux/amd64 on amd64 node -> OK" $
      probeStatus (gradeArch "linux/amd64" "amd64") @?= StatusOk
  , testCase "gradeArch: linux/arm64 on amd64 node -> WARN" $
      probeStatus (gradeArch "linux/arm64" "amd64") @?= StatusWarn
  , testCase "gradeArch: linux/arm64/v8 on arm64 node -> OK (ignores variant)" $
      probeStatus (gradeArch "linux/arm64/v8" "arm64") @?= StatusOk
  , testCase "parseConfigDomain: returns the domain key, skips _example" $
      parseConfigDomain configDomainJson @?= Just "apps.example.com"
  , testCase "parseClusterIssuerReady: Ready=True" $
      parseClusterIssuerReady clusterIssuerJson @?= Just True
  , testCase "parseNewestBackupAge: picks the max timestamp, ignores TOTAL:" $
      parseNewestBackupAge gsutilLs @?= Just "2026-06-09T03:00:01Z"
  , testCase "parseNewestBackupAge: empty prefix" $
      parseNewestBackupAge "" @?= Nothing
  , testCase "parseDfUsage: data mount" $
      parseDfUsage dfOutput "/var/lib/nagare" @?= Just "12% of 100G"
  , testCase "parseDfUsage: boot mount" $
      parseDfUsage dfOutput "/" @?= Just "24% of 100G"
  , testCase "parseDfUsage: absent mount" $
      parseDfUsage dfOutput "/nope" @?= Nothing
  , testCase "statusLabel covers every constructor" $
      map statusLabel [StatusOk, StatusWarn, StatusUnknown, StatusFail]
        @?= ["OK", "WARN", "UNKNOWN", "FAIL"]
  , testCase "renderInventory aligns STATUS/CHECK/DETAIL" $
      renderInventory [Probe "VM" StatusOk "RUNNING", Probe "k3s node" StatusFail "NotReady"]
        @?= T.unlines
          [ "  STATUS   CHECK                    DETAIL"
          , "  OK       VM                       RUNNING"
          , "  FAIL     k3s node                 NotReady"
          ]
  ]
  where
    nodeReadyJson =
      "{\"items\":[{\"status\":{\"conditions\":[{\"type\":\"MemoryPressure\",\"status\":\"False\"},{\"type\":\"Ready\",\"status\":\"True\"}]}}]}"
    nodeNotReadyJson =
      "{\"items\":[{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\"}]}}]}"
    deployReadyJson =
      "{\"metadata\":{\"name\":\"controller\"},\"status\":{\"availableReplicas\":1,\"conditions\":[{\"type\":\"Available\",\"status\":\"True\"}]}}"
    deployUnavailableJson =
      "{\"metadata\":{\"name\":\"controller\"},\"status\":{\"availableReplicas\":0,\"conditions\":[{\"type\":\"Available\",\"status\":\"False\"}]}}"
    kourierJson =
      "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"34.83.0.1\"}]}}}"
    kourierPendingJson =
      "{\"status\":{\"loadBalancer\":{}}}"
    nodeAddrsJson =
      "{\"items\":[{\"status\":{\"addresses\":[{\"type\":\"InternalIP\",\"address\":\"10.10.0.4\"},{\"type\":\"ExternalIP\",\"address\":\"34.145.74.203\"}]}}]}"
    nodeInternalOnlyJson =
      "{\"items\":[{\"status\":{\"addresses\":[{\"type\":\"InternalIP\",\"address\":\"10.10.0.4\"}]}}]}"
    configDeploymentJson =
      "{\"data\":{\"registriesSkippingTagResolving\":\"kind.local,ko.local,dev.local,us-west1-docker.pkg.dev\"}}"
    nodeArchJson =
      "{\"items\":[{\"status\":{\"nodeInfo\":{\"architecture\":\"amd64\"}}}]}"
    configDomainJson =
      "{\"data\":{\"_example\":\"## docs ##\",\"apps.example.com\":\"\"}}"
    clusterIssuerJson =
      "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
    gsutilLs =
      T.unlines
        [ "      1234  2026-06-08T03:00:01Z  gs://b/postgres/dump-20260608.sql.gz"
        , "      5678  2026-06-09T03:00:01Z  gs://b/postgres/dump-20260609.sql.gz"
        , "TOTAL: 2 objects, 6912 bytes"
        ]
    dfOutput =
      T.unlines
        [ "Filesystem      Size  Used Avail Use% Mounted on"
        , "/dev/sda1       100G   24G   76G  24% /"
        , "/dev/sdb        100G   12G   88G  12% /var/lib/nagare"
        ]

-- ---------------------------------------------------------------------------
-- Nagare.Ops.Cleanup (MasterPlan 8, EP-41): the pure selectors, image parsers,
-- and report formatter (every selector deterministic — `now`/keep passed in).

cleanupTests :: [TestTree]
cleanupTests =
  [ testCase "pruneReleases: 14-entry log, keep 10 -> 10 kept, 4 removed" $
      let logv = StaticReleaseLog (Just "r14") (map mkRel [14, 13 .. 1])
          (trimmed, removed) = pruneReleases 10 logv
       in (length (releases trimmed), length removed) @?= (10, 4)
  , testCase "pruneReleases: keeps current even when it is the oldest record" $
      let logv = StaticReleaseLog (Just "r1") (map mkRel [14, 13 .. 1])
          (trimmed, removed) = pruneReleases 3 logv
       in do
            assertBool "current kept" ("r1" `elem` map releaseId (releases trimmed))
            assertBool "current not removed" ("r1" `notElem` map releaseId removed)
            length removed @?= 10
  , testCase "pruneReleases: nothing to trim when keep >= length" $
      let logv = StaticReleaseLog (Just "r3") (map mkRel [3, 2, 1])
       in snd (pruneReleases 10 logv) @?= []
  , testCase "selectStalePreviews: picks exactly entries past the TTL" $
      let now = UTCTime (fromGregorian 2026 6 9) 0
          ttl = 7 * 86400
          ps =
            [ mkPreview "site-pr-fresh" (fromGregorian 2026 6 8) -- 1d
            , mkPreview "site-pr-stale9" (fromGregorian 2026 5 31) -- 9d
            , mkPreview "site-pr-stale21" (fromGregorian 2026 5 19) -- 21d
            ]
       in map previewName (selectStalePreviews now ttl ps) @?= ["site-pr-stale9", "site-pr-stale21"]
  , testCase "parseCrictlImages: parses rows, skips header/blank" $
      parseCrictlImages crictlFixture
        @?= [ ImagePlan "docker.io/library/nginx" 142000000
            , ImagePlan "registry.k8s.io/pause" 744000
            ]
  , testCase "sumReclaimableBytes: totals the rows" $
      sumReclaimableBytes (parseCrictlImages crictlFixture) @?= 142744000
  , testCase "formatCleanupReport: dry run ends with the dry-run notice" $ do
      let out = formatCleanupReport (dryReport False)
      assertBool "dry header" ("cleanup (dry run)" `T.isInfixOf` out)
      assertBool "dry-run notice" ("re-run with --confirm to apply" `T.isInfixOf` out)
      assertBool "no done." (not ("done." `T.isInfixOf` out))
  , testCase "formatCleanupReport: confirmed ends with done., no dry-run notice" $ do
      let out = formatCleanupReport (dryReport True)
      assertBool "applied header" ("cleanup (applied)" `T.isInfixOf` out)
      assertBool "done." ("done." `T.isInfixOf` out)
      assertBool "no dry-run notice" (not ("re-run with --confirm" `T.isInfixOf` out))
  ]
  where
    mkRel :: Int -> StaticRelease
    mkRel n =
      StaticRelease
        { releaseId = "r" <> T.pack (show n)
        , siteName = "notes"
        , namespace = "personal"
        , image = "img"
        , imageTag = "r" <> T.pack (show n)
        , url = "http://x"
        , source = Nothing
        , createdAt = UTCTime (fromGregorian 2026 6 1) 0
        }
    mkPreview nm day = PreviewInfo nm "personal" (UTCTime day 0)
    crictlFixture =
      TE.encodeUtf8 $
        T.unlines
          [ "IMAGE                          TAG       IMAGE ID       SIZE"
          , "docker.io/library/nginx        latest    abc            142MB"
          , "registry.k8s.io/pause          3.9       def            744kB"
          , ""
          ]
    dryReport confirmed =
      CleanupReport
        { reportImages = Just (12, 3650722201)
        , reportStalePreviews = [mkPreview "site-pr-old" (fromGregorian 2026 5 1)]
        , reportTrimmedReleases = [("notes", [mkRel 1])]
        , reportConfirmed = confirmed
        }

-- ---------------------------------------------------------------------------
-- Nagare.Ops.Domains (MasterPlan 8, EP-40): the pure DomainMapping/Certificate
-- extractors, the computed DNS expectation, and the table formatter.

domainsTests :: [TestTree]
domainsTests =
  [ testCase "extractDomainMappings decodes host/service/ready" $
      extractDomainMappings domainMappingJson
        @?= Right
          [ DomainMapping "blog.apps.example.com" (Just "blog") (Just True)
          , DomainMapping "app.nadeem.dev" (Just "shop") (Just False)
          ]
  , testCase "extractDomainMappings malformed -> Left" $
      assertBool "Left" (isLeft (extractDomainMappings "{not json"))
  , testCase "extractDomainMappings empty list -> Right []" $
      extractDomainMappings "{\"items\":[]}" @?= Right []
  , testCase "extractCertReadiness pulls (dnsName, ready) per name" $
      extractCertReadiness certJson
        @?= Right [("*.personal.apps.example.com", True), ("apps.example.com", True)]
  , testCase "extractCertReadiness absent/empty -> Right []" $
      extractCertReadiness "{\"items\":[]}" @?= Right []
  , testCase "dnsExpectationFor: apex is under the wildcard" $
      dnsExpectationFor "apps.example.com" "34.83.0.1" "apps.example.com"
        @?= UnderWildcard "34.83.0.1"
  , testCase "dnsExpectationFor: one-label subdomain is under the wildcard" $
      dnsExpectationFor "apps.example.com" "34.83.0.1" "blog.apps.example.com"
        @?= UnderWildcard "34.83.0.1"
  , testCase "dnsExpectationFor: two-label subdomain is outside" $
      dnsExpectationFor "apps.example.com" "34.83.0.1" "a.b.apps.example.com"
        @?= OutsideWildcard
  , testCase "dnsExpectationFor: unrelated domain is outside" $
      dnsExpectationFor "apps.example.com" "34.83.0.1" "app.nadeem.dev"
        @?= OutsideWildcard
  , testCase "certStateFor: wildcard cert matches a subdomain (ready)" $
      certStateFor [("*.personal.apps.example.com", True)] "blog.personal.apps.example.com"
        @?= CertReady
  , testCase "certStateFor: matching but not ready -> pending" $
      certStateFor [("app.nadeem.dev", False)] "app.nadeem.dev"
        @?= CertPending
  , testCase "certStateFor: no match -> disabled" $
      certStateFor [] "app.nadeem.dev" @?= CertDisabled
  , testCase "formatDomainList: aligned base + app rows golden" $
      formatDomainList
        [ DomainRow "apps.example.com" Nothing Nothing (UnderWildcard "34.83.0.1") CertDisabled
        , DomainRow "blog.apps.example.com" (Just "blog") (Just True) (UnderWildcard "34.83.0.1") CertReady
        , DomainRow "app.nadeem.dev" (Just "shop") (Just True) OutsideWildcard CertPending
        ]
        @?= T.unlines
          [ "  DOMAIN                          SERVICE         DNS                               CERT"
          , "  apps.example.com                (base)          *.apps.example.com A -> 34.83.0.1 disabled"
          , "  blog.apps.example.com           blog            *.apps.example.com A -> 34.83.0.1 Ready"
          , "  app.nadeem.dev                  shop            (outside wildcard)                pending"
          ]
  , testCase "formatDomainList: empty -> (no domains)" $
      formatDomainList [] @?= "(no domains)\n"
  ]
  where
    domainMappingJson =
      "{\"items\":[\
      \{\"metadata\":{\"name\":\"blog.apps.example.com\"},\"spec\":{\"ref\":{\"name\":\"blog\"}},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}},\
      \{\"metadata\":{\"name\":\"app.nadeem.dev\"},\"spec\":{\"ref\":{\"name\":\"shop\"}},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\"}]}}\
      \]}"
    certJson =
      "{\"items\":[{\"spec\":{\"dnsNames\":[\"*.personal.apps.example.com\",\"apps.example.com\"]},\
      \\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}]}"

-- ---------------------------------------------------------------------------
-- Nagare.Ops.Doctor (MasterPlan 8, EP-39): the pure remediation knowledge base,
-- the checklist renderer, and the exit grade.

doctorTests :: [TestTree]
doctorTests =
  [ testCase "remediationFor: OK probe has no hint" $
      remediationFor tnbProfile (Probe "VM" StatusOk "RUNNING") @?= Nothing
  , testCase "remediationFor: VM FAIL -> gcloud start" $
      cmdOf (Probe "VM" StatusFail "TERMINATED")
        `containsT` "gcloud compute instances start nagare-01 --zone=us-west1-a"
  , testCase "remediationFor: k3s node FAIL -> kubectl context hint" $
      cmdOf (Probe "k3s node" StatusFail "NotReady")
        `containsT` "retrieve the k3s kubeconfig per docs/runbooks/cluster-access.md"
  , testCase "remediationFor: Knative controller FAIL -> rollout status" $
      cmdOf (Probe "Knative controller" StatusFail "not rolled out")
        `containsT` "kubectl rollout status deploy/controller -n knative-serving"
  , testCase "remediationFor: cert-manager-cainjector FAIL -> cert-manager target" $
      cmdOf (Probe "cert-manager-cainjector" StatusFail "not rolled out")
        `containsT` "deploy/cert-manager-cainjector -n cert-manager"
  , testCase "remediationFor: Kourier ingress FAIL -> curl reachability + publicIp" $ do
      let c = cmdOf (Probe "Kourier ingress" StatusFail "node ExternalIP 1.2.3.4 != publicIp 5.6.7.8")
      c `containsT` "stack output publicIp"
      c `containsT` "curl"
  , testCase "remediationFor: private image pull WARN -> EP-2 mechanism pointer" $
      cmdOf (Probe "private image pull" StatusWarn "us-west1-docker.pkg.dev not configured for private pull")
        `containsT` "docs/plans/66"
  , testCase "remediationFor: build platform WARN -> set NAGARE_TARGET_PLATFORM" $
      cmdOf (Probe "build platform" StatusWarn "linux/arm64 will not run on amd64 node")
        `containsT` "NAGARE_TARGET_PLATFORM"
  , testCase "remediationFor: base domain WARN -> re-render config-domain" $
      cmdOf (Probe "base domain" StatusWarn "x != Pulumi y")
        `containsT` "stack output baseDomain"
  , testCase "remediationFor: Artifact Registry -> configure-docker" $
      cmdOf (Probe "Artifact Registry" StatusUnknown "gcloud unavailable")
        `containsT` "gcloud auth configure-docker us-west1-docker.pkg.dev"
  , testCase "remediationFor: data disk WARN -> cleanup pointer" $
      cmdOf (Probe "data disk" StatusWarn "92% of 100G")
        `containsT` "nagarectl cleanup"
  , testCase "remediationFor: backup WARN -> nagarectl db backup" $
      cmdOf (Probe "backup postgres" StatusWarn "newest object 9d ago")
        `containsT` "nagarectl db backup"
  , testCase "remediationFor: UNKNOWN -> 'could not check' why" $
      whyOf (Probe "k3s node" StatusUnknown "no kubeconfig / not reachable")
        `startsWithT` "could not check"
  , testCase "remediationFor: uncatalogued non-OK probe gets a generic hint" $
      cmdOf (Probe "mystery" StatusFail "boom") @?= "see docs/runbooks/"
  , testCase "doctorExitOk: False iff any FAIL" $
      doctorExitOk (gradeChecks tnbProfile [Probe "VM" StatusOk "RUNNING", Probe "k3s node" StatusFail "NotReady"])
        @?= False
  , testCase "doctorExitOk: True when only OK/WARN" $
      doctorExitOk (gradeChecks tnbProfile [Probe "VM" StatusOk "RUNNING", Probe "backup postgres" StatusWarn "9d ago"])
        @?= True
  , testCase "formatDoctor: header, FAIL tag, fix line, and summary" $ do
      let out = formatDoctor (gradeChecks tnbProfile [Probe "VM" StatusFail "TERMINATED", Probe "k3s node" StatusOk "Ready"])
      assertBool "header" ("nagare doctor — 2 checks" `T.isInfixOf` out)
      assertBool "FAIL tag" ("[FAIL]" `T.isInfixOf` out)
      assertBool "fix line" ("fix: gcloud compute instances start" `T.isInfixOf` out)
      assertBool "summary" ("1 failed, 0 warnings, 1 ok." `T.isInfixOf` out)
  ]
  where
    cmdOf p = maybe "" remCommand (remediationFor tnbProfile p)
    whyOf p = maybe "" remWhy (remediationFor tnbProfile p)
    containsT hay needle = assertBool (T.unpack needle) (needle `T.isInfixOf` hay)
    startsWithT hay needle = assertBool (T.unpack needle) (needle `T.isPrefixOf` hay)

-- ---------------------------------------------------------------------------
-- Nagare.Storage.Snapshot (EP-36)

storageSnapshotTests :: [TestTree]
storageSnapshotTests =
  [ testCase "snapshotObjectPath builds volumes/<app>/<volume>/<ts>.tar.gz" $
      snapshotObjectPath "myapp" "data" "20260609T141503Z"
        @?= "volumes/myapp/data/20260609T141503Z.tar.gz"
  , testCase "snapshotsToPrune keeps the newest N and returns the oldest (newest-first)" $
      snapshotsToPrune 7 nineStamps
        @?= [ "gs://b/volumes/a/d/20260602T000000Z.tar.gz"
            , "gs://b/volumes/a/d/20260601T000000Z.tar.gz"
            ]
  , testCase "snapshotsToPrune is idempotent on an already-pruned set" $
      snapshotsToPrune 7 (drop 2 (reverse nineStamps)) @?= []
  , testCase "snapshotsToPrune keeps everything when count <= N" $
      snapshotsToPrune 7 (take 3 nineStamps) @?= []
  , testCase "backupExcludedWarnings warns for exactly the Delete volume" $
      backupExcludedWarnings "myapp" [mkVolWith Retain "data" "/data", mkVolWith Delete "cache" "/cache"]
        @?= ["warning: volume 'cache' on app 'myapp' is NOT backed up (backup excluded in config)"]
  , testCase "backupExcludedWarnings is empty when all volumes are Retain" $
      backupExcludedWarnings "myapp" [mkVolWith Retain "data" "/data"] @?= []
  ]
  where
    -- Nine fixed-width timestamps; lexicographic == chronological.
    nineStamps =
      [ "gs://b/volumes/a/d/2026060" <> T.pack (show d) <> "T000000Z.tar.gz"
      | d <- [1 .. 9 :: Int]
      ]

-- | A 'Volume' with an explicit 'RetentionPolicy' for the backup-policy tests.
mkVolWith :: RetentionPolicy -> Text -> Text -> Volume
mkVolWith ret n mp =
  Volume
    { volName = orError (mkVolumeName n)
    , size = orError (mkQuantity "1Gi")
    , mountPath = orError (mkMountPath mp)
    , accessMode = ReadWriteOnce
    , readOnly = False
    , retention = ret
    }
  where
    orError = either (error . T.unpack) id

-- ---------------------------------------------------------------------------
-- Nagare.Storage.Discover (EP-35)

-- | Build a known-valid 'Volume' for the storage tests.
mkVol :: Text -> Text -> Text -> Volume
mkVol n sz mp =
  Volume
    { volName = orError (mkVolumeName n)
    , size = orError (mkQuantity sz)
    , mountPath = orError (mkMountPath mp)
    , accessMode = ReadWriteOnce
    , readOnly = False
    , retention = Retain
    }
  where
    orError = either (error . T.unpack) id

storageDiscoverTests :: [TestTree]
storageDiscoverTests =
  [ testCase "appPVCLabelSelector builds the app selector" $
      appPVCLabelSelector "myapp" @?= "nagare.dev/app=myapp"
  , testCase "pvcName is the deterministic nagare-vol-<app>-<vol> form" $
      pvcName "myapp" "data" @?= "nagare-vol-myapp-data"
  , testCase "extractPVCStatus reads one item into a row" $
      extractPVCStatus (BC.pack pvcListJSON)
        @?= Right
          [ PVCRow
              { prVolume = "data"
              , prName = "nagare-vol-myapp-data"
              , prSize = "1Gi"
              , prStatus = "Bound"
              , prPvName = "pvc-abc123"
              , prNodePath = ""
              }
          ]
  , testCase "extractPVCStatus of empty items is []" $
      extractPVCStatus (BC.pack "{\"items\":[]}") @?= Right []
  , testCase "extractPVCStatus of malformed JSON is Left" $
      case extractPVCStatus (BC.pack "not json") of
        Left _ -> pure ()
        Right r -> assertFailure ("expected Left, got: " <> show r)
  , testCase "formatStorageTable marks a declared-but-missing volume MISSING" $ do
      let vols = [mkVol "data" "1Gi" "/data", mkVol "logs" "2Gi" "/logs"]
          rows =
            [ PVCRow
                { prVolume = "data"
                , prName = "nagare-vol-myapp-data"
                , prSize = "1Gi"
                , prStatus = "Bound"
                , prPvName = "pvc-abc123"
                , prNodePath = "/var/lib/nagare/local-path/pvc-abc123"
                }
            ]
          out = formatStorageTable "myapp" vols rows
      assertInfix "VOLUME" out
      assertInfix "Bound" out
      assertInfix "MISSING" out
      assertInfix "nagare-vol-myapp-logs" out
  ]
  where
    assertInfix needle hay =
      assertBool ("expected " <> show needle <> " in:\n" <> T.unpack hay) (needle `T.isInfixOf` hay)
    pvcListJSON =
      "{\"items\":[{\"metadata\":{\"name\":\"nagare-vol-myapp-data\",\"labels\":\
      \{\"nagare.dev/volume\":\"data\",\"nagare.dev/app\":\"myapp\",\
      \\"nagare.dev/managed-by\":\"nagarectl\"}},\"spec\":{\"resources\":\
      \{\"requests\":{\"storage\":\"1Gi\"}},\"volumeName\":\"pvc-abc123\"},\
      \\"status\":{\"phase\":\"Bound\"}}]}"

-- ---------------------------------------------------------------------------
-- Nagare.App.Deployments (EP-31)

deploymentsTests :: [TestTree]
deploymentsTests =
  [ testCase "appConfigMapName prefixes the app name" $
      appConfigMapName "notes" @?= "nagare-app-deployments-notes"
  , testCase "revisionForTag matches the revision whose image ends with :tag" $
      revisionForTag "20260610-110000" revisionsJSON @?= Just "notes-00002"
  , testCase "revisionForTag returns Nothing when no revision carries the tag" $
      revisionForTag "20260101-000000" revisionsJSON @?= Nothing
  , testCase "revisionForTag returns Nothing on malformed JSON" $
      revisionForTag "x" "{not json" @?= Nothing
  ]
  where
    revisionsJSON =
      BC.pack $
        concat
          [ "{\"items\":["
          , "{\"metadata\":{\"name\":\"notes-00001\"},\"spec\":{\"containers\":[{\"image\":\"gcr.io/p/notes:20260610-100000\"}]}},"
          , "{\"metadata\":{\"name\":\"notes-00002\"},\"spec\":{\"containers\":[{\"image\":\"gcr.io/p/notes:20260610-110000\"}]}}"
          , "]}"
          ]

-- ---------------------------------------------------------------------------
-- Nagare.App (EP-30)

appTests :: [TestTree]
appTests =
  [ testGroup
      "parseServiceNames"
      [ testCase "strips the resource prefix and drops blanks" $
          parseServiceNames "service.serving.knative.dev/notes\n\nservice.serving.knative.dev/blog\n"
            @?= ["notes", "blog"]
      , testCase "tolerates already-bare names" $
          parseServiceNames "notes\nblog\n" @?= ["notes", "blog"]
      ]
  , testGroup
      "logArgs"
      [ testCase "service selector, user-container, default no follow/tail" $
          logArgs (LogTarget "personal" "notes" Nothing False Nothing)
            @?= ["logs", "-l", "serving.knative.dev/service=notes", "-n", "personal", "-c", "user-container"]
      , testCase "adds --tail and --follow" $
          logArgs (LogTarget "personal" "notes" Nothing True (Just 50))
            @?= [ "logs"
                , "-l"
                , "serving.knative.dev/service=notes"
                , "-n"
                , "personal"
                , "-c"
                , "user-container"
                , "--tail"
                , "50"
                , "--follow"
                ]
      , testCase "pins the revision selector when given" $
          logArgs (LogTarget "personal" "notes" (Just "notes-00003") False Nothing)
            @?= [ "logs"
                , "-l"
                , "serving.knative.dev/service=notes,serving.knative.dev/revision=notes-00003"
                , "-n"
                , "personal"
                , "-c"
                , "user-container"
                ]
      ]
  , testGroup
      "restartPatch"
      [ testCase "contains the stamp and is valid JSON" $ do
          let p = restartPatch "20260610-120000"
          assertBool "stamp present" ("20260610-120000" `T.isInfixOf` p)
          assertBool "clears visibility label with null" ("\"networking.knative.dev/visibility\":null" `T.isInfixOf` p)
          case eitherDecodeStrict (TE.encodeUtf8 p) :: Either String Aeson.Value of
            Right _ -> pure ()
            Left e -> assertFailure ("restartPatch is not valid JSON: " <> e)
      ]
  , testGroup
      "extractAppSummary"
      [ testCase "pulls name/url/ready/revision/image from a ksvc object" $
          extractAppSummary ksvcJSON
            @?= Right
              AppSummary
                { asName = "notes"
                , asUrl = Just "https://notes.personal.apps.example.com"
                , asReady = Just True
                , asLatestRevision = Just "notes-00003"
                , asImage = Just "gcr.io/p/notes:20260610-120000"
                }
      , testCase "missing .metadata.name is a Left" $
          case extractAppSummary "{\"status\":{}}" of
            Left _ -> pure ()
            Right s -> assertFailure ("expected Left, got: " <> show s)
      , testCase "a list response yields one summary per item" $
          fmap (map asName) (extractAppSummaries ksvcListJSON) @?= Right ["notes"]
      ]
  , testGroup
      "extractDomainsFor"
      [ testCase "keeps only mappings whose spec.ref.name matches" $
          extractDomainsFor "notes" domainMappingListJSON
            @?= Right ["notes.example.com", "www.example.com"]
      , testCase "no matches yields empty" $
          extractDomainsFor "other" domainMappingListJSON @?= Right []
      ]
  , testGroup
      "formatAppList"
      [ testCase "aligns NAME/READY/URL and marks empty" $
          formatAppList [] @?= "(no apps)\n"
      , testCase "renders a row with ready and url" $ do
          let out = formatAppList [AppSummary "notes" (Just "https://x") (Just True) Nothing Nothing]
          assertBool "has header NAME" ("NAME" `T.isInfixOf` out)
          assertBool "has the app name" ("notes" `T.isInfixOf` out)
          assertBool "has ready True" ("True" `T.isInfixOf` out)
          assertBool "has url" ("https://x" `T.isInfixOf` out)
      ]
  ]
  where
    ksvcJSON =
      BC.pack $
        concat
          [ "{\"metadata\":{\"name\":\"notes\"},"
          , "\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"image\":\"gcr.io/p/notes:20260610-120000\"}]}}},"
          , "\"status\":{\"url\":\"https://notes.personal.apps.example.com\","
          , "\"latestReadyRevisionName\":\"notes-00003\","
          , "\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
          ]
    ksvcListJSON =
      BC.pack ("{\"items\":[" <> BC.unpack ksvcJSON <> "]}")
    domainMappingListJSON =
      BC.pack $
        concat
          [ "{\"items\":["
          , "{\"metadata\":{\"name\":\"notes.example.com\"},\"spec\":{\"ref\":{\"name\":\"notes\"}}},"
          , "{\"metadata\":{\"name\":\"www.example.com\"},\"spec\":{\"ref\":{\"name\":\"notes\"}}},"
          , "{\"metadata\":{\"name\":\"blog.example.com\"},\"spec\":{\"ref\":{\"name\":\"blog\"}}}"
          , "]}"
          ]

-- ---------------------------------------------------------------------------
-- Nagare.Env.PreviewOverlay (EP-27 M2)

-- | A minimal static preview Service (no env/envFrom), as the static renderer
-- emits it. The overlay must add the four envFrom entries to its container.
staticServiceYaml :: ByteString
staticServiceYaml =
  BC.pack $
    unlines
      [ "apiVersion: serving.knative.dev/v1"
      , "kind: Service"
      , "metadata:"
      , "  name: demo-pr-42"
      , "  namespace: personal"
      , "spec:"
      , "  template:"
      , "    spec:"
      , "      containers:"
      , "      - image: gcr.io/p/demo:20260609-120000"
      , "        ports:"
      , "        - containerPort: 8080"
      ]

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

-- | Assert needle @a@ appears before needle @b@ in @hay@.
assertBefore :: ByteString -> ByteString -> ByteString -> Assertion
assertBefore a b hay =
  assertBool
    (show a <> " must appear before " <> show b)
    (idx a < idx b)
  where
    idx n = BS.length (fst (BS.breakSubstring n hay))

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
      let m = generatedEnv sampleCtx {Gen.source = Nothing}
      genLit m "NAGARE_SOURCE" @?= Nothing
      length (Map.keys m) @?= 5
  , testCase "every generated entry is Runtime-scoped" $ do
      let m = generatedEnv sampleCtx
      mapM_ (\sev -> scopes sev @?= scopes (runtimeScoped (EnvLiteral "x"))) (Map.elems m)
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

brokerConnectionEnvTests :: [TestTree]
brokerConnectionEnvTests =
  [ testCase "brokerConnectionEnv emits Kafka bootstrap and topic variables" $ do
      let env = unsafe (brokerConnectionEnv eventsBinding eventsConn)
      genLit env "KAFKA_BOOTSTRAP_SERVERS" @?= Just "events.personal.svc.cluster.local:9092"
      genLit env "KAFKA_SECURITY_PROTOCOL" @?= Just "PLAINTEXT"
      genLit env "NAGARE_BROKER_NAME" @?= Just "events"
      genLit env "NAGARE_TOPIC_JOBS" @?= Just "jobs"
      genLit env "NAGARE_TOPIC_USER_CREATED" @?= Just "user.created"
  , testCase "identical broker env maps merge without conflict" $ do
      let env = unsafe (brokerConnectionEnv eventsBinding eventsConn)
      mergeBrokerConnectionEnvs [env, env] @?= Right env
  , testCase "different bootstrap targets are rejected" $ do
      let env1 = unsafe (brokerConnectionEnv eventsBinding eventsConn)
          otherConn = eventsConn {bootstrapServers = "other.personal.svc.cluster.local:9092"}
          env2 = unsafe (brokerConnectionEnv eventsBinding otherConn)
      assertBool "should be Left" (isLeft (mergeBrokerConnectionEnvs [env1, env2]))
  , testCase "topics that normalize to the same env key are rejected" $ do
      let binding =
            BrokerBinding
              { name = unsafe (mkBrokerName "events")
              , topics = [unsafe (mkTopicName "user.created"), unsafe (mkTopicName "user-created")]
              }
      assertBool "should be Left" (isLeft (brokerConnectionEnv binding eventsConn))
  ]

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
      let gctx = sampleCtx {Gen.source = Nothing}
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
    , volumes = []
    , cdn = Nothing
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
      [ testCase "emits --platform, -f, -t, --build-arg, context in order" $
          dockerBuildArgs "linux/amd64" "r" "Dockerfile" "." [("A", "1")]
            @?= ["build", "--platform", "linux/amd64", "-f", "Dockerfile", "-t", "r", "--build-arg", "A=1", "."]
      , testCase "no build args omits --build-arg" $
          dockerBuildArgs "linux/amd64" "ref:tag" "docker/Dockerfile" "svc" []
            @?= ["build", "--platform", "linux/amd64", "-f", "docker/Dockerfile", "-t", "ref:tag", "svc"]
      , testCase "multiple build args each get their own --build-arg" $
          dockerBuildArgs "linux/amd64" "r" "Dockerfile" "." [("A", "1"), ("B", "2")]
            @?= [ "build"
                , "--platform"
                , "linux/amd64"
                , "-f"
                , "Dockerfile"
                , "-t"
                , "r"
                , "--build-arg"
                , "A=1"
                , "--build-arg"
                , "B=2"
                , "."
                ]
      , testCase "the platform argument is honored (EP-3)" $
          dockerBuildArgs "linux/arm64" "r" "Dockerfile" "." []
            @?= ["build", "--platform", "linux/arm64", "-f", "Dockerfile", "-t", "r", "."]
      ]
  , testGroup
      "nixpacksBuildArgs"
      [ testCase "builds the context and tags with --name, with --platform" $
          nixpacksBuildArgs "linux/amd64" "ref:tag" "." []
            @?= ["build", ".", "--platform", "linux/amd64", "--name", "ref:tag"]
      , testCase "build args become --env KEY=VALUE" $
          nixpacksBuildArgs "linux/amd64" "r" "app" [("A", "1")]
            @?= ["build", "app", "--platform", "linux/amd64", "--name", "r", "--env", "A=1"]
      , testCase "multiple build args each get their own --env" $
          nixpacksBuildArgs "linux/amd64" "r" "." [("A", "1"), ("B", "2")]
            @?= ["build", ".", "--platform", "linux/amd64", "--name", "r", "--env", "A=1", "--env", "B=2"]
      ]
  , testGroup
      "describeBuild"
      [ testCase "prebuilt mentions no local build and the tag" $
          describeBuild "linux/amd64" prebuiltSpec @?= "prebuilt image (no local build), tag v1.2.3"
      , testCase "dockerfile shows the docker build command with --platform" $
          describeBuild "linux/amd64" dockerfileSpec @?= "docker build --platform linux/amd64 -f Dockerfile ."
      , testCase "nixpacks shows the nixpacks build command with --platform" $
          describeBuild "linux/amd64" nixpacksSpec @?= "nixpacks build --platform linux/amd64 ."
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
    , cdn = Nothing
    }

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> T.unpack e)

-- ---------------------------------------------------------------------------
-- EP-45: managed-database CLI pure helpers.

databaseTests :: [TestTree]
databaseTests =
  [ testGroup
      "Nagare.Database.Secret"
      [ testCase "composeConnectionUrl postgres" $
          composeConnectionUrl Postgres parts
            @?= "postgresql://nagare:pw@pg-main.personal.svc.cluster.local:5432/pg_main"
      , testCase "composeConnectionUrl redis" $
          composeConnectionUrl Redis parts
            @?= "redis://:pw@pg-main.personal.svc.cluster.local:6379"
      , testCase "composeConnectionUrl clickhouse" $
          composeConnectionUrl ClickHouse parts
            @?= "clickhouse://nagare:pw@pg-main.personal.svc.cluster.local:9000"
      , testCase "secretKeysFor postgres has the four keys" $
          map fst (secretKeysFor Postgres parts)
            @?= ["POSTGRES_PASSWORD", "POSTGRES_USER", "POSTGRES_DB", "DATABASE_URL"]
      , testCase "secretKeysFor redis has two keys" $
          map fst (secretKeysFor Redis parts) @?= ["REDIS_PASSWORD", "REDIS_URL"]
      , testCase "engineToken maps the three engines" $
          map engineToken [Postgres, Redis, ClickHouse] @?= ["postgres", "redis", "clickhouse"]
      , testCase "passwordKey per engine" $
          map passwordKey [Postgres, Redis, ClickHouse]
            @?= ["POSTGRES_PASSWORD", "REDIS_PASSWORD", "CLICKHOUSE_PASSWORD"]
      ]
  , testGroup
      "Nagare.Database.Create.buildDatabase"
      [ testCase "builds postgres with defaults" $
          case buildDatabase Postgres "pg-main" (mkParams Nothing Nothing) of
            Right _ -> pure ()
            Left e -> assertFailure (T.unpack e)
      , testCase "rejects a bad name" $
          assertBool "should reject" (isLeft (buildDatabase Postgres "Bad_Name" (mkParams Nothing Nothing)))
      , testCase "rejects latest version" $
          assertBool "should reject" (isLeft (buildDatabase Postgres "pg" (mkParams (Just "latest") Nothing)))
      ]
  , testGroup
      "Nagare.Database.Discover"
      [ testCase "dbLabelSelector" $
          dbLabelSelector @?= "nagare.dev/managed-by=nagarectl,nagare.dev/database"
      , testCase "extractDbRows parses a statefulset list" $
          extractDbRows stsListJson
            @?= Right [DbRow "pg-main" "postgres" "18" "10Gi" "Retain" "pg-main.personal.svc.cluster.local" True]
      , testCase "extractDbRows on empty items is Right []" $
          extractDbRows "{\"items\":[]}" @?= Right []
      , testCase "extractDbRows on malformed JSON is Left" $
          assertBool "should be Left" (isLeft (extractDbRows "not json"))
      , testCase "formatDbTable renders a header" $
          assertBool
            "has NAME header"
            ( "NAME"
                `T.isInfixOf` formatDbTable
                  [DbRow "pg-main" "postgres" "18" "10Gi" "Retain" "pg-main.personal.svc.cluster.local" True]
            )
      ]
  ]
  where
    parts =
      ConnectionParts
        { cpUser = "nagare"
        , cpPassword = "pw"
        , cpHost = "pg-main.personal.svc.cluster.local"
        , cpDb = "pg_main"
        }
    mkParams ver sz =
      DbCreateParams
        { dcpNamespace = "personal"
        , dcpVersion = ver
        , dcpSize = sz
        , dcpCpu = Nothing
        , dcpMemory = Nothing
        , dcpConfig = Nothing
        , dcpDryRun = True
        , dcpTargetProfile = tnbProfile
        }
    stsListJson =
      BC.pack
        "{\"items\":[{\"metadata\":{\"name\":\"pg-main\",\"namespace\":\"personal\",\"labels\":{\"nagare.dev/engine\":\"postgres\",\"nagare.dev/managed-by\":\"nagarectl\"},\"annotations\":{\"nagare.dev/version\":\"18\",\"nagare.dev/size\":\"10Gi\",\"nagare.dev/retention\":\"Retain\"}},\"status\":{\"readyReplicas\":1}}]}"

-- ---------------------------------------------------------------------------
-- EP-78: broker lifecycle command helpers.

brokerTests :: [TestTree]
brokerTests =
  [ testGroup
      "Nagare.Broker.Create.buildBroker"
      [ testCase "builds Redpanda with defaults" $
          case buildBroker Redpanda "events" (mkParams Nothing Nothing Nothing) of
            Right Broker {name = brokerName, version = brokerVersion, sizing = BrokerSizing {smp, memory}} -> do
              let BrokerSizing {smp = defaultSmp, memory = defaultMemory} = defaultBrokerSizing
              brokerNameText brokerName @?= "events"
              brokerVersion @?= defaultBrokerVersion Redpanda
              smp @?= defaultSmp
              memory @?= defaultMemory
            Left e -> assertFailure (T.unpack e)
      , testCase "rejects latest version" $
          assertBool "should reject" (isLeft (buildBroker Redpanda "events" (mkParams (Just "latest") Nothing Nothing)))
      , testCase "honors Redpanda sizing flags" $
          case buildBroker Redpanda "events" (mkParams Nothing (Just 2) (Just "4Gi")) of
            Right Broker {sizing = BrokerSizing {smp, memory}} -> do
              smp @?= 2
              quantityText memory @?= "4Gi"
            Left e -> assertFailure (T.unpack e)
      , testCase "builds topics from CLI flags" $
          case buildBroker Redpanda "events" (mkParams Nothing Nothing Nothing) {topics = ["jobs"], topicPartitions = Just 3, topicRetentionMs = Just 86400000} of
            Right Broker {topics = [BrokerTopic {name = topicName, partitions, replicationFactor, retentionMs}]} -> do
              topicNameText topicName @?= "jobs"
              partitions @?= 3
              replicationFactor @?= 1
              retentionMs @?= Just 86400000
            Right other -> assertFailure ("unexpected broker topics: " <> show other)
            Left e -> assertFailure (T.unpack e)
      ]
  , testGroup
      "Nagare.Broker.Topic"
      [ testCase "rpkTopicCreateArgs includes idempotence, sizing, retention, and brokers" $
          let topic =
                BrokerTopic
                  { name = unsafe (mkTopicName "jobs")
                  , partitions = 3
                  , replicationFactor = 1
                  , retentionMs = Just 86400000
                  }
           in rpkTopicCreateArgs "events.personal.svc.cluster.local:9092" topic
                @?= [ "topic"
                    , "create"
                    , "--if-not-exists"
                    , "-p"
                    , "3"
                    , "-r"
                    , "1"
                    , "-c"
                    , "retention.ms=86400000"
                    , "jobs"
                    , "-X"
                    , "brokers=events.personal.svc.cluster.local:9092"
                    ]
      , testCase "parseTopicDescription reads rpk summary and retention" $
          parseTopicDescription topicDescribeOutput
            @?= Right (TopicStatus "jobs" 3 1 (Just 86400000))
      , testCase "renderTopicPlan includes declared topics" $
          case buildBroker Redpanda "events" (mkParams Nothing Nothing Nothing) {topics = ["jobs"], topicPartitions = Just 3, topicRetentionMs = Just 86400000} of
            Right broker ->
              assertBool
                "contains topic plan"
                ("jobs partitions=3 replicationFactor=1 retentionMs=86400000" `T.isInfixOf` renderTopicPlan broker)
            Left e -> assertFailure (T.unpack e)
      ]
  , testGroup
      "Nagare.Broker.Discover"
      [ testCase "brokerLabelSelector" $
          brokerLabelSelector @?= "nagare.dev/managed-by=nagarectl,nagare.dev/broker"
      , testCase "extractBrokerRows parses a statefulset list" $
          extractBrokerRows brokerStsListJson
            @?= Right [BrokerRow "events" "redpanda" "v25.2.1" "5Gi" "events.personal.svc.cluster.local:9092" True]
      , testCase "extractBrokerRows falls back to image version" $
          extractBrokerRows brokerStsImageVersionJson
            @?= Right [BrokerRow "events" "redpanda" "v25.2.1" "?" "events.personal.svc.cluster.local:9092" False]
      , testCase "extractBrokerRows on empty items is Right []" $
          extractBrokerRows "{\"items\":[]}" @?= Right []
      , testCase "extractBrokerRows on malformed JSON is Left" $
          assertBool "should be Left" (isLeft (extractBrokerRows "not json"))
      , testCase "formatBrokerTable renders a header" $
          assertBool
            "has NAME header"
            ( "NAME"
                `T.isInfixOf` formatBrokerTable
                  [BrokerRow "events" "redpanda" "v25.2.1" "5Gi" "events.personal.svc.cluster.local:9092" True]
            )
      ]
  , testGroup
      "Nagare.Broker.Health"
      [ testCase "parsePodReady reads Ready=True" $
          parsePodReady readyPodJson @?= Just True
      , testCase "parsePodReady reads Ready=False" $
          parsePodReady notReadyPodJson @?= Just False
      , testCase "parseVictoriaUp matches broker up sample" $
          parseVictoriaUp "events" victoriaUpJson @?= Right True
      , testCase "parseVictoriaUp returns False when broker has no up sample" $
          parseVictoriaUp "events" victoriaEmptyJson @?= Right False
      ]
  ]
  where
    mkParams ver smp' memory' =
      BrokerCreateParams
        { namespace = "personal"
        , version = ver
        , size = Nothing
        , cpu = Nothing
        , memory = Nothing
        , config = Nothing
        , dryRun = True
        , redpandaSmp = smp'
        , redpandaMemory = memory'
        , topics = []
        , topicPartitions = Nothing
        , topicRetentionMs = Nothing
        }
    topicDescribeOutput =
      BC.pack
        "SUMMARY\n=======\nNAME        jobs\nPARTITIONS  3\nREPLICAS    1\nCONFIGS\n=======\nKEY           VALUE     SOURCE\nretention.ms  86400000  DYNAMIC_TOPIC_CONFIG\n"
    brokerStsListJson =
      BC.pack
        "{\"items\":[{\"metadata\":{\"name\":\"events\",\"namespace\":\"personal\",\"labels\":{\"nagare.dev/broker\":\"events\",\"nagare.dev/broker-provider\":\"redpanda\",\"nagare.dev/managed-by\":\"nagarectl\"},\"annotations\":{\"nagare.dev/version\":\"v25.2.1\",\"nagare.dev/size\":\"5Gi\"}},\"status\":{\"readyReplicas\":1}}]}"
    brokerStsImageVersionJson =
      BC.pack
        "{\"items\":[{\"metadata\":{\"name\":\"events\",\"namespace\":\"personal\",\"labels\":{\"nagare.dev/broker\":\"events\",\"nagare.dev/broker-provider\":\"redpanda\",\"nagare.dev/managed-by\":\"nagarectl\"}},\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"image\":\"docker.redpanda.com/redpandadata/redpanda:v25.2.1\"}]} }},\"status\":{\"readyReplicas\":0}}]}"
    readyPodJson =
      BC.pack
        "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
    notReadyPodJson =
      BC.pack
        "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\"}]}}"
    victoriaUpJson =
      BC.pack
        "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"nagare_broker\":\"events\"},\"value\":[1710000000,\"1\"]}]}}"
    victoriaEmptyJson =
      BC.pack
        "{\"status\":\"success\",\"data\":{\"result\":[]}}"

-- ---------------------------------------------------------------------------
-- EP-46: app -> database connection-env injection.

connEnvTestPg :: Map.Map EnvName ScopedEnvVar
connEnvTestPg =
  connectionEnv
    Postgres
    (unsafe (mkDatabaseName "notes-db"))
    (unsafe (mkNamespace "personal"))
    (ConnIdentity {connUser = Just "app", connDb = Just "notes"})

connEnvTestRedis :: Map.Map EnvName ScopedEnvVar
connEnvTestRedis =
  connectionEnv
    Redis
    (unsafe (mkDatabaseName "cache"))
    (unsafe (mkNamespace "personal"))
    (ConnIdentity {connUser = Nothing, connDb = Nothing})

-- | Classify a generated entry: Left literal-value, or Right secret-name.
classifyConn :: Map.Map EnvName ScopedEnvVar -> Text -> Maybe (Either Text Text)
classifyConn m name = do
  en <- either (const Nothing) Just (mkEnvName name)
  ScopedEnvVar {value = v} <- Map.lookup en m
  pure $ case v of
    EnvLiteral t -> Left t
    EnvSecretRef s -> Right (secretNameText s)

connectionEnvTests :: [TestTree]
connectionEnvTests =
  [ testGroup
      "connectionEnv per engine"
      [ testCase "Postgres host/port/user/db are literals" $ do
          classifyConn connEnvTestPg "POSTGRES_HOST" @?= Just (Left "notes-db.personal.svc.cluster.local")
          classifyConn connEnvTestPg "POSTGRES_PORT" @?= Just (Left "5432")
          classifyConn connEnvTestPg "POSTGRES_USER" @?= Just (Left "app")
          classifyConn connEnvTestPg "POSTGRES_DB" @?= Just (Left "notes")
      , testCase "Postgres password and DATABASE_URL are secret refs to nagare-db-notes-db" $ do
          classifyConn connEnvTestPg "POSTGRES_PASSWORD" @?= Just (Right "nagare-db-notes-db")
          classifyConn connEnvTestPg "DATABASE_URL" @?= Just (Right "nagare-db-notes-db")
      , testCase "Postgres has exactly these six keys" $
          sort (map envNameText (Map.keys connEnvTestPg))
            @?= sort ["POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_USER", "POSTGRES_DB", "POSTGRES_PASSWORD", "DATABASE_URL"]
      , testCase "Redis host/port literals; password/URL secret refs" $ do
          classifyConn connEnvTestRedis "REDIS_HOST" @?= Just (Left "cache.personal.svc.cluster.local")
          classifyConn connEnvTestRedis "REDIS_PORT" @?= Just (Left "6379")
          classifyConn connEnvTestRedis "REDIS_PASSWORD" @?= Just (Right "nagare-db-cache")
          classifyConn connEnvTestRedis "REDIS_URL" @?= Just (Right "nagare-db-cache")
      , testCase "every entry is Runtime-scoped" $
          mapM_ (\sev -> scopes sev @?= scopes (runtimeScoped (EnvLiteral "x"))) (Map.elems connEnvTestPg)
      ]
  , testGroup
      "mergeConnectionEnvs"
      [ testCase "two same-engine maps collide" $
          assertBool "should be Left" (isLeft (mergeConnectionEnvs [connEnvTestPg, pgOther]))
      , testCase "different engines merge cleanly" $
          case mergeConnectionEnvs [connEnvTestPg, connEnvTestRedis] of
            Right m -> assertBool "has both" (Map.size m == Map.size connEnvTestPg + Map.size connEnvTestRedis)
            Left e -> assertFailure (T.unpack e)
      ]
  , testGroup
      "rendered Service carries DB env (IP5)"
      [ testCase "literals and a DATABASE_URL secretKeyRef appear" $ do
          let dep' = mkDemoDep connEnvTestPg
              yaml = TE.decodeUtf8 (renderService dep' "20260602-120000")
          assertBool "POSTGRES_HOST" ("POSTGRES_HOST" `T.isInfixOf` yaml)
          assertBool "host literal" ("notes-db.personal.svc.cluster.local" `T.isInfixOf` yaml)
          assertBool "DATABASE_URL" ("DATABASE_URL" `T.isInfixOf` yaml)
          assertBool "secretKeyRef" ("secretKeyRef" `T.isInfixOf` yaml)
          assertBool "secret name" ("nagare-db-notes-db" `T.isInfixOf` yaml)
      , testCase "generated connection var overrides a user value (precedence)" $ do
          let userUrl = Map.singleton (unsafe (mkEnvName "DATABASE_URL")) (runtimeScoped (EnvLiteral "user-wrote-this"))
              merged = Map.union connEnvTestPg userUrl -- mergeGenerated is left-biased
          classifyConn merged "DATABASE_URL" @?= Just (Right "nagare-db-notes-db")
      ]
  ]
  where
    pgOther =
      connectionEnv
        Postgres
        (unsafe (mkDatabaseName "other-db"))
        (unsafe (mkNamespace "personal"))
        (ConnIdentity {connUser = Just "app", connDb = Just "other"})

-- ---------------------------------------------------------------------------
-- EP-47: database backups, retention, restore.

-- | The cloud (GCS) backend carrying the tan-nb-exp worked-example values; the
-- four renderer fixtures use it so their @gs://@ URLs and @CLOUDSDK_CORE_PROJECT@
-- are exactly the historic bytes (EP-84 keeps the cloud path unchanged).
tnbGcsBackend :: StoreBackend
tnbGcsBackend = GcsBackend "tan-nb-exp" "tan-nb-exp-nagare-backups"

-- | The local (MinIO) backend matching @nagare.local.env.example@'s
-- @NAGARE_LOCAL_OBJECT_STORE@, for the per-mode renderer tests (EP-84).
localMinioBackend :: StoreBackend
localMinioBackend =
  MinioBackend
    (MinioRef "http://minio.nagare-system.svc.cluster.local:9000" "nagare-backups" "nagare-minio-credentials")

backupJobInputsPg :: BackupJobInputs
backupJobInputsPg =
  BackupJobInputs
    { bjiNamespace = "personal"
    , bjiJobName = "nagare-dbbackup-mydb-20260610t141503z"
    , bjiEngine = Postgres
    , bjiClientImage = "postgres:18"
    , bjiSvcHost = "mydb"
    , bjiSecretName = "nagare-db-mydb"
    , bjiName = "mydb"
    , bjiDestUrl = "gs://tan-nb-exp-nagare-backups/databases/mydb/20260610T141503Z.sql.gz"
    , bjiPrefix = "gs://tan-nb-exp-nagare-backups/databases/mydb/"
    , bjiKeep = 7
    , bjiSelfPrune = False
    , bjiBackend = tnbGcsBackend
    }

restoreJobInputsPg :: RestoreJobInputs
restoreJobInputsPg =
  RestoreJobInputs
    { rjiNamespace = "personal"
    , rjiJobName = "nagare-dbrestore-mydb-20260610t141503z"
    , rjiEngine = Postgres
    , rjiClientImage = "postgres:18"
    , rjiSvcHost = "mydb"
    , rjiSecretName = "nagare-db-mydb"
    , rjiName = "mydb"
    , rjiSrcUrl = "gs://tan-nb-exp-nagare-backups/databases/mydb/20260610T141503Z.sql.gz"
    , rjiLiveTarget = False
    , rjiBackend = tnbGcsBackend
    }

snapshotJobInputs :: SnapshotJobInputs
snapshotJobInputs =
  SnapshotJobInputs
    { sjiNamespace = "personal"
    , sjiJobName = "nagare-snapshot-myapp-data-20260610t141503z"
    , sjiClaimName = "nagare-vol-myapp-data"
    , sjiDestUrl = "gs://tan-nb-exp-nagare-backups/volumes/myapp/data/20260610T141503Z.tar.gz"
    , sjiMountPath = "/vol"
    , sjiBackend = tnbGcsBackend
    }

storageRestoreJobInputs :: StorageRestoreJobInputs
storageRestoreJobInputs =
  StorageRestoreJobInputs
    { sriNamespace = "personal"
    , sriJobName = "nagare-volrestore-myapp-data-20260610t141503z"
    , sriClaimName = "nagare-vol-myapp-data-restore-scratch"
    , sriSrcUrl = "gs://tan-nb-exp-nagare-backups/volumes/myapp/data/20260610T141503Z.tar.gz"
    , sriMountPath = "/restore"
    , sriBackend = tnbGcsBackend
    }

-- | Recurrence guard (EP-1): every GCS data-movement Job renderer must emit the
-- metadata @hostAliases@ and the @google/cloud-sdk:slim@ image. All four render
-- through the shared 'Nagare.Cluster.GcsJob', so dropping the @hostAliases@ there
-- fails every case at once.
gcsJobHostAliasesTests :: [TestTree]
gcsJobHostAliasesTests =
  [ testCase (name <> " renders the metadata hostAliases and the cloud-sdk image") $ do
      let y = TE.decodeUtf8 rendered
      assertBool "hostAliases for metadata.google.internal" ("metadata.google.internal" `T.isInfixOf` y)
      assertBool "metadata IP" ("169.254.169.254" `T.isInfixOf` y)
      assertBool "cloud-sdk image" ("google/cloud-sdk:slim" `T.isInfixOf` y)
      assertBool "restartPolicy Never" ("Never" `T.isInfixOf` y)
  | (name, rendered) <-
      [ ("db backup Job", renderBackupJob backupJobInputsPg)
      , ("db restore Job", renderRestoreJob restoreJobInputsPg)
      , ("volume snapshot Job", renderSnapshotJob snapshotJobInputs)
      , ("volume restore Job", renderStorageRestoreJob storageRestoreJobInputs)
      ]
  ]

-- | EP-84 (MasterPlan 16 Integration Point 3): each of the four data-movement
-- Job renderers must differ correctly by store backend. Under 'GcsBackend' it
-- renders exactly the cloud shape (cloud-sdk image, metadata @hostAliases@/IP,
-- @gs://@, @gsutil@); under 'MinioBackend' it renders the MinIO shape
-- (@amazon/aws-cli@, @s3://@, @--endpoint-url@, a @secretKeyRef@ to
-- @nagare-minio-credentials@) and carries NO metadata server reference. All four
-- render through the shared 'Nagare.Cluster.GcsJob', so the per-mode branch is
-- proven once per verb.
storeBackendModeTests :: [TestTree]
storeBackendModeTests =
  parseTests <> renderTests
  where
    parseTests =
      [ testCase "parseLocalObjectStore splits endpoint and bucket on the last /" $
          parseLocalObjectStore "http://minio.nagare-system.svc.cluster.local:9000/nagare-backups"
            @?= Just ("http://minio.nagare-system.svc.cluster.local:9000", "nagare-backups")
      , testCase "parseLocalObjectStore rejects an empty string" $
          parseLocalObjectStore "" @?= Nothing
      ]
    renderTests =
      [ testCase (name <> ": " <> show backend <> " renders the right backend shape") $ do
          let y = TE.decodeUtf8 (render backend)
          case backend of
            GcsBackend {} -> do
              assertBool "cloud image" ("google/cloud-sdk:slim" `T.isInfixOf` y)
              assertBool "metadata dns" ("metadata.google.internal" `T.isInfixOf` y)
              assertBool "metadata ip" ("169.254.169.254" `T.isInfixOf` y)
              assertBool "gs url" ("gs://" `T.isInfixOf` y)
              assertBool "no tar/gzip install in cloud" (not ("dnf install" `T.isInfixOf` y))
            MinioBackend {} -> do
              assertBool "minio image" ("amazon/aws-cli" `T.isInfixOf` y)
              assertBool "s3 url" ("s3://" `T.isInfixOf` y)
              assertBool "endpoint" ("--endpoint-url" `T.isInfixOf` y)
              assertBool "secret ref" ("nagare-minio-credentials" `T.isInfixOf` y)
              -- amazon/aws-cli ships no tar/gzip; the Job installs them (EP-84).
              assertBool "installs tar+gzip" ("dnf install -y -q tar gzip" `T.isInfixOf` y)
              assertBool "no metadata ip" (not ("169.254.169.254" `T.isInfixOf` y))
              assertBool "no metadata dns" (not ("metadata.google.internal" `T.isInfixOf` y))
      | (name, render) <-
          [ ("db backup Job", \b -> renderBackupJob backupJobInputsPg {bjiBackend = b, bjiDestUrl = destFor b "databases/mydb/20260610T141503Z.sql.gz", bjiPrefix = destFor b "databases/mydb/"})
          , ("db restore Job", \b -> renderRestoreJob restoreJobInputsPg {rjiBackend = b, rjiSrcUrl = destFor b "databases/mydb/20260610T141503Z.sql.gz"})
          , ("volume snapshot Job", \b -> renderSnapshotJob snapshotJobInputs {sjiBackend = b, sjiDestUrl = destFor b "volumes/myapp/data/20260610T141503Z.tar.gz"})
          , ("volume restore Job", \b -> renderStorageRestoreJob storageRestoreJobInputs {sriBackend = b, sriSrcUrl = destFor b "volumes/myapp/data/20260610T141503Z.tar.gz"})
          ]
      , backend <- [tnbGcsBackend, localMinioBackend]
      ]
    -- The full object URL for a key under the backend's bucket, so each fixture's
    -- DEST/SRC carries the right scheme for the backend under test.
    destFor (GcsBackend _ bucket) key = "gs://" <> bucket <> "/" <> key
    destFor (MinioBackend ref) key = "s3://" <> mrBucket ref <> "/" <> key

-- | EP-6 M1: the GHC-env auto-resolver's testable core. 'findGhcEnvIn' returns
-- the first @.ghc.environment.*@ across the given dirs (absolute), else Nothing.
ghcEnvTests :: [TestTree]
ghcEnvTests =
  [ testCase "findGhcEnvIn finds a planted .ghc.environment file" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        let envFile = root </> ".ghc.environment.aarch64-darwin-9.12.3"
        writeFile envFile "package-db dummy\n"
        found <- findGhcEnvIn [root]
        case found of
          Just p -> assertBool "returns the planted file (absolute)" (".ghc.environment.aarch64-darwin-9.12.3" `isSuffixOf` p)
          Nothing -> assertFailure "expected to find the planted env file"
  , testCase "findGhcEnvIn returns Nothing when no env file exists" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        found <- findGhcEnvIn [root]
        found @?= Nothing
  , testCase "findGhcEnvIn skips a nonexistent directory" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        found <- findGhcEnvIn [root </> "does-not-exist"]
        found @?= Nothing
  , testCase "findGhcEnvIn returns the first hit across dirs" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        let d1 = root </> "empty"
            d2 = root </> "haz"
        createDirectoryIfMissing True d1
        createDirectoryIfMissing True d2
        writeFile (d2 </> ".ghc.environment.x") "x\n"
        found <- findGhcEnvIn [d1, d2]
        case found of
          Just p -> assertBool "from the second dir" ("haz" `isInfixOf` p)
          Nothing -> assertFailure "expected a hit in the second dir"
  ]

backupRestoreTests :: [TestTree]
backupRestoreTests =
  [ testGroup
      "pure path / extension / schedule"
      [ testCase "dbBackupObjectPath builds databases/<name>/<ts>.<ext>" $
          dbBackupObjectPath "mydb" "20260610T141503Z" "sql.gz" @?= "databases/mydb/20260610T141503Z.sql.gz"
      , testCase "dbBackupKeyPrefix builds databases/<name>/" $
          dbBackupKeyPrefix "mydb" @?= "databases/mydb/"
      , testCase "backupExt per engine" $
          map backupExt [Postgres, Redis, ClickHouse] @?= ["sql.gz", "rdb.gz", "native.gz"]
      , testCase "backupRawExt per engine" $
          map backupRawExt [Postgres, Redis, ClickHouse] @?= ["sql", "rdb", "native"]
      , testCase "defaultBackupSchedule is daily 03:17 UTC" $
          defaultBackupSchedule @?= "17 3 * * *"
      ]
  , testGroup
      "Job / CronJob renderers"
      [ testCase "renderBackupJob is a two-container Job" $ do
          let y = TE.decodeUtf8 (renderBackupJob backupJobInputsPg)
          assertBool "kind Job" ("kind: Job" `T.isInfixOf` y)
          assertBool "initContainers" ("initContainers" `T.isInfixOf` y)
          assertBool "dump container" ("pg_dump" `T.isInfixOf` y)
          assertBool "upload image" ("google/cloud-sdk:slim" `T.isInfixOf` y)
          assertBool "metadata host" ("169.254.169.254" `T.isInfixOf` y)
          assertBool "hostAliases for metadata.google.internal" ("metadata.google.internal" `T.isInfixOf` y)
          assertBool "no self-prune for on-demand" (not ("pruning" `T.isInfixOf` y))
      , testCase "renderBackupCronJob wraps the body on a schedule and self-prunes" $ do
          let cron = BackupCronInputs {bciSchedule = defaultBackupSchedule, bciBase = backupJobInputsPg {bjiSelfPrune = True}}
              y = TE.decodeUtf8 (renderBackupCronJob cron)
          assertBool "kind CronJob" ("kind: CronJob" `T.isInfixOf` y)
          assertBool "schedule" ("17 3 * * *" `T.isInfixOf` y)
          assertBool "no overlap" ("Forbid" `T.isInfixOf` y)
          assertBool "self-prune" ("pruning" `T.isInfixOf` y)
      ]
  , testGroup
      "restore"
      [ testCase "isObjectUrl recognizes gs:// and s3://" $ do
          isObjectUrl "gs://b/x" @?= True
          isObjectUrl "s3://b/x" @?= True
          isObjectUrl "20260610T141503Z" @?= False
      , testCase "resolveBackupObject composes a bare timestamp (cloud)" $
          resolveBackupObject (GcsBackend "p" "b") "mydb" "sql.gz" "20260610T141503Z" @?= "gs://b/databases/mydb/20260610T141503Z.sql.gz"
      , testCase "resolveBackupObject passes a full URL through" $
          resolveBackupObject (GcsBackend "p" "b") "mydb" "sql.gz" "gs://other/x.sql.gz" @?= "gs://other/x.sql.gz"
      , testCase "renderRestoreJob targets a scratch database by default" $ do
          let y = TE.decodeUtf8 (renderRestoreJob restoreJobInputsPg)
          assertBool "kind Job" ("kind: Job" `T.isInfixOf` y)
          assertBool "download init" ("gunzip" `T.isInfixOf` y)
          assertBool "scratch target" ("_restore_scratch" `T.isInfixOf` y)
      , testCase "renderRestoreJob into live drops the scratch suffix" $ do
          let y = TE.decodeUtf8 (renderRestoreJob restoreJobInputsPg {rjiLiveTarget = True})
          assertBool "live warning" ("LIVE database" `T.isInfixOf` y)
          assertBool "no scratch suffix" (not ("_restore_scratch" `T.isInfixOf` y))
      ]
  ]

-- ---------------------------------------------------------------------------
-- Nagare.Cdn (MasterPlan 11, EP-57): the pure Cloudflare request-builders and
-- envelope parsers, asserted byte-exactly (compared as decoded Values so key
-- order is irrelevant).

cloudflareTests :: [TestTree]
cloudflareTests =
  [ testCase "buildCacheRulesPayload: default + /assets/ + never-cache /api/ + static" $
      buildCacheRulesPayload "blog.example.com" cdnFixture @?= expectedCacheRules
  , testCase "buildUpsertRecordPayload: proxied A record" $
      buildUpsertRecordPayload "blog.example.com" "34.105.10.20"
        @?= Aeson.object
          [ "type" Aeson..= ("A" :: Text)
          , "name" Aeson..= ("blog.example.com" :: Text)
          , "content" Aeson..= ("34.105.10.20" :: Text)
          , "proxied" Aeson..= True
          , "ttl" Aeson..= (1 :: Int)
          ]
  , testCase "sslModeToken: flexible/full/strict" $ do
      sslModeToken Flexible @?= "flexible"
      sslModeToken Full @?= "full"
      sslModeToken FullStrict @?= "strict"
  , testCase "buildPurgePayload: purge-all when no paths" $
      buildPurgePayload "blog.example.com" []
        @?= Aeson.object ["purge_everything" Aeson..= True]
  , testCase "buildPurgePayload: purge specific URLs" $
      buildPurgePayload "blog.example.com" ["/assets/app.css", "/"]
        @?= Aeson.object
          [ "files"
              Aeson..= ( [ "https://blog.example.com/assets/app.css"
                         , "https://blog.example.com/"
                         ] ::
                           [Text]
                       )
          ]
  , testCase "zoneNameFromHostname: registrable domain" $ do
      zoneNameFromHostname "blog.example.com" @?= "example.com"
      zoneNameFromHostname "example.com" @?= "example.com"
      zoneNameFromHostname "a.b.example.com." @?= "example.com"
  , testCase "parseEnvelopeUnit: success:true -> Right ()" $
      parseEnvelopeUnit "{\"success\":true,\"errors\":[],\"result\":{}}" @?= Right ()
  , testCase "parseEnvelopeUnit: success:false -> Left message" $
      parseEnvelopeUnit
        "{\"success\":false,\"errors\":[{\"code\":9109,\"message\":\"Invalid access token\"}]}"
        @?= Left "Invalid access token"
  , testCase "parseZoneId: result[0].id from a zone list" $
      parseZoneId "{\"success\":true,\"result\":[{\"id\":\"zone1\",\"name\":\"example.com\"}]}"
        @?= Just "zone1"
  , testCase "parseDnsRecordId: result[0].id from a record list (find)" $
      parseDnsRecordId "{\"success\":true,\"result\":[{\"id\":\"rec1\"}]}"
        @?= Just "rec1"
  , testCase "parseDnsRecordId: result.id from a single-object response (create)" $
      parseDnsRecordId "{\"success\":true,\"result\":{\"id\":\"rec2\"}}"
        @?= Just "rec2"
  ]
  where
    cdnFixture =
      Cdn
        { provider = CloudflareCdn
        , defaultTtlSeconds = Just 3600
        , cacheStaticAssets = True
        , cacheRules =
            [ CdnCacheRule "/assets/" (Just 31536000)
            , CdnCacheRule "/api/" Nothing
            ]
        }

    ttlParams ttl =
      Aeson.object
        [ "cache" Aeson..= True
        , "edge_ttl"
            Aeson..= Aeson.object
              [ "mode" Aeson..= ("override_origin" :: Text)
              , "default" Aeson..= (ttl :: Int)
              ]
        ]
    bypassParams = Aeson.object ["cache" Aeson..= False]
    ruleObj expr params =
      Aeson.object
        [ "expression" Aeson..= (expr :: Text)
        , "action" Aeson..= ("set_cache_settings" :: Text)
        , "action_parameters" Aeson..= params
        ]

    expectedCacheRules =
      Aeson.object
        [ "rules"
            Aeson..= [ ruleObj
                         "(http.host eq \"blog.example.com\") and starts_with(http.request.uri.path, \"/assets/\")"
                         (ttlParams 31536000)
                     , ruleObj
                         "(http.host eq \"blog.example.com\") and starts_with(http.request.uri.path, \"/api/\")"
                         bypassParams
                     , ruleObj
                         "(http.host eq \"blog.example.com\") and (http.request.uri.path.extension in {\"js\" \"css\" \"woff2\" \"woff\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"svg\" \"webp\" \"ico\"})"
                         (ttlParams 31536000)
                     , ruleObj
                         "(http.host eq \"blog.example.com\")"
                         (ttlParams 3600)
                     ]
        ]

-- ---------------------------------------------------------------------------
-- Nagare.Cdn.Provision (MasterPlan 11, EP-58): the pure deploy-time planner,
-- the gcloud-arg builders, and the dry-run renderer.

cdnProvisionTests :: [TestTree]
cdnProvisionTests =
  [ testCase "planCdn Cloudflare: DNS/OriginTls/Cache actions, no GcloudCmd" $ do
      let p = planCdn cfCdn cfTarget noRefs
      planProvider p @?= CloudflareCdn
      assertBool "no gcloud action" (not (any isGcloud (planActions p)))
      assertBool "one DnsUpsert per host" (length [() | DnsUpsert {} <- planActions p] == 1)
  , testCase "planCdn Gcp: all GcloudCmd, every argv pins --project=tan-nb-exp" $ do
      let p = planCdn gcpCdn gcpTarget gcpRefs
      planProvider p @?= GcpCloudCdn
      assertBool "all actions are gcloud" (all isGcloud (planActions p))
      assertBool
        "every gcloud argv has --project=tan-nb-exp"
        (all (\a -> "--project=tan-nb-exp" `elem` a) [args | GcloudCmd args <- planActions p])
  , testCase "gcloudDnsUpsertArgs: exact argv (more-specific A record to the global IP)" $
      gcloudDnsUpsertArgs "tan-nb-exp" "nagare-zone" "app.example.com" "203.0.113.20"
        @?= [ "dns"
            , "record-sets"
            , "create"
            , "app.example.com."
            , "--type=A"
            , "--ttl=300"
            , "--rrdatas=203.0.113.20"
            , "--zone=nagare-zone"
            , "--project=tan-nb-exp"
            ]
  , testCase "gcloudDnsUpsertArgs: project is parameterized (EP-62)" $
      assertBool
        "--project follows the supplied project"
        ("--project=acme-prod" `elem` gcloudDnsUpsertArgs "acme-prod" "z" "h" "ip")
  , testCase "gcloudBackendCacheArgs: exact argv (cache mode + default ttl + project)" $
      gcloudBackendCacheArgs "tan-nb-exp" "nagare-cdn-backend" gcpCdn
        @?= [ "compute"
            , "backend-services"
            , "update"
            , "nagare-cdn-backend"
            , "--cache-mode=USE_ORIGIN_HEADERS"
            , "--default-ttl=3600"
            , "--project=tan-nb-exp"
            ]
  , testCase "renderCdnPlan: Cloudflare dry-run block" $
      renderCdnPlan (planCdn cfCdn cfTarget noRefs)
        @?= T.unlines
          [ "--- CDN plan (Cloudflare) ---"
          , "DNS: blog.example.com -> 203.0.113.10 (proxied)"
          , "Origin TLS: Flexible"
          , "Cache: /assets/ -> 31536000s"
          , "Cache: /api/ -> never"
          , "Cache: (default) -> 3600s"
          ]
  , testCase "renderCdnPlan: Google dry-run block (gcloud lines pinned to the project)" $
      renderCdnPlan (planCdn gcpCdn gcpTarget gcpRefs)
        @?= T.unlines
          [ "--- CDN plan (GcpCloudCdn) ---"
          , "gcloud dns record-sets create app.example.com. --type=A --ttl=300 --rrdatas=203.0.113.20 --zone=nagare-zone --project=tan-nb-exp"
          , "gcloud compute backend-services update nagare-cdn-backend --cache-mode=USE_ORIGIN_HEADERS --default-ttl=3600 --project=tan-nb-exp"
          ]
  ]
  where
    isGcloud (GcloudCmd _) = True
    isGcloud _ = False
    cfCdn =
      Cdn
        { provider = CloudflareCdn
        , defaultTtlSeconds = Just 3600
        , cacheStaticAssets = False
        , cacheRules = [CdnCacheRule "/assets/" (Just 31536000), CdnCacheRule "/api/" Nothing]
        }
    cfTarget = CdnTarget ["blog.example.com"] "203.0.113.10" "personal" "blog"
    gcpCdn =
      Cdn
        { provider = GcpCloudCdn
        , defaultTtlSeconds = Just 3600
        , cacheStaticAssets = False
        , cacheRules = []
        }
    gcpTarget = CdnTarget ["app.example.com"] "203.0.113.20" "personal" "app"
    gcpRefs = GcpStackRefs "203.0.113.20" "nagare-cdn-backend" "nagare-cdn-urlmap" "nagare-zone" "tan-nb-exp"
    noRefs = GcpStackRefs "" "" "" "" "tan-nb-exp"

-- ---------------------------------------------------------------------------
-- Nagare.Cdn.Status (EP-58): the cdn list/status formatters.

cdnStatusTests :: [TestTree]
cdnStatusTests =
  [ testCase "formatCdnList []: empty sentinel" $
      formatCdnList [] @?= "(no CDN-fronted hostnames)\n"
  , testCase "formatCdnList: header + edge/VM rows are present and aligned" $ do
      let out = formatCdnList [edgeRow, vmRow]
      assertBool "HOST header" ("HOST" `T.isInfixOf` out)
      assertBool "edge host" ("blog.example.com" `T.isInfixOf` out)
      assertBool "points at edge" ("points at edge (203.0.113.30)" `T.isInfixOf` out)
      assertBool "points at VM" ("points at VM (203.0.113.10)" `T.isInfixOf` out)
  , testCase "formatCdnStatus: one host's field block" $
      formatCdnStatus edgeRow
        @?= T.unlines
          [ "Host:     blog.example.com"
          , "Provider: Cloudflare"
          , "DNS:      points at edge (203.0.113.30)"
          , "Cache:    default 3600s, 2 rules"
          , "Ready:    ready"
          ]
  ]
  where
    edgeRow = CdnRow "blog.example.com" "Cloudflare" (PointsAtEdge "203.0.113.30") "default 3600s, 2 rules" True
    vmRow = CdnRow "old.example.com" "GcpCloudCdn" (PointsAtVm "203.0.113.10") "default 3600s" False
