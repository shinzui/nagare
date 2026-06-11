---
id: 10
slug: scheduled-tasks-for-nagare
title: "Scheduled Tasks for Nagare"
kind: master-plan
created_at: 2026-06-10T16:49:49Z
intention: "intention_01kts6qyg4ezsbj500ksjr90r1"
---

# Scheduled Tasks for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Nagare today can deploy long-running web applications (Knative Services), static sites,
and managed databases (Postgres/Redis/ClickHouse StatefulSets), but it has no way to run
work *on a schedule* or *once, on demand*. A user who wants a nightly cleanup, an hourly
sync, a periodic report, or a one-off data migration has to hand-write a Kubernetes
CronJob or `kubectl run` a pod by hand — exactly the Kubernetes-internals exposure the
typed DSL exists to hide. This is the next PaaS gap on the roadmap
(`docs/roadmaps/paas-gap-roadmap.md`, "Phase 5: Scheduled Tasks and One-Off Jobs").

After this initiative, a user can declare a **scheduled task** — a named unit of work with
a cron schedule and a command — in the same typed Haskell config they already use for apps
and databases, and operate it with a new `nagarectl task` command group. Concretely, after
this initiative someone can:

- Write a `Task` value in `Config.hs` that says "run `python manage.py cleanup` every night
  at 03:00 in the `notes` app's image, with the `notes` app's runtime environment and
  secrets" and have `nagarectl deploy` render and apply a Kubernetes **CronJob** for it.
- Run `nagarectl task list notes` and see every task attached to the `notes` app, its
  schedule, and when it last ran and last succeeded.
- Run `nagarectl task run notes cleanup` to fire the task **once, right now**, wait for it to
  finish, and stream its logs — without waiting for the next scheduled time.
- Run `nagarectl task logs notes cleanup` to view the most recent run's logs (and follow a
  running one), with a pointer into the existing Grafana/VictoriaLogs story for history.
- Run `nagarectl task delete notes cleanup` to remove the CronJob.

A "scheduled task" here means a Kubernetes **CronJob**: a typed object that, on a cron
schedule (for example `0 3 * * *`), creates a **Job**, which runs one or more **Pods** to
completion. A "one-off run" means a single **Job** created immediately from that CronJob's
template, independent of the schedule. These are standard Kubernetes batch primitives;
Nagare already proves they work — the managed-database backup feature
(`cli/nagarectl/src/Nagare/Database/Backup.hs`) renders a `batch/v1` CronJob for scheduled
backups and a `batch/v1` Job for on-demand backups today. This initiative generalizes that
private, backup-specific machinery into a first-class, user-facing `Task` resource.

In scope:

- A typed `Task` model in the pure DSL package (`cli/nagare-dsl/`): name, namespace, cron
  schedule (validated), the command and arguments to run, the image to run them in (either
  an explicit image or "inherit the referenced app's image"), inline environment variables
  with the existing runtime/build/preview scopes, an optional reference to an app whose
  runtime environment and secrets the task inherits, resource requests/limits, an execution
  timeout, a concurrency policy (forbid/allow/replace overlapping runs), a restart/retry
  policy (backoff limit and pod restart policy), and history-retention limits.
- A renderer that turns a `Task` into a Kubernetes CronJob, plus the embedded Job template
  that a one-off run reuses.
- The `nagarectl task list/run/logs/delete` command group, plus deploy-time provisioning so
  declared tasks are applied alongside their app.
- App↔task association: a task can run "in an app's world" — the app's deployed image tag
  and its managed runtime `ConfigMap`/`Secret` — resolved at deploy time, mirroring how
  managed-database connection environment is injected into apps today.
- Golden-file tests for the rendered manifests, offline unit tests for the CLI helpers, a
  user guide (`docs/user/scheduled-tasks.md`), and runnable end-to-end examples under
  `cluster/examples/`.

Explicitly out of scope (deferred or handled elsewhere):

- **General-purpose ad-hoc shells / `kubectl exec` into arbitrary pods.** `task run` runs a
  *declared* task once; it is not an interactive shell. (`nagarectl db shell` already covers
  interactive database sessions.)
