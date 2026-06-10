---
id: 53
slug: scheduled-tasks-docs-and-end-to-end-examples
title: "Scheduled-tasks docs and end-to-end examples"
kind: exec-plan
created_at: 2026-06-10T16:50:01Z
intention: "intention_01kts6qyg4ezsbj500ksjr90r1"
master_plan: "docs/masterplans/10-scheduled-tasks-for-nagare.md"
---

# Scheduled-tasks docs and end-to-end examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the fifth and final child of the MasterPlan at
`docs/masterplans/10-scheduled-tasks-for-nagare.md` ("Scheduled Tasks for Nagare"). The
scheduled-task *behavior* is built by its sibling plans: the substrate feasibility spike
(`docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md`), the typed
`Task` model and the CronJob/Job renderer
(`docs/plans/50-typed-task-model-and-cronjob-job-renderer.md`), the `nagarectl task`
lifecycle commands and deploy-time provisioning
(`docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md`), and the
app↔task association with runtime env/image/secret inheritance
(`docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md`). This
plan makes that behavior **discoverable and learnable**: it writes the user guide, cross-links
it from the docs index, the deploy guide, and the sibling feature pages, and ships two to three
runnable end-to-end examples under `cluster/examples/` that prove the whole pipeline (declare →
provision → run on a schedule → run once → read logs) works.

This plan **hard-depends** on EP-50 (the typed `Task` model and its renderer), because a docs
plan must document the typed surface that actually exists: the `Task` record, the `Schedule`
newtype and the cron grammar `mkSchedule` accepts, the `scheduledTask` preset, the
`{"kind":"Task"}` JSON shape, and the rendered `nagare-task-<name>` CronJob with its labels. It
**soft-depends** on EP-51 (the `nagarectl task list/run/logs/delete` command group and
deploy-time provisioning) and EP-52 (the app association, the inherited-variable set, and the
precedence rule), because the guide documents the CLI surface and the app-inheritance behavior
and must describe *what actually shipped*. If those plans' final names or output differ from
what is reproduced here from the MasterPlan's Integration Points, reconcile against their final
Interfaces/Concrete-Steps sections before finalizing snippets and transcripts, and record any
divergence in this plan's Decision Log.


## Purpose / Big Picture

Today a Nagare workload is one of: a long-running web app (a Knative Service), a static site,
or a managed database (a StatefulSet). What Nagare cannot yet *teach a developer to do* is run
work **on a schedule** (a nightly cleanup, an hourly sync) or **once, on demand** (a one-off
data migration). The sibling plans (EP-49 through EP-52) build that capability — a typed `Task`
that renders a Kubernetes **CronJob**, a `nagarectl task` command group, and app↔task
inheritance — but a capability nobody can find is a capability that does not exist. This plan is
what turns the shipped machinery into something a developer can use without reading Haskell
source or the plan files.

After this plan, a developer can open a single new page,
`docs/user/scheduled-tasks.md`, and learn the whole story:

