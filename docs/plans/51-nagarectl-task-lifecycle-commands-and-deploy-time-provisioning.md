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

- [ ] Create `cli/nagarectl/src/Nagare/Task/Discover.hs` with `taskLabelSelector`,
      `TaskRow (..)`, `extractTaskRows`, `listTasks`, `getTask`, `formatTaskTable`.
- [ ] Create `cli/nagarectl/src/Nagare/Task/List.hs` with `runTaskList`.
- [ ] Create `cli/nagarectl/src/Nagare/Task/Delete.hs` with `TaskDeleteParams (..)` and
      `runTaskDelete`.
- [ ] Add the `TaskCommand` ADT and the `Task` constructor to `Command` in `app/Main.hs`.
- [ ] Add `taskCmd`/`taskSubparser`, the option parsers, and the `runTask` dispatcher for
      `list`/`delete` in `app/Main.hs`; wire `Task` into `main`.
- [ ] Register `Nagare.Task.Discover`, `Nagare.Task.List`, `Nagare.Task.Delete` in
      `nagarectl.cabal`.
- [ ] Add the captured fixture `cli/nagarectl/test/fixtures/cronjob-list.json` and unit
      tests for `taskLabelSelector`, `extractTaskRows`, `formatTaskTable`.
- [ ] `cabal build` and `cabal test nagarectl-test` pass; document the on-VM live check.

Milestone M2 — `task run` (one-off) + `task logs`:

- [ ] Create `cli/nagarectl/src/Nagare/Task/Run.hs` with `oneOffJobName`, `runArgs`,
      `TaskRunParams (..)`, `runTaskRun`.
- [ ] Create `cli/nagarectl/src/Nagare/Task/Logs.hs` with `TaskLogTarget (..)`,
      `taskLogArgs`, `grafanaHint`, `runTaskLogs`.
- [ ] Add the `TaskRun`/`TaskLogs` constructors, parsers, and dispatch arms.
- [ ] Register `Nagare.Task.Run`, `Nagare.Task.Logs` in `nagarectl.cabal`.
- [ ] Unit-test `oneOffJobName` (deterministic given a `UTCTime`), `runArgs`, and
      `taskLogArgs`.
- [ ] `cabal test nagarectl-test` passes; capture a `task run --dry-run` transcript;
      document the live run on the VM with the expected transcript.

Milestone M3 — deploy-time provisioning:

- [ ] Extend `Nagare.Deploy` (or `app/Main.hs:runDeploy`) so declared tasks are rendered
      with EP-50's `renderTask` and applied alongside the Service/PVCs/databases.
- [ ] Show each rendered CronJob in `deploy --dry-run`.
- [ ] `cabal build` passes; capture a `deploy --dry-run` transcript showing the CronJob;
      document the live provisioning check on the VM.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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

(To be filled during and after implementation.)


## Context and Orientation

This section orients a reader who knows nothing about this repository. Read it in full
before editing anything.

### The `nagarectl` package

`nagarectl` is a Haskell command-line program. Its source lives under
`cli/nagarectl/`. The two relevant build artifacts are described by the Cabal file
`cli/nagarectl/nagarectl.cabal`:

- A **library** (`library` stanza, `hs-source-dirs: src`) containing all the reusable
  logic in modules under `cli/nagarectl/src/Nagare/`. Every module that does real work
  (discovering objects, rendering, deploying) is a library module listed under
  `exposed-modules`. You will add five new modules here under `Nagare/Task/`.
- An **executable** named `nagarectl` (`executable nagarectl` stanza,
  `hs-source-dirs: app`, `main-is: Main.hs`). The single file
  `cli/nagarectl/app/Main.hs` defines the command-line surface: a big `Command`
  algebraic data type ("ADT" — a Haskell sum type, one constructor per top-level command),
  the `optparse-applicative` parsers that turn `argv` into a `Command`, and the dispatcher
  that pattern-matches a `Command` and calls into the library.
- A **test suite** named `nagarectl-test` (`test-suite nagarectl-test` stanza,
  `hs-source-dirs: test`, `main-is: Spec.hs`). The single file
  `cli/nagarectl/test/Spec.hs` runs offline unit tests using `tasty` and `tasty-hunit`.
  These tests must never require a live cluster: they exercise *pure* helper functions
  (functions with no `IO`) only.

Build and test from inside the package directory:

```bash
cd cli/nagarectl
cabal build
cabal test nagarectl-test
```

The error convention everywhere in this CLI is: print `nagarectl: <message>` to standard
error and exit with a non-zero status. The shared helper for that is `dieT :: Text -> IO a`
in `cli/nagarectl/app/Main.hs` (around line 2044). Library modules that need the same
behaviour inline it (for example `cli/nagarectl/src/Nagare/Database/List.hs` writes
`"nagarectl: " <> err` to `stderr` then calls `exitFailure`).

### The optparse command tree

`optparse-applicative` is the command-line parsing library. In `cli/nagarectl/app/Main.hs`
the pattern for a *command group* (a top-level command with sub-commands, like
`nagarectl db <verb>`) is:

1. A constructor on the top-level `Command` ADT that wraps a group-specific ADT — for
   databases this is `Db DbCommand` (line ~292), where `DbCommand` (lines ~347–355) has one
   constructor per `db` sub-command (`DbList`, `DbCreate`, `DbGet`, …).
2. A `subparser` block that declares each sub-command with `command "name" (info (...)
   (progDesc "..."))`. For databases this is `dbSubparser`, built inside `dbCmd` (lines
   ~1098–1159). Each `command` builds the matching `DbCommand` constructor from option
   parsers.
3. Small reusable option parsers. The ones you will reuse are `namespaceOpt :: Parser
   (Maybe String)` (lines ~591–600, the `-n/--namespace` flag, `Nothing` means the
   `personal` namespace), `dryRunOpt :: Parser Bool` (lines ~518–523, the `--dry-run`
   switch), and the positional-argument helpers built with `strArgument` (for example
   `dbNameArg`, line ~710).
4. A dispatcher that pattern-matches the group ADT and calls library functions — for
   databases this is `runDb :: DbCommand -> IO ()` (lines ~1844–1880). It defines a local
   `nsOf = maybe "personal" T.pack` to turn the optional namespace string into a `Text`
   namespace, defaulting to `personal`.
5. The top-level `main` (lines ~1183 onward) calls `execParser opts` to get a `Command`,
   then pattern-matches it. The `Db dbc -> runDb dbc` arm is the model; you add `Task tc ->
   runTask tc`.

The `db` command group's `command "list"` entry registers `nagarectl db list`, and so on.
You will mirror this structure exactly for `nagarectl task`.

### The Cradle kubectl wrapper

Every shell-out in this CLI goes through the `cradle` library, imported as `import Cradle`.
The two shapes you need:

- **Capture output**: build a command with `cmd "kubectl" & addArgs [..]`, optionally
  `& silenceStderr`, then `& run` (or `run $ cmd ...`). Bind the result as
  `(code, StdoutRaw out)` where `code :: ExitCode` (from `System.Exit`) and `out` is a
  strict `ByteString`. This is how `listDatabases` in
  `cli/nagarectl/src/Nagare/Database/Discover.hs` reads JSON: it captures
  `kubectl get statefulset ... -o json` and parses `out`.
- **Inherit stdout/stderr** (for streaming logs or a blocking wait the user should see):
  use `run_ $ cmd "kubectl" & addArgs [..]`. This does not capture output; the child's
  stdout/stderr go straight to the terminal. This is how `streamServiceLogs` in
  `cli/nagarectl/src/Nagare/App.hs` (line ~125) tails logs, and how `waitForJob` in
  `cli/nagarectl/src/Nagare/Database/Backup.hs` (lines ~392–404) tails a Job.

`&` is just reverse function application (`x & f = f x`); read `cmd "kubectl" & addArgs xs &
run` as "build the kubectl command, add args, run it". `StdoutRaw` is a Cradle newtype that
asks Cradle to give you the raw bytes; `StdoutUntrimmed` (used by `waitForJob`) keeps
trailing whitespace; both are interchangeable for our purposes since we only check the
exit code or hand bytes to Aeson.

### The discovery pattern (the template to copy)

`cli/nagarectl/src/Nagare/Database/Discover.hs` is the canonical "find Nagare-managed
objects by label and parse the JSON defensively" module. Study it in full; your
`Nagare/Task/Discover.hs` is its sibling. Its shape:

