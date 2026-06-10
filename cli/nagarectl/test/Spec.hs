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
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.List (sort)
import Data.Text (Text)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Set qualified as Set
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
import Nagare.Database.Create (DbCreateParams (..), buildDatabase, passwordKey)
import Nagare.Database.Backup
  ( BackupCronInputs (..)
  , BackupJobInputs (..)
  , backupExt
  , backupRawExt
  , dbBackupGsUrl
  , dbBackupObjectPath
  , defaultBackupSchedule
  , renderBackupCronJob
  , renderBackupJob
  )
import Nagare.Database.Connection (ConnIdentity (..), connectionEnv, mergeConnectionEnvs)
import Nagare.Database.Discover (DbRow (..), dbLabelSelector, extractDbRows, formatDbTable)
import Nagare.Task.Discover
  ( AppScope (..)
  , TaskRow (..)
  , extractTaskRows
  , formatTaskTable
  , taskLabelSelector
  )
import Nagare.Task.Logs (TaskLogTarget (..), grafanaHint, taskLogArgs)
import Nagare.Task.Run (oneOffJobName, runArgs)
import Nagare.Database.Restore (isGsUrl, renderRestoreJob, resolveBackupObject, RestoreJobInputs (..))
import Nagare.Database.Secret
  ( ConnectionParts (..)
  , composeConnectionUrl
  , secretKeysFor
  )
import Nagare.Dsl.Database (Engine (..), engineToken, mkDatabaseName)
import Nagare.Ops.Doctor
  ( Check (..)
  , Remediation (..)
  , doctorExitOk
  , formatDoctor
  , gradeChecks
  , remediationFor
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
  ( Probe (..)
  , ProbeStatus (..)
  , parseClusterIssuerReady
  , parseConfigDomain
  , parseDeploymentReady
  , parseDfUsage
  , parseKourierIp
  , parseNewestBackupAge
  , parseNodeReady
  , renderInventory
  , statusLabel
  )
import Nagare.Build (applyBuildOverrides, describeBuild)
import Nagare.Dsl.Build (BuildSpec (..), defaultBuild, mkTag)
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Render (renderService)
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
  , runtimeScoped
  , scopedEnv
  , secretNameText
  )
import Nagare.Storage.Discover
  ( PVCRow (..)
  , appPVCLabelSelector
  , extractPVCStatus
  , formatStorageTable
  , pvcName
  )
import Nagare.Storage.Snapshot
  ( backupExcludedWarnings
  , snapshotObjectPath
  , snapshotsToPrune
  )
