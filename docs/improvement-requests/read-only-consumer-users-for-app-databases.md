---
type: Improvement Request
title: Give app databases reviewed read-only consumer users
description: Let an app database declare named read-only users that may SELECT only listed tables or views, under fixed query limits, with their own Secret, rotation and retirement, so dashboards and other trusted SQL consumers can read an app's data without its runtime or migration credentials and without access management on the shared server.
generated:
  by: process:claude-code
  at: "2026-10-19T17:40:31Z"
requestId: IR-33
status: accepted
targetPlan: docs/plans/206-give-app-databases-reviewed-read-only-consumer-users.md
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
dependencies:
  - ref: mori://shinzui/nagare/okf/improvement-requests/concepts/IR-32
    kind: soft
    reason: Reader limits reuse the per-user ClickHouse settings-profile and PostgreSQL connection-limit mechanism IR-32 introduces, but a reader with fixed built-in limits can ship first.
acceptanceCriteria:
  - id: AC-1
    statement: An app database can declare one or more named reader users, each with an explicit list of tables or views it may SELECT, and planning shows each reader, its objects and its limits as reviewed members.
    verification: Declare a reader with three ClickHouse views and one with a PostgreSQL schema's views, plan, and assert the operations name every object; declare an object in another app's database and assert the configuration is refused.
  - id: AC-2
    statement: A reader can SELECT exactly its declared objects and nothing else.
    verification: As the reader, assert SELECT on each declared object succeeds; assert SELECT on an undeclared table of the same database, INSERT, ALTER UPDATE or DELETE, DDL, temporary tables, access management, system tables outside the public set, and any object of another app are refused.
  - id: AC-3
    statement: ClickHouse readers run under a Nagare-managed constrained profile that fixes readonly=2 and caps execution time, memory, result rows, result bytes and threads; the reader can lower the time and memory caps but cannot raise any of them.
    verification: As the reader, run a query exceeding each cap and assert it is stopped; SET a cap lower and higher and assert only the lower value is accepted; assert readonly cannot be changed.
  - id: AC-9
    statement: PostgreSQL readers are bounded by a server-enforced connection limit and cannot write or change data through any path, including SECURITY DEFINER functions, even after overriding their role-level read-only and timeout defaults.
    verification: As a PostgreSQL reader, open one connection over the limit and assert it is refused; SET default_transaction_read_only = off and statement_timeout = 0, then assert INSERT, UPDATE, DELETE, DDL and a call to a migration-owned SECURITY DEFINER function that writes are all refused or unreachable; assert a security_invoker view over undeclared tables is flagged at planning.
  - id: AC-4
    statement: Readers of views whose SQL security definer is the app's migration user, and PostgreSQL views owned by it, work without granting the reader the underlying tables.
    verification: Create a SQL SECURITY DEFINER ClickHouse view and a PostgreSQL view owned by the migration user over a table the reader cannot read, and assert the reader can query the view but not the table.
  - id: AC-5
    statement: Declared objects that migrations have not created yet do not wedge the app database; once they exist, a re-plan grants them and then reports no operations.
    verification: Declare a reader before the app's migrations run and assert plan and apply succeed and report the pending objects; run the migrations, re-plan, apply, and assert the next plan has no operations.
  - id: AC-6
    statement: Each reader has its own Secret, can be rotated or retired alone without changing the app's other users, and is never bound to a workload through the owning app's runtime binding.
    verification: Rotate and then retire one reader and assert only its Secret and login change; assert a workload binding the app database still receives only the runtime Secret.
  - id: AC-7
    statement: A workload in another app can bind a reader only if the owning app database declares that consumer.
    verification: Bind a reader from a second app's workload with and without the owner's declaration and assert the deploy is refused without it and injects only that reader's Secret with it.
  - id: AC-8
    statement: Per-app backups capture reader users and their grants, and restores recreate them; scratch restores do not grant readers on the scratch databases unless declared.
    verification: Back up and rebuilt-restore an app database with a reader and assert the reader and its grants return; scratch-restore it and assert the reader cannot read the scratch databases.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-19T17:40:31Z"
    document_timestamp: "2026-10-19T17:40:31Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Nagare v0.7.0 app-database users and drift rules and Kansoku
      9127c47's reader role, profile and consumer guide; no independent verification
      attestation is claimed.
---

# Give app databases reviewed read-only consumer users

