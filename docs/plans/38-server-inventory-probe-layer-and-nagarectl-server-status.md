---
id: 38
slug: server-inventory-probe-layer-and-nagarectl-server-status
title: "Server inventory probe layer and nagarectl server status"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# Server inventory probe layer and nagarectl server status

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today an operator who wants to know whether the Nagare platform is healthy has to stitch the
answer together by hand: run `gcloud compute instances describe nagare-01` to see if the VM is
even powered on, open an IAP-tunnelled SSH session to run `df -h`, run `kubectl rollout status`
in four namespaces, compare the Kourier `EXTERNAL-IP` against the Pulumi `publicIp` output by
eye, and run `gsutil ls -l` to see when the last backup landed. Nothing ties these together and
nothing tells a newcomer what a bad result means. This plan replaces that scavenger hunt with a
single command that prints a one-screen, aligned health report of the whole platform:

```text
nagarectl server status
```

After this plan, that command prints — in one aligned table — the power state of the VM
`nagare-01` (RUNNING / TERMINATED), whether the k3s node is `Ready`, whether the Knative
Serving / Kourier / cert-manager / net-certmanager control-plane deployments are rolled out, the
live base domain (read from the Pulumi `baseDomain` stack output and cross-checked against the
in-cluster `config-domain` ConfigMap), the Kourier ingress `EXTERNAL-IP` and whether it equals
the reserved `publicIp`, the boot-disk and `/var/lib/nagare` data-disk usage, whether Artifact
Registry push auth is configured, and the age of the most recent object in each backup prefix of
`gs://tan-nb-exp-nagare-backups/`. Every line is tagged `OK` / `WARN` / `UNKNOWN` / `FAIL`, and a
probe whose data source is unreachable (the VM is off, no kubeconfig, `gsutil`/`pulumi` not on
PATH) degrades to an `UNKNOWN`/`WARN` line with a short hint rather than crashing the command — so
the report is always printed, partial-but-clear, never a stack trace.

Underneath the command, this plan builds a reusable, typed probe layer under
`cli/nagarectl/src/Nagare/Ops/` (modules `Nagare.Ops.Probe`, `Nagare.Ops.Pulumi`,
`Nagare.Ops.Status`) whose pure parsers and formatters are unit-tested without a live cluster.
That layer is the foundation that the sibling plans build on: `nagarectl doctor`
(`docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md`) re-grades the same
`Probe` values into remediation checks, and `nagarectl domains list`
(`docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md`) and
`nagarectl cleanup` (`docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md`) reuse
its base-domain resolver and table formatting.

You can see it working end-to-end: with your `kubectl` context pointing at the k3s cluster and
`gcloud`/`pulumi`/`gsutil` on PATH, run `nagarectl server status`. It prints a table whose first
line is the VM power state and whose remaining lines walk down the platform — node, control
planes, ingress IP match, base domain match, disk usage, registry auth, backup ages — each marked
`OK`/`WARN`/`UNKNOWN`/`FAIL`. Power the VM off (`gcloud compute instances stop nagare-01
--zone=us-west1-a`) and re-run: the VM line reads `FAIL TERMINATED`, the k3s/control-plane/disk
lines that depend on the VM degrade to `UNKNOWN` with a hint, and the command still exits cleanly
having printed the whole report.


## Progress

- [x] M1 (2026-06-10): `Nagare.Ops.Probe` (the `ProbeStatus`/`Probe` types, `InventoryOpts`, the external-tool wrappers `captureTool`/`runMaybe`, and the pure parsers/formatters) plus `Nagare.Ops.Pulumi.stackOutput`; both added to the cabal library; `testGroup "Nagare.Ops"` (16 cases) covering the pure helpers — all green.
- [x] M2 (2026-06-10): `gatherInventory` in `Nagare.Ops.Status` wiring every probe (VM, k3s node, Knative controller/webhook, Kourier gateway, cert-manager + webhook + cainjector, net-certmanager, ClusterIssuer, Kourier IP vs publicIp, base domain, external-domain-tls info, registry auth, backup freshness ×3, boot+data disk) with graceful degradation; compiles, typechecks.
- [ ] M3: `server status` command registered in `cli/nagarectl/app/Main.hs` (a `server` group whose first subcommand is `status`); the `runServerStatus` handler renders the report via `renderInventory`.
- [ ] M4: `nagarectl-test` green + `--help` transcript captured below; live cluster run deferred (no cluster mutated / VM not powered on during implementation).


## Surprises & Discoveries

(None yet — to be recorded as implementation proceeds.)


## Decision Log

- Decision: Bundle the reusable probe layer with `nagarectl server status` in this one plan rather
  than shipping a behavior-less "foundations" plan. The probe types (`ProbeStatus`/`Probe`), the
  external-tool wrappers, and the pure parsers/formatters live in `cli/nagarectl/src/Nagare/Ops/`
  and are exercised by `server status` as their first real consumer.
  Rationale: A foundation plan with no user-visible behavior would violate the MasterPlan
  requirement that every work stream produce a demonstrable outcome; folding `server status` in
  gives the foundation a runnable proof while still leaving the types as the dependency root EP-39
  consumes.
  Date: 2026-06-09

