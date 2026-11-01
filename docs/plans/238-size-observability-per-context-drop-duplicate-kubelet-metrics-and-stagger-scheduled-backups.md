---
id: 238
slug: size-observability-per-context-drop-duplicate-kubelet-metrics-and-stagger-scheduled-backups
title: "Size observability per context, drop duplicate kubelet metrics and stagger scheduled backups"
kind: exec-plan
created_at: 2026-10-31T23:21:18Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-31T23:21:18Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-01T02:20:39Z
      verdict: "changes-requested"
      note: "Verified files, symbols, chart 0.81.0 mergeOverwrite, offsets 12/6/4/11 and CLI flags; the context: overlay path cannot resolve as written, the curl measurement globs its selector, and the hourly test and adapter-test claims need correcting"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-01T02:22:25Z
      mode: "update"
      note: "Fix the context: overlay path and its resolver field, the globbed curl measurement, the hourly test and adapter-test claims; name the config builder and payload packaging"
---

# Size observability per context, drop duplicate kubelet metrics and stagger scheduled backups

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

The work intranet's metrics store, VMSingle, is killed for running out of memory several times a
day. It runs at its 512Mi limit, it stores the k3s apiserver and etcd metrics twice, and four
backup CronJobs start at the same second every quarter hour, so it has to index about a thousand
new series at once. Today the operator cannot change any of this without a Nagare code change and
a release: the observability Helm values are packaged and pinned by digest, and the backup
schedule is a hard-coded string.

This plan makes these things operator configuration, not Nagare code. After it, an operator puts a
Helm values file for one observability release in the context's operator-owned directory, for
example `~/.config/nagare/observability/intranet/vmks.yaml` setting VMSingle's memory limit to
1Gi. `nagarectl platform bootstrap plan` merges it after the packaged values, records its digest in
the review, and changes only that release. Apply runs with the same file. The same mechanism covers
the resources of every observability pod, the cache budgets, the retention periods and the scrape
relabelling rules, so the next sizing or metric-churn problem is fixed by editing a file in the
operator repository. Which keys an overlay may set is listed in a packaged data file, not in
Haskell, so widening the supported set later is a YAML edit too. A key outside the list is refused
at plan time with its name.

Two load reductions also ship for every context. The kubelet `/metrics` scrape no longer stores the
control-plane families that the apiserver job already collects (about 44k series on the intranet).
Hourly-objective backup CronJobs keep their 15-minute cadence but each starts at its own minute,
derived from its name, so the producers on one cluster no longer start together. On the intranet
the four schedules land on minutes 12, 6, 4 and 11 of each quarter hour.

This plan implements improvement request IR-40,
[`docs/improvement-requests/size-observability-per-context-and-cut-metric-churn.md`](../improvement-requests/size-observability-per-context-and-cut-metric-churn.md),
from `mori://tan/tan-ng-labs`. Its acceptance criteria AC-1 to AC-5 are the acceptance of this plan.


## Progress

- [ ] M1: a per-context values overlay for any of the five observability releases is merged at
  plan time, recorded in the reviewed Helm contract and used again at apply; keys outside
  `cluster/observability/overrides-policy.yaml` and null values are refused, naming the key; a
  context without overlays produces a byte-identical contract (IR-40 AC-1, AC-2).
- [ ] M2: the packaged kubelet `/metrics` scrape drops the control-plane families the apiserver job
  already stores, measured on a local k3s context, with `kubelet_*` families and the broker
  dashboard intact (IR-40 AC-3).
- [ ] M3: hourly-objective backup CronJobs (server, app-database and volume schedules) start at a
  per-name minute offset, and the accepted-schedule receipt check accepts exactly the 15-minute
  cadences under the hourly objective (IR-40 AC-4, AC-5).