**Authored by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on the `tan-ng-labs` intranet, running Nagare v0.7.0.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-19.

This request was added at the operator's request to the set filed with IR-30.


## Why

Nagare v0.7.0 gives an app database exactly two users. Neither is suitable for a dashboard,
notebook or other trusted SQL consumer:

- **Runtime** can read every table and write too.
- **Migration** owns the schema and is meant to stay operator-held.

There is no third user, and v0.7.0 reports any user, role or table-level grant that Nagare did
not create as drift (`cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs`). So a reader
cannot be added by hand either.

Kansoku is the motivating case. Its supported direct-SQL surface is a reader limited to three
stable views, under a constrained settings profile:

- the views: `analytics.events_resolved`, `analytics.events_resolved_v3` and the parameterized
  `analytics.events_analytics_v1`;
- the profile: `readonly=2` constant, at most 30 s and 512 MiB, 10,000 result rows, 10 MiB
  result bytes, overflow throws, four threads.

These are defined in `mori://shinzui/kansoku`, project-relative `db/clickhouse/reader-role.sql`
and `docs/guides/consume-clickhouse.md` (`mori://shinzui/kansoku/okf/guides/concepts/DOC-4`).
The views are `SQL SECURITY DEFINER` with the migration user as definer, so the reader never
needs the raw tables.

Kansoku's guide sets this up with `CREATE ROLE`, `CREATE SETTINGS PROFILE` and `CREATE USER`.
Those require `access_management` for the migration user, which a shared server must not give
an app.

Other apps have the same need: a Grafana panel over an app's PostgreSQL reporting views, or a
read-only export job, should hold a credential that can read only what the owning app publishes.


## Requested change

- **Declaration.** An app database may declare reader users by name, each with:
  - an explicit list of tables or views, or for PostgreSQL optionally all views in a named
    schema;
  - optional limits.

  Objects must be in the app's own databases.
- **Grants.**
  - SELECT on the declared objects only, plus the minimum needed to resolve them: PostgreSQL
    CONNECT and schema USAGE; ClickHouse nothing global.
  - No INSERT, mutations, DDL, temporary tables, `system` grants beyond the public set, or
    access management.
  - Catalog treats these grants as declared members; anything else stays drift.
- **Limits.**
  - ClickHouse readers get a Nagare-managed settings profile with constraints. `readonly=2` is
    constant; execution time, memory, result rows and bytes and threads are capped, and the
    reader may lower time and memory. Defaults should match Kansoku's profile.
  - PostgreSQL readers get a `CONNECTION LIMIT`, which the server enforces. They also get
    role-level `default_transaction_read_only = on` and a `statement_timeout`. PostgreSQL has
    no equivalent of ClickHouse constraints, so a session can `SET` either one back. Treat them
    as defaults, not as the boundary. Read-only must come from grants alone (AC-2), and the
    documentation must say the timeout is advisory.
  - Reuse IR-32's mechanism where it exists.
- **PostgreSQL specifics.**
  - A view declared `security_invoker = true` checks the reader's own privileges on the
    underlying tables. Planning should flag such a view rather than grant those tables
    silently.
  - Schema USAGE plus PostgreSQL's default PUBLIC EXECUTE lets the reader call the app's
    functions. A `SECURITY DEFINER` function owned by the migration user would run with the
    owner's rights and could write. Either keep readers off schemas holding such functions
    unless they are declared, or revoke PUBLIC EXECUTE on them for the reader's path. Report
    which one applies.
  - Readers never get membership in `pg_read_all_data` or any other predefined role.
- **Objects created later.** Declared objects may not exist until the app's migrations run.
  Planning must report them as pending rather than fail. A later review grants them once they
  exist.
- **Credentials and binding.**
  - Each reader has its own Secret, rotation and retirement, independent of the runtime and
    migration users.
  - A workload in another app may bind a reader only when the owning app database names that
    consumer, and it then receives only that reader's Secret. The owning app's runtime binding
    never includes readers.
- **Backup and restore.** Readers and their grants are part of the app database's backup and
  rebuilt restore. Scratch restores do not extend readers to scratch databases unless asked.


## Not requested

Row-level or per-account security. Kansoku's guide is explicit that a reader sees every account,
and that account predicates are not authorization. Readers on another app's objects without that
app's declaration are also out of scope, as is exposing the database servers outside the
cluster.
