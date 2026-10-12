---
id: 51
slug: nagarectl-task-lifecycle-commands-and-deploy-time-provisioning
title: "nagarectl task lifecycle commands and deploy-time provisioning"
kind: exec-plan
created_at: 2026-06-10T16:50:01Z
intention: "intention_01kts6qyg4ezsbj500ksjr90r1"
master_plan: "docs/masterplans/10-scheduled-tasks-for-nagare.md"
---

# nagarectl task lifecycle commands and deploy-time provisioning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare is a small "personal platform-as-a-service" (PaaS): a command-line tool named
`nagarectl` that takes a typed Haskell configuration file and turns it into running
things on a single Kubernetes cluster (web apps, static sites, and managed databases).
A "scheduled task" is the one common PaaS feature Nagare is missing today: a named unit
of work that runs *on a cron schedule* (for example "every night at 03:00") or *once,
right now, on demand*. In Kubernetes terms a scheduled task is a **CronJob** (an object
that creates a **Job** on a schedule; a Job runs one or more **Pods** to completion), and
a one-off run is a single **Job** created immediately from that CronJob's template.

After this ExecPlan, a person operating Nagare can run four new commands:

- `nagarectl task list [APP]` — show every scheduled task (optionally only those attached
  to one app), with its cron schedule, the app it belongs to, when it last ran, when it
  last succeeded, and whether a run is currently active.
- `nagarectl task run APP TASK` — fire a task **once, right now**, wait for it to finish,
  stream its logs, and report success or failure — without waiting for the next scheduled
  time. `--dry-run` prints the exact `kubectl` command instead of running it.
- `nagarectl task logs APP TASK` — show the most recent run's pod logs (and follow a
  running one with `--follow`), plus a one-line hint pointing at the cluster's
  Grafana/VictoriaLogs history.
- `nagarectl task delete APP TASK` — remove the task's CronJob (idempotently).

Additionally, when a configuration file declares scheduled tasks, `nagarectl deploy`
**provisions** them: it renders each declared task into a CronJob and applies it to the
cluster in the same pass that applies the app's Knative Service, its volumes, and its
databases. `nagarectl deploy --dry-run` prints the rendered CronJob manifest so the
operator can review it before applying.

You can see it working end-to-end like this: declare a task in `Config.hs`, run
`nagarectl deploy` (the CronJob appears in the cluster), run `nagarectl task list` (the
task is listed), run `nagarectl task run APP TASK` (a Job runs once and its logs stream to
your terminal), then `nagarectl task delete APP TASK` (the CronJob is gone). The offline
unit tests prove the pure helpers — the label selector strings, the deterministic one-off
Job name, and the CronJob-list JSON parser — without needing a cluster at all.

This plan **owns** two integration points from the parent MasterPlan
(`docs/masterplans/10-scheduled-tasks-for-nagare.md`): IP4 (the `nagarectl task`
command-group plumbing) and IP6 (the one-off run plus the logs/observability contract).
It **consumes** the contracts produced by `docs/plans/50-typed-task-model-and-cronjob-job-renderer.md`
(EP-50, a hard dependency): the typed `Task` value, the function that renders a `Task`
into a CronJob, and the naming/label convention (the CronJob is named `nagare-task-<name>`
and every rendered object carries the labels `nagare.dev/managed-by=nagarectl`,
`nagare.dev/task=<name>`, and — when the task belongs to an app — `nagare.dev/app=<app>`).
The actual *association* of a task with an app (resolving the app's image and runtime
environment) is owned by `docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md`
(EP-52); this plan simply applies whatever EP-50's renderer produces and discovers
whatever labels are present.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone M1 — `task list` / `task delete` + `Nagare.Task.Discover`:

- [x] Create `cli/nagarectl/src/Nagare/Task/Discover.hs` with `taskLabelSelector`,
      `TaskRow (..)`, `extractTaskRows`, `listTasks`, `getTask`, `formatTaskTable`.