- Decision: The access model is: `kubectl` runs against the operator's *ambient* context exactly as
  every existing `nagarectl` command assumes (no kubeconfig management, no `--context` flag);
  `gcloud`/`pulumi`/`gsutil` run locally and default to project `tan-nb-exp` (region `us-west1`,
  zone `us-west1-a`) per the repo's `.envrc`, with explicit flags where reasonable; the VM disk
  probe is best-effort over `scripts/iap-ssh.sh` invoked as `SSH_USER=deploy
  SSH_KEY=~/.ssh/id_ed25519`.
  Rationale: Matches the assumption of every existing command and the project-isolation rule in
  `CLAUDE.md`. The workstation's *default* kubectl context points at an unrelated GKE cluster
  (`tan-cluster`), so the report documents that pitfall but does not try to fix the operator's
  context for them.
  Date: 2026-06-09

- Decision: Backup freshness is defined purely as the age of the *newest* object in each GCS backup
  prefix (`gs://tan-nb-exp-nagare-backups/{postgres,litestream,volumes}/`), read via `gsutil ls -l`.
  Rationale: No host-level backup systemd timer exists yet — backups are manual scripts under
  `scripts/` (e.g. `scripts/backup-postgres.sh`) — so there is no schedule to compare against;
  "freshness" can only mean "how long since the last object landed". Building a scheduler is out of
  scope (it belongs to a future databases/backups initiative).
  Date: 2026-06-09

- Decision: The base-domain probe reads the authoritative value from Pulumi (`pulumi -C
  infra/pulumi stack output baseDomain`) via a new `Nagare.Ops.Pulumi.stackOutput` helper and
  cross-checks it against the in-cluster `config-domain` ConfigMap; the existing `resolveBaseDomain`
  in `cli/nagarectl/app/Main.hs` (which reads only a flag/env/literal fallback) is left untouched
  for the deploy path.
  Rationale: `resolveBaseDomain` deliberately does not read Pulumi and must keep its
  flag/env/literal behavior for offline deploys; the *probe* needs the authoritative Pulumi value to
  meaningfully report drift. EP-40 (`domains list`) reuses `Nagare.Ops.Pulumi.stackOutput` rather
  than re-implementing it.
  Date: 2026-06-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan lives entirely in the `cli/nagarectl` package (the CLI). It adds three new library
modules and one new command; it touches no DSL types and no infrastructure code. You need to
understand five things: how the CLI is structured, how it shells out, the exact precedents to copy,
where the ground-truth for each probe lives, and how the test suite is organized.

**The CLI structure.** `cli/nagarectl/app/Main.hs` (~1462 lines) is the entry point; it uses
`optparse-applicative`. A sum type `Command` (around line 232) enumerates every operation
(`Deploy`, `SiteDeploy`, the `app*` constructors, the `deployments*` constructors, …).
`opts :: ParserInfo Command` (around line 540) builds a top-level `subparser` (around line 549)
with `command "deploy" …`, `command "site" …`, `command "app" …`, `command "deployments" …`; the
`site` and `app` commands are themselves *nested* subparsers, which is the precedent for a command
group. `main` (around line 776) does `execParser opts >>= \case …`, dispatching each constructor to
a `runX` handler. To add a command you (1) define an `XOpts` record and an `xOptsParser :: Parser
XOpts`, (2) add a `Command` constructor, (3) register `command "x" xCmd` in the subparser, (4) add a
`runX` handler, and (5) add a dispatch arm in `main`. For `server status` you add a `server`
*group* whose nested subparser's first (and, in this plan, only) subcommand is `status` — mirror the
`app`/`site` nested-subparser shape exactly. Reusable Main helpers you will lean on: `dieT :: Text
-> IO a` (prints `nagarectl: <msg>` to stderr and `exitFailure`); and note `resolveBaseDomain`
(around line 1446) reads only a `--base-domain` flag, then `$NAGARE_BASE_DOMAIN`, then the literal
`"apps.example.com"` — it does **not** read Pulumi, and you leave it in place (see the Decision Log).

**How it shells out.** All subprocess calls go through the `cradle` library (already a dependency).
The patterns, copied from `cli/nagarectl/src/Nagare/App.hs` and `cli/nagarectl/src/Nagare/Image.hs`:

```haskell
import Cradle
-- Fire and forget (inherit stdout/stderr); throws on non-zero exit:
run_ $ cmd "gcloud" & addArgs ["auth", "configure-docker", "us-west1-docker.pkg.dev", "--quiet"]
-- Capture stdout, tolerate a non-zero exit (the key shape for probes):
(exitCode, StdoutRaw out) <- run $ cmd "kubectl" & addArgs ["get", "nodes", "-o", "json"] & silenceStderr
-- StdoutRaw / StdoutUntrimmed are cradle output wrappers; pattern-match to get the bytes/text.
```

`run` returns an `(ExitCode, StdoutRaw)` pair and never throws on a non-zero exit — that is exactly
what every probe needs, because a probe must turn "the tool failed / is missing" into a `StatusUnknown`
line, not an exception. `silenceStderr` keeps the child's stderr off the operator's terminal so the
report stays clean. A tool that is not on PATH makes `run` throw an `IOException`; wrap each probe's
IO in a `try`/`catch` (or a small `runMaybe` helper, see M1) so even a missing binary degrades to
`StatusUnknown`.

**The precedents to copy.** `cli/nagarectl/src/Nagare/App.hs` is the closest template and you should
read it before writing anything. It already shows: the capture-and-tolerate shape
(`appDomains`/`extractDomainsFor`, around lines 348-373, which runs `kubectl get domainmapping -n
<ns> -o json`, tolerates a non-zero exit, and Aeson-walks the JSON defensively); the readiness
extractor pattern (`readyOf`, which reads `.status.conditions[]` where `type=="Ready"` and treats
ready as `status=="True"`); the JSON walk helpers `lookupPath`/`textAt` (around lines 240-265); and
the aligned-table formatter `formatAppList` with its `pad` helper
(`pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "`, around lines
269-283) — copy that `pad` verbatim for the status table. `cli/nagarectl/src/Nagare/Image.hs` shows
the registry plumbing: `configureDockerAuth` runs `gcloud auth configure-docker
us-west1-docker.pkg.dev --quiet`, and `registryHost = "us-west1-docker.pkg.dev"`.