- [ ] M4: user documentation, the ADR 23 amendment and IR-40's status are updated, and the intranet
  operators have the overlay they need for 1Gi.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Overrides are ordinary Helm values files, one per release, in an operator-owned
  directory per context: `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/observability/<context>/<release>.yaml`,
  where `<release>` is one of `vmks`, `victoria-logs`, `victoria-logs-collector`,
  `victoria-traces` or `otel-collector`. Each file is passed to Helm as a second `--values` after
  the packaged file.
  Rationale: the operator asked (2026-10-31) that Nagare be configurable without code changes. A
  typed context field per knob needs code for every new knob. A values file uses the chart's own
  keys, needs no Nagare schema, and lives with the context's other operator material, as
  `cluster-secrets/<context>` already does (ADR 13).
  Date: 2026-10-31.

- Decision: The supported set of overlay keys is data, in a packaged file
  `cluster/observability/overrides-policy.yaml`, not a Haskell list. It names, per release, value
  paths as lists of key segments (`*` matches any one key). An overlay may set any key at or under
  a listed path. Everything else is refused, and so is any `null` value.
  Rationale: refusing unknown keys keeps Nagare's guarantees (pinned images, the fixed VMSingle
  port the Grafana datasource uses, Alertmanager gating), while widening the set later is a
  reviewed payload edit with no code change. A `null` makes Helm delete a packaged key, which could
  remove a memory limit that ADR 23 requires; refusing it keeps every container bounded without a
  separate post-merge resource check.
  Date: 2026-10-31.

