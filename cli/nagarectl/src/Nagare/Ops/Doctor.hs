-- | The @nagarectl doctor@ remediation knowledge base and checklist renderer
-- (MasterPlan 8, EP-39).
--
-- @doctor@ re-grades the very same probes "Nagare.Ops.Status" gathers (the IP1
-- 'Probe'/'ProbeStatus' types) into an actionable triage list: each non-OK probe
-- is paired with a plain-language /why/ and the exact command an operator would
-- paste to fix it. Everything here is pure — 'remediationFor', 'gradeChecks',
-- 'formatDoctor', and 'doctorExitOk' — so the whole knowledge base is
-- unit-testable without a cluster. The command wiring (calling 'gatherInventory'
-- and translating 'doctorExitOk' into a process exit code) lives in
-- @app/Main.hs@.
--
-- The knowledge base keys off EP-38's committed 'probeName' display values
-- (e.g. @"VM"@, @"k3s node"@, @"Knative controller"@). EP-38 ships display-only
-- names and no separate machine key, so those names are the stable matching key
-- (see the Decision Log in
-- @docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md@). A
-- non-OK probe whose name is not catalogued still gets a generic hint, so
-- @doctor@ never prints a bare red line.
module Nagare.Ops.Doctor
  ( Remediation (..)
  , Check (..)
  , remediationFor
  , remediationForAt
  , gradeChecks
  , gradeChecksAt
  , formatDoctor
  , doctorExitOk
  )
where

import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Ops.Probe (Probe (..), ProbeStatus (..))
import Nagare.Target (TargetProfile (..))
import System.FilePath ((</>))

-- ---------------------------------------------------------------------------
-- Model

-- | A remediation: a plain-language explanation of what is wrong and the exact
-- command (or short pointer) to run to fix it.
data Remediation = Remediation
  { remWhy :: !Text
  , remCommand :: !Text
  }
  deriving stock (Eq, Show)

-- | One graded check: the underlying probe plus its remediation hint (absent for
-- an @OK@ probe).
data Check = Check
  { checkProbe :: !Probe
  , checkHint :: !(Maybe Remediation)
  }
  deriving stock (Show)

-- ---------------------------------------------------------------------------
-- Grading

-- | Grade probes into checks, preserving EP-38's probe order so the checklist
-- reads top-down exactly like @server status@.
gradeChecks :: TargetProfile -> [Probe] -> [Check]
gradeChecks tp = map (\p -> Check p (remediationFor tp p))

gradeChecksAt :: FilePath -> FilePath -> FilePath -> TargetProfile -> [Probe] -> [Check]
gradeChecksAt root pulumiDir iapSsh tp = map (\p -> Check p (remediationForAt root pulumiDir iapSsh tp p))

-- | The knowledge base: map a probe to a remediation hint. 'Nothing' for an
-- @OK@ probe. A 'StatusUnknown' probe always yields a @"could not check; …"@
-- hint (it renders as @WARN@, never @FAIL@). All other non-OK probes get the
-- catalogued /why/ and command, falling back to a generic pointer for any probe
-- name not yet catalogued.
remediationFor :: TargetProfile -> Probe -> Maybe Remediation
remediationFor = remediationForAt "." "infra/pulumi" "scripts/iap-ssh.sh"

remediationForAt :: FilePath -> FilePath -> FilePath -> TargetProfile -> Probe -> Maybe Remediation
remediationForAt root pulumiDir iapSsh tp p = case probeStatus p of
  StatusOk -> Nothing
  StatusUnknown ->
    Just
      Remediation
        { remWhy = "could not check; " <> probeDetail p
        , remCommand = commandAt root pulumiDir iapSsh tp (probeName p)
        }
  _ ->
    Just
      Remediation
        { remWhy = why tp (probeName p) (probeDetail p)
        , remCommand = commandAt root pulumiDir iapSsh tp (probeName p)
        }

