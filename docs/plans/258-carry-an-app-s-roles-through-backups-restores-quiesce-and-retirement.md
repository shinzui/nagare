---
id: 258
slug: carry-an-app-s-roles-through-backups-restores-quiesce-and-retirement
title: "Carry an app's roles through backups, restores, quiesce and retirement"
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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-12T06:53:51Z
      mode: "implement"
      note: "Implemented all milestones; native confirmation moves to EP-260 M1"
---

# Carry an app's roles through backups, restores, quiesce and retirement

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and
Outcomes & Retrospective current. Record implementation friction in the friction log as it
occurs (`agents/skills/exec-plan/FRICTION.md`).


## Purpose / Big Picture

An app-owned app database (one whose app creates its own roles and logins; see Context) is
backed up, restored, quiesced, resumed and retired with the same commands as any other app
database, and the roles the app created come along. A backup holds those roles and logins with
their memberships and the database's own grants. A restore onto a rebuilt server recreates them
before the data, so ownership and grants load and the app's logins work with the passwords they
had. Quiesce and retirement close the logins the app created as well as Nagare's.

None of this depends on what the app did to its own privileges: these operations run as the
server administrator. This is IR-43 AC-4
([docs/improvement-requests/let-an-app-own-its-database.md](../improvement-requests/let-an-app-own-its-database.md)).
Backups and lifecycle of app databases that did not opt in are unchanged.


## Progress

- [x] M1: A scheduled or on-demand backup of an app-owned database writes one object holding
  the dump and a role file, under a new signed format token. Ingest accepts it. A backup of an
  app database that did not opt in is byte-for-byte what it was. Evidence: `AppOwnedDatabaseSpec`
  "backups and restores carry the app's roles (EP-258)": the app-owned schedule runs the role
  file query and `tar -C /dump -cf /dump/backup.tar backup.dump roles.json` under format
  `tar.gz`, and an app-owned run ingests (`ingestedWith`); the role file query is the one
  `app-owned.sh` ran on PostgreSQL 18 (`observed/postgres-app-owned-roles.json`); existing
  schedule and ingest tests of Nagare-managed app databases are unchanged. The on-demand backup
  of an app-owned database checks only that it is not retired.
- [x] M2: A scratch restore and a rebuilt-server restore of that backup succeed, and after the
  rebuilt restore the app's roles, logins, memberships, object ownership, database grants and
  password verifiers equal the source's. A role file that fails validation is refused before
  any statement runs. Evidence: in `app-owned.expected` (PostgreSQL 18) the scratch restore
  prints `restored` and the app's login reads its copy; after dropping alpha's database and
  every role and re-applying, the rebuilt restore prints `restored`, a second run changes
  nothing, the role file read afterwards is byte-identical to the source's
  (`postgres-app-owned-roles-restored.json`), the owned observation classifies both members
  complete, and the app's login reads its data; a role file with an elevated attribute or a
  membership naming another app's role fails inside the one transaction. The compiled scratch
  and rebuilt restore Jobs run exactly that SQL (`AppOwnedDatabaseSpec`).
- [x] M3: Quiesce closes the owner's choice of logins and every login the app created, resume
  reopens exactly those, and retirement closes them all. The local smoke proves each on
  PostgreSQL 18, and the user guide documents backup, restore and lifecycle for app-owned
  databases. Evidence: `AppOwnedDatabaseSpec` "quiesce, resume and retirement reach the app's
  logins (EP-258 M3)": quiesce closes and drains `kotei_app` and keeps the owner open (or closes
  it with `owner`), resume reopens exactly it and leaves a never-login role without login, a
  login opened after the review refuses the drain naming it, retirement closes the owner and the
  app's login and re-planning reopens both; a mutant that reopened nothing failed two of them.
  The logins are observed at planning (`ownedLogins` in `cli/nagarectl/app/Nagare/Cli/Data/AppDatabase.hs`)
  and recorded on the `AppOwnedDatabase` spec. Docs: "Backups, restores and maintenance" under
  "App-owned databases" in `docs/user/managed-databases.md` and the rebuild steps in
  `docs/runbooks/inventory-operations.md`. The native proof is EP-260 M1's run (Decision Log).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The role file is JSON produced by one catalog query, not SQL from `pg_dumpall`.
  Rationale: `pg_dumpall --roles-only` cannot be limited to one app's roles, and a restore runs
  as the server's superuser, so it must never execute statements it read from a bucket.
  Date: 2026-11-11.