- what a *scheduled task* is on this single-node cluster (a Kubernetes **CronJob** that, on a
  cron schedule, creates a **Job**, which runs one or more **Pods** to completion — not an app
  `Deployment`, not a Knative Service), what a *one-off run* is (a single Job created
  immediately from that CronJob's template, bypassing the schedule), and what the cron schedule
  grammar, concurrency policy, backoff limit, execution timeout, and history limits each mean;
- how to declare a `Task` in a typed `nagare/Config.hs` — choosing a name, a validated cron
  `Schedule`, an image (or "inherit the app's image"), a command and args, inline env, and the
  batch policies — using the `scheduledTask` preset for the common case;
- how to operate it with `nagarectl task list/run/logs/delete`, including running it once with
  `nagarectl task run` and viewing its logs with `nagarectl task logs`;
- how a task runs "in an app's world" — the app association, the inherited image and runtime
  env/secrets, the predefined `NAGARE_TASK_NAME`/`NAGARE_RUN_ID` variables, and the precedence
  rule for same-named variables;
- where the task's logs live: `nagarectl task logs` for recent pod output, and the existing
  Grafana/VictoriaLogs stack for history, with the exact LogsQL query;
- and the constraints a reader must know: every task is a **single-node, single-completion Job**
  (no fan-out, no parallelism, no multi-node scheduling), tasks are **cron-only plus manual
  `task run`** (no event or webhook triggers), and `task run` is **not an interactive shell**
  (use `nagarectl db shell` for that).

The proof that the documentation is correct is **two to three runnable end-to-end examples**
under `cluster/examples/`, each with a `nagare/Config.hs` and a `README.md`:

1. **`heartbeat-task`** — a standalone scheduled task with its own image and its own env (a
   periodic `date`/`curl` heartbeat). It demonstrates the smallest typed `Task`, the
   `scheduledTask` preset, and the rendered standalone CronJob — no app involved.
2. **`app-cleanup-task`** — an app-associated scheduled task that inherits an existing example
   app's image and runtime env/secrets (a nightly cleanup that runs inside the `postgres-app`
   example's image and reaches the same database). It demonstrates the app association, the
   inherited-variable set, and the `nagare.dev/app` label.
3. **A one-off run** demonstrated against the `app-cleanup-task` example via `nagarectl task
   run` (no separate directory — it reuses example 2's CronJob), showing
   `kubectl create job --from=cronjob/...` end to end.

You can see this working by following each example README top to bottom against a live cluster:
every command runs and produces the shown output, the scheduled CronJob appears, a one-off run
completes, and its logs stream. Where no cluster is reachable in the implementation environment
— the common case, because `nagare-01` is often `TERMINATED` and IAP forwards only SSH/22 so a
workstation `kubectl`/`nagarectl` cannot reach the k3s API — the examples are still verifiable
offline: every `Config.hs` emits valid `{"kind":"Task"}` JSON via `runghc`, and the live legs
are marked "dry-run verified; live run deferred" with exact on-VM instructions, exactly as the
sibling docs plan `docs/plans/48-managed-databases-docs-and-end-to-end-examples.md` did.

Terms used throughout this plan, defined once here in plain language:

- A **scheduled task** is a named unit of work Nagare runs on a cron schedule. In typed config
  it is a `Task` value (name, namespace, validated cron `Schedule`, image, command/args, env,
  resources, timeout, concurrency/restart/backoff policy, history limits, and an optional app
  reference). It is not an app `Deployment` and not a Knative Service; it is provisioned at
  deploy time and operated through the `nagarectl task` command group.
- A **CronJob** is the standard Kubernetes object that, on a cron schedule (for example
  `0 3 * * *`), creates a **Job**. Nagare names a task's CronJob `nagare-task-<name>`.
- A **Job** is the run-to-completion primitive: unlike a web service it finishes. A task's Job
  is single-completion (one pod runs once).
- A **one-off run** is a single Job created immediately from a task's CronJob template, bypassing
  the schedule, via `kubectl create job --from=cronjob/nagare-task-<name>`. `nagarectl task run`
  does exactly this.
- A **cron schedule** here is a validated 5-field expression (`minute hour day-of-month month
  day-of-week`) — for example `0 3 * * *` ("every day at 03:00"). EP-50's `mkSchedule` validates
  each field; named months/days and `@daily`-style macros are deliberately not accepted.
- The **app association** is the optional reference a task carries to an app (by `ServiceName`).
  When present, the task runs in the app's deployed image and inherits the app's managed runtime
  ConfigMap and Secret via `envFrom`, and its CronJob carries the `nagare.dev/app: <app>` label.
- A **label selector** is the comma-separated `key=value` filter Kubernetes uses to find objects.
  The `nagarectl task` commands discover tasks by
  `nagare.dev/managed-by=nagarectl,nagare.dev/task` (optionally narrowed by `nagare.dev/app`).
- **VictoriaLogs** is the cluster's log store (in the `logging` namespace); **LogsQL** is its
  query language. Task pods are ordinary pods, so the existing collector scrapes their logs with
  no new wiring; history is queryable in Grafana.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone M1 — the scheduled-tasks guide and cross-links:

- [x] Wrote `docs/user/scheduled-tasks.md` (concepts → declaring a `Task` co-located in an
      app's `tasks` list → operating with `nagarectl task` → running in an app's world +
      inherited-variable table + precedence → logs & observability + the verified LogsQL query
      → hard constraints → worked examples), reconciled against the shipped surface.
- [x] Indexed the new page in `docs/user/README.md` (the read-order sub-bullet under item 8
      and the "Area / Plan / Status" table row, both 🟡).
- [x] Linked it from `docs/user/deploying-apps.md` (a "scheduled tasks" pointer) and
      cross-linked `docs/user/managed-databases.md` (run maintenance against a managed DB).
- [x] Verified links resolve and every opening fence carries a language tag.

Milestone M2 — the end-to-end examples (offline-verified):

- [x] Created `cluster/examples/heartbeat-task/` (`nagare/Config.hs` + `README.md`): a minimal
      app co-locating an inheriting `heartbeat` task. Emits a `Deployment` JSON whose `tasks`
      array carries the task; `deploy --dry-run` renders the `nagare-task-heartbeat` CronJob
      **fully offline**.
- [x] Created `cluster/examples/app-cleanup-task/` (`nagare/Config.hs` + `README.md`): the
      `postgres-app` app co-locating an inheriting `cleanup` task. Emits valid JSON via
      `runghc`; `deploy --dry-run` needs a cluster for the DB connection env (noted, like the
      managed-database examples).
- [x] Each README shows declare → deploy → `task list`/`task run`/`task logs`, marking the live
      legs deferred-with-on-VM-commands. **Reshaped from the plan's "standalone task config"
      form** to app-co-located form — the shipped provisioning path (see Surprises).

Milestone M3 — observability/runbook integration + final reconciliation:

- [x] Added the Grafana/VictoriaLogs history walkthrough to `docs/user/scheduled-tasks.md`,
      cross-linking `docs/user/observability.md` and citing EP-49's **verified** LogsQL query
      `kubernetes.pod_labels.nagare.dev/task:="<task>"` (corrected from the plan's
      `{nagare_dev_task="<task>"}` — see Surprises).
- [~] No runbook edit: `docs/runbooks/server-operations.md` is purely host/cluster operations;
      scheduled tasks are an app-developer workload concern covered by the user guide (Decision
      Log).
- [x] Reconciled every command, field, label, and transcript against the shipped state; the
      live legs are deferred with exact on-VM commands. Divergences recorded in Surprises.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **There is no standalone-task provisioning path; tasks are provisioned only by deploy-time
  co-location in an app's `Deployment.tasks` list.** The plan's examples assumed `nagarectl
  deploy -f <standalone-task-config>` provisions a `Task` emitted via `emitTask`. It does not:
  `deploy` loads a `Deployment`, and a standalone Task config (`"kind":"Task"`) fails with
  `nagare: config emitted a 'Task' but 'Deployment' was expected`. The `nagarectl task` verbs
  only *operate* CronJobs that `deploy` already provisioned. Consequence: both examples were
  reshaped from "a standalone `Task` config" to "an app `Deployment` that co-locates the task in
  its `tasks` list" — the actual working path. The guide's "smallest thing that works" and
  "Constraints" sections state this plainly. (`emitTask`/`loadTask` remain a valid typed
  primitive, but co-location is how a task reaches the cluster.)
- **A co-located task's image is always tag-resolved at deploy time, so a public fixed-tag image
  doesn't fit.** EP-52's resolver appends the deploy tag to an explicit task image
  (`<repo>:<tag>`) and gives an inheriting task the app's resolved `<repo>:<tag>`. A public
  image like `curlimages/curl` would become `curlimages/curl:<timestamp>` (nonexistent). So the
  examples use **inheriting** tasks (`taskImage = Nothing`) that run the app's Nagare-built
  image; the guide notes "a public fixed-tag image is not a fit (use the app's built image)."
- **The `task logs` Grafana hint query was wrong; corrected against EP-49.** EP-51's
  `grafanaHint` emitted `{nagare_dev_task="<task>"}`, but the EP-49 spike verified the collector
  exposes the label as the stream field `kubernetes.pod_labels.nagare.dev/task` (not
  `nagare_dev_task`). As part of this plan's reconciliation, `grafanaHint` (and its unit test)
  were fixed to emit `kubernetes.pod_labels.nagare.dev/task:="<task>"`, and the guide documents
  that verified query plus the namespace-scoped form
  `{kubernetes.pod_namespace="<ns>"} kubernetes.pod_labels.nagare.dev/task:="<task>"`.
- **`app-cleanup-task` cannot be `deploy --dry-run`-rendered fully offline** because it
  references the `pg-main` managed database, and Nagare resolves the database connection env at
  deploy time (which needs a reachable cluster) — exactly the limitation the managed-database
  examples (EP-48) note. Its offline proof is the `runghc` JSON emit; the heartbeat example (no
  DB) renders fully offline.
- **A reliable offline `runghc` invocation runs from `cli/nagarectl`**, where `nagare-dsl` is an
  exposed dependency: `( cd cli/nagarectl && cabal exec -- runghc -XGHC2024 -XOverloadedStrings
  <config> )`. Running `runghc -i.../nagare-dsl/src` instead recompiles the DSL without its
  per-module extensions and fails; the example READMEs use the `cabal exec` form.


## Decision Log

Record every decision made while working on the plan.

- Decision: Put the scheduled-task user documentation in a new dedicated page
  `docs/user/scheduled-tasks.md`, mirroring the per-feature guides
  (`docs/user/managed-databases.md`, `docs/user/persistent-storage.md`,
  `docs/user/env-and-secrets.md`) in shape and tone — Concepts → Declaring in `Config.hs` →
  Operating with the CLI → App inheritance → Logs/observability → Hard constraints — rather than
  expanding `docs/user/deploying-apps.md` in place.
  Rationale: scheduled tasks are a focused, sizeable sub-topic (concepts + a typed `Task` field
  group + a four-verb CLI + an app-inheritance contract + a logs/observability story + several
  hard constraints). Every sibling per-feature initiative finished with its own page linked from
  `deploying-apps.md` and the README index; following that convention keeps the docs navigable.
  This is the same decision EP-48 made for managed databases and EP-37 for persistent storage.
  Date: 2026-06-10

- Decision: Ship two example directories plus a one-off-run demonstration that reuses the second
  example, rather than three separate directories. The set is `cluster/examples/heartbeat-task/`
  (a standalone task with its own image and env) and `cluster/examples/app-cleanup-task/` (an
  app-associated task inheriting the existing `postgres-app` example's image and runtime
  env/secrets); the one-off run (`nagarectl task run`) is demonstrated in the `app-cleanup-task`
  README against that example's CronJob.
  Rationale: the MasterPlan's Vision & Scope names "runnable end-to-end examples under
  `cluster/examples/`"; two examples cover the two distinct shapes (standalone vs. app-associated)
  that exercise every load-bearing surface — own-image-and-env, image/env inheritance, the
  `nagare.dev/app` label, and the `--from=cronjob` one-off run. A third standalone directory just
  for `task run` would duplicate a CronJob with no new mental model, so the one-off run is folded
  into the app-associated example's README, where it is most natural.
  Date: 2026-06-10

- Decision: Treat the live end-to-end legs (deploy the CronJob, `task run`, `task logs`,
  Grafana history) as deferrable-with-instructions, exactly as EP-48 did, while mandatory offline
  checks — every example `Config.hs` emits valid `{"kind":"Task"}` JSON via `runghc`, and (where
  EP-51's `task run --dry-run` / `deploy --dry-run` is available) the CronJob renders — prove the
  examples and the docs.
  Rationale: `nagare-01` is often `TERMINATED`, and IAP forwards only SSH/22 so a workstation
  `kubectl`/`nagarectl` cannot reach the k3s API; the workstation's default kubectl context is an
  unrelated GKE cluster that must not be used (repo memory). The honest, reproducible posture is:
  emit-and-render everything offline now, and write the exact on-VM commands (start the VM,
  `scripts/iap-ssh.sh` as the deploy user, run `nagarectl`/`kubectl` on the VM) so the live leg
  can be completed when the VM is up. A new page therefore starts 🟡 until the live legs run.
  Date: 2026-06-10

- Decision: No `docs/runbooks/server-operations.md` edit. That runbook is purely host/cluster
  operations (`nagarectl server status`/`doctor`/`domains`/`cleanup`, the TERMINATED→green
  recovery). Scheduled tasks are an app-developer workload concern, fully covered by
  `docs/user/scheduled-tasks.md`; adding a `nagarectl task` pointer to a host-ops glance table
  would be off-topic. The plan explicitly permits recording that no runbook edit was made.
  Date: 2026-06-10

- Decision: Reshape both examples from "a standalone `Task` config provisioned by `nagarectl
  deploy -f`" to "an app `Deployment` that co-locates the task in its `tasks` list", and fix
  EP-51's `grafanaHint` to the EP-49-verified LogsQL field.
  Rationale: reconciliation against the shipped surface (see Surprises) showed (1) `deploy`
  rejects a standalone Task config — co-location is the only provisioning path — and (2)
  `grafanaHint`'s `{nagare_dev_task=...}` query does not match the real VictoriaLogs stream field
  `kubernetes.pod_labels.nagare.dev/task` the spike verified. Both the docs and the example
  shapes were corrected to what actually works; the `grafanaHint` source + test were updated.
  Date: 2026-06-10

- Decision: Document — do not define — every surface owned by the sibling plans. This plan adds
  no library code; the `Task` type and fields (EP-50), the `task` subcommands (EP-51), and the
  app-association/inheritance contract (EP-52) are read from their shipped state and from
  MasterPlan 10's IP1–IP6, and the docs/examples must match what was actually shipped.
  Rationale: this is the docs/examples plan; its only "interface" obligation is accuracy. Because
  the sibling plans may be fleshed out after this plan is written, the implementer must verify the
  real surfaces (run the real `nagarectl task --help` and any `--dry-run`) before finalizing
  snippets and transcripts, and record any divergence here.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome: scheduled tasks are discoverable and learnable.** Against the original purpose:

- **The guide ships.** `docs/user/scheduled-tasks.md` covers concepts → declaring a task
  co-located in an app's `tasks` list → the four `nagarectl task` verbs (with transcripts) →
  running in an app's world (the inherited-variable table + the predefined-var table + the
  precedence rule) → logs & observability (the EP-49-verified LogsQL query) → the hard
  constraints → worked examples. It is indexed in `docs/user/README.md` (read-order + status
  table), linked from `deploying-apps.md`, and cross-linked from `managed-databases.md`.
- **Two runnable examples ship**, both offline-verified: `heartbeat-task` (a minimal app +
  inheriting heartbeat task; renders fully offline via `deploy --dry-run`) and `app-cleanup-task`
  (the `postgres-app` app + inheriting cleanup task reaching the same database; `runghc` emits
  the Deployment JSON with the co-located task). Each README walks declare → deploy → `task
  list`/`run`/`logs`, with live legs deferred-with-on-VM-commands.
- **Reconciliation corrected the docs to the shipped reality** rather than the plan's
  assumptions: tasks are provisioned by deploy-time co-location (no standalone-task deploy), task
  images are always tag-resolved (so inheriting tasks, not public images, are the norm), and the
  Grafana history query is the EP-49-verified `kubernetes.pod_labels.nagare.dev/task:="<task>"`
  (which also fixed EP-51's `grafanaHint` and its test). All recorded in Surprises/Decision Log.

**Gaps / deferred.** The live end-to-end legs (apply the CronJob on `nagare-01`, `task run`,
stream logs, Grafana history) are deferred-with-instructions per the EP-48 precedent — the
cluster API is reachable only on the VM. The offline emit-and-render checks (mandatory) all pass.
No runbook edit was made (Decision Log). The page is 🟡 until the live legs run.


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`. This plan
writes and edits **Markdown** under `docs/user/` (and possibly `docs/runbooks/`) and adds two
example directories (each a `nagare/Config.hs` and a `README.md`) under `cluster/examples/`. It
contains **no library code**; it consumes the behavior the sibling plans ship. Read this section
in full before editing.

### Where the docs and examples live

**The user docs directory — `docs/user/`.** It is the developer- and operator-facing guide. The
pages relevant here are:

- `docs/user/README.md` — the index. It carries a **Status legend** (✅ Working / 🟡 In progress /
  🔭 Planned), an "Area / Plan / Status" mapping table, and a "Read in this order" list whose item
  8 ("Deploying apps") has per-feature sub-bullets (Build modes, App lifecycle, Static hosting,
  Environment and secrets, Persistent storage, Managed databases). You add a **Scheduled tasks**
  sub-bullet and a status-table row.
- `docs/user/deploying-apps.md` — the developer-facing first-deploy on-ramp. It has a "Choosing a
  data tier" section near the end and a "Next" pointer. You add a brief "scheduled tasks" pointer.
- `docs/user/managed-databases.md` — the **direct structural precedent** your new page mirrors:
  an H1, a `>` status box with a badge, an intro naming the audience, a "smallest thing that
  works" block, then Concepts → Declaring in `Config.hs` → Choosing fields → Operating with the
  CLI → Connecting an app + an inherited-variable table → Backups → Constraints → Worked examples.
  Match its shape and tone.
- `docs/user/persistent-storage.md` and `docs/user/env-and-secrets.md` — additional tone
  references; cross-link them where natural.
- `docs/user/observability.md` — where the Victoria stack / Grafana story lives (VictoriaLogs is
  the log store in the `logging` namespace). Your logs section links here.

**The runbooks directory — `docs/runbooks/`.** Operator/disaster-recovery runbooks live here.
`docs/runbooks/server-operations.md` is the day-2 operations runbook; if task operations belong
there (for example, "how to inspect a failing scheduled task on the VM"), add a brief pointer.

**The examples directory — `cluster/examples/`.** Existing projects show the structure: a
`nagare/` subdirectory holding one or more `Config.hs`-style files, plus any app source and a
`README.md`. The closest precedent is `cluster/examples/postgres-app/`, which carries
`nagare/Config.hs` (an app `Deployment`), `nagare/Database.hs` (a typed `Database`), `app.py`, a
`Dockerfile`, and `README.md`. Your task examples follow the same layout, but a task config
emits a `Task` (not a `Deployment`), so the `Config.hs` imports `emitTask` and builds a `Task`.

### The house style for a `docs/user/` page

Visible at the top of `managed-databases.md` and `persistent-storage.md`:

- An H1 title (`# Scheduled tasks`).
- A `>` status box using one of the badges from `docs/user/README.md`'s Status legend: ✅ Working,
  🟡 In progress, or 🔭 Planned, with plain-English caveats. Because the live legs may be deferred,
  use **🟡 In progress** with the honest caveat "Built and offline-verified; live end-to-end run
  pending until `nagare-01` is back up," matching the persistent-storage and managed-databases
  pages. A new page starts 🔭 or 🟡 until the live legs run.
- An intro paragraph naming the audience ("for **app developers** who need to run work on a
  schedule or once on demand") and the promise.
- A fenced block showing "the smallest thing that works," then progressive detail.
- `>` callout blocks linking to related pages and stating constraints.

**Formatting rules this plan must obey** (per `.claude/skills/exec-plan/PLANS.md` and the existing
docs): two newlines after every heading, and **every fenced code block carries a language tag** —
`haskell`, `bash`, `text`, `yaml`, `json`, or `markdown` — never a bare ``` ` ` ` ```.

### What the sibling plans deliver — the source of truth for what to document

Because EP-51 and EP-52 may not be fully fleshed out when this plan is written, the binding
contract is MasterPlan 10's Integration Points
(`docs/masterplans/10-scheduled-tasks-for-nagare.md`, IP1–IP6) plus EP-50's Concrete Steps (which
are detailed and checked in). Reproduced here so this plan is self-contained. **The implementer
must reconcile every name below against the shipped surfaces** (run the real `nagarectl task
--help` and any `--dry-run`, read EP-50/51/52's final sections) and record any divergence in the
Decision Log.

**The typed `Task` model (IP1, owned by EP-50)** lives in
`cli/nagare-dsl/src/Nagare/Dsl/Task.hs`, exporting a validated `Task` record, a `Schedule`
newtype with `mkSchedule :: Text -> Either Text Schedule`, the `ConcurrencyPolicy`
(`Forbid`/`Allow`/`Replace`) and `RestartPolicy` (`Never`/`OnFailure`) enums, `mkTask`, the
`scheduledTask` preset, and the naming helper `taskResourceName`. The record's fields, exactly as
EP-50 specifies (every constrained field goes through a smart constructor):

```haskell
data Task = Task
  { taskName :: !ServiceName            -- ^ DNS-1123 label; CronJob is nagare-task-<taskName>
  , taskNamespace :: !Namespace         -- ^ default "personal"
  , taskSchedule :: !Schedule           -- ^ validated 5-field cron expression
  , taskImage :: !(Maybe ImageRef)      -- ^ Nothing = inherit taskApp's image (requires taskApp)
  , taskApp :: !(Maybe ServiceName)     -- ^ the app whose image/env this task may inherit
  , taskCommand :: ![Text]              -- ^ container command (entrypoint override)
  , taskArgs :: ![Text]                 -- ^ container args
  , taskEnv :: !(Map EnvName ScopedEnvVar) -- ^ inline env; only Runtime-scoped entries render
  , taskResources :: !(Maybe Resources) -- ^ CPU/memory requests and limits
  , taskTimeoutSeconds :: !(Maybe Int)  -- ^ > 0 when set; activeDeadlineSeconds
  , taskConcurrencyPolicy :: !ConcurrencyPolicy -- ^ default Forbid
  , taskRestartPolicy :: !RestartPolicy -- ^ default Never
  , taskBackoffLimit :: !Int            -- ^ >= 0; default 0
  , taskSuccessfulJobsHistoryLimit :: !Int -- ^ default 3
  , taskFailedJobsHistoryLimit :: !Int  -- ^ default 1
  , taskStartingDeadlineSeconds :: !(Maybe Int) -- ^ > 0 when set
  }
```

`mkTask` enforces the numeric bounds and the one cross-field invariant: a task must have a
non-empty `taskCommand` **or** reference an app to inherit its entrypoint, and a task with no
image (`taskImage = Nothing`) **must** reference an app. The `scheduledTask` preset builds a
standalone task from four `Text` arguments — name, cron schedule, image, command — filling
defaults (namespace `personal`, no app, `Forbid`/`Never`, backoff 0, history 3/1):

```haskell
scheduledTask :: Text -> Text -> Text -> Text -> Either Text Task   -- name sched image command
```

The `Task` is serialized to JSON by `emitTask :: Task -> IO ()` (in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs`), whose JSON object carries the top-level discriminator
`"kind": "Task"` (databases use `"kind":"Database"`; plain deployments carry no `kind`). The
loader `decodeTask`/`loadTask` (in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`) re-runs every smart
constructor, so an invalid task fails at load with a precise `MarshalError "<field>" "<message>"`.

**The rendered CronJob (IP2/IP3, owned by EP-50)** is a single `batch/v1` CronJob named
`nagare-task-<taskName>`, whose `spec.jobTemplate.spec` is the Job template a one-off run reuses.
Every rendered object carries the labels `nagare.dev/managed-by: nagarectl`,
`nagare.dev/task: <taskName>`, and — when the task references an app — `nagare.dev/app: <appName>`.
The CronJob `spec` carries `schedule`, `concurrencyPolicy`, `successfulJobsHistoryLimit`,
`failedJobsHistoryLimit`, and (when set) `startingDeadlineSeconds`; the Job template carries
`backoffLimit`, `activeDeadlineSeconds`, `restartPolicy`, and the container. When the task
references an app, the template gains an `envFrom` block referencing `nagare-env-<app>-runtime`
(ConfigMap) and `nagare-secret-<app>-runtime` (Secret), each `optional: true`.

**The `nagarectl task` command group (IP4/IP6, owned by EP-51).**

```text
nagarectl task list [APP]        # table of tasks (optionally scoped to one app)
nagarectl task run APP TASK      # run once, now: kubectl create job --from=cronjob/...; --dry-run prints the command
nagarectl task logs APP TASK     # most recent pod logs (--follow to tail) + a Grafana/VictoriaLogs hint
nagarectl task delete APP TASK   # delete the CronJob (guarded by --yes; --dry-run prints the plan)
```

`APP` is **optional** for `task list` (omit it to list every task; pass a name to scope to one
app; pass the single-hyphen sentinel `-` to list only app-less tasks). For `run`/`logs`/`delete`,
`APP` is a **required** positional combined with `TASK` into the label selector
`nagare.dev/task=<task>,nagare.dev/app=<app>` (with `-` meaning "no app"). `task run` builds a
deterministic Job name `nagare-task-<task>-manual-<YYYYmmddHHMMSS>`, runs
`kubectl create job <name> --from=cronjob/nagare-task-<task> -n <ns>`, waits with
`kubectl wait --for=condition=complete --timeout=600s`, and reports. `task logs` streams pod logs
by the `nagare.dev/task=<task>` selector and prints a one-line Grafana hint:

```text
For older runs, query VictoriaLogs in Grafana with: {nagare_dev_task="cleanup"}
```

Additionally, when a deployment declares tasks (the `Deployment` carries a tasks field that
EP-50/EP-52 add), `nagarectl deploy` **provisions** them: it renders each declared task into a
CronJob and applies it in the same idempotent pass as the app's Service/PVCs/databases.
`nagarectl deploy --dry-run` prints each rendered CronJob under a `--- Task CronJob manifest ---`
banner.

**The app↔task association and inheritance (IP5, owned by EP-52).** A task may reference an app by
`ServiceName` (the `taskApp` field). When present and the task opts into inheritance (`taskImage
= Nothing`), the rendered Job template (1) uses the app's deployed image tag, resolved at deploy
time, and (2) gains `envFrom` references to `nagare-env-<app>-runtime` and
`nagare-secret-<app>-runtime` (each `optional: true`), exactly as the app's own container gets
them. EP-52 also injects predefined task variables into every task run — at minimum
`NAGARE_TASK_NAME` and a per-run `NAGARE_RUN_ID`. The precedence rule (reconcile against EP-52):
inherited app env is the base; the task's own inline `taskEnv` overrides same-named inherited
variables; the predefined `NAGARE_*` variables are set by the platform.

> **Reconciliation note.** The exact predefined-variable set, the precedence ordering, and the
> `Deployment` tasks field name are owned by EP-52 (and the field shape by EP-50). Before writing
> the inherited-variable table and the precedence sentence in the guide, read EP-52's final
> Concrete Steps and confirm the variable names and ordering against a real `deploy --dry-run`,
> and record any divergence in the Decision Log.

### The verified VictoriaLogs query (from EP-49)

The spike `docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md` records
that the cluster's log collector ships every container log to VictoriaLogs in the `logging`
namespace, and that the log **stream fields are `kubernetes.pod_namespace`,
`kubernetes.pod_name`, and `kubernetes.container_name`** (not the bare names). The LogsQL selector
that finds a namespace's logs is `{kubernetes.pod_namespace="<ns>"}`. The `task logs` Grafana hint
uses the pod label `nagare_dev_task` (label keys are dotted-to-underscored in the log stream), so
the history query for one task is `{nagare_dev_task="<task>"}`. The guide cites this query and
links `docs/user/observability.md` for how to open Grafana's Explore view; it builds no new
observability.

### The cluster-access reality (repo memory)

The VM `nagare-01` is often `TERMINATED` — start it first
(`gcloud compute instances start nagare-01 --project=tan-nb-exp --zone=us-west1-a`). Reach it via
`scripts/iap-ssh.sh` as the deploy user (its `~/.ssh/id_ed25519`). IAP forwards only SSH/22, so a
workstation `kubectl`/`nagarectl` cannot reach the k3s API — run them *on the VM*. The
workstation's default kubectl context is an unrelated GKE cluster; do not use it. This is why the
live legs are deferred-with-instructions. Every cloud read/write targets the `tan-nb-exp` project,
region `us-west1`, zone `us-west1-a`, per the repository `CLAUDE.md`.


## Plan of Work

The work is three milestones: write the guide and cross-links (M1), then build-and-verify the
examples offline (M2), then add the observability/runbook integration and a final reconciliation
pass that defers the live legs with exact instructions (M3). Each milestone ends with an
observable acceptance a reader can reproduce.

Before writing any snippet or transcript, the implementer reconciles the documented surfaces
against what the sibling plans actually shipped. From the repository root, run the real CLI help
and (where available) a dry-run, and read EP-50/51/52's final sections:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
cabal --project-dir=cli/nagarectl run nagarectl -- task --help
cabal --project-dir=cli/nagarectl run nagarectl -- task run --help
cabal --project-dir=cli/nagarectl run nagarectl -- task run myapp cleanup --dry-run
```

Update the field names, command flags, the inherited-variable set, the precedence rule, and the
`Deployment` tasks field name in the guide and the examples to match the real output, and note any
divergence from MasterPlan 10's IP1–IP6 in the Decision Log.

### Milestone M1 — The scheduled-tasks guide and cross-links

Scope: create `docs/user/scheduled-tasks.md`, index it in `docs/user/README.md`, link it from
`docs/user/deploying-apps.md`, and cross-link `docs/user/managed-databases.md` /
`docs/user/persistent-storage.md` where natural. At the end of this milestone the conceptual and
reference documentation is complete and internally consistent; the examples it references are
added in M2 and the Grafana history walkthrough is finished in M3.

Create **`docs/user/scheduled-tasks.md`** in the house style, with these sections in order
(the exact content to write is in Concrete Steps below):

1. **Title + status box + intro.** H1 `# Scheduled tasks`, a `>` status box (🟡 In progress,
   honest caveat about the deferred live run). One paragraph naming the audience ("for **app
   developers** who need to run work on a schedule or once on demand") and the promise.
2. **The smallest thing that works.** A two-step block: declare a `Task` with the `scheduledTask`
   preset, then `nagarectl deploy` provisions the CronJob; `nagarectl task run` runs it once.
3. **Concepts.** Define *scheduled task*, *CronJob*, *Job*, *one-off run*, the cron grammar,
   concurrency/backoff/timeout/history meaning, and the app association — in prose, reusing the
   "Terms" wording above. A `>` callout stating the three hard constraints up front.
4. **Declaring a task in `Config.hs`.** The typed `Task`: the `scheduledTask` preset for the
   common case, then the full record form annotating each field; the `Schedule` cron grammar;
   command/args; inline env.
5. **Operating with `nagarectl task`.** Each verb with one transcript: `list`, `run` (with the
   `--dry-run` transcript), `logs`, `delete`. State that discovery is label-based.
6. **Running in an app's world.** The app association, the inherited-variable table, and the
   precedence rule.
7. **Logs & observability.** `task logs`, then the Grafana/VictoriaLogs history query (finished
   in M3), linking `docs/user/observability.md`.
8. **Constraints and limits.** Single-node/single-completion, cron-only + manual `task run`, no
   event triggers, not an interactive shell.
9. **Worked examples.** Short subsections pointing at the two `cluster/examples/` directories.

Index the new page in **`docs/user/README.md`**: add a sub-bullet under item 8 ("Deploying apps"),
after the "Managed databases" sub-bullet, linking `scheduled-tasks.md` with a one-line description
and a 🟡 status badge; and add a row to the "Area / Plan / Status" table (e.g. "Scheduled tasks
(`nagarectl task`) | MP-10 (EP-49–53) | 🟡 Built; live run pending").

Link the new page from **`docs/user/deploying-apps.md`**: in the "Next" pointer area or near the
data-tier section, add a one-line "scheduled tasks" pointer. Cross-link
**`docs/user/managed-databases.md`** (a task can run nightly maintenance against a managed
database) and **`docs/user/persistent-storage.md`** where natural, with a one-line description.

Acceptance for M1: `docs/user/scheduled-tasks.md` exists and renders; every command, field name,
and label in it matches MasterPlan 10's IP1–IP6 and EP-50/51/52's shipped surface (verified by
running the real `--help`/`--dry-run`); `README.md` and `deploying-apps.md` link the new page;
`managed-databases.md`/`persistent-storage.md` cross-link it where natural; no bare ``` fences
exist in any edited file (`grep -rn '^```$' docs/user/scheduled-tasks.md` returns nothing).

### Milestone M2 — The end-to-end examples (offline-verified)

Scope: create `cluster/examples/heartbeat-task/` (a standalone task) and
`cluster/examples/app-cleanup-task/` (an app-associated task inheriting the `postgres-app`
image/env), each with a `nagare/Config.hs` and a `README.md`; demonstrate the one-off run via
`nagarectl task run` in the `app-cleanup-task` README. At the end of this milestone every example
emits valid `{"kind":"Task"}` JSON offline via `runghc`, and (where EP-51's `task run --dry-run` /
`deploy --dry-run` is available) the rendered CronJob is shown. The live legs are deferred.

Each example directory follows the `cluster/examples/postgres-app/` shape — a `nagare/`
subdirectory with `Config.hs`, plus a `README.md`. The heartbeat task needs no app source (it
runs a public image's `date`/`curl`); the app-cleanup task reuses the `postgres-app` example's
image and database, so it needs no new source either — it inherits.

**Example 1 — `cluster/examples/heartbeat-task/` (a standalone scheduled task).** Files:
`nagare/Config.hs` (a `Task` built with the `scheduledTask` preset: name `heartbeat`, schedule
`*/15 * * * *` — every 15 minutes, a public image such as `curlimages/curl`, a command that
prints the date / pings a URL), and `README.md`. The README shows: `runghc` emitting the
`{"kind":"Task"}` JSON (the offline proof), `nagarectl deploy --dry-run` rendering the
`nagare-task-heartbeat` CronJob, the live deploy, `nagarectl task list`, `nagarectl task run -
heartbeat` (the `-` sentinel, because this task is app-less) streaming one run, and
`nagarectl task logs - heartbeat`. Note that this task is **app-less**, so it is addressed with
the `-` sentinel.

**Example 2 — `cluster/examples/app-cleanup-task/` (an app-associated scheduled task).** Files:
`nagare/Config.hs` (a `Task` with `taskApp = Just "postgres-app"`, `taskImage = Nothing` so it
inherits the app's image, a schedule like `0 3 * * *`, and a command that runs a cleanup against
the inherited `DATABASE_URL` — e.g. `python -c "..."` deleting old rows), and `README.md`. The
README shows: `runghc` emitting the JSON, `nagarectl deploy --dry-run` (or the task's own
provisioning) rendering the `nagare-task-cleanup` CronJob with the `nagare.dev/app: postgres-app`
label and the `envFrom` block, the live deploy, `nagarectl task list postgres-app`,
`nagarectl task run postgres-app cleanup` (the one-off run, demonstrating
`kubectl create job --from=cronjob/...`), and `nagarectl task logs postgres-app cleanup`. The
README states plainly that this task inherits the app's image and runtime env/secrets (so it
reaches the same database) and carries the `nagare.dev/app` label.

Each README ends with a **Clean up** section: `nagarectl task delete <app> <name> --yes` (or
`nagarectl task delete - heartbeat --yes` for the app-less one), noting the command is idempotent.

Acceptance for M2: for each example, `runghc` of its `nagare/Config.hs` prints a single line of
JSON beginning `{"kind":"Task",`; and (where the CLI is buildable in the environment) the rendered
CronJob shows the `nagare-task-<name>` name and the IP3 labels — for `app-cleanup-task`, also the
`nagare.dev/app` label and the `envFrom` block. No bare ``` fences in any new file.

### Milestone M3 — Observability/runbook integration and final reconciliation

Scope: finish the Grafana/VictoriaLogs history walkthrough in `docs/user/scheduled-tasks.md`
(cross-linking `docs/user/observability.md` and citing EP-49's verified LogsQL query
`{nagare_dev_task="<task>"}`), add a brief "scheduled tasks" pointer to
`docs/runbooks/server-operations.md` if task operations belong there, and run a final
reconciliation pass against EP-50/51/52's shipped state, marking the live legs deferred with the
exact on-VM commands.

Acceptance for M3: the guide's "Logs & observability" section shows `nagarectl task logs` and the
`{nagare_dev_task="<task>"}` LogsQL query, and links `observability.md`; the runbook has a
scheduled-tasks pointer (or this plan records that none was needed and why); every command, field,
and label in the guide and examples matches the shipped surface; the live legs in the guide and
each README read "dry-run verified; live run deferred" with the exact on-VM commands.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

First reconcile the documented surfaces against the shipped CLI (see Plan of Work). When
`nagarectl` is on `PATH`:

```bash
nagarectl task --help
nagarectl task run --help
nagarectl task list --help
```

From a source checkout where `nagarectl` is not on `PATH`, use the cabal form (the same form
EP-48's examples use):

```bash
cabal --project-dir=cli/nagarectl run nagarectl -- task --help
cabal --project-dir=cli/nagarectl run nagarectl -- task run notes cleanup --dry-run
```

### M1.1 — write `docs/user/scheduled-tasks.md`

Create the page with the following structure and content. Reconcile every name against the
shipped surface before committing.

**Title, status box, intro, and "smallest thing that works."**

```markdown
# Scheduled tasks

> 🟡 **In progress.** Built and offline-verified (typed `Task` model, the
> CronJob renderer, the `nagarectl task` command group, and app↔task
> inheritance). Every example `Config.hs` emits valid `{"kind":"Task"}` JSON and
> renders a `nagare-task-<name>` CronJob via `--dry-run`. The full **live**
> end-to-end run (deploy the CronJob, `task run`, stream logs) is pending only
> because `nagare-01` is often `TERMINATED`; the exact on-VM commands are below.

For **app developers** who need to run work **on a schedule** (a nightly cleanup,
an hourly sync) or **once, on demand** (a one-off migration). You declare a typed
`Task` — a name, a cron schedule, and a command — in the same `nagare/Config.hs`
you already use for apps; Nagare provisions a Kubernetes **CronJob**, and you
operate it with a new `nagarectl task` command group.

A scheduled task is **not** an app `Deployment` and **not** a Knative Service. It
is a `Task` value that renders a CronJob named `nagare-task-<name>`, provisioned
at deploy time and operated through `nagarectl task`.


## The smallest thing that works

​```haskell
-- nagare/Config.hs — a standalone scheduled task with its own image and command.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task (scheduledTask)

main :: IO ()
main = case scheduledTask "heartbeat" "*/15 * * * *" "curlimages/curl" "date -u" of
  Left err -> ioError (userError err)
  Right t  -> emitTask t
​```

​```bash
# Provision the CronJob (deploy applies declared tasks alongside the app):
nagarectl deploy -f nagare/Config.hs

# See it, run it once now, and read the logs:
nagarectl task list
nagarectl task run - heartbeat      # "-" addresses an app-less task
nagarectl task logs - heartbeat
​```
```

(Replace the zero-width-space-prefixed fences with plain triple backticks when you write the
file; they appear here only so this plan's own fences nest correctly.)

**Concepts.** Write prose defining *scheduled task*, *CronJob*, *Job*, *one-off run*, the cron
grammar, and the policies, reusing the "Terms" wording from Context and Orientation. Then a `>`
callout stating the three hard constraints:

```markdown
## Concepts

- A **scheduled task** is a named unit of work Nagare runs on a cron schedule,
  declared as a typed `Task` (name, namespace, schedule, image, command/args,
  env, resources, timeout, concurrency/restart/backoff policy, history limits,
  and an optional app reference).
- A **CronJob** is the Kubernetes object that, on a cron schedule, creates a
  **Job**, which runs a **Pod** to completion. Nagare names it `nagare-task-<name>`.
- A **one-off run** is a single Job created immediately from the CronJob's
  template, bypassing the schedule. `nagarectl task run` does exactly this.
- The **cron schedule** is a validated 5-field expression
  (`minute hour day-of-month month day-of-week`), e.g. `0 3 * * *` ("daily at
  03:00"). A malformed schedule is rejected at load with a precise message.
  Named months/days (`JAN`, `MON`) and `@daily`-style macros are not accepted.
- **Concurrency policy** decides what happens if a run is still going when the
  next is due: `Forbid` (the default — skip the new run), `Allow` (run both), or
  `Replace` (cancel the running one). **Backoff limit** is how many times a failed
  Job is retried before it is marked failed (default 0). **Timeout** is a hard
  wall-clock limit on a run (`activeDeadlineSeconds`). **History limits** keep the
  last N successful (default 3) and failed (default 1) Jobs for inspection.
- The **app association** lets a task run "in an app's world": it inherits the
  app's deployed image and runtime env/secrets and carries the `nagare.dev/app`
  label. See "Running in an app's world" below.

> **Three hard constraints, up front.**
> - **Single-node, single-completion.** Each task is one Job that runs one pod to
>   completion. No fan-out, no parallelism, no multi-node scheduling — this is the
>   deliberate single-node design the whole PaaS accepts.
> - **Cron-only plus manual `task run`.** Tasks fire on their cron schedule or when
>   you run `nagarectl task run`. There are no event or webhook triggers.
> - **`task run` is not a shell.** It runs a *declared* task once; it is not an
>   interactive session. For an interactive database session use `nagarectl db shell`.
```

**Declaring a task in `Config.hs`.** Show the preset, then the full record form. Annotate each
field. State that the task is typed and validated at load time:

```markdown
## Declaring a task in `Config.hs`

A task is typed and validated at load time — a bad name, a malformed cron string,
a negative backoff, or a task with neither a command nor an inheriting app is
rejected with a precise message. For the common case use the `scheduledTask`
preset (name, schedule, image, command):

​```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task (scheduledTask)

main :: IO ()
main = case scheduledTask "nightly-report" "30 2 * * *"
              "us-west1-docker.pkg.dev/tan-nb-exp/nagare/reporter" "python report.py" of
  Left err -> ioError (userError err)
  Right t  -> emitTask t
​```

For full control — args, inline env, resources, timeout, the batch policies, or an
app reference — build the record directly. Every constrained field goes through a
smart constructor:

​```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Map qualified as Map
import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task
  ( Task (..), ConcurrencyPolicy (..), RestartPolicy (..)
  , mkSchedule, mkTask )
import Nagare.Dsl.Types
  ( EnvVar (EnvLiteral), mkEnvName, mkImageRef, mkNamespace
  , mkServiceName, runtimeScoped )

task :: Either String Task
task = mapLeft show $ do
  n     <- mkServiceName "cleanup"
  ns    <- mkNamespace "personal"
  sched <- mkSchedule "0 3 * * *"          -- daily at 03:00
  img   <- mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
  dry   <- mkEnvName "DRY_RUN"
  mkTask Task
    { taskName        = n
    , taskNamespace   = ns
    , taskSchedule    = sched
    , taskImage       = Just img
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

main :: IO ()
main = case task of
  Left err -> ioError (userError err)
  Right t  -> emitTask t

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
​```

Smoke-test it offline (no cluster):

​```bash
runghc -XGHC2024 -inagare nagare/Config.hs
# -> {"kind":"Task","name":"cleanup","namespace":"personal","schedule":"0 3 * * *",...}
​```
```

State, in prose after the snippet: only `Runtime`-scoped inline env renders into the container;
`taskImage = Nothing` means "inherit the app's image" and is only valid with `taskApp = Just _`.

**Operating with `nagarectl task`.** Document each verb with one transcript. Use the exact shapes
from EP-51:

```markdown
## Operating with `nagarectl task`

​```text
nagarectl task list [APP]        # table of tasks (omit APP for all; "-" for app-less)
nagarectl task run APP TASK      # run once, now; --dry-run prints the kubectl command
nagarectl task logs APP TASK     # most recent pod logs (--follow to tail)
nagarectl task delete APP TASK   # delete the CronJob (guarded by --yes)
​```

Tasks are discovered by label — `nagare.dev/managed-by=nagarectl,nagare.dev/task`
(narrowed by `nagare.dev/app` when you pass an `APP`) — never by guessing names,
so `task list` always reflects exactly what was provisioned.

​```text
$ nagarectl task list -n personal
  NAME              APP         SCHEDULE        LAST RUN              LAST SUCCESS          ACTIVE
  cleanup           notes       0 3 * * *       2026-06-10T03:00:00Z  2026-06-10T03:00:12Z  0
  heartbeat         -           */15 * * * *    2026-06-10T17:15:00Z  2026-06-10T17:15:01Z  0
​```

`nagarectl task run APP TASK` fires the task once, right now: it creates a Job from
the deployed CronJob, waits for it to finish, and reports. `--dry-run` prints the
exact command and runs nothing:

​```text
$ nagarectl task run notes cleanup --dry-run
--- task run (dry-run) ---
kubectl create job nagare-task-cleanup-manual-<timestamp> --from=cronjob/nagare-task-cleanup -n personal
Then: kubectl wait --for=condition=complete --timeout=600s job/nagare-task-cleanup-manual-<timestamp> -n personal
​```

A live run streams to completion:

​```text
$ nagarectl task run notes cleanup -n personal
Starting one-off run nagare-task-cleanup-manual-20260610174500 ...
job.batch/nagare-task-cleanup-manual-20260610174500 created
job.batch/nagare-task-cleanup-manual-20260610174500 condition met
Task cleanup completed (nagare-task-cleanup-manual-20260610174500).
​```

`nagarectl task delete APP TASK` (without `--yes`) prints the deletion plan and
deletes nothing; with `--yes` it removes the CronJob idempotently:

​```text
$ nagarectl task delete notes cleanup
Would delete (run again with --yes):
  cronjob/nagare-task-cleanup
  configmap/nagare-task-runs-cleanup

$ nagarectl task delete notes cleanup --yes
Deleted task cleanup
​```
```

**Running in an app's world.** Document the association, the inherited-variable table, and the
precedence rule. Reconcile the predefined-variable set against EP-52:

```markdown
## Running in an app's world

A task can run **in an app's world**: set `taskApp = Just "<app>"` (and leave
`taskImage = Nothing` to inherit the app's image). At deploy time the rendered Job
template uses the app's deployed image tag and adds an `envFrom` block importing
the app's managed runtime ConfigMap and Secret, so the task sees the same
environment — including any injected `DATABASE_URL` — as the app itself. The
CronJob and its pods carry the `nagare.dev/app: <app>` label, so
`nagarectl task list <app>` scopes to that app's tasks.

The task container's environment is composed from three layers:

| Layer | Source | Wins over |
| --- | --- | --- |
| Inherited app env | `envFrom` the app's `nagare-env-<app>-runtime` ConfigMap and `nagare-secret-<app>-runtime` Secret (`optional: true`) | (base) |
| Task inline env | the task's own `taskEnv` (Runtime-scoped) | inherited app env |
| Predefined task vars | `NAGARE_TASK_NAME` (the task name) and a per-run `NAGARE_RUN_ID` | set by the platform |

The precedence rule: **inherited app env is the base; the task's own inline env
overrides any same-named inherited variable; the predefined `NAGARE_*` variables
are always set.** An app and its task must share a namespace (the default
`personal`) for the inherited ConfigMap/Secret references to resolve.

> The inherited references are `optional: true`, so a task associated with an app
> that has no managed env/secret yet still starts — it just sees no inherited
> variables until the app is deployed with env.
```

**Logs & observability** (filled in M3) and **Constraints and limits** and **Worked examples** —
their content is specified in M3.1 and M1.2/M2 below.

### M1.2 — the "Constraints and limits" and "Worked examples" sections

Add to `docs/user/scheduled-tasks.md`:

```markdown
## Constraints and limits

- **Single-node, single-completion.** Each task is one Job that runs one pod to
  completion. No fan-out, no parallelism beyond a single completion, no task
  queues, no multi-node scheduling. This is the deliberate single-node design.
- **Cron-only plus manual `task run`.** Tasks fire on their cron schedule or when
  you run `nagarectl task run`. There are no event-driven or webhook triggers
  (those belong to the future Control-Plane API).
- **`task run` is not an interactive shell.** It runs a declared task once. For an
  interactive database session use `nagarectl db shell` (see
  [Managed databases](managed-databases.md)).
- **Out of scope:** event/webhook triggers, parallel/fan-out Jobs, and changing
  the managed-database backup CronJob (that machinery stays as-is).


## Worked examples

Two runnable examples live under `cluster/examples/`:

- **[`heartbeat-task`](../../cluster/examples/heartbeat-task/)** — a standalone
  scheduled task (its own image and command) that prints a heartbeat every 15
  minutes. The smallest typed `Task`; no app involved.
- **[`app-cleanup-task`](../../cluster/examples/app-cleanup-task/)** — an
  app-associated task that inherits the `postgres-app` example's image and runtime
  env/secrets and runs a nightly cleanup against the same database. Also shows the
  one-off run via `nagarectl task run`.

Each example's `README.md` walks through declare → deploy → `task list`/`task
run`/`task logs`, with the offline `runghc`/`--dry-run` checks and the on-VM live
commands.
```

### M1.3 — index and cross-link

In **`docs/user/README.md`**, under item 8's sub-bullets (after the "Managed databases"
sub-bullet, around line 99–102), add:

```markdown
   - [Scheduled tasks](scheduled-tasks.md) — run work on a cron schedule or once
     on demand: declare a typed `Task`, provision a CronJob at deploy time, and
     operate it with `nagarectl task list/run/logs/delete`, including app↔task
     image/env inheritance. 🟡
```

In the same file's "Area / Plan / Status" table (around line 46, after the managed-databases
row), add:

```markdown
| Scheduled tasks (`nagarectl task`) | MP-10 (EP-49–53) | 🟡 Built; live run pending |
```

In **`docs/user/deploying-apps.md`**, near the "Choosing a data tier" / "Next" area, add a
one-line pointer:

```markdown
Need to run work **on a schedule** (a nightly cleanup) or **once on demand** (a
one-off migration)? Declare a typed `Task` and operate it with `nagarectl task` —
see **[Scheduled tasks](scheduled-tasks.md)**.
```

In **`docs/user/managed-databases.md`** (in its "Worked examples" or "Constraints" area) and
**`docs/user/persistent-storage.md`**, add a one-line cross-link where natural, e.g. in the
databases page: "To run scheduled maintenance against a managed database (a nightly cleanup or
report), declare a [scheduled task](scheduled-tasks.md) that references the app."

Verify the links resolve:

```bash
grep -rn "scheduled-tasks.md" docs/
grep -rn '^```$' docs/user/scheduled-tasks.md || echo "all fences tagged"
```

### M2.1 — `cluster/examples/heartbeat-task/`

Create `cluster/examples/heartbeat-task/nagare/Config.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | The heartbeat-task example: a standalone scheduled task with its own image
-- and command. Every 15 minutes it prints the current UTC time — the smallest
-- typed Task (MasterPlan 10). No app is referenced, so it is addressed with the
-- "-" sentinel: `nagarectl task run - heartbeat`.
--
-- Provision it with:
--   nagarectl deploy -f cluster/examples/heartbeat-task/nagare/Config.hs
module Main (main) where

import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task (scheduledTask)

main :: IO ()
main = case scheduledTask "heartbeat" "*/15 * * * *" "curlimages/curl" "date -u" of
  Left err -> ioError (userError err)
  Right t  -> emitTask t
```

Create `cluster/examples/heartbeat-task/README.md`:

```markdown
# heartbeat-task — a standalone scheduled task

A scheduled task that prints the current UTC time every 15 minutes, running in a
public `curlimages/curl` image with its own command. It is the smallest typed
`Task`: no app, no inherited env. See
[`docs/user/scheduled-tasks.md`](../../../docs/user/scheduled-tasks.md).

## Files

- `nagare/Config.hs` — the typed `Task`, built with the `scheduledTask` preset
  (name `heartbeat`, schedule `*/15 * * * *`, image `curlimages/curl`, command
  `date -u`). It emits `{"kind":"Task", ...}` JSON.

## Verify offline (no cluster)

​```bash
runghc -XGHC2024 -icluster/examples/heartbeat-task/nagare \
  cluster/examples/heartbeat-task/nagare/Config.hs
# -> {"kind":"Task","name":"heartbeat","namespace":"personal","schedule":"*/15 * * * *",...}

# The rendered CronJob (named nagare-task-heartbeat, with the IP3 labels):
nagarectl deploy -f cluster/examples/heartbeat-task/nagare/Config.hs --dry-run
​```

The `deploy --dry-run` output shows a `--- Task CronJob manifest ---` banner with a
`batch/v1` CronJob named `nagare-task-heartbeat`, the labels
`nagare.dev/managed-by: nagarectl` and `nagare.dev/task: heartbeat`, `schedule:
"*/15 * * * *"`, and the `curlimages/curl` container running `date -u`.

## Live run (on `nagare-01`)

> The workstation cannot reach the k3s API (IAP forwards only SSH/22). Run these
> **on the VM** via `scripts/iap-ssh.sh`, after `gcloud compute instances start
> nagare-01 --project=tan-nb-exp --zone=us-west1-a`.

​```bash
nagarectl deploy -f cluster/examples/heartbeat-task/nagare/Config.hs
nagarectl task list                 # heartbeat appears with APP "-"
nagarectl task run - heartbeat      # "-" addresses this app-less task; runs once now
nagarectl task logs - heartbeat     # the most recent run's output (a UTC timestamp)
​```

## Clean up

​```bash
nagarectl task delete - heartbeat --yes   # removes the CronJob (idempotent)
​```
```

(Replace the zero-width-space-prefixed fences with plain triple backticks in the file.)

### M2.2 — `cluster/examples/app-cleanup-task/`

Create `cluster/examples/app-cleanup-task/nagare/Config.hs`. It references the existing
`postgres-app` example app, inherits its image (`taskImage = Nothing`), and runs a cleanup against
the inherited `DATABASE_URL`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | The app-cleanup-task example: an app-associated scheduled task. It references
-- the postgres-app example app, inherits its deployed image and runtime env/secrets
-- (taskImage = Nothing), and runs a nightly cleanup against the inherited
-- DATABASE_URL (MasterPlan 10, IP5). Its CronJob carries the nagare.dev/app:
-- postgres-app label, so `nagarectl task list postgres-app` scopes to it.
--
-- Provision it with:
--   nagarectl deploy -f cluster/examples/app-cleanup-task/nagare/Config.hs
module Main (main) where

import Nagare.Dsl.Config (emitTask)
import Nagare.Dsl.Task (Task (..), ConcurrencyPolicy (..), RestartPolicy (..), mkSchedule, mkTask)
import Nagare.Dsl.Types (mkNamespace, mkServiceName)

task :: Either String Task
task = mapLeft show $ do
  n     <- mkServiceName "cleanup"
  app   <- mkServiceName "postgres-app"
  ns    <- mkNamespace "personal"
  sched <- mkSchedule "0 3 * * *"               -- daily at 03:00
  mkTask Task
    { taskName        = n
    , taskNamespace   = ns
    , taskSchedule    = sched
    , taskImage       = Nothing                  -- inherit postgres-app's image
    , taskApp         = Just app
    , taskCommand     =
        [ "python", "-c"
        , "import os,psycopg; psycopg.connect(os.environ['DATABASE_URL'],autocommit=True)\
          \.execute(\"DELETE FROM hits WHERE at < now() - interval '7 days'\")"
        ]
    , taskArgs        = []
    , taskEnv         = mempty
    , taskResources   = Nothing
    , taskTimeoutSeconds = Just 300
    , taskConcurrencyPolicy = Forbid
    , taskRestartPolicy     = Never
    , taskBackoffLimit      = 0
    , taskSuccessfulJobsHistoryLimit = 3
    , taskFailedJobsHistoryLimit     = 1
    , taskStartingDeadlineSeconds    = Nothing
    }

main :: IO ()
main = case task of
  Left err -> ioError (userError err)
  Right t  -> emitTask t

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
```

> Note: `mempty` for `taskEnv` is `Map.empty`. If the environment's `runghc` does not resolve the
> `Map` `Monoid` instance without an import, change `taskEnv = mempty` to `taskEnv = Map.empty`
> and add `import Data.Map qualified as Map`. Reconcile the multi-line string against the shipped
> `MultilineStrings`/escaping conventions; if `python -c` is awkward, use a small `cleanup.py`
> COPYed into the image instead.

Create `cluster/examples/app-cleanup-task/README.md`:

```markdown
# app-cleanup-task — an app-associated scheduled task

A scheduled task that **inherits the `postgres-app` example app's image and runtime
env/secrets** and runs a nightly cleanup against the same database. It references
the app by name (`taskApp = Just "postgres-app"`) and leaves `taskImage = Nothing`,
so at deploy time it runs in the app's deployed image with the app's injected
`DATABASE_URL`. Its CronJob carries the `nagare.dev/app: postgres-app` label. See
[`docs/user/scheduled-tasks.md`](../../../docs/user/scheduled-tasks.md).

This example builds on [`postgres-app`](../postgres-app/) — provision that app and
its database first.

## Files

- `nagare/Config.hs` — the typed `Task`: `taskApp = Just "postgres-app"`,
  `taskImage = Nothing` (inherit), schedule `0 3 * * *`, a cleanup command that
  deletes rows older than 7 days using the inherited `DATABASE_URL`.

## Verify offline (no cluster)

​```bash
runghc -XGHC2024 -icluster/examples/app-cleanup-task/nagare \
  cluster/examples/app-cleanup-task/nagare/Config.hs
# -> {"kind":"Task","name":"cleanup","namespace":"personal","app":"postgres-app",...}

# The rendered CronJob: name nagare-task-cleanup, the nagare.dev/app label, and the
# envFrom block importing the app's managed runtime ConfigMap/Secret:
nagarectl deploy -f cluster/examples/app-cleanup-task/nagare/Config.hs --dry-run
​```

The `deploy --dry-run` output shows a `batch/v1` CronJob named `nagare-task-cleanup`
labelled `nagare.dev/managed-by: nagarectl`, `nagare.dev/task: cleanup`, and
`nagare.dev/app: postgres-app`, whose Job template has an `envFrom` block referencing
`nagare-env-postgres-app-runtime` (ConfigMap) and `nagare-secret-postgres-app-runtime`
(Secret), each `optional: true`.

## Live run (on `nagare-01`)

> Run these **on the VM** via `scripts/iap-ssh.sh`, after starting `nagare-01`.
> Provision the `postgres-app` example first (see its README) so the inherited
> image and `DATABASE_URL` exist.

​```bash
# Provision the task's CronJob:
nagarectl deploy -f cluster/examples/app-cleanup-task/nagare/Config.hs

# It is scoped to the postgres-app app:
nagarectl task list postgres-app
#   NAME       APP            SCHEDULE     LAST RUN   LAST SUCCESS   ACTIVE
#   cleanup    postgres-app   0 3 * * *    never      never          0

# Run it once now (a one-off Job from the CronJob template — bypasses the schedule):
nagarectl task run postgres-app cleanup
#   Starting one-off run nagare-task-cleanup-manual-<timestamp> ...
#   job.batch/nagare-task-cleanup-manual-<timestamp> created
#   job.batch/nagare-task-cleanup-manual-<timestamp> condition met
#   Task cleanup completed (nagare-task-cleanup-manual-<timestamp>).

# Read the most recent run's logs (and the Grafana history hint):
nagarectl task logs postgres-app cleanup
#   <the cleanup pod's output>
#   For older runs, query VictoriaLogs in Grafana with: {nagare_dev_task="cleanup"}
​```

## Clean up

​```bash
nagarectl task delete postgres-app cleanup --yes   # removes the CronJob (idempotent)
​```
```

(Replace the zero-width-space-prefixed fences with plain triple backticks in the file.)

### M2.3 — verify the examples offline

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
runghc -XGHC2024 -icluster/examples/heartbeat-task/nagare \
  cluster/examples/heartbeat-task/nagare/Config.hs
runghc -XGHC2024 -icluster/examples/app-cleanup-task/nagare \
  cluster/examples/app-cleanup-task/nagare/Config.hs
```

Expected: each prints a single line of JSON beginning `{"kind":"Task",`. The `heartbeat` one has
`"app":null`; the `cleanup` one has `"app":"postgres-app"` and `"image":null`. If `runghc` cannot
find `Nagare.Dsl.*`, use the cabal/`--ghc-env` form the other examples use, or run from inside
`cli/nagare-dsl` with the package in scope. Then, where the CLI is buildable, render each CronJob:

```bash
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/heartbeat-task/nagare/Config.hs --dry-run
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/app-cleanup-task/nagare/Config.hs --dry-run
```

Expected (abbreviated) for the app-associated one:

```text
--- Task CronJob manifest ---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-cleanup
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: cleanup
    nagare.dev/app: postgres-app
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: cleanup
            envFrom:
            - configMapRef: { name: nagare-env-postgres-app-runtime, optional: true }
            - secretRef:    { name: nagare-secret-postgres-app-runtime, optional: true }
```

(The exact key ordering and image come from EP-50's renderer / EP-52's deploy-time resolution;
update the snippet to the real output during reconciliation. The inherited *image tag* is resolved
at deploy time, so a fully-offline render of an inheriting task may show a placeholder or require a
reachable cluster — note this in the README, exactly as the managed-database examples note that an
app referencing a database needs a reachable cluster to render.)

### M3.1 — the "Logs & observability" section

Add to `docs/user/scheduled-tasks.md`, before "Constraints and limits":

```markdown
## Logs & observability

`nagarectl task logs APP TASK` shows the most recent run's pod logs; add `--follow`
to tail a running one and `--tail N` to limit the lines. It selects pods by the
`nagare.dev/task=<task>` label (narrowed by app), so it always finds the right pods:

​```text
$ nagarectl task logs postgres-app cleanup
<the cleanup pod's most recent output>
For older runs, query VictoriaLogs in Grafana with: {nagare_dev_task="cleanup"}
​```

Task pods are ordinary Kubernetes pods, so the cluster's existing log collector
scrapes them automatically — no new wiring. For **history** beyond the most recent
run (every run a task has ever made, including ones whose Jobs have aged out of the
CronJob's history limit), open Grafana's Explore view on the VictoriaLogs data
source and run the LogsQL query:

​```text
{nagare_dev_task="cleanup"}
​```

To narrow to one namespace or app, combine the stream fields:

​```text
{kubernetes.pod_namespace="personal", nagare_dev_task="cleanup"}
​```

(The pod label `nagare.dev/task` appears in the log stream as `nagare_dev_task`,
with the dots and slash flattened to underscores; the namespace stream field is
`kubernetes.pod_namespace`, verified by the substrate spike.) See
[Observability](observability.md) for how to reach Grafana and the VictoriaLogs
data source.
```

### M3.2 — runbook pointer

Read `docs/runbooks/server-operations.md`. If it has a day-2 "operating workloads" or
"inspecting failures" section, add a brief pointer:

```markdown
**Scheduled tasks.** Inspect and run scheduled tasks with `nagarectl task
list/run/logs/delete` (see [Scheduled tasks](../user/scheduled-tasks.md)). A task's
CronJob is `nagare-task-<name>`; its history is in Grafana via the LogsQL query
`{nagare_dev_task="<name>"}`.
```

If the runbook has no natural home for this (it is purely host/cluster operations), record in
this plan's Decision Log that no runbook edit was made and why, and rely on the user guide instead.

### M3.3 — final reconciliation and commit

Re-run the real `nagarectl task --help` and the `--dry-run` forms, confirm every command, field,
label, and transcript in the guide and both READMEs matches, and mark the live legs deferred. Then
check fences and links once more:

```bash
grep -rn "scheduled-tasks.md" docs/
grep -rn '^```$' docs/user/scheduled-tasks.md \
  cluster/examples/heartbeat-task/README.md \
  cluster/examples/app-cleanup-task/README.md || echo "all fences tagged"
```

Commit the work in coherent chunks (the guide + cross-links, then the examples, then the
observability/runbook integration), following Conventional Commits and committing directly to the
current branch (no feature branch). Every commit on this plan carries these trailers:

```text
docs(tasks): EP-53 scheduled-tasks user guide and end-to-end examples

MasterPlan: docs/masterplans/10-scheduled-tasks-for-nagare.md
ExecPlan: docs/plans/53-scheduled-tasks-docs-and-end-to-end-examples.md
Intention: intention_01kts6qyg4ezsbj500ksjr90r1
```


## Validation and Acceptance

Acceptance is documentation-by-demonstration. Concretely:

1. `docs/user/scheduled-tasks.md` exists, is linked from `docs/user/README.md` (the "Read in this
   order" sub-bullet under item 8 and the "Area / Plan / Status" table row) and
   `docs/user/deploying-apps.md`, and is cross-linked from `docs/user/managed-databases.md`
   and/or `docs/user/persistent-storage.md` where natural. Every concept, `Task` field name,
   `nagarectl task` command and flag, the IP3 labels, the cron grammar, the inherited-variable
   table, and the precedence rule match MasterPlan 10's IP1–IP6 and EP-50/51/52's shipped surface
   (verified by reading their final sections, or by running `nagarectl task --help` and the
   dry-runs). Verify the link resolves: `grep -rn "scheduled-tasks.md" docs/` shows the index, the
   deploy guide, and the cross-linked sibling page(s).

2. `cluster/examples/heartbeat-task/nagare/Config.hs` emits valid JSON:
   `runghc -XGHC2024 -icluster/examples/heartbeat-task/nagare
   cluster/examples/heartbeat-task/nagare/Config.hs` prints one line beginning `{"kind":"Task",`
   with `"name":"heartbeat"`, `"schedule":"*/15 * * * *"`, and `"app":null`. Where the CLI is
   buildable, `nagarectl deploy -f .../Config.hs --dry-run` renders a `batch/v1` CronJob named
   `nagare-task-heartbeat` carrying `nagare.dev/managed-by: nagarectl` and `nagare.dev/task:
   heartbeat`, with `schedule: "*/15 * * * *"` and the `curlimages/curl` container.

3. `cluster/examples/app-cleanup-task/nagare/Config.hs` emits valid JSON beginning `{"kind":"Task",`
   with `"name":"cleanup"`, `"app":"postgres-app"`, and `"image":null`. Where the CLI is buildable,
   `deploy --dry-run` renders a `nagare-task-cleanup` CronJob carrying the `nagare.dev/app:
   postgres-app` label and a Job template whose container has an `envFrom` block referencing
   `nagare-env-postgres-app-runtime` and `nagare-secret-postgres-app-runtime` (each
   `optional: true`). (The inherited image tag is resolved at deploy time; if a fully-offline
   render cannot resolve it, the README says so, mirroring the managed-database examples.)

4. The guide's "Operating with `nagarectl task`" section shows a `task list` table, a `task run
   --dry-run` transcript with `kubectl create job ... --from=cronjob/nagare-task-<task>`, and a
   `task delete` plan/confirm pair, all matching EP-51's shipped output. The "Logs &
   observability" section shows `nagarectl task logs` and the LogsQL query
   `{nagare_dev_task="<task>"}`, and links `observability.md`.

5. On a live cluster (deferred-with-instructions): for at least one example, `nagarectl deploy`
   provisions the CronJob (it appears in `kubectl get cronjob -l
   nagare.dev/managed-by=nagarectl,nagare.dev/task -n personal`), `nagarectl task run` completes a
   one-off Job, and `nagarectl task logs` streams its output. These legs are marked "dry-run
   verified; live run deferred" in the example READMEs and this plan's Progress, with the exact
   on-VM commands.

6. No bare ``` ` ` ` ``` fences in any new or edited file (every block has a language tag):
   `grep -rn '^```$' docs/user/scheduled-tasks.md cluster/examples/heartbeat-task/README.md
   cluster/examples/app-cleanup-task/README.md` returns nothing.

Where a live cluster is unavailable, item 5's live legs are deferred-with-instructions, mirroring
`docs/plans/48-managed-databases-docs-and-end-to-end-examples.md`. The offline emit-and-render
checks (items 2–4) are mandatory and must pass regardless. There is no separate doc build; the
docs are read as Markdown in the repo. The "test" is that every command in each example README runs
and matches its shown output (or is marked live-deferred), and every `Config.hs` emits valid JSON.


## Idempotence and Recovery

All work here is additive: one new Markdown page, two new example directories, and edits to
existing docs (index links, a deploy-guide pointer, two cross-links, and an optional runbook
pointer). Every step is safe to re-run and re-render. `runghc` of a `Config.hs` and `nagarectl
deploy --dry-run` / `nagarectl task run --dry-run` have no side effects, so example verification
can be repeated freely. `git checkout <file>` recovers any bad edit.

The examples are provisionable repeatedly. `nagarectl deploy` applies CronJobs idempotently
(`kubectl apply` on a deterministic name `nagare-task-<name>`), so re-deploying reconciles rather
than duplicates. `nagarectl task run` creates a freshly-named one-off Job
(`nagare-task-<task>-manual-<timestamp>`) each time, so repeated runs never collide. `nagarectl
task delete <app> <task> --yes` is `--ignore-not-found`, so deleting an already-deleted task is a
no-op. Re-running any example README from the top is safe.

Because docs and examples are regenerable from this plan alone, recovery is simply re-applying the
Concrete Steps. No destructive or migration step exists in this plan.


## Interfaces and Dependencies

No code dependencies; this plan writes Markdown and example `Config.hs` files. It **documents — it
does not define** — the user-facing surfaces of the sibling plans, named here by path:

- `docs/plans/50-typed-task-model-and-cronjob-job-renderer.md` — the typed `Task` record
  (`taskName`, `taskNamespace`, `taskSchedule`, `taskImage`, `taskApp`, `taskCommand`, `taskArgs`,
  `taskEnv`, `taskResources`, `taskTimeoutSeconds`, `taskConcurrencyPolicy`, `taskRestartPolicy`,
  `taskBackoffLimit`, `taskSuccessfulJobsHistoryLimit`, `taskFailedJobsHistoryLimit`,
  `taskStartingDeadlineSeconds`), the `Schedule` newtype + `mkSchedule` and its cron grammar, the
  `ConcurrencyPolicy`/`RestartPolicy` enums, `mkTask`, the `scheduledTask` preset, the
  `emitTask`/`decodeTask` JSON path with the `"kind":"Task"` discriminator, the naming helper
  `taskResourceName` (`nagare-task-<name>`), and the rendered CronJob/Job YAML with the IP3 labels
  and the `envFrom` block (IP1, IP2, IP3). The config snippets in the guide and the example
  `Config.hs` files consume `emitTask`, `scheduledTask`, `Task (..)`, `mkSchedule`, and `mkTask`
  from `Nagare.Dsl.Task` / `Nagare.Dsl.Config`. **Hard dependency** — reconcile exact names against
  EP-50's final Concrete Steps before finalizing snippets.

- `docs/plans/51-nagarectl-task-lifecycle-commands-and-deploy-time-provisioning.md` — the
  `nagarectl task list|run|logs|delete` command group (IP4), the optional/required `APP` positional
  and the `-` sentinel, the label-based discovery selector
  `nagare.dev/managed-by=nagarectl,nagare.dev/task`, the one-off run via
  `kubectl create job --from=cronjob/nagare-task-<task>` and the deterministic Job name
  `nagare-task-<task>-manual-<timestamp>`, the `task logs` selector and the Grafana hint
  `{nagare_dev_task="<task>"}`, and deploy-time provisioning that applies declared task CronJobs
  (IP6). The guide and examples document and exercise these commands. **Soft dependency** — verify
  the real `task --help` and the `task run --dry-run` transcript.

- `docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md` — the
  app↔task association (`taskApp`), the deploy-time resolution of the app's image tag, the inherited
  `envFrom` references to `nagare-env-<app>-runtime` / `nagare-secret-<app>-runtime`, the predefined
  task variables (`NAGARE_TASK_NAME`, `NAGARE_RUN_ID`), and the `nagare.dev/app` label (IP5). The
  "Running in an app's world" section, the inherited-variable table, and the precedence rule depend
  on this. **Soft dependency** — the inherited-variable table and precedence rule are the most
  accuracy-critical artifacts; verify them against EP-52's final Concrete Steps and a real `deploy
  --dry-run`, and record any divergence in the Decision Log.

- `docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md` — the verified
  VictoriaLogs stream fields (`kubernetes.pod_namespace`, `kubernetes.pod_name`,
  `kubernetes.container_name`) and the confirmed task-log query `{nagare_dev_task="<task>"}`. The
  "Logs & observability" section cites this. **Soft dependency** (for the query string).

New files this plan creates:

- `docs/user/scheduled-tasks.md` (the new guide).
- `cluster/examples/heartbeat-task/nagare/Config.hs`, `cluster/examples/heartbeat-task/README.md`.
- `cluster/examples/app-cleanup-task/nagare/Config.hs`,
  `cluster/examples/app-cleanup-task/README.md`.

Files this plan edits:

- `docs/user/README.md` (index the new page: the "Read in this order" sub-bullet and the
  "Area / Plan / Status" table row).
- `docs/user/deploying-apps.md` (a "scheduled tasks" pointer).
- `docs/user/managed-databases.md` and/or `docs/user/persistent-storage.md` (a one-line cross-link
  where natural).
- `docs/runbooks/server-operations.md` (a brief scheduled-tasks pointer, if a natural home exists;
  otherwise the Decision Log records why none was added).

The only "interface" this plan must keep accurate is that the documented `Task` field names, the
`nagarectl task` command and flag names, the CronJob name `nagare-task-<name>` and its labels
(`nagare.dev/managed-by`, `nagare.dev/task`, `nagare.dev/app`), the inherited-env references
(`nagare-env-<app>-runtime` / `nagare-secret-<app>-runtime`), the predefined task variables, the
one-off-run command (`kubectl create job --from=cronjob/...`), and the LogsQL query
`{nagare_dev_task="<task>"}` match what EP-50/51/52 actually shipped. Re-read their final sections
(and run the real `--help`/`--dry-run`) before writing the snippets and transcripts, and record any
divergence in this plan's Decision Log. All cloud reads and writes target the `tan-nb-exp` project /
`us-west1` region only, per the repository `CLAUDE.md`.