- Decision: The packaged defaults stay as they are (VMSingle 512Mi, cache budget 40%). The intranet
  sets 1Gi in its own overlay.
  Rationale: other contexts run smaller VMs (ADR 14 makes the VM shape the context's choice), and
  the overlay now lets each context size itself.
  Date: 2026-10-31.

- Decision: The stagger offset is the first eight bytes of SHA-256 of the CronJob's name, read as a
  big-endian integer, modulo 15. Offset 0 keeps `*/15 * * * *`; offset M from 1 to 14 gives
  `M-59/15 * * * *`. Daily schedules are unchanged.
  Rationale: deterministic, stable across re-plans, independent of other schedules, and computed in
  the one function every scheduled backup already passes through. The intranet's four names give
  12, 6, 4 and 11, so no two of them collide. Keeping `*/15` for offset 0 means those schedules do
  not change bytes.
  Date: 2026-10-31.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Nagare is a small platform-as-a-service that runs on one k3s node. `nagarectl` is its command-line
tool, written in Haskell under `cli/nagarectl/`. A context is a named target (one GCP project, or a
loopback-only local k3d cluster when `NAGARE_MODE=local`); its settings are in
`~/.config/nagare/contexts/<name>.env`, and operator-owned material for it, such as encrypted
secrets, lives in a private operator repository symlinked into `~/.config/nagare/`.

Changes to the cluster go through a review: a command such as
`nagarectl platform bootstrap plan --out DIR` compiles the desired resources into an immutable
review directory, and `nagarectl platform bootstrap apply DIR --yes` applies exactly that review.
Each resource carries a digest of its native bytes; apply refuses if what it would send differs.

**Observability releases.** Five Helm releases make up the observability stack. Their vendored
chart archives are in `cluster/observability/vendor/`, and their values files are
`cluster/observability/victoria-metrics/values.yaml` (release `vmks`: VMSingle, VMAgent, VMAlert,
Grafana and its sidecars, kube-state-metrics, node-exporter and the Victoria operator),
`cluster/observability/victoria-logs/values.yaml`, `cluster/observability/victoria-logs/collector-values.yaml`,
`cluster/observability/victoria-traces/values.yaml` and
`cluster/observability/opentelemetry-collector/values.yaml`.
`pinnedObservabilityInputs` in `cli/nagarectl/src/Nagare/Inventory/Components/Observability.hs`
lists each release with the SHA-256 digest of its chart and values file. `capturePackagedRelease`
in the same module checks both digests, runs `helm template` with `--values <packaged file>` and a
capture post-renderer (`cluster/observability/helm-review/capture`), and keeps the rendered bytes.
`compileRenderedRelease` writes a canonical JSON contract with `chartPath`, `chartDigest`,
`valuesPath`, `valuesDigest`, `renderDigest` and the Helm and Kubernetes versions; its digest is
the release's native digest. Paths under the payload are written portably as `payload:<path>`.

At apply, `cli/nagarectl/src/Nagare/Inventory/Adapters/HelmRuntime.hs` reads the contract back
(`checkContract`), resolves `payload:` paths, re-checks the chart and values digests, and runs
`helm upgrade --install ... --values <file> --post-renderer nagare-reviewed-manifests` with
`NAGARE_HELM_REVIEW_SHA256` set to the reviewed render digest; the reviewing post-renderer
(`cluster/observability/helm-review/verify.sh`) refuses if Helm renders anything else. So an
overlay used at plan time must also be passed at apply, in the same order, or apply refuses.
`HelmRuntimeConfig` (same module) carries the kube context, the `ContextId`, the verify plugin
directory, the declarations and a runtime guard; `checkContract` resolves a `payload:` path against
the parent of that plugin directory, which is how a review made on one machine applies on another.
The config is built in one place, `inventoryHelmRuntimeConfig` in
`cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs`; two tests in
`cli/nagarectl/test/InventoryObservabilitySpec.hs` build it positionally. The private review keeps
each Helm contract's bytes verbatim and `cli/nagarectl/src/Nagare/Inventory/HelmReview.hs` reads
them back, so new contract fields need no change there.

`buildPlatformCandidate` in `cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` calls
`pinnedObservabilityInputs` and then `compilePinnedObservability`. It also reads
`alertmanager.enabled` from the packaged `vmks` values through `readAlertmanagerEnabled`
(`cli/nagarectl/src/Nagare/Inventory/Components/ObservabilitySecrets.hs`), which decides whether
an Alertmanager secret is required. The overlay policy must not allow `alertmanager`, so that
reading stays correct. The same module's `resolveDirectory` shows the established lookup for
context-owned material: `nagareConfigDir </> "cluster-secrets" </> <context>`, with `nagareConfigDir`
from `cli/nagarectl/src/Nagare/Target.hs`.

**Chart list merging.** In chart 0.81.0, `templates/servicemonitors.yaml` builds each kubelet scrape
with `mergeOverwrite` of `kubelet.vmScrape` and `kubelet.vmScrapes.<name>`. `mergeOverwrite`
replaces lists rather than appending, so a `metricRelabelConfigs` set under
`kubelet.vmScrapes.kubelet.spec` replaces the chart's three default rules (drop the `uid` label,
drop the `id` and `name` labels, drop `rest_client_request_duration_seconds_*`). Any new list must
restate them. The scrape named `kubelet` has no `path`, so it scrapes `/metrics`; the others are
`cadvisor`, `probes` and `resources`. On k3s the kubelet and apiserver share one process, so
`/metrics` also exposes apiserver, etcd and client-go families. No dashboard or rule under
`cluster/observability/grafana/` or `cluster/observability/vmrules/` queries `apiserver_*`, `etcd_*`,
`workqueue_*` or `rest_client_*`; `cluster/observability/grafana/dashboards/nagare-brokers.json`
queries `kubelet_volume_stats_*`, which must stay.