- [x] Create `cli/nagarectl/src/Nagare/Task/List.hs` with `runTaskList`.
- [x] Create `cli/nagarectl/src/Nagare/Task/Delete.hs` with `TaskDeleteParams (..)` and
      `runTaskDelete`.
- [x] Add the `TaskCommand` ADT and the `Task` constructor to `Command` in `app/Main.hs`.
- [x] Add `taskCmd`/`taskSubparser`, the option parsers, and the `runTask` dispatcher for
      `list`/`delete` in `app/Main.hs`; wire `Task` into `main` and the top-level subparser.
- [x] Register `Nagare.Task.Discover`, `Nagare.Task.List`, `Nagare.Task.Delete` (and the M2
      modules) in `nagarectl.cabal`.
- [x] Add the captured fixture `cli/nagarectl/test/fixtures/cronjob-list.json` and unit
      tests for `taskLabelSelector`, `extractTaskRows`, `formatTaskTable`.
- [x] `cabal build` and `cabal test nagarectl-test` pass (220 tests); live check deferred
      (workstation kubectl cannot reach the IAP-only cluster; see Surprises).

Milestone M2 — `task run` (one-off) + `task logs`:

- [x] Create `cli/nagarectl/src/Nagare/Task/Run.hs` with `oneOffJobName`, `runArgs`,
      `TaskRunParams (..)`, `runTaskRun`.
- [x] Create `cli/nagarectl/src/Nagare/Task/Logs.hs` with `TaskLogTarget (..)`,
      `taskLogArgs`, `grafanaHint`, `runTaskLogs`.
- [x] Add the `TaskRun`/`TaskLogs` constructors, parsers, and dispatch arms.
- [x] Register `Nagare.Task.Run`, `Nagare.Task.Logs` in `nagarectl.cabal`.
- [x] Unit-test `oneOffJobName` (deterministic given a `UTCTime`), `runArgs`, and
      `taskLogArgs`.
- [x] `cabal test nagarectl-test` passes; captured a fully-offline `task run --dry-run`
      transcript; live run deferred (Surprises).

Milestone M3 — deploy-time provisioning:

- [x] **Implemented in EP-52** (which owns the `Deployment.tasks` field and the resolved
      `runDeploy` wiring). `nagarectl deploy` now renders each declared task's CronJob with the
      inherited image tag + `envFrom` + predefined vars and applies it alongside the
      Service/PVCs/databases (printing it under a `--- Task CronJob manifest ---` banner in
      `--dry-run`). There is exactly one render-and-apply call site, using
      `renderResolvedTask`. The `Deployment.tasks` field is owned by EP-52's M1, not EP-50 as
      this plan originally assumed (see Surprises).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The `Deployment.tasks` field is owned by EP-52, not EP-50.** This plan's M3 context said
  "EP-50 adds the field that carries declared tasks." It does not: EP-50 shipped `Nagare.Dsl.Task`
  as a standalone model and renderer and left `Deployment` untouched. EP-52's M1 (see
  `docs/plans/52-...`, "Add `tasks :: ![Task]` to the `Deployment` record") introduces the
  field, *and* EP-52 wires the resolved task provisioning (image-tag + envFrom) into
  `runDeploy`. Consequence: M3 here is deferred to EP-52 to avoid implementing a naive
  render-and-apply that EP-52 would immediately rewrite. M1/M2 are independent of the field and
  shipped fully. Recorded in the MasterPlan Surprises too.
- **`--dry-run` for `task run` is now fully offline.** The plan's `runTaskRun` skeleton called
  `getTask` (which shells `kubectl`) *before* the dry-run branch, contradicting the plan's own
  acceptance criterion that `task run ... --dry-run` "contacts no cluster." Resolved by checking
  `trpDryRun` first: in dry-run we build and print the `kubectl create job ... --from=cronjob`
  command (and the follow-up `wait`) without any cluster call; the existence check runs only on
  a live run. Evidence: `nagarectl task run notes cleanup --dry-run` prints
  `kubectl create job nagare-task-cleanup-manual-<ts> --from=cronjob/nagare-task-cleanup -n personal`
  with no kubectl context configured.