- **Event-driven or webhook-triggered tasks.** Triggers beyond cron and manual `task run`
  belong to the future Control-Plane API (roadmap Phase 8).
- **Multi-node scheduling, task queues, fan-out/parallelism beyond a single Job's
  completions.** Nagare is intentionally single-node; tasks render single-completion Jobs.
- **A new logging pipeline.** Task pod logs flow through the *existing* VictoriaLogs/Grafana
  stack that already scrapes cluster pods; this initiative documents and links to it rather
  than building new observability infrastructure.
- **Changing the managed-database backup CronJob.** That machinery
  (`Nagare.Database.Backup`) stays as-is; this initiative does not refactor it onto the new
  `Task` type (a possible future cleanup, recorded as a follow-up, not a deliverable).

The user-visible win is that the most common "cron job" need — the thing every other PaaS
offers — becomes a typed, validated, one-line declaration plus a four-verb CLI, with the
same safety and determinism guarantees as the rest of Nagare's surface.


## Decomposition Strategy

The initiative is decomposed into five child plans that separate *substrate feasibility*
from the *typed model and renderer* from the *operational CLI* from the *app-integration
layer* from the *documentation*, so that each plan produces an independently verifiable
behavior and groups one functional concern rather than one file. This mirrors the
decomposition that worked for MasterPlan 9 (managed databases): a gating spike, a pure-DSL
model/renderer plan, a CLI/provisioning plan, an app-integration plan, and a docs plan.

The decisive structural decision is that **scheduled tasks and one-off runs are two
operations on one model, not two units of decomposition.** The roadmap notes a MasterPlan
"if one-off Jobs and CronJobs are split," but splitting them into separate plans would force
two plans to define the same Pod template and the same labels in the same way — exactly the
cross-plan coupling the decomposition principles warn against. Instead, one renderer
(EP-50) produces the CronJob *and* the embedded Job template; the one-off run (`task run`,
in EP-51) reuses that same template via Kubernetes' native `kubectl create job
--from=cronjob/...`. The schedule is just a field on the CronJob; removing it yields the
Job a one-off run uses. They share a single typed model and a single rendered shape.

A second structural decision: **the typed model (EP-50) is pure DSL work and carries no
hard dependency on the live cluster.** It depends only *softly* on the spike (EP-49) to
match the YAML shapes the spike verifies against a real Kubernetes CronJob/Job on the
`tan-nb-exp` cluster. This lets the model and renderer be written and golden-tested entirely
offline while the spike de-risks the genuinely uncertain parts: that a one-off run derived
from a CronJob behaves correctly, that a task can inherit an app's environment via `envFrom`
the app's managed `ConfigMap`/`Secret`, that concurrency/backoff/history-limit semantics
behave as documented, and that task pod logs actually appear in VictoriaLogs/Grafana.

A third decision: **app-integration is split out (EP-52) from both the model (EP-50) and the
CLI (EP-51)** because it touches a *different code path* — the app deploy path in
`cli/nagarectl/src/Nagare/Deploy.hs` and the `Deployment` type in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` — and resolves values only knowable at deploy time
(the app's pushed image tag, the app's managed env/secret resource names). This is the exact
parallel of MasterPlan 9's EP-46 ("generated database connection-env injection for apps"),
which was deliberately separated from the database CLI (EP-45) for the same reason: app-side
wiring is a distinct concern from resource provisioning.

Alternatives considered and rejected:

- **One single ExecPlan.** Rejected: the work spans the pure DSL package, the CLI package,
  the app deploy path, golden tests, and docs/examples — more than five milestones across
  unrelated modules, with a genuine live-cluster feasibility risk worth isolating in a
  spike. The roadmap itself allows "a small MasterPlan."
- **Splitting CronJobs and one-off Jobs into two plans.** Rejected for the coupling reason
  above: they are one model and one rendered template.
