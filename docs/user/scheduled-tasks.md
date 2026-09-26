---
type: Guide
title: "Scheduled tasks"
description: "Declare, deploy, run, observe, and troubleshoot scheduled application tasks on Nagare."
docId: DOC-31
tags: [scheduled-tasks, cronjobs, workloads, operations]
generated:
  by: human:nadeem
  at: 2026-06-19T14:49:44Z
---

# Scheduled tasks

> 🟡 **In progress.** Built and offline-verified — the typed `Task` model, the
> CronJob renderer, the `nagarectl task` command group, and app↔task image/env
> inheritance all ship and are covered by unit and golden tests. A reviewed
> one-off Job run is available for accepted CronJobs. An app config
> that co-locates a task emits valid JSON and renders a `nagare-task-<name>`
> CronJob via `nagarectl deploy --dry-run`. The full **live** end-to-end run
> (apply the CronJob, run a Job, stream logs) is pending because
> `nagare-01` is often `TERMINATED`; the exact on-VM commands are below.

For **app developers** who need to run work **on a schedule** (a nightly cleanup,
an hourly sync) or **once, on demand** (a one-off migration). You declare a typed
`Task` — a name, a validated cron schedule, and a command — in the same
`nagare/Config.hs` you already use for an app; `nagarectl deploy` provisions a
Kubernetes **CronJob** for it, and you operate it with a new `nagarectl task`
command group.

A scheduled task is **not** an app `Deployment` and **not** a Knative Service. It
is a `Task` value that renders a CronJob named `nagare-task-<name>`, provisioned at
deploy time and operated through `nagarectl task`.


## The smallest thing that works

A task is provisioned by **co-locating it in an app's config** — you add it to the
app's `tasks` list and `nagarectl deploy` applies the app and its task in one pass.
The `scheduledTask` preset builds a task from four values — name, schedule, image,
command:

```haskell
-- nagare/Config.hs — an app that also runs a scheduled task.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task (scheduledTask)
import Nagare.Dsl.Types (Deployment (..))

deployment :: Either String Deployment
deployment = first show $ do
  dep  <- webService "notes" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
  task <- scheduledTask "heartbeat" "*/15 * * * *"
            "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes" "date -u"
  pure dep {tasks = [task]}

main :: IO ()
main = either (ioError . userError) emitDeployment deployment
```

```bash
# Provision the app and its CronJob in one pass:
nagarectl deploy -f nagare/Config.hs

# See it, run it once now, and read the logs:
nagarectl task list
nagarectl task run notes heartbeat --run-id heartbeat-001
nagarectl task logs notes heartbeat
```

> A task carries an optional **app association** (the `taskApp` field), which
> controls managed runtime `envFrom` and `NAGARE_APP`; `taskImage = Nothing`
> selects the app's deployed image. The `scheduledTask` preset
> leaves it unset. A task co-located in the `notes` application is still deployed
> with the `notes` ownership label, so address it as `nagarectl task run notes
> heartbeat --run-id ID`. Use the `-` sentinel only for a task deployed without an app label.


## Concepts

- A **scheduled task** is a named unit of work Nagare runs on a cron schedule,
  declared as a typed `Task` (name, namespace, schedule, image, command/args, env,
  resources, timeout, concurrency/restart/backoff policy, history limits, and an
  optional app reference).
- A **CronJob** is the Kubernetes object that, on a cron schedule, creates a
  **Job**, which runs a **Pod** to completion. Nagare names it `nagare-task-<name>`.
- A **one-off run** is a single Job derived from the accepted CronJob's saved
  native template with a stable run ID, bypassing the schedule.
