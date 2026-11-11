---
id: 257
slug: declare-an-app-owned-postgresql-app-database-and-keep-apps-apart
title: "Declare an app-owned PostgreSQL app database and keep apps apart"
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

# Declare an app-owned PostgreSQL app database and keep apps apart

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and
Outcomes & Retrospective current. Record implementation friction in the friction log as it
occurs (`agents/skills/exec-plan/FRICTION.md`).


## Purpose / Big Picture

An app database on a shared PostgreSQL server can be declared app-owned. Nagare then creates one
login for it, the owner credential, which has `CREATEROLE` and owns the database. The app's own
SQL, run as that login, creates roles and logins, grants memberships, moves ownership of its
objects and grants privileges, and a re-plan afterwards prints `no operations`. Nagare checks
only that nothing the app created reaches another app's roles or database, Nagare's users, or a
server-wide privilege, and reports any such reach as drift.

This is IR-43 AC-1, AC-2 and AC-3
([docs/improvement-requests/let-an-app-own-its-database.md](../improvement-requests/let-an-app-own-its-database.md)).
An app database that does not opt in is unchanged, byte for byte.


## Progress

- [ ] M1: The PostgreSQL rules the design rests on are proven against real PostgreSQL 18
  with a checked-in fixture and its expected results. Any rule that does not hold is recorded
  here and in the MasterPlan before M2 starts.
- [ ] M2: An app-owned app database plans, applies and re-plans to `no operations`, before and
  after a Kotei-shaped script creates roles, memberships, ownership changes and grants inside
  it. An app database that did not opt in renders identical declaration JSON, SQL and backup
  schedule bytes.
- [ ] M3: Each reach beyond the app's own database is reported as drift at planning, and each
  attempt in the AC-2 list fails on a real server. ADR 37 is written, ADR 30 and ADR 31 carry
  an amendment note, and the user guide documents the declaration and the guarantees.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The owner user's attributes are `LOGIN NOSUPERUSER NOCREATEDB CREATEROLE
  NOREPLICATION NOBYPASSRLS`, and Nagare sets `createrole_self_grant = 'set, inherit'` on it.
  Rationale: with that setting the owner automatically holds the roles it creates, so
  `ALTER ... OWNER TO` a role it created works as it would for the superuser most migrations
  were written for. Date: 2026-11-11.
- Decision: The declaration may name one owning role (`databaseOwner`). Nagare creates it
  without login, makes it the database's owner, and grants it to the owner user with the admin,
  inherit and set options. Rationale: `ALTER DATABASE ... OWNER TO` needs `CREATEDB`, which no
  app receives; Kotei's script skips that statement when the ownership already holds (operator,
  2026-11-11). Date: 2026-11-11.
- Decision: An app-owned database has no runtime or migration user, takes no `access` other than
  `owners`, and its ownership cannot be changed after creation. Rationale: MasterPlan 35's
  Decision Log. Date: 2026-11-11.
- Decision: Nagare does nothing inside an app-owned database. It creates the database with its
  owner, revokes every database privilege from `PUBLIC`, and keeps `PUBLIC` out of the system
  databases as it does today. It does not change the owner of the `public` schema or set default
  privileges. Rationale: the inside is the app's. Date: 2026-11-11.
- Decision: The backup schedule of an app-owned database dumps as the server administrator from
  its first review. Rationale: a dump as the owner user would miss objects the app moved out of
  its reach (MasterPlan 35 integration point; the role file is EP-258). Date: 2026-11-11.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Paths are repository-relative. Nagare configuration is a Haskell program (`Config.hs`) that
emits JSON; `nagarectl` loads it, plans operations against an accepted inventory, saves a
review, and applies it.

An **app database** is a reviewed tenant of a shared server
([ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md)). It is its own
inventory scope `appdb-<key>` holding, today, two credential Secrets (`<name>-runtime`,
`<name>-migration`), two database users, one logical database on PostgreSQL, and a backup
schedule. The declaration is `AppDatabase` in `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`.
Its JSON instances write a key only when it has a value, so older declarations keep their bytes,
and they refuse unknown keys. `AppDatabaseRole` (`RuntimeRole`, `MigrationRole`, `ReaderRole`)
with `appDatabaseRoleToken`, `appDatabaseUser` and `appDatabaseSecretName` derives every name.
`cli/nagare-dsl/src/Nagare/Resource/AppDatabase.hs` turns a declaration into inventory members.

`cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs` renders every SQL statement and
observation query. `renderCreateUser` writes the role attributes, `renderDatabaseAccess` the
grants on one database, `renderObserveServer` the server-wide facts (roles with their
`elevated` attributes, memberships, database owners and grants, `foreignAccess`). Its `pgIdent`
wraps a name in double quotes without escaping, which is safe only because every name so far is
a validated identifier. `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs` parses the
observation and classifies each member as complete, incomplete or drift. Today it reports as
drift any elevated attribute including `CREATEROLE` (near line 218), any membership with a role
outside the scope, any database not owned by the migration user, any schema owned by another
role, and any default privilege set by another role (near lines 708 to 725).
`cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs` compiles the scope, and
`cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs` defines the `CatalogCommand` values
the adapter executes through `kubectl exec` and `psql` as the server's superuser.

The backup schedule is rendered in `cli/nagarectl/src/Nagare/Database/AppDatabase/Backup.hs`,
which names the Secret the dump reads its credential from (`<name>-migration`, near line 75).
The server administrator's Secret is `nagare-db-<server>`, in the same namespace.

Tests: `cli/nagarectl/test/AppDatabaseSqlSpec.hs` pins rendered SQL to
`cli/nagarectl/test/fixtures/app-database/postgres.sql`, which was proven by hand against
`postgres:18`. `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs` is a fake catalog that
interprets `CatalogCommand` values (not SQL) and models users, attributes, memberships, database
owners and grants; `AppDatabaseWorldSpec.hs` converges and re-plans against it.
`scripts/local-app-database-smoke.sh` (`just local-app-database-smoke <context>`) runs the real
commands against PostgreSQL 18 on a local k3d context.

[ADR 31](../adr/0031-own-database-privileges-are-declarable-server-wide-access-is-not.md) sets
the boundary at the app's own databases and says the app database, never the workload, decides
who binds the owning credential (`access.owners`). Both are kept.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires
defects to be found by interpreter tests before a native run.

PostgreSQL terms used here. A **role** is a server-wide account or group; a **login** is a role
that may connect. `CREATEROLE` lets a role create roles. From PostgreSQL 16, the creator of a
role is granted that role with the **admin option** by the bootstrap superuser, and may alter,
drop or grant only roles it holds the admin option on. It cannot give an attribute it lacks
(`SUPERUSER`, `CREATEDB`, `REPLICATION`, `BYPASSRLS`) or membership in a role it does not
administer, which includes the predefined `pg_*` roles. **The app's roles** in this plan means
the owner user plus every role reachable from it by following admin-option memberships.


## Plan of Work

### M1: prove the PostgreSQL rules

Add `cli/nagarectl/test/fixtures/app-database/app-owned.sql` and a short script beside it that
runs it against a disposable `postgres:18` container (use Apple's `container`
tool locally). The fixture sets up two tenants as Nagare will (two owner logins with the
attributes above, two databases, `PUBLIC` revoked, one declared owning role), then, as tenant
A's owner, runs a Kotei-shaped script: guarded `CREATE ROLE` for several roles, memberships
among them, a guarded `ALTER DATABASE ... OWNER TO` the declared owning role, `ALTER SCHEMA`,
`ALTER TABLE` and `ALTER FUNCTION ... OWNER TO`, and table, sequence and function grants and
revokes. The shape follows `kotei-migrations/privileges/apply.sql` in `mori://shinzui/kotei`
(project-relative path; artifact-level URI pending); do not copy that file.

