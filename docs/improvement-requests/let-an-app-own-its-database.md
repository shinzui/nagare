---
type: Improvement Request
title: Let an app own its database
description: Give an app database an owner credential with full authority over that database, including creating and administering its own roles and logins, stop treating what the app does inside its own database as drift, and let tasks and pre-deploy hooks bind that credential, so an app manages its own schema, roles and privileges with its own SQL on a shared server while Nagare only keeps apps apart.
timestamp: "2026-11-11T14:27:44Z"
generated:
  by: process:claude-code
  at: "2026-11-11T14:27:44Z"
requestId: IR-43
status: proposed
origin: mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application
dependencies:
  - ref: mori://shinzui/nagare/okf/improvement-requests/concepts/IR-35
    kind: soft
    reason: Supersedes IR-35's case-by-case privilege declarations for apps that own their database; IR-35 remains the model for apps that keep the fixed runtime and migration users.
acceptanceCriteria:
  - id: AC-1
    statement: An app database can be declared app-owned. Its owner credential owns the database and has CREATEROLE, so the app's own SQL can create, alter, grant and drop roles and logins, change ownership of its objects, and grant privileges, with no further Nagare declaration.
    verification: On a local context, declare an app-owned PostgreSQL 18 app database and run Kotei's kotei-migrations/privileges/apply.sql unchanged as the owner credential; assert it succeeds twice, its five roles, memberships, ownership changes and grants exist, and a re-plan prints no operations.
  - id: AC-2
    statement: Apps stay apart. An app's owner credential and the roles it creates cannot alter, drop or join another app's roles or Nagare's users, connect to another app's database, or obtain SUPERUSER, CREATEDB, REPLICATION, BYPASSRLS or a predefined role.
    verification: As one app's owner and as a login it created, attempt each of these against a second app on the same server and assert every attempt fails.
  - id: AC-3
    statement: Nagare does not report roles, memberships, grants, ownership or default privileges inside an app-owned database as drift. It checks only that nothing the app created reaches beyond its own database.
    verification: After AC-1, change grants, add and drop roles and logins as the app, re-plan and assert no operations; grant one of the app's roles CONNECT on another app's database through an administrator and assert planning reports it.
  - id: AC-4
    statement: Backups, scratch restore and rebuilt-server restore include the roles and logins the app created, with their memberships and grants, and recreate them before the data; retiring or quiescing the app database also blocks the app-created logins.
    verification: Back up and rebuilt-restore an AC-1 database and assert the app's roles, logins, memberships, ownership and grants match; quiesce and assert an app-created login cannot connect, resume and assert it can.
  - id: AC-5
    statement: Tasks, including an Application's pre-deploy hooks, can bind an app database's owner credential, and any binding can choose the name of its connection-URL variable; the hook's credential is never added to the app's long-running workloads.
    verification: Bind the owner credential to a pre-deploy hook under KOTEI_RELEASE_MAINTENANCE_DATABASE_URL, apply a reviewed Application, and assert the hook connects as the owner and completes before promotion, and neither the web nor the worker Pod references the owner Secret.
  - id: AC-6
    statement: The managed-databases guide documents app-owned databases, what Nagare enforces between apps, and the hook binding.
    verification: Review docs/user/managed-databases.md for the declaration, the isolation guarantees and a migration-hook example.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-11T14:27:44Z"
    document_timestamp: "2026-11-11T14:27:44Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Nagare v0.18.0 (cli/nagare-dsl AppDatabase.hs and Task.hs;
      cli/nagarectl AppDatabase/Sql.hs membership and relation-ACL observation;
      docs/user/managed-databases.md), PostgreSQL 16+ CREATEROLE semantics, and Kotei's
      kotei-migrations/privileges/apply.sql and nagare/Config.hs. No live rehearsal and no
      independent verification attestation is claimed.
---

# Let an app own its database

**Authored by:** a `claude-code` session in `mori://shinzui/kotei`, assessing how to deploy
Kotei to the `mori://tan/tan-ng-labs` intranet on Nagare v0.18.0.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-11-11.

The operator's requirement: **the app owns its database.** Nagare keeps apps apart on a shared
server. What happens inside an app's database is the app's business.


