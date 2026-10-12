---
id: 49
slug: scheduled-task-substrate-spike-and-one-off-run-feasibility
title: "Scheduled-task substrate spike and one-off-run feasibility"
kind: exec-plan
created_at: 2026-06-10T16:50:01Z
intention: "intention_01kts6qyg4ezsbj500ksjr90r1"
master_plan: "docs/masterplans/10-scheduled-tasks-for-nagare.md"
---

# Scheduled-task substrate spike and one-off-run feasibility

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today Nagare can deploy long-running web apps (Knative Services), static sites, and managed
databases (Postgres/Redis/ClickHouse StatefulSets), but it has no way to run a unit of work
*on a schedule* (a nightly cleanup, an hourly sync) or *once, on demand* (a one-off
migration). The parent initiative, MasterPlan 10
(`docs/masterplans/10-scheduled-tasks-for-nagare.md`), closes that gap by adding a typed
**`Task`** to the DSL and a `nagarectl task list/run/logs/delete` command group that render
and operate a Kubernetes **CronJob** per task. A "CronJob" is the standard Kubernetes batch
object that, on a cron schedule such as `0 3 * * *`, creates a **Job**, which runs one or
more **Pods** to completion; a "one-off run" is a single Job created immediately from that
CronJob's embedded template, independent of the schedule.

This plan, **EP-49**, is the **feasibility spike** for that initiative. It owns no shipped
code and no Integration Point of its own; instead it *verifies on the live cluster* the
substrate that four later plans will encode, and records the exact verified YAML and command
sequences as a contract. Concretely it de-risks and pins down:

- **IP2 — the rendered CronJob and embedded Job-template shapes.** Prove a `batch/v1`
  CronJob carrying the Nagare label scheme schedules and runs a Job on time, and that the
  batch semantics the renderer will encode (`concurrencyPolicy: Forbid`, `backoffLimit`,
  `restartPolicy: Never`, `successfulJobsHistoryLimit`/`failedJobsHistoryLimit`,
  `activeDeadlineSeconds`, `startingDeadlineSeconds`) behave as documented.
- **IP3 — the task naming and label contract.** Prove the CronJob named
  `nagare-task-<name>` with labels `nagare.dev/managed-by: nagarectl`, `nagare.dev/task:
  <name>`, and optionally `nagare.dev/app: <app>` is discoverable by the exact label
  selector EP-51 will use.
- **IP5 — env/image inheritance.** Prove a task pod inherits an app's runtime environment
  and secrets by adding `envFrom` references to the app's managed `nagare-env-<app>-runtime`
  ConfigMap and `nagare-secret-<app>-runtime` Secret (each `optional: true`), exactly as the
  app's own container does, and prove a task can run *in the app's deployed image*.
- **IP6 — the one-off run and logs/observability contract.** Prove `kubectl create job
  <name> --from=cronjob/nagare-task-<name>` fires a Job immediately, that `kubectl wait
  --for=condition=complete` returns when it finishes, that `kubectl logs -l
  nagare.dev/task=<name>` retrieves its output, and that those same pod logs are scraped by
  the existing VictoriaLogs stack and queryable in Grafana.

What someone "gains" after EP-49 is not a clickable feature — it is **a settled substrate and
a body of verified evidence**. Nothing downstream is allowed to encode a *guess* about what
the cluster accepts. After this spike, the renderer plan
(`docs/plans/50-typed-task-model-and-cronjob-job-renderer.md`, EP-50) can write its CronJob
renderer and golden files against the verified YAML recorded in this plan's "Interfaces and
Dependencies" section; the CLI plan
(`docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md`, EP-51)
can encode the exact one-off-run-and-wait-and-logs command sequence; the app-association plan
(`docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md`, EP-52)
can encode the verified `envFrom` block and image-inheritance approach; and the docs plan
(`docs/plans/53-scheduled-tasks-docs-and-end-to-end-examples.md`, EP-53) can document the
verified Grafana/VictoriaLogs query. You can see the spike "working" by reading the captured
transcripts in Concrete Steps: a CronJob runs on time, a one-off Job completes and its logs
print, and a value defined in an app's runtime env appears inside a task pod's logs.

