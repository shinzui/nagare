---
id: 101
slug: alerting-and-backup-freshness-monitoring
title: "Alerting and backup freshness monitoring"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
---

# Alerting and backup freshness monitoring

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare is a personal single-node PaaS: one GCP VM (`nagare-01`) running k3s and
Knative, with a VictoriaMetrics/Logs/Traces + Grafana observability stack. At
authoring, that stack had dashboards but **zero alerting**. M2 has since enabled
vmalert with a curated rule set and an explicit blackhole notifier; the Helm
values still keep `alertmanager.enabled: false` until the operator supplies the
Pushover credential required by M1.
If the data disk fills up, a nightly database backup silently stops running, a
TLS certificate approaches expiry, or a pod crash-loops, nothing tells the
operator. Worse, the one tool that *does* check backup freshness on demand —
`nagarectl server status` — probes a stale object-store layout: it checks the
`postgres/` prefix (a removed host-Postgres flow) instead of `databases/<name>/`,
where managed-database dumps actually land. And the backup/restore path for
managed databases has never been exercised by an automated test.

After this plan is implemented:

1. The cluster evaluates a small curated set of alert rules (disk usage, backup
   staleness, certificate expiry, node NotReady, pod crash-looping) with
   **vmalert** and routes firing alerts through **Alertmanager** to a phone push
   notification (Pushover). You can prove the whole pipeline works by injecting
   a synthetic alert and watching your phone buzz.
2. `nagarectl server status` reports the freshness of the backups that actually
   exist: one `backup databases/<name>` line per managed database, plus the
   still-valid `litestream/` and `volumes/` prefixes. The legacy `postgres/`
   probe is gone.
3. `nagare local-smoke` (or `just local-smoke` in a contributor checkout) proves the managed-database backup story end-to-end with
   zero cloud resources: create a Postgres database, insert a sentinel row, back
   it up to the local MinIO object store, clobber the live data, restore into
   the scratch target, and assert the row came back. The cloud live-smoke
   workflow additionally runs on a monthly cron so the drill cannot silently rot.


## Progress

- [ ] M1: Create a Pushover account and application; obtain the user key and app
      token (manual, outside the repo — see Concrete Steps M1.1).
- [ ] M1: Write and sops-encrypt the active context's
      `cluster-secrets/<context>/alertmanager-config.yaml`
      (Secret `nagare-alertmanager-config`, namespace `monitoring`, key
      `alertmanager.yaml`, Pushover receiver). A source checkout may retain a tracked
      `cluster/secrets/alertmanager-config.yaml` compatibility copy.
- [ ] M1: Edit `cluster/observability/victoria-metrics/values.yaml` — enable
      `alertmanager` and `vmalert` with trimmed resources, point Alertmanager at
      the config Secret, remove M2's blackhole notifier, and retain
      `defaultRules.enabled: false`.
- [x] M1: Make `cluster/observability/install.sh` resolve context-owned encrypted
      Secrets, require Alertmanager's file when enabled, and preserve the checkout
      fallback. Released payloads/workspaces exclude `cluster/secrets`. (2026-08-26)
- [ ] M1: Run `nagare observability`; confirm the vmalert and Alertmanager pods
      are Running in `monitoring`.
- [ ] M1: Inject a synthetic alert into Alertmanager and receive the push
      notification on the phone.
- [x] M2: Enable vmalert with trimmed resources and an explicit blackhole
      notifier while M1's operator-owned Pushover credential is unavailable;
      disable the chart's bundled rules with the current `defaultRules.enabled`
      key. Exact chart 0.81.0 render passed. (2026-08-24)
- [ ] M2: Verify metric names against the live cluster in vmui (node-exporter
      filesystem metrics, kube-state-metrics CronJob/restart/node metrics). The
      cloud context still requires interactive reauthentication.
- [x] M2: Add `cluster/observability/cert-manager/vmservicescrape.yaml` using
      the selector and port verified against upstream cert-manager v1.20.2.
      (2026-08-24)
- [x] M2: Add `cluster/observability/vmrules/nagare-alerts.yaml` with six rules
      covering five failure modes; wire both manifests into `install.sh`;
      `promtool` reports all six rules valid. (2026-08-24)
- [x] M2: Add pure `backupPrefixes` to `cli/nagarectl/src/Nagare/Ops/Probe.hs`,
      rewire `gatherInventory` in `cli/nagarectl/src/Nagare/Ops/Status.hs` to
      enumerate managed databases and probe `databases/<name>` prefixes; drop
      the legacy `postgres` probe. (2026-08-24)
- [x] M2: Add unit tests for `backupPrefixes` to `cli/nagarectl/test/Spec.hs`;
      all 394 current tests pass in the packaged Nix check. (2026-08-26)
- [x] M2: Update `docs/runbooks/disaster-recovery.md` so the restore map has
      only the managed `databases/<name>/` layout. (2026-08-24)
- [ ] M2: `nagarectl server status` against the live cluster shows
      `backup databases/<name>` lines with fresh ages.
- [x] M3: Append the managed-DB backup→restore round-trip (new step 5) to
      `scripts/local-smoke.sh`, with matching teardown in its `cleanup()` trap;
      use the managed password without printing it and pin the cleanup client.
      (2026-08-24)
- [x] M3: Packaged `nagare local-smoke` passes repeatedly end-to-end, including
      volume restore, managed-DB backup/restore, `DB RESTORE OK`, and cleanup. The
      final acceptance run also proves `nagare-dbbackup-smokedb` is absent after
      teardown. Shell syntax and error-level shellcheck pass. (2026-08-26)
- [x] M3: Add a monthly `schedule:` cron to `.github/workflows/live-smoke.yml`
      alongside `workflow_dispatch`, update its header comment, and make the
      unwired authentication step fail explicitly. (2026-08-24)
- [x] Packaging reconciliation: ship `cluster/examples` in every context workspace,
      make `scripts/local-smoke.sh` use the packaged `nagarectl` on `PATH` with a
      checkout-only Cabal fallback, and add release checks proving examples are present
      while secrets are absent. The asset and clone-free package checks pass. (2026-08-26)


## Surprises & Discoveries

- Mori has no registered VictoriaMetrics, cert-manager, or kube-state-metrics
  project, so their pinned interfaces were checked against the exact Helm chart,
  upstream release tag/manifests, and upstream metric documentation instead.
  (2026-08-24)
- The cert-manager Service port in the exact v1.20.2 release manifest is
  `tcp-prometheus-servicemonitor`, not the plan's
  `tcp-prometheus-servicemonitoring`. The latter would have silently selected no
  endpoint. Its selector labels match the planned name/component labels.
  (2026-08-24)
- Chart 0.81.0 prefers `defaultRules.enabled` (the old `create` remains only a
  fallback) and refuses to render vmalert without a notifier. Because M1's
  Pushover credential is operator-owned, M2 uses
  `extraArgs.notifier.blackhole: "true"`; M1 must remove that flag when enabling
  the real Alertmanager notifier. (2026-08-24)
- kube-state-metrics can expose both `kube_job_status_failed` and
  `kube_job_status_succeeded` for a Job whose earlier attempt failed but retry
  succeeded. The backup-failure rule therefore subtracts successful Jobs. The
  stale rule also covers CronJobs older than 48 hours that have never succeeded,
  for which no last-success series exists. (2026-08-24)
- The local Docker endpoint was absent on 2026-08-24, so M3 initially stopped at
  offline shell/YAML validation. Docker was available when work resumed on
  2026-08-26; repeated packaged k3d runs then supplied the missing restore evidence.
- MasterPlan 20's packaged workspace intentionally omitted `cluster/secrets` and
  contributor source, exposing two checkout assumptions after this plan's last
  revision: `install.sh` looked for `../secrets/grafana-admin.yaml`, and
  `local-smoke.sh` unconditionally built `cli/nagarectl` even though neither path
  exists in an installed workspace. The 2026-08-26 fix moves cluster credentials to
  context-owned XDG configuration, ships the required `cluster/examples`, and uses the
  release-matched CLI already on `PATH`.
- A contributor shell can export `NAGARE_RESOLVED_CONTEXT` for the checkout.
  When the packaged workspace then sources `target.sh`, its different root makes
  that marker stale and clears `NAGARE_MODE=local`. The smoke harness now clears
  inherited resolution markers and sets its complete, fixed loopback target before
  sourcing the guardrail. (2026-08-26)
