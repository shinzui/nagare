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


## Context and Orientation

Read this section fully before running anything. It assumes you know nothing about this
repository.

**The cluster and how you reach it.** Nagare is a single-node personal PaaS running on one
Google Cloud Compute Engine virtual machine named **`nagare-01`** (an `e2-standard-2`: 2
vCPU, ≈8 GB RAM), in GCP project **`tan-nb-exp`**, region **`us-west1`**, zone
**`us-west1-a`**. The VM runs NixOS, and on top of NixOS runs **k3s**, a lightweight
single-binary Kubernetes distribution. "The cluster" means this one-node k3s. The repository
root `CLAUDE.md` mandates a hard rule: **every `gcloud` operation in this repo targets
project `tan-nb-exp` only** — never any other project, not even for read-only listing.
Scripts include a preflight assertion that refuses to run if the active gcloud project is not
`tan-nb-exp`, and every `gcloud` call passes `--project=tan-nb-exp` explicitly. The only
`gcloud` call this spike makes is the VM start; it pins the project explicitly.

**Critical access reality (do not skip).** Two facts from the project memory note govern how
you reach the cluster. First, the VM is **often `TERMINATED`** to save cost — you must
**start it first** and wait ~1–2 minutes for sshd and k3s. Second, a workstation `kubectl`
cannot reach the k3s API directly: IAP (Google's Identity-Aware Proxy, the tunnel this repo
uses to reach the VM) forwards only SSH on port 22, so opening an IAP tunnel to the k3s API
port 6443 is refused, and the workstation's default kubectl context points at an *unrelated*
GKE cluster you must **never** touch. The correct path, used throughout this plan, is to run
cluster operations **on the VM itself as `sudo k3s kubectl ...`**, reached with the repo's
IAP SSH wrapper as the `deploy` user with the `~/.ssh/id_ed25519` key:

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- '<command>'
```

The wrapper (`scripts/iap-ssh.sh`) opens an IAP tunnel, routes OpenSSH through `socat`, and
runs `<command>` under a shell on the VM. It refuses to run unless the active gcloud project
is `tan-nb-exp`. Read its header for the full surface. Because every manifest here is applied
via `kubectl exec`/`kubectl apply` *inside* the cluster, no client tools need installing
anywhere.

**The CronJob/Job substrate, and the prior art that proves it works.** A Kubernetes
**CronJob** (API group `batch/v1`, kind `CronJob`) is a controller that, on a cron schedule,
stamps out a **Job** from an embedded template (`spec.jobTemplate`). A **Job** (`batch/v1`,
kind `Job`) runs one or more **Pods** until they exit successfully, then reports
`status.conditions[].type == "Complete"`. Nagare already renders both today: the
managed-database backup feature, `cli/nagarectl/src/Nagare/Database/Backup.hs`, renders a
`batch/v1` CronJob for scheduled backups (`renderBackupCronJob`, lines ~283–298) wrapping a
shared Job body (`backupJobSpecValue`, lines ~131–151), and a one-shot `batch/v1` Job for
on-demand backups (`renderBackupJob`). The shared Job body uses `backoffLimit: 0`,
`restartPolicy: Never`, and labels `nagare.dev/managed-by: nagarectl` plus
`nagare.dev/database: <name>` (`labelsValue`, lines ~161–166). The CronJob adds
`concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 1`,
and `jobTemplate.spec` set to the same body. The backup command driver waits for a Job with
`kubectl wait --for=condition=complete --timeout=600s job/<name> -n <ns>` (`waitForJob`,
lines ~392–404). **This spike's central job is to confirm that this exact shape generalizes
from a backup to a generic user task** — same label scheme, same CronJob/Job structure, same
wait flow — and to record any field that differs.

**The label/discovery pattern, from the database CLI.** `nagarectl db` finds managed
databases by a label selector, not by re-deriving names:
`cli/nagarectl/src/Nagare/Database/Discover.hs` defines `dbLabelSelector =
"nagare.dev/managed-by=nagarectl,nagare.dev/database"` (line 50) and runs `kubectl get
statefulset -n <ns> -l <selector> -o json` (`listDatabases`, lines ~121–139), parsing the
JSON defensively. EP-51's `nagarectl task list/run/logs/delete` will discover task CronJobs
the same way, by the selector `nagare.dev/managed-by=nagarectl,nagare.dev/task` (optionally
`,nagare.dev/app=<app>`). This spike proves that selector finds the hand-applied CronJob and
its Job pods.

**The env-inheritance pattern, from the app renderer.** When Nagare renders an app's Knative
Service, the app's container always gets an `envFrom:` block referencing two managed
resources, so the running container inherits the app's stored runtime environment and
secrets. The helper is `envFromField` in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` (lines
~368–375):

```haskell
envFromField :: Text -> [Pair]
envFromField app =
  [ "envFrom"
      .= toJSON
        [ object ["configMapRef" .= object ["name" .= managedConfigMapName app Runtime, "optional" .= True]]
        , object ["secretRef" .= object ["name" .= managedSecretName app Runtime, "optional" .= True]]
        ]
  ]
```

The two resource names come from `managedConfigMapName app Runtime == "nagare-env-<app>-runtime"`
and `managedSecretName app Runtime == "nagare-secret-<app>-runtime"` (lines ~82–88). `optional:
true` means an app whose store was never written still deploys. **This spike proves a *task*
pod can inherit the very same `nagare-env-<app>-runtime` ConfigMap and
`nagare-secret-<app>-runtime` Secret by adding the identical `envFrom` block** — which is the
IP5 contract EP-52 will encode. To prove it without touching a real app, the spike
hand-creates a throwaway app world (`spikeapp`) whose managed ConfigMap and Secret are named
exactly as the renderer would name them.

**The observability stack, reused, not built.** The cluster already runs the Victoria stack
(EP-5, `docs/plans/5-victoria-observability-stack-and-grafana.md`). VictoriaLogs lives in the
`logging` namespace, and a collector DaemonSet tails every container log file under
`/var/log/containers` and ships the lines to VictoriaLogs at
`http://victoria-logs-victoria-logs-single-server.logging.svc:9428`
(`cluster/observability/victoria-logs/collector-values.yaml`). EP-5 verified that the log
**stream fields are `kubernetes.pod_namespace`, `kubernetes.pod_name`, and
`kubernetes.container_name`** (not the bare `namespace`/`pod`/`container` names) — so the
LogsQL selector that finds a namespace's logs is `{kubernetes.pod_namespace="<ns>"}`. Task
pods are ordinary pods, so they are scraped automatically with no new wiring. This spike's
last job is to *confirm* a task's pod logs appear in VictoriaLogs and to record the exact
query, so EP-51's `task logs` Grafana hint and EP-53's docs walkthrough can reference it. It
builds no new observability.

