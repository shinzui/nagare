---
title: "An app may own its database; Nagare keeps apps apart"
status: accepted
date: 2026-11-11
authors: [shinzui]
related:
  - docs/masterplans/35-let-an-app-own-its-database-on-a-shared-postgresql-server.md
  - docs/plans/257-declare-an-app-owned-postgresql-app-database-and-keep-apps-apart.md
  - docs/improvement-requests/let-an-app-own-its-database.md
  - docs/adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md
  - docs/adr/0031-own-database-privileges-are-declarable-server-wide-access-is-not.md
---

# ADR 37 — An app may own its database; Nagare keeps apps apart

## Status

Accepted on 2026-11-11 with [EP-257](../plans/257-declare-an-app-owned-postgresql-app-database-and-keep-apps-apart.md)
under [MasterPlan 35](../masterplans/35-let-an-app-own-its-database-on-a-shared-postgresql-server.md),
which answers [IR-43](../improvement-requests/let-an-app-own-its-database.md). It amends
[ADR 30](0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) and
[ADR 31](0031-own-database-privileges-are-declarable-server-wide-access-is-not.md) for app-owned
databases only.

## Context

ADR 30 makes the declaration the authority for an app database's users and grants and treats
anything else as drift. Apps that manage their own privilege model in their own migrations (the
first is Kotei, whose privilege script creates five roles, memberships among them, moves
ownership of its schemas and objects and grants per role) cannot run under it without rewriting
their migrations, and growing a declaration for every pattern does not scale. From PostgreSQL 16 a
`CREATEROLE` role administers only the roles it created, cannot give an attribute it lacks, and
cannot grant a role it does not administer, which includes the predefined `pg_*` roles. EP-257 M1
proved each of these on PostgreSQL 18 (`cli/nagarectl/test/fixtures/app-database/app-owned.sql`).

## Decision

- **An app database may be declared app-owned** (`ownership = AppOwned`). Nagare then provisions
  one login, the owner (`<name>_owner`, Secret `<name>-owner`), with `LOGIN NOSUPERUSER
  NOCREATEDB CREATEROLE NOREPLICATION NOBYPASSRLS` and `createrole_self_grant = 'set, inherit'`,
  and the database. It has no runtime or migration user and takes no `access` but `owners`.
- **One owning role may be declared** (`databaseOwner`). Nagare creates it without login, makes it
  the database's owner and grants it to the owner with the admin, inherit and set options, because
  moving a database's ownership needs `CREATEDB`, which no app receives. An owning role that
  already exists and is not administered by the owner refuses before anything is created.
- **Nagare judges nothing inside.** Roles the app created, their memberships among themselves,
  schema and object owners, grants and default privileges are the app's.
- **Nagare checks only the boundary.** With the app's roles being the owner and every role
  reachable from it through admin-option memberships, read once by one recursive catalog query,
  each of these is drift and refuses at planning, never revoked: a role of the app holding
  `SUPERUSER`, `CREATEDB`, `REPLICATION` or `BYPASSRLS`; a role of the app being a member of a role
  outside it (another app's, a Nagare user, a `pg_*` role); a role outside the app being a member
  of, or administering, one of its roles; a role of the app owning or holding a privilege on
  another database (its own scratch restores excepted); a role outside the app holding a privilege
  on its database; the database owned by anything but the declared owner. `PUBLIC` on the
  database or a system database is closed again by the next apply.
- **Backups and maintenance run as the server administrator.** The schedule dumps an app-owned
  database with the server's administrator Secret, so no grant the app manages can make a backup
  incomplete. The backup carries the roles the app created with their SCRAM-SHA-256 verifiers;
  Nagare's own users stay out (EP-258). This amends ADR 30's "never roles or password hashes" for
  app-owned databases.
- **Ownership is fixed at creation**, including the owning role. A change refuses with
  `app-database-ownership-fixed`; moving between models is a data migration to a new app
  database.
- **PostgreSQL 18 or later only**; planning refuses an older server.
- **Role names are server-wide.** Two apps on one server cannot create a role of the same name: the
  second fails in its own SQL. Nagare does not rename or prefix. An owning role may not be a name
  another app database on the server derives or owns, and no app database derives a user named as
  another's owning role.
- **Who binds the owner credential stays with the app database.** Its `owners` list names the
  tasks that receive `<name>-owner` (ADR 31's rule, extended to tasks); a long-running workload
  binds the logins the app creates, supplied as ordinary app Secrets.

## Consequences

- An app's own privilege SQL runs unchanged as the owner; Nagare re-plans to `no operations`
  after it.
- An app database that does not opt in renders the same declaration, SQL and backup schedule
  bytes as before.
- What the app does inside its database is no longer reviewed by Nagare. An app that shares its
  database or a role with another app makes both apps' next plans refuse until it is undone.
- The passwords of the logins an app creates are the app's and its operator's; Nagare neither sets
  nor rotates them.
- A drain or resume acts on the sessions of a server that may since be gone, so a fresh rebuild of
  an app database's scope does not run them again, while its migrations and hooks do (2048214e,
  found by EP-260's native run).