The fixture must show, with the server's own output recorded as expected results:

- the script succeeds twice in a row;
- as A's owner and as a login A created, each of these fails: altering, dropping or joining B's
  roles and Nagare's users; connecting to B's database; creating or altering a role with
  `SUPERUSER`, `CREATEDB`, `REPLICATION` or `BYPASSRLS`; granting a `pg_*` role; `ALTER
  DATABASE ... OWNER TO` an undeclared role; setting the password of a role A does not
  administer;
- A's owner cannot revoke the admin-option grant it received at role creation, so a role it
  created cannot leave the set reachable from it. If it can, record that here and add to M3 a
  server-wide check that every non-system role belongs to exactly one tenant or to Nagare;
- the catalog query that reads the app's roles (a recursive query over `pg_auth_members` on
  `admin_option`) returns exactly A's roles.

### M2: the declaration, the owner, and no judgement inside

In `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs` add `ownership` to `AppDatabase` with a type
`Ownership = NagareManaged | AppOwned { databaseOwner :: Maybe RoleName }`. Write the JSON key
only for `AppOwned`. `RoleName` is a validated identifier like `SchemaName`, and refuses the
`pg_` prefix. Add `OwnerRole` to `AppDatabaseRole` with token `owner`. `validateAppDatabase`
refuses `AppOwned` on any engine but PostgreSQL and with any `access` other than `owners`.
`appDatabaseRoles` returns only `OwnerRole` for an app-owned database. Update the loader
(`cli/nagare-dsl/src/Nagare/Dsl/Load/AppDatabase.hs`) and every `AppDatabase` record literal in
tests, fixtures and docs.