- Decision: The restore Job applies the role file with one fixed `DO` block Nagare renders
  (`renderRestoreRoles`), which reads the file as data through a psql variable, validates it,
  and builds each statement with the server's `format` and `%I`/`%L`, in one transaction. This
  replaces rendering the statements in nagarectl, which would have needed the backup object at
  planning. Rationale: the file is only in the Job; the server's own quoting is the escaping, and
  the fixture proves the block on PostgreSQL 18. Database grants are made after `SET ROLE` to
  their grantor, since `GRANTED BY` on an object privilege must be the current user (found by
  the fixture). Date: 2026-11-11.
- Decision: The native smoke for this plan runs in EP-260 M1's local run. Rationale: as EP-257's.
  Date: 2026-11-11.
- Decision: A closed login's name is kept as text on the `AppOwnedDatabase` spec, not as a
  `Name`, and rendered with `quoteIdent`. Rationale: the app chooses its role names, which need
  not be Nagare identifiers. Date: 2026-11-11.
- Decision: The role file holds SCRAM-SHA-256 verifiers for the logins the app created and none
  for Nagare's users. Rationale: MasterPlan 35's Decision Log (operator, 2026-11-11); Nagare's
  users take their passwords from their Secrets on re-apply. Date: 2026-11-11.
- Decision: The dump and the role file travel as one object (a gzipped tar) under a new format
  token; app databases that did not opt in keep `dump.gz`. Rationale: the receipt signs one
  object's SHA-256, so one object needs no receipt change. Date: 2026-11-11.
- Decision: The logins a quiesce or retirement closes are listed in the saved review and
  recorded in the accepted scope; resume reopens exactly the recorded list. Rationale: an app
  has roles that were never logins, so "reopen everything" would be wrong, and the review must
  show what it will close. Date: 2026-11-11.


## Outcomes & Retrospective

An app-owned database's backup carries a role file beside its dump; scratch and rebuilt restores
apply it, as data through one server-side block, before the data, and on PostgreSQL 18 a rebuilt
restore returns the role file byte for byte; quiesce, resume and retirement close and reopen
exactly the app's recorded logins. The fixture found two defects before any native run (`t`/`f`
booleans in `GRANT ... WITH`, and `GRANTED BY` on a database privilege), which is ADR 25 working as
intended. The native confirmation is EP-260 M1's. ADR 37 already records the backup decision.


## Context and Orientation

Paths are repository-relative. An **app database** is a tenant of a shared PostgreSQL server,
its own inventory scope `appdb-<key>`
([ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md)).
[EP-257](257-declare-an-app-owned-postgresql-app-database-and-keep-apps-apart.md), which must be
complete before this plan starts, lets a declaration say `ownership = AppOwned`. Such a
database has one Nagare user, the owner (`<name>_owner`, Secret `<name>-owner`), which has
`CREATEROLE`; the app's SQL creates every other role. EP-257 provides, in
`cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs`, the one reading of **the app's
roles** (the owner plus every role reachable from it through admin-option memberships), and in
`cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs` escaping renderers for names Nagare did
not validate. It also already renders an app-owned database's backup schedule to read the
server administrator's Secret, `nagare-db-<server>`. Use those; do not define them again.
ADR 37 (`docs/adr/0037-an-app-may-own-its-database-and-nagare-keeps-apps-apart.md`, written by
EP-257) records the model.