**The terms used in this plan, in plain language.** A *CronJob* is a scheduled Job factory; a
*Job* runs pods to completion; a *one-off run* is a Job created immediately from a CronJob's
template, bypassing the schedule; `envFrom` is the Kubernetes container field that imports
all keys of a ConfigMap or Secret as environment variables; a *label selector* is a
comma-separated `key=value` filter Kubernetes uses to find objects; *LogsQL* is VictoriaLogs'
query language; a *throwaway app world* is a hand-created managed ConfigMap + Secret named as
the real renderer would name them, standing in for a deployed app.


## Plan of Work

The work is six milestones. M0 prepares the cluster and the disposable namespace. M1 proves
the *scheduled* path: a CronJob with the Nagare labels runs a Job on time. M2 proves the
*one-off* path (IP6): `kubectl create job --from=cronjob/...` + `kubectl wait` + `kubectl
logs`. M3 proves *inheritance* (IP5): a task pod inherits a throwaway app's runtime env and
secret via `envFrom`, and runs in the app's image. M4 proves the *batch semantics* (IP2) the
renderer encodes — concurrency, retries, history limits, and the execution-timeout kill. M5
confirms logs reach VictoriaLogs/Grafana, records every verified contract into "Interfaces
and Dependencies", and tears everything down. Each milestone is independently verifiable: at
its end you can run the listed commands and observe the listed output. Everything M1–M5
applies lives in `task-spike` (plus the throwaway `spikeapp` resources, also in `task-spike`)
and is throwaway evidence; the only durable output is what gets written into *this* plan.

A note on the **image** used during the spike. To keep every milestone self-contained and
free of image-pull surprises, M1/M2/M4 use the tiny `busybox:1.36` image with a `sh -c`
command that prints, sleeps, or exits as needed. M3 additionally uses one *other* image
(`busybox:1.37`, a different tag) as the throwaway "app image" so that "the task ran in the
app's image" is observable: the task prints `busybox --help`'s version line, which differs
between tags, proving image inheritance rather than just env inheritance. No private registry
or pushed image is required.

### Milestone M0 — Prepare the cluster and the disposable namespace

Scope: start the VM, confirm the cluster is healthy, create the `task-spike` namespace. At
the end of M0 a single `Ready` node is visible via `sudo k3s kubectl get nodes` and the
`task-spike` namespace exists. No task objects yet. Acceptance: `sudo k3s kubectl get ns
task-spike` shows the namespace `Active`.

### Milestone M1 — Scheduled CronJob runs a Job on time, with the Nagare label scheme

Scope: hand-apply a `batch/v1` CronJob named `nagare-task-tick` carrying the labels
`nagare.dev/managed-by: nagarectl` and `nagare.dev/task: tick`, with a fast schedule `* * *
* *` (every minute) so a run is observable within ~90 seconds, a pod template labelled the
same way with `restartPolicy: Never`, and a command that prints a recognizable line. At the
end of M1 the CronJob exists, the controller has created at least one Job, that Job's pod has
completed, and the pod's log line is retrievable by the `nagare.dev/task=tick` label
selector. Acceptance (captured transcripts): `kubectl get cronjob,job,pods -n task-spike -l
nagare.dev/task=tick` shows a CronJob, a `Complete` Job, and a `Completed` pod; `kubectl logs
-l nagare.dev/task=tick -n task-spike` prints the task's line. This proves IP2's "a CronJob
schedules and runs a Job" and IP3's label/discovery contract.

### Milestone M2 — One-off run from the CronJob, with wait and logs (IP6)

Scope: from the M1 CronJob, fire a one-off Job immediately with `kubectl create job
tick-oneoff-<ts> --from=cronjob/nagare-task-tick -n task-spike`, wait for it with `kubectl
wait --for=condition=complete --timeout=120s job/tick-oneoff-<ts> -n task-spike`, and retrieve
its logs with `kubectl logs -l nagare.dev/task=tick -n task-spike`. At the end of M2 the
one-off Job has reached `condition=complete` and its logs printed — *without* waiting for the
next scheduled minute. Acceptance: `kubectl wait` returns `job.batch/tick-oneoff-<ts>
condition met` and the logs show the task line. This is the **exact** mechanism EP-51's
`nagarectl task run` (IP6) shells out to; proving it end-to-end is the milestone's whole
point.

### Milestone M3 — Env and image inheritance from a throwaway app world (IP5)

Scope: hand-create a throwaway app identity `spikeapp` consisting of a managed ConfigMap
`nagare-env-spikeapp-runtime` (carrying a recognizable key, e.g. `GREETING=hello-from-app`)
and a managed Secret `nagare-secret-spikeapp-runtime` (carrying e.g. `APP_SECRET=s3cr3t-from-app`),
named exactly as `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`'s `managedConfigMapName` /
`managedSecretName` would name them. Then apply a CronJob `nagare-task-inherit` that (1)
carries `nagare.dev/task: inherit` AND `nagare.dev/app: spikeapp`, (2) runs in the throwaway
*app image* (`busybox:1.37`, standing in for "the app's deployed image"), and (3) adds the
identical `envFrom` block from `envFromField` — a `configMapRef` to
`nagare-env-spikeapp-runtime` and a `secretRef` to `nagare-secret-spikeapp-runtime`, each
`optional: true` — and whose command echoes `$GREETING` and a marker derived from
`$APP_SECRET`. Fire it one-off (the M2 mechanism) and read the logs. At the end of M3 the task
pod's logs show `hello-from-app` (proving runtime-env inheritance from the ConfigMap), a
marker proving the Secret value was present, and a busybox version string proving it ran in
the app image. Acceptance: the inherited ConfigMap value and a Secret-derived marker appear
in the task pod logs, and the image's version line matches `busybox:1.37`. This is the IP5
contract EP-52 encodes.

### Milestone M4 — Batch semantics the renderer will encode (IP2)