- `dbLabelSelector :: Text` is the constant `"nagare.dev/managed-by=nagarectl,nagare.dev/database"`.
- `listDatabases :: Text -> IO (Either Text [DbRow])` runs `kubectl get statefulset -n <ns>
  -l <selector> -o json` (captured), and on a failed exit returns `Right []` (an empty list,
  not an error — a missing namespace or unreachable cluster simply means "no databases"),
  while a *successful* exit with malformed JSON returns `Left`.
- `extractDbRows :: ByteString -> Either Text [DbRow]` is the **pure** parser: decode the
  bytes with `eitherDecodeStrict`, look at `.items`; an absent/empty `items` yields
  `Right []`, a malformed top-level shape yields `Left`, and any single item missing
  `.metadata.name` is *skipped* (not fatal). The private JSON-walking helpers
  `lookupPath`, `textAt`, `labelAt`, `annotationAt` (lines ~227–242) walk the `Aeson.Value`
  by a path of keys. Copy these helpers verbatim into your module (they are intentionally
  module-local; the database module copied them from the storage module the same way).
- `formatDbTable :: [DbRow] -> Text` renders an aligned table with a local `pad` helper.

Because `extractDbRows` and `formatDbTable` are pure, they are unit-tested in `Spec.hs`
against in-memory bytes — no cluster needed. You do the same for `extractTaskRows` and
`formatTaskTable`.

### How `deploy` applies manifests today

`cli/nagarectl/app/Main.hs:runDeploy` (lines ~1284–1371) is the deploy path. It loads the
typed `Deployment` from the config file (`Load.loadDeployment`), renders the PVCs, the
Knative Service, and the DomainMappings, and on a real (non-dry-run) deploy calls
`applyPVCs pvcBytes` then `applyManifests (svcBytes : dmBytes)` (lines ~1360–1361). In
`--dry-run` mode (lines ~1333–1345) it instead prints each manifest under a `--- ...
manifest ---` banner. `applyManifests :: [ByteString] -> IO ()` lives in
`cli/nagarectl/src/Nagare/Deploy.hs` (lines ~39–45): it writes each manifest to a temp file
and runs `kubectl apply -f`. M3 hooks declared tasks into both the dry-run print and the
live apply here.

The typed `Deployment` record is defined in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` (line ~578). It already carries `volumes ::
[Volume]` (line ~604) and `databases :: [DatabaseName]` (line ~609). EP-50 adds the field
that carries declared tasks (its exact name and type are owned by EP-50's IP1; this plan
refers to it abstractly as "the deployment's declared tasks" and reads whatever EP-50
exposes). If EP-50 names it `tasks :: [Task]`, M3 reads `dep ^. #tasks`.

### What EP-50 gives you (the hard dependency)

This plan does not compile until `docs/plans/50-typed-task-model-and-cronjob-job-renderer.md`
is implemented. From EP-50 you consume, by full module path:

- The typed value `Nagare.Dsl.Task.Task` (a validated record describing one task).
- The renderer `Nagare.Dsl.Task.Render.renderTask :: Task -> ByteString` (or whatever exact
  name/signature EP-50 settles on) that turns a `Task` into a single `batch/v1` CronJob YAML
  document. M3 calls this and feeds the bytes to `applyManifests`.
- The naming/label contract (IP3): the CronJob is named `nagare-task-<taskName>`; every
  rendered object carries `nagare.dev/managed-by: nagarectl`, `nagare.dev/task: <taskName>`,
  and optionally `nagare.dev/app: <appName>`. This plan hard-codes the selector strings and
  the `nagare-task-` name prefix to match this contract, exactly as the database CLI
  hard-codes `nagare-` prefixes to match EP-44/EP-45.

If EP-50's final field/function names differ from the names assumed here, reconcile by
adjusting only the M3 wiring and the import lines; the discovery/run/logs/delete modules
depend only on the *cluster* (labels and names), not on EP-50's Haskell types, so they are
unaffected.


## Plan of Work

The work is three milestones. Each is independently verifiable: M1 and M2 add CLI commands
that you can exercise with `--dry-run` and unit tests offline, plus a documented live check
on the VM; M3 wires provisioning into `deploy` and is verifiable through `deploy --dry-run`.

### Milestone M1 — `task list` and `task delete`, backed by `Nagare.Task.Discover`

**Scope.** Introduce the discovery module and the two read/remove commands, plus the whole
`task` command-group skeleton in `Main.hs` (the `TaskCommand` ADT, the subparser, the
dispatcher), so that the later milestones only add constructors. At the end of M1,
`nagarectl task list` prints a table of task CronJobs discovered by label, and `nagarectl
task delete APP TASK` removes one idempotently. The pure parser is unit-tested against a
checked-in JSON fixture.

**Files created:** `cli/nagarectl/src/Nagare/Task/Discover.hs`,
`cli/nagarectl/src/Nagare/Task/List.hs`, `cli/nagarectl/src/Nagare/Task/Delete.hs`,
`cli/nagarectl/test/fixtures/cronjob-list.json`.
**Files edited:** `cli/nagarectl/app/Main.hs`, `cli/nagarectl/nagarectl.cabal`,
`cli/nagarectl/test/Spec.hs`.

**Commands to run:** `cd cli/nagarectl && cabal build && cabal test nagarectl-test`.