This plan touches **no Haskell code**. Everything it applies to the cluster lives in a
disposable namespace (`task-spike`) that a single command tears down, plus one throwaway
"app" (a managed ConfigMap + Secret + Knative-style image reference) used only to prove
inheritance. Every manifest is applied with `kubectl apply` (re-runnable) and removed with
`kubectl delete --ignore-not-found`, so the spike is safe to run repeatedly and never
disturbs the real `personal` namespace.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: VM started (already RUNNING); one `Ready` node confirmed (`v1.35.4+k3s1`);
  `task-spike` namespace created (`Active`).
- [x] M1: A hand-applied CronJob `nagare-task-tick` (schedule `* * * * *`) with the Nagare
  label scheme ran a Job on time; `kubectl get cronjob,job,pods` showed a `Complete` Job and
  `Completed` pod within ~60s; the run's pod log line was retrieved by the `nagare.dev/task`
  label selector.
- [x] M2: A one-off Job created via `kubectl create job tick-oneoff-<ts>
  --from=cronjob/nagare-task-tick` reached `condition=complete` under `kubectl wait` and its
  logs were retrieved via both `logs job/<name>` and `logs -l nagare.dev/task=tick`. (This is
  the exact IP6 mechanism.)
- [x] M3: A throwaway "app" world (managed `nagare-env-spikeapp-runtime` ConfigMap +
  `nagare-secret-spikeapp-runtime` Secret) was created; the task CronJob `nagare-task-inherit`
  carrying `envFrom` both resources (each `optional: true`) and running the app's image
  (`busybox:1.37`) echoed `GREETING=hello-from-app`, `APP_SECRET_LEN=15`, and the `1.37`
  banner. With both resources deleted, the pod still completed (empty vars), proving
  `optional: true`.
- [x] M4: Batch semantics verified — `concurrencyPolicy: Forbid` skipped a fire with a
  `JobAlreadyActive` event; `backoffLimit: 2` produced exactly 3 `Error` pods then
  `Failed=BackoffLimitExceeded`; `restartPolicy: Never` replaced pods per attempt;
  `successfulJobsHistoryLimit: 3` retained exactly 3 CronJob-owned `tick` Jobs;
  `activeDeadlineSeconds: 10` killed a 120s task with `DeadlineExceeded` ("should never print"
  absent); `startingDeadlineSeconds` documented (not force-reproduced).
