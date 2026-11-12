---
id: 259
slug: let-tasks-and-pre-deploy-hooks-bind-an-app-database-under-a-named-url-variable
title: "Let tasks and pre-deploy hooks bind an app database under a named URL variable"
kind: exec-plan
created_at: 2026-11-11T15:15:38Z
intention: "intention_01m75kmah1emw9d4qqaveqxnx2"
master_plan: "docs/masterplans/35-let-an-app-own-its-database-on-a-shared-postgresql-server.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-11T15:15:38Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-11T15:28:32Z
      mode: "update"
      note: "Require PostgreSQL 18 or later and link the intention."
---

# Let tasks and pre-deploy hooks bind an app database under a named URL variable

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and
Outcomes & Retrospective current. Record implementation friction in the friction log as it
occurs (`agents/skills/exec-plan/FRICTION.md`).


## Purpose / Big Picture

A task can bind an app database, and so can an Application's pre-deploy hook, which is where an
app runs its migrations. Any binding, on a task, a deployment or a worker, may name the
environment variable that receives the connection URL, so an app that reads
`KOTEI_RELEASE_MAINTENANCE_DATABASE_URL` needs no wrapper. When the app database is app-owned
and names the hook among its owners, the hook receives the owner credential, runs before
promotion, and no long-running Pod of the app ever references that Secret.

This is IR-43 AC-5
([docs/improvement-requests/let-an-app-own-its-database.md](../improvement-requests/let-an-app-own-its-database.md)).


## Progress

- [x] M1: A task and an Application pre-deploy hook bind an app database that did not opt into
  ownership, receiving the runtime credential, or the migration credential when the app
  database names the task in `owners`. A binding with `urlVariable` injects exactly that one
  variable. Existing configurations change only the form of their `appDatabases` entries.
  Evidence (pass): `cli/nagarectl/test/AppDatabaseTaskSpec.hs` "AppDatabase task and named
  bindings (EP-259)": a name-only binding renders byte-identical objects and dependencies to the
  fixture `test/fixtures/app-database/v0.19.2/name-only-bindings.txt`, produced by the same
  worker and Deployment compiled on 931c1d83; a named binding injects one variable from
  `DATABASE_URL` and two PostgreSQL bindings coexist; a clashing `urlVariable` is refused; a
  Deployment's task receives `alpha-pg-migration` when named in `owners` and only its own
  Secret otherwise, ordered after the Secret and the app database's members; a hook's Job
  carries `KOTEI_RELEASE_MAINTENANCE_DATABASE_URL` from `alpha-pg-runtime`, is ordered after
  it, no Pod template references it, and the service, its tasks and the workers keep
  `app-database-not-bindable-from-application`. `cli/nagare-dsl/test/AppDatabaseBindingSpec.hs`:
  round trip on `Deployment`, `Worker` and `Task`, the bare-name form and a `SecretKeyRef` env
  entry refused at load, `mkTask` refusals, golden `test/golden/task-url-variable.cronjob.yaml`.
  The existing `AppDatabaseSpec` and `AppDatabasePrivilegeSpec` cases pass unchanged apart from
  the binding form. `just gate-fast c976957f` green (record
  `gates/fast/c976957fd189b77da8a118fd92762b2196e0a124.json`), and `exe:nagarectl` builds. New
  cases live in their own modules because `AppDatabaseSpec.hs` and `AppDeploySpec.hs` are at
  their size limits.
- [ ] M2: A pre-deploy hook named in an app-owned database's `owners` receives the owner
  credential under its chosen variable, completes before promotion, and the rendered web and
  worker Pods do not reference the owner Secret. The user guides document the binding with a
  migration-hook example.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A binding is a record, `AppDatabaseBinding { name, urlVariable }`, replacing the
  bare name in `appDatabases` on `Deployment` and `Worker` and added to `Task`. No legacy form
  is kept. Rationale: IR-43 asks that any binding can name its variable, and the repository
  keeps no compatibility shims; consumers change their `Config.hs` at the release (the
  precedent is EP-254). Date: 2026-11-11.
- Decision: A binding with `urlVariable` injects only that variable. A binding without it
  injects today's fixed set. Rationale: the fixed names are why a workload can bind only one
  database per engine; a named binding has no such clash, so several may coexist. Date:
  2026-11-11.
- Decision: The binding never names a credential. The app database's `owners` list decides
  whether a named workload or task receives the owning credential. Rationale:
  [ADR 31](../adr/0031-own-database-privileges-are-declarable-server-wide-access-is-not.md).
  Date: 2026-11-11.