**Scheduled backups.** A recovery-point objective is `hourly` or `daily`
(`RecoveryPointObjective` in `cli/nagarectl/src/Nagare/Inventory/BackupFreshness.hs`, selected by
the context's `NAGARE_BACKUP_RECOVERY_POINT`). `recoveryPointSchedule` maps hourly to
`*/15 * * * *` and daily to `17 3 * * *`; `recoveryPointThresholds` gives warning and breach ages
(30 and 60 minutes for hourly). Every scheduled backup CronJob — managed database servers,
app databases (`cli/nagarectl/src/Nagare/Database/AppDatabase/Backup.hs`) and backup-included
volumes — is rendered by `renderScheduledCronJob` in `cli/nagarectl/src/Nagare/Database/Backup.hs`,
which takes the schedule from `recoveryPointSchedule` and the CronJob name from the input's
`jobName` (for example `nagare-dbbackup-labs-postgres`, `nagare-appdb-kansoku-pg`). The schedule
revision signed into each receipt is the digest of the CronJob rendered with a zero revision, so a
schedule change gives a new revision. Ingestion already accepts runs signed under earlier converged
revisions of the same schedule (EP-207, `cli/nagarectl/src/Nagare/Inventory/ScheduledIngest.hs`),
so a schedule update does not orphan earlier receipts.

`cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs`, around the message "accepted scheduled backup
cadence differs from its recovery-point objective", checks an accepted CronJob's `spec.schedule`.
Today it compares exactly for daily and skips the comparison for hourly. Tests for scheduled
backups are in `cli/nagarectl/test/Nagare/Test/Backup/Scheduled.hs` (which already asserts
`*/15 * * * *` for hourly), with recovery-model tests in `cli/nagarectl/test/InventoryRecoveryModelSpec.hs`
and `cli/nagarectl/test/Nagare/Test/Model/Ingest.hs`. Observability tests are in
`cli/nagarectl/test/InventoryObservabilitySpec.hs`.

**Relevant ADRs.**
[ADR 23](../adr/0023-observability-resource-bounds-cover-chart-and-operator-created-containers.md)
requires explicit CPU and memory requests and a memory limit on every observability container, and
treats a Victoria `memory.allowedPercent` as a cache budget that must leave non-cache headroom
(40% under the 512Mi caps). Its consequences name `scripts/test-observability-resources.sh`, which
no longer exists in the tree; this plan keeps the bounds by refusing `null` in overlays and amends
the ADR to say an overlay that raises a limit should reconsider the cache budget.
[ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md)
fixes the hourly objective, its 15-minute producer cadence and its thresholds, and its amendment
fixes the retention policy in the release with no context value; staggering keeps all of that.
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
puts operator material in the private operator repository; overlays are operator material.
[ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) makes the VM shape the context's
choice, which is why sizing belongs to the context too.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) means the
unit and adapter tests find defects; the local native check only confirms.


## Plan of Work

The three changes are independent and can land in any order. M1 is the largest. M2 changes the
packaged `vmks` values, so every context's next upgrade shows a `vmks` change; that is intended.

**M1: per-context overlays.** Create `cluster/observability/overrides-policy.yaml`. Everything under
`cluster/` is already copied into the payload (`nix/haskell-packages.nix` copies it for the tests,
and the payload root `root` that `pinnedObservabilityInputs` receives contains
`cluster/observability/`), so the file needs no Nix change; read it from
`root </> "cluster/observability/overrides-policy.yaml"`. Its top-level
keys are the five release names; each holds a list of allowed paths, each path a YAML list of key
segments, because some keys contain dots (`memory.allowedPercent`). Start with resources for every
pod, the cache budgets, retention and scrape relabelling:

```yaml
# Keys a context's observability overlay may set. A path allows itself and
# everything under it; "*" matches any one key. See docs/user/observability.md.
vmks:
  - [vmsingle, spec, resources]
  - [vmsingle, spec, extraArgs, memory.allowedPercent]
  - [vmsingle, spec, retentionPeriod]
  - [vmagent, spec, resources]
  - [vmalert, spec, resources]
  - [prometheus-node-exporter, resources]
  - [kube-state-metrics, resources]
  - [victoria-metrics-operator, resources]
  - [grafana, resources]
  - [grafana, sidecar, resources]
  - [kubelet, vmScrapes, "*", spec, metricRelabelConfigs]
victoria-logs:
  - [server, resources]
  - [server, extraArgs, memory.allowedPercent]
  - [server, retentionPeriod]
  - [server, retentionDiskSpaceUsage]
victoria-logs-collector:
  - [resources]
victoria-traces:
  - [server, resources]
  - [server, retentionPeriod]
  - [server, retentionDiskSpaceUsage]
otel-collector:
  - [resources]
```

The Victoria operator's reloader sizes are environment entries in a list
(`victoria-metrics-operator.env`); a list cannot be partly overridden, so leave them out unless a
context needs them, and say so in the user documentation. PVC sizes stay out: `local-path` volumes
cannot be resized in place.