- [x] M5: Task pod logs confirmed in VictoriaLogs; the LogsQL stream query recorded, including
  the discovery that the collector promotes pod labels to queryable
  `kubernetes.pod_labels.nagare.dev/task` stream fields. Verified contracts written into
  "Interfaces and Dependencies"; namespace torn down (`NotFound`); throwaway app resources
  deleted with it.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The collector promotes pod labels to queryable VictoriaLogs stream fields.** EP-5's notes
  said only the `kubernetes.pod_namespace`/`pod_name`/`container_name` fields were verified, and
  this plan anticipated the collector might *not* expose the `nagare.dev/task` pod label. It
  does: every task log line carries `kubernetes.pod_labels.nagare.dev/task`,
  `kubernetes.pod_labels.nagare.dev/managed-by`, and the batch `controller-uid`/`job-name`
  labels as fields. Both of these queries return the same task's lines on the live cluster:

  ```text
  {kubernetes.pod_namespace="task-spike"} kubernetes.pod_labels.nagare.dev/task:="tick"
  {kubernetes.pod_namespace="task-spike"} kubernetes.pod_name:"nagare-task-tick"
  ```

  Impact: EP-51's Grafana hint and EP-53's docs can use the *label-scoped* query
  `{kubernetes.pod_namespace="<ns>"} kubernetes.pod_labels.nagare.dev/task:="<task>"`, which is
  more precise than the `pod_name:"nagare-task-<task>"` word-prefix fallback (the prefix query
  also matches a same-prefixed one-off Job's pods, which is usually desirable but less exact).
  Note the LogsQL exact-match operator is `:=` for a field value; `:"..."` is a phrase filter.

- **Modern Kubernetes (k3s v1.35.4) adds a `FailureTarget` condition before `Failed`.** A
  failing Job's `status.conditions` is `FailureTarget=BackoffLimitExceeded` first, then
  `Failed=BackoffLimitExceeded`; an `activeDeadlineSeconds` kill shows
  `FailureTarget=DeadlineExceeded` then `Failed=DeadlineExceeded`. So
  `status.conditions[0].type` is `FailureTarget`, not `Failed`, in the window right after the
  failure. Impact: EP-51 must not assume `conditions[0].type == "Failed"`; the robust check is
  `kubectl wait --for=condition=failed` / `--for=condition=complete` (which key on the named
  condition, not index 0) — exactly the flow IP6 already prescribes. No change to the contract,
  but EP-51's JSON parsing of conditions should scan for the `Failed`/`Complete` *type*, not
  read index 0.

- **`kubectl get cronjob` now prints a `TIMEZONE` column** (`<none>` when `spec.timeZone` is
  unset). Cosmetic only; the renderer need not set `spec.timeZone`. Recorded so EP-51's
  `task list` column parsing (if it shells `kubectl get cronjob`) accounts for the extra
  column, or better, uses `-o json`/`-o jsonpath` as `Database/Discover.hs` does.

- **The VM was already `RUNNING`** at spike time, so the `gcloud compute instances start` step
  reported nothing to do; the node was `Ready` immediately. No surprise, but it means the
  spike's only `gcloud` interaction was the idempotent describe/start.

- **Manifest delivery through the IAP SSH wrapper.** Passing multi-line YAML containing single
  quotes and `$(...)` through the `iap-ssh.sh ssh nagare-01 -- '<cmd>'` single-quoted argument
  is error-prone. The reliable pattern used throughout this spike was to write the manifest to
  a local temp file, `base64`-encode it (`base64 < f | tr -d '\n'`), and run
  `echo <b64> | base64 -d | sudo k3s kubectl apply -f -` on the VM — the base64 payload has no
  shell-special characters. This is a workstation-side convenience for the spike only; EP-51's
  CLI applies manifests via the `Cradle` wrapper writing to `kubectl apply -f -` stdin, which
  has none of this quoting problem.

## Decision Log

Record every decision made while working on the plan.

- Decision: Run a throwaway, hand-applied spike on the live single-node k3s cluster to prove
  the scheduled-task substrate (CronJob → Job → Pod), the one-off-run mechanism, env/image
  inheritance, batch semantics, and log scraping — *before* EP-50 commits any renderer or
  golden files.
  Rationale: The later plans must encode a *verified* CronJob/Job shape and command sequence,
  not a guess. The parent MasterPlan soft-gates every child plan on this spike's findings.
  This mirrors MasterPlan 9's EP-43 (managed-database substrate spike,
  `docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`),
  which de-risked the StatefulSet substrate the same way. The ExecPlan specification
  explicitly encourages an isolated prototyping spike to de-risk significant unknowns.
  Date: 2026-06-10

- Decision: Structure the hand-applied CronJob/Job to mirror the proven backup machinery in
  `cli/nagarectl/src/Nagare/Database/Backup.hs` (`renderBackupCronJob`, `backupJobSpecValue`),
  not to invent a new shape. Specifically: a `batch/v1` CronJob whose `spec.jobTemplate.spec`
  is the Job body, with `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit`,
  `failedJobsHistoryLimit`, and a pod template with `restartPolicy: Never` and a `backoffLimit`.
  Rationale: The backup CronJob is the repository's existing, working prior art for
  CronJob/Job rendering and is the reference EP-50's renderer follows. Verifying that *this
  same shape* generalizes from a backup to a user task is the spike's central job; reproducing
  its key fields keeps the verified contract aligned with what EP-50 will emit.
  Date: 2026-06-10