- **Opts-record field-prefix collision.** The plan reused the `tlo` field prefix for *both*
  `TaskListOpts` and `TaskLogsOpts`. With `DuplicateRecordFields` on but no `OverloadedRecordDot`,
  selector *use* (`tloApp o`) is ambiguous. Renamed to unique prefixes: `TaskListOpts` →
  `tls*`, `TaskLogsOpts` → `tlg*` (mirroring the db code's distinct `dblo`/`dbn`/`dbd`
  prefixes). `TaskRunOpts` (`tro*`) and `TaskDeleteOpts` (`tdo*`) were already unique.
- **`tShow` is a private helper in `app/Main.hs`, not exported.** `Nagare.Task.Discover`
  defines its own local `tShow = T.pack . show` (the one place it is needed,
  `formatTaskTable`), exactly as the plan's fallback note anticipated.
- **Live check deferred (EP-48 precedent).** `nagarectl` shells `kubectl` against the active
  context, but the `tan-nb-exp` k3s API is reachable only on the VM (IAP forwards SSH only).
  The offline unit suite (220 tests) plus the offline `--dry-run`/`--help` transcripts are the
  acceptance here; the EP-49 spike already proved the exact `kubectl create job --from=cronjob`
  → `wait --for=condition=complete` → `logs -l nagare.dev/task` mechanisms on the live cluster,
  so the CLI's IO paths shell verified commands.

## Decision Log

Record every decision made while working on the plan.

- Decision: `nagarectl task run` creates the one-off Job with `kubectl create job
  <generated-name> --from=cronjob/nagare-task-<task>` rather than re-rendering a Job
  manifest from the typed model.
  Rationale: The CronJob already embeds the exact Job template the scheduled runs use
  (its `spec.jobTemplate.spec`). `kubectl create job --from=cronjob/...` copies that
  template verbatim, so a manual run is byte-for-byte identical to a scheduled run — no
  risk of the CLI and the renderer drifting, and no need for the CLI to depend on the
  renderer at run time. This is the substrate the parent MasterPlan's spike (EP-49)
  verifies on the live cluster, and it mirrors how the managed-database backup feature
  waits on a Job in `cli/nagarectl/src/Nagare/Database/Backup.hs`.
  Date: 2026-06-10

- Decision: Discovery is label-based (`kubectl get cronjob -l
  nagare.dev/managed-by=nagarectl,nagare.dev/task`), never name-derived.
  Rationale: This matches the proven managed-database discovery in
  `cli/nagarectl/src/Nagare/Database/Discover.hs` (which finds StatefulSets by
  `nagare.dev/managed-by=nagarectl,nagare.dev/database`). Querying by label means the CLI
  finds exactly the objects EP-50 stamps, tolerates objects it did not create, and lets
  EP-52 narrow the same query to one app by appending `,nagare.dev/app=<app>` without
  changing any name-construction logic.
  Date: 2026-06-10

- Decision: The `APP` positional scopes discovery by the `nagare.dev/app` label. `task
  list` accepts `APP` as **optional** (omit it to list every task in the namespace);
  `task run`, `task logs`, and `task delete` take `APP` as a required positional that is
  combined with `TASK` into the label selector `nagare.dev/task=<task>,nagare.dev/app=<app>`.
  A task with no app association (its `nagare.dev/app` label unset) is addressed by passing
  the sentinel app name `-` (a single hyphen), which the CLI translates into "match tasks
  with no `nagare.dev/app` label" via the selector term `!nagare.dev/app`.
  Rationale: Keeping `APP` optional for the read-only listing makes the common "show me
  everything" case ergonomic, while requiring it for the mutating/streaming verbs keeps the
  positional argument shape uniform with `nagarectl db <verb> NAME` and with EP-52's app
  scoping. The `-` sentinel gives a deterministic, documented way to reach an app-less task
  without inventing a second command. EP-52 sets the `nagare.dev/app` label; until it ships,
  every task is app-less and reachable via `-`.
  Date: 2026-06-10