Add a module `cli/nagarectl/src/Nagare/Inventory/Components/ObservabilityOverlay.hs` with a pure
validator and a loader. The validator takes the release name, the parsed policy and the parsed
overlay and returns either the overlay or a refusal naming the release, the overlay file and the
first offending key as a dotted path (for example
`observability overlay vmks.yaml sets vmsingle.image.tag, which overrides-policy.yaml does not allow`).
A key is allowed when its segment path has a policy path as a prefix, or is itself a prefix of a
policy path and maps to an object (so `vmsingle:` and `vmsingle.spec:` may appear as parents). Any
`null` value is refused. An empty file or `{}` is treated as no overlay. The loader resolves
`nagareConfigDir </> "observability" </> <context>`, reads `<release>.yaml` if it exists, and
returns its path and bytes. Register the module in `cli/nagarectl/nagarectl.cabal` and run
`cabal-gild` as `just haskell-style-check` requires.

Extend `PackagedHelmInput` and `ObservabilityReleaseInput` with an optional overlay (its path and
expected digest, then its bytes). `pinnedObservabilityInputs` is pure
(`ResourceId -> FilePath -> Text -> [PackagedHelmInput]`), so the file reads happen in
`buildPlatformCandidate`: it loads and validates the five overlays with the loader and validator
below, stops with the refusal on an invalid one, and passes the loaded set (release name to path and
bytes) to `pinnedObservabilityInputs`, which attaches each release's overlay to its input. In
`capturePackagedRelease`, check the overlay's digest like the values digest and append a second
`--values <overlay>` after the packaged one. In `compileRenderedRelease`, add `overlayPath` and
`overlayDigest` to the contract only when an overlay is present, so the contract of a context
without overlays is unchanged byte for byte. Write `overlayPath` as `context:<release>.yaml`: the
overlay lives under the operator's config directory, which differs between machines as the payload
root does, so the contract must not carry an absolute path, and the context name is not part of the
written path because the resolver already knows the context. In `HelmRuntime.checkContract`, read
the two optional fields and resolve `context:` against a new `helmOverlayDir :: !FilePath` field of
`HelmRuntimeConfig`, the context's overlay directory
`nagareConfigDir </> "observability" </> <context>`, filled in `inventoryHelmRuntimeConfig`
(`cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs`); the two positional constructions in
`cli/nagarectl/test/InventoryObservabilitySpec.hs` gain the field too. Re-check the overlay digest
("observability overlay changed after review") and pass the second `--values` in the same order.
A contract with `overlayPath` but no readable file refuses as a known no-effect failure, like a
changed values file. Keep the overlay check a small pure function in `HelmRuntime.hs`
(`checkOverlay :: Maybe (FilePath, ContentDigest) -> Maybe ByteString -> Either Text ()`) so a unit
test can reach it without Helm or a cluster.

Tests, in `cli/nagarectl/test/InventoryObservabilitySpec.hs`: the validator accepts one overlay per
policy path and refuses `vmsingle.image.tag`, `alertmanager.enabled` and a `null` limit, each
naming the key; a capture of the vendored `vmks` chart with an overlay setting
`vmsingle.spec.resources.limits.memory: 1Gi` renders a VMSingle object with that limit and a
contract carrying `overlayDigest`; the same capture without an overlay gives a contract equal to
the one the current code produces; `checkOverlay` accepts a matching digest and refuses a changed
file and a missing file, naming the overlay. No existing unit test reaches `checkContract`'s digest
refusal: the case "reviewed Helm adapter refuses a changed release revision" fakes the mutation and
tests the observed release revision, and the only native exercise of `checkContract` is the case
gated by `NAGARE_EP147_TEST_CONTEXT`. The end-to-end refusal of a changed overlay is therefore
confirmed in the local run below (edit the overlay between plan and apply once), not by a unit test.

**M2: no duplicate control-plane metrics.** First measure. On a bootstrapped local context, port
forward VMSingle and list the metric names stored by both jobs:

