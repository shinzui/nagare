---
id: 266
slug: upgrade-the-intranet-s-platform-and-shared-server-postgresql-databases-side-by-side
title: "Upgrade the intranet's platform and shared-server PostgreSQL databases side by side"
kind: exec-plan
created_at: 2026-11-18T02:09:52Z
master_plan: "docs/masterplans/36-finish-and-keep-current-the-production-readiness-checklist.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-18T02:09:52Z
---

# Upgrade the intranet's platform and shared-server PostgreSQL databases side by side

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Box 4 of the production readiness checklist was drilled for one kind of database: an application's
standalone PostgreSQL. The procedure is "Upgrade PostgreSQL to a new major version" in
`docs/user/managed-databases.md`, and it moves the application's binding with a reviewed deploy.
The intranet's data is mostly in other kinds:

- the platform databases `en-db` and `shomei-db`, which the platform binds, not an app;
- the En tenant databases `en-<name>-db`;
- shared PostgreSQL servers carrying app databases (ADR 30, ADR 37).

After this plan, the operator can move each of those kinds to a new PostgreSQL major side by side.
A fresh verified backup comes first. The old instance stays the authority until the new one is
proven. A failed attempt returns to the old instance with every acknowledged row. The proof is a
rehearsal on the local warm drill context, with no cloud step until the operator wants a real
upgrade on the intranet.

Scope waits for decision D3 in
`docs/masterplans/36-finish-and-keep-current-the-production-readiness-checklist.md`. If the
operator holds it, this plan stays Not Started until a new major is wanted on the intranet.


## Progress

- [ ] M1, desk-check (no code). For each kind, write a table of the procedure's six steps:
  backup and prove, declare the new instance, fence and copy, verify, switch the binding, retire
  the old. Name the existing command that does each step, or mark the step missing and name the
  module that would carry it. Check every claim against the CLI help and the scope compiler.
  Include whether the rebuild path's dump-and-restore (`inventory rebuild` with a recovery point,
  then `db restore-rebuilt` and `db app-database restore-rebuilt`) can serve as the copy step
  without retiring the old instance first. Pass: the table is in this plan, and each missing step
  has one owner module.
- [ ] M2, only for steps M1 marks missing: the code, with interpreter tests that prove each failure
  returns to the old instance (ADR 25). Pass: `just haskell-style-check` and `just gate-fast` green
  on the committed revision, then `just land`.
- [ ] M3, local rehearsal on the warm drill context, resumable at each step. Seed rows into
  `en-db`, one En tenant database and two app databases on one shared server, all at major N.
  Then:
  - Upgrade each kind to N+1 side by side. Fingerprints match, the switch-over is reviewed, and the
    old instance is retired only after a post-switch backup restores.
  - Fail 1: the copy fails, and the old instance takes writes again.
  - Fail 2: the new instance is rejected after the switch, and a reviewed switch back loses no
    acknowledged row.
  - The intranet's sign-in works on the switched `en-db` and `shomei-db`.

  Pass: the drill log is under `docs/audits/`, and every assertion holds.
- [ ] M4: `docs/user/managed-databases.md` covers each kind, and the drill log path is handed to
  `docs/plans/267-bring-the-readiness-checklist-s-evidence-gate-rules-and-ledger-rows-up-to-the-current-release.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Rehearse 17 → 18 if no newer PostgreSQL major is packaged, as `mp23-c3l` did. The
  procedure is the same for any pair of majors.
  Rationale: the intranet runs 18; the drill needs two majors, not the newest.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

- In-place major or engine changes are refused at planning (F86):
  `cli/nagarectl/src/Nagare/Inventory/DatabaseEngine.hs` (`databaseEngineUnchanged`).
- Platform databases and their wiring: `cli/nagarectl/src/Nagare/Inventory/Components/PackagedAuth.hs`
  (`en-db`, `shomei-db`) and `cli/nagarectl/src/Nagare/Inventory/Components/AuthTenants.hs`
  (`en-<name>-db`, EP-262).
- App databases on a shared server: `cli/nagarectl/src/Nagare/Database/AppDatabase/`
  (`Catalog.hs`, `Owned.hs`, `Backup.hs`, `Drain.hs`), with
  [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) and
  [ADR 37](../adr/0037-an-app-may-own-its-database-and-nagare-keeps-apps-apart.md).
  EP-258 (`docs/plans/258-carry-an-app-s-roles-through-backups-restores-quiesce-and-retirement.md`)
  carries an app's roles through backup, restore, quiesce and retirement.
- Restore after a rebuild, and the En counter and datastore-id handling (F144, F147):
  `cli/nagarectl/src/Nagare/Inventory/RebuildRestore.hs`; `docs/runbooks/disaster-recovery.md`.
- The standalone procedure and its drill: `docs/user/managed-databases.md`, and the checklist's
  section 4 evidence for `3b59bcb7`.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): defects
  are found by the interpreters, and the native run only confirms.
- The warm drill context is the resumable local context nagare-fix is introducing (2026-11-17).
  Until it exists, use a disposable `mode=local` context; a green `gate-fast` is enough for local
  native runs.


## Plan of Work

M1 decides how much code M2 needs. If M1 finds every step served by existing commands, M2 is
empty, and M3 rehearses the documented composition.


## Concrete Steps

M1 starts from the CLI help of each command in the procedure:

```bash
nagarectl db create --help
nagarectl db app-database --help
nagarectl inventory rebuild-decisions --help
nagarectl db restore-rebuilt --help
```


## Validation and Acceptance

M3's assertions are the acceptance: every seeded row reads back after the switch and after each
failure, and the post-switch backup restores before the old instance retires.


## Idempotence and Recovery

Until the switch, the old instance is the authority, so stopping at any step loses nothing. Each
drill step resumes on its context, never through a full rebuild.


## Interfaces and Dependencies

No prerequisite plan. Soft: nagare-fix's warm drill context.
