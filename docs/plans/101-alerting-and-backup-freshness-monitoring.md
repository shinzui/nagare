---
id: 101
slug: alerting-and-backup-freshness-monitoring
title: "Alerting and backup freshness monitoring"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T21:36:18Z
      mode: "implement"
      note: "Record labs rule health, metric series, empty backup prefixes, and Pushover dependency"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T21:10:30Z
      mode: "implement"
      note: "Reconcile system auth databases with the still-open application backup-age gate"
---

# Alerting and backup freshness monitoring

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [101-alerting-and-backup-freshness-monitoring.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/101-alerting-and-backup-freshness-monitoring.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] M1/M2 live read-only audit (2026-09-16): guarded labs identity passed;
      context-owned `alertmanager-config.yaml` is absent, live Alertmanager is
      disabled, and vmalert intentionally retains its blackhole notifier. No
      notification configuration or cluster resource was changed.
- [x] M2: Enable vmalert with trimmed resources and an explicit blackhole
      notifier while M1's operator-owned Pushover credential is unavailable;
      disable the chart's bundled rules with the current `defaultRules.enabled`
      key. Exact chart 0.81.0 render passed. (2026-08-24)
- [x] M2: Verify metric names against the live cluster (2026-09-16): both `/`
      and `/var/lib/nagare` filesystem series exist; CronJob success, Job failure,
      node readiness, pod restart, and certificate-expiry families all return
      live series through VMSingle's authenticated Service proxy.
- [x] M2: Add `cluster/observability/cert-manager/vmservicescrape.yaml` using
      the selector and port verified against upstream cert-manager v1.20.2.
      (2026-08-24)
- [x] M2: Add `cluster/observability/vmrules/nagare-alerts.yaml` with seven rules
      covering five failure modes; wire both manifests into `install.sh`;
      `promtool` reports the original six rules valid; the later
      `DiskUsageCritical` rule follows the same validated expression. (2026-08-24,
      reconciled 2026-09-16)
- [x] M2: Add pure `backupPrefixes` to `cli/nagarectl/src/Nagare/Ops/Probe.hs`,
      rewire `gatherInventory` in `cli/nagarectl/src/Nagare/Ops/Status.hs` to
      enumerate managed databases and probe `databases/<name>` prefixes; drop
      the legacy `postgres` probe. (2026-08-24)
- [x] M2: Add unit tests for `backupPrefixes` to `cli/nagarectl/test/Spec.hs`;
      all 394 current tests pass in the packaged Nix check. (2026-08-26)
- [x] M2: Update `docs/runbooks/disaster-recovery.md` so the restore map has
      only the managed `databases/<name>/` layout. (2026-08-24)
- [ ] M2: `nagarectl server status` against the live cluster shows
      `backup databases/<name>` lines with fresh ages. A guarded 2026-09-17 read
      found no managed database in the `personal` namespace, so the command still
      emits the truthful `backup databases` fallback and no legacy `postgres` line.
      EP-4 created `en-db` and `shomei-db` in `nagare-system`, but the status probe
      intentionally enumerates application databases in `personal`; those system
      databases do not satisfy this acceptance gate. A fresh-age proof still needs
      an approved live application database plus backup.
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

- The guarded labs audit on 2026-09-16 found seven live rules, not the six this
  plan originally installed. `DiskUsageCritical` was added later by the optional
  in-cluster cache work so disk pressure has warning and critical thresholds.
  The live `nagare-alerts` VMRule is operational; vmalert's API reports all seven
  rules `health: ok`, inactive, and without evaluation errors. Both required
  filesystem mountpoints and every other metric family named by the rules return
  live series.
- Labs has no `nagarectl`-managed StatefulSet in `personal`. A guarded 2026-09-17
  follow-up found the EP-4 auth databases and their not-yet-run backup CronJobs in
  `nagare-system`, plus a successful `nix-cache-db` backup object. The packaged
  `nagarectl server status` intentionally enumerates application databases in
  `personal`, so it correctly retains the `backup databases` fallback and no
  legacy `backup postgres` line. Fresh-age acceptance still requires creating and
  backing up a live application database, which is a separately approved mutation.
- The labs context-owned secret directory has no `alertmanager-config.yaml`.
  Live Helm values therefore correctly keep Alertmanager disabled and vmalert in
  explicit blackhole mode. M1 still requires operator-owned Pushover account/token
  material and phone observation; neither can be inferred from healthy rule evaluation.
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

- Decision: retain the later `DiskUsageCritical` rule as the seventh member of
  EP-5's curated set and reconcile this plan to the live/current manifest.
  Rationale: it is a second severity threshold for the existing disk failure mode,
  not a new noisy multi-node rule family. The live rule API proves it evaluates
  cleanly alongside the original six, so deleting it merely to preserve the
  authored count would regress the operator's escalation signal.
  Date: 2026-09-16.

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
the cert-manager scrape matches the pinned upstream Service, the original six
PromQL rules pass `promtool`, the later seventh disk-critical rule shares the
validated expression, and all 394 current nagarectl tests pass. The 2026-09-16
guarded labs audit closes live series discovery and rule evaluation: all required
families exist and all seven rules report healthy. The status transcript proves
the correct `databases` fallback and no legacy `postgres` line. Labs now has
system-namespace auth databases, but no application database in `personal`, so a
fresh `databases/<name>` age remains open.
M1 remains operator-gated on an absent Pushover ciphertext and phone delivery.
M3's restore round-trip and monthly workflow are implemented. The packaged local
create→backup→restore assertion passes repeatedly, including teardown and an explicit
post-run check that the database's deterministic backup CronJob is gone;
the scheduled cloud workflow intentionally stops at its explicit authentication
TODO rather than proceeding unauthenticated.
Packaging reconciliation now makes both remaining workflows runnable from a released
operator package without a checkout and keeps encrypted credentials outside immutable
payloads. Live Pushover and cluster metrics/status evidence remain open.