```bash
kubectl -n monitoring port-forward svc/vmsingle-vmks-victoria-metrics-k8s-stack 8429:8429 &
names() { curl -sG 'http://127.0.0.1:8429/api/v1/label/__name__/values' --data-urlencode "match[]=$1" | jq -r '.data[]' | sort; }
names '{job="kubelet",metrics_path="/metrics"}' > kubelet.txt
names '{job="apiserver"}' > apiserver.txt
comm -12 kubelet.txt apiserver.txt | sed 's/_.*//' | sort | uniq -c | sort -rn
```

Pass the selector with `--data-urlencode`, never inside the URL: curl expands `[]` and `{}` in a
URL as globs, and `?match[]={job="kubelet",metrics_path="/metrics"}` silently becomes two requests,
`match[]=job="kubelet"` and `match[]=metrics_path="/metrics"`.

Build the drop regex from the shared prefixes, excluding `kubelet`, `go` and `process` (those
describe the node process and are small), and record the prefix list in Surprises & Discoveries.
Then add to `cluster/observability/victoria-metrics/values.yaml`:

```yaml
kubelet:
  vmScrapes:
    kubelet:
      spec:
        # mergeOverwrite replaces the chart's list, so restate its three rules.
        metricRelabelConfigs:
          - action: labeldrop
            regex: (uid)
          - action: labeldrop
            regex: (id|name)
          - action: drop
            source_labels: [__name__]
            regex: (rest_client_request_duration_seconds_bucket|rest_client_request_duration_seconds_sum|rest_client_request_duration_seconds_count)
          # On k3s the apiserver shares the kubelet's /metrics; job="apiserver" stores these.
          - action: drop
            source_labels: [__name__]
            regex: (apiserver|etcd|workqueue|rest_client|...)_.*
```

with the measured prefixes in place of the last regex. Update the `vmks` values digest in
`pinnedObservabilityInputs` (`shasum -a 256 cluster/observability/victoria-metrics/values.yaml`).
Because this rule sits under the allowed path `kubelet.vmScrapes.*.spec.metricRelabelConfigs`, a
context can replace it from its overlay without a release.