- Decision: Per-task run history (a `nagare-task-runs-<name>` ConfigMap) is **optional and
  secondary**; it is not implemented in this plan beyond a documented extension point.
  Rationale: The CronJob's own `status` already records `lastScheduleTime` and
  `lastSuccessfulTime`, and the cluster's existing VictoriaLogs/Grafana stack already
  retains pod logs (the parent MasterPlan explicitly defers new observability). A bespoke
  ConfigMap history would duplicate both with no user-visible win for this plan's scope.
  The pattern (mirroring `cli/nagarectl/src/Nagare/App/Deployments.hs`'s
  `nagare-app-deployments-<name>` ConfigMap) is recorded here so a later plan can add it
  without re-deciding.
  Date: 2026-06-10

- Decision: Deploy-time provisioning applies the rendered task CronJobs in the *same*
  `applyManifests` pass `nagarectl deploy` already uses for the Service and DomainMappings,
  after the PVCs, reusing `Nagare.Deploy.applyManifests`.
  Rationale: `applyManifests` (in `cli/nagarectl/src/Nagare/Deploy.hs`) already writes each
  manifest to a temp file and runs `kubectl apply -f`, which is idempotent. Reusing it keeps
  task provisioning consistent with app/volume/database provisioning and avoids a second
  apply mechanism. EP-50's `renderTask` produces the CronJob bytes; this plan only wires
  them into the existing pass.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome: the four operational `nagarectl task` verbs ship (M1+M2); deploy-time provisioning
moves to EP-52 (M3).** Against the original purpose:

- **`task list [APP]`, `task run APP TASK`, `task logs APP TASK`, `task delete APP TASK`** are
  registered (`nagarectl task --help` lists all four) and dispatch into five new library
  modules under `Nagare/Task/` (`Discover`, `List`, `Run`, `Logs`, `Delete`). Discovery is
  label-based (`nagare.dev/managed-by=nagarectl,nagare.dev/task`, narrowed by `AppScope`),
  mirroring `Nagare.Database.Discover`. The `-` sentinel reaches app-less tasks via the
  `!nagare.dev/app` selector term.
- **IP4 (the command-group plumbing) and IP6 (one-off run + logs):** `task run` builds a
  deterministic `nagare-task-<task>-manual-<ts>` Job name and shells `kubectl create job
  --from=cronjob/nagare-task-<task>` → `kubectl wait --for=condition=complete` → log-on-failure;
  `task logs` streams pods by the IP3 label and prints a Grafana/VictoriaLogs hint. Both the
  one-off-run command vector and the logs vector match the EP-49-verified mechanisms.
- **Offline proof (220 tests pass):** the three label-selector strings, the CronJob-list JSON
  parser against the checked-in fixture (schedule/app/active-count/last-run read correctly,
  empty-shape `Right []`), the deterministic `oneOffJobName` (lower-cased, ≤63 chars), the
  `runArgs` create-job vector, and the `taskLogArgs` logs vector (app scoping + `--tail`/`--follow`).
  `task run --dry-run` prints the exact command fully offline.

**Gaps / deferred.** M3 (deploy-time provisioning) is implemented in EP-52, which owns the
`Deployment.tasks` field and the resolved `runDeploy` wiring (see Surprises). The live on-VM
check is deferred per the EP-48 precedent (the cluster API is reachable only on the VM); the
offline suite plus the EP-49 spike's live verification of the same kubectl mechanisms cover the
behavior. The optional per-task run-history ConfigMap remains a documented, unimplemented
extension point (Decision Log).

