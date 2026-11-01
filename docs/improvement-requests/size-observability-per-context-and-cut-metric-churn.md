---
type: Improvement Request
title: Let a context size the observability stack, and stop scrape duplication and backup bursts from overrunning VMSingle
description: Give a context a reviewed way to override observability resources such as VMSingle's memory limit, stop scraping k3s's embedded apiserver and etcd metrics twice, and stagger the hourly backup CronJobs, because the work intranet's VMSingle has been OOM-killed every few hours, almost always seconds after a quarter hour, since its 15-minute backups started.
timestamp: "2026-10-31T23:05:36Z"
generated:
  by: process:claude-code
  at: "2026-10-31T23:05:36Z"
requestId: IR-40
status: accepted
origin: mori://tan/tan-ng-labs
acceptanceCriteria:
  - id: AC-1
    statement: An operator can set VMSingle's memory request and limit and its memory.allowedPercent for one context without editing or re-pinning the packaged values.yaml, and the override goes through the same review, digest and apply path as other platform changes.
    verification: Set VMSingle's limit to 1Gi for a local context, run nagarectl platform bootstrap plan, and assert the plan shows only the vmks release changing, with the override's digest recorded in the review; apply it and assert the VMSingle pod runs with a 1Gi limit. A context with no override renders byte-identical to today.
  - id: AC-2
    statement: The override covers at least the resources of every pod the observability releases run (VMSingle, VMAgent, VMAlert, Grafana and its sidecars, kube-state-metrics, node-exporter, VictoriaLogs and its collector, VictoriaTraces, the OpenTelemetry Collector) and the metrics retention period; anything outside the supported set is refused at plan time with a message that names the key.
    verification: Plan one override per supported key and assert each renders; plan an unsupported key (for example a chart image tag) and assert plan refuses it, naming the key.
  - id: AC-3
    statement: On k3s, VMAgent no longer stores the apiserver and etcd metrics twice. The kubelet scrape of /metrics drops the apiserver_*, etcd_* and other control-plane families the apiserver job already collects, and keeps kubelet's own families.
    verification: On a local k3s context, after apply, count({job="kubelet",metrics_path="/metrics",__name__=~"apiserver_.*|etcd_.*"}) returns no data, count by (__name__) ({job="apiserver"}) is unchanged, and kubelet_running_pods and kubelet_volume_stats_used_bytes are still present. The broker dashboard's kubelet_volume_stats panels still render.
  - id: AC-4
    statement: With the hourly recovery-point objective, each scheduled backup CronJob (server backups and app-database backups) keeps a 15-minute cadence but starts at its own minute offset, derived deterministically from the schedule's identity, so the producers on one cluster no longer all start at :00, :15, :30 and :45.
    verification: Declare four scheduled backups on one context and assert their spec.schedule values are four distinct */15 offsets (for example 3-59/15, 7-59/15) that stay the same across re-plans; assert the freshness thresholds (warning 30 min, breach 60 min) still hold.
  - id: AC-5
    statement: The accepted scheduled-backup receipt check accepts a staggered schedule for the hourly objective and still refuses a schedule whose cadence does not meet the objective.
    verification: Unit test BackupReceipt with a staggered hourly schedule (accepted), a */30 schedule under the hourly objective (refused) and a daily schedule (unchanged behaviour). On a cloud context already running unstaggered CronJobs, the upgrade plan shows a schedule-only change and is accepted.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-31T23:05:36Z"
    document_timestamp: "2026-10-31T23:05:36Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against cluster/observability/victoria-metrics/values.yaml,
      pinnedObservabilityInputs in
      cli/nagarectl/src/Nagare/Inventory/Components/Observability.hs,
      recoveryPointSchedule in
      cli/nagarectl/src/Nagare/Inventory/BackupFreshness.hs and its users in
      Database/Backup.hs and Inventory/BackupReceipt.hs (master 6ae3320e), and
      live reads of VMSingle, VMAgent and the CronJobs on the tan-ng-labs
      intranet running Nagare v0.14.1 on 2026-10-31. No independent
      verification is claimed.
---

# Let a context size the observability stack, and stop scrape duplication and backup bursts from overrunning VMSingle

**Authored by:** a `claude-code` session operating the `tan-ng-labs` intranet
(`mori://tan/tan-ng-labs`), running Nagare v0.14.1.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-31.


## Why