**Where ground truth lives.** Each probe inspects exactly one of these sources:

- *VM power* — `gcloud compute instances describe nagare-01 --zone=us-west1-a
  --format='value(status)'` prints `RUNNING` or `TERMINATED`. The VM is often left `TERMINATED` to
  save cost; the remediation (printed by EP-39, not here) is `gcloud compute instances start
  nagare-01 --zone=us-west1-a`.
- *Pulumi stack outputs* — `pulumi -C infra/pulumi stack output <name>` (state is file-backed in-repo
  per `CLAUDE.md`: `login file://./infra/pulumi/.pulumi-state`, passphrase provider; `.envrc` sets
  `PULUMI_HOME`/`PULUMI_CONFIG_PASSPHRASE`). The outputs (defined in `infra/pulumi/index.ts`) this
  plan reads are `publicIp`, `baseDomain` (currently the placeholder `apps.example.com`),
  `backupBucket` (`tan-nb-exp-nagare-backups`), and `artifactRegistry`
  (`us-west1-docker.pkg.dev/tan-nb-exp/nagare`).
- *k3s node* — `kubectl get nodes -o json`; the node's `Ready` condition lives at
  `.items[0].status.conditions[] | select(.type=="Ready") | .status == "True"`. On the VM directly
  it is `sudo k3s kubectl …` with kubeconfig `/etc/rancher/k3s/k3s.yaml`, but `nagarectl` assumes the
  operator's *ambient* kubectl context already points at the cluster.
- *Knative Serving* (namespace `knative-serving`, version `knative-v1.22.0`) — deployments
  `controller`, `webhook`; rollout health read from each Deployment's `.status` conditions /
  `availableReplicas` via `kubectl get deploy -n knative-serving -o json`.
- *Kourier ingress* (namespace `kourier-system`) — `kubectl get svc kourier -n kourier-system -o
  json`; it is a `LoadBalancer`, and `.status.loadBalancer.ingress[0].ip` (the `EXTERNAL-IP`) MUST
  equal the Pulumi `publicIp` output.
- *cert-manager* (namespace `cert-manager`) — deployments `cert-manager`, `cert-manager-webhook`,
  `cert-manager-cainjector`, plus the `ClusterIssuer` `letsencrypt-dns` whose readiness is
  `kubectl get clusterissuer letsencrypt-dns -o json` → `.status.conditions[] |
  select(.type=="Ready")`. The Knative TLS controller `net-certmanager-controller` (frozen at
  `v1.14.0`) lives in the `knative-serving` namespace, not `cert-manager`.
- *base domain* — compare the Pulumi `baseDomain` output to the in-cluster `config-domain`
  ConfigMap: `kubectl get configmap config-domain -n knative-serving -o json` (the domain is a
  top-level key under `.data`). Separately, the `config-network-tls` ConfigMap currently has
  `external-domain-tls` *Disabled* (HTTP-first, because the placeholder `apps.example.com` cannot
  pass DNS-01) — report that as *informational*, not a failure.
- *disk usage* — SSH to the VM and run `df -h /var/lib/nagare /`. The boot disk is 100 GB (containerd
  image store + `/nix/store`); the data disk is a 100 GB `pd-balanced` volume mounted at
  `/var/lib/nagare` with subdirs `victoria-metrics/ victoria-logs/ victoria-traces/ postgres/
  sqlite/ backups/ local-path/`. Access is IAP-tunnelled (port 22 is firewalled to the IAP range
  `35.235.240.0/20`); invoke it as `SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh
  nagare-01 -- 'df -h /var/lib/nagare /'`.
- *Artifact Registry auth* — `gcloud artifacts repositories describe nagare --location=us-west1`
  succeeds when auth is good (the node SA `nagare-node` holds `roles/artifactregistry.writer`, and a
  docker credHelper entry exists for `us-west1-docker.pkg.dev`).
- *backup freshness* — `gsutil ls -l gs://tan-nb-exp-nagare-backups/postgres/` (also `litestream/`,
  `volumes/`); the newest object's timestamp is the freshness signal (see the Decision Log).

The two runbooks this command automates are `docs/runbooks/cluster-access.md` (VM start, IAP SSH as
`deploy`, kubeconfig setup, and the GKE-default-context pitfall) and
`docs/runbooks/disaster-recovery.md` (its backup-inventory table around lines 21-37 and the per-step
"observe" assertions in its rebuild sequence — those assertions *are* the health checks this command
performs).

**The pitfall to document.** The workstation's *default* kubectl context points at an unrelated GKE
cluster (`tan-cluster`). Never trust the default: the operator must point `kubectl` at the k3s
cluster before `server status` is meaningful. When the k3s node probe sees something that looks like
a non-k3s cluster (or nothing), it degrades to `UNKNOWN` with a hint to check the context, rather
than reporting a healthy GKE node as if it were `nagare-01`.