Scope: prove, one at a time, the batch fields EP-50 will emit:

- `concurrencyPolicy: Forbid` prevents overlapping runs: a CronJob whose Job sleeps longer
  than its schedule interval shows the controller skipping a fire rather than running two
  Jobs at once.
- `backoffLimit` controls retries: a deliberately-failing Job (`exit 1`) with `backoffLimit:
  2` produces up to 3 pod attempts then a `Failed` Job, not an infinite retry loop.
- `restartPolicy: Never` at pod level: a failed pod is *replaced* (a new pod), not restarted
  in place — confirmed by seeing multiple pods, each `Error`, under the failing Job.
- `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` bound retained Jobs: with the M1
  CronJob's limits set low, only the configured number of completed/failed Jobs are retained
  over several minutes.
- `activeDeadlineSeconds` enforces a timeout: a Job whose command sleeps 120s with
  `activeDeadlineSeconds: 10` is killed at ~10s with reason `DeadlineExceeded`, never
  completing.
- `startingDeadlineSeconds`: note (and, if observable, record) that if the controller cannot
  start a scheduled Job within this many seconds of its scheduled time it skips that run; a
  too-small value can cause missed runs. This is recorded as documented behavior; it is hard
  to force deterministically, so it is *noted* rather than necessarily reproduced.

At the end of M4 each of the first five behaviors is observed and captured; `startingDeadlineSeconds`
is documented. Acceptance: the transcripts in Concrete Steps show the skip-on-overlap, the
bounded retries, the per-attempt new pods, the bounded history, and the `DeadlineExceeded`
kill. This pins IP2's batch semantics.

### Milestone M5 — Confirm logs in VictoriaLogs/Grafana; record contracts; tear down

Scope: confirm a task pod's logs reached VictoriaLogs and record the exact LogsQL query, then
write every verified contract (the CronJob YAML, the embedded `jobTemplate`, the `envFrom`
inheritance block, the labels, and the one-off-run + wait + logs command sequence) into
"Interfaces and Dependencies", record any surprise, and tear everything down. At the end of
M5 the namespace and throwaway app resources are gone and the contracts are recorded.
Acceptance: a LogsQL query against VictoriaLogs returns the task's lines; "Interfaces and
Dependencies" contains the complete language-tagged YAML and command blocks; `kubectl get ns
task-spike` reports `NotFound`.


## Concrete Steps

All commands below run **on the VM `nagare-01`** unless stated otherwise. Wrap each in the IAP
SSH helper from the repository root (`/Users/shinzui/Keikaku/bokuno/nagare`):

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- '<command>'
```

For readability the steps below show the `<command>` that runs *on the VM*; prefix each with
that wrapper. Where a heredoc manifest is piped to `sudo k3s kubectl apply -f -`, run the
whole pipeline inside the single quoted `'<command>'` argument (the wrapper executes it under
a shell on the VM). Every cluster operation uses `sudo k3s kubectl` — never the workstation's
default kubectl context.

The implementer must carry these git trailers on any commit produced by this plan (no feature
branch; commit directly to the current branch). A spike may commit **only** the plan doc and
any recorded artifacts; no production source changes:

```text
MasterPlan: docs/masterplans/10-scheduled-tasks-for-nagare.md
ExecPlan: docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md
Intention: intention_01kts6qyg4ezsbj500ksjr90r1
```

### M0 step 1 — Start the VM and confirm the cluster

The VM is often `TERMINATED`. Start it from the workstation (repo root), then wait for sshd +
k3s:

```bash
gcloud compute instances start nagare-01 --zone=us-west1-a --project=tan-nb-exp
```

Expected (or "already running"):

```text
Starting instance(s) nagare-01...done.
Updated [https://compute.googleapis.com/compute/v1/projects/tan-nb-exp/zones/us-west1-a/instances/nagare-01].
```

Wait ~1–2 minutes, then confirm one `Ready` node (run on the VM):

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl get nodes'
```

Expected:

```text
NAME        STATUS   ROLES                  AGE   VERSION
nagare-01   Ready    control-plane,master   ...   v1.xx.x+k3s1
```

### M0 step 2 — Create the disposable namespace (idempotently)

`kubectl create namespace` errors if it already exists; the `apply` form is re-runnable:

```bash
sudo k3s kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: task-spike
YAML
```

Expected (first run `created`, subsequent runs `unchanged`):

```text
namespace/task-spike created
```

### M1 step 1 — Apply the scheduled CronJob with the Nagare label scheme

Apply a `batch/v1` CronJob named `nagare-task-tick` (the `nagare-task-<name>` convention from
IP3) with a fast `* * * * *` schedule so a Job fires within a minute. The CronJob, the
embedded `jobTemplate`, and the pod template all carry `nagare.dev/managed-by: nagarectl` and
`nagare.dev/task: tick`. The pod uses `restartPolicy: Never` and a `backoffLimit: 0`,
mirroring `backupJobSpecValue` in `cli/nagarectl/src/Nagare/Database/Backup.hs`. History
limits are set low so retained Jobs stay bounded.

```bash
sudo k3s kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-tick
  namespace: task-spike
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: tick
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  startingDeadlineSeconds: 120
  jobTemplate:
    metadata:
      labels:
        nagare.dev/managed-by: nagarectl
        nagare.dev/task: tick
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 300
      template:
        metadata:
          labels:
            nagare.dev/managed-by: nagarectl
            nagare.dev/task: tick
        spec:
          restartPolicy: Never
          containers:
            - name: task
              image: busybox:1.36
              command: ["sh", "-c"]
              args:
                - 'echo "nagare-task tick ran at $(date -u +%Y-%m-%dT%H:%M:%SZ)"'
              resources:
                requests:
                  cpu: "50m"
                  memory: 32Mi
                limits:
                  memory: 64Mi
YAML
```

Expected:

```text
cronjob.batch/nagare-task-tick created
```

### M1 step 2 — Observe the CronJob fire a Job on schedule

Wait up to ~90 seconds for the controller to fire the first Job (the cron granularity is one
minute), then list the CronJob, its Jobs, and pods by the IP3 selector. A short poll loop
avoids racing the minute boundary:

```bash
for i in $(seq 1 18); do
  if sudo k3s kubectl get jobs -n task-spike -l nagare.dev/task=tick \
       -o jsonpath='{.items[*].metadata.name}' | grep -q .; then break; fi
  sleep 10