-- | The catalogued plain-language /why/ for a non-OK probe name. Falls back to
-- echoing the live detail when the name is not catalogued.
why :: TargetProfile -> Text -> Text -> Text
why tp name detail
  | name == "VM" = "The VM " <> tpInstanceName tp <> " is powered off."
  | name == "k3s node" = "kubectl cannot reach the k3s cluster (or your context points at the wrong cluster)."
  | isDeploy name = "The " <> name <> " control plane is not ready."
  | name == "ClusterIssuer" = "TLS issuance is not ready."
  | name == "Kourier ingress" = "The gateway is not reachable on the reserved public IP (and could not be confirmed fronting the node)."
  | name == "base domain" = "The cluster's configured base domain disagrees with infrastructure."
  | name == "external-domain-tls" = "External-domain TLS is disabled (HTTP-first)."
  | name == "Artifact Registry" = "Image push auth is not configured."
  | name == "private image pull" = "The cluster is not configured to pull private images from the project Artifact Registry."
  | name == "build platform" = "The configured build platform does not match the cluster node architecture; images built here will not run on the node."
  | name == "platform version" = detail
  | isDisk name = "Disk is filling up."
  | isBackup name = "No recent backup object found."
  | otherwise = detail

-- | The catalogued remediation command for a probe name (used for both @FAIL@
-- and @UNKNOWN@ — the fix is the same: make the source reachable / healthy).
commandAt :: FilePath -> FilePath -> FilePath -> TargetProfile -> Text -> Text
commandAt root pulumiDir iapSsh tp name
  | name == "VM" =
      "gcloud compute instances start " <> tpInstanceName tp <> " --zone=" <> tpZone tp
  | name == "k3s node" =
      "point kubectl at the k3s cluster — the workstation default context often points at the unrelated "
        <> "GKE cluster tan-cluster; retrieve the k3s kubeconfig per "
        <> asset "docs/runbooks/cluster-access.md"
  | isDeploy name =
      let (dep, ns, readme) = deployTarget name
       in "kubectl rollout status deploy/" <> dep <> " -n " <> ns <> "; consult " <> asset (T.unpack readme)
  | name == "ClusterIssuer" =
      "kubectl get clusterissuer letsencrypt-dns -o yaml "
        <> "(note: TLS is HTTP-first/deferred while the base domain is the placeholder apps.example.com)"
  | name == "Kourier ingress" =
      "curl -sS -o /dev/null -w '%{http_code}\\n' http://$(pulumi -C "
        <> T.pack pulumiDir
        <> " stack output publicIp)/ "
        <> "(active context stack); "
        <> "also: kubectl get svc -n kourier-system kourier -o wide; kubectl get nodes -o wide"
  | name == "private image pull" =
      "apply the declarative private-image-pull config (config-deployment registriesSkippingTagResolving "
        <> "+ node registries.yaml) per "
        <> asset "docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md"
  | name == "build platform" =
      "set NAGARE_TARGET_PLATFORM (e.g. linux/amd64) in nagare.target.env to match the node architecture; "
        <> "see "
        <> asset "docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md"
  | name == "platform version" =
      "nagarectl platform status; use `nagarectl platform adopt` for verified legacy contexts or `nagarectl platform upgrade` for release skew"
  | name == "base domain" =
      "re-render config-domain from the active context stack: pulumi -C "
        <> T.pack pulumiDir
        <> " stack output baseDomain "
        <> "(see "
        <> asset "cluster/bootstrap/knative-serving/README.md"
        <> ")"
  | name == "external-domain-tls" =
      "expected while the base domain is the placeholder apps.example.com; "
        <> "enable once a real DNS-01-capable domain is set ("
        <> asset "cluster/bootstrap/net-certmanager/README.md"
        <> ")"
  | name == "Artifact Registry" =
      "gcloud auth configure-docker "
        <> tpRegistryHost tp
        <> "; "
        <> "verify the nagare-node service account holds roles/artifactregistry.writer"
  | isDisk name =
      "inspect: SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 "
        <> T.pack iapSsh
        <> " ssh "
        <> tpInstanceName tp
        <> " -- 'df -h'; "
        <> "then run nagarectl cleanup once available (EP-41)"
  | isBackup name = "take an on-demand managed-DB backup: nagarectl db backup <name>; consult " <> asset "docs/runbooks/disaster-recovery.md"
  | otherwise = "see " <> asset "docs/runbooks/"
  where
    asset relative
      | root == "." = T.pack relative
      | otherwise = T.pack (root </> relative)