- StatefulSet rollout completion is not PostgreSQL readiness because the managed
  database manifest has no readiness probe. The first live run reached `psql`
  before the server listened; the harness now waits with `pg_isready` and connects
  explicitly over `127.0.0.1`. The same run exposed that `db delete` omitted its
  deterministic backup CronJob, so deletion now removes that child resource too.
  (2026-08-26)


## Decision Log

- Decision: Use **Pushover** (native `pushover_configs` Alertmanager receiver)
  as the push channel, not ntfy.sh.
  Rationale: Alertmanager speaks Pushover natively, so zero extra components run
  on the 2-vCPU node. ntfy.sh is free, but Alertmanager's `webhook_configs`
  posts its own JSON envelope which ntfy does not accept as a message body, so
  ntfy requires deploying a translation bridge (e.g. the `ntfy-alertmanager`
  project) — one more pod, image, and config to maintain on a deliberately
  minimal single node. Pushover costs a one-time ~$5 per device platform, which
  is acceptable for a personal platform in exchange for a zero-maintenance
  receiver. If the operator refuses the one-time cost, the documented fallback
  is a `webhook_configs` receiver pointed at a self-hosted `ntfy-alertmanager`
  bridge; the Secret/values wiring in this plan is channel-agnostic.
  Date: 2026-07-15.

- Decision: Detect backup staleness with **kube-state-metrics CronJob/Job
  metrics** (`kube_cronjob_status_last_successful_time`,
  `kube_job_status_failed`), not a GCS object-age exporter.
  Rationale: every scheduled backup is a `nagare-dbbackup-<name>` CronJob
  created by `nagarectl db create` (see Context). kube-state-metrics is already
  scraped, so "the CronJob has not succeeded in 48h" and "a backup Job failed"
  are available today with zero new components, and they catch the actual
  failure mode (the job stopped running or started failing). A GCS object-age
  exporter would additionally catch "job reports success but uploads nothing",
  but costs a new deployment, GCS credentials in-cluster, and maintenance —
  wrong trade at personal scale. The object-age angle is covered on demand by
  the fixed `nagarectl server status` probe (M2), which reads the real
  `databases/<name>/` prefixes via `gsutil`.
  Date: 2026-07-15.

- Decision: Disable the chart's default rules and ship a
  single curated VMRule instead of the chart's bundled kube-prometheus rule
  library.
  Rationale: the bundled library assumes a full multi-node cluster and alerts on
  components k3s embeds or hides (kube-scheduler / controller-manager endpoints,
  etcd, HA quorum), which would fire permanently-false alerts on a single-node
  k3s box and train the operator to ignore the channel. Five meaningful rules
  the operator will actually act on beat two hundred noisy ones.
  Date: 2026-07-15. Implemented with the current chart key
  `defaultRules.enabled: false` on 2026-08-24.

- Decision: `nagarectl server status` enumerates managed databases with the
  existing `Nagare.Database.Discover.listDatabases` in the `personal` namespace
  (the same default namespace every `nagarectl db` command uses), probing one
  `databases/<name>` prefix per database, and falls back to probing the bare
  `databases` prefix when none are discoverable (no kubeconfig, empty cluster).
  The legacy `postgres` prefix probe is **removed**, not kept-but-marked: the
  host-Postgres flow it watched no longer exists, and a permanently-warning line
  is noise that erodes trust in the report.
  Rationale: reuses the exact discovery path (`kubectl get statefulset -l
  nagare.dev/managed-by=nagarectl,nagare.dev/database`) that `db backup` itself
  uses, so the probe watches precisely the databases that have backups; degraded
  clusters still yield a bucket-level line rather than nothing.
  Date: 2026-07-15.

- Decision: Add the monthly cron to `.github/workflows/live-smoke.yml` even
  though its "Authenticate to GCP" step is still a TODO stub.
  Rationale: the scheduled run fails fast at the auth step, which functions as a
  monthly reminder that the live drill is not yet automated — strictly better
  than a workflow nobody remembers to dispatch. Wiring real GCP auth (WIF or a
  service-account key) is out of scope here and stays a TODO in the workflow.
  Date: 2026-07-15.

- Decision: The database backup round-trip is added to `scripts/local-smoke.sh`
  (MinIO, zero cloud), not to `scripts/live-smoke.sh`.
  Rationale: the pure logic (renderers, key layout) is identical across
  backends by construction (`Nagare.Cluster.GcsJob.StoreBackend` abstracts
  GCS/MinIO), so the free local test exercises the same code paths; the cloud
  smoke already costs real money/minutes per run and its scope is guarded by
  other plans.
  Date: 2026-07-15.

- Decision: Implement and validate M2 with vmalert in explicit blackhole mode
  while M1 remains blocked on operator-owned Pushover credentials and live phone
  delivery.
  Rationale: rule evaluation, scrape selection, and backup-freshness correctness
  are independent repository work. Chart 0.81.0 requires an explicit notifier;
  blackhole mode makes the temporary no-delivery state deliberate and renderable
  without inventing credentials. M1 removes the flag when its real notifier is
  enabled.
  Date: 2026-08-24.