How these operations work today:

- **Scheduled backup.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Backup.hs` builds the
  CronJob `nagare-appdb-<name>` through `renderScheduledCronJob` in
  `cli/nagarectl/src/Nagare/Database/Backup.hs`. The Job runs `pg_dump -Fc` on the one logical
  database, gzips it, uploads it create-only to `app-databases/<namespace>/<name>/`, reads it
  back, and writes a receipt signed with an HMAC key. The signed metadata names the format
  (`dump.gz`) and a digest of the declaration.
- **On-demand backup.** `cli/nagarectl/src/Nagare/Inventory/AppDatabaseBackup.hs` runs the
  accepted CronJob's Job template once. It refuses unless the migration user's login is open.
- **Restore.** `cli/nagarectl/src/Nagare/Inventory/AppDatabaseRestore.hs` runs as the server
  administrator. A scratch restore creates `<db>_restore_<id>` with `renderScratchRestore` and
  runs `pg_restore --exit-on-error` into it. A `--rebuilt` restore runs after the app database
  has been re-applied on a rebuilt server and refuses a database that holds any relation. The
  dump names owners and grantees by role name, and a missing role fails the Job.
- **Quiesce, drain, resume.** `cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs` (near lines
  415 to 446) sets named users to `LoginQuiesced`, suspends the schedule and declares a drain.
  `renderUserAccess` in `Sql.hs` renders `ALTER ROLE ... NOLOGIN`.
  `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabaseSessions.hs` waits a grace period,
  terminates the blocked users' sessions and waits for none to remain, recording the server's
  identity. Resume reopens exactly the quiesced users.
- **Retirement.** `retireAppDatabaseScope` (same file, near line 340) closes every user and
  disables the database.

Two facts about PostgreSQL shape this plan. `pg_dump` never dumps roles, which are server-wide.
And a custom-format dump taken without `--create` does not hold grants on the database itself
(such as `GRANT CONNECT ON DATABASE`) or `ALTER DATABASE ... SET` and `ALTER ROLE ... IN
DATABASE ... SET` settings. A **SCRAM verifier** is the salted hash PostgreSQL stores in place
of a password (`pg_authid.rolpassword`, readable only by a superuser); setting it on a new role
lets the old password work.

Tests: `cli/nagarectl/test/AppDatabaseSpec.hs` covers rendering and compilation of schedules,
restores, quiesce and retirement; `AppDatabaseWorldSpec.hs` runs quiesce and retirement cycles
against the fake catalog in `test/Nagare/Test/World/AppDatabase.hs`, which does not model backup
or restore Jobs. `scripts/local-app-database-smoke.sh` (`just local-app-database-smoke
<context>`) exercises quiesce, on-demand backup, ingest, scratch restore and resume on
PostgreSQL 18; it does not exercise `--rebuilt`.


## Plan of Work

### M1: the backup carries the roles

For an app-owned database, the backup Job additionally runs one query as the administrator that
returns the role file as JSON, and uploads a gzipped tar of `backup.dump` and `roles.json` in
place of the gzipped dump. The role file holds, for the app's roles except the owner user's
password: each role's name, attributes, connection limit, validity, its verifier when it is a
login, and its server-wide settings; every membership among the app's roles with its admin,
inherit and set options; the database's grants and owner; and the database's settings,
including per-role settings in this database. Render the query in `Sql.hs` and pin it in
`AppDatabaseSqlSpec.hs` and the EP-257 fixture
(`cli/nagarectl/test/fixtures/app-database/app-owned.sql`).

Give the signed metadata a new format token for this object, and make ingest
(`cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs`) accept it for app databases. The
on-demand backup of an app-owned database has no migration user, so its precondition does not
apply. Assert in `AppDatabaseSpec.hs` that a `NagareManaged` schedule is unchanged.

### M2: restore recreates the roles first

Add a parser for the role file with validation that refuses, before anything runs: an elevated
attribute (`SUPERUSER`, `CREATEDB`, `REPLICATION`, `BYPASSRLS`), a `pg_` role name, a membership
whose either end is not in the file or the owner, a verifier that is not a SCRAM-SHA-256
verifier, and unknown keys. The restore Job fetches and unpacks the object, and Nagare renders
the role statements itself with the escaping renderers.

A `--rebuilt` restore, after the existing empty-database check: refuse if a role named in the
file exists on the server and is not one of this app's roles (the owner and the declared owning
role already exist from the re-apply and are skipped); create the remaining roles with their
attributes, verifiers and settings; grant the memberships, including the owner's admin option on
each role so the app's roles are again reachable from it; apply the database's grants and
settings; then run `pg_restore` as today. A scratch restore runs on the same server, where the
roles exist: create the scratch database with the source's owner and grants from the role file,
then `pg_restore`.

Extend `AppDatabaseSpec.hs` for the rendered restore, and add parser tests for each refusal.

### M3: quiesce, resume and retirement reach the app's logins

For an app-owned database, quiesce closes every login among the app's roles and, when the
operator asks with `--users owner`, the owner too; by default the owner stays open so the app's
migrator can run in the window. The plan prints the logins it will close; the scope records
them; the drain terminates and counts their sessions; resume reopens exactly the recorded
logins. If a login among the app's roles is open at the drain that the review did not list, the
drain fails and names it. Retirement closes the owner and every login among the app's roles and
records them; re-planning the app database reopens them.

Extend the fake catalog and `AppDatabaseWorldSpec.hs` with a quiesce and resume cycle and a
retirement over app-created logins and non-login roles. Extend
`scripts/local-app-database-smoke.sh`: back up an app-owned database, restore it to scratch,
quiesce and show an app-created login refused, resume and show it connect; then delete the
database and the app's roles, re-apply, restore with `--rebuilt`, and compare roles,
memberships, ownership, grants and a login with its original password against the source.

In `docs/user/managed-databases.md`, extend the "App-owned databases" subsection EP-257 started
with backups (what the object holds, that it runs as the administrator), restore and the
rebuilt-server order, and quiesce, resume and retirement. Update the rebuild steps in
`docs/runbooks/inventory-operations.md` where they describe app databases.


## Concrete Steps

From the repository root, per Haskell commit:

```bash
just haskell-style-check
just gate-fast
```

For each milestone on a local context (see `docs/user/local-development.md`):

```bash
just local-app-database-smoke <local-context>
```


## Validation and Acceptance

M1: the smoke's backup of an app-owned database ingests, and the unpacked object holds a dump
and a role file naming the roles the smoke's script created. M2: the rebuilt-server comparison
in the smoke shows no difference and the restored login connects with its original password;
each parser refusal has a test. M3: the smoke shows the app-created login refused while
quiesced and accepted after resume, and `db app-database evidence` shows the drain. In every
milestone the smoke's existing steps for an app database that did not opt in still pass, and
`just gate-fast` is green with no uncommitted changes before landing.


## Idempotence and Recovery

Role creation in a rebuilt restore skips a role that already exists as one of this app's roles
with the same definition, so a restore interrupted after the roles and before the data can be
run again; the empty-database check still protects data. Quiesce and resume remain reviewed,
forward-only operations with the server identity checks they have today. The smoke uses a
disposable local context. Nothing here touches a cloud context.


## Interfaces and Dependencies

Hard dependency: EP-257 complete (the declaration, the owner user, the reading of the app's
roles, the escaping renderers, the administrator credential on the schedule). No new library.
Check that `tar` is present in the image of the container that packs the object before relying
on it; the Jobs already use `gzip`.
[EP-260](260-confirm-an-app-owned-database-with-kotei-s-unchanged-privilege-script-and-release-it.md)
confirms this plan's behavior with Kotei's real script.