-- | Whether a probe name is one of the control-plane Deployment rollouts.
isDeploy :: Text -> Bool
isDeploy name = name `elem` deployNames
  where
    deployNames =
      [ "Knative controller"
      , "Knative webhook"
      , "Kourier gateway"
      , "cert-manager"
      , "cert-manager-webhook"
      , "cert-manager-cainjector"
      , "net-certmanager"
      ]

-- | The @(deployment, namespace, readme)@ rollout target for a control-plane
-- probe name.
deployTarget :: Text -> (Text, Text, Text)
deployTarget name = case name of
  "Knative controller" -> ("controller", "knative-serving", "cluster/bootstrap/knative-serving/README.md")
  "Knative webhook" -> ("webhook", "knative-serving", "cluster/bootstrap/knative-serving/README.md")
  "Kourier gateway" -> ("3scale-kourier-gateway", "kourier-system", "cluster/bootstrap/kourier/README.md")
  "cert-manager" -> ("cert-manager", "cert-manager", "cluster/bootstrap/cert-manager/README.md")
  "cert-manager-webhook" -> ("cert-manager-webhook", "cert-manager", "cluster/bootstrap/cert-manager/README.md")
  "cert-manager-cainjector" -> ("cert-manager-cainjector", "cert-manager", "cluster/bootstrap/cert-manager/README.md")
  "net-certmanager" -> ("net-certmanager-controller", "knative-serving", "cluster/bootstrap/net-certmanager/README.md")
  _ -> ("<deploy>", "<namespace>", "cluster/bootstrap/")

-- | Whether a probe name is a disk-usage probe (@"boot disk"@, @"data disk"@, or
-- the degraded @"disk"@ line).
isDisk :: Text -> Bool
isDisk name = name == "disk" || " disk" `T.isSuffixOf` name

-- | Whether a probe name is a backup-freshness probe (@"backup postgres"@, …).
isBackup :: Text -> Bool
isBackup name = "backup " `T.isPrefixOf` name

-- ---------------------------------------------------------------------------
-- Rendering

-- | Render the graded checks as an ordered checklist: a header, one or two lines
-- per check (a @[TAG] name detail-or-why@ line plus an indented @fix:@ line for
-- non-OK checks with a hint), and a @"<f> failed, <w> warnings, <o> ok."@
-- summary. Pure — no clock, no IO.
formatDoctor :: [Check] -> Text
formatDoctor checks =
  T.unlines $
    [header, ""]
      <> concatMap renderCheck checks
      <> ["", summary]
  where
    header = "nagare doctor — " <> tshow (length checks) <> " checks"
    summary =
      tshow (count StatusFail)
        <> " failed, "
        <> tshow (countWarn)
        <> " warnings, "
        <> tshow (count StatusOk)
        <> " ok."

    count st = length [() | c <- checks, probeStatus (checkProbe c) == st]
    -- WARN and UNKNOWN both render as a WARN line.
    countWarn = length [() | c <- checks, let s = probeStatus (checkProbe c), s == StatusWarn || s == StatusUnknown]

    renderCheck (Check p mhint) =
      let line1 =
            "  "
              <> pad 8 ("[" <> tag (probeStatus p) <> "]")
              <> pad 25 (probeName p)
              <> trailing
          trailing = case mhint of
            Just rem' | probeStatus p /= StatusOk -> remWhy rem'
            _ -> probeDetail p
       in case mhint of
            Just rem' -> [line1, "          fix: " <> remCommand rem']
            Nothing -> [line1]

    tag StatusOk = "OK"
    tag StatusWarn = "WARN"
    tag StatusUnknown = "WARN"
    tag StatusFail = "FAIL"

    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "
    tshow = T.pack . show

-- | 'True' iff no check is a hard 'StatusFail' — i.e. the process should exit 0.
-- @WARN@/@UNKNOWN@/@OK@ do not affect the exit code.
doctorExitOk :: [Check] -> Bool
doctorExitOk = not . any isFail
  where
    isFail c = probeStatus (checkProbe c) == StatusFail