**Acceptance:** the test suite passes (including the new `extractTaskRows` tests against the
fixture); `cabal run nagarectl -- task list --help` shows the new command; the on-VM live
check (documented below, deferred like EP-48's live legs) lists a real CronJob.

### Milestone M2 — `task run` (one-off execution) and `task logs`

**Scope.** Add the one-off run (IP6) and the log viewer (IP6). `task run` builds a
deterministic Job name, runs `kubectl create job <name> --from=cronjob/nagare-task-<task>`,
waits for completion with `kubectl wait --for=condition=complete`, tails logs on failure,
and reports. `--dry-run` prints the constructed command and runs nothing. `task logs`
streams pod logs by the IP3 label selector and prints a Grafana/VictoriaLogs hint.

**Files created:** `cli/nagarectl/src/Nagare/Task/Run.hs`,
`cli/nagarectl/src/Nagare/Task/Logs.hs`.
**Files edited:** `cli/nagarectl/app/Main.hs`, `cli/nagarectl/nagarectl.cabal`,
`cli/nagarectl/test/Spec.hs`.

**Commands to run:** `cd cli/nagarectl && cabal build && cabal test nagarectl-test`, then
`cabal run nagarectl -- task run myapp cleanup --dry-run`.

**Acceptance:** the test suite passes (including `oneOffJobName`, `runArgs`, `taskLogArgs`
tests); the `--dry-run` transcript shows the exact `kubectl create job ... --from=cronjob/...`
command; the on-VM live run (documented below) completes a Job and streams its logs.

### Milestone M3 — deploy-time provisioning

**Scope.** Make `nagarectl deploy` render and apply declared task CronJobs. In dry-run,
print each rendered CronJob under a banner; in a live deploy, apply them with
`applyManifests` after the PVCs and alongside the Service.

**Files edited:** `cli/nagarectl/app/Main.hs` (the `runDeploy` function), and possibly
`cli/nagarectl/src/Nagare/Deploy.hs` if a small helper is cleaner.

**Commands to run:** `cd cli/nagarectl && cabal build`, then `cabal run nagarectl -- deploy
--dry-run -f <config-with-tasks>`.

**Acceptance:** `cabal build` passes; the `deploy --dry-run` transcript shows a `--- Task
CronJob manifest ---` banner with the rendered CronJob; the on-VM live deploy (documented
below) leaves a `nagare-task-<name>` CronJob in the cluster.


## Concrete Steps

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`. All
`cabal` commands run from `cli/nagarectl`.

### M1.1 — `cli/nagarectl/src/Nagare/Task/Discover.hs`

Create this file. It mirrors `cli/nagarectl/src/Nagare/Database/Discover.hs`. The
`TaskRow` reads the CronJob's schedule from `.spec.schedule`, the app from the
`nagare.dev/app` label (absent for app-less tasks), and the run timestamps and active count
from `.status`.

```haskell
{-# LANGUAGE PackageImports #-}

-- | Shared scheduled-task discovery for the @nagarectl task@ commands
-- (MasterPlan 10, EP-51, Integration Point IP4).
--
-- This module owns the task label selector, the defensive
-- @kubectl get cronjob -o json@ parse, and the @task list@ table formatter. The
-- pure parts ('taskLabelSelector', 'extractTaskRows', 'formatTaskTable') are
-- separated from the @kubectl@ IO so they are unit-testable without a cluster,
-- exactly as 'Nagare.Database.Discover' separates 'dbLabelSelector' /
-- 'extractDbRows' / 'formatDbTable'. EP-52 narrows the same query to one app by
-- appending @,nagare.dev/app=<app>@ to the selector — it must extend, not fork,
-- this module.
module Nagare.Task.Discover
  ( taskLabelSelector
  , AppScope (..)
  , TaskRow (..)
  , extractTaskRows
  , listTasks
  , getTask
  , formatTaskTable
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text qualified as T
import Data.Vector qualified as V
import System.Exit (ExitCode (..))

-- | How a command scopes discovery by the @nagare.dev/app@ label.
--
-- * 'AnyApp' — do not constrain by app (the @task list@ default; lists every task).
-- * 'NoApp' — only tasks with NO @nagare.dev/app@ label (the @-@ sentinel app).
-- * 'App name' — only tasks whose @nagare.dev/app@ equals @name@.
data AppScope = AnyApp | NoApp | App Text
  deriving stock (Eq, Show)

-- | The base label selector that finds every Nagare-managed task CronJob (IP3/IP4):
-- managed by nagarectl AND carrying the @nagare.dev/task@ label. EP-52 narrows by
-- 'AppScope'; it never re-derives names.
taskLabelSelector :: AppScope -> Text
taskLabelSelector scope = base <> appTerm scope
  where
    base = "nagare.dev/managed-by=nagarectl,nagare.dev/task"
    appTerm AnyApp = ""
    appTerm NoApp = ",!nagare.dev/app"
    appTerm (App a) = ",nagare.dev/app=" <> a

-- | One discovered scheduled task, read back from its CronJob.
data TaskRow = TaskRow
  { trName :: !Text
  -- ^ the task name (the @nagare.dev/task@ label, falling back to the object name
  -- with the @nagare-task-@ prefix stripped)
  , trApp :: !Text
  -- ^ the owning app (@nagare.dev/app@ label) or @"-"@ when app-less
  , trSchedule :: !Text
  -- ^ @.spec.schedule@ (the cron expression) or @"?"@
  , trLastRun :: !Text
  -- ^ @.status.lastScheduleTime@ or @"never"@
  , trLastSuccess :: !Text
  -- ^ @.status.lastSuccessfulTime@ or @"never"@
  , trActive :: !Int
  -- ^ number of currently-active Jobs (@length .status.active@)
  }
  deriving stock (Generic, Eq, Show)

-- | Parse a @kubectl get cronjob -n <ns> -l <selector> -o json@ list into rows.
-- Defensive (mirrors 'Nagare.Database.Discover.extractDbRows'): an empty/absent
-- @items@ array is @Right []@, a malformed top-level shape is a 'Left', and an item
-- with no @.metadata.name@ is skipped rather than fatal.
extractTaskRows :: ByteString -> Either Text [TaskRow]
extractTaskRows bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode cronjob list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) -> Right (foldr step [] (V.toList items))
      _ -> Right []
  where
    step item acc = case rowFromItem item of
      Just r -> r : acc
      Nothing -> acc

rowFromItem :: Aeson.Value -> Maybe TaskRow
rowFromItem item = do
  objName <- textAt ["metadata", "name"] item
  let taskName =
        fromMaybe
          (stripTaskPrefix objName)
          (labelAt "nagare.dev/task" item)
  pure
    TaskRow
      { trName = taskName
      , trApp = fromMaybe "-" (labelAt "nagare.dev/app" item)
      , trSchedule = fromMaybe "?" (textAt ["spec", "schedule"] item)
      , trLastRun = fromMaybe "never" (textAt ["status", "lastScheduleTime"] item)
      , trLastSuccess = fromMaybe "never" (textAt ["status", "lastSuccessfulTime"] item)
      , trActive = activeCount item
      }

-- | Strip the @nagare-task-@ name prefix EP-50 stamps (IP3), if present.
stripTaskPrefix :: Text -> Text
stripTaskPrefix n = fromMaybe n (T.stripPrefix "nagare-task-" n)

activeCount :: Aeson.Value -> Int
activeCount item =
  case lookupPath ["status", "active"] item of
    Just (Aeson.Array a) -> V.length a
    _ -> 0

-- | List managed tasks in @ns@ matching @scope@ via @kubectl get cronjob -l
-- <selector> -o json@. A failed query (missing namespace, unreachable cluster) is
-- @Right []@; a present-but-malformed response is a 'Left'.
listTasks :: Text -> AppScope -> IO (Either Text [TaskRow])
listTasks ns scope = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "get"
          , "cronjob"
          , "-n"
          , T.unpack ns
          , "-l"
          , T.unpack (taskLabelSelector scope)
          , "-o"
          , "json"
          ]
        & silenceStderr
  pure $ case code of
    ExitFailure _ -> Right []
    ExitSuccess -> extractTaskRows out

-- | Look up a single task by name in @ns@, scoped by @scope@. @Left@ with a clear
-- message when no managed task of that name exists in that scope.
getTask :: Text -> AppScope -> Text -> IO (Either Text TaskRow)
getTask ns scope name = do
  rows <- listTasks ns scope
  pure $ case rows of
    Left e -> Left e
    Right rs -> case find ((== name) . trName) rs of
      Just r -> Right r
      Nothing -> Left ("no managed task named '" <> name <> "' in namespace " <> ns)

-- | Render the @task list@ table with @pad@-aligned columns.
formatTaskTable :: [TaskRow] -> Text
formatTaskTable [] = "(no scheduled tasks)\n"
formatTaskTable rows = T.unlines (header : map line rows)
  where
    header =
      "  "
        <> pad 18 "NAME"
        <> pad 12 "APP"
        <> pad 16 "SCHEDULE"
        <> pad 22 "LAST RUN"
        <> pad 22 "LAST SUCCESS"
        <> "ACTIVE"
    line r =
      T.concat
        [ "  "
        , pad 18 (trName r)
        , pad 12 (trApp r)
        , pad 16 (trSchedule r)
        , pad 22 (trLastRun r)
        , pad 22 (trLastSuccess r)
        , tShow (trActive r)
        ]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- ---------------------------------------------------------------------------
-- JSON walking (local copies; mirror Nagare.Database.Discover's private helpers)

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

labelAt :: Text -> Aeson.Value -> Maybe Text
labelAt key = textAt ["metadata", "labels", key]
```

Notes for the implementer: `tShow` and `fromMaybe` come from `Nagare.Dsl.Prelude` (the
package-wide prelude these modules import; `Nagare.Database.Discover` relies on the same
`fromMaybe`/`tShow`). If `tShow` is not in scope, define it locally as `tShow = T.pack .
show`. The `{-# LANGUAGE PackageImports #-}` pragma and the `import Nagare.Dsl.Prelude`
match the database module's header verbatim.

### M1.2 — `cli/nagarectl/src/Nagare/Task/List.hs`

Mirror `cli/nagarectl/src/Nagare/Database/List.hs`.

```haskell
{-# LANGUAGE PackageImports #-}

-- | @nagarectl task list [APP]@ (MasterPlan 10, EP-51): print a table of scheduled
-- tasks in a namespace, discovered by the IP3 labels. Read-only. With no @APP@ it
-- lists every task; with @APP@ it lists only that app's tasks; with the @-@ sentinel
-- it lists only app-less tasks.
module Nagare.Task.List
  ( runTaskList
  ) where

import Nagare.Dsl.Prelude

import Data.Text.IO qualified as TIO
import Nagare.Task.Discover (AppScope, formatTaskTable, listTasks)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Print the @NAME APP SCHEDULE LAST-RUN LAST-SUCCESS ACTIVE@ table for the
-- namespace and app scope.
runTaskList :: Text -> AppScope -> IO ()
runTaskList ns scope = do
  erows <- listTasks ns scope
  case erows of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right rows -> TIO.putStr (formatTaskTable rows)
```

### M1.3 — `cli/nagarectl/src/Nagare/Task/Delete.hs`

Mirror `cli/nagarectl/src/Nagare/Database/Delete.hs`, but a task is a single CronJob, so
deletion is one `kubectl delete cronjob nagare-task-<task> --ignore-not-found`. The optional
run-history ConfigMap (`nagare-task-runs-<task>`) is deleted too — also `--ignore-not-found`
— so the command stays correct if a later plan adds that ConfigMap. There is no retention
policy to honour (tasks own no persistent data), so the only guard is `--yes` (without it,
or with `--dry-run`, the plan is printed and nothing is deleted).

```haskell
{-# LANGUAGE PackageImports #-}

-- | @nagarectl task delete APP TASK@ (MasterPlan 10, EP-51): remove a scheduled
-- task. Deletes its CronJob @nagare-task-<task>@ and any run-history ConfigMap
-- @nagare-task-runs-<task>@, each @--ignore-not-found@ so the command is idempotent.
-- Guarded by @--yes@: without it (or with @--dry-run@), the deletion plan is printed
-- and nothing is deleted. Verifies the task exists first (scoped by @APP@) so a typo
-- fails clearly instead of silently deleting nothing.
module Nagare.Task.Delete
  ( TaskDeleteParams (..)
  , runTaskDelete
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Task.Discover (AppScope, getTask)
import System.Exit (exitFailure)
import System.IO (stderr)

data TaskDeleteParams = TaskDeleteParams
  { tdpName :: !Text
  , tdpNamespace :: !Text
  , tdpScope :: !AppScope
  , tdpYes :: !Bool
  , tdpDryRun :: !Bool
  }
  deriving stock (Generic, Show)

runTaskDelete :: TaskDeleteParams -> IO ()
runTaskDelete p = do
  erow <- getTask (tdpNamespace p) (tdpScope p) (tdpName p)
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right _ -> do
      let ns = tdpNamespace p
          objs = objectsToDelete (tdpName p)
      if not (tdpYes p) || tdpDryRun p
        then
          TIO.putStr $
            T.unlines (["Would delete (run again with --yes):"] <> map ("  " <>) objs)
        else do
          mapM_ (deleteObj ns) objs
          TIO.putStrLn ("Deleted task " <> tdpName p)

-- | The objects deleted for one task: its CronJob, then any run-history ConfigMap.
objectsToDelete :: Text -> [Text]
objectsToDelete task =
  [ "cronjob/nagare-task-" <> task
  , "configmap/nagare-task-runs-" <> task
  ]

deleteObj :: Text -> Text -> IO ()
deleteObj ns obj =
  run_ $
    cmd "kubectl"
      & addArgs ["delete", T.unpack obj, "-n", T.unpack ns, "--ignore-not-found"]
```

### M1.4 — wire the command group into `cli/nagarectl/app/Main.hs`

Make four edits. (a) Add the `Task TaskCommand` constructor to the top-level `Command` ADT,
right after `Db DbCommand` (line ~292):

```haskell
  | Db DbCommand
  | Task TaskCommand
```

(b) Add the `TaskCommand` ADT and its option records near the `DbCommand` block (after line
~355). The `AppScope` import comes from `Nagare.Task.Discover`.

```haskell
-- | The @task@ subcommands (MasterPlan 10, EP-51, Integration Point IP4). One
-- constructor per subcommand, mirroring 'DbCommand'. EP-52 may add app-scoping
-- flags but must extend, not fork, this group.
data TaskCommand
  = TaskList TaskListOpts -- ^ nagarectl task list [APP] [-n NS]
  | TaskRun TaskRunOpts -- ^ nagarectl task run APP TASK [-n NS] [--dry-run]
  | TaskLogs TaskLogsOpts -- ^ nagarectl task logs APP TASK [-n NS] [--follow] [--tail N]
  | TaskDelete TaskDeleteOpts -- ^ nagarectl task delete APP TASK [-n NS] [--yes] [--dry-run]

-- | Options for @task list [APP]@: an optional positional APP (scopes by the
-- @nagare.dev/app@ label; @-@ means app-less) and a namespace.
data TaskListOpts = TaskListOpts
  { tloApp :: !(Maybe String)
  , tloNamespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | The positional APP + TASK plus a namespace, shared by run/logs/delete.
data TaskRunOpts = TaskRunOpts
  { troApp :: !String
  , troTask :: !String
  , troNamespace :: !(Maybe String)
  , troDryRun :: !Bool
  }
  deriving stock (Generic, Show)

data TaskLogsOpts = TaskLogsOpts
  { tloApp :: !String
  , tloTask :: !String
  , tloNamespace :: !(Maybe String)
  , tloFollow :: !Bool
  , tloTail :: !(Maybe Int)
  }
  deriving stock (Generic, Show)

data TaskDeleteOpts = TaskDeleteOpts
  { tdoApp :: !String
  , tdoTask :: !String
  , tdoNamespace :: !(Maybe String)
  , tdoYes :: !Bool
  , tdoDryRun :: !Bool
  }
  deriving stock (Generic, Show)
```

(c) Add the option parsers near the database parsers (after line ~765) and the `taskCmd`
subparser near `dbCmd` (after line ~1159). The `appScopeFromArg`/`requiredAppScope` helpers
translate the positional `APP` (and the `-` sentinel) into an `AppScope`.

```haskell
-- Scheduled-task option fragments (MasterPlan 10, EP-51).

-- | The positional TASK argument every @task ... TASK@ command takes.
taskNameArg :: Parser String
taskNameArg = strArgument (metavar "TASK" <> help "Scheduled task name (DNS label)")

-- | The positional APP argument: scopes by the @nagare.dev/app@ label. @-@ means
-- "tasks with no app association".
taskAppArg :: Parser String
taskAppArg = strArgument (metavar "APP" <> help "Owning app (or - for app-less tasks)")

taskListOptsParser :: Parser TaskListOpts
taskListOptsParser =
  TaskListOpts
    <$> optional (strArgument (metavar "APP" <> help "Owning app to scope to (or - for app-less; omit for all)"))
    <*> namespaceOpt

taskRunOptsParser :: Parser TaskRunOpts
taskRunOptsParser =
  TaskRunOpts <$> taskAppArg <*> taskNameArg <*> namespaceOpt <*> dryRunOpt

taskLogsOptsParser :: Parser TaskLogsOpts
taskLogsOptsParser =
  TaskLogsOpts
    <$> taskAppArg
    <*> taskNameArg
    <*> namespaceOpt
    <*> switch (long "follow" <> help "Stream logs until interrupted")
    <*> optional (option auto (long "tail" <> metavar "N" <> help "Show only the last N lines"))

taskDeleteOptsParser :: Parser TaskDeleteOpts
taskDeleteOptsParser =
  TaskDeleteOpts
    <$> taskAppArg
    <*> taskNameArg
    <*> namespaceOpt
    <*> switch (long "yes" <> help "Confirm deletion (without it, prints the plan and deletes nothing)")
    <*> dryRunOpt
```

```haskell
    taskCmd =
      info
        (taskSubparser <**> helper)
        (fullDesc <> progDesc "List, run, view logs for, and delete scheduled tasks (CronJobs)")
    taskSubparser =
      subparser
        ( command
            "list"
            ( info
                (Task . TaskList <$> taskListOptsParser <**> helper)
                (progDesc "List scheduled tasks (optionally scoped to one app)")
            )
            <> command
              "run"
              ( info
                  (Task . TaskRun <$> taskRunOptsParser <**> helper)
                  (progDesc "Run a task once, now: create a Job from its CronJob and wait; --dry-run prints the command")
              )
            <> command
              "logs"
              ( info
                  (Task . TaskLogs <$> taskLogsOptsParser <**> helper)
                  (progDesc "Show a task's most recent pod logs (--follow to tail); prints a Grafana history hint")
              )
            <> command
              "delete"
              ( info
                  (Task . TaskDelete <$> taskDeleteOptsParser <**> helper)
                  (progDesc "Delete a task's CronJob (guarded by --yes)")
              )
        )
```

You must also register `taskCmd` as a top-level command in the same `subparser` that lists
`db`, `deployments`, etc. Find the top-level command list (where `command "db" dbCmd` is
declared) and add `<> command "task" taskCmd` next to it. (Search `app/Main.hs` for
`"db" dbCmd` — the precise surrounding lines vary; add the `task` entry in the same block.)

(d) Add the `Task tc -> runTask tc` arm to `main` (after the `Db dbc -> runDb dbc` arm,
around line ~1200) and the `runTask` dispatcher (after `runDb`, around line ~1880). The
`appScopeOf` helper turns the optional/required `APP` string into an `AppScope`.

```haskell
    Db dbc -> runDb dbc
    Task tc -> runTask tc
```

```haskell
runTask :: TaskCommand -> IO ()
runTask = \case
  TaskList o -> runTaskList (nsOf (tloNamespace o)) (scopeOfMaybe (tloApp o))
  TaskRun o ->
    runTaskRun
      TaskRunParams
        { trpApp = T.pack (troApp o)
        , trpTask = T.pack (troTask o)
        , trpNamespace = nsOf (troNamespace o)
        , trpScope = scopeOf (troApp o)
        , trpDryRun = troDryRun o
        }
  TaskLogs o ->
    runTaskLogs
      TaskLogTarget
        { tltNamespace = nsOf (tloNamespace o)
        , tltTask = T.pack (tloTask o)
        , tltScope = scopeOf (tloApp o)
        , tltFollow = tloFollow o
        , tltTail = tloTail o
        }
  TaskDelete o ->
    runTaskDelete
      TaskDeleteParams
        { tdpName = T.pack (tdoTask o)
        , tdpNamespace = nsOf (tdoNamespace o)
        , tdpScope = scopeOf (tdoApp o)
        , tdpYes = tdoYes o
        , tdpDryRun = tdoDryRun o
        }
  where
    nsOf = maybe "personal" T.pack
    -- A required APP positional: "-" means app-less, anything else is that app.
    scopeOf "-" = NoApp
    scopeOf a = App (T.pack a)
    -- An optional APP positional (task list): absent means "any app".
    scopeOfMaybe Nothing = AnyApp
    scopeOfMaybe (Just a) = scopeOf a
```

Add the imports near the other `Nagare.*` imports at the top of `app/Main.hs`:

```haskell
import Nagare.Task.Discover (AppScope (..))
import Nagare.Task.List (runTaskList)
import Nagare.Task.Delete (TaskDeleteParams (..), runTaskDelete)
import Nagare.Task.Run (TaskRunParams (..), runTaskRun)
import Nagare.Task.Logs (TaskLogTarget (..), runTaskLogs)
```

(The `Run` and `Logs` imports and dispatch arms are completed in M2; if you build M1 in
isolation, comment out the `TaskRun`/`TaskLogs` arms and their imports temporarily, or
implement M2's modules first. The cleanest path is to land M1's three modules plus stubs
for `runTaskRun`/`runTaskLogs`, then flesh them out in M2.)

### M1.5 — register the new modules in `cli/nagarectl/nagarectl.cabal`

In the `library` stanza's `exposed-modules` list (lines ~32–73), add, in alphabetical
order near the other `Nagare.` modules:

```text
    Nagare.Task.Delete
    Nagare.Task.Discover
    Nagare.Task.List
    Nagare.Task.Logs
    Nagare.Task.Run
```

(Adding all five now avoids a second cabal edit in M2.)

### M1.6 — the captured JSON fixture and the unit tests

Create `cli/nagarectl/test/fixtures/cronjob-list.json`. This is a real-shaped
`kubectl get cronjob -o json` response. It contains two managed tasks (one app-scoped, one
app-less) and one *unmanaged* CronJob — except that `kubectl -l <selector>` would have
filtered the unmanaged one out, so the fixture mimics the *post-filter* list: only managed
tasks appear. Capture a real one on the VM later (see the live check) and replace this seed
if its shape differs; the parser is defensive, so extra fields are ignored.

```json
{
  "apiVersion": "v1",
  "kind": "List",
  "items": [
    {
      "apiVersion": "batch/v1",
      "kind": "CronJob",
      "metadata": {
        "name": "nagare-task-cleanup",
        "namespace": "personal",
        "labels": {
          "nagare.dev/managed-by": "nagarectl",
          "nagare.dev/task": "cleanup",
          "nagare.dev/app": "notes"
        }
      },
      "spec": { "schedule": "0 3 * * *" },
      "status": {
        "lastScheduleTime": "2026-06-10T03:00:00Z",
        "lastSuccessfulTime": "2026-06-10T03:00:12Z",
        "active": []
      }
    },
    {
      "apiVersion": "batch/v1",
      "kind": "CronJob",
      "metadata": {
        "name": "nagare-task-nightly-report",
        "namespace": "personal",
        "labels": {
          "nagare.dev/managed-by": "nagarectl",
          "nagare.dev/task": "nightly-report"
        }
      },
      "spec": { "schedule": "30 2 * * *" },
      "status": {
        "active": [ { "name": "nagare-task-nightly-report-28999999" } ]
      }
    }
  ]
}
```

Add tests to `cli/nagarectl/test/Spec.hs`. Add the imports near the existing
`Nagare.Database.Discover` import (line ~53):

```haskell
import Nagare.Task.Discover
  ( AppScope (..)
  , TaskRow (..)
  , extractTaskRows
  , formatTaskTable
  , taskLabelSelector
  )
```

Add a `taskTests` test group and include it in the suite's top-level `testGroup` list. The
fixture is read at test time with `BS.readFile`; tasty test trees can be `IO`-built with
`withResource` or, more simply, read the file once in `main` and thread the bytes into a
pure test group. The simplest pattern that matches the existing file: read the fixture in
`main` and pass it down.

```haskell
taskTests :: ByteString -> TestTree
taskTests fixture =
  testGroup
    "Nagare.Task.Discover"
    [ testCase "taskLabelSelector AnyApp omits the app term" $
        taskLabelSelector AnyApp
          @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task"
    , testCase "taskLabelSelector (App notes) appends the app term" $
        taskLabelSelector (App "notes")
          @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task,nagare.dev/app=notes"
    , testCase "taskLabelSelector NoApp appends the not-exists term" $
        taskLabelSelector NoApp
          @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task,!nagare.dev/app"
    , testCase "extractTaskRows parses both managed tasks" $
        case extractTaskRows fixture of
          Left e -> assertFailure (T.unpack e)
          Right rows -> map trName rows @?= ["cleanup", "nightly-report"]
    , testCase "extractTaskRows reads schedule, app, and active count" $
        case extractTaskRows fixture of
          Left e -> assertFailure (T.unpack e)
          Right rows -> do
            let byName n = head (filter ((== n) . trName) rows)
            trApp (byName "cleanup") @?= "notes"
            trSchedule (byName "cleanup") @?= "0 3 * * *"
            trActive (byName "cleanup") @?= 0
            trApp (byName "nightly-report") @?= "-"
            trLastRun (byName "nightly-report") @?= "never"
            trActive (byName "nightly-report") @?= 1
    , testCase "extractTaskRows on empty bytes shape is Right []" $
        extractTaskRows "{\"items\":[]}" @?= Right []
    , testCase "formatTaskTable empty prints the placeholder" $
        formatTaskTable [] @?= "(no scheduled tasks)\n"
    ]
```

In `main`, read the fixture and add the group:

```haskell
main :: IO ()
main = do
  taskFixture <- BS.readFile "test/fixtures/cronjob-list.json"
  defaultMain $
    testGroup
      "nagarectl"
      [ {- ...existing groups... -}
      , taskTests taskFixture
      ]
```

If `main` currently calls `defaultMain (testGroup ...)` directly without an `IO` prelude,
restructure it to the `do`-block form above. The fixture path `test/fixtures/cronjob-list.json`
is relative to the package directory `cli/nagarectl`, which is the working directory `cabal
test` uses.

### M1.7 — build, test, and the deferred live check

```bash
cd cli/nagarectl
cabal build
cabal test nagarectl-test
```

Expected (abbreviated):

```text
nagarectl
  ...
  Nagare.Task.Discover
    taskLabelSelector AnyApp omits the app term:            OK
    taskLabelSelector (App notes) appends the app term:     OK
    taskLabelSelector NoApp appends the not-exists term:    OK
    extractTaskRows parses both managed tasks:              OK
    extractTaskRows reads schedule, app, and active count:  OK
    extractTaskRows on empty bytes shape is Right []:       OK
    formatTaskTable empty prints the placeholder:           OK

All N tests passed
```

**On-VM live check (deferred, per the EP-48 precedent).** The offline suite proves the
parser; a live check confirms the wiring against a real cluster. Do this once a real task
CronJob exists (after M3 or after EP-49's hand-applied CronJob). Per repo memory, start the
VM `nagare-01` first, then run kubectl on the VM through `scripts/iap-ssh.sh`:

```bash
# from the repo root, with the GCP env from .envrc active
scripts/iap-ssh.sh ssh nagare-01 -- kubectl get cronjob \
  -l nagare.dev/managed-by=nagarectl,nagare.dev/task -n personal -o json
```

Save that JSON over `cli/nagarectl/test/fixtures/cronjob-list.json` if its shape differs,
then re-run the offline tests. Then exercise the CLI itself against the active context:

```text
$ nagarectl task list -n personal
  NAME              APP         SCHEDULE        LAST RUN              LAST SUCCESS          ACTIVE
  cleanup           notes       0 3 * * *       2026-06-10T03:00:00Z  2026-06-10T03:00:12Z  0
  nightly-report    -           30 2 * * *      never                 never                 1

$ nagarectl task delete notes cleanup
Would delete (run again with --yes):
  cronjob/nagare-task-cleanup
  configmap/nagare-task-runs-cleanup

$ nagarectl task delete notes cleanup --yes
Deleted task cleanup
```

### M2.1 — `cli/nagarectl/src/Nagare/Task/Run.hs`

Create this file. It mirrors `runDbBackup` + `waitForJob` in
`cli/nagarectl/src/Nagare/Database/Backup.hs`, but the Job is created by `kubectl create job
... --from=cronjob/...` (IP6) rather than from a rendered manifest. `oneOffJobName` is pure
and takes the current time as an argument so it is deterministic and unit-testable (exactly
how `runDbBackup` derives `jobName` from `snapshotTimestamp now`). `runArgs` is the pure
argument vector for the `create job` call, also unit-testable.

```haskell
{-# LANGUAGE PackageImports #-}

-- | @nagarectl task run APP TASK@ (MasterPlan 10, EP-51, Integration Point IP6):
-- run a scheduled task once, now. Creates a single Job from the deployed CronJob
-- via @kubectl create job <name> --from=cronjob/nagare-task-<task>@, waits for it
-- with @kubectl wait --for=condition=complete@, tails its logs on failure, and
-- reports. With @--dry-run@, prints the exact @kubectl@ command and runs nothing.
--
-- This reuses Kubernetes' native @--from=cronjob@ so a manual run is byte-for-byte
-- identical to a scheduled run — no separate Job rendering, no drift. It mirrors the
-- apply -> wait -> log-on-failure flow of 'Nagare.Database.Backup.waitForJob'.
module Nagare.Task.Run
  ( TaskRunParams (..)
  , oneOffJobName
  , runArgs
  , runTaskRun
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Nagare.Task.Discover (AppScope, getTask)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)

data TaskRunParams = TaskRunParams
  { trpApp :: !Text
  , trpTask :: !Text
  , trpNamespace :: !Text
  , trpScope :: !AppScope
  , trpDryRun :: !Bool
  }
  deriving stock (Generic, Show)

-- | The deterministic one-off Job name: @nagare-task-<task>-manual-<YYYYmmddHHMMSS>@,
-- lower-cased and truncated to Kubernetes' 63-character name limit (as
-- 'Nagare.Database.Backup' does for its backup Job). Pure in @now@ so it is testable.
oneOffJobName :: Text -> UTCTime -> Text
oneOffJobName task now =
  T.take 63 (T.toLower ("nagare-task-" <> task <> "-manual-" <> stamp))
  where
    stamp = T.pack (formatTime defaultTimeLocale "%Y%m%d%H%M%S" now)

-- | The @kubectl@ argument vector for the one-off run (pure, unit-testable):
-- @create job <jobName> --from=cronjob/nagare-task-<task> -n <ns>@.
runArgs :: Text -> Text -> Text -> [String]
runArgs ns task jobName =
  [ "create"
  , "job"
  , T.unpack jobName
  , "--from=cronjob/nagare-task-" <> T.unpack task
  , "-n"
  , T.unpack ns
  ]

-- | Run a task once. Verifies the task exists (scoped by @scope@) so a typo fails
-- before touching the cluster, then creates the Job, waits, and reports.
runTaskRun :: TaskRunParams -> IO ()
runTaskRun p = do
  erow <- getTask (trpNamespace p) (trpScope p) (trpTask p)
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right _ -> do
      now <- getCurrentTime
      let ns = trpNamespace p
          task = trpTask p
          jobName = oneOffJobName task now
          args = runArgs ns task jobName
      if trpDryRun p
        then do
          TIO.putStrLn "--- task run (dry-run) ---"
          TIO.putStrLn ("kubectl " <> T.unwords (map T.pack args))
          TIO.putStrLn
            ( "Then: kubectl wait --for=condition=complete --timeout=600s job/"
                <> jobName
                <> " -n "
                <> ns
            )
        else do
          TIO.putStrLn ("Starting one-off run " <> jobName <> " ...")
          run_ $ cmd "kubectl" & addArgs args
          waitForTaskJob ns jobName task
          TIO.putStrLn ("Task " <> task <> " completed (" <> jobName <> ").")

-- | Wait for the one-off Job to reach @condition=complete@; on timeout/failure,
-- tail its logs and exit non-zero. Mirrors 'Nagare.Database.Backup.waitForJob'.
waitForTaskJob :: Text -> Text -> Text -> IO ()
waitForTaskJob ns jobName task = do
  (code, _ :: StdoutUntrimmed) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "wait"
          , "--for=condition=complete"
          , "--timeout=600s"
          , "job/" <> T.unpack jobName
          , "-n"
          , T.unpack ns
          ]
        & silenceStderr
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> do
      TIO.hPutStrLn stderr ("nagarectl: task " <> task <> " run " <> jobName <> " did not complete; recent logs:")
      run_ $ cmd "kubectl" & addArgs ["logs", "job/" <> T.unpack jobName, "-n", T.unpack ns, "--tail", "50"]
      exitFailure
```

Notes: `getCurrentTime` comes from `Data.Time` via the prelude (used by `runDbBackup`); if
not re-exported by `Nagare.Dsl.Prelude`, add `import Data.Time (getCurrentTime)`. The
`--from=cronjob/...` argument is one token (a single string with no space), so it goes into
the args list as `"--from=cronjob/nagare-task-" <> T.unpack task`.

### M2.2 — `cli/nagarectl/src/Nagare/Task/Logs.hs`

Create this file. It mirrors `logArgs`/`streamServiceLogs` in
`cli/nagarectl/src/Nagare/App.hs` (lines ~99–125): a pure `taskLogArgs` builds the `kubectl
logs -l <selector>` vector, and `runTaskLogs` runs it with `run_` so `--follow` tails live.
It then prints a Grafana/VictoriaLogs history hint (the parent MasterPlan's IP6 makes the
hint this plan's responsibility; EP-53 documents the full walkthrough). The selector uses
the IP3 task label, narrowed by the same `AppScope` discovery uses.

```haskell
{-# LANGUAGE PackageImports #-}

-- | @nagarectl task logs APP TASK@ (MasterPlan 10, EP-51, Integration Point IP6):
-- show a task's most recent pod logs, following a running one with @--follow@. Pods
-- are selected by the IP3 label @nagare.dev/task=<task>@ (narrowed by app). After
-- streaming, prints a one-line Grafana/VictoriaLogs hint for run history (the cluster
-- logging stack already scrapes these pods; EP-53 documents the full walkthrough).
module Nagare.Task.Logs
  ( TaskLogTarget (..)
  , taskLogArgs
  , grafanaHint
  , runTaskLogs
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Task.Discover (AppScope (..))

data TaskLogTarget = TaskLogTarget
  { tltNamespace :: !Text
  , tltTask :: !Text
  , tltScope :: !AppScope
  , tltFollow :: !Bool
  , tltTail :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- | The @kubectl logs@ argument vector for a 'TaskLogTarget' (pure, unit-testable).
-- Selects pods by @nagare.dev/task=<task>@ (plus @,nagare.dev/app=<app>@ when scoped,
-- or @,!nagare.dev/app@ for the @-@ sentinel).
taskLogArgs :: TaskLogTarget -> [String]
taskLogArgs t =
  [ "logs"
  , "-l"
  , T.unpack (selector t)
  , "-n"
  , T.unpack (tltNamespace t)
  ]
    <> maybe [] (\n -> ["--tail", show n]) (tltTail t)
    <> ["--follow" | tltFollow t]
  where
    selector x = "nagare.dev/task=" <> tltTask x <> appTerm (tltScope x)
    appTerm AnyApp = ""
    appTerm NoApp = ",!nagare.dev/app"
    appTerm (App a) = ",nagare.dev/app=" <> a

-- | A one-line pointer into the cluster's Grafana/VictoriaLogs history for a task.
-- The label query mirrors the kubectl selector so the operator can paste it into the
-- VictoriaLogs Explore view for older runs (EP-53 documents the full walkthrough).
grafanaHint :: Text -> Text
grafanaHint task =
  "For older runs, query VictoriaLogs in Grafana with: {nagare_dev_task=\""
    <> task
    <> "\"}"

-- | Stream (or print) a task's pod logs, inheriting stdout/stderr so @--follow@ tails
-- live. Then print the Grafana history hint. (Mirrors
-- 'Nagare.App.streamServiceLogs'.)
runTaskLogs :: TaskLogTarget -> IO ()
runTaskLogs t = do
  run_ $ cmd "kubectl" & addArgs (taskLogArgs t)
  TIO.putStrLn (grafanaHint (tltTask t))
```

### M2.3 — finish the `Main.hs` dispatch arms

The `TaskRun`/`TaskLogs` dispatch arms and imports added in M1.4 now resolve against real
modules. Uncomment them if you stubbed them. Confirm the imports listed in M1.4 are present.

### M2.4 — unit tests for the M2 helpers

Add to `cli/nagarectl/test/Spec.hs`. Imports:

```haskell
import Nagare.Task.Run (oneOffJobName, runArgs)
import Nagare.Task.Logs (TaskLogTarget (..), grafanaHint, taskLogArgs)
```

`oneOffJobName` is deterministic given a fixed `UTCTime` (build one with `UTCTime
(fromGregorian 2026 6 10) (secondsToDiffTime (3*3600 + 0*60 + 12))`, already imported in
`Spec.hs`):

```haskell
taskRunTests :: TestTree
taskRunTests =
  testGroup
    "Nagare.Task.Run / Logs"
    [ testCase "oneOffJobName is deterministic and prefixed" $
        oneOffJobName "cleanup" fixedTime
          @?= "nagare-task-cleanup-manual-20260610030012"
    , testCase "oneOffJobName lower-cases and truncates to 63 chars" $
        let n = oneOffJobName (T.replicate 80 "A") fixedTime
         in (T.length n <= 63 && n == T.toLower n) @?= True
    , testCase "runArgs builds the --from=cronjob create-job vector" $
        runArgs "personal" "cleanup" "nagare-task-cleanup-manual-20260610030012"
          @?= [ "create", "job", "nagare-task-cleanup-manual-20260610030012"
              , "--from=cronjob/nagare-task-cleanup", "-n", "personal"
              ]
    , testCase "taskLogArgs scopes by app and honours --tail/--follow" $
        taskLogArgs
          TaskLogTarget
            { tltNamespace = "personal"
            , tltTask = "cleanup"
            , tltScope = App "notes"
            , tltFollow = True
            , tltTail = Just 20
            }
          @?= [ "logs", "-l", "nagare.dev/task=cleanup,nagare.dev/app=notes"
              , "-n", "personal", "--tail", "20", "--follow"
              ]
    , testCase "taskLogArgs NoApp uses the not-exists term, no tail/follow" $
        taskLogArgs
          TaskLogTarget
            { tltNamespace = "personal"
            , tltTask = "nightly-report"
            , tltScope = NoApp
            , tltFollow = False
            , tltTail = Nothing
            }
          @?= [ "logs", "-l", "nagare.dev/task=nightly-report,!nagare.dev/app"
              , "-n", "personal"
              ]
    , testCase "grafanaHint embeds the task label query" $
        grafanaHint "cleanup"
          @?= "For older runs, query VictoriaLogs in Grafana with: {nagare_dev_task=\"cleanup\"}"
    ]
  where
    fixedTime = UTCTime (fromGregorian 2026 6 10) (secondsToDiffTime (3 * 3600 + 12))
```

Add `taskRunTests` to the top-level `testGroup` list in `main`.

### M2.5 — build, test, dry-run transcript, and the deferred live run

```bash
cd cli/nagarectl
cabal build
cabal test nagarectl-test
cabal run nagarectl -- task run notes cleanup --dry-run
```

Expected dry-run transcript:

```text
--- task run (dry-run) ---
kubectl create job nagare-task-cleanup-manual-<timestamp> --from=cronjob/nagare-task-cleanup -n personal
Then: kubectl wait --for=condition=complete --timeout=600s job/nagare-task-cleanup-manual-<timestamp> -n personal
```

**On-VM live run (deferred).** With the VM started and a real `nagare-task-cleanup` CronJob
present, the live run streams the Job to completion:

```text
$ nagarectl task run notes cleanup -n personal
Starting one-off run nagare-task-cleanup-manual-20260610174500 ...
job.batch/nagare-task-cleanup-manual-20260610174500 created
job.batch/nagare-task-cleanup-manual-20260610174500 condition met
Task cleanup completed (nagare-task-cleanup-manual-20260610174500).

$ nagarectl task logs notes cleanup -n personal
<the task's most recent pod output>
For older runs, query VictoriaLogs in Grafana with: {nagare_dev_task="cleanup"}
```

Because the CLI shells `kubectl` against the active context, run these on the VM via
`scripts/iap-ssh.sh` (or with the active context pointed at the cluster). The offline suite
never contacts a cluster.

### M3.1 — render and apply declared tasks in `runDeploy`

Edit `cli/nagarectl/app/Main.hs:runDeploy` (lines ~1284–1371). After the existing manifest
bindings (around line ~1325, where `svcBytes`, `dmBytes`, `pvcBytes` are bound), add the
rendered task CronJobs. The exact field/function from EP-50 is consumed here; the snippet
assumes EP-50 names the field `tasks :: [Task]` on `Deployment` and exports
`renderTask :: Task -> ByteString` from `Nagare.Dsl.Task.Render`. Adjust the two names to
whatever EP-50 settles on.

```haskell
      taskBytes = map renderTask (dep' ^. #tasks) -- EP-50 renderer; [] when no tasks declared
```

Add the import at the top of `app/Main.hs`:

```haskell
import Nagare.Dsl.Task.Render (renderTask)
```

In the **dry-run** branch (after the DomainMapping print, ~line 1343), print each task
CronJob:

```haskell
      forM_ taskBytes $ \tb -> do
        BC.putStrLn "--- Task CronJob manifest ---"
        BC.putStr tb
```

In the **live** branch (after `applyManifests (svcBytes : dmBytes)`, ~line 1361), apply the
task CronJobs in the same idempotent pass:

```haskell
      unless (null taskBytes) $ do
        applyManifests taskBytes
        TIO.putStrLn ("Provisioned " <> tShow (length taskBytes) <> " task(s).")
```

`applyManifests` is already imported in `app/Main.hs` (line ~56). `forM_`, `unless`, and
`null` come from the prelude already used in `runDeploy`. If EP-50 does not yet add a `tasks`
field to `Deployment`, M3 cannot land until EP-50 ships that field; until then, leave M3
unimplemented and check the box only when the field exists. (M1/M2 do not depend on the
`tasks` field — they operate purely on the live cluster — so they can land first.)

### M3.2 — build and the deploy dry-run transcript

```bash
cd cli/nagarectl
cabal build
cabal run nagarectl -- deploy --dry-run -f <path-to-a-Config.hs-declaring-a-task>
```

Expected (abbreviated) transcript showing the new banner:

```text
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
...
--- Task CronJob manifest ---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nagare-task-cleanup
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/task: cleanup
    nagare.dev/app: notes
spec:
  schedule: "0 3 * * *"
  ...
Build mode: ...
URL: https://...
```

**On-VM live provisioning check (deferred).** With the VM started, run a real deploy of a
config declaring a task, then confirm the CronJob exists:

```text
$ nagarectl deploy -f Config.hs
...
Provisioned 1 task(s).
Deployed: https://notes.apps.example.com

$ kubectl get cronjob -l nagare.dev/managed-by=nagarectl,nagare.dev/task -n personal
NAME                  SCHEDULE     ...
nagare-task-cleanup   0 3 * * *    ...
```


## Validation and Acceptance

The plan is accepted when all of the following hold.

**Offline (no cluster).** From `cli/nagarectl`, `cabal build` succeeds and `cabal test
nagarectl-test` passes, including the new `Nagare.Task.Discover` and `Nagare.Task.Run /
Logs` groups. These prove the pure surface: the three label-selector strings
(`taskLabelSelector AnyApp/App/NoApp`), the CronJob-list JSON parse against the checked-in
fixture `cli/nagarectl/test/fixtures/cronjob-list.json` (two managed tasks parsed, schedule
/ app / active-count / last-run read correctly, empty-shape is `Right []`), the deterministic
one-off Job name (`oneOffJobName "cleanup" fixedTime ==
"nagare-task-cleanup-manual-20260610030012"`, lower-cased, truncated to 63 chars), the
`kubectl create job ... --from=cronjob/...` argument vector (`runArgs`), and the `kubectl
logs -l ...` argument vector (`taskLogArgs`, including app scoping and `--tail`/`--follow`).

**Command-surface (no cluster).** `cabal run nagarectl -- task --help` lists `list`, `run`,
`logs`, `delete`. `cabal run nagarectl -- task run notes cleanup --dry-run` prints the exact
`kubectl create job ... --from=cronjob/nagare-task-cleanup -n personal` command and the
follow-up `wait` command, and contacts no cluster. `cabal run nagarectl -- task delete notes
cleanup` (without `--yes`) prints the deletion plan and deletes nothing. `cabal run nagarectl
-- deploy --dry-run -f <config-with-tasks>` prints a `--- Task CronJob manifest ---` banner
with the rendered CronJob.

**Live (on the VM, deferred per the EP-48 precedent).** With `nagare-01` started and a real
`nagare-task-<name>` CronJob present (from M3's provisioning or EP-49's hand-applied
CronJob): `nagarectl task list` shows it with its schedule and run timestamps; `nagarectl
task run <app> <task>` creates a Job, waits for `condition=complete`, and reports success;
`nagarectl task logs <app> <task>` prints the run's pod output and the Grafana hint;
`nagarectl task delete <app> <task> --yes` removes the CronJob and a re-run prints `no
managed task named ...`. Capture the real `kubectl get cronjob -o json` and reconcile the
fixture if its shape differs.

Acceptance is phrased as observable behaviour, not internal attributes: a person can list,
run, view, and delete scheduled tasks from the CLI, and `deploy` materializes declared tasks
as CronJobs.


## Idempotence and Recovery

`task delete` is idempotent: it uses `kubectl delete ... --ignore-not-found`, so deleting an
already-deleted task succeeds (after the existence check, which fails loudly only for a name
that was never present). Re-running `task delete --yes` on a partially-deleted task finishes
the job.

Deploy-time provisioning is idempotent: `applyManifests` runs `kubectl apply -f`, which
creates the CronJob if absent and updates it in place if present, with no duplication and no
data loss (a CronJob owns no persistent state). Re-running `nagarectl deploy` re-applies the
same CronJob harmlessly.

`task run` creates a *new* Job each time, named with a second-resolution timestamp
(`nagare-task-<task>-manual-<YYYYmmddHHMMSS>`), so two runs within the same second would
collide — acceptable for an interactive command (a human cannot fire two in the same
second), and `kubectl create job` fails loudly on a name clash rather than silently
overwriting. If a run is interrupted (Ctrl-C during the `wait`), the Job keeps running in the
cluster; re-attach with `nagarectl task logs <app> <task> --follow`, or clean it up with
`kubectl delete job <name>`. If a *scheduled* run is in flight when you fire a manual run,
both run independently (Kubernetes' `concurrencyPolicy` on the CronJob governs overlap of
*scheduled* runs; a `--from=cronjob` manual Job is a separate object and is not subject to
that policy). `task delete` removes the CronJob but does not abort an in-flight Job created
from it; delete the Job separately if needed.

Recovery is uniform: every mutating command is safe to re-run, and every read command
(`task list`, `task logs`) is non-mutating. A failed `kubectl` call surfaces its own error;
a missing namespace or unreachable cluster makes `task list` print the empty placeholder
rather than crash (the `Right []`-on-failure contract inherited from
`Nagare.Database.Discover`).


## Interfaces and Dependencies

Libraries used and why: `cradle` (the `kubectl` wrapper — `cmd`/`addArgs`/`run`/`run_`,
already used throughout the CLI); `aeson` + `vector` (defensive JSON parsing of `kubectl ...
-o json`, as in `Nagare.Database.Discover`); `text` (all string handling); `time`
(`UTCTime`/`formatTime` for the deterministic one-off Job name); `optparse-applicative` (the
command-group parsers in `app/Main.hs`); `tasty`/`tasty-hunit` (the offline unit tests). No
new dependency is added; all are already declared in `cli/nagarectl/nagarectl.cabal`.

The exact signatures that must exist at the end of each milestone — these are the IP4/IP6
surface that EP-52 and EP-53 consume:

End of M1 (module `Nagare.Task.Discover`):

```haskell
data AppScope = AnyApp | NoApp | App Text
taskLabelSelector :: AppScope -> Text
data TaskRow = TaskRow
  { trName :: !Text, trApp :: !Text, trSchedule :: !Text
  , trLastRun :: !Text, trLastSuccess :: !Text, trActive :: !Int }
extractTaskRows :: ByteString -> Either Text [TaskRow]
listTasks :: Text -> AppScope -> IO (Either Text [TaskRow])
getTask :: Text -> AppScope -> Text -> IO (Either Text TaskRow)
formatTaskTable :: [TaskRow] -> Text
```

```haskell
-- Nagare.Task.List
runTaskList :: Text -> AppScope -> IO ()

-- Nagare.Task.Delete
data TaskDeleteParams = TaskDeleteParams
  { tdpName :: !Text, tdpNamespace :: !Text, tdpScope :: !AppScope
  , tdpYes :: !Bool, tdpDryRun :: !Bool }
runTaskDelete :: TaskDeleteParams -> IO ()
```

End of M2 (modules `Nagare.Task.Run`, `Nagare.Task.Logs`):

```haskell
-- Nagare.Task.Run
data TaskRunParams = TaskRunParams
  { trpApp :: !Text, trpTask :: !Text, trpNamespace :: !Text
  , trpScope :: !AppScope, trpDryRun :: !Bool }
oneOffJobName :: Text -> UTCTime -> Text
runArgs :: Text -> Text -> Text -> [String]   -- ns -> task -> jobName -> argv
runTaskRun :: TaskRunParams -> IO ()

-- Nagare.Task.Logs
data TaskLogTarget = TaskLogTarget
  { tltNamespace :: !Text, tltTask :: !Text, tltScope :: !AppScope
  , tltFollow :: !Bool, tltTail :: !(Maybe Int) }
taskLogArgs :: TaskLogTarget -> [String]
grafanaHint :: Text -> Text
runTaskLogs :: TaskLogTarget -> IO ()
```

End of M3 (no new exported module; `runDeploy` consumes EP-50):

```haskell
-- consumed from EP-50 (docs/plans/50-...); names reconciled at integration:
renderTask :: Nagare.Dsl.Task.Task -> Data.ByteString.ByteString
-- and the Deployment field carrying declared tasks (e.g. tasks :: [Task])
```

Dependencies on sibling plans: this plan **hard-depends** on
`docs/plans/50-typed-task-model-and-cronjob-job-renderer.md` for `renderTask`, the `Task`
type, and the naming/label contract (IP3) that the selector strings and `nagare-task-` name
prefix encode. It **soft-depends** on
`docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md` for the
verified `kubectl create job --from=cronjob` substrate and the log-retrieval approach.
`docs/plans/52-app-task-association-and-runtime-env-image-and-secret-inheritance.md` consumes
this plan's `AppScope` and selector helpers (it sets the `nagare.dev/app` label that
`App`/`NoApp` scoping reads) and must *extend* the `task` command group, never fork it.
`docs/plans/53-scheduled-tasks-docs-and-end-to-end-examples.md` documents the four commands
and expands the `grafanaHint` into the full VictoriaLogs/Grafana history walkthrough.