**M3: staggered hourly schedules.** In `cli/nagarectl/src/Nagare/Inventory/BackupFreshness.hs`
add `hourlyScheduleOffset :: Text -> Int` (the Decision Log's derivation) and
`staggeredRecoveryPointSchedule :: RecoveryPointObjective -> Text -> Text`, which returns
`recoveryPointSchedule` for daily and for offset 0, and `"<M>-59/15 * * * *"` otherwise. Add
`isHourlyCadence :: Text -> Bool`, true exactly for `*/15 * * * *` and `M-59/15 * * * *` with M
from 0 to 14. In `renderScheduledCronJob`, take the schedule from
`staggeredRecoveryPointSchedule objective (baseInputs ^. #jobName)` when `timed`. In
`BackupReceipt.hs`, replace `objective == HourlyRecoveryPoint || ...` with: hourly requires
`isHourlyCadence` of the accepted `spec.schedule`; daily keeps the exact comparison. The check
accepts any 15-minute form rather than the derived one, so CronJobs accepted before this change keep
validating until their next review rewrites them. Freshness thresholds do not change: a 15-minute
cadence with any offset still leaves 15 minutes between runs. Backup-included volume schedules go
through the same function, so they stagger too; IR-40 AC-4 names servers and app databases, and
volumes come with the shared renderer rather than as added scope.

Tests in `cli/nagarectl/test/Nagare/Test/Backup/Scheduled.hs`: four schedules named
`nagare-dbbackup-labs-postgres`, `nagare-dbbackup-labs-clickhouse`, `nagare-appdb-kansoku-pg` and
`nagare-appdb-kansoku-ch` render `12-59/15`, `6-59/15`, `4-59/15` and `11-59/15`, and the same
again on a second render; the receipt check accepts a staggered hourly schedule and `*/15`,
refuses `*/30 * * * *` and `0 * * * *` under hourly, and keeps the daily behaviour. The existing
case "daily schedules bind their objective into signed metadata; hourly bytes are unchanged"
renders `nagare-dbbackup-mydb`, whose offset is 5, so its schedule becomes `5-59/15 * * * *`; change
the assertion and rename the case, because its premise ends here: every hourly CronJob whose name
gives a non-zero offset gets a new schedule revision at its next review, which ingestion tolerates
(EP-207). Update any golden bytes or recovery-model fixtures that embed a rendered backup schedule
(the `*/15` in `cli/nagarectl/test/golden/task-app-resolved.cronjob.yaml` and
`cli/nagarectl/test/Nagare/Test/Task.hs` is an application task, not a backup, and stays); a
fixture whose bytes change is regenerated from the code, not hand-edited.

**M4: documentation and handoff.** Document overlays in `docs/user/observability.md` (where the file
goes, the five release names, the policy file, a 1Gi VMSingle example, the cache-budget advice
from ADR 23, and that apply needs the same file present) and point to it from
`docs/user/contexts.md`. Update the schedule table in `docs/user/backups-and-disaster-recovery.md`
to say the hourly schedule is `M-59/15` with a per-schedule M. Amend ADR 23 with a dated section:
overlays may raise bounds per context, nulls are refused so no container loses a bound, a raised
limit should keep non-cache headroom, and the missing `scripts/test-observability-resources.sh`
reference is replaced by the overlay validator and the existing render tests. Set IR-40's `status`
to `completed`, as the other finished requests in `docs/improvement-requests/` are. Send the intranet operators
the overlay they asked for, to commit in their repository at
`cluster-observability/intranet/vmks.yaml` (or wherever they keep the symlink target), linked as
`~/.config/nagare/observability/intranet`:

```yaml
vmsingle:
  spec:
    resources:
      requests:
        memory: 400Mi
      limits:
        memory: 1Gi
```

Applying it to the intranet is the operator's cloud upgrade, done with the next release on the
real intranet context; it is not part of this plan's acceptance.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`, in a shell where
`direnv` has loaded the dev environment.

For each Haskell commit:

```bash
just haskell-style-check && echo STYLE-OK
just gate-fast
```

Check the exit status, not the output text. While developing, run the focused suites:

```bash
cabal test nagarectl-test --test-options='-p "/observability/"'
cabal test nagarectl-test --test-options='-p "/Scheduled/"'
```

For the local native confirmation (M1 and M2), use a disposable local context as described in
`docs/user/local-development.md` (`just local-up`, then `just local-bootstrap`). Then, for M1:

```bash
ctx=$(nagarectl context current)
mkdir -p ~/.config/nagare/observability/$ctx
printf 'vmsingle:\n  spec:\n    resources:\n      limits:\n        memory: 1Gi\n' > ~/.config/nagare/observability/$ctx/vmks.yaml
nagarectl platform bootstrap plan --out ./platform-review
nagarectl platform bootstrap apply ./platform-review --yes
kubectl -n monitoring get vmsingle vmks-victoria-metrics-k8s-stack -o jsonpath='{.spec.resources.limits.memory}'; echo
```

The plan output lists the `vmks` release as the only changed resource, and the last command prints
`1Gi`. Then write `vmsingle:\n  image:\n    tag: v0.0.0\n` into the same file and run the plan again;
it stops with a message naming `vmsingle.image.tag`. For the apply-side check, restore the 1Gi
overlay, plan, change `1Gi` to `2Gi` in the file, and apply the saved review: it refuses with
"observability overlay changed after review" and changes nothing. Remove the file afterwards.

For M2, query VMSingle through the same port forward; `--data-urlencode` keeps curl from globbing
the selector:

```bash
q() { curl -sG 'http://127.0.0.1:8429/api/v1/query' --data-urlencode "query=$1" | jq -c '.data.result'; }
q 'count({job="kubelet",metrics_path="/metrics",__name__=~"apiserver_.*|etcd_.*"})'
q 'count(count by (__name__) ({job="apiserver"}))'
q 'kubelet_running_pods'
q 'kubelet_volume_stats_used_bytes'
```

The first prints `[]`; the second prints the value it printed before the change; the last two print
non-empty results.

Commit messages follow Conventional Commits and end with the trailer:

```text
ExecPlan: docs/plans/238-size-observability-per-context-drop-duplicate-kubelet-metrics-and-stagger-scheduled-backups.md
```


## Validation and Acceptance

M1 is accepted when the observability tests above pass, including the byte-identical contract for a
context without overlays, and the local run shows a plan that changes only `vmks`, a VMSingle with
a `1Gi` limit after apply, and a plan refusal naming an unsupported key (IR-40 AC-1, AC-2).

M2 is accepted when, on the local context after apply and at least two scrape intervals (one
minute), the four queries in Concrete Steps give the stated results:
`count({job="kubelet",metrics_path="/metrics",__name__=~"apiserver_.*|etcd_.*"})` returns no data;
`count(count by (__name__) ({job="apiserver"}))` equals its value before the change;
`kubelet_running_pods` and `kubelet_volume_stats_used_bytes` return data. The broker dashboard's
volume panels render in Grafana (IR-40 AC-3).

M3 is accepted when the schedule tests pass with the four offsets above, the receipt-check tests
accept `*/15` and staggered hourly schedules and refuse `*/30` and hourly-on-the-hour, and on a
local context with an existing hourly database created by the previous build, re-reviewing it
(`nagarectl db create postgres NAME --recovery-backup ... --recovery-key-version ... --save-plan ./db-review`)
shows a CronJob change limited to `spec.schedule` and the schedule-revision bytes derived from it,
applies, and `nagarectl db backup-receipts NAME --all --save-plan ./ingest` then ingests both a run
signed before and a run signed after the change (IR-40 AC-4, AC-5).

M4 is accepted when the documentation and ADR changes are committed and IR-40's status is updated.
The plan is complete when M1–M4 are accepted and `just gate-fast` is green on the final commit,
landed with `just land`.


## Idempotence and Recovery

Planning is read-only and can be repeated. Re-planning with an unchanged overlay gives the same
review digest; the stagger offsets depend only on names, so they are the same on every plan. If an
apply fails after an overlay change, remove or restore the overlay file and plan again; the review
records the overlay digest, so a stale review refuses rather than applying different values. On a
local context, `just local-down` discards everything. A backup schedule update can be reverted by
re-reviewing with the previous build; earlier receipts stay ingestible because ingestion accepts
earlier converged schedule revisions.


## Interfaces and Dependencies

No new libraries. The new interfaces are:

In `cli/nagarectl/src/Nagare/Inventory/Components/ObservabilityOverlay.hs`:

```haskell
data OverlayPolicy -- per release, the allowed segment paths
parseOverlayPolicy :: ByteString -> Either Text OverlayPolicy
validateOverlay :: OverlayPolicy -> Text -> FilePath -> Value -> Either Text ()
loadObservabilityOverlay :: Text -> Text -> IO (Either Text (Maybe (FilePath, ByteString)))
-- context name, release name; Nothing when the file is absent or empty
```

In `cli/nagarectl/src/Nagare/Inventory/BackupFreshness.hs`:

```haskell
hourlyScheduleOffset :: Text -> Int
staggeredRecoveryPointSchedule :: RecoveryPointObjective -> Text -> Text
isHourlyCadence :: Text -> Bool
```

In `cli/nagarectl/src/Nagare/Inventory/Adapters/HelmRuntime.hs`:

```haskell
checkOverlay :: Maybe (FilePath, ContentDigest) -> Maybe ByteString -> Either Text ()
-- the contract's resolved overlay path and digest, and the file's bytes if it could be read
```

The Helm contract gains two optional fields, `overlayPath` (the form `context:<release>.yaml`) and
`overlayDigest`, present only when an overlay is used; `HelmRuntimeConfig` gains
`helmOverlayDir :: !FilePath`, the directory `context:` resolves against. Helm v4.2.4 merges
multiple `--values` files left to right, maps by key and lists by replacement, which the overlay
relies on.