- The **cron schedule** is a validated 5-field expression
  (`minute hour day-of-month month day-of-week`), e.g. `0 3 * * *` ("daily at
  03:00"). A malformed schedule is rejected at load with a precise message. Each
  field accepts `*`, a number in range, an `a-b` range, a comma list, or an `*/n`
  step; named months/days (`JAN`, `MON`) and `@daily`-style macros are **not**
  accepted, so the one rendered form is unambiguous.
- **Concurrency policy** decides what happens if a run is still going when the next
  is due: `Forbid` (the default — skip the new run), `Allow` (run both), or
  `Replace` (cancel the running one). **Backoff limit** is how many times a failed
  Job is retried before it is marked failed (default 0). **Timeout**
  (`taskTimeoutSeconds`) is a hard wall-clock limit on a run, rendered as
  `activeDeadlineSeconds`. **History limits** keep the last N successful (default 3)
  and failed (default 1) Jobs for inspection.
- The **app association** lets a task run "in an app's world": it inherits the app's
  deployed image and runtime env/secrets and carries the `nagare.dev/app` label. See
  "Running in an app's world" below.

> **Three hard constraints, up front.**
> - **Single-node, single-completion.** Each task is one Job that runs one pod to
>   completion. No fan-out, no parallelism, no multi-node scheduling — this is the
>   deliberate single-node design the whole PaaS accepts.
> - **Cron-only plus manual `task run`.** Tasks fire on their cron schedule or when
>   you run `nagarectl task run`. There are no event or webhook triggers.
> - **`task run` is not a shell.** It runs a *declared* task once; it is not an
>   interactive session. For an interactive database session use `nagarectl db shell`.


## Declaring a task in `Config.hs`

A task is typed and validated at load time — a bad name, a malformed cron string, a
negative backoff, or a task with neither a command nor an inheriting app is rejected
with a precise message. You declare tasks in an app's `tasks` list. For the common
case use the `scheduledTask` preset (name, schedule, image, command):

```haskell
scheduledTask :: Text -> Text -> Text -> Text -> Either Text Task
-- e.g.
scheduledTask "nightly-report" "30 2 * * *"
  "us-west1-docker.pkg.dev/tan-nb-exp/nagare/reporter" "python report.py"
```

For full control — args, inline env, resources, timeout, the batch policies, or an
app reference — build the record directly. Every constrained field goes through a
smart constructor:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Bifunctor (first)
import Data.Map qualified as Map
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task
  ( Task (..), ConcurrencyPolicy (..), RestartPolicy (..), mkSchedule, mkTask )
import Nagare.Dsl.Types
  ( Deployment (..), EnvVar (EnvLiteral), mkEnvName, mkImageRef, mkNamespace
  , mkServiceName, runtimeScoped )

deployment :: Either String Deployment
deployment = first show $ do
  dep   <- webService "notes" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
  n     <- mkServiceName "cleanup"
  ns    <- mkNamespace "personal"
  sched <- mkSchedule "0 3 * * *"          -- daily at 03:00
  img   <- mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
  dry   <- mkEnvName "DRY_RUN"
  task  <- mkTask Task
    { taskName        = n
    , taskNamespace   = ns
    , taskSchedule    = sched
    , taskImage       = Just img          -- an explicit image (Nothing = inherit the app's)
    , taskApp         = Nothing
    , taskCommand     = ["python", "manage.py", "cleanup"]
    , taskArgs        = []
    , taskEnv         = Map.fromList [(dry, runtimeScoped (EnvLiteral "false"))]
    , taskResources   = Nothing
    , taskTimeoutSeconds = Just 600          -- kill a run after 10 minutes
    , taskConcurrencyPolicy = Forbid
    , taskRestartPolicy     = Never
    , taskBackoffLimit      = 0
    , taskSuccessfulJobsHistoryLimit = 3
    , taskFailedJobsHistoryLimit     = 1
    , taskStartingDeadlineSeconds    = Nothing
    }
  pure dep {tasks = [task]}

main :: IO ()
main = either (ioError . userError) emitDeployment deployment
```

Only `Runtime`-scoped inline env renders into the container (build-only vars are
dropped, exactly as for an app). `taskImage = Nothing` means "inherit the app's
image" and is only valid when `taskApp = Just _`. The image is always **tagged at
deploy time**: an explicit task image becomes `<repo>:<deploy-tag>` (the same
release tag the app gets this run), and an inheriting task gets the app's resolved
`<repo>:<tag>` verbatim — so task images are as reproducible as app images, and a
public fixed-tag image is not a fit (use the app's built image).


## Operating with `nagarectl task`

```text
nagarectl task list [APP]        # table of tasks (omit APP for all; "-" for app-less)
nagarectl task run APP TASK --dry-run  # read-only legacy command preview
nagarectl task run APP TASK --run-id ID  # review and apply an accepted task's Job
nagarectl task run APP TASK --run-id ID --save-plan DIR  # review an accepted task's one-off Job
nagarectl task logs APP TASK     # most recent pod logs (--follow to tail; --tail N)
nagarectl task delete APP TASK   # read-only preview of retirement stages
nagarectl task delete APP TASK --save-plan DIR  # next reviewed deletion stage
```

Tasks are discovered by label — `nagare.dev/managed-by=nagarectl,nagare.dev/task`
(narrowed by `nagare.dev/app` when you pass an `APP`) — never by guessing names, so
`task list` always reflects exactly what was provisioned. For `run`/`logs`/`delete`,
`APP` is required: pass the app name for an app-associated task, or the `-` sentinel
for an app-less one.

```text
$ nagarectl task list -n personal
  NAME              APP            SCHEDULE        LAST RUN              LAST SUCCESS          ACTIVE
  cleanup           notes          0 3 * * *       2026-06-10T03:00:00Z  2026-06-10T03:00:12Z  0
  heartbeat         -              */15 * * * *    2026-06-10T17:15:00Z  2026-06-10T17:15:01Z  0
```

`nagarectl task run APP TASK --run-id ID` fires an accepted task once through
a reviewed Job and records completion. `--dry-run` without a run ID prints the
older kubectl command shape without creating a Job.

For a CronJob already accepted in the resource inventory, run it with a stable ID.
The command saves an immutable review in the context's inventory store, displays
the proposed operation, and applies that same review:

```bash
nagarectl task run notes cleanup --run-id cleanup-20260924
```

To inspect the review before a separate apply, save it to a directory:

```bash
nagarectl task run notes cleanup --run-id cleanup-20260924 --save-plan ./task-run-review
nagarectl inventory apply ./task-run-review --yes
```

The Job has an independent scope and the name
`nagare-task-cleanup-manual-cleanup-20260924`. Reusing the same run ID targets
that identity; it cannot silently submit another Job. Longer task and run IDs
use a deterministic digest in the Job name while the full run ID remains in its
scope identity. Planning reads the exact
accepted CronJob template from private inventory evidence and refuses an
unaccepted or differently labeled task. Pass `-` as `APP` only when the accepted
CronJob has no app label. The review binds creation and waits for
Job completion; an uncertain effect needs inventory recovery before retry.
`--dry-run` cannot be combined with `--run-id` or `--save-plan`; use
`--save-plan` to inspect a reviewed run. Pre-deploy migration hooks use
independent per-tag reviewed Jobs as described in [Deploying apps](deploying-apps.md).

Every live run requires `--run-id` and an accepted CronJob, even in a fresh
context. The timestamped command remains only as read-only `--dry-run` output.

```text
$ nagarectl task run notes cleanup --dry-run
--- task run (dry-run) ---
kubectl create job nagare-task-cleanup-manual-<timestamp> --from=cronjob/nagare-task-cleanup -n personal
Then: kubectl wait --for=condition=complete --timeout=600s job/nagare-task-cleanup-manual-<timestamp> -n personal
```

`nagarectl task delete APP TASK` without `--save-plan` previews the stages and
changes nothing:

```text
$ nagarectl task delete notes cleanup
Would review CronJob suspension, retention, and conditional collection:
  cronjob/nagare-task-cleanup
Run task delete --save-plan DIR, apply it, and repeat for each stage.
```

Live `task delete --yes` refuses in every context. Delete an accepted schedule
through three saved reviews, applying each before planning
the next:

```text
nagarectl task delete notes cleanup --save-plan ./task-suspend-review
nagarectl inventory apply ./task-suspend-review --yes
nagarectl task delete notes cleanup --save-plan ./task-retain-review
nagarectl inventory apply ./task-retain-review --yes
nagarectl task delete notes cleanup --save-plan ./task-collect-review
nagarectl inventory apply ./task-collect-review --yes
```

The first review sets the accepted CronJob's `spec.suspend` to `true`, stopping
future scheduled runs. The second removes that CronJob from desired intent and
retains its exact live identity while the application's other members stay
accepted. The third conditionally deletes that retained CronJob by its observed
identity. A retry of `--save-plan` selects the next stage from accepted history.
Existing Jobs and any legacy run-history ConfigMap are separate objects and are
not deleted by this sequence. A Job that still depends on the CronJob may need
its own reviewed retirement before the schedule can retire. The plan-only form
and `--dry-run` remain read-only.


## Running in an app's world

A task can run **in an app's world**: set `taskApp = Just "<app>"` (and leave
`taskImage = Nothing` to inherit the app's image), and co-locate it in that app's
`tasks` list. At deploy time the rendered Job template uses the app's deployed image
tag and adds an `envFrom` block importing the app's managed runtime ConfigMap and
Secret, so the task sees the same environment — including any injected `DATABASE_URL`
— as the app itself. The CronJob and its pods carry the `nagare.dev/app: <app>`
label, so `nagarectl task list <app>` scopes to that app's tasks.

The task container's environment is composed from three layers:

| Layer | Source | Wins over |
| --- | --- | --- |
| Inherited app env | `envFrom` the app's `nagare-env-<app>-runtime` ConfigMap and `nagare-secret-<app>-runtime` Secret (each `optional: true`) | (base) |
| Task inline env | the task's own `taskEnv` (Runtime-scoped) | inherited app env |
| Predefined task vars | `NAGARE_TASK_NAME`, `NAGARE_NAMESPACE`, `NAGARE_APP` (when associated), `NAGARE_RUN_ID` | set by the platform |

The predefined variables, set by Nagare on every task run:

| Variable | Value |
| --- | --- |
| `NAGARE_TASK_NAME` | the task name (e.g. `cleanup`) |
| `NAGARE_NAMESPACE` | the task's namespace (e.g. `personal`) |
| `NAGARE_APP` | the associated app name; absent for app-less tasks |
| `NAGARE_RUN_ID` | the pod's own name (a Kubernetes Downward-API `fieldRef` to `metadata.name`), unique per run — so a scheduled run and a one-off `task run` are distinguishable in logs |

The precedence rule follows Kubernetes' native `envFrom`-before-`env` ordering:
**inherited app env is the base; the task's own inline env overrides any same-named
inherited variable; the predefined `NAGARE_*` variables are always set** (the
`NAGARE_*` prefix is reserved, so they never collide with an app's keys). An app and
its task share a namespace (the default `personal`) for the inherited
ConfigMap/Secret references to resolve.

> The inherited references are `optional: true`, so a task associated with an app
> that has no managed env/secret yet still starts — it just sees no inherited
> variables until the app is deployed with env. To run scheduled maintenance against
> a managed database, declare the task on the app that
> [references the database](managed-databases.md): the task inherits the app's
> injected `DATABASE_URL` and reaches the same database.


## Logs & observability

`nagarectl task logs APP TASK` shows the most recent run's pod logs; add `--follow`
to tail a running one and `--tail N` to limit the lines. It selects pods by the
`nagare.dev/task=<task>` label (narrowed by app), so it always finds the right pods:

```text
$ nagarectl task logs notes cleanup
<the cleanup pod's most recent output>
For older runs, query VictoriaLogs in Grafana with: kubernetes.pod_labels.nagare.dev/task:="cleanup"
```

Task pods are ordinary Kubernetes pods, so the cluster's existing log collector
scrapes them automatically — no new wiring. For **history** beyond the most recent
run (every run a task has ever made, including ones whose Jobs have aged out of the
CronJob's history limit), open Grafana's Explore view on the VictoriaLogs data
source and run the LogsQL query the substrate spike verified on the live cluster:

```text
kubernetes.pod_labels.nagare.dev/task:="cleanup"
```

To scope to one namespace, combine it with the namespace stream field:

```text
{kubernetes.pod_namespace="personal"} kubernetes.pod_labels.nagare.dev/task:="cleanup"
```

The collector promotes pod labels to queryable stream fields, so a task's
`nagare.dev/task` label is available as `kubernetes.pod_labels.nagare.dev/task`
(the namespace field is `kubernetes.pod_namespace`). See
[Observability](observability.md) for how to reach Grafana and the VictoriaLogs data
source.


## Constraints and limits

- **Single-node, single-completion.** Each task is one Job that runs one pod to
  completion. No fan-out, no parallelism beyond a single completion, no task queues,
  no multi-node scheduling. This is the deliberate single-node design.
- **Provisioned by deploy-time co-location.** A task is applied by co-locating it in
  an app's `tasks` list and running `nagarectl deploy`. There is no separate
  "apply a standalone task" command; the `nagarectl task` verbs operate tasks that
  `deploy` already provisioned.
- **Cron-only plus manual `task run`.** Tasks fire on their cron schedule or when you
  run `nagarectl task run`. There are no event-driven or webhook triggers (those
  belong to the future Control-Plane API).
- **`task run` is not an interactive shell.** It runs a declared task once. For an
  interactive database session use `nagarectl db shell` (see
  [Managed databases](managed-databases.md)).
- **Out of scope:** event/webhook triggers, parallel/fan-out Jobs, and changing the
  managed-database backup CronJob (that machinery stays as-is).


## Worked examples

Two runnable examples live under `cluster/examples/`:

- **[`heartbeat-task`](../../cluster/examples/heartbeat-task/)** — a minimal app that
  co-locates an inheriting `heartbeat` task printing the UTC time every 15 minutes.
  The smallest co-located task; renders fully offline via `deploy --dry-run`.
- **[`app-cleanup-task`](../../cluster/examples/app-cleanup-task/)** — the
  `postgres-app` app co-locating an inheriting `cleanup` task that reaches the same
  database (via the inherited `DATABASE_URL`) on a nightly schedule. Also shows the
  one-off run via `nagarectl task run`.

Each example's `README.md` walks through declare → deploy → `task list`/`task
run`/`task logs`, with the offline `runghc`/`--dry-run` checks and the on-VM live
commands.
