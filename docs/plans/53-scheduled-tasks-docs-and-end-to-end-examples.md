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

Full plan before trimming: [53-scheduled-tasks-docs-and-end-to-end-examples.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/53-scheduled-tasks-docs-and-end-to-end-examples.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