- **Folding app-integration into the model plan.** Rejected: image-tag and managed-resource
  resolution happen at deploy time in the CLI package, not in the pure DSL; merging them
  would put a cluster-aware concern inside the pure, offline-testable renderer.
- **Folding observability into its own plan.** Rejected as too thin: task pods are scraped
  by the existing VictoriaLogs stack automatically, so the work is a `task logs` command
  (part of the CLI plan, EP-51) plus a documented Grafana walkthrough (part of the docs
  plan, EP-53), not a standalone build.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 49 | Scheduled-task substrate spike and one-off-run feasibility | docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md | None | None | Complete |
| 50 | Typed Task model and CronJob/Job renderer | docs/plans/50-typed-task-model-and-cronjob-job-renderer.md | None | EP-49 | Complete |
| 51 | nagarectl task lifecycle commands and deploy-time provisioning | docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md | EP-50 | EP-49 | Complete |
| 52 | App-task association and runtime env/image/secret inheritance | docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md | EP-50 | EP-51 | Complete |
| 53 | Scheduled-tasks docs and end-to-end examples | docs/plans/53-scheduled-tasks-docs-and-end-to-end-examples.md | EP-50 | EP-51, EP-52 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-49, EP-51).


## Dependency Graph

EP-49 (the spike) has no dependencies and gates nothing *hard*. It exists to verify the
substrate on the live `tan-nb-exp` cluster and to record the exact CronJob/Job YAML shapes,
the one-off-run command, and the env-inheritance mechanism that the later plans encode. Its
output is a verified contract, not shipped code, so every later plan *soft*-depends on it:
they can begin against the spike's documented findings, and reconcile if the spike surfaces
a surprise.

EP-50 (typed model and renderer) is pure work inside the `cli/nagare-dsl/` package. It has
no hard dependency — it introduces a new `Nagare.Dsl.Task` module and a new
`Nagare.Dsl.Task.Render` module, neither of which any existing code imports. It
soft-depends on EP-49 so the rendered CronJob/Job matches the shapes the spike proved on a
real cluster. EP-50 is the keystone: it defines the typed `Task` model and its JSON shape
(Integration Point IP1), the rendered CronJob/Job manifests (IP2), and the task
naming/label contract (IP3).

EP-51 (the `nagarectl task` CLI and deploy-time provisioning) hard-depends on EP-50: its
commands discover, run, and delete the CronJobs that EP-50's renderer produces, and its
deploy-time provisioning applies them. It cannot compile or behave meaningfully without
EP-50's `Task` type, renderer, and label contract. It soft-depends on EP-49 for the exact
one-off-run command and log-retrieval approach. EP-51 owns the CLI command-group plumbing
(IP4) and the one-off-run + logs contract (IP6).

EP-52 (app↔task association and inheritance) hard-depends on EP-50: it extends the
`Deployment` type and the renderer to resolve an app's image and managed env/secret into the
task. It soft-depends on EP-51 because the most natural way to exercise the association
end-to-end is through the `task` CLI, but the association can be implemented and tested via
the renderer and `nagarectl deploy` alone. EP-52 owns the app↔task association contract
(IP5).

EP-53 (docs and examples) hard-depends on EP-50 (it documents the typed model and must show
real config) and soft-depends on EP-51 and EP-52 because it documents the CLI surface and
the app-inheritance behavior and should describe *what actually shipped*. It is always last.

