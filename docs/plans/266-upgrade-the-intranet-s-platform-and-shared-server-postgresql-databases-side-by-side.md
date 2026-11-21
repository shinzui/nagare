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

- [x] (2026-11-18) M1, desk-check. The table is below, under "M1 desk-check". Every claim
  carries a file:line citation. A shared server with app databases needs no code: each step is an
  existing command, and the copy is the same manual `pg_dump | psql` as the standalone procedure.
  The platform databases (`en-db`, `shomei-db`, `en-<name>-db`) need code, for two reasons.
  Their names, Secrets and Service hosts are fixed, so a second instance cannot sit beside the
  first. And nothing keeps their accepted version (F156).
- [x] (2026-11-18) M2: fix F156. The platform databases use `platformPostgresVersion` (18,
  `cli/nagarectl/src/Nagare/Inventory/Database.hs`), not the payload default, so a default bump
  never plans an in-place major change. Test: "F156: every platform database, a tenant's included,
  is at the platform PostgreSQL version" (`cli/nagarectl/test/InventoryAuthTenantsSpec.hs`).
  2026-11-18: landed as `8e0a2981`, with `just gate-commit` green and a green `just gate-fast` on
  the landed tip `b561a622`. It ships in the release after v0.22.0.
- [-] M2b, voided: the operator chose D5 (c) on 2026-11-18. The platform databases' move is the
  held [EP-268](268-move-nagare-s-own-postgresql-databases-to-a-new-major-version.md).
- [x] (2026-11-18) M3: `scripts/local-postgres-major-upgrade-drill.sh` passed on the warm
  `ep235` context (nagare-c4-amd64), run `s1118030645`
  ([evidence](../audits/ep266-pg-major-upgrade-drill-2026-11-18.txt)):
  - fresh backups of `ua-pg` and `ub-pg` restored equal;
  - `upg-18` beside `upg-17`, with the in-place move to 18 refused (F86);
  - `ua-pg` fenced and copied with equal fingerprints, the probe switched by review and writing
    to 18;
  - `ua-pg-v2`'s own backup restored equal before `ua-pg` retired, its data kept;
  - fail 1: the copy failed in one transaction, and `ub-pg` resumed with every row;
  - fail 2: switched and rejected, then the old binding redeployed and resumed with every row,
    and `ub-pg-v2` took no write.

  The platform-database part moved to EP-268.
- [x] (2026-11-18) M4: `docs/user/managed-databases.md` has "Upgrade app databases on a shared
  server" and says the platform databases stay at the platform version (F156). The drill log is
  handed to EP-267.


## Surprises & Discoveries

- F156: the platform databases take their PostgreSQL version from the payload default on every
  plan (`cli/nagarectl/src/Nagare/Inventory/Components/PackagedAuth.hs:101`,
  `defaultEngineVersion Postgres`, which is `"18"` at `cli/nagare-dsl/src/Nagare/Dsl/Database.hs:162`).
  No accepted-version read exists on that path. A release that moves the default would have every
  context's platform plan refused by F86 (`cli/nagarectl/app/Nagare/Cli/Inventory/Planning.hs:304-318`).
  The refusal is safe, but no transition could converge. This contradicts the guide's "a database
  keeps the version it was created with". It changed the plan: M2 fixes it first.


## Decision Log

- Decision: F156 is fixed with a platform constant, not by reading each accepted StatefulSet's
  image back.
  Rationale: the read would add store reads to every platform plan (MasterPlan 29's cost). A fixed
  platform major already keeps the guide's promise, and moving it waits for D5 anyway.
  Date: 2026-11-18
- Decision: Rehearse 17 → 18 if no newer PostgreSQL major is packaged, as `mp23-c3l` did. The
  procedure is the same for any pair of majors.
  Rationale: the intranet runs 18; the drill needs two majors, not the newest.
  Date: 2026-11-17


## M1 desk-check

The six steps are: (1) back up and prove, (2) declare the new instance, (3) fence and copy, (4)
verify, (5) switch the binding, (6) retire the old.

| Step | Shared server with app databases | Platform `en-db`, `shomei-db`, `en-<name>-db` |
|---|---|---|
| 1 | `db app-database backup`, `backup-receipts`, `restore --restore-id` (scratch) | `db backup en-db -n nagare-system`, `db restore` (scratch) |
| 2 | `db create SERVER-18 --version 18`. Declare a new app database on it, `<name>-v2`; nothing forbids a second app database for one app (scope `appdb-<key>`, `cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs:79`). An in-place `server` change is refused as `migration-review-required` (`cli/nagare-dsl/src/Nagare/Resource/Inventory.hs:924-926`, `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs:834-835`). | Missing. Names are fixed as `<service>-db` (`cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs:111`), and En and Shomei reach them by fixed hosts and Secrets (`cluster/bootstrap/en/service.yaml`, `cluster/bootstrap/shomei/service.yaml`, `cli/nagarectl/src/Nagare/Inventory/Components/AuthTenants.hs:128-143`). |
| 3 | Fence: `db app-database quiesce` closes the logins, drains sessions and suspends the schedule (`Inventory/AppDatabase.hs:520-547`). Copy: manual `pg_dump \| psql` as the server administrator. Restores are bound to the same app database and server (`cli/nagarectl/src/Nagare/Inventory/AppDatabaseRestore.hs:282-284`), so no command copies between two app databases. | A platform writer can be held absent (F144's mechanism, `cli/nagarectl/src/Nagare/Inventory/RebuildRestore.hs`). There is nowhere to copy to. |
| 4 | Manual fingerprints, as in the standalone procedure. | Same. |
| 5 | Change the workload's `appDatabaseBinding` and run a reviewed deploy. The Secret is `<appdatabase>-runtime` (`cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs:835-836`), and the host comes from the accepted users' server (`cli/nagarectl/src/Nagare/Inventory/Application/Bindings.hs:592-651`). A typed `Application` cannot bind an app database (`Inventory/Application/Compile.hs:149-152`). | Missing: the fixed hosts above. |
| 6 | `db app-database retire`, then the old server's retirement. | Missing. |
| Fail | Copy fails: `db app-database resume` (`Inventory/AppDatabase.hs:552-563`). Rejected after the switch: deploy the old binding, then `resume`. | Missing. |

D5's options for the platform databases are in the MasterPlan's Decision Log.


## Outcomes & Retrospective

App databases, standalone and on a shared server, move to a new PostgreSQL major side by side,
drilled locally with both failures ending on the old database with every row. F156 is fixed, so no
release forces a platform database's major. The platform databases (`en-db`, `shomei-db`,
`en-<name>-db`) have no procedure. They moved to the held EP-268 by MasterPlan 36's decision D5.
No ADR.


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
  EP-258 ([docs/plans/258-carry-an-app-s-roles-through-backups-restores-quiesce-and-retirement.md](https://github.com/shinzui/nagare/blob/940c1481caa27e7b267f070b623201c5da31e64f/docs/plans/258-carry-an-app-s-roles-through-backups-restores-quiesce-and-retirement.md))
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