- Decision: make encrypted observability credentials context-owned and validate M1/M3
  through the packaged operator release.
  Rationale: [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
  excludes credentials and contributor build trees from released workspaces. The
  installer now resolves
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` (or explicit
  `NAGARE_CLUSTER_SECRETS_DIR`) and fails before Helm when a required file is missing.
  `nagare local-smoke` uses the packaged CLI and shipped example, while `just` + Cabal
  remain contributor fallbacks.
  Date: 2026-08-26.

- Decision: make local smoke own a deterministic loopback target rather than inherit
  a caller's resolved cloud/check-out context.
  Rationale: this test always creates and targets `nagare-local`,
  `k3d-registry.localhost:5000`, the loopback sslip.io domain, and the in-cluster
  MinIO endpoint. Carrying a cloud profile into that harness is both incorrect and
  unsafe. Explicit local values also make packaged and contributor runs identical.
  Date: 2026-08-26.


## Outcomes & Retrospective

M2's repository implementation is complete: the exact pinned chart renders,
the cert-manager scrape matches the pinned upstream Service, all six PromQL
rules pass `promtool`, and all 394 current nagarectl tests pass. Live series discovery,
rule evaluation, and the status transcript remain open because the cloud context
requires interactive gcloud reauthentication. M1 remains operator-gated on real
Pushover credentials and phone delivery.
M3's restore round-trip and monthly workflow are implemented. The packaged local
create→backup→restore assertion passes repeatedly, including teardown and an explicit
post-run check that the database's deterministic backup CronJob is gone;
the scheduled cloud workflow intentionally stops at its explicit authentication
TODO rather than proceeding unauthenticated.
Packaging reconciliation now makes both remaining workflows runnable from a released
operator package without a checkout and keeps encrypted credentials outside immutable
payloads. Live Pushover and cluster metrics/status evidence remain open.


## Context and Orientation

This section is self-contained; you need no other document.

**The repository.** `/…/nagare` is a mono-repo for a personal PaaS. The parts
this plan touches:

**Packaged operation.** [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
distributes release assets in an immutable payload and materializes a per-context
workspace under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/platform/`.
Operators invoke `nagare observability` and `nagare local-smoke` from the pinned
release; contributors may use the equivalent `just` recipes in this checkout.
Encrypted cluster Secrets are not payload assets. `scripts/lib/cluster-secrets.sh`
resolves the context-owned XDG directory or `NAGARE_CLUSTER_SECRETS_DIR`, with tracked
`cluster/secrets/` only as a checkout compatibility fallback.

- `cluster/observability/` — the observability stack, installed by the
  idempotent script `cluster/observability/install.sh` (run via `nagare
  observability`, or `just observability` while contributing). The script `helm upgrade --install`s the
  chart `vm/victoria-metrics-k8s-stack` **version 0.81.0** as release `vmks`
  into namespace `monitoring`, with values from
  `cluster/observability/victoria-metrics/values.yaml`. That chart bundles
  VMSingle (the metrics store, HTTP port pinned to 8429), VMAgent (the scraper,
  with `selectAllByDefault: true` so it picks up any `VMServiceScrape` object in
  the cluster), `prometheus-node-exporter` (host CPU/memory/disk metrics),
  `kube-state-metrics` (Kubernetes object state as metrics), the
  victoria-metrics-operator (which reconciles the `VMAlert`, `VMAlertmanager`,
  `VMRule`, and `VMServiceScrape` custom resources), and Grafana. Lines 66–70 of
  the values file currently read, in substance:

  ```yaml
  alertmanager:
    enabled: false
  vmalert:
    enabled: true
    spec:
      extraArgs:
        notifier.blackhole: "true"
  ```

  An existing example of a hand-written scrape object is
  `cluster/observability/brokers/vmservicescrape.yaml` (kind `VMServiceScrape`,
  namespace `monitoring`), applied by `install.sh` right after the vmks helm
  upgrade.

- Context-owned cluster secrets live under
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` and are
  intentionally absent from released payloads/workspaces. The explicit
  `NAGARE_CLUSTER_SECRETS_DIR` override wins. A source checkout may use tracked
  `cluster/secrets/` as a compatibility fallback; its `.sops.yaml` encrypts only
  `data`/`stringData`. `install.sh` requires `grafana-admin.yaml` and, when
  Alertmanager is enabled, `alertmanager-config.yaml` before invoking Helm.

- `cli/nagarectl/` — the Haskell CLI (cabal project). Modules relevant here:
  - `src/Nagare/Ops/Status.hs` — assembles the `nagarectl server status`
    report. Before M2, `gatherInventory` ran these stale fixed probes:

    ```haskell
    , probeBackup bucket "postgres"
    , probeBackup bucket "litestream"
    , probeBackup bucket "volumes"
    ```

    M2 now discovers managed databases and appends
    `map (probeBackup bucket) (backupPrefixes dbNames)`. `probeBackup bucket
    prefix` shells out to
    `gsutil ls -l gs://<bucket>/<prefix>/`, extracts the newest object
    timestamp with the pure `parseNewestBackupAge`, and grades it with
    `gradeAge` (OK under 24h, WARN otherwise). The `postgres/` prefix belonged
    to a **removed** host-Postgres backup flow; managed-database dumps land
    under `databases/<name>/` (next bullet), so the first line warns forever
    while real backups go unwatched.
  - `src/Nagare/Ops/Probe.hs` — the pure, unit-tested parsers used by
    Status.hs (`parseNewestBackupAge`, `parseDfUsage`, `gradeKourier`, …) plus
    the `Probe`/`ProbeStatus` types and IO wrappers (`captureTool`). New pure
    logic belongs here, tested in `cli/nagarectl/test/Spec.hs` (tasty/HUnit;
    existing cases for `parseNewestBackupAge` are near line 1089).
  - `src/Nagare/Database/Discover.hs` — `listDatabases :: Text -> IO (Either
    Text [DbRow])` finds every managed database in a namespace via
    `kubectl get statefulset -l
    nagare.dev/managed-by=nagarectl,nagare.dev/database -o json`. An
    unreachable cluster yields `Right []`; `DbRow` has `drName :: Text`.
  - `src/Nagare/Database/Backup.hs` — owns the backup layout and jobs. Key
    facts: on-demand backups upload to the object key
    `databases/<name>/<timestamp>.<ext>` (`dbBackupObjectPath`); `nagarectl db
    create` also applies a self-pruning CronJob named `nagare-dbbackup-<name>`
    (schedule `17 3 * * *`, i.e. 03:17 UTC daily; `concurrencyPolicy: Forbid`)
    unless the database's retention is `Delete`. `runDbBackup` prints
    `Backup written: <url>` on success. The `StoreBackend` type
    (`Nagare.Cluster.GcsJob`) abstracts GCS (`gs://…`, cloud mode) vs MinIO
    (`s3://nagare-backups/…`, local mode); the backend is chosen from the
    active target context's mode (`NAGARE_MODE`).
  - `src/Nagare/Database/Restore.hs` — `nagarectl db restore NAME BACKUP_ID`
    accepts either a bare timestamp or a **full `gs://`/`s3://` URL** as
    BACKUP_ID. By default it restores into a scratch target — for Postgres the
    database `<POSTGRES_DB>_restore_scratch` inside the same instance — and
    prints `Restored <name> into a scratch target from <src> — compare, then
    promote manually.`
  - Naming: the managed Secret is `nagare-db-<name>` (keys `POSTGRES_USER`,
    `POSTGRES_DB`, `POSTGRES_PASSWORD` for Postgres), the StatefulSet/Service
    are `<name>` (pod `<name>-0`), the data PVC is `nagare-db-<name>-data`.
    `nagarectl db delete NAME --yes` removes the StatefulSet/Service/Secret/
    CronJob but **keeps** the PVC when retention is `Retain` (the default),
    printing the manual `kubectl delete pvc` command.

- `scripts/local-smoke.sh` — the zero-cloud end-to-end smoke test (`nagare
  local-smoke`; `just local-smoke` in a checkout): stands up a k3d cluster + local registry + MinIO if needed,
  deploys the `uploads-volume` example app, writes a sentinel file, snapshots
  the volume to MinIO, restores it, asserts HTTP 200, and tears down via a
  `cleanup()` EXIT trap. It exports `NAGARE_MODE=local` up top, so any
  `nagarectl` command it runs automatically selects the MinIO backend. It
  resolves the release-matched `nagarectl` from `PATH` and uses a checkout-only
  Cabal fallback, defines a `nagarectl()` wrapper, a
  `minio_rm` helper that deletes an `s3://…` object via a throwaway `minio/mc`
  pod, and ends with `echo "local smoke: OK"`. Trap-safety refactors of this
  script are owned by `docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md`
  — this plan only **appends** a step and teardown lines.

- `.github/workflows/live-smoke.yml` — the cloud smoke workflow. It now has both
  `workflow_dispatch` and the monthly cron added by M3. Its "Authenticate to
  GCP" step remains an explicit fail-fast TODO stub.

- `cert-manager` — installed in namespace `cert-manager` from the upstream
  v1.20.2 manifest (see `cluster/bootstrap/cert-manager/README.md`). The
  upstream manifest's `cert-manager` Service exposes the controller's metrics
  on port 9402 (port name `tcp-prometheus-servicemonitor`), which nothing
  currently scrapes. cert-manager exports
  `certmanager_certificate_expiration_timestamp_seconds` per Certificate.

**Terms.** *vmalert* is VictoriaMetrics' rule evaluator: it periodically runs
each alerting rule's query against VMSingle and, when a rule "fires", pushes the
alert to Alertmanager. *Alertmanager* is the standard Prometheus-ecosystem
component that deduplicates/groups alerts and delivers notifications (it has a
built-in Pushover sender). *VMRule* is the operator CRD holding rule groups;
*VMServiceScrape* is the operator CRD telling VMAgent to scrape a Service.
*MetricsQL* is VictoriaMetrics' query language, a backwards-compatible superset
of PromQL — every expression in this plan is plain PromQL and works in both.
*Pushover* (pushover.net) is a push-notification service: you register, install
the phone app (one-time ~$5), create an "application" to get an API token, and
anything holding your user key + token can send you a push. *vmui* is the query
UI built into VMSingle at `/vmui`. *sops* is the encrypted-secrets tool; *age*
is its keypair encryption backend.

**Integration with sibling plans (read before editing).**

- `docs/plans/100-bound-and-harden-cluster-workloads.md` ALSO edits
  `cluster/observability/victoria-metrics/values.yaml`: it owns the `grafana:`
  block (admin secret) and retention caps, and establishes the sops-Secret
  pattern for observability credentials. This plan is a **soft dependent**:
  confine every edit here to the `alertmanager:` / `vmalert:` /
  `defaultRules:` blocks — never touch `grafana:`. Plan 100 has landed; its
  Grafana Secret must now be copied or re-encrypted into the active context's
  operator-owned cluster-secret directory before running the packaged
  installer.
- `docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md`
  and its ExecPlan 106 established the immutable payload/context-workspace
  boundary recorded by ADR 4. This plan must not add credentials or contributor
  build trees to that payload. It may add immutable runtime inputs, such as
  `cluster/examples`, and release checks for those inputs.
- `docs/plans/102-nagarectl-correctness-and-robustness-fixes.md` touches
  `cli/nagarectl` in different modules (`Deploy.hs`, `Database/Create.hs`).
  This plan owns `Ops/Status.hs` (and the additive change to `Ops/Probe.hs`);
  no overlap is expected — if a merge conflict appears anywhere else, this
  plan's change is in the wrong place.
- `docs/plans/97-…` owns `scripts/local-smoke.sh` trap-safety changes; this
  plan only appends test steps and teardown lines to the existing structure.

**Commit conventions.** Conventional Commits, with these trailers on every
commit belonging to this plan:

```text
MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/101-alerting-and-backup-freshness-monitoring.md
Intention: intention_01kzakvy1qeasagg3rpbn44749
```


## Plan of Work

The work is three independently verifiable milestones. M1 stands up the alert
delivery pipeline (vmalert → Alertmanager → phone) with a synthetic alert as
proof. M2 gives the pipeline real rules and fixes the `nagarectl` freshness
probe, so both the automated and on-demand views watch the true backup layout.
M3 closes the loop on backups being *restorable*, not just present, by adding a
database round-trip to the local smoke test and putting the cloud smoke on a
calendar.


### Milestone 1 — vmalert + Alertmanager with a Pushover channel

Scope: enable Alertmanager alongside the already-enabled vmalert in
`cluster/observability/victoria-metrics/values.yaml`, feed Alertmanager its
config (with Pushover credentials) from a context-owned, sops-managed Secret.
The installer already resolves and applies that Secret without assuming a
checkout path. At the end, `kubectl get pods
-n monitoring` shows vmalert and Alertmanager Running, and a synthetic alert
POSTed to Alertmanager arrives as a push notification on the phone. No rules
from the chart are enabled (`defaultRules.enabled: false`); the curated M2
VMRule is already present, so verify its evaluation separately from the
synthetic delivery test.

The edits:

1. **Context-owned `alertmanager-config.yaml` (new).** A Kubernetes Secret
   named `nagare-alertmanager-config` in namespace `monitoring` whose single
   key `alertmanager.yaml` is a complete Alertmanager configuration with one
   Pushover receiver. Store it under
   `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/`, or in
   `NAGARE_CLUSTER_SECRETS_DIR`. Write it in plaintext first, then encrypt it in
   place using an operator-owned sops policy that encrypts only `data` and
   `stringData`. A checkout's `cluster/secrets/notes-db-url.yaml` shows the
   manifest shape, but released workspaces never contain that directory.
   Plaintext template:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: nagare-alertmanager-config
     namespace: monitoring
   type: Opaque
   stringData:
     alertmanager.yaml: |
       route:
         receiver: pushover
         group_by: ["alertname"]
         group_wait: 30s
         group_interval: 5m
         repeat_interval: 12h
       receivers:
         - name: pushover
           pushover_configs:
             - user_key: "REPLACE_WITH_PUSHOVER_USER_KEY"
               token: "REPLACE_WITH_PUSHOVER_APP_TOKEN"
               send_resolved: true
   ```

   `repeat_interval: 12h` re-notifies twice a day while a problem persists —
   right for a personal platform (annoying enough to act, not a pager storm).
   `send_resolved: true` sends an all-clear push.

2. **`cluster/observability/victoria-metrics/values.yaml`.** Replace the five
   lines quoted in Context (66–70) with:

   ```yaml
   # --- Alerting (EP-101): vmalert evaluates the curated VMRule groups in
   # cluster/observability/vmrules/; Alertmanager routes firing alerts to a
   # phone push (Pushover). The Alertmanager config — which embeds the Pushover
   # credentials — lives in the active context's operator-owned cluster-secret
   # directory (Secret nagare-alertmanager-config, key alertmanager.yaml),
   # applied by install.sh BEFORE this chart. Resources
   # trimmed for the 2-vCPU node in the same style as vmsingle/vmagent above:
   # small CPU request, no CPU limit, memory limit as the OOM guard.
   alertmanager:
     enabled: true
     spec:
       configSecret: nagare-alertmanager-config
       resources:
         requests:
           cpu: 10m
           memory: 32Mi
         limits:
           memory: 64Mi
   vmalert:
     enabled: true
     spec:
       # Evaluate every VMRule in the cluster (mirrors vmagent's
       # selectAllByDefault so Nagare-owned rule files are discovered without
       # another chart-value edit per file).
       selectAllByDefault: true
       evaluationInterval: 30s
       resources:
         requests:
           cpu: 25m
           memory: 64Mi
         limits:
           memory: 128Mi

   # The chart's bundled kube-prometheus rule library targets full multi-node
   # clusters (separate scheduler/controller-manager/etcd endpoints that k3s
   # embeds) and would fire permanently-false alerts on this single-node box.
   # Alerting starts from the curated VMRule in
   # cluster/observability/vmrules/nagare-alerts.yaml (EP-101 M2).
   defaultRules:
     enabled: false
   ```

   Do not touch any other block, especially `grafana:` (owned by plan 100).
   Before committing, verify the chart honors this shape against the pinned
   version (the operator's `VMAlertmanager` CRD consumes `configSecret`; the
   chart must not also inject a generated config):

   ```bash
   cd /path/to/nagare
   helm repo add vm https://victoriametrics.github.io/helm-charts/ && helm repo update
   helm template vmks vm/victoria-metrics-k8s-stack --version 0.81.0 \
     -n monitoring -f cluster/observability/victoria-metrics/values.yaml \
     | grep -B2 -A12 'kind: VMAlertmanager'
   ```

   Expect a `VMAlertmanager` object whose `spec` contains
   `configSecret: nagare-alertmanager-config` and the resources above, and a
   `VMAlert` object whose `spec.notifier`/`notifiers` points at the
   Alertmanager service. If chart 0.81.0 spells the values key differently
   (chart keys drift across versions — e.g. some versions want the config under
   `alertmanager.config` rendered into a chart-generated secret), adapt to what
   `helm template` proves and record the difference in Surprises & Discoveries.
   The non-negotiable outcome: Alertmanager's live config is the sops-managed
   Secret's `alertmanager.yaml`, and no plaintext credential appears in Git.

3. **`cluster/observability/install.sh`.** This packaging reconciliation is
   implemented: source `scripts/lib/cluster-secrets.sh`, resolve the active
   context directory (or explicit override), and require
   `alertmanager-config.yaml` before Helm whenever the values file enables
   Alertmanager. Keep this fail-closed resolver; do not reintroduce
   `$ROOT/../secrets` as the operational path.

Acceptance for M1: `nagare observability` completes from outside a checkout;
both new pods are Running; a
synthetic alert POSTed to Alertmanager's API produces a push notification on
the phone within ~a minute (exact commands and transcripts in Concrete Steps).


### Milestone 2 — six rules for five failure modes, and a truthful freshness probe

Scope: give vmalert its rules, add the one missing scrape (cert-manager), and
fix `nagarectl server status` to probe `databases/<name>/`. At the end, `kubectl
get vmrule -n monitoring` shows exactly one Nagare rule file, vmalert's UI lists
five healthy (non-erroring) rules, and `nagarectl server status` prints one
fresh `backup databases/<name>` line per managed database.

**2a. Verify metric names first.** Metric names below are the standard
node-exporter/kube-state-metrics/cert-manager names, but k3s packaging and
chart relabeling can surprise (e.g. mountpoint filtering in the node-exporter's
chart defaults). Before committing rules, check each name in vmui:

```bash
# Find the VMSingle service name, then port-forward its pinned port 8429:
kubectl get svc -n monitoring | grep vmsingle
kubectl -n monitoring port-forward svc/<vmsingle-service-name> 8429:8429
# Open http://127.0.0.1:8429/vmui and run each query below.
```

Queries to confirm (each must return at least one series):

```text
node_filesystem_size_bytes{mountpoint="/"}
node_filesystem_size_bytes{mountpoint="/var/lib/nagare"}
kube_cronjob_status_last_successful_time
kube_job_status_failed
kube_node_status_condition{condition="Ready",status="true"}
kube_pod_container_status_restarts_total
```

If `node_filesystem_*` lacks the `/var/lib/nagare` mountpoint, the
node-exporter chart's mountpoint exclude-regex is filtering it — add a
`prometheus-node-exporter.extraArgs` override in the values file to include it,
and record what was needed in Surprises & Discoveries. If
`kube_cronjob_status_last_successful_time` is absent (it requires
kube-state-metrics ≥ v2.5), fall back to
`kube_cronjob_status_last_schedule_time` combined with the `BackupJobFailed`
rule, and record the substitution. `certmanager_*` names are verified after 2b.

**2b. Scrape cert-manager.** New file
`cluster/observability/cert-manager/vmservicescrape.yaml`:

```yaml
# Scrape cert-manager's controller metrics (EP-101): the upstream v1.20.x
# manifest's `cert-manager` Service exposes port 9402, name
# "tcp-prometheus-servicemonitor". VMAgent's selectAllByDefault picks this
# object up automatically. Feeds the CertificateExpiringSoon rule
# (certmanager_certificate_expiration_timestamp_seconds).
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: cert-manager
  namespace: monitoring
  labels:
    nagare.dev/component: alerting
spec:
  namespaceSelector:
    matchNames:
      - cert-manager
  selector:
    matchLabels:
      app.kubernetes.io/name: cert-manager
      app.kubernetes.io/component: controller
  endpoints:
    - port: tcp-prometheus-servicemonitor
      path: /metrics
      interval: 60s
```

Before writing it, confirm the Service's actual labels and port name (they must
match exactly or the scrape silently selects nothing):

```bash
kubectl -n cert-manager get svc cert-manager -o yaml | grep -E 'app.kubernetes.io|name: tcp|port: 9402'
```

After applying, confirm in vmui that
`certmanager_certificate_expiration_timestamp_seconds` returns series (one per
Certificate; if the cluster currently has no Certificate objects — the platform
is HTTP-first until a real base domain is delegated — the query is legitimately
empty and the rule simply cannot fire yet; note that in the report).

**2c. The rules.** New file
`cluster/observability/vmrules/nagare-alerts.yaml`:

```yaml
# The curated Nagare alert set (EP-101). Five rules the operator will actually
# act on; the chart's bundled kube-prometheus library is disabled
# (defaultRules.enabled: false in victoria-metrics/values.yaml) because it
# false-fires on single-node k3s. Expressions are plain PromQL (valid
# MetricsQL). Applied by cluster/observability/install.sh; vmalert discovers it
# via selectAllByDefault.
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: nagare-alerts
  namespace: monitoring
  labels:
    nagare.dev/component: alerting
spec:
  groups:
    - name: nagare.node
      interval: 60s
      rules:
        - alert: DiskUsageHigh
          # Boot (/) or data (/var/lib/nagare) filesystem above 80% for 15m.
          # fstype filter drops pseudo-filesystems node-exporter also reports.
          expr: |
            (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|iso9660", mountpoint=~"/|/var/lib/nagare"}
               / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|iso9660", mountpoint=~"/|/var/lib/nagare"}) * 100
              > 80
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: 'Disk {{ $labels.mountpoint }} is {{ $value | printf "%.0f" }}% full'
            description: 'Filesystem {{ $labels.mountpoint }} on nagare-01 has been above 80% for 15m. Free space or grow the disk (docs/user/resizing-the-vm.md).'
        - alert: NodeNotReady
          # The single k3s node reports NotReady (or the Ready condition is
          # false) for 5 minutes. On a one-node platform this is "everything
          # is down": page-worthy.
          expr: kube_node_status_condition{condition="Ready",status="true"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: 'k3s node {{ $labels.node }} NotReady for 5m'
            description: 'The node has not been Ready for 5 minutes. Check the VM (nagarectl server status; gcloud compute instances list) and k3s.'
    - name: nagare.workloads
      interval: 60s
      rules:
        - alert: PodCrashLooping
          # More than 3 container restarts in 30m — the CrashLoopBackOff shape.
          expr: increase(kube_pod_container_status_restarts_total[30m]) > 3
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: 'Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash-looping'
            description: 'Container {{ $labels.container }} restarted more than 3 times in 30m. kubectl -n {{ $labels.namespace }} logs {{ $labels.pod }} -c {{ $labels.container }} --previous'
    - name: nagare.backups
      interval: 60s
      rules:
        - alert: BackupJobFailed
          # A run of any nagare-dbbackup-<name> CronJob failed. kube-state-
          # metrics exposes child Jobs as kube_job_status_failed{job_name=...};
          # the CronJob's children inherit its name prefix. Exclude an
          # eventually successful Job whose earlier attempt failed.
          expr: |
            kube_job_status_failed{job_name=~"nagare-dbbackup-.*"} > 0
              unless on(namespace, job_name)
                kube_job_status_succeeded{job_name=~"nagare-dbbackup-.*"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: 'Database backup job {{ $labels.job_name }} failed'
            description: 'kubectl -n {{ $labels.namespace }} logs job/{{ $labels.job_name }} — then run nagarectl db backup manually once fixed.'
        - alert: BackupStale
          # The scheduled backup CronJob has not SUCCEEDED for 48h (schedule is
          # daily at 03:17 UTC, so 48h = two consecutive misses). This also
          # catches a suspended or deleted-but-expected CronJob going quiet
          # only while the metric exists; the nagarectl server status probe
          # (this plan, M2) covers the object-store view on demand.
          expr: |
            (time() - kube_cronjob_status_last_successful_time{cronjob=~"nagare-dbbackup-.*"}) > 172800
              or
            (time() - kube_cronjob_created{cronjob=~"nagare-dbbackup-.*"} > 172800
              unless on(namespace, cronjob)
                kube_cronjob_status_last_successful_time{cronjob=~"nagare-dbbackup-.*"})
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: 'Backups of {{ $labels.cronjob }} stale (>48h since last success)'
            description: 'The daily dump has not succeeded in 48h. Check kubectl -n {{ $labels.namespace }} get cronjob {{ $labels.cronjob }} and recent Jobs; confirm object ages with nagarectl server status.'
    - name: nagare.certificates
      interval: 300s
      rules:
        - alert: CertificateExpiringSoon
          # Any cert-manager Certificate expiring within 14 days. cert-manager
          # renews at 2/3 lifetime (Let's Encrypt: ~30 days before expiry), so
          # 14 days out means renewal has been failing for ~2 weeks.
          expr: (certmanager_certificate_expiration_timestamp_seconds - time()) < 1209600
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: 'Certificate {{ $labels.namespace }}/{{ $labels.name }} expires in <14d'
            description: 'Renewal is likely failing. kubectl -n {{ $labels.namespace }} describe certificate {{ $labels.name }}; check the letsencrypt-dns ClusterIssuer and DNS-01 solver.'
```

Wire both new manifests into `cluster/observability/install.sh` next to the
existing broker-scrape apply (after the vmks helm upgrade, which guarantees the
CRDs exist on a fresh install):

```bash
kubectl apply -f "$ROOT/vmrules/nagare-alerts.yaml"
kubectl apply -f "$ROOT/cert-manager/vmservicescrape.yaml"
```

**2d. Fix the `nagarectl` probe.** Two files, plus tests.

In `cli/nagarectl/src/Nagare/Ops/Probe.hs`, add a pure function (near
`parseNewestBackupAge`) and export it from the module's export list:

```haskell
-- | The object-store prefixes @nagarectl server status@ probes for backup
-- freshness (EP-101): one @databases/<name>@ prefix per discovered managed
-- database (the EP-47 layout — scheduled dumps land at
-- @databases/<name>/scheduled-<ts>.<ext>@), falling back to the bare
-- @databases@ prefix when none are discoverable (no kubeconfig, empty
-- cluster) so the report always carries at least one database-backup line,
-- plus the fixed @litestream@ and @volumes@ prefixes. The legacy @postgres@
-- prefix (the removed host-Postgres flow) is intentionally absent.
backupPrefixes :: [Text] -> [Text]
backupPrefixes dbNames =
  (if null dbNames then ["databases"] else map ("databases/" <>) dbNames)
    <> ["litestream", "volumes"]
```

In `cli/nagarectl/src/Nagare/Ops/Status.hs`, import the discovery
(`import Nagare.Database.Discover (DbRow (..), listDatabases)`) and rework
`gatherInventory`: before the `core <- sequence [...]` block, enumerate the
databases —

```haskell
  dbNames <- either (const []) (map drName) <$> listDatabases "personal"
```

— then replace the three hard-coded probe lines

```haskell
      , probeBackup bucket "postgres"
      , probeBackup bucket "litestream"
      , probeBackup bucket "volumes"
      ]
```

by ending the fixed list after `probeArch tp` and appending the computed
prefixes, so the final shape is:

```haskell
  core <-
    sequence
      ( [ probeVm o
        , probeNode
        -- … the unchanged probes through probeArch tp …
        ]
          <> map (probeBackup bucket) (backupPrefixes dbNames)
      )
```

`probeBackup` itself is unchanged — it already takes an arbitrary prefix and
labels the line `backup <prefix>`, so the report gains lines like
`backup databases/notes  OK  newest object 6h ago`. The `"personal"` namespace
matches the default of every `nagarectl db` command (see Decision Log). Note
the fallback's behavior honestly: `gsutil ls -l gs://<bucket>/databases/` lists
subdirectory markers without timestamps, so the fallback line reads
`no objects (empty prefix)` (StatusWarn) — correct when there are truly no
backups, and a visible prompt to investigate when the cluster was merely
unreachable.

Add unit tests in `cli/nagarectl/test/Spec.hs` next to the existing
`parseNewestBackupAge` cases (~line 1089), adding `backupPrefixes` to the
existing `Nagare.Ops.Probe` import list (~line 196):

```haskell
  , testCase "backupPrefixes: one databases/<name> prefix per db + fixed tails" $
      backupPrefixes ["notes", "shop"]
        @?= ["databases/notes", "databases/shop", "litestream", "volumes"]
  , testCase "backupPrefixes: no discoverable dbs -> bare databases prefix" $
      backupPrefixes [] @?= ["databases", "litestream", "volumes"]
```

Finally, update the restore map in `docs/runbooks/disaster-recovery.md` (~line
45) from `gcs://<backupBucket>/postgres/` to
`gcs://<backupBucket>/databases/<name>/` so the runbook matches both the code
and reality.

Acceptance for M2: `cabal test` green; `kubectl get vmrule -n monitoring` shows
only `nagare-alerts`; vmalert's rule status shows all six rules evaluating
without errors; `nagarectl server status` shows `backup databases/<name>` lines
(transcripts in Validation).


### Milestone 3 — prove backups restore, on a schedule

Scope: extend `scripts/local-smoke.sh` with a managed-database round-trip
(create → sentinel row → backup to MinIO → clobber → restore → assert the row
survived) and add a monthly cron to `.github/workflows/live-smoke.yml`. At the
end, `nagare local-smoke` exercises the entire managed-DB backup/restore machinery
with zero cloud resources from the pinned release. `just local-smoke` preserves
the contributor-checkout path.

**3a. `scripts/local-smoke.sh`.** Two edits, both purely additive (plan 97 owns
structural/trap changes).

First, extend `cleanup()` (keep its existing lines; append before
`echo "== teardown done =="`):

```bash
  # EP-101: managed-DB round-trip teardown (all best-effort).
  nagarectl db delete "${SMOKE_DB}" -n "${SMOKE_NS}" --yes >/dev/null 2>&1 || true
  kubectl -n "${SMOKE_NS}" delete pvc "nagare-db-${SMOKE_DB}-data" >/dev/null 2>&1 || true
  [ -n "${DB_BACKUP_URL}" ] && minio_rm "${DB_BACKUP_URL}"
```

and initialize the new state variables next to the existing
`SNAPSHOT_URL=""` / `PF_PID=""` declarations (they must exist before the trap
can reference them):

```bash
SMOKE_DB="smokedb"
DB_BACKUP_URL=""
```

Second, insert the new step between the current step 4 (HTTP 200 check) and the
final `echo "local smoke: OK"`:

```bash
# --- Step 5 (EP-101): managed-DB backup -> restore round-trip via MinIO ---
# Proves the EP-47 backup/restore machinery end-to-end on the same MinIO
# backend the volume snapshot already uses: NAGARE_MODE=local (exported above)
# makes nagarectl pick the MinIO StoreBackend automatically.
echo "== step 5: managed-DB create -> backup -> restore -> assert row count =="
nagarectl db create postgres "${SMOKE_DB}" -n "${SMOKE_NS}"   # waits for Ready

# Credentials/identity from the managed Secret (nagare-db-<name>). The password
# is passed only as the psql process environment inside the pod and is never
# printed or written to disk.
PGUSER="$(kubectl -n "${SMOKE_NS}" get secret "nagare-db-${SMOKE_DB}" -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)"
PGPASSWORD="$(kubectl -n "${SMOKE_NS}" get secret "nagare-db-${SMOKE_DB}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
PGDB="$(kubectl -n "${SMOKE_NS}" get secret "nagare-db-${SMOKE_DB}" -o jsonpath='{.data.POSTGRES_DB}' | base64 -d)"
for _attempt in $(seq 1 60); do
  if kubectl -n "${SMOKE_NS}" exec "${SMOKE_DB}-0" -- \
      pg_isready -h 127.0.0.1 -U "${PGUSER}" -d "${PGDB}" >/dev/null 2>&1; then
    break
  fi
  if [ "${_attempt}" = "60" ]; then
    echo "local smoke: PostgreSQL did not accept connections within 120s" >&2
    exit 1
  fi
  sleep 2
done
psql_in_pod() {
  kubectl -n "${SMOKE_NS}" exec "${SMOKE_DB}-0" -- \
    env PGPASSWORD="${PGPASSWORD}" psql -h 127.0.0.1 -U "${PGUSER}" -d "$1" -tAc "$2"
}

echo "== step 5a: write a sentinel row =="
psql_in_pod "${PGDB}" "CREATE TABLE IF NOT EXISTS smoke_sentinel(v text); TRUNCATE smoke_sentinel; INSERT INTO smoke_sentinel VALUES ('smoke $$');"

echo "== step 5b: back up to MinIO =="
db_backup_out="$(nagarectl db backup "${SMOKE_DB}" -n "${SMOKE_NS}")"
echo "${db_backup_out}"
DB_BACKUP_URL="$(printf '%s\n' "${db_backup_out}" | sed -n 's/^Backup written: //p' | head -1)"
case "${DB_BACKUP_URL}" in
  s3://*) echo "  backup: ${DB_BACKUP_URL}" ;;
  *) echo "  expected an s3:// (MinIO) backup URL, got '${DB_BACKUP_URL}'" >&2; exit 1 ;;
esac

echo "== step 5c: clobber the live table, restore into the scratch target =="
psql_in_pod "${PGDB}" "TRUNCATE smoke_sentinel;"
# db restore accepts the full s3:// URL as BACKUP_ID; default target is the
# scratch database ${PGDB}_restore_scratch inside the same instance.
nagarectl db restore "${SMOKE_DB}" "${DB_BACKUP_URL}" -n "${SMOKE_NS}"

echo "== step 5d: assert the sentinel row survived the round-trip =="
db_count="$(psql_in_pod "${PGDB}_restore_scratch" "SELECT count(*) FROM smoke_sentinel;" | tr -d '[:space:]')"
if [ "${db_count}" = "1" ]; then
  echo "  DB RESTORE OK: smoke_sentinel has ${db_count} row in ${PGDB}_restore_scratch"
else
  echo "  DB RESTORE FAILED: expected 1 row in ${PGDB}_restore_scratch, got '${db_count}'" >&2
  exit 1
fi
```

Notes for the implementer: `nagarectl db create` blocks until the StatefulSet
rolls out and prints `Created database smokedb (postgres) at
smokedb.personal.svc.cluster.local`; the first run pulls the `postgres:18`
image into k3d, so allow a couple of minutes. `db backup` in local mode skips
the laptop-side prune by design (MinIO is only reachable in-cluster). The
scratch database lives inside the same Postgres instance, so it disappears with
the pod/PVC in teardown.

**3b. `.github/workflows/live-smoke.yml`.** Replace the trigger block and
update the header comment (which currently claims "MANUAL trigger ONLY"):

```yaml
# EP-5 (docs/plans/69, MasterPlan 13) + EP-101: manual trigger, plus a monthly
# scheduled drill so the live backup/restore path cannot silently rot. The run
# deploys to the real cluster and requires the running VM + GCP credentials;
# until the auth step below is wired, the scheduled run fails fast at that step
# (a deliberate monthly reminder — see EP-101 Decision Log). Never runs on
# push/PR.
on:
  workflow_dispatch:
  schedule:
    - cron: "23 6 1 * *"   # 06:23 UTC on the 1st of each month
```

Acceptance for M3: `nagare local-smoke` prints the step-5 markers ending in
`DB RESTORE OK` and finally `local smoke: OK`; `git grep 'schedule:' .github/workflows/live-smoke.yml`
shows the cron; the GitHub Actions UI lists the schedule after the commit lands
on the default branch.


## Concrete Steps

Packaged operator commands may run from any directory and resolve the active
context's release workspace. Contributor build and source-edit commands run
from the repository root. Cloud-side steps (M1/M2 install and validation)
assume `KUBECONFIG` points at `nagare-01` and the active context is a cloud
context (see `docs/runbooks/cluster-access.md`); M3's packaged local smoke needs
Docker plus the installed release, while its contributor equivalent uses the
dev shell.

**M1.1 — Pushover credentials (manual, once).** Create an account at
pushover.net, install the phone app, note the **user key** (dashboard). Create
an Application (name it `nagare`) and note its **API token**. These two strings
go only into the sops-encrypted Secret, never anywhere plaintext in Git.

**M1.2 — the Secret.**

```bash
# Write the plaintext (template in Plan of Work M1 item 1), then encrypt in place
# using the operator-owned .sops.yaml beside this directory:
context="$(nagarectl context current)"
secret_dir="${NAGARE_CLUSTER_SECRETS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/${context}}"
mkdir -p "$secret_dir"
# First create "$secret_dir/.sops.yaml" with an operator-owned age recipient
# and a rule matching *.yaml that encrypts ^(data|stringData)$.
$EDITOR "$secret_dir/alertmanager-config.yaml"
(cd "$secret_dir" && sops -e -i alertmanager-config.yaml)
# Sanity: values encrypted, keys readable, round-trip works:
grep -c 'ENC\[AES256_GCM' "$secret_dir/alertmanager-config.yaml"   # >= 1
sops -d "$secret_dir/alertmanager-config.yaml" | head -8
```

Expected decrypt output (head):

```text
apiVersion: v1
kind: Secret
metadata:
    name: nagare-alertmanager-config
    namespace: monitoring
type: Opaque
stringData:
    alertmanager.yaml: |
```

**M1.3 — values edit + packaged installer verification.** Apply the values
change specified in Plan of Work. The context-secret resolver and installer
wiring were implemented on 2026-08-26; verify they remain present, then verify
the chart rendering with the `helm template … | grep -B2 -A12 'kind:
VMAlertmanager'` command shown there. Build/check the package so the immutable
payload is also proven to exclude `cluster/secrets`.

**M1.4 — install and observe.**

```bash
nagare observability
kubectl get pods -n monitoring
```

Expected (names vary with the chart's release-name templating; the two new
pods are the point):

```text
NAME                                                        READY   STATUS    RESTARTS
vmalert-vmks-victoria-metrics-k8s-stack-...                 2/2     Running   0
vmalertmanager-vmks-victoria-metrics-k8s-stack-0            2/2     Running   0
vmsingle-vmks-victoria-metrics-k8s-stack-...                1/1     Running   0
vmagent-vmks-victoria-metrics-k8s-stack-...                 2/2     Running   0
...
```

**M1.5 — end-to-end synthetic alert.** Inject an alert directly into
Alertmanager's v2 API (no amtool required in the dev shell):

```bash
kubectl get svc -n monitoring | grep alertmanager   # find the service name
kubectl -n monitoring port-forward svc/<alertmanager-service-name> 9093:9093 &
curl -sS -XPOST http://127.0.0.1:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"NagareTestAlert","severity":"warning"},
        "annotations":{"summary":"EP-101 M1 pipeline test — ignore"}}]'
kill %1
```

Expected: HTTP 200 (empty body) from the curl, and within ~30–60 seconds (the
`group_wait`) a Pushover notification on the phone titled with
`NagareTestAlert`. If no push arrives, check Alertmanager's logs:
`kubectl -n monitoring logs vmalertmanager-...-0 -c alertmanager | tail`.

Commit M1:

```text
feat(observability): enable vmalert and alertmanager with a pushover channel

MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/101-alerting-and-backup-freshness-monitoring.md
Intention: intention_01kzakvy1qeasagg3rpbn44749
```

**M2.1 — metric-name verification** per Plan of Work 2a (port-forward VMSingle,
run the six vmui queries). Record any deviation in Surprises & Discoveries and
adjust the rule expressions before committing them.

**M2.2 — scrape + rules.** Create the two YAML files from Plan of Work 2b/2c,
add the two `kubectl apply` lines to `install.sh`, then:

```bash
nagare observability
kubectl get vmrule,vmservicescrape -n monitoring
```

Expected to include:

```text
vmrule.operator.victoriametrics.com/nagare-alerts
vmservicescrape.operator.victoriametrics.com/cert-manager
vmservicescrape.operator.victoriametrics.com/nagare-brokers
```

Check vmalert accepted the rules (port-forward the vmalert service, open
`http://127.0.0.1:8080/vmalert/groups` — all six rules listed, none in an
error state; or grep the vmalert container logs for `error`).

**M2.3 — the probe fix.** Apply the Haskell edits from Plan of Work 2d, then:

```bash
cd cli/nagarectl
cabal build exe:nagarectl
cabal test
```

Expected: build clean; the test summary includes the two new `backupPrefixes`
cases and ends with all tests passing (the suite prints a tasty summary; any
failure names the case).

Run the packaged report against the live cluster (cloud context, VM running):

```bash
cd /tmp
nagarectl server status
```

Expected excerpt (one line per managed database that exists, e.g. `notes`; ages
under 24h show OK because the CronJob runs daily at 03:17 UTC):

```text
backup databases/notes   OK    newest object 6h ago
backup litestream        WARN  no objects (empty prefix)
backup volumes           OK    newest object 3d ago
```

(The exact set of lines depends on what exists in the bucket; the acceptance
point is the presence of `backup databases/<name>` lines and the absence of any
`backup postgres` line.)

Update `docs/runbooks/disaster-recovery.md` line ~45 as described. Commit M2
(split into two commits if preferred — `feat(observability): add curated alert
rules and cert-manager scrape` and `fix(nagarectl): probe databases/<name>
backup prefixes in server status` — both with the plan trailers).

**M3.1 — local smoke.** Apply the script edits from Plan of Work 3a, then:

```bash
nagare local-smoke
```

From a contributor checkout, run `just local-smoke` as a compatibility check.

Expected transcript excerpts (in order, among the existing steps):

```text
== step 5: managed-DB create -> backup -> restore -> assert row count ==
Created database smokedb (postgres) at smokedb.personal.svc.cluster.local
== step 5b: back up to MinIO ==
Backup written: s3://nagare-backups/databases/smokedb/20260715T....sql.gz
== step 5c: clobber the live table, restore into the scratch target ==
Restored smokedb into a scratch target from s3://nagare-backups/databases/smokedb/... — compare, then promote manually.
== step 5d: assert the sentinel row survived the round-trip ==
  DB RESTORE OK: smoke_sentinel has 1 row in ..._restore_scratch
== step 4: verify HTTP 200 ==   (earlier)
local smoke: OK
```

**M3.2 — workflow cron.** Apply the trigger-block edit from Plan of Work 3b.
Validate the YAML parses (`yq . .github/workflows/live-smoke.yml >/dev/null` or
push and watch the Actions tab list the schedule). Commit M3:

```text
test(smoke): add managed-DB backup/restore round-trip and monthly live-smoke cron

MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/101-alerting-and-backup-freshness-monitoring.md
Intention: intention_01kzakvy1qeasagg3rpbn44749
```


## Validation and Acceptance

The plan is done when all of the following observable behaviors hold:

1. **Alert pipeline fires end-to-end.** Either the M1.5 synthetic-alert curl,
   or a real threshold test: temporarily edit the `DiskUsageHigh` expression in
   `cluster/observability/vmrules/nagare-alerts.yaml` from `> 80` to `> 1` and
   `for: 15m` to `for: 1m`, `kubectl apply -f` it, and within ~2 minutes a
   Pushover notification arrives reading `Disk /… is NN% full`; then revert the
   file, re-apply, and (because `send_resolved: true`) a "resolved"
   notification follows. Both the synthetic and threshold paths must have been
   exercised at least once.

2. **`nagarectl server status` reports true backup freshness.** Against the
   live cloud cluster with at least one managed database and its
   `nagare-dbbackup-<name>` CronJob having run within 24h, the report contains
   `backup databases/<name>  OK  newest object <N>h ago`, contains `backup
   litestream` and `backup volumes` lines, and contains **no** `backup
   postgres` line. `cd cli/nagarectl && cabal test` passes, including the two
   new `backupPrefixes` cases.

3. **Local smoke proves restorability.** `nagare local-smoke` exits 0 from
   outside a checkout and its
   transcript contains `DB RESTORE OK: smoke_sentinel has 1 row` followed by
   `local smoke: OK`. Run it twice in a row: the second run must also pass
   (idempotence — the fixed `smokedb` name is recreated cleanly after the
   previous teardown). `just local-smoke` also passes in a contributor checkout.

4. **The cloud drill is scheduled.** `.github/workflows/live-smoke.yml`
   contains both `workflow_dispatch:` and a `schedule:` cron, and the GitHub
   Actions UI shows the workflow as scheduled once the change is on the default
   branch.

5. **Credentials stay outside the release.** The context-owned
   `alertmanager-config.yaml` contains only `ENC[AES256_GCM,…]` values and
   `sops -d` round-trips. The `nagare-platform` payload and a newly materialized
   context workspace contain no `cluster/secrets`, while both contain
   `cluster/examples/uploads-volume/nagare/Config.hs` for packaged local smoke.


## Idempotence and Recovery

Everything in this plan is safe to repeat. `cluster/observability/install.sh`
is `helm upgrade --install` plus `kubectl apply` throughout — including the new
Secret and manifest applies — so re-running it converges with no drift.
`sops -e -i` must be run only once per plaintext write (running it on an
already-encrypted file double-encrypts; if that happens, restore the
operator-owned ciphertext from its private configuration backup and redo). If
the Alertmanager pod ever starts before the Secret exists (e.g. someone helm-runs
outside `install.sh`), it crash-loops or runs with a null config; fix by
applying the Secret and deleting the pod — the operator recreates it.

The `nagarectl` change is additive pure logic plus a rewired call site; revert
its commit if the build breaks after integration.
`server status` degrades exactly as before when tools are missing: an
unreachable cluster makes `listDatabases` return `Right []`, which produces the
bare `databases` fallback line rather than an error.

The local-smoke additions are covered by the existing `cleanup()` EXIT trap
(extended in M3), so an aborted run leaves at most: the `smokedb`
StatefulSet/PVC (removed by the trap on the next run's create-or-cleanup, or
manually with `nagarectl db delete smokedb -n personal --yes` plus `kubectl -n
personal delete pvc nagare-db-smokedb-data`) and a MinIO object (wiped by
`nagare local-down` in any case). Reverting the workflow cron is deleting two
lines.

Rolling back the whole milestone M1 is `git revert` of its commit plus `nagare
observability` (helm returns `alertmanager`/`vmalert` to disabled and the
operator garbage-collects their pods); the Secret may remain in the cluster
harmlessly or be deleted with `kubectl -n monitoring delete secret
nagare-alertmanager-config`.


## Interfaces and Dependencies

**External services.** Pushover (pushover.net): one user key + one application
token, stored only in the active context's operator-owned
`cluster-secrets/<context>/alertmanager-config.yaml` (sops/age encrypted). No
new in-cluster components beyond what the already-pinned
`vm/victoria-metrics-k8s-stack` 0.81.0 chart provides (vmalert, Alertmanager —
both reconciled by the victoria-metrics-operator the stack already runs).

**Kubernetes objects introduced.**
- Secret `monitoring/nagare-alertmanager-config`, key `alertmanager.yaml`
  (source: context-owned `alertmanager-config.yaml`).
- `VMRule monitoring/nagare-alerts`
  (source: `cluster/observability/vmrules/nagare-alerts.yaml`), six alert rules:
  `DiskUsageHigh`, `NodeNotReady`, `PodCrashLooping`, `BackupJobFailed` +
  `BackupStale`, `CertificateExpiringSoon`.
- `VMServiceScrape monitoring/cert-manager`
  (source: `cluster/observability/cert-manager/vmservicescrape.yaml`).

**Haskell surface (end of M2).** In `Nagare.Ops.Probe`
(`cli/nagarectl/src/Nagare/Ops/Probe.hs`), exported:

```haskell
backupPrefixes :: [Text] -> [Text]
```

In `Nagare.Ops.Status` (`cli/nagarectl/src/Nagare/Ops/Status.hs`),
`gatherInventory :: TargetProfile -> InventoryOpts -> IO [Probe]` keeps its
signature; it newly imports `Nagare.Database.Discover (DbRow (..),
listDatabases)` and consumes `backupPrefixes`. No other module signatures
change. Tests: `cli/nagarectl/test/Spec.hs` (tasty/HUnit), run with `cabal
test` from `cli/nagarectl`.

**Scripts/CI.** `scripts/lib/cluster-secrets.sh` resolves operator-owned
encrypted cluster Secrets; `cluster/observability/install.sh` requires and
applies them before Helm and applies two observability manifests afterward.
`scripts/local-smoke.sh` gains step 5 and teardown lines, resolves the packaged
`nagarectl` from `PATH`, and keeps a checkout-only Cabal fallback. The workspace
asset set includes `cluster/examples`; Nix release checks assert examples are
present and `cluster/secrets` is absent.
`.github/workflows/live-smoke.yml` gains a monthly `schedule:` trigger.

**Plan interactions.** Soft-depends on
`docs/plans/100-bound-and-harden-cluster-workloads.md` (shares
`cluster/observability/victoria-metrics/values.yaml`; 100 owns the `grafana:`
block and its work has landed; keep the alert-channel secret context-owned and
leave `grafana:` alone). Disjoint from
`docs/plans/102-nagarectl-correctness-and-robustness-fixes.md` (different
modules: 102 owns `Deploy.hs` and `Database/Create.hs`; this plan owns
`Ops/Status.hs`). Appends-only to `scripts/local-smoke.sh`, whose structural
hardening `docs/plans/97-…` owns.

The immutable payload/context workspace constraints come from
`docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md`,
ExecPlan 106, and ADR 4. They are integration dependencies, not ownership
transfers: this plan owns only the observability/local-smoke reconciliation
needed for its acceptance commands.

---

Revision note (2026-07-15): initial authoring — replaced the generated skeleton
with the full plan. Research basis: read
`cluster/observability/victoria-metrics/values.yaml` (alerting disabled at
lines 66–70), `cluster/observability/install.sh` (chart 0.81.0, release
`vmks`), `cli/nagarectl/src/Nagare/Ops/Status.hs` (legacy `postgres` probe at
lines 72–74), `Nagare/Ops/Probe.hs` (`parseNewestBackupAge`, `gradeAge`),
`Nagare/Database/{Backup,Restore,Discover,Create,Delete}.hs` (CronJob
`nagare-dbbackup-<name>` at `17 3 * * *`; `databases/<name>/` layout; scratch
restore target; `nagare-db-<name>` Secret/PVC naming), `.sops.yaml` +
`cluster/secrets/notes-db-url.yaml` (secret pattern),
`scripts/local-smoke.sh` + `scripts/live-smoke.sh` + `justfile`,
`.github/workflows/live-smoke.yml` (dispatch-only), and
`docs/user/backups-and-disaster-recovery.md` + `docs/runbooks/disaster-recovery.md`.

Revision note (2026-08-24): implemented M2 while preserving M1's operator-only
Pushover gate; corrected the cert-manager v1.20.2 port, current chart key and
notifier requirement, backup retry false-positive, and never-succeeded CronJob
case. Reason: exact pinned dependency verification exposed material drift from
the authored assumptions.

Revision note (2026-08-24): implemented M3's managed-database restore smoke step
and monthly workflow, using the real managed password contract and an explicit
CI authentication failure. Reason: repository work could proceed while Docker
and cloud credentials remained unavailable.

Revision note (2026-08-26): reconciled M1 and M3 with the packaged operator
model introduced by MasterPlan 20/ExecPlan 106. Cluster credentials now live in
context-owned configuration, the installer resolves them fail-closed, the
immutable payload excludes them, and packaged local smoke receives its example
asset and release-matched CLI. Reason: the prior plan still assumed checkout-only
paths and therefore described commands that could not work from an installed
release.

Revision note (2026-08-26): completed packaged M3 validation and fixed the three
runtime failures it exposed: stale inherited context resolution, PostgreSQL
readiness/socket assumptions, and leaked managed-backup CronJobs. Reason: only an
actual clone-free Docker run exercised the full package, target guardrail, database,
backup, restore, and teardown sequence together.