done
sudo k3s kubectl get cronjob,job,pods -n task-spike -l nagare.dev/task=tick
```

Expected — the CronJob shows a `LAST SCHEDULE`, a Job exists and is `Complete`, and its pod
shows `Completed`:

```text
NAME                          SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
cronjob.batch/nagare-task-tick   * * * * *   False     0        20s             70s

NAME                              STATUS     COMPLETIONS   DURATION   AGE
job.batch/nagare-task-tick-28...   Complete   1/1           3s         20s

NAME                                READY   STATUS      RESTARTS   AGE
pod/nagare-task-tick-28...-abcde     0/1     Completed   0          20s
```

### M1 step 3 — Retrieve the run's logs by the task label selector

This is the discovery the later `task logs` will use. The `nagare.dev/task=tick` selector
matches the pod (which inherits the label from the pod template):

```bash
sudo k3s kubectl logs -l nagare.dev/task=tick -n task-spike --tail=5
```

Expected — the recognizable line printed by the task command:

```text
nagare-task tick ran at 2026-06-10T17:01:00Z
```

### M2 step 1 — Fire a one-off run from the CronJob, then wait and log it (IP6)

Create a Job immediately from the CronJob's template with `kubectl create job ...
--from=cronjob/...`. Use a unique generated name so the step is re-runnable. Then wait for
completion and read the logs — the exact apply→wait→logs flow EP-51's `task run` performs:

```bash
TS=$(date -u +%Y%m%d%H%M%S)
sudo k3s kubectl create job "tick-oneoff-$TS" \
  --from=cronjob/nagare-task-tick -n task-spike
sudo k3s kubectl wait --for=condition=complete --timeout=120s \
  "job/tick-oneoff-$TS" -n task-spike
sudo k3s kubectl logs "job/tick-oneoff-$TS" -n task-spike
```

Expected — the Job is created, `wait` reports the condition met, and the logs print:

```text
job.batch/tick-oneoff-20260610170215 created
job.batch/tick-oneoff-20260610170215 condition met
nagare-task tick ran at 2026-06-10T17:02:16Z
```

Note that the one-off Job's pod *also* carries `nagare.dev/task: tick` (it inherits the
CronJob's `jobTemplate` labels), so the same label-selector log retrieval works for it too —
this is what EP-51's `task logs` uses rather than the Job name:

```bash
sudo k3s kubectl logs -l nagare.dev/task=tick -n task-spike --tail=10
```

Expected — lines from both the scheduled run(s) and the one-off run:

```text
nagare-task tick ran at 2026-06-10T17:01:00Z
nagare-task tick ran at 2026-06-10T17:02:16Z
```

### M3 step 1 — Create the throwaway app world (managed ConfigMap + Secret)

Stand up an `spikeapp` "app" identity: a runtime ConfigMap and Secret named **exactly** as
`cli/nagare-dsl/src/Nagare/Dsl/Render.hs` names them — `nagare-env-<app>-runtime` and
`nagare-secret-<app>-runtime`. These stand in for the resources a real deployed app owns, so
the inheritance proof is a faithful rehearsal of IP5.

```bash
sudo k3s kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nagare-env-spikeapp-runtime
  namespace: task-spike
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/app: spikeapp
data:
  GREETING: hello-from-app
---
apiVersion: v1
kind: Secret
metadata:
  name: nagare-secret-spikeapp-runtime
  namespace: task-spike
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/app: spikeapp
type: Opaque
stringData:
  APP_SECRET: s3cr3t-from-app
YAML
```

Expected:

```text
configmap/nagare-env-spikeapp-runtime created
secret/nagare-secret-spikeapp-runtime created
```

### M3 step 2 — Apply a task that inherits the app's env, secret, and image

Apply a CronJob `nagare-task-inherit` carrying `nagare.dev/task: inherit` AND `nagare.dev/app:
spikeapp` (the optional app label from IP3). It runs in the throwaway *app image*
(`busybox:1.37`, standing in for the app's deployed image) and adds the **identical** `envFrom`
block from `envFromField`: a `configMapRef` to `nagare-env-spikeapp-runtime` and a `secretRef`
to `nagare-secret-spikeapp-runtime`, each `optional: true`. The command echoes the inherited
ConfigMap value, a marker proving the Secret was present (it prints the length of `$APP_SECRET`
so the secret value itself is not logged in clear, but its presence is proven), and the
busybox version line so the running image is observable.

```bash
sudo k3s kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-inherit
  namespace: task-spike
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: inherit
    nagare.dev/app: spikeapp
spec:
  schedule: "0 0 31 2 *"   # never fires (Feb 31); we run it one-off only
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    metadata:
      labels:
        nagare.dev/managed-by: nagarectl
        nagare.dev/task: inherit
        nagare.dev/app: spikeapp
    spec:
      backoffLimit: 0
      template:
        metadata:
          labels:
            nagare.dev/managed-by: nagarectl
            nagare.dev/task: inherit
            nagare.dev/app: spikeapp
        spec:
          restartPolicy: Never
          containers:
            - name: task
              image: busybox:1.37
              envFrom:
                - configMapRef:
                    name: nagare-env-spikeapp-runtime
                    optional: true
                - secretRef:
                    name: nagare-secret-spikeapp-runtime
                    optional: true
              command: ["sh", "-c"]
              args:
                - 'echo "GREETING=$GREETING"; echo "APP_SECRET_LEN=${#APP_SECRET}"; busybox | head -1'
              resources:
                requests:
                  cpu: "50m"
                  memory: 32Mi
                limits:
                  memory: 64Mi
YAML
```

Expected:

```text
cronjob.batch/nagare-task-inherit created
```

The schedule `0 0 31 2 *` (the 31st of February) never fires, so this CronJob only ever runs
when we trigger it one-off — keeping the inheritance proof deterministic. EP-50's renderer
will use the task's real schedule; here a never-firing schedule plus a one-off run is the
controlled way to observe a single inheriting pod.

### M3 step 3 — Fire it one-off and read the inherited values back from the logs

```bash
TS=$(date -u +%Y%m%d%H%M%S)
sudo k3s kubectl create job "inherit-oneoff-$TS" \
  --from=cronjob/nagare-task-inherit -n task-spike