- Decision: A hook that binds an app database still needs its reviewed effects stated with
  `--hook-affects` or `--hook-no-data-effects`. The binding does not imply them. Rationale: the
  review of what a hook changes is a separate, existing safeguard. Date: 2026-11-11.
- Decision: A named binding's variable is a new env value, `EnvSecretKeyRef SecretName EnvName`
  (a Secret reference reading a key other than the variable's name). Only planning produces
  it; the configuration loader refuses the `SecretKeyRef` kind, so a configuration names a
  Secret key only through `urlVariable`. Rationale: `EnvSecretRef` reads the key equal to the
  variable name, and the credential Secret's keys are fixed by the app database. Date:
  2026-11-11.
- Decision: The duplicate rule is refused only among bindings without a `urlVariable`; one app
  database may be bound under the fixed set and under names. A `urlVariable` may not redefine
  the workload's or task's env, the application env a task inherits, another binding's
  variable, or a `NAGARE_` name. Rationale: only fixed sets clash. Date: 2026-11-11.
- Decision: A standalone `Deployment`'s scheduled tasks bind too, each resolved for its own
  name; the standalone service compile takes bindings keyed by consumer name, and a task that
  binds needs a name other than its Deployment's. In an `Application` only the top-level
  tasks (hooks) bind; the service's own tasks are refused with the service. A hook's Job is
  ordered directly after the bound Secret and the app database's users and databases, not only
  through its CronJob. Rationale: a task field that some paths ignored would silently drop a
  binding; a failed hook Job is terminal, so it must not start before the users exist. Date:
  2026-11-11.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Paths are repository-relative. Nagare configuration is a Haskell program that emits JSON
(`cli/nagare-dsl/src/Nagare/Dsl/Config.hs`); loaders under `cli/nagare-dsl/src/Nagare/Dsl/Load/`
decode it, reading optional keys with `.:?`. The configuration has no contract version, and the
rendered-configuration envelope (`Load/Rendered.hs`) carries the program's output as an opaque
string, so a new field needs no version bump.

An **app database** is a tenant of a shared server with its own credential Secrets
([ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md)). A
`Deployment` (`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, near line 773) and a `Worker`
(`cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`, near line 231) bind one through
`appDatabases :: [AppDatabaseName]`. At planning,
`acceptedAppDatabaseBindings` in `cli/nagarectl/src/Nagare/Inventory/Application/Bindings.hs`
(near lines 529 to 605) finds the accepted `appdb-*` scope, picks the Secret `<name>-runtime`,
or `<name>-migration` when the accepted migration user's `owners` names the workload, and
refuses a retired app database. `standaloneDatabaseEnvironment` in
`cli/nagarectl/src/Nagare/Inventory/Application/Environment.hs` (near line 224) injects, for
PostgreSQL, literals `POSTGRES_HOST` and `POSTGRES_PORT` and Secret references `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB` and `DATABASE_URL`; each reference's Secret key equals the
variable name. `workloadDatabaseNames` in the same file refuses a repeated name.

A **task** (`cli/nagare-dsl/src/Nagare/Dsl/Task.hs`, record near line 221, validated by
`mkTask`, preset `scheduledTask`) renders as a CronJob (`Nagare/Dsl/Task/Render.hs`,
`Nagare/Dsl/Batch/Render.hs`). It has no database binding. `cli/nagarectl/src/Nagare/Task/Resolve.hs`
and `renderTaskObjects` in `cli/nagarectl/src/Nagare/App/Deploy.hs` add the image and the app's
shared environment; `compileTaskMembers` in
`cli/nagarectl/src/Nagare/Inventory/Application/Tasks.hs` orders the CronJob after the Secrets
its environment references.

An **Application** (`cli/nagare-dsl/src/Nagare/Dsl/Application.hs`) combines a service, workers
and tasks. Its top-level `tasks` are **pre-deploy hooks**: `compileApplicationHooks` in
`Tasks.hs` gives each its own scope and a Job, runs them in order, and orders the service,
workers and release after every hook's proof. A failed hook Job is terminal and a proven hook is
not rerun. Each hook needs an exact reviewed `--hook-affects TASK=...` or
`--hook-no-data-effects TASK`. Two refusals in
`cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` matter here: an Application's
service and workers may not bind app databases (`app-database-not-bindable-from-application`,
near line 148), and every Secret a hook references must be supplied exactly (near lines 718 to
772).

[EP-257](257-declare-an-app-owned-postgresql-app-database-and-keep-apps-apart.md) adds
`ownership = AppOwned` to the app database declaration. Such a database has one Nagare user,
the owner, with role token `owner` and Secret `<name>-owner`, no runtime or migration user, and
planning refuses a `Deployment` or `Worker` that binds it. Its `access.owners` list may name
tasks only. M2 of this plan needs EP-257's M2 accepted; M1 needs nothing from it.


## Plan of Work

### M1: tasks bind, and bindings name their variable

In `cli/nagare-dsl`, define `AppDatabaseBinding { name :: AppDatabaseName, urlVariable :: Maybe
EnvName }` with a constructor for the common case (name only). Change `appDatabases` on
`Deployment` and `Worker` to a list of it and add the field to `Task`, including `mkTask`'s
validation and the `scheduledTask` preset. Emit the `urlVariable` key only when set; decode a
binding object in `Load/Deployment.hs`, `Load/Worker.hs` and `Load/Task.hs`. Update every record
literal the compiler reports, in tests, fixtures, examples and docs.

In `Environment.hs`, a binding with `urlVariable` produces one Secret reference: that variable
name, the bound Secret, and the URL key (`DATABASE_URL` or `CLICKHOUSE_URL`). Refuse a
`urlVariable` that the workload's own environment or another binding already defines. Relax
`workloadDatabaseNames` and the one-per-engine rule only among named bindings.

Make `acceptedAppDatabaseBindings` serve tasks: resolve a task's bindings by the task's name
against `owners`, as it does for workloads, and render the result into the task's Job
environment in the path that `renderTaskObjects` and `compileTaskMembers` use, ordering the
CronJob and a hook's Job after the bound Secret. Allow an Application's top-level tasks to bind
app databases; keep the refusal for its service and workers.

Tests: round-trip and golden tests in `cli/nagare-dsl/test/Spec.hs` (task goldens under
`test/golden/`), and in `cli/nagarectl/test/` `AppDatabaseSpec.hs` (a task receives only its
own app database's Secret, a named binding injects one variable),
`AppDatabasePrivilegeSpec.hs` (a task named in `owners` receives the migration credential, one
not named receives runtime) and `AppDeploySpec.hs` (a hook's Job references the Secret and is
ordered after it).

### M2: the owner credential reaches only the hook

With EP-257 M2 in place, teach the binding resolution the `owner` role: for an app-owned
database, a task named in `owners` receives `<name>-owner`; a task not named is refused, since
there is no other credential to give it. The credential is decided only from the accepted app
database scope, by a pure function run when a review is prepared and at admission
([MasterPlan 35](../masterplans/35-let-an-app-own-its-database-on-a-shared-postgresql-server.md),
integration point on several operators); a delegated deployer gets it the same way and no
other. Add a test in `AppDatabasePrivilegeSpec.hs` and one in
`WorkloadControlsInventorySpec.hs` or `AppDeploySpec.hs` that compiles an Application with a web
service, a worker and a hook bound to an app-owned database under
`KOTEI_RELEASE_MAINTENANCE_DATABASE_URL`, and asserts that the hook's Job carries that one
variable from `<name>-owner`, that the service and Deployment are ordered after the hook's
proof, and that neither rendered Pod template mentions `<name>-owner`.

Document it: in `docs/user/managed-databases.md`, the binding form under "Binding" and a
migration-hook example in the "App-owned databases" subsection; in
`docs/user/scheduled-tasks.md` and `docs/user/deploying-apps.md`, that a task or hook may bind
an app database; in `docs/user/config-reference.md`, the new field.


## Concrete Steps

From the repository root, per Haskell commit:

```bash
just haskell-style-check
just gate-fast
```


## Validation and Acceptance

M1 is accepted when the named tests pass and an existing fixture application, with its
`appDatabases` entries rewritten in the new form and no `urlVariable`, renders the same
Kubernetes objects as before. M2 is accepted when the Application test above passes. The live
run of a hook connecting as the owner is
[EP-260](260-confirm-an-app-owned-database-with-kotei-s-unchanged-privilege-script-and-release-it.md)'s.
`just gate-fast` is green with no uncommitted changes before landing.


## Idempotence and Recovery

The change is to desired bytes only; the review, journal and recovery code is not touched. A
hook remains forward-only: a proven hook is not rerun, and changing it under the same release
tag is refused, as today.


## Interfaces and Dependencies

No new library. This plan owns `AppDatabaseBinding`. It consumes from EP-257 the `owner` role
token, the Secret name `<name>-owner` and the rule that an app-owned database's `owners` are
tasks. Hard dependency for M2 only: EP-257 M2.