## Why

Today Nagare manages the inside of every app database:

- **Two fixed users.** Nagare decides which users exist (runtime and migration) and what they
  may do.
- **Exceptions need a declaration or a release.** Each extra privilege must be declared (IR-30,
  IR-35) or wait for a Nagare release.
- **Everything else is drift.** The catalog treats any role, membership or object grant
  Nagare did not create as drift (`cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`).

Real apps manage their own privilege model in their own migrations. Kotei's
`kotei-migrations/privileges/apply.sql` (`mori://shinzui/kotei`, project-relative;
artifact-level URI pending) is typical:

- it creates five roles;
- it grants memberships among them;
- it moves ownership of its schemas and objects to a maintenance role;
- it grants and revokes table and function privileges per role.

None of this can run on a Nagare app database. Each app adapting itself to Nagare, or Nagare
growing a declaration for every pattern, does not scale.

PostgreSQL 16 and later make app ownership safe on a shared server. A `CREATEROLE` role can
administer only the roles it created. It cannot grant attributes it lacks (`SUPERUSER`,
`CREATEDB`, `REPLICATION`, `BYPASSRLS`), and it cannot grant memberships in roles it does not
administer, including predefined roles. Nagare already revokes `CONNECT` from `PUBLIC`, so an
app's roles can reach only the database whose owner grants them access.

Pre-deploy hooks are where an app runs its migrations, but `Task` has no database binding
(`cli/nagare-dsl/src/Nagare/Dsl/Task.hs`). The owner credential therefore has no native path to
the hook, and every binding injects a fixed `DATABASE_URL`.


## What was delivered

MasterPlan 35 ([docs/masterplans/35-let-an-app-own-its-database-on-a-shared-postgresql-server.md](../masterplans/35-let-an-app-own-its-database-on-a-shared-postgresql-server.md),
[ADR 37](../adr/0037-an-app-may-own-its-database-and-nagare-keeps-apps-apart.md)) delivers every
criterion. It was confirmed on 2026-11-12 on a local context with Kotei 1bd9cf48's migrations and
`privileges/apply.sql` unchanged, run as the owner (ExecPlan 260 M1). Two criteria were delivered
differently from their text:

- **AC-1.** The owner credential does not own the database itself when the app moves the
  database's ownership. Changing a database's owner needs `CREATEDB`, which no app receives. The
  declaration therefore names the owning role (`ownership = AppOwned {databaseOwner = Just
  "kotei_maintenance"}`); Nagare creates that role, makes it the database's owner and gives it to
  the owner login with the admin option. Kotei's `ALTER DATABASE … OWNER TO kotei_maintenance` then
  finds the ownership already in place.
- **AC-4.** Backups, restores and quiesce run as the server administrator, not as the owner. A
  backup holds the dump and a role file with every role of the app but the owner, including
  password verifiers. Restore applies the role file as data and refuses one that names an elevated
  attribute or a role outside the app. Quiesce closes the logins the app created and leaves the
  owner open for a migration window unless asked.

Kotei's own `privileges/verify.sql` refuses under this model: its member check of
`kotei_inspection` reaches the owner login, which holds every role it creates and has
`CREATEROLE`. The check is Kotei's to change, so that it excludes the provisioning owner.


## Requested change

- **App-owned app databases** (AC-1). The app database's owner credential owns the database
  and has `CREATEROLE`. The app's SQL does the rest: roles, logins, memberships, ownership and
  grants.
- **Isolation between apps** (AC-2, AC-3). This is all Nagare enforces. Nothing the app does
  inside its own database is drift. Anything that reaches another app's database, another app's
  roles or a server-wide privilege is drift.
- **Backups and lifecycle** (AC-4). Backups and restores carry the app's roles and logins along
  with its data. Retire and quiesce block the app-created logins too.
- **Hooks** (AC-5). Tasks and pre-deploy hooks bind the owner credential, and a binding may
  name its URL variable.

The app's long-running workloads use logins the app itself created. The operator supplies those
credentials as ordinary app Secrets, as for any other app secret.


## Not requested

Changing the fixed runtime and migration model for apps that are happy with it. An app opts
into ownership. ClickHouse can follow under the same rule.