sudo k3s kubectl wait --for=condition=complete --timeout=120s \
  "job/inherit-oneoff-$TS" -n task-spike
sudo k3s kubectl logs -l nagare.dev/task=inherit -n task-spike --tail=5
```

Expected — `GREETING` is the value from the app's ConfigMap (env inheritance proven),
`APP_SECRET_LEN` is non-zero (the Secret was present), and the busybox banner shows the
`1.37` build (image inheritance proven):

```text
job.batch/inherit-oneoff-20260610170900 created
job.batch/inherit-oneoff-20260610170900 condition met
GREETING=hello-from-app
APP_SECRET_LEN=15
BusyBox v1.37.0 (...) multi-call binary.
```

The `GREETING=hello-from-app` line is the load-bearing proof: a value that exists only in the
app's `nagare-env-spikeapp-runtime` ConfigMap appeared inside the task pod, exactly because
the task container's `envFrom` referenced it — precisely as the app's own container does. The
`busybox:1.37` banner (distinct from M1's `1.36`) proves the task ran in the app's image, not
a hard-coded one. Record both lines in Interfaces and Dependencies.

### M3 step 4 — (Optional) prove `optional: true` tolerates a missing store

Delete the ConfigMap and Secret, fire the task again, and confirm the pod still runs (env vars
empty) rather than failing to start — this proves `optional: true` matches the app renderer's
"an app whose store was never written still deploys" guarantee. Re-create them afterward if
continuing.

```bash
sudo k3s kubectl delete configmap nagare-env-spikeapp-runtime -n task-spike --ignore-not-found
sudo k3s kubectl delete secret nagare-secret-spikeapp-runtime -n task-spike --ignore-not-found
TS=$(date -u +%Y%m%d%H%M%S)
sudo k3s kubectl create job "inherit-opt-$TS" --from=cronjob/nagare-task-inherit -n task-spike
sudo k3s kubectl wait --for=condition=complete --timeout=120s "job/inherit-opt-$TS" -n task-spike
sudo k3s kubectl logs "job/inherit-opt-$TS" -n task-spike
```

Expected — the pod still completes; the inherited vars are simply empty:

```text
job.batch/inherit-opt-20260610171200 condition met
GREETING=
APP_SECRET_LEN=0
BusyBox v1.37.0 (...) multi-call binary.
```

Re-create the throwaway app world (M3 step 1) before moving on if you want the inheriting
task to keep its values for later milestones.

### M4 step 1 — `concurrencyPolicy: Forbid` prevents overlapping runs

Apply a CronJob whose Job sleeps 90 seconds — longer than its one-minute schedule — with
`concurrencyPolicy: Forbid`. The controller must *skip* the next fire rather than run two Jobs
at once. Watch for ~3 minutes and confirm at most one Job is `ACTIVE` at any time.

```bash
sudo k3s kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-overlap
  namespace: task-spike
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: overlap
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    metadata:
      labels:
        nagare.dev/managed-by: nagarectl
        nagare.dev/task: overlap
    spec:
      backoffLimit: 0
      template:
        metadata:
          labels:
            nagare.dev/managed-by: nagarectl
            nagare.dev/task: overlap
        spec:
          restartPolicy: Never
          containers:
            - name: task
              image: busybox:1.36
              command: ["sh", "-c"]
              args: ['echo start $(date -u +%H:%M:%S); sleep 90; echo done']
YAML
```

After ~2–3 minutes, list the Jobs and the CronJob events:

```bash
sudo k3s kubectl get jobs -n task-spike -l nagare.dev/task=overlap
sudo k3s kubectl get events -n task-spike --field-selector involvedObject.name=nagare-task-overlap | tail -5
```

Expected — far fewer Jobs than minutes elapsed, and a `JobAlreadyActive` event showing the
controller skipping a fire while one is still running:

```text
NAME                          STATUS    COMPLETIONS   DURATION   AGE
nagare-task-overlap-28...      Running   0/1           95s        95s
...
... Warning  JobAlreadyActive   cronjob/nagare-task-overlap   Not starting job because prior execution is running and concurrency policy is Forbid
```

### M4 step 2 — `backoffLimit` bounds retries; `restartPolicy: Never` replaces pods

Apply a CronJob whose container always `exit 1`, with `backoffLimit: 2`. The Job must make at
most 3 pod attempts (initial + 2 retries) and then become `Failed` — not loop forever. Each
attempt is a *new pod* (because `restartPolicy: Never`), so multiple `Error` pods appear.

```bash
sudo k3s kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-fail
  namespace: task-spike
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: fail
spec:
  schedule: "0 0 31 2 *"   # never fires; run one-off
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    metadata:
      labels: { nagare.dev/managed-by: nagarectl, nagare.dev/task: fail }
    spec:
      backoffLimit: 2
      template:
        metadata:
          labels: { nagare.dev/managed-by: nagarectl, nagare.dev/task: fail }
        spec:
          restartPolicy: Never
          containers:
            - name: task
              image: busybox:1.36
              command: ["sh", "-c"]
              args: ['echo attempt $(date -u +%H:%M:%S); exit 1']