The work intranet (context `intranet`, one n2-standard-4 node with about 16 GB, 37% used)
loses its metrics store several times a day. On 2026-10-31 the VMSingle pod
`vmsingle-vmks-victoria-metrics-k8s-stack` had restarted 29 times in 19 days, every time
`OOMKilled` at its 512Mi limit (`memory.allowedPercent=40`, set by
`cluster/observability/victoria-metrics/values.yaml`). Its working set peaked at 470–504Mi in
every 6-hour window over the previous two days, so it runs with almost no headroom.

The restarts follow the backup CronJobs:

- **Timing.** Before 2026-10-19 VMSingle restarted twice in eight days. Since then it has
  restarted about every 12 hours. That is when the shared database servers and their
  scheduled backups arrived (the CronJobs are 12 days old). Of the 27 restarts since then,
  21 began 7–26 seconds after a quarter hour.
- **Cause.** The `hourly` recovery-point objective runs every producer at `*/15 * * * *`
  (`recoveryPointSchedule`). On the intranet four producers are active and all fire at the
  same instant: `nagare-dbbackup-labs-postgres`, `nagare-dbbackup-labs-clickhouse`,
  `nagare-appdb-kansoku-pg` and `nagare-appdb-kansoku-ch`. Each new pod creates about 280
  new series (cAdvisor and kube-state-metrics), and VMSingle has to index all of them at once.
  The namespace saw 1,048 distinct pods in 24 hours, with 4 running. cAdvisor had 6.3k active
  series but touched 102k that day. Overall about 6,700 new series per hour, 138k active and
  312k touched per day.
- **Duplication.** On k3s the kubelet's `/metrics` endpoint is served by the same process as
  the apiserver, so the chart's kubelet `VMNodeScrape` stores the apiserver and etcd families
  a second time. On the intranet the kubelet job held 44.6k `apiserver_*|etcd_*` series and
  the apiserver job 45.2k. That is about a third of all active series and a large share of
  VMSingle's index and cache work.

The operator cannot fix any of this from the context's configuration repository:

- The observability values are packaged inputs, pinned by digest in
  `pinnedObservabilityInputs`. There is no per-context overlay, and a `kubectl` patch to the
  `VMSingle` object is drift that the next `platform bootstrap` apply reverts. Raising the
  limit to 1Gi on a 16 GB node is the obvious fix, but it needs a Nagare release, and every
  other context then gets the same value whether it has a 4 GB or a 16 GB node.
- The cadence is one hard-coded string per objective. The only operator choice is `daily`,
  which lowers the recovery point from an hour to a day just to spread pod starts.


## Requested change

1. **Per-context observability overrides.** A reviewed, operator-owned way to override a
   documented set of observability values for one context: at least every pod's resources,
   VMSingle's `memory.allowedPercent` and the retention periods. For example, an overlay file
   in the context's configuration store that is merged after the packaged `values.yaml`, with
   its digest recorded alongside the packaged values' digest. The default stays the packaged
   file. The post-renderer digest check, the review and the inventory keep working, and
   unsupported keys are refused instead of passed through. The shape is Nagare's call. A typed
   field in the context or in an inventory declaration would work as well as a values overlay.
2. **No duplicate control-plane metrics on k3s.** Add `metricRelabelConfigs` to the kubelet
   `/metrics` scrape that drop the families the apiserver job already collects (`apiserver_*`,
   `etcd_*`, and the other embedded control-plane families such as `workqueue_*` and
   `rest_client_*` where they are duplicates), or keep only kubelet's own families. Keep
   `kubelet_volume_stats_*`, which the broker dashboard uses.
3. **Staggered hourly backups.** Keep the 15-minute cadence and the hourly objective, but give
   each CronJob a deterministic minute offset within the quarter hour, for example a hash of
   its schedule name, giving `M-59/15`. Update the receipt check in `BackupReceipt.hs`,
   which today accepts the hourly objective without comparing `spec.schedule`, so that it
   validates a staggered cadence instead of any schedule at all.

The intranet's operators want 1Gi for VMSingle. Whether 512Mi stays the packaged default for
smaller nodes is Nagare's call. Requests 2 and 3 reduce the load on every context.

Out of scope: alerting on VMSingle restarts (the intranet's Alertmanager is still
operator-gated, EP-101), and moving to a clustered VictoriaMetrics.


## Consumer

When this ships, the tan-ng-labs intranet will set VMSingle's limit to 1Gi in its context
overlay, upgrade, and check that VMSingle goes a week without an OOM kill, that the kubelet
job drops by about 44k series, and that its four backup CronJobs start at distinct minutes.
