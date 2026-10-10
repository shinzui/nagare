-- | Operations responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Operations
  ( cleanupTests
  , doctorTests
  , opsTests
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (UTCTime), fromGregorian)
import InventoryCleanupSpec (inventoryCleanupTests)
import InventoryPreviewCleanupSpec (inventoryPreviewCleanupTests)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Inventory.BackupFreshness (BackupFreshness (..), RecoveryPointGrade (RecoveryPointGrade), RecoveryPointObjective (..))
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
  ( doctorExitOk
  , formatDoctor
  , gradeChecks
  , remediationFor
  )
import Nagare.Ops.Probe
  ( KourierEvidence (..)
  , Probe (..)
  , ProbeStatus (..)
  , backupPrefixes
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
  , recoveryPointProbe
  , renderInventory
  , statusLabel
  )
import Nagare.Ops.Status (parseHostAgeKeyProbe)
import Nagare.Static.Release
  ( StaticRelease (..)
  , StaticReleaseLog (StaticReleaseLog)
  )
import Nagare.Test.Support.Profiles (tnbProfile)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

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
      (gradeKourier (KourierEvidence (Just "10.10.0.4") (Just "34.145.74.203") (Just "404") Nothing)) ^. #status @?= StatusOk
  , testCase "gradeKourier: no curl, node ExternalIP fronts publicIp -> OK" $
      (gradeKourier (KourierEvidence (Just "10.10.0.4") (Just "34.145.74.203") Nothing (Just "34.145.74.203"))) ^. #status @?= StatusOk
  , testCase "gradeKourier: no curl, node ExternalIP differs from publicIp -> FAIL" $
      (gradeKourier (KourierEvidence (Just "10.10.0.4") (Just "34.145.74.203") Nothing (Just "9.9.9.9"))) ^. #status @?= StatusFail
  , testCase "gradeKourier: inconclusive (no curl, no node ExternalIP) -> WARN not FAIL" $
      (gradeKourier (KourierEvidence (Just "10.10.0.4") (Just "34.145.74.203") Nothing Nothing)) ^. #status @?= StatusWarn
  , testCase "gradeKourier: no LB EXTERNAL-IP -> FAIL" $
      (gradeKourier (KourierEvidence Nothing (Just "34.145.74.203") Nothing Nothing)) ^. #status @?= StatusFail
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
      (gradeArch "linux/amd64" "amd64") ^. #status @?= StatusOk
  , testCase "gradeArch: linux/arm64 on amd64 node -> WARN" $
      (gradeArch "linux/arm64" "amd64") ^. #status @?= StatusWarn
  , testCase "gradeArch: linux/arm64/v8 on arm64 node -> OK (ignores variant)" $
      (gradeArch "linux/arm64/v8" "arm64") ^. #status @?= StatusOk
  , testCase "parseConfigDomain: returns the domain key, skips _example" $
      parseConfigDomain configDomainJson @?= Just "apps.example.com"
  , testCase "parseClusterIssuerReady: Ready=True" $
      parseClusterIssuerReady clusterIssuerJson @?= Just True
  , testCase "parseNewestBackupAge: picks the max timestamp, ignores TOTAL:" $
      parseNewestBackupAge gsutilLs @?= Just "2026-06-09T03:00:01Z"
  , testCase "parseNewestBackupAge: empty prefix" $
      parseNewestBackupAge "" @?= Nothing
  , testCase "backupPrefixes: databases and volumes are graded by receipts, not object age" $
      backupPrefixes ["notes", "shop"] @?= ["litestream"]
  , testCase "recoveryPointProbe: fresh, warning, breach and unknown grades" $ do
      let hourly value = RecoveryPointGrade HourlyRecoveryPoint value False
      recoveryPointProbe "personal/notes" (Right (hourly (Fresh 120)))
        @?= Probe "recovery point" StatusOk "personal/notes: healthy; age=120s; objective=hourly"
      recoveryPointProbe "personal/notes" (Right (RecoveryPointGrade DailyRecoveryPoint (Fresh 600) True))
        @?= Probe "recovery point" StatusOk "personal/notes: healthy; age=600s; objective=daily; newest point is verified and awaits reviewed ingestion"
      status (recoveryPointProbe "personal/notes" (Right (hourly (Deteriorating 1900)))) @?= StatusWarn
      map (status . recoveryPointProbe "personal/notes" . Right . hourly) [Breached 3600, NoRecoveryPoint, FutureRecoveryPoint]
        @?= [StatusFail, StatusFail, StatusFail]
      recoveryPointProbe "personal/notes" (Left "object store unavailable")
        @?= Probe "recovery point" StatusUnknown "personal/notes: receipts unobservable: object store unavailable"
  , testCase "parseDfUsage: data mount" $
      parseDfUsage dfOutput "/var/lib/nagare" @?= Just "12% of 100G"
  , testCase "parseDfUsage: boot mount" $
      parseDfUsage dfOutput "/" @?= Just "24% of 100G"
  , testCase "parseDfUsage: absent mount" $
      parseDfUsage dfOutput "/nope" @?= Nothing
  , testCase "IR-18: host age-key ready record grades OK alongside df output" $ do
      let record = "age-key\tready\t/var/lib/sops-nix/age-key.txt\t" <> BC.replicate 64 'a' <> "\n" <> TE.encodeUtf8 dfOutput
          probe = parseHostAgeKeyProbe record
      probe ^. #status @?= StatusOk
      assertBool "ready detail names the configured path" ("ready at /var/lib/sops-nix/age-key.txt" `T.isInfixOf` (probe ^. #detail))
  , testCase "IR-18: confirmed missing and invalid records grade FAIL with actionable detail" $ do
      let missing = parseHostAgeKeyProbe "age-key\tmissing\t/var/lib/sops-nix/age-key.txt\tage key missing at /var/lib/sops-nix/age-key.txt\n"
          invalid = parseHostAgeKeyProbe "age-key\tinvalid\t/var/lib/sops-nix/age-key.txt\texpected root:root mode 0400; found 0:0:644\n"
      missing @?= Probe "host age key" StatusFail "age key missing at /var/lib/sops-nix/age-key.txt"
      invalid ^. #status @?= StatusFail
      assertBool "invalid detail preserves the metadata defect" ("found 0:0:644" `T.isInfixOf` (invalid ^. #detail))
  , testCase "IR-18: malformed, absent, and unsupported host records remain UNKNOWN" $ do
      parseHostAgeKeyProbe "age-key\tready\t/path\tnot-a-digest\n" ^. #status @?= StatusUnknown
      parseHostAgeKeyProbe (TE.encodeUtf8 dfOutput) ^. #status @?= StatusUnknown
      parseHostAgeKeyProbe "age-key\tunknown\t-\thost helper is not installed\n" ^. #status @?= StatusUnknown
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
  [ inventoryCleanupTests
  , inventoryPreviewCleanupTests
  , testCase "pruneReleases: 14-entry log, keep 10 -> 10 kept, 4 removed" $
      let logv = StaticReleaseLog (Just "r14") (map mkRel [14, 13 .. 1])
          (trimmed, removed) = pruneReleases 10 logv
       in (length (trimmed ^. #releases), length removed) @?= (10, 4)
  , testCase "pruneReleases: keeps current even when it is the oldest record" $
      let logv = StaticReleaseLog (Just "r1") (map mkRel [14, 13 .. 1])
          (trimmed, removed) = pruneReleases 3 logv
       in do
            assertBool "current kept" ("r1" `elem` map (^. #releaseId) (trimmed ^. #releases))
            assertBool "current not removed" ("r1" `notElem` map (^. #releaseId) removed)
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
       in map (^. #name) (selectStalePreviews now ttl ps) @?= ["site-pr-stale9", "site-pr-stale21"]
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
        { images = Just (12, 3650722201)
        , stalePreviews = [mkPreview "site-pr-old" (fromGregorian 2026 5 1)]
        , trimmedReleases = [("notes", [mkRel 1])]
        , confirmed = confirmed
        }

-- ---------------------------------------------------------------------------
-- Nagare.Ops.Doctor (MasterPlan 8, EP-39): the pure remediation knowledge base,
-- the checklist renderer, and the exit grade.

doctorTests :: [TestTree]
doctorTests =
  [ testCase "remediationFor: OK probe has no hint" $
      remediationFor tnbProfile (Probe "VM" StatusOk "RUNNING") @?= Nothing
  , testCase "remediationFor: recovery point FAIL -> receipt ingestion" $
      cmdOf (Probe "recovery point" StatusFail "personal/notes: unhealthy; age=4000s; one-hour objective breached")
        `containsT` "nagarectl db backup-receipts"
  , testCase "remediationFor: stuck rollout FAIL -> db restart proposes the replacement (EP-181)" $ do
      let probe' = Probe "stuck rollout personal/pg" StatusFail "pg-0 at revision 9d647 is not Ready and blocks the rollout to d9d6d"
      cmdOf probe' `containsT` "run nagarectl db restart NAME"
      cmdOf probe' `containsT` "review the proposed replace-stuck-pod, then apply it"
      fmap (^. #reason) (remediationFor tnbProfile probe') @?= Just "Its pod at an older revision is not Ready, and Kubernetes will not roll it, so the StatefulSet never runs its reviewed template (pg-0 at revision 9d647 is not Ready and blocks the rollout to d9d6d)."
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
  , testCase "remediationFor: certificate policy FAIL -> focused inventory" $
      cmdOf (Probe "certificate policy" StatusFail "kube-system/wildcard: public wildcard is in an unlabeled namespace")
        `containsT` "kubectl get certificate -A -o yaml"
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
  , testCase "IR-18: host age-key remediation is exact and confirmed absence fails doctor" $ do
      let missing = Probe "host age key" StatusFail "age key missing at /var/lib/sops-nix/age-key.txt"
          ready = Probe "host age key" StatusOk "ready"
          unreachable = Probe "host age key" StatusUnknown "iap-ssh unavailable"
      cmdOf missing @?= "nagarectl host place-age-key --key-file <private-key-file>"
      whyOf missing @?= "The host age key is missing or invalid, so sops-nix cannot activate runtime secrets."
      doctorExitOk (gradeChecks tnbProfile [missing]) @?= False
      doctorExitOk (gradeChecks tnbProfile [ready]) @?= True
      doctorExitOk (gradeChecks tnbProfile [unreachable]) @?= True
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
    cmdOf p = maybe "" (^. #command) (remediationFor tnbProfile p)
    whyOf p = maybe "" (^. #reason) (remediationFor tnbProfile p)
    containsT hay needle = assertBool (T.unpack needle) (needle `T.isInfixOf` hay)
    startsWithT hay needle = assertBool (T.unpack needle) (needle `T.isPrefixOf` hay)