**The test suite.** `cli/nagarectl/test/Spec.hs` uses `tasty` + `tasty-hunit`, grouped by module
(`testGroup "Nagare.App" […]`, etc.), and tests *pure* helpers only — never the `kubectl`/`gcloud`
IO. You will add a `testGroup "Nagare.Ops"` exercising the pure parsers (node-ready, deployment
rollout, Kourier IP, config-domain extraction, `gsutil ls -l` newest-age, `df -h` parse) and the
formatter, asserting with `@?=` against hand-written JSON / text fixtures. No tool is mocked; the
live cluster run is deferred.

**The cabal file.** `cli/nagarectl/nagarectl.cabal` lists library `exposed-modules` (currently
`Nagare.App`, `Nagare.App.Deployments`, `Nagare.Build`, …, `Nagare.Server.Build`,
`Nagare.Server.Deploy`, `Nagare.Server.Image`, `Nagare.Static.*`). You add `Nagare.Ops.Probe`,
`Nagare.Ops.Pulumi`, and `Nagare.Ops.Status` there. The new modules need no dependency the
library does not already have (`aeson`, `bytestring`, `containers`, `cradle`, `text`, `time`,
`vector`).

Note the namespace choice: the `Nagare.Server.*` namespace is **already taken** by the
full-stack server-runtime hosting feature (`Nagare.Server.Build`, `Nagare.Server.Deploy`,
`Nagare.Server.Image` from `docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md`),
where "Server" means *a user's server-side application*, not the physical host. To avoid
conflating the two unrelated concerns, this initiative's operator/inventory layer lives
under `Nagare.Ops.*` instead. Every plan in MasterPlan 8 uses `Nagare.Ops.*` for the new
probe, Pulumi, doctor, domains, and cleanup modules.


## Plan of Work

### Milestone 1 — `Nagare.Ops.Probe` types, tool wrappers, and pure parsers

Scope: create `cli/nagarectl/src/Nagare/Ops/Probe.hs` (the typed model, the external-tool
wrappers, and the pure parsers/formatters) and `cli/nagarectl/src/Nagare/Ops/Pulumi.hs` (the
Pulumi-reading helper), add both to the cabal library, and unit-test the pure helpers. After this
milestone the modules compile and are exported, the pure parsers are green under test, but no probe
is wired into a command yet.

Create `cli/nagarectl/src/Nagare/Ops/Probe.hs` exporting the IP1 typed model and the helpers:

```haskell
module Nagare.Ops.Probe
  ( -- * The typed probe model (Integration Point IP1)
    ProbeStatus (..)
  , Probe (..)
  , InventoryOpts (..)
    -- * Rendering
  , renderInventory
  , statusLabel
    -- * Tool wrappers (Integration Point IP4)
  , captureTool
  , runMaybe
    -- * Pure parsers (unit-tested)
  , parseNodeReady
  , parseDeploymentReady
  , parseKourierIp
  , parseConfigDomain
  , parseClusterIssuerReady
  , parseNewestBackupAge
  , parseDfUsage
  ) where
```

The model is fixed here and read back verbatim by EP-39/40/41, so finalize the field names now:

```haskell
data ProbeStatus = StatusOk | StatusWarn | StatusUnknown | StatusFail
  deriving stock (Eq, Show)

data Probe = Probe
  { probeName   :: !Text   -- "VM", "k3s node", "Kourier ingress", "base domain", ...
  , probeStatus :: !ProbeStatus
  , probeDetail :: !Text   -- "RUNNING", "EXTERNAL-IP 34.x = publicIp", "data 12% of 100G", ...
  }
  deriving stock (Eq, Show)

-- Knobs gatherInventory reads; kept a record so EP-39 can add fields without breaking callers.
data InventoryOpts = InventoryOpts
  { ioZone        :: !Text     -- "us-west1-a"
  , ioInstance    :: !Text     -- "nagare-01"
  , ioPulumiDir   :: !FilePath -- "infra/pulumi"
  , ioSkipVm      :: !Bool     -- when True, skip the IAP-SSH disk probe (best-effort)
  }
  deriving stock (Show)
```

The tool wrappers establish the IP4 degradation convention every later plan inherits — a probe
whose source is unreachable returns a `StatusUnknown` line, never an uncaught exception:

```haskell
-- Run a tool, capturing stdout and tolerating a non-zero exit; a missing binary
-- (IOException) yields Nothing rather than throwing. The cradle `run` already
-- avoids throwing on non-zero exit, so we only guard the IOException case.
captureTool :: String -> [String] -> IO (Maybe ByteString)
captureTool exe args =
  (handleIOErr Nothing) $ do
    (code, StdoutRaw out) <- run $ cmd exe & addArgs args & silenceStderr
    pure $ case code of
      ExitSuccess   -> Just out
      ExitFailure _ -> Nothing
  where handleIOErr d = flip catch (\(_ :: IOException) -> pure d)

-- Lift "no data" into a StatusUnknown Probe with a hint.
runMaybe :: Text -> Text -> Maybe a -> (a -> Probe) -> IO Probe
runMaybe name hint m k = pure $ maybe (Probe name StatusUnknown hint) k m
```

Implement the pure parsers against representative JSON/text excerpts. For the node-ready probe,
`kubectl get nodes -o json` returns `{"items":[{"status":{"conditions":[…,{"type":"Ready",
"status":"True"}]}}]}`, and:

```haskell
-- True iff the first node's Ready condition has status=="True".
parseNodeReady :: ByteString -> Maybe Bool
parseNodeReady bs = do
  v <- decodeStrict bs
  Aeson.Array items <- lookupPath ["items"] v
  node <- items V.!? 0
  Aeson.Array conds <- lookupPath ["status", "conditions"] node
  ready <- find (\c -> textAt ["type"] c == Just "Ready") (V.toList conds)
  pure (textAt ["status"] ready == Just "True")
```