In planning, refuse an app-owned declaration on a server below major version 18, a change of
`ownership` on an accepted app database, a `databaseOwner` name that an accepted scope on that
server already derives for one of its users, and a long-running workload (`Deployment` or
`Worker`) that binds an app-owned database. Write these refusals as pure functions of the
declaration and the accepted snapshot, and run them both when a review is prepared and at
admission, as [MasterPlan 35](../masterplans/35-let-an-app-own-its-database-on-a-shared-postgresql-server.md)'s
integration point on several operators requires.

In `Sql.hs`, render the owner user (attributes above, then `ALTER ROLE ... SET
createrole_self_grant`), the optional owning role and its grant to the owner, the database
created with its owner, and the `PUBLIC` revocations. Add escaping identifier and literal
renderers for names Nagare did not validate, and use them wherever an observed role name is
rendered. Extend `renderObserveServer` with the app's roles, read once.

In `Catalog.hs`, classify an app-owned database's members without judging the inside: schema
owners, default privileges, relation owners, grants to the app's roles on its own database and
memberships among the app's roles are never drift. The owner user is complete when its
attributes, setting and database ownership are as declared.

In `Backup.hs`, an app-owned database's schedule reads the server administrator's Secret.

Extend the fake catalog in `test/Nagare/Test/World/AppDatabase.hs` with the new commands and
with roles created outside Nagare, and add World tests: converge, apply app-made changes,
re-plan to no operations. Add a golden test that a `NagareManaged` declaration's JSON, SQL and
schedule are unchanged.

### M3: the boundary

In `Catalog.hs`, with C the app's roles, report as drift on the owner user's member, naming the
role and the reach:

- a role in C with `SUPERUSER`, `CREATEDB`, `REPLICATION` or `BYPASSRLS`;
- a role in C that is a member of a role outside C (another app's role, a Nagare user, a `pg_*`
  role);
- a role outside C, other than the bootstrap superuser's grant, that is a member of or
  administers a role in C;
- a role in C holding any privilege on, or owning, a database other than this one;
- a role outside C holding a privilege on this database;
- the database owned by anything but the declared owner.

Keep the existing check that reports a membership between a `NagareManaged` app database's users
and any outside role; it is what catches an app that created a role under a name Nagare later
derives. Drift is refused at planning, never revoked, as today.

Add World tests for each line, and extend `scripts/local-app-database-smoke.sh` with two
app-owned databases on one server: run the M1 script as one owner, attempt the AC-2 list as that
owner and as a login it created, and grant one of its roles `CONNECT` on the other database as
the administrator and expect the next plan to report it.

Write `docs/adr/0037-an-app-may-own-its-database-and-nagare-keeps-apps-apart.md` in the form of
the existing ADRs: the model, the boundary list above, what an app-owned backup carries and who
runs it (from MasterPlan 35's Decision Log), and the rule that role names are server-wide so two
apps cannot create the same one. Add one line under Status in ADR 30 and ADR 31 saying ADR 37
amends them for app-owned databases. In `docs/user/managed-databases.md`, under "Sharing one
server between apps", start an "App-owned databases" subsection with the declaration, what
Nagare creates, what it enforces between apps, and the limits (PostgreSQL 18 or later, fixed at
creation, server-wide role names).


## Concrete Steps

From the repository root, per Haskell commit:

```bash
just haskell-style-check
just gate-fast
```

For M2 and M3 on a local context (see `docs/user/local-development.md`):

```bash
just local-app-database-smoke <local-context>
```


## Validation and Acceptance

M1 is accepted when the fixture's recorded results match on PostgreSQL 18. M2 is
accepted when the World tests pass, the unchanged-bytes golden test passes, and on a local
context the smoke shows `no operations` after the script has run twice. M3 is accepted when the
World tests for each boundary line pass, every AC-2 attempt in the smoke fails with the server's
own permission error, and the cross-database `CONNECT` grant is reported by `db app-database
plan`. `just gate-fast` is green with no uncommitted changes before landing.


## Idempotence and Recovery

Every new statement is rendered so a retried review converges: the owner user, the owning role
and the database are created only when observation shows them absent, as the existing users
are. The fixture and the smoke use disposable servers. Nothing here touches a cloud context.


## Interfaces and Dependencies

No new library. Other plans consume from this one: the `ownership` field and `OwnerRole` with
its derived names, the single reading of the app's roles in `Catalog.hs`, the escaping
renderers in `Sql.hs`, and the administrator credential on the app-owned backup schedule.
[EP-258](258-carry-an-app-s-roles-through-backups-restores-quiesce-and-retirement.md) and
[EP-259](259-let-tasks-and-pre-deploy-hooks-bind-an-app-database-under-a-named-url-variable.md)
depend on them; this plan depends on neither.