YAML
TS=$(date -u +%Y%m%d%H%M%S)
sudo k3s kubectl create job "fail-oneoff-$TS" --from=cronjob/nagare-task-fail -n task-spike
# Wait for it to FAIL (wait --for=condition=failed), bounded:
sudo k3s kubectl wait --for=condition=failed --timeout=120s "job/fail-oneoff-$TS" -n task-spike || true
sudo k3s kubectl get pods -n task-spike -l nagare.dev/task=fail
sudo k3s kubectl get "job/fail-oneoff-$TS" -n task-spike -o jsonpath='{.status.failed} failed, {.status.conditions[0].type}{"\n"}'
```

Expected — three `Error` pods (initial + 2 retries) and a `Failed` Job condition:

```text
job.batch/fail-oneoff-20260610171500 condition met
NAME                            READY   STATUS   RESTARTS   AGE
fail-oneoff-20260610171500-aaa   0/1     Error    0          40s
fail-oneoff-20260610171500-bbb   0/1     Error    0          30s
fail-oneoff-20260610171500-ccc   0/1     Error    0          15s
3 failed, Failed
```

### M4 step 3 — History limits bound retained Jobs

The M1 `nagare-task-tick` CronJob runs every minute with `successfulJobsHistoryLimit: 3`. After
it has fired several times, confirm the controller retains at most 3 completed Jobs (older ones
are garbage-collected):

```bash
sudo k3s kubectl get jobs -n task-spike -l nagare.dev/task=tick \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.succeeded}{"\n"}{end}'
sudo k3s kubectl get jobs -n task-spike -l nagare.dev/task=tick --no-headers | wc -l
```

Expected — no more than 3 succeeded `tick` Jobs retained, regardless of how many minutes have
elapsed (the one-off `tick-oneoff-*` Jobs are separate and not garbage-collected by the
CronJob, since they are not owned by it):

```text
nagare-task-tick-28...   1
nagare-task-tick-28...   1
nagare-task-tick-28...   1
3
```

### M4 step 4 — `activeDeadlineSeconds` kills a too-long task

Apply a CronJob whose command sleeps 120s but whose Job has `activeDeadlineSeconds: 10`. The
Job must be killed at ~10s with reason `DeadlineExceeded`, never completing — this is how the
renderer encodes a task's execution timeout.

```bash
sudo k3s kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-timeout
  namespace: task-spike
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: timeout
spec:
  schedule: "0 0 31 2 *"   # never fires; run one-off
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    metadata:
      labels: { nagare.dev/managed-by: nagarectl, nagare.dev/task: timeout }
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 10
      template:
        metadata:
          labels: { nagare.dev/managed-by: nagarectl, nagare.dev/task: timeout }
        spec:
          restartPolicy: Never
          containers:
            - name: task
              image: busybox:1.36
              command: ["sh", "-c"]
              args: ['echo "sleeping 120s"; sleep 120; echo "should never print"']
YAML
TS=$(date -u +%Y%m%d%H%M%S)
sudo k3s kubectl create job "timeout-oneoff-$TS" --from=cronjob/nagare-task-timeout -n task-spike
sleep 20
sudo k3s kubectl get "job/timeout-oneoff-$TS" -n task-spike \
  -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].reason}{"\n"}'
```

Expected — the Job failed with reason `DeadlineExceeded` at ~10s; "should never print" is
absent from the logs:

```text
Failed=DeadlineExceeded
```

### M4 step 5 — `startingDeadlineSeconds` (documented behavior)

`startingDeadlineSeconds` bounds how long after a scheduled time the controller may still
start a missed Job; past it, that run is skipped (counted as a missed start). A value set too
small (e.g. below the controller's ~10s reconcile cadence) can cause a CronJob to never run if
the controller is briefly busy. This is well-documented Kubernetes behavior and is hard to
force deterministically on a healthy cluster, so it is **recorded** here rather than
necessarily reproduced: EP-50 should choose a generous default (the M1 manifest uses `120`)
and EP-53 should document that an aggressively small value risks missed runs. If you wish to
observe it, you can set `startingDeadlineSeconds: 5`, `suspend: true` for ~30 seconds across a
scheduled boundary, then `suspend: false`, and observe a `Cannot determine if job needs to be
started ... too many missed start times` / skipped-run event; record whatever you observe in
Surprises.

### M5 step 1 — Confirm task pod logs in VictoriaLogs and record the query

The cluster already ships every pod's stdout/stderr to VictoriaLogs in the `logging`
namespace (EP-5). Task pods are ordinary pods, so they are scraped automatically. Confirm a
`tick` task's logs are queryable. The simplest in-cluster check queries VictoriaLogs' HTTP API
directly from a throwaway pod, using the EP-5-verified stream fields
`kubernetes.pod_namespace` and `kubernetes.container_name`. The LogsQL selector that finds the
task-spike namespace's task logs is:

```text
{kubernetes.pod_namespace="task-spike"} nagare-task
```

Run it against the VictoriaLogs server from a curl pod (the field-value selector restricts to
the spike namespace; the `nagare-task` word-filter narrows to the task's printed lines):

```bash
sudo k3s kubectl run vlogs-check --rm -i --restart=Never -n task-spike \
  --image=curlimages/curl:8.10.1 -- \
  curl -s 'http://victoria-logs-victoria-logs-single-server.logging.svc:9428/select/logsql/query' \
  --data-urlencode 'query={kubernetes.pod_namespace="task-spike"} nagare-task' \
  --data-urlencode 'limit=5'