`parseDeploymentReady :: ByteString -> Text -> Maybe Bool` reads `kubectl get deploy <name> -n <ns>
-o json` and returns `Just True` iff `.status.availableReplicas >= 1` and the `Available` condition
is `True`. `parseKourierIp :: ByteString -> Maybe Text` pulls
`.status.loadBalancer.ingress[0].ip` from the Kourier Service JSON. `parseConfigDomain :: ByteString
-> Maybe Text` returns the single top-level key under `.data` of the `config-domain` ConfigMap (its
value is conventionally empty; the *key* is the domain). `parseClusterIssuerReady :: ByteString ->
Maybe Bool` reuses the Ready-condition walk against `kubectl get clusterissuer letsencrypt-dns -o
json`.

For backup freshness, `gsutil ls -l gs://…/postgres/` prints lines like
`   1234  2026-06-08T03:00:01Z  gs://…/postgres/dump-20260608.sql.gz` ending in a `TOTAL:` line, and:

```haskell
-- The newest object age (as the raw RFC3339 timestamp text) from `gsutil ls -l` output,
-- ignoring the trailing "TOTAL:" line; Nothing when the prefix is empty.
parseNewestBackupAge :: Text -> Maybe Text
parseNewestBackupAge out =
  let stamps = [ t | ln <- T.lines out
                   , not ("TOTAL:" `T.isPrefixOf` T.stripStart ln)
                   , (_size : t : _) <- [T.words ln]
                   , "T" `T.isInfixOf` t ]   -- crude RFC3339 filter
  in if null stamps then Nothing else Just (maximum stamps)
```

(The caller turns that timestamp into a human age with `Data.Time`; the *parse* stays clock-free and
testable.) `parseDfUsage :: Text -> Text -> Maybe Text` extracts the `Use%`/size column for a given
mountpoint from `df -h` output (lines like `/dev/sdb 100G 12G 88G 12% /var/lib/nagare`).

Finally the formatter, copying the `pad` helper from `Nagare.App.formatAppList`:

```haskell
renderInventory :: [Probe] -> Text
renderInventory ps = T.unlines (header : map row ps)
  where
    header = "  " <> pad 6 "STATUS" <> pad 22 "CHECK" <> "DETAIL"
    row p  = "  " <> pad 6 (statusLabel (probeStatus p)) <> pad 22 (probeName p) <> probeDetail p
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

statusLabel :: ProbeStatus -> Text
statusLabel = \case
  StatusOk -> "OK"; StatusWarn -> "WARN"; StatusUnknown -> "UNKNOWN"; StatusFail -> "FAIL"
```

Create `cli/nagarectl/src/Nagare/Ops/Pulumi.hs` with the IP2 helper EP-40 reuses:

```haskell
module Nagare.Ops.Pulumi (stackOutput) where

-- `pulumi -C <dir> stack output <name>`; Nothing if pulumi is missing or the call fails.
stackOutput :: FilePath -> Text -> IO (Maybe Text)
stackOutput dir name = do
  m <- captureTool "pulumi" ["-C", dir, "stack", "output", T.unpack name]
  pure $ fmap (T.strip . decodeUtf8) m
```

Add `Nagare.Ops.Probe` and `Nagare.Ops.Pulumi` to `exposed-modules` in
`cli/nagarectl/nagarectl.cabal`. Add a `testGroup "Nagare.Ops"` in
`cli/nagarectl/test/Spec.hs` covering: `parseNodeReady` on a ready and a not-ready node and on
malformed JSON (→ `Nothing`); `parseDeploymentReady` available vs unavailable; `parseKourierIp`
present vs absent; `parseConfigDomain` returns the key; `parseClusterIssuerReady` ready vs not;
`parseNewestBackupAge` picks the max timestamp and ignores `TOTAL:` and returns `Nothing` on empty;
`parseDfUsage` extracts the right mount; and `renderInventory`/`statusLabel` produce the expected
aligned lines. Acceptance: `cd cli/nagarectl && cabal build && cabal test` green.

### Milestone 2 — `gatherInventory` wiring every probe

Scope: create `cli/nagarectl/src/Nagare/Ops/Status.hs` with `gatherInventory :: InventoryOpts ->
IO [Probe]`, the one IO function that runs every probe in order and assembles the `[Probe]` list,
each probe degrading gracefully. After this milestone the inventory can be gathered in code (called
by the command in M3), and a `cabal repl` could run `gatherInventory defaultInventoryOpts`.

Create `cli/nagarectl/src/Nagare/Ops/Status.hs` exporting:

```haskell
module Nagare.Ops.Status
  ( gatherInventory
  , defaultInventoryOpts
  ) where

defaultInventoryOpts :: InventoryOpts
defaultInventoryOpts = InventoryOpts
  { ioZone = "us-west1-a", ioInstance = "nagare-01", ioPulumiDir = "infra/pulumi", ioSkipVm = False }
```

`gatherInventory` runs the probes in report order; each is a small `IO Probe` that uses
`captureTool`/`runMaybe` so a failed/missing source yields a `StatusUnknown` line. Sketch of the
key probes:

```haskell
gatherInventory :: InventoryOpts -> IO [Probe]
gatherInventory o = do
  publicIp   <- stackOutput (ioPulumiDir o) "publicIp"
  baseDomain <- stackOutput (ioPulumiDir o) "baseDomain"
  sequence
    [ probeVm o
    , probeNode
    , probeDeploy "knative-serving" "controller"          "Knative controller"
    , probeDeploy "knative-serving" "webhook"             "Knative webhook"
    , probeDeploy "kourier-system"  "3scale-kourier-gateway" "Kourier gateway"
    , probeDeploy "cert-manager"    "cert-manager"        "cert-manager"
    , probeDeploy "cert-manager"    "cert-manager-webhook" "cert-manager-webhook"
    , probeDeploy "knative-serving" "net-certmanager-controller" "net-certmanager"
    , probeClusterIssuer
    , probeKourierIp publicIp
    , probeBaseDomain baseDomain
    , probeRegistryAuth
    , probeBackup "postgres"
    , probeBackup "litestream"
    , probeBackup "volumes"
    ] >>= \core -> (core <>) <$> probeDisk o   -- disk probe(s) appended (best-effort SSH)

-- VM power: gcloud … describe … --format='value(status)'.
probeVm :: InventoryOpts -> IO Probe
probeVm o = do
  m <- captureTool "gcloud"
         [ "compute", "instances", "describe", T.unpack (ioInstance o)
         , "--zone", T.unpack (ioZone o), "--format=value(status)" ]
  pure $ case fmap (T.strip . decodeUtf8) m of
    Just "RUNNING"    -> Probe "VM" StatusOk   "RUNNING"
    Just "TERMINATED" -> Probe "VM" StatusFail "TERMINATED (start: gcloud compute instances start)"
    Just other        -> Probe "VM" StatusWarn other
    Nothing           -> Probe "VM" StatusUnknown "gcloud unavailable or no access"

-- Kourier EXTERNAL-IP must equal the Pulumi publicIp.
probeKourierIp :: Maybe Text -> IO Probe
probeKourierIp publicIp = do
  m <- captureTool "kubectl" ["get", "svc", "kourier", "-n", "kourier-system", "-o", "json"]
  runMaybe "Kourier ingress" "no kubeconfig / not reachable" (m >>= parseKourierIp) $ \ip ->
    case publicIp of
      Just want | want == ip -> Probe "Kourier ingress" StatusOk   ("EXTERNAL-IP " <> ip <> " = publicIp")
      Just want              -> Probe "Kourier ingress" StatusFail  ("EXTERNAL-IP " <> ip <> " != publicIp " <> want)
      Nothing                -> Probe "Kourier ingress" StatusWarn  ("EXTERNAL-IP " <> ip <> " (publicIp unknown)")

-- base domain: Pulumi baseDomain vs in-cluster config-domain key.
probeBaseDomain :: Maybe Text -> IO Probe
probeBaseDomain baseDomain = do
  m <- captureTool "kubectl" ["get", "configmap", "config-domain", "-n", "knative-serving", "-o", "json"]
  runMaybe "base domain" "config-domain not reachable" (m >>= parseConfigDomain) $ \live ->
    case baseDomain of
      Just want | want == live -> Probe "base domain" StatusOk   (live <> " (= Pulumi baseDomain)")
      Just want                -> Probe "base domain" StatusWarn  (live <> " != Pulumi " <> want)
      Nothing                  -> Probe "base domain" StatusWarn  (live <> " (Pulumi baseDomain unknown)")
```

The disk probe is best-effort over IAP SSH and is the canonical `StatusUnknown` case when SSH is not
set up; honor `ioSkipVm`:

```haskell
probeDisk :: InventoryOpts -> IO [Probe]
probeDisk o
  | ioSkipVm o = pure [Probe "disk" StatusUnknown "skipped (--skip-vm)"]
  | otherwise  = do
      m <- captureTool "scripts/iap-ssh.sh"
             ["ssh", T.unpack (ioInstance o), "--", "df -h /var/lib/nagare /"]
      -- requires SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 in the environment (see Concrete Steps)
      pure $ case fmap decodeUtf8 m of
        Nothing  -> [Probe "disk" StatusUnknown "iap-ssh unavailable (VM off? key not set?)"]
        Just out ->
          [ mk "boot disk" (parseDfUsage out "/")
          , mk "data disk" (parseDfUsage out "/var/lib/nagare") ]
  where mk nm = maybe (Probe nm StatusUnknown "df parse failed") (Probe nm StatusOk)
```

`probeRegistryAuth` runs `gcloud artifacts repositories describe nagare --location=us-west1` and
reports `OK`/`UNKNOWN` on success/failure. `probeBackup prefix` runs `gsutil ls -l
gs://tan-nb-exp-nagare-backups/<prefix>/`, applies `parseNewestBackupAge`, and turns the newest
timestamp into a human age (via `Data.Time`, the one clock touch, kept inside the IO probe). The
`config-network-tls` `external-domain-tls=Disabled` fact is surfaced as one informational
`StatusWarn`/`StatusOk` line, not a failure. Acceptance: `cabal build` succeeds; the pure parsers
the probes call are already covered by M1's tests; `gatherInventory` typechecks and returns a list
whose length equals the number of probes.

### Milestone 3 — `server status` command, rendering, and graceful degradation

Scope: register the `server` command group (first subcommand `status`) in
`cli/nagarectl/app/Main.hs` and wire the handler. After this milestone an operator can run
`nagarectl server status` and read the report.

In `cli/nagarectl/app/Main.hs`:

- Add a `Command` constructor `ServerStatus ServerStatusOpts` (around line 232) and an options
  record `data ServerStatusOpts = ServerStatusOpts { ssSkipVm :: Bool }` with a parser
  `serverStatusOptsParser :: Parser ServerStatusOpts` exposing `--skip-vm` (skip the IAP-SSH disk
  probe). Define the nested `server` group exactly like the `app` group:

  ```haskell
  serverCmd = info (serverSub <**> helper)
    (fullDesc <> progDesc "Server and platform inventory")
  serverSub = subparser
    ( command "status" (info (ServerStatus <$> serverStatusOptsParser <**> helper)
                         (progDesc "One-screen platform health report")) )
  ```

  Register `command "server" serverCmd` in the top-level `subparser` (around line 549).