Parallelism: EP-50 can start immediately (alongside or just after EP-49's findings land).
Once EP-50 is Complete, EP-51 and EP-52 can proceed **in parallel** — they touch largely
different code (EP-51 the `Nagare.Task.*` CLI modules and the `task` subparser; EP-52 the
`Deployment` type, the app deploy path, and the renderer's env/image resolution) and share
only the EP-50 contracts and a small reconciliation at IP5/IP6. EP-53 begins once at least
one of EP-51/EP-52 is far enough along to document.


## Integration Points

**IP1 — The typed `Task` model and its JSON shape.** Defined by **EP-50** in a new module
`cli/nagare-dsl/src/Nagare/Dsl/Task.hs`, exporting a validated `Task` record with hidden
constructors and smart constructors that match the house pattern in
`cli/nagare-dsl/src/Nagare/Dsl/Database.hs` (e.g. `mkDatabaseName`, `mkEngineVersion`). The
`Task` value is serialized to JSON by an `emitTask :: Task -> IO ()` function in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` and decoded back by a `decodeTask`/`toTask` path
in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, exactly mirroring `emitDatabase`/`decodeDatabase`.
The JSON object carries a `"kind": "Task"` discriminator (databases use `"kind": "Database"`;
plain deployments carry no `kind`). The contract is: a config file calls `emitTask task` and
the loader re-runs every smart constructor so an invalid task fails at load with a precise
`MarshalError "<field>" "<message>"`. Consumed by EP-51 (the CLI loads tasks from config to
provision them) and EP-52 (the app deploy path loads tasks associated with an app). The
exact field set is owned by EP-50; the cron-schedule validation rule it introduces (a new
`Schedule` newtype with `mkSchedule`) is part of this contract.

**IP2 — The rendered CronJob and embedded Job-template shapes.** Verified on the live cluster
by **EP-49** and produced by **EP-50** in `cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs`. The
contract is a single `batch/v1` CronJob document whose `spec.jobTemplate.spec` is the Job
template, structured to match the proven backup machinery in
`cli/nagarectl/src/Nagare/Database/Backup.hs` (`renderBackupCronJob`, lines ~283–298):
`spec.schedule`, `spec.concurrencyPolicy`, `spec.successfulJobsHistoryLimit`,
`spec.failedJobsHistoryLimit`, `spec.startingDeadlineSeconds`, and
`spec.jobTemplate.spec.{backoffLimit,activeDeadlineSeconds,template.spec.{restartPolicy,
containers,...}}`. Rendering uses the same Aeson `object`/`.=` → `Data.Yaml.Pretty.encodePretty`
pipeline and deterministic key-ordering comparator that `Nagare/Dsl/Database/Render.hs` uses,
so golden files are byte-stable. The renderer also exposes the bare Job `.spec` so a one-off
run can reuse it. Consumed by EP-51 (applies the CronJob; derives the one-off Job) and EP-52
(injects the app's `envFrom` and resolved image into the same template).

**IP3 — The task naming and label contract.** Defined by **EP-50**. The CronJob is named
`nagare-task-<taskName>` (mirroring the backup CronJob's `nagare-dbbackup-<dbName>` and the
managed-resource `nagare-<kind>-<name>` convention used throughout the renderer). Every
rendered object carries the labels `nagare.dev/managed-by: nagarectl`, `nagare.dev/task:
<taskName>`, and — when the task is associated with an app — `nagare.dev/app: <appName>`.
This is the discovery contract: EP-51's `nagarectl task list/run/logs/delete` find tasks by
the label selector `nagare.dev/managed-by=nagarectl,nagare.dev/task` (optionally
`,nagare.dev/app=<app>` to scope to one app), exactly as
`cli/nagarectl/src/Nagare/Database/Discover.hs` finds databases by
`nagare.dev/managed-by=nagarectl,nagare.dev/database`. EP-50 owns the names and label keys;
EP-51 consumes them for discovery; EP-52 sets `nagare.dev/app` when an app reference is
present.

**IP4 — The `nagarectl task` command-group plumbing.** Introduced by **EP-51** in
`cli/nagarectl/app/Main.hs` (a new `TaskCommand` ADT added to the top-level `Command` ADT, a
`taskCmd`/`taskSubparser` block mirroring `dbCmd`/`dbSubparser` at lines ~1098–1159, and a
`runTask` dispatcher mirroring `runDb` at lines ~1844–1880) and in new modules under
`cli/nagarectl/src/Nagare/Task/` (`Discover.hs`, `List.hs`, `Run.hs`, `Logs.hs`,
`Delete.hs`), registered in `cli/nagarectl/nagarectl.cabal`. Shared discovery helpers
(label-selector query + defensive JSON parsing, modelled on
`Nagare/Database/Discover.hs`) live in `Nagare/Task/Discover.hs`. The contract is that this
subparser and these helpers are *extension points*: EP-52 may add an app-scoped flag or
positional, but must extend, not fork, this command group. Process invocation uses the
existing `Cradle` wrapper (`cmd "kubectl" & addArgs [...] & run`/`run_`) used everywhere in
the CLI.

**IP5 — The app↔task association and inheritance contract.** Defined by **EP-52**. A task may
reference an app by its `ServiceName`; the association is expressed in the typed model (a
field carried on `Task` — e.g. `taskApp :: Maybe ServiceName` — defined in EP-50's IP1 so the
model compiles, with EP-52 owning the *semantics* and the deploy-time resolution). When an
app reference is present and the task opts into inheritance, the rendered Job template (1)
uses the app's deployed image tag instead of an explicit image, resolved at deploy time in
`cli/nagarectl/src/Nagare/Deploy.hs` the same way `Nagare.Image`/`resolveImageTag` resolves an
app's tag today, and (2) gains `envFrom` references to the app's managed runtime resources
`nagare-env-<app>-runtime` (ConfigMap) and `nagare-secret-<app>-runtime` (Secret), each with
`optional: true`, exactly as `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` (`envFromField`,
lines ~368–375) wires them into the app's own container. EP-52 also defines the predefined
task variables injected into every task run (at minimum `NAGARE_TASK_NAME` and a per-run
`NAGARE_RUN_ID`), following the generated-variable pattern in
`cli/nagarectl/src/Nagare/Env/Generated.hs`. Consumed by EP-50's renderer (which emits the
`envFrom` block and the `nagare.dev/app` label), EP-51 (whose `task list <app>` scopes by the
`nagare.dev/app` label), and EP-53 (which documents the inherited-variable table).

**IP6 — The one-off run and logs/observability contract.** Defined by **EP-51**. `nagarectl
task run <app> <task>` creates a single Job from the deployed CronJob via `kubectl create
job <generated-name> --from=cronjob/nagare-task-<task> -n <ns>`, waits with `kubectl wait
--for=condition=complete --timeout=...`, and streams logs — mirroring the
apply→`kubectl wait --for=condition=complete`→logs flow in
`cli/nagarectl/src/Nagare/Database/Backup.hs` (`waitForJob`, lines ~392–404). `nagarectl
task logs <app> <task>` follows pod logs by the IP3 label selector with `kubectl logs -l
nagare.dev/task=<task> ...`, mirroring `streamServiceLogs`/`logArgs` in
`cli/nagarectl/src/Nagare/App.hs` (lines ~103–125). Task pod logs are scraped by the existing
cluster VictoriaLogs stack with no new wiring; the contract here is that EP-51 surfaces a
Grafana/VictoriaLogs query hint and EP-53 documents the full history walkthrough. Consumed by
EP-53 (docs) and exercised by the spike EP-49 (which proves both `--from=cronjob` and log
retrieval on the live cluster).


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and
the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-49: A hand-applied CronJob with the Nagare label scheme runs on schedule on the live cluster.
- [x] EP-49: A one-off Job created via `kubectl create job --from=cronjob/...` runs, completes, and its logs are retrievable.
- [x] EP-49: A task pod inherits an app's runtime env/secret via `envFrom`, and its logs appear in VictoriaLogs/Grafana; findings + verified YAML recorded.
- [x] EP-50: `Nagare.Dsl.Task` typed model with smart constructors and `Schedule` validation; JSON round-trip via `emitTask`/`decodeTask`.
- [x] EP-50: `Nagare.Dsl.Task.Render` produces deterministic CronJob/Job YAML; golden tests pass; no existing golden changed.
- [x] EP-51: `nagarectl task list/delete` discover and remove CronJobs by label selector.
- [x] EP-51: `nagarectl task run` fires a one-off Job and waits; `nagarectl task logs` streams pod logs; deploy-time provisioning of declared CronJobs is implemented in EP-52 (which owns the `Deployment.tasks` field — see Surprises).
- [x] EP-52: `Deployment`/`Task` carry the app association; deploy-time resolution injects the app's image tag and `envFrom` managed env/secret; predefined task vars injected.
- [x] EP-53: `docs/user/scheduled-tasks.md` written and cross-linked; runnable `cluster/examples/` task examples (heartbeat-task, app-cleanup-task); VictoriaLogs/Grafana logs walkthrough with the EP-49-verified query; runbook deliberately untouched (host-ops only).


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- **EP-49 spike verified the whole substrate on k3s `v1.35.4+k3s1` (2026-06-10); the backup
  CronJob shape generalizes verbatim.** Scheduled run, one-off `--from=cronjob` run + `kubectl
  wait` + label-selector logs, `envFrom` env/secret inheritance with `optional: true`, image
  inheritance, and all batch semantics (`concurrencyPolicy: Forbid`, `backoffLimit`,
  `restartPolicy: Never`, history limits, `activeDeadlineSeconds`) behaved as documented. The
  later plans (EP-50/51/52/53) encode the verified YAML/commands recorded in EP-49's
  "Interfaces and Dependencies"; none need to guess.
- **Discovery affecting EP-51/EP-53 (observability is better than assumed).** The VictoriaLogs
  collector promotes pod labels to queryable stream fields, so a task's history has a precise
  LogsQL query `{kubernetes.pod_namespace="<ns>"} kubernetes.pod_labels.nagare.dev/task:="<task>"`
  (not just the `pod_name:"nagare-task-<task>"` prefix fallback). EP-51's Grafana hint and
  EP-53's docs should use the label-scoped form.
- **Provisioning is deploy-time co-location only (surfaced in EP-53).** There is no
  standalone-task provisioning command: a `Task` reaches the cluster by being co-located in an
  app's `Deployment.tasks` list and applied by `nagarectl deploy` (`deploy -f <task-config>`
  rejects a `"kind":"Task"` with `UnexpectedKind`). The `nagarectl task` verbs only *operate*
  CronJobs `deploy` already provisioned. Consequence: EP-53's examples are apps-with-co-located
  tasks, and the user guide documents co-location as *the* provisioning path. A follow-up could
  add a `nagarectl task apply -f` for truly standalone tasks, but it was not in scope.
- **Task images are always tag-resolved at deploy (surfaced in EP-53).** EP-52 appends the
  deploy tag to an explicit task image and gives an inheriting task the app's resolved tag, so a
  public fixed-tag image (e.g. `curlimages/curl`) doesn't fit — the examples use inheriting
  tasks running the app's Nagare-built image.
- **`grafanaHint` corrected to the EP-49-verified field (in EP-53).** EP-51's hint emitted
  `{nagare_dev_task="<task>"}`, but the spike verified the collector exposes the label as the
  stream field `kubernetes.pod_labels.nagare.dev/task`. EP-53's reconciliation fixed
  `Nagare.Task.Logs.grafanaHint` (and its test) to emit
  `kubernetes.pod_labels.nagare.dev/task:="<task>"`, matching the docs.

- **Discovery affecting EP-51 (status parsing).** Modern Kubernetes adds a `FailureTarget`
  condition before `Failed` on a failing Job, so `status.conditions[0].type` may be
  `FailureTarget`. EP-51 must parse Job status by condition *type* (scan for `Complete`/`Failed`)
  or rely on `kubectl wait --for=condition=complete|failed`, never read `conditions[0]`.
  Separately, `kubectl get cronjob` now prints a `TIMEZONE` column, so EP-51 should discover via
  `-o json`/`-o jsonpath` (as `Database/Discover.hs` does) rather than parsing table columns.
  Both honoured: EP-51 discovers with `kubectl get cronjob -o json` and runs `kubectl wait
  --for=condition=complete`.

- **Ownership reconciliation — `Deployment.tasks` belongs to EP-52, not EP-50; EP-51 M3 moves
  to EP-52.** EP-51's plan text assumed EP-50 would add a `tasks :: [Task]` field to the
  `Deployment` record for deploy-time provisioning. It does not: EP-50 shipped `Nagare.Dsl.Task`
  as a standalone model/renderer and left `Deployment` untouched. EP-52's M1 actually adds the
  field, *and* EP-52 owns the resolved `runDeploy` wiring (image-tag + `envFrom` injection +
  predefined task vars). Decision: EP-51 ships M1+M2 (the four operational CLI verbs, which do
  not touch the field) and EP-51's M3 (deploy-time provisioning) is implemented **once, in
  EP-52**, against the field EP-52 introduces — avoiding a naive render-and-apply in EP-51 that
  EP-52 would immediately rewrite. EP-51 stays In Progress until EP-52's provisioning lands;
  then both complete together. This mirrors the EP-50/EP-52 "shape vs. semantics" split already
  recorded in the Decision Log.


## Decision Log

- Decision: Decompose into five child plans (spike, typed model + renderer, CLI +
  provisioning, app-association/inheritance, docs) rather than one ExecPlan or a CronJob/Job
  split.
  Rationale: The work spans the pure DSL package, the CLI package, the app deploy path,
  golden tests, and docs — with a live-cluster feasibility risk worth isolating in a spike.
  This mirrors the decomposition that succeeded for MasterPlan 9 (managed databases). The
  roadmap explicitly permits "a small MasterPlan."
  Date: 2026-06-10

- Decision: Treat scheduled CronJobs and one-off Jobs as two operations over one typed model
  and one rendered template, not as two units of decomposition.
  Rationale: Splitting them would force two plans to define the same Pod template and labels
  identically — the cross-plan coupling the decomposition principles forbid. The CronJob's
  `spec.jobTemplate.spec` *is* the one-off Job; `task run` reuses it via `kubectl create job
  --from=cronjob`.
  Date: 2026-06-10

- Decision: Keep the typed model/renderer (EP-50) free of any hard cluster dependency; let
  it soft-depend on the spike (EP-49) only for shape-matching.
  Rationale: The renderer is pure and golden-testable offline. Isolating cluster-aware
  concerns (image-tag resolution, live apply) in EP-51/EP-52 keeps EP-50 deterministic and
  fast to verify, exactly as EP-44 was kept pure relative to EP-43 in MasterPlan 9.
  Date: 2026-06-10

- Decision: Split app↔task association and inheritance into its own plan (EP-52), separate
  from both the model (EP-50) and the CLI (EP-51).
  Rationale: It touches a different code path — the app deploy path and the `Deployment`
  type — and resolves deploy-time values (the app's pushed image tag, managed resource
  names). This is the precise parallel of MasterPlan 9's EP-46 (app DB connection-env
  injection), separated from the database CLI EP-45 for the same reason.
  Date: 2026-06-10

- Decision: Reuse, but do not refactor, the existing managed-database backup CronJob
  machinery (`Nagare.Database.Backup`).
  Rationale: That code is the proven prior art for CronJob/Job rendering and is the reference
  the new renderer follows, but rewiring it onto the new `Task` type is risk without user
  value for this initiative. Recorded as a possible future cleanup, not a deliverable.
  Date: 2026-06-10

- Decision: Do not build new observability; rely on the existing VictoriaLogs/Grafana stack
  for task history, with `task logs` (kubectl) for recent logs and a documented Grafana
  walkthrough.
  Rationale: Task pods are already scraped by the cluster logging stack, so a dedicated
  observability plan would be too thin. The work folds into the CLI plan (EP-51, `task logs`)
  and the docs plan (EP-53, the walkthrough).
  Date: 2026-06-10

- Decision: The `Task` carries the app reference field in EP-50's model (so the type
  compiles and round-trips), but EP-52 owns the *semantics* of that field (deploy-time image
  and env/secret resolution).
  Rationale: Keeps the model self-consistent and golden-testable in EP-50 while letting the
  cluster-aware resolution live in the plan that owns the app deploy path. Documented as IP1
  (shape) versus IP5 (semantics) so the two plans cannot drift.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

**All five child plans are Complete (2026-06-10).** Against the original Vision & Scope, the
user-visible win landed: the most common "cron job" need is now a typed, validated declaration
plus a CLI, with the same safety/determinism guarantees as the rest of Nagare.

What shipped, mapped to the Vision's promises:

- **Declare a `Task` in `Config.hs` and have `nagarectl deploy` provision a CronJob.** ✅ via
  EP-50's typed `Task` model + renderer and EP-52's `Deployment.tasks` co-location + deploy-time
  provisioning. (Refinement vs. the Vision's wording: provisioning is by *co-locating* the task
  in an app's config, not deploying a standalone task file — see Surprises.)
- **`nagarectl task list/run/logs/delete`.** ✅ via EP-51 (five `Nagare.Task.*` modules + the
  `task` subparser). One-off runs use the EP-49-verified `kubectl create job --from=cronjob`.
- **Run "in an app's world" — inherited image + runtime env/secrets.** ✅ via EP-52
  (`resolveTaskImage`, the `envFrom` inheritance, the `nagare.dev/app` label, and the predefined
  `NAGARE_TASK_NAME`/`NAGARE_NAMESPACE`/`NAGARE_APP`/`NAGARE_RUN_ID` vars).
- **Logs via `task logs` + Grafana/VictoriaLogs history.** ✅ via EP-51's `task logs` and the
  EP-49-verified LogsQL query, documented by EP-53.
- **Golden tests, offline unit tests, a user guide, runnable examples.** ✅ — `nagare-dsl` (235
  tests incl. task model/renderer/round-trip goldens) and `nagarectl` (226 tests incl. discovery
  parse, run/logs arg vectors, resolve + resolved-render golden) both green; `docs/user/scheduled-tasks.md`
  plus `cluster/examples/heartbeat-task` and `app-cleanup-task`.

Decomposition retrospective: the five-plan split held up. The spike (EP-49) paid for itself —
its findings (the `FailureTarget` condition, the promoted pod-label stream field, the verified
`--from=cronjob` flow) directly shaped EP-51/EP-52/EP-53 and caught the `grafanaHint` query bug.
The "shape vs. semantics" split (EP-50 owns the typed shape + pure renderer; EP-52 owns
deploy-time value resolution) worked cleanly, enabled by two additive EP-50 exports
(`cronJobValue`/`encodeCronJob`) so EP-52 patches the rendered `Value` without duplicating the
manifest shape. The one cross-plan reconciliation cost was the `Deployment.tasks` field
ownership: EP-51's plan assumed EP-50 added it, but it is EP-52's; resolved by deferring EP-51's
M3 (deploy provisioning) into EP-52, which owns the field — a single render-and-apply call site,
no duplicate loop.

Gaps / follow-ups (none block the initiative): (1) every live on-cluster leg
(`deploy`/`task run`/`task logs` against `nagare-01`) was once deferred-with-instructions per the
EP-48 precedent — **now EXECUTED and VERIFIED live on 2026-06-10**: `nagarectl deploy` of an app with
a co-located task provisioned both the Knative Service and `cronjob.batch/nagare-task-heartbeat`
(`*/15 * * * *`) in one pass; `task list` (global + app-scoped) showed it; `task run heartbeat-app
heartbeat` created a one-off Job from the CronJob and ran it to completion; `task logs` returned the
task's real `date -u` output (`Wed Jun 10 23:11:56 UTC 2026`) plus the VictoriaLogs/Grafana history
hint; `task delete` removed the CronJob. (The live deploy used a prebuilt public image so the proof is
independent of the in-flight image-ref build work.) The offline unit/golden/dry-run proofs plus the
EP-49 live spike already covered behavior;
(2) a `nagarectl task apply -f` for truly standalone (non-co-located) tasks is a possible
follow-up; (3) the per-task run-history ConfigMap remains a documented, unimplemented extension
point (EP-51 Decision Log); (4) refactoring `Nagare.Database.Backup` onto the new `Task` type
remains the explicitly-deferred future cleanup recorded in the Decision Log.