```

Expected — JSON lines whose `_msg` is a task's printed output, tagged with the pod's
namespace/name/container stream fields:

```text
{"_time":"2026-06-10T17:01:00...","_msg":"nagare-task tick ran at 2026-06-10T17:01:00Z","kubernetes.pod_namespace":"task-spike","kubernetes.pod_name":"nagare-task-tick-28...-abcde","kubernetes.container_name":"task"}
pod "vlogs-check" deleted
```

For Grafana (the human-facing path EP-51/EP-53 reference), the Logs datasource is the signed
`victoriametrics-logs-datasource` plugin; the Explore query that finds a single task's history
across both scheduled and one-off runs, scoping by the IP3 label if the collector promotes
pod labels, otherwise by namespace + word filter, is recorded in Interfaces and Dependencies.
Record in Surprises whether the collector exposes the `nagare.dev/task` *pod label* as a
queryable stream field (it may only expose the `kubernetes.*` fields by default); if it does
not, the canonical task-history query is `{kubernetes.pod_namespace="<ns>"}
kubernetes.pod_name:"nagare-task-<task>"`.

### M5 step 2 — Record all verified contracts

Copy the *observed* CronJob YAML, the embedded `jobTemplate`, the `envFrom` inheritance block,
the labels, the one-off-run + wait + logs command sequence, and the LogsQL query into the
"Interfaces and Dependencies" section below, replacing the templated values there with what
the cluster actually accepted. Note any field Kubernetes rejected or defaulted differently
from the backup CronJob in Surprises & Discoveries.

### M5 step 3 — Tear down (idempotent)

Remove everything the spike applied. Deleting the namespace removes the CronJobs, Jobs, pods,
ConfigMap, and Secret in one shot; `--ignore-not-found` makes it safe to re-run:

```bash
sudo k3s kubectl delete namespace task-spike --ignore-not-found
```

Expected:

```text
namespace "task-spike" deleted
```

Confirm it is gone:

```bash
sudo k3s kubectl get ns task-spike
```

Expected:

```text
Error from server (NotFound): namespaces "task-spike" not found
```

Because the throwaway app's managed ConfigMap and Secret lived inside `task-spike`, deleting
the namespace removes them too; no resource leaks into `personal` or any other namespace.


## Validation and Acceptance

The spike passes when all of the following are observed on the live cluster and the
transcripts are captured in Concrete Steps (or this section's deltas), phrased as behavior a
human can verify:

1. **Scheduled run (M1).** `sudo k3s kubectl get cronjob,job,pods -n task-spike -l
   nagare.dev/task=tick` shows the CronJob `nagare-task-tick`, at least one `Complete` Job,
   and a `Completed` pod within ~90 seconds of applying it; `sudo k3s kubectl logs -l
   nagare.dev/task=tick -n task-spike` prints `nagare-task tick ran at <ts>`. This proves the
   IP3 naming/label/discovery contract and IP2's "a CronJob schedules and runs a Job".

2. **One-off run (M2, IP6).** `sudo k3s kubectl create job <gen> --from=cronjob/nagare-task-tick`
   creates a Job; `sudo k3s kubectl wait --for=condition=complete --timeout=120s job/<gen>`
   returns `condition met`; `sudo k3s kubectl logs -l nagare.dev/task=tick` prints the task
   line. This is the exact mechanism EP-51's `nagarectl task run` uses.

3. **Inheritance (M3, IP5).** The task pod's logs show `GREETING=hello-from-app` (a value that
   exists *only* in `nagare-env-spikeapp-runtime`), a non-zero `APP_SECRET_LEN` (the Secret
   was present via `secretRef`), and the `busybox:1.37` banner (the task ran in the app's
   image). Optionally, with the ConfigMap/Secret deleted, the task still completes with empty
   vars, proving `optional: true`.

4. **Batch semantics (M4, IP2).** `concurrencyPolicy: Forbid` yields a `JobAlreadyActive`
   skip rather than overlapping Jobs; `backoffLimit: 2` yields exactly 3 `Error` pod attempts
   then a `Failed` Job; `successfulJobsHistoryLimit: 3` retains at most 3 completed `tick`
   Jobs; `activeDeadlineSeconds: 10` kills a 120s task at ~10s with reason `DeadlineExceeded`.
   `startingDeadlineSeconds` behavior is documented.

5. **Observability (M5, IP6).** A LogsQL query
   `{kubernetes.pod_namespace="task-spike"} nagare-task` against the VictoriaLogs server
   returns the task's printed lines with the `kubernetes.*` stream fields, proving the
   existing stack scrapes task pods with no new wiring; the exact query is recorded for
   EP-51/EP-53.

6. **Recorded contracts.** "Interfaces and Dependencies" below contains the final verified
   CronJob YAML, the embedded `jobTemplate`, the `envFrom` inheritance block, the label set,
   the one-off-run + wait + logs command sequence, and the LogsQL query — the contracts
   EP-50/EP-51/EP-52/EP-53 encode.

7. **Clean teardown.** `sudo k3s kubectl get ns task-spike` reports `NotFound`; nothing was
   applied to `personal` or any namespace other than `task-spike`.

This spike ships no code, so there are no unit tests to run; its "tests" are the live `kubectl`
proofs above. Each is a before/after observation a novice can reproduce by following Concrete
Steps and comparing to the expected transcripts.


## Idempotence and Recovery

Every step is safe to repeat. All manifests are applied with `kubectl apply -f -`, which
creates on first run and reconciles (`unchanged`/`configured`) on subsequent runs — never
erroring on "already exists". The namespace itself is created via `apply` (not `kubectl create
namespace`, which would error if present). One-off Jobs use a timestamped generated name
(`tick-oneoff-$TS`, `inherit-oneoff-$TS`, etc.) so re-running never collides with a prior
Job; if you reuse a fixed name and it already exists, delete it first with `sudo k3s kubectl
delete job <name> -n task-spike --ignore-not-found`.

If a milestone fails halfway: the CronJobs are harmless (the never-firing `0 0 31 2 *`
schedule means the inherit/fail/timeout CronJobs only run when you trigger them; the
every-minute `tick`/`overlap` CronJobs self-bound their retained Jobs via the history limits).
You can re-run any milestone's `kubectl apply` to restore the intended state. To pause the
every-minute CronJobs without deleting them, set `suspend: true`:

```bash
sudo k3s kubectl patch cronjob nagare-task-tick -n task-spike \
  -p '{"spec":{"suspend":true}}'
```

To recover from any confused state, the universal reset is full teardown followed by re-running
from M0 step 2:

```bash
sudo k3s kubectl delete namespace task-spike --ignore-not-found
```

The spike never touches the `personal` namespace, any managed database, any deployed app, or
GCS. The only `gcloud` call is the VM start, which is itself idempotent ("already running" is
fine). Tearing down the `task-spike` namespace fully reclaims everything the spike created.


## Interfaces and Dependencies

This section records the **verified contracts** the later plans encode. The blocks below are
the *intended* shapes the spike proves; after running, replace any value the cluster corrected
with the observed value, and note the correction in Surprises & Discoveries.

**Libraries / tools used by the spike.** `kubectl` (as `sudo k3s kubectl` on the VM) for all
cluster operations; `gcloud` (project-pinned to `tan-nb-exp`) only to start the VM; the repo's
`scripts/iap-ssh.sh` wrapper to reach the VM. No Haskell, no `Cradle`, no pushed images — the
spike is hand-run shell + YAML. The later plans (EP-50/51/52) will use `Cradle` (`cmd
"kubectl" & addArgs [...] & run`/`run_`) to shell out exactly as
`cli/nagarectl/src/Nagare/Database/Backup.hs` and `Discover.hs` already do.

**The CronJob shape (IP2 + IP3), the contract EP-50's `Nagare.Dsl.Task.Render` reproduces.**
A `batch/v1` CronJob named `nagare-task-<task>`, carrying the Nagare labels at the CronJob,
`jobTemplate`, and pod-template levels, with the batch fields below. This mirrors
`renderBackupCronJob` / `backupJobSpecValue` in `cli/nagarectl/src/Nagare/Database/Backup.hs`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-<task>
  namespace: <ns>
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: <task>
    # nagare.dev/app: <app>   # present only when the task is associated with an app
spec:
  schedule: "<cron expression>"        # e.g. "0 3 * * *"; "* * * * *" for fast spike runs
  concurrencyPolicy: Forbid            # never overlap a task with itself
  successfulJobsHistoryLimit: 3        # bound retained completed Jobs
  failedJobsHistoryLimit: 1            # bound retained failed Jobs
  startingDeadlineSeconds: 120         # generous; small values risk missed runs
  jobTemplate:
    metadata:
      labels:
        nagare.dev/managed-by: nagarectl
        nagare.dev/task: <task>
        # nagare.dev/app: <app>
    spec:                              # <-- this .spec IS the one-off Job's body
      backoffLimit: <retries>          # e.g. 0 (no retry) .. N
      activeDeadlineSeconds: <timeout> # execution timeout; Job killed at deadline
      template:
        metadata:
          labels:
            nagare.dev/managed-by: nagarectl
            nagare.dev/task: <task>
            # nagare.dev/app: <app>
        spec:
          restartPolicy: Never         # a failed pod is replaced, not restarted in place
          containers:
            - name: task
              image: <image>           # explicit, OR the app's deployed image (IP5)
              command: [...]
              args: [...]
              # envFrom: (see inheritance block below, when app-associated)
              resources: { ... }
```

