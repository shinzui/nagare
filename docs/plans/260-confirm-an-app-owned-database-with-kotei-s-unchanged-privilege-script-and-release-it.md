---
id: 260
slug: confirm-an-app-owned-database-with-kotei-s-unchanged-privilege-script-and-release-it
title: "Confirm an app-owned database with Kotei's unchanged privilege script and release it"
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

# Confirm an app-owned database with Kotei's unchanged privilege script and release it

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and
Outcomes & Retrospective current. Record implementation friction in the friction log as it
occurs (`agents/skills/exec-plan/FRICTION.md`).


## Purpose / Big Picture

The three plans before this one let an app own its database, carry its roles through backups
and maintenance, and bind the owner credential to a pre-deploy hook. This plan confirms them
together on one local context with the consumer they were built for: Kotei's own migrations and
its privilege script, unchanged, run by a pre-deploy hook as the owner. It then checks the user
guide against IR-43 AC-6, releases, and closes the improvement request.

Under [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) a
native run only confirms. A defect found here is fixed with an interpreter test in the plan that
owns the code, not worked around in this run.


## Progress

- [ ] M1: On one local context, IR-43 AC-1 to AC-5 pass together with Kotei's script unchanged,
  and an app database that did not opt in re-plans with no operations and still backs up and
  restores.
- [ ] M2: `docs/user/managed-databases.md` meets AC-6, and IR-43 records what was delivered.
- [ ] M3: The release is published and the intranet runs it and passes the deploy-and-login
  check.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Kotei's script is read from Kotei's repository at run time and is not copied into
  this one. Rationale: the claim under test is "unchanged"; a copy would drift. Date:
  2026-11-11.
- Decision: The app's own logins are created in this run by a short SQL file run as the owner,
  standing in for Kotei's separate login provisioning. Rationale: the script creates roles
  without login and says logins are provisioned separately; AC-2 and AC-4 need at least one
  app-created login. Date: 2026-11-11.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Paths are repository-relative. The request is