- Decision: Prove the one-off run with Kubernetes' native `kubectl create job <name>
  --from=cronjob/nagare-task-<task>`, not a separately authored Job manifest, and confirm it
  with `kubectl wait --for=condition=complete --timeout=...` followed by `kubectl logs -l
  nagare.dev/task=<task>`.
  Rationale: This is the exact mechanism EP-51's `nagarectl task run` (IP6) will shell out to
  via the `Cradle` wrapper, and it guarantees the one-off Job reuses the CronJob's template
  verbatim (the MasterPlan's "two operations over one rendered template" principle). The
  apply→`kubectl wait --for=condition=complete`→logs flow mirrors `waitForJob` in
  `Nagare/Database/Backup.hs`. Proving it on the cluster removes the largest IP6 unknown.
  Date: 2026-06-10

- Decision: Use the disposable namespace `task-spike` for everything the spike applies, and a
  throwaway app identity `spikeapp` (managed ConfigMap + Secret named exactly as the real
  renderer names them: `nagare-env-spikeapp-runtime` / `nagare-secret-spikeapp-runtime`), so a
  single `kubectl delete namespace task-spike --ignore-not-found` removes it all and the real
  `personal` namespace and its apps/databases are never touched.
  Rationale: Mirrors EP-43's `db-spike` namespace pattern; keeps the spike fully reversible
  and idempotent (`kubectl apply` re-applies cleanly; `--ignore-not-found` makes teardown
  safe to repeat). Naming the throwaway app's managed resources exactly as the real renderer
  would name them is what makes the inheritance proof a faithful rehearsal of IP5.
  Date: 2026-06-10

- Decision: Run every cluster operation **on the VM via `sudo k3s kubectl`**, reached through
  the repo's IAP SSH wrapper as the `deploy` user, never against the workstation's default
  kubectl context.
  Rationale: Per the project memory note, IAP forwards only SSH/22 so a workstation kubectl
  cannot reach the k3s API directly, and the workstation's default context points at an
  unrelated GKE cluster you must never touch. Running on the VM is the simplest correct path
  for a hand-applied spike, exactly as EP-43 did.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome: the substrate is fully verified; every later plan can encode a proven shape, not a
guess.** All six milestones (M0–M5) passed on the live `tan-nb-exp` k3s cluster (node
`nagare-01`, `v1.35.4+k3s1`) on 2026-06-10, and the namespace was torn down cleanly
(`get ns task-spike` → `NotFound`). Against the original purpose:

- **IP2 / IP3 (CronJob + labels), proven.** A `batch/v1` CronJob `nagare-task-tick` carrying
  the Nagare label scheme scheduled and ran a `Complete` Job within ~60s; the
  `nagare.dev/managed-by=nagarectl,nagare.dev/task=tick` selector found the CronJob, Job, and
  pod. The backup-CronJob shape (`concurrencyPolicy: Forbid`,
  `successful/failedJobsHistoryLimit`, `startingDeadlineSeconds`, `backoffLimit`,
  `activeDeadlineSeconds`, `restartPolicy: Never`) generalizes verbatim from a DB backup to a
  generic task. EP-50 reproduces it.
- **IP6 (one-off run + wait + logs), proven.** `kubectl create job <gen>
  --from=cronjob/nagare-task-tick` → `kubectl wait --for=condition=complete` → `kubectl logs -l
  nagare.dev/task=tick` worked end-to-end without waiting for the schedule. EP-51 shells this
  exact sequence via `Cradle`.
- **IP5 (env/image inheritance), proven.** A task pod inheriting the app's
  `nagare-env-spikeapp-runtime` ConfigMap and `nagare-secret-spikeapp-runtime` Secret via the
  identical `envFrom` block (each `optional: true`) read back `GREETING=hello-from-app` and a
  non-zero `APP_SECRET_LEN`, and ran in the app's image (`busybox:1.37` banner). With both
  resources deleted, the pod still completed — `optional: true` holds. EP-52 encodes this.
- **Batch semantics (IP2), proven.** Concurrency `Forbid` skip (`JobAlreadyActive`), bounded
  retries (`backoffLimit: 2` → 3 attempts → `Failed=BackoffLimitExceeded`), per-attempt new
  pods (`restartPolicy: Never`), bounded history (3 retained `tick` Jobs), and the
  `activeDeadlineSeconds` kill (`DeadlineExceeded`, "should never print" absent) all behaved as
  documented.
- **Observability (IP6), proven and improved.** Task pod logs reached VictoriaLogs with no new
  wiring, and — beyond the original expectation — the collector promotes the `nagare.dev/task`
  pod label to a queryable `kubernetes.pod_labels.nagare.dev/task` stream field, giving EP-51/53
  a precise label-scoped LogsQL query.

**Gaps / deferred.** `startingDeadlineSeconds` was documented rather than force-reproduced (it
is hard to trigger deterministically on a healthy cluster); EP-50 should keep a generous default
(120s) and EP-53 should warn that an aggressively small value risks missed runs. Two findings
that change *how EP-51 parses status*, not the contract: Job failure now surfaces a
`FailureTarget` condition before `Failed` (so parse by condition *type*, never `conditions[0]`),
and `kubectl get cronjob` prints an extra `TIMEZONE` column (so prefer `-o json`/`-o jsonpath`).
Both are recorded in Surprises. No production code was written or committed by this spike; its
only durable output is this document.