**The `envFrom` inheritance block (IP5), the contract EP-52 reproduces.** When a task is
associated with an app, the task container gains exactly this block, mirroring `envFromField`
in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`. The two resource names are
`nagare-env-<app>-runtime` (ConfigMap) and `nagare-secret-<app>-runtime` (Secret), each
`optional: true`:

```yaml
envFrom:
  - configMapRef:
      name: nagare-env-<app>-runtime
      optional: true
  - secretRef:
      name: nagare-secret-<app>-runtime
      optional: true
```

Verified effect: a key set only in `nagare-env-<app>-runtime` (the spike used
`GREETING=hello-from-app`) appears as an environment variable inside the task pod; a key in
`nagare-secret-<app>-runtime` is likewise present; with both resources absent, `optional:
true` lets the pod still start (empty vars). Image inheritance is verified by running the task
in the app's image directly (the spike used `busybox:1.37` and observed its distinct banner).

**The label / discovery contract (IP3), the contract EP-51 queries.** Every task object
carries `nagare.dev/managed-by: nagarectl` and `nagare.dev/task: <task>`, plus
`nagare.dev/app: <app>` when app-associated. The discovery selector EP-51 uses, mirroring
`dbLabelSelector` in `cli/nagarectl/src/Nagare/Database/Discover.hs`, is:

```text
nagare.dev/managed-by=nagarectl,nagare.dev/task            # all tasks
nagare.dev/managed-by=nagarectl,nagare.dev/task=<task>     # one task's CronJob + Job pods
nagare.dev/managed-by=nagarectl,nagare.dev/app=<app>       # all tasks of one app
```

**The one-off run + wait + logs sequence (IP6), the contract EP-51's `task run`/`task logs`
encode.** A one-off run reuses the deployed CronJob's `jobTemplate` verbatim via Kubernetes'
native `--from=cronjob`; the wait/logs flow mirrors `waitForJob` in
`cli/nagarectl/src/Nagare/Database/Backup.hs`:

```bash
# task run <app> <task>  ==>
kubectl create job <generated-name> --from=cronjob/nagare-task-<task> -n <ns>
kubectl wait --for=condition=complete --timeout=<timeout>s job/<generated-name> -n <ns>
kubectl logs -l nagare.dev/task=<task> -n <ns>     # logs by label, not by Job name

# task logs <app> <task>  ==>  (follow with -f for a running task)
kubectl logs -l nagare.dev/task=<task> -n <ns> --tail=<n>
```

The generated name should be unique per invocation (the spike used
`<task>-oneoff-<UTCtimestamp>`); EP-51 will choose its own scheme (e.g. a short random or
timestamp suffix, truncated to 63 chars as `Backup.hs` does with `T.take 63`).

**The observability query (IP6), the contract EP-51's Grafana hint and EP-53's docs
reference.** Task pods are scraped by the existing VictoriaLogs collector (EP-5) with no new
wiring — **verified** on the live cluster. The stream fields present on every task log line are
`kubernetes.pod_namespace`, `kubernetes.pod_name`, `kubernetes.container_name`, **and the
promoted pod labels** `kubernetes.pod_labels.nagare.dev/task`,
`kubernetes.pod_labels.nagare.dev/managed-by` (plus the batch-injected
`kubernetes.pod_labels.job-name` / `controller-uid`). The **canonical** task-history LogsQL
query, verified against both scheduled and one-off runs, is the label-scoped form:

```text
{kubernetes.pod_namespace="<ns>"} kubernetes.pod_labels.nagare.dev/task:="<task>"
```

(LogsQL `:=` is exact field-value match.) An equivalent name-prefix fallback, which also
captures one-off `<task>-oneoff-*` pods sharing the prefix, is
`{kubernetes.pod_namespace="<ns>"} kubernetes.pod_name:"nagare-task-<task>"`; the spike's quick
smoke check was `{kubernetes.pod_namespace="<ns>"} nagare-task`. Query any of these in Grafana's
Explore via the `victoriametrics-logs-datasource` Logs datasource, or against the server
directly at
`http://victoria-logs-victoria-logs-single-server.logging.svc:9428/select/logsql/query`.
Verified server response (one line, abridged):

```text
{"_msg":"nagare-task tick ran at 2026-06-10T18:02:01Z",
 "kubernetes.pod_namespace":"task-spike",
 "kubernetes.pod_name":"nagare-task-tick-29685242-bw9zf",
 "kubernetes.container_name":"task",
 "kubernetes.pod_labels.nagare.dev/task":"tick",
 "kubernetes.pod_labels.nagare.dev/managed-by":"nagarectl"}
```

**Downstream consumers.** EP-50 (`docs/plans/50-typed-task-model-and-cronjob-job-renderer.md`)
reproduces the CronJob/jobTemplate shape and the labels. EP-51
(`docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md`) encodes
the discovery selector, the one-off-run + wait + logs sequence, and the Grafana query hint.
EP-52 (`docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md`)
encodes the `envFrom` inheritance block, the `nagare.dev/app` label, and image inheritance.
EP-53 (`docs/plans/53-scheduled-tasks-docs-and-end-to-end-examples.md`) documents the LogsQL
query and the full Grafana walkthrough. None of them may re-derive these shapes from a guess;
they cite the verified blocks above.