[IR-43](../improvement-requests/let-an-app-own-its-database.md), raised for
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`. Its acceptance
criteria, as this initiative delivers them:

- AC-1: an app-owned PostgreSQL 18 app database; Kotei's script runs unchanged as the owner,
  twice; its five roles, memberships, ownership changes and grants exist; a re-plan prints no
  operations. The declaration names `kotei_maintenance` as the database's owning role, because
  the script's `ALTER DATABASE ... OWNER TO` would otherwise need `CREATEDB`
  ([MasterPlan 35](../masterplans/35-let-an-app-own-its-database-on-a-shared-postgresql-server.md),
  Decision Log).
- AC-2: the owner and a login it created cannot touch a second app's roles or database,
  Nagare's users, or a server-wide privilege.
- AC-3: changes the app makes inside its database are not drift; a grant reaching another app's
  database is.
- AC-4: a backup and a rebuilt-server restore return the app's roles, logins, memberships,
  ownership and grants; quiesce blocks an app-created login and resume reopens it.
- AC-5: a pre-deploy hook binds the owner credential under
  `KOTEI_RELEASE_MAINTENANCE_DATABASE_URL`, completes before promotion, and neither the web nor
  the worker Pod references the owner Secret.
- AC-6: the managed-databases guide documents the declaration, the guarantees between apps and
  the hook binding.

What the earlier plans provide:
[EP-257](257-declare-an-app-owned-postgresql-app-database-and-keep-apps-apart.md) the
declaration (`ownership = AppOwned` with an optional `databaseOwner`), the owner user and Secret
`<name>-owner`, and the boundary checks;
[EP-258](258-carry-an-app-s-roles-through-backups-restores-quiesce-and-retirement.md) backup,
restore, quiesce, resume and retirement;
[EP-259](259-let-tasks-and-pre-deploy-hooks-bind-an-app-database-under-a-named-url-variable.md)
the task binding with `urlVariable`. All three must be complete. ADR 37
(`docs/adr/0037-an-app-may-own-its-database-and-nagare-keeps-apps-apart.md`) records the model.
`scripts/local-app-database-smoke.sh` already exercises each with a Kotei-shaped script.

Kotei is the project `mori://shinzui/kotei`; find its checkout with `mori registry show
shinzui/kotei --full`. The script is `kotei-migrations/privileges/apply.sql` in that project
(project-relative path; artifact-level URI pending). It expects Kotei's schemas (`kiroku`,
`keiro`, `kotei`, `pgmq`, `pgmigrate`, `keiro_read`) to exist, so Kotei's migrations run first,
as the same owner. Kotei's `nagare/Config.hs` declares a pre-deploy hook task `migrate` that
runs `kotei-release-migrate` and reads `KOTEI_RELEASE_MAINTENANCE_DATABASE_URL`. If Kotei's
migrations need an extension, it must be one a database owner can create on the server image;
if it is not, record that as a finding here and stop, since it is outside this initiative.

A local context is a k3d cluster with loopback substitutes for every cloud service
([docs/user/local-development.md](../user/local-development.md)); the GCP guardrail steps aside
there by design. The release procedure is the `nagare-release` skill and the rules in
`CLAUDE.md`: the full gate green, the upgrade rehearsal on a disposable local context reading
seeded data back unchanged, and the intranet context upgraded and passing the deploy-and-login
check. Cloud-mutating steps need the operator's go-ahead, asked once for the bounded sequence,
after [Before a native run](../runbooks/before-a-native-run.md).


## Plan of Work

### M1: confirm on a local context

On a disposable local context with one shared PostgreSQL 18 server, declare three app
databases: `kotei-pg`, app-owned with `databaseOwner` `kotei_maintenance` and `owners` naming
the hook; a second app-owned database for the isolation attempts; and one that does not opt in,
with data, for the unchanged path. Then:

1. Apply them, and deploy an Application whose pre-deploy hook binds `kotei-pg` under
   `KOTEI_RELEASE_MAINTENANCE_DATABASE_URL` and runs Kotei's migrations and then its privilege
   script. Use Kotei's image and `Config.hs` if they build for the local context; otherwise a
   small image holding `psql` and the two inputs, and say so in Progress.
2. Show the hook completed before promotion, the rendered web and worker Pods do not reference
   `kotei-pg-owner`, the five roles and their memberships, ownership and grants exist, and
   re-running the hook under a new release and re-planning both leave no operations.
3. As the owner, create a login in one of the script's roles. Run the AC-2 attempts as the
   owner and as that login against the second app. As the administrator, grant one of Kotei's
   roles `CONNECT` on the second database and show planning reports it; revoke it.
4. Back up, quiesce and show the login refused, resume and show it connect. Then rebuild:
   delete the database and the app's roles, re-apply, restore with `--rebuilt`, and compare
   roles, memberships, ownership and grants with the source and connect as the login with its
   original password.
5. Show the database that did not opt in re-plans with no operations and its backup and scratch
   restore still pass.

Record each result in Progress as one line of evidence.

### M2: the guide and the request

Read the "App-owned databases" subsection of `docs/user/managed-databases.md` as a new user
would and fix what M1 showed to be wrong or missing; it must hold the declaration, the
guarantees between apps and a migration-hook example. In
`docs/improvement-requests/let-an-app-own-its-database.md`, set the status and note under AC-1
and AC-4 what was delivered differently from the text (the declared owning role; verifiers in
the backup), following the form other completed requests in that directory use.

### M3: release

Follow the `nagare-release` skill. Complete the MasterPlan's ADR distillation and its Outcomes
& Retrospective.


## Concrete Steps

```bash
just local-app-database-smoke <local-context>
just gate-fast
```

The release commands are the `nagare-release` skill's; do not restate them here.


## Validation and Acceptance

M1 is accepted when each of the five steps has its evidence and no step needed a change to
Kotei's script. M2 is accepted when the guide section covers the three AC-6 items and the
request file records the outcome. M3 is accepted by the three release proofs in `CLAUDE.md`.


## Idempotence and Recovery

The local context is disposable; tear it down and repeat from step 1 after any fix. If a guard,
check or script refuses during the release, stop and report to the operator.


## Interfaces and Dependencies

Hard dependencies: EP-257, EP-258 and EP-259 complete. Reads Kotei's repository through Mori;
changes nothing there. Kotei's own adoption (its `Config.hs` and login provisioning) belongs to
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`.