import Nagare.Env.BuildArgs (BuildArgWarning (..), assembleBuildArgs)
import Nagare.Env.Dotenv (parseDotenv)
import Nagare.Env.Generated (generatedEnv, mergeGenerated)
import Nagare.Env.Generated qualified as Gen
import Nagare.Env.PreviewOverlay (withPreviewEnvFrom)
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
main = do
  taskFixture <- BS.readFile "test/fixtures/cronjob-list.json"
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
      , testGroup "Nagare.Database (EP-45)" databaseTests
      , testGroup "Nagare.Database.Connection (EP-46)" connectionEnvTests
      , testGroup "Nagare.Database.Backup/Restore (EP-47)" backupRestoreTests
      , testGroup "Nagare.Task.Discover (EP-51)" (taskDiscoverTests taskFixture)
      , testGroup "Nagare.Task.Run / Logs (EP-51)" taskRunTests
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
  , testCase "grafanaHint embeds the task label query" $
      grafanaHint "cleanup"
        @?= "For older runs, query VictoriaLogs in Grafana with: {nagare_dev_task=\"cleanup\"}"
  ]
  where
    fixedTime = UTCTime (fromGregorian 2026 6 10) (secondsToDiffTime (3 * 3600 + 12))

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
      remediationFor (Probe "VM" StatusOk "RUNNING") @?= Nothing
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
  , testCase "remediationFor: Kourier ingress FAIL -> compare publicIp" $
      cmdOf (Probe "Kourier ingress" StatusFail "EXTERNAL-IP 1.2.3.4 != publicIp 5.6.7.8")
        `containsT` "stack output publicIp"
  , testCase "remediationFor: base domain WARN -> re-render config-domain" $
      cmdOf (Probe "base domain" StatusWarn "x != Pulumi y")
        `containsT` "stack output baseDomain"
  , testCase "remediationFor: Artifact Registry -> configure-docker" $
      cmdOf (Probe "Artifact Registry" StatusUnknown "gcloud unavailable")
        `containsT` "gcloud auth configure-docker us-west1-docker.pkg.dev"
  , testCase "remediationFor: data disk WARN -> cleanup pointer" $
      cmdOf (Probe "data disk" StatusWarn "92% of 100G")
        `containsT` "nagarectl cleanup"
  , testCase "remediationFor: backup WARN -> backup-postgres script" $
      cmdOf (Probe "backup postgres" StatusWarn "newest object 9d ago")
        `containsT` "scripts/backup-postgres.sh"
  , testCase "remediationFor: UNKNOWN -> 'could not check' why" $
      whyOf (Probe "k3s node" StatusUnknown "no kubeconfig / not reachable")
        `startsWithT` "could not check"
  , testCase "remediationFor: uncatalogued non-OK probe gets a generic hint" $
      cmdOf (Probe "mystery" StatusFail "boom") @?= "see docs/runbooks/"
  , testCase "doctorExitOk: False iff any FAIL" $
      doctorExitOk (gradeChecks [Probe "VM" StatusOk "RUNNING", Probe "k3s node" StatusFail "NotReady"])
        @?= False
  , testCase "doctorExitOk: True when only OK/WARN" $
      doctorExitOk (gradeChecks [Probe "VM" StatusOk "RUNNING", Probe "backup postgres" StatusWarn "9d ago"])
        @?= True
  , testCase "formatDoctor: header, FAIL tag, fix line, and summary" $ do
      let out = formatDoctor (gradeChecks [Probe "VM" StatusFail "TERMINATED", Probe "k3s node" StatusOk "Ready"])
      assertBool "header" ("nagare doctor — 2 checks" `T.isInfixOf` out)
      assertBool "FAIL tag" ("[FAIL]" `T.isInfixOf` out)
      assertBool "fix line" ("fix: gcloud compute instances start" `T.isInfixOf` out)
      assertBool "summary" ("1 failed, 0 warnings, 1 ok." `T.isInfixOf` out)
  ]
  where
    cmdOf p = maybe "" remCommand (remediationFor p)
    whyOf p = maybe "" remWhy (remediationFor p)
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
    , tasks = []
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
        }
    stsListJson =
      BC.pack
        "{\"items\":[{\"metadata\":{\"name\":\"pg-main\",\"namespace\":\"personal\",\"labels\":{\"nagare.dev/engine\":\"postgres\",\"nagare.dev/managed-by\":\"nagarectl\"},\"annotations\":{\"nagare.dev/version\":\"18\",\"nagare.dev/size\":\"10Gi\",\"nagare.dev/retention\":\"Retain\"}},\"status\":{\"readyReplicas\":1}}]}"

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
    }

backupRestoreTests :: [TestTree]
backupRestoreTests =
  [ testGroup
      "pure path / extension / schedule"
      [ testCase "dbBackupObjectPath builds databases/<name>/<ts>.<ext>" $
          dbBackupObjectPath "mydb" "20260610T141503Z" "sql.gz" @?= "databases/mydb/20260610T141503Z.sql.gz"
      , testCase "dbBackupGsUrl prepends gs://<bucket>/" $
          dbBackupGsUrl "b" "mydb" "20260610T141503Z" "sql.gz" @?= "gs://b/databases/mydb/20260610T141503Z.sql.gz"
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
      [ testCase "isGsUrl" $ do
          isGsUrl "gs://b/x" @?= True
          isGsUrl "20260610T141503Z" @?= False
      , testCase "resolveBackupObject composes a bare timestamp" $
          resolveBackupObject "b" "mydb" "sql.gz" "20260610T141503Z" @?= "gs://b/databases/mydb/20260610T141503Z.sql.gz"
      , testCase "resolveBackupObject passes a full URL through" $
          resolveBackupObject "b" "mydb" "sql.gz" "gs://other/x.sql.gz" @?= "gs://other/x.sql.gz"
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