- Add the handler and the `main` dispatch arm (around line 776):

  ```haskell
  runServerStatus :: ServerStatusOpts -> IO ()
  runServerStatus o = do
    let opts = defaultInventoryOpts { ioSkipVm = ssSkipVm o }
    probes <- gatherInventory opts
    TIO.putStr (renderInventory probes)
  ```

  ```haskell
  ServerStatus o -> runServerStatus o
  ```

Import `gatherInventory`/`defaultInventoryOpts` from `Nagare.Ops.Status` and
`renderInventory`/`InventoryOpts(..)` from `Nagare.Ops.Probe`. `runServerStatus` never calls
`dieT` for a probe failure — degradation is the probes' job — so the command always prints the full
report and exits 0 (exit-code semantics for scripting belong to EP-39's `doctor`). Acceptance:
`nagarectl server status --help` shows the command; `nagarectl server status` prints a table (all
`UNKNOWN` if no tools/cluster are reachable, which is itself the graceful-degradation proof).

### Milestone 4 — Tests green and a captured `--help` transcript

Run `cabal test` in `cli/nagarectl`. Capture the `nagarectl server --help` and `nagarectl server
status --help` transcripts into Concrete Steps as evidence. Then, against a reachable cluster with
the VM powered on, run `nagarectl server status` once and paste the transcript. If no cluster is
reachable (the VM is commonly left `TERMINATED`), record that the `kubectl`/`gcloud`/`pulumi`/`gsutil`
paths were verified by the pure-helper unit tests and `--help` inspection and that the live run is
deferred (mirroring how `docs/plans/30-nagarectl-app-lifecycle-commands.md` deferred its cluster
run). The conventional final state of this milestone is: tests green + `--help` transcript captured;
live cluster run deferred.


## Concrete Steps

Build and test from the package directory (prefix with `nix develop -c` if `cabal`/`kubectl`/
`gcloud`/`pulumi`/`gsutil` are not already on PATH):

```bash
cd cli/nagarectl && cabal build && cabal test
```

Inspect the command surface (no cluster needed):

```bash
cabal run -v0 nagarectl -- server --help
cabal run -v0 nagarectl -- server status --help
```

Run the report end-to-end. The disk probe needs the IAP-SSH environment from
`docs/runbooks/cluster-access.md`; ensure your `kubectl` context points at the k3s cluster (not the
default GKE `tan-cluster` context) and that the VM is powered on:

```bash
gcloud compute instances start nagare-01 --zone=us-west1-a   # if TERMINATED
export SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519             # for the IAP-SSH disk probe
nagarectl server status
nagarectl server status --skip-vm                            # skip the disk probe (no SSH needed)
```

Expected `nagarectl server --help` output shape:

```text
Usage: nagarectl server COMMAND
  Server and platform inventory
Available commands:
  status   One-screen platform health report
```

Expected `nagarectl server status` output shape (healthy cluster, VM running):

```text
  STATUS  CHECK                 DETAIL
  OK      VM                    RUNNING
  OK      k3s node              Ready
  OK      Knative controller    rolled out
  OK      Knative webhook       rolled out
  OK      Kourier gateway       rolled out
  OK      cert-manager          rolled out
  OK      cert-manager-webhook  rolled out
  OK      net-certmanager       rolled out
  OK      ClusterIssuer         letsencrypt-dns Ready
  OK      Kourier ingress       EXTERNAL-IP 34.83.0.1 = publicIp
  WARN    base domain           apps.example.com (placeholder; external-domain-tls Disabled)
  OK      Artifact Registry     us-west1-docker.pkg.dev/tan-nb-exp/nagare reachable
  OK      backup postgres       newest object 6h ago
  WARN    backup litestream     newest object 5d ago
  OK      backup volumes        newest object 2h ago
  OK      boot disk             24% of 100G
  OK      data disk             12% of 100G
```

Expected output shape when the VM is off / no cluster (graceful degradation — the command still
prints a full report and exits 0):

```text
  STATUS   CHECK                 DETAIL
  FAIL     VM                    TERMINATED (start: gcloud compute instances start)
  UNKNOWN  k3s node              no kubeconfig / not reachable
  UNKNOWN  Knative controller    no kubeconfig / not reachable
  UNKNOWN  Kourier ingress       no kubeconfig / not reachable
  UNKNOWN  base domain           config-domain not reachable
  UNKNOWN  Artifact Registry     gcloud unavailable or no access
  UNKNOWN  backup postgres       gsutil unavailable
  UNKNOWN  disk                  iap-ssh unavailable (VM off? key not set?)
```


## Validation and Acceptance

1. `cd cli/nagarectl && cabal build && cabal test` succeeds, including the new `testGroup
   "Nagare.Ops"` cases (node-ready, deployment-ready, Kourier IP, config-domain, ClusterIssuer,
   newest-backup-age, `df` usage, and the `renderInventory`/`statusLabel` formatter), and the
   existing test groups are unchanged (no regression).
2. `nagarectl server --help` lists the `status` subcommand and `nagarectl server status --help`
   shows the `--skip-vm` flag.
3. With the VM running and `kubectl` pointed at the k3s cluster, `nagarectl server status` prints an
   aligned table whose first line is the VM power state (`OK RUNNING`) and whose remaining lines
   report the node, the Knative/Kourier/cert-manager/net-certmanager rollouts, the ClusterIssuer,
   the Kourier `EXTERNAL-IP = publicIp` match, the base-domain comparison, Artifact Registry auth,
   the boot+data disk usage, and the per-prefix backup ages — each tagged `OK`/`WARN`/`UNKNOWN`/`FAIL`.
4. Stop the VM (`gcloud compute instances stop nagare-01 --zone=us-west1-a`) and re-run: the VM line
   reads `FAIL TERMINATED`, every probe whose source is now unreachable degrades to `UNKNOWN` with a
   short hint, and the command still prints the whole report and exits 0 (no stack trace) — proving
   the IP4 graceful-degradation convention.

If no cluster is reachable, items 3–4 are validated by unit tests on the pure helpers (the parsers
and the formatter run against hand-written JSON/text fixtures) plus `--help` inspection; the live
run is explicitly deferred.


## Idempotence and Recovery

`nagarectl server status` is entirely read-only: every probe runs a `describe`/`get`/`ls`/`df`
command and parses the result, mutating nothing on the VM, in the cluster, in Pulumi state, or in
GCS. It is therefore safe to run as many times as you like and safe to interrupt at any point — a
re-run simply re-gathers the inventory. Because each probe tolerates a failed or missing source
(`captureTool` returns `Nothing` on a non-zero exit and catches the `IOException` from a missing
binary, and `runMaybe` lifts `Nothing` into a `StatusUnknown` line), there is no partial state to
clean up and nothing to roll back; a transient failure (the VM mid-boot, a flaky network) shows as
`UNKNOWN`/`WARN` and clears on the next run once the source is reachable. The build/test steps are
ordinary `cabal` invocations and are freely repeatable. Recover from a bad edit with `git checkout`.


## Interfaces and Dependencies

Existing libraries (already in `cli/nagarectl/nagarectl.cabal`): `cradle` (subprocess via `run`/
`run_`/`cmd`/`addArgs`/`silenceStderr`), `aeson` + `bytestring` + `vector` (parse `kubectl/gcloud
-o json`), `containers` (the `config-domain` `.data` map), `text`, `time` (turn a backup timestamp
into a human age), and `optparse-applicative` (the CLI). No new external dependency.

Signatures that must exist at the end of this plan:

```haskell
-- Nagare.Ops.Probe (new module — the IP1 typed model and IP4 wrappers)
data ProbeStatus = StatusOk | StatusWarn | StatusUnknown | StatusFail
  deriving stock (Eq, Show)
data Probe = Probe
  { probeName   :: !Text
  , probeStatus :: !ProbeStatus
  , probeDetail :: !Text
  } deriving stock (Eq, Show)
data InventoryOpts = InventoryOpts
  { ioZone :: !Text, ioInstance :: !Text, ioPulumiDir :: !FilePath, ioSkipVm :: !Bool }
  deriving stock (Show)
renderInventory        :: [Probe] -> Text                       -- pure, tested
statusLabel            :: ProbeStatus -> Text                   -- pure, tested
captureTool            :: String -> [String] -> IO (Maybe ByteString)
runMaybe               :: Text -> Text -> Maybe a -> (a -> Probe) -> IO Probe
parseNodeReady         :: ByteString -> Maybe Bool              -- pure, tested
parseDeploymentReady   :: ByteString -> Text -> Maybe Bool      -- pure, tested
parseKourierIp         :: ByteString -> Maybe Text              -- pure, tested
parseConfigDomain      :: ByteString -> Maybe Text              -- pure, tested
parseClusterIssuerReady :: ByteString -> Maybe Bool             -- pure, tested
parseNewestBackupAge   :: Text -> Maybe Text                    -- pure, tested
parseDfUsage           :: Text -> Text -> Maybe Text            -- pure, tested

-- Nagare.Ops.Pulumi (new module — the IP2 Pulumi reader)
stackOutput :: FilePath -> Text -> IO (Maybe Text)              -- `pulumi -C <dir> stack output <name>`

-- Nagare.Ops.Status (new module — the assembled inventory)
gatherInventory     :: InventoryOpts -> IO [Probe]
defaultInventoryOpts :: InventoryOpts
```

Integration: this plan is the root of MasterPlan 8
(`docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md`) and owns four integration
points. **IP1** — the `Probe`/`ProbeStatus` types above are read back verbatim by
`docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md`, which re-grades the same
`Probe` values into remediation checks (it may add a field to `Probe` in coordination; this plan's
field names are final). **IP2** — `Nagare.Ops.Pulumi.stackOutput` is reused by
`docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md` to resolve the base
domain for expected wildcard DNS records, rather than re-implementing a Pulumi reader; the existing
`resolveBaseDomain` in `cli/nagarectl/app/Main.hs` is left in place for the deploy path. **IP3** —
this plan establishes the `server` command group and the top-level registration pattern in
`cli/nagarectl/app/Main.hs`; `docs/plans/40-...` (`domains`) and
`docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md` (`cleanup`) append their
commands in the same style. **IP4** — the `captureTool`/`runMaybe` wrappers and the "unreachable
source → `StatusUnknown`/`WARN`, never an exception" convention defined here are inherited by EP-39,
EP-40, and EP-41. The closing docs plan
`docs/plans/42-server-and-operations-ux-docs-and-runbook-integration.md` folds `server status` into
`docs/runbooks/cluster-access.md` and `docs/runbooks/disaster-recovery.md`.
