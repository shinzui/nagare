---
id: 206
slug: give-app-databases-reviewed-read-only-consumer-users
title: "Give app databases reviewed read-only consumer users"
kind: exec-plan
created_at: 2026-10-19T19:58:14Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-19T19:58:14Z
---

# Give app databases reviewed read-only consumer users

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This plan answers [IR-33](../improvement-requests/read-only-consumer-users-for-app-databases.md),
filed from the Kansoku deployment
(`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`).

An app database has exactly two users today. The runtime user reads and writes everything. The
migration user owns the schema. A dashboard, a notebook or an export job needs a third kind of
credential that can read only what the owning app publishes. It cannot be added by hand,
because any extra user or table grant is drift. Kansoku's own reader setup (`CREATE ROLE`,
`CREATE SETTINGS PROFILE`) needs access management, which a shared server must not give an app.

After this plan, an app database can declare named **readers**. Each reader has:

- an explicit list of tables or views it may `SELECT`, or, on PostgreSQL, all views in a named
  schema;
- server-enforced limits. On ClickHouse these are a constrained profile: `readonly=2` fixed,
  plus ceilings on time, memory, result rows, result bytes and threads. On PostgreSQL they are a
  connection limit, plus role defaults for read-only transactions and a statement timeout;
- its own Secret, `<appdb>-reader-<reader>`, which can be rotated or retired on its own;
- a list of consumer apps in the same namespace. Only those apps' workloads may bind it.

A reader can read its declared objects and nothing else. On PostgreSQL that boundary comes from
grants alone, not from the overridable role defaults. Planning refuses a PostgreSQL schema that
would hand a reader a write path through a `SECURITY DEFINER` function, and it flags a
`security_invoker` view. Objects the app's migrations have not created yet are reported as
pending, and do not wedge the app database. For Kansoku, the reader is `dashboards` on
`kansoku-ch`, over `analytics.events_resolved`, `analytics.events_resolved_v3` and
`analytics.events_analytics_v1`, with Kansoku's profile as the default limits.


## Progress

- [ ] M1 (engine proof). Reader statements and observations are proven by hand against
  `postgres:18` and `clickhouse/clickhouse-server:26.8`. They are committed as `-- operation:`
  blocks in `cli/nagarectl/test/fixtures/app-database/clickhouse.sql` and `postgres.sql`, with
  captured observations under `observed/`. Every question listed under M1 in Plan of Work is
  answered in the Decision Log.
- [ ] M2 (declaration). `AppDatabase` declares readers, each with a name, objects, optional
  limits and consumers. `AppDatabaseRole` gains `ReaderRole`. Derived user and Secret names fit
  both engines' identifier limits. The loader refuses an object outside the app's own databases
  (IR-33 AC-1), a repeated reader, and a name that would be too long.
- [ ] M3 (members, grants and classification). Each reader compiles to a credential member and
  a user member. The adapter creates, grants, limits and observes readers. Logical-database
  members accept declared reader grants. Anything else stays drift. Absent PostgreSQL objects
  plan as pending. The two PostgreSQL write-path refusals hold. `AppDatabaseWorldSpec` proves
  IR-33 AC-1, AC-2, AC-4, AC-5 and AC-9 in the interpreter, and AC-3 against the M1 semantics.
- [ ] M4 (credentials and binding). `rotate --user reader:<r>` rotates one reader, and
  `retire --reader <r>` retires one reader. Neither touches other users. A workload binds a
  reader through `appDatabaseReaders` only when the owning declaration lists its app, and then
  receives only that Secret. `appDatabases` never injects a reader. Render tests prove IR-33
  AC-6 and AC-7.
- [ ] M5 (backup, restore and docs). Rebuilt restore brings readers and their grants back, and
  scratch restore does not extend readers to scratch databases (IR-33 AC-8), on both engines.
  The "Sharing one server between apps" section of `docs/user/managed-databases.md` documents
  readers, including the advisory nature of the PostgreSQL role defaults. Commands are
  registered in `scripts/audit-managed-commands.py`. The change is landed with a green
  `just gate-fast`.
- [ ] M6 (native confirmation). `scripts/local-app-database-smoke.sh` declares one reader on
  `alpha-ch` and one on `alpha-pg`. It binds each from a second app, and proves AC-2, AC-3, AC-6,
  AC-7, AC-8 and AC-9 on a disposable local context with the packaged CLI.
- [ ] M7 (release). The change ships in a release. The intranet is upgraded on the candidate
  before the tag. `kansoku-ch` declares its `dashboards` reader in `mori://tan/tan-ng-labs`.
  IR-33 is completed in `docs/improvement-requests/log.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: This plan starts after
  [EP-204](204-let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits.md) M3 is
  landed.
  Rationale: Reader limits reuse EP-204's ClickHouse user-level settings with constraints, its
  PostgreSQL connection limit and role settings, and their observation and classification.
  Building readers first would mean a second limits mechanism, which IR-33 asks Nagare to avoid.
  Date: 2026-10-19

- Decision: Readers are named `<appdb_with_underscores>_reader_<reader>`. Their Secrets are
  named `<appdb>-reader-<reader>`, and their spec role token is `reader-<reader>`. A reader
  name matches `[a-z][a-z0-9]{0,15}`.
  Rationale: An app-database name is at most 36 characters, so the longest user name is 60
  characters. That is under PostgreSQL's 63, and needs no quoting on either engine. A fixed
  infix keeps readers distinct from `_runtime` and `_migration` for any reader name.
  Date: 2026-10-19

- Decision: ClickHouse reader limits are user-level settings with constraints, as EP-204 sets
  them. The defaults are Kansoku's profile:
  - `readonly = 2 CONST` and `result_overflow_mode = 'throw' CONST`;
  - `max_execution_time = 30 MAX 30`;
  - `max_memory_usage = 536870912 MAX 536870912`;
  - `max_result_rows = 10000 MAX 10000`;
  - `max_result_bytes = 10485760 MAX 10485760`;
  - `max_threads = 4 MAX 4`.

  A declaration may set different positive ceilings, but cannot change the two `CONST`
  settings.
  Rationale: IR-33 asks for these defaults and for reuse of IR-32's mechanism. Settings on the
  user avoid a named profile entity per reader. M1 confirms that a zero value, which means
  unlimited, is refused.
  Date: 2026-10-19

- Decision: PostgreSQL reader limits are `CONNECTION LIMIT` (default 5), plus role settings
  `default_transaction_read_only = on` and `statement_timeout = '30s'`. The docs call the two
  settings advisory defaults. The read-only boundary is grants: `CONNECT` on the database,
  `USAGE` on the schemas of declared objects, and `SELECT` on each declared object. A reader
  never gets membership in any role, including `pg_read_all_data`.
  Rationale: A session can `SET` either role setting back, as IR-33 AC-9 notes. Only grants and
  the connection limit are enforced by the server.
  Date: 2026-10-19

- Decision: The PostgreSQL `SECURITY DEFINER` path is closed by refusing to plan. The plan
  refuses with `app-database-reader-definer-function` when a schema the reader would get
  `USAGE` on holds a `SECURITY DEFINER` function that `PUBLIC` or the reader can execute. The
  message names each function. Nagare does not revoke `PUBLIC EXECUTE` itself.
  Rationale: Revoking `PUBLIC EXECUTE` would change the app's own objects, which Nagare does not
  own. The app can revoke it in a migration, after which the plan passes. IR-33 asks Nagare to
  report which way applies.
  Date: 2026-10-19

- Decision: A declared PostgreSQL view with `security_invoker = true` refuses with
  `app-database-reader-invoker-view`, naming the view.
  Rationale: Such a view checks the reader's own grants on its base tables. Granting those
  tables silently would widen the reader beyond its declaration.
  Date: 2026-10-19

- Decision: An absent declared PostgreSQL object is pending. The reader member is complete over
  the present objects, and the plan prints `pending: <schema>.<object>`. Once the object
  exists and is ungranted, the member is incomplete, and a re-plan grants it. ClickHouse
  behaves the same way unless M1 shows that a grant on a not-yet-existing table both succeeds
  and is observed exactly. In that case ClickHouse grants by name up front and has nothing
  pending.
  Rationale: IR-33 AC-5 requires that a reader declared before migrations neither fails nor
  wedges, and that the next plan after migrations ends with no operations.
  Date: 2026-10-19

- Decision: Consumers are app names in the app database's own namespace. Cross-namespace
  readers are out of scope.
  Rationale: An app database, its server and its bound workloads are already in one namespace
  (`acceptedAppDatabaseServer` refuses otherwise), and a Secret can only be mounted in its own
  namespace.
  Date: 2026-10-19

- Decision: A reader binding injects the same variable names as a runtime binding, so a
  workload binds at most one credential per engine: a runtime or a reader.
  Rationale: ADR 30 already limits a workload to one database per engine, because bindings
  inject fixed names.
  Date: 2026-10-19

- Decision: One reader is retired by `db app-database retire NAME --reader R`, a scope revision
  that closes its login and revokes its grants while keeping its Secret. A later `plan` that
  still lists the reader re-opens it, as app-database retirement does. A `plan` that drops an
  enabled reader from the declaration refuses with `app-database-reader-not-retired`.
  Rationale: This mirrors app-database retirement (ADR 30, EP-203 F131), and never deletes a
  credential implicitly.
  Date: 2026-10-19


## Outcomes & Retrospective

(None yet.)


## Context and Orientation

Nagare is a single-node PaaS driven by `nagarectl`, a Haskell CLI under `cli/nagarectl/`. Its
declaration types live in `cli/nagare-dsl/`. Every change is a saved, reviewed plan that
`nagarectl inventory apply DIR --yes` executes. Read
[EP-202](202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md),
[ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) and
[EP-204](204-let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits.md) first.

An **app database** is the inventory scope `appdb-<key>`, a tenant of a shared server. Its
members are:

- credential Secrets `<name>-runtime` and `<name>-migration`;
- users `<name>_runtime` and `_migration`;
- logical-database members;
- a backup schedule.

A **reader** is a third kind of user added by this plan. A **consumer** is an app whose
workloads may bind a reader. A **definer view** is a ClickHouse `SQL SECURITY DEFINER` view, or
a PostgreSQL view owned by the migration user. It reads its base tables with its owner's rights,
so a reader needs `SELECT` on the view only.

Where each part lives:

- **Roles and names.** In `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`:
  - `AppDatabaseRole = RuntimeRole | MigrationRole`, which derives `Enum` and `Bounded`;
  - `appDatabaseUser`, `appDatabaseSecretName` and `appDatabaseRoleToken`;
  - the grant functions;
  - EP-204's `AppDatabaseAccess`.
- **Members.** `compileAppDatabase` in `cli/nagare-dsl/src/Nagare/Resource/AppDatabase.hs`
  builds a credential and a user member per role, plus the logical-database and backup members.
  `appDatabaseCredentialTemplate` writes the Secret's labels and annotations, including
  `nagare.dev/app-database-role`. Spec validity, which today allows only the role tokens
  `runtime` and `migration`, is in `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` near
  line 217.
- **SQL and observation.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`.
  - PostgreSQL observation reads database, schema and default ACLs, not per-relation ACLs. A
    reader's per-object `SELECT` needs a new per-database relation observation.
  - ClickHouse observation already returns every `system.grants` row of the app's users, plus
    every grant on the app's databases.
- **Classification.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs`.
  - `classifyDatabase` treats a ClickHouse grant on the app's database to anyone but the two
    users as `granted to …` drift.
  - `postgresGrant` treats any PostgreSQL grantee except the two users, `PUBLIC` and
    `pg_database_owner` as drift.
  - ClickHouse table-level grants are anomalies.

  All of these must learn the declared readers.
- **Adapter.** `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs`:
  `AppDatabaseMember`, `MemberKind`, `UserMember role user secretNs secretName`, and
  `mkAppDatabaseAdapter`.
- **Rotation and retirement.** `rotateAppDatabaseScope` and `retireAppDatabaseScope` are in
  `cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs`. Their CLI is
  `cli/nagarectl/app/Nagare/Cli/Parser/AppDatabase.hs`, with `--user runtime|migration`.
- **Bindings.** `appDatabases :: ![AppDatabaseName]` on the deployment record is in
  `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` near line 716. It is loaded in
  `cli/nagare-dsl/src/Nagare/Dsl/Load/Deployment.hs` and emitted only when non-empty by
  `appDatabasesJSON` in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`.
  `acceptedAppDatabaseBindings` in `cli/nagarectl/src/Nagare/Inventory/Application/Bindings.hs`
  resolves each name to the `<name>-runtime` Secret in the namespace. It refuses a retired app
  database by requiring every user spec to be enabled. That check must become "the runtime
  user is enabled", or retiring one reader would block every binding.
- **Backups.** `appDatabaseDumpShell` in `cli/nagarectl/src/Nagare/Database/Backup.hs` dumps
  PostgreSQL in custom format, with owners and ACLs, as the migration user, and ClickHouse with
  `BACKUP DATABASE`, which carries no user grants. Scratch restore
  (`renderScratchRestore` in `Sql.hs`) revokes `ALL ON DATABASE` from `PUBLIC` and grants only
  the runtime user `CONNECT`. So a reader's restored ACLs on scratch objects are unreachable
  without `CONNECT`.
- **Tests and smoke.**
  - `cli/nagarectl/test/AppDatabaseSqlSpec.hs` (fixtures);
  - `cli/nagarectl/test/AppDatabaseSpec.hs` (compile, bindings, schedules);
  - `cli/nagarectl/test/AppDatabaseWorldSpec.hs` with
    `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs` (interpreter world);
  - `scripts/local-app-database-smoke.sh` (native).

Relevant ADRs:

- [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md): the
  declaration is the authority for users and grants, undeclared access is drift, a workload
  binds one database per engine, and backups dump with the migration credential.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): the
  interpreter world finds defects, and the smoke confirms.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
  every transport call checks the server's recorded identity.


## Plan of Work

**M1, engine proof.** Use containers with the server render's environment, as EP-202 M1 did.
Set up `alpha` with a base table, a definer view, a parameterized definer view and an undeclared
table. Add a reader `alpha_reader_dash` on each engine.

ClickHouse questions:

- **Grants.** With `GRANT SELECT ON alpha.v1, alpha.v2, alpha.pv TO alpha_reader_dash` and the
  user settings from the Decision Log:
  - are the declared views readable, including `SELECT * FROM alpha.pv(x = 1)`?
  - are the base table and the undeclared table refused?
  - are `INSERT`, `ALTER … UPDATE`, `CREATE TABLE`, `CREATE TEMPORARY TABLE`, `CREATE USER`,
    `SELECT FROM system.parts` and `SELECT FROM beta.t` all refused?
- **Ceilings.** Is each ceiling enforced when exceeded? Is `SET max_execution_time = 10`
  accepted, `= 60` refused and `= 0` refused? Is `SET readonly = 0` refused?
- **Early grants.** Is a grant on a table that does not exist yet accepted, and is it reported
  in `system.grants` exactly? This decides the pending rule for ClickHouse.

PostgreSQL questions:

- **Grants.** With `CONNECT`, `USAGE ON SCHEMA public` and `SELECT` on two views owned by
  `alpha_migration`, can the reader read the views but not the base table?
- **Write path.** After `SET default_transaction_read_only = off; SET statement_timeout = 0`,
  are `INSERT`, `UPDATE`, `DELETE` and `CREATE TABLE` refused?
- **Definer function.** Is a migration-owned `SECURITY DEFINER` function that inserts callable
  by default? It is expected to be, through `PUBLIC EXECUTE`. Is it refused after
  `REVOKE EXECUTE … FROM PUBLIC`?
- **Invoker view.** Does a `security_invoker = true` view fail for the reader?
- **Connection limit.** Is connection limit + 1 refused?
- **Observation.** Write a relation-ACL observation query for one database. It returns, for each
  relation whose ACL names a reader, the schema, name, `relkind`, `reloptions` and the reader's
  privileges. It also returns `SECURITY DEFINER` functions in the given schemas, with their
  ACLs. Capture its output.

**M2, declaration.** In `Nagare.Dsl.AppDatabase`:

- Add `ReaderName` (validated) and `AppDatabaseReader { name, objects :: NonEmpty
  ReaderObject, limits :: !ReaderLimits, consumers :: ![AppName] }`.
- `ReaderObject` is `ReaderTable LogicalDatabaseName Text` (schema-qualified on PostgreSQL), or
  `ReaderSchemaViews Text` (PostgreSQL only).
- Add `readers :: ![AppDatabaseReader]` to EP-204's `AppDatabaseAccess`.
- `AppDatabaseRole` gains `ReaderRole !ReaderName`. Drop `Enum` and `Bounded`, and replace
  `[minBound ..]` uses with explicit lists.
- Extend `appDatabaseUser`, `appDatabaseSecretName` and `appDatabaseRoleToken`.

`validateAppDatabase` refuses:

- an object whose database is not one of the app's `logicalDatabases`;
- `ReaderSchemaViews` on ClickHouse;
- a repeated reader or object;
- a non-positive limit.

The loader takes an optional `readers` array inside `access`, emitted only when non-empty.

**M3, members, grants and classification.**

- **Members.** `compileAppDatabase` emits, per reader, a credential member and a user member
  with the `reader-<r>` token. The user spec's extension (from EP-204) carries the objects,
  limits and consumers. Allow the token in `Nagare.Resource.Inventory`.
- **SQL.**
  - The create, access and password renderings take the reader role.
  - New renderings: `renderReaderAccess` (grants or revokes on objects, the settings or
    connection limit, and the role settings), and `renderObserveRelations`, which is M1's query.
- **Classification.**
  - Add `classifyReader`, which compares the reader's observed grants, settings and role
    settings with its declaration. It returns complete with a pending list, incomplete, or
    drift.
  - Teach `classifyDatabase` and `postgresGrant` to accept a declared reader's `CONNECT` and
    schema `USAGE`, and on ClickHouse its table-level `SELECT` on the app's databases. Leave
    judging those grants to the reader member. Any other grantee stays drift.
  - The two write-path refusals come from the relation observation, under their codes. Add
    them to `appDatabaseRefusal` in `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`, so
    the plan reports them by code.
- **Adapter.** `MemberKind` gains `ReaderMember`. `converge` creates the user, applies the
  access and verifies.
- **Pending report.** The plan summary prints pending objects. `AppDatabaseMember` exposes them
  through the member's observation summary.
- **World.** Extend the interpreter world with relations (tables, views, definer and invoker
  views), functions, and per-relation ACLs, all with M1's semantics.

**M4, credentials and binding.**

- **Rotation.** `rotate` accepts `--user reader:<r>`. `rotateAppDatabaseScope` already keys
  rotation on the role token.
- **Retirement.** `retire` gains `--reader R`, which disables only that reader's user spec.
- **Plan.** The `plan` runner refuses an enabled reader missing from the declaration.
- **Bindings.**
  - Add `appDatabaseReaders :: ![AppDatabaseReaderRef]` to the deployment record, loader and
    emitter, emitted only when non-empty.
  - In `Bindings.hs`, resolve each reference to `<appdb>-reader-<r>`. Refuse when the reader
    spec's consumers do not list the deploying app, when the reader is retired, or when the
    workload binds the same engine twice.
  - Change the retired check of `acceptedAppDatabaseBindings` to the runtime user's spec.

**M5, backup, restore and docs.**

- **Tests.**
  - A rebuilt restore after re-apply leaves every reader complete, on both engines.
  - A scratch restore leaves the reader unable to connect to, or read, the scratch databases.
  - The schedule's declaration digest changes when a reader is added. This is expected, because
    a restore must re-apply the readers.
- **Docs.** Document readers with the Kansoku example and the Grafana-over-PostgreSQL example.
- **Audit.** Register the changed `rotate` and `retire` options and any new subcommand.

**M6, native confirmation.** Extend the smoke after its AC-3 step:

1. Create a definer view and a parameterized view on `alpha-ch`, and a view on `alpha-pg`.
   Declare reader `dash` on each over those views, with consumer `gamma`.
2. Re-plan and apply, and assert the probes listed in Validation.
3. Deploy probe workload `gamma` binding both readers, and probe workload `delta` binding one
   without being a declared consumer. `delta` must be refused.
4. Rotate `alpha-pg`'s reader, then retire it.
5. Back up and restore into scratch.

**M7, release.** Follow `docs/runbooks/releases.md`: upgrade the intranet on the candidate,
then tag. Hand the tan-ng-labs plan the `dashboards` reader declaration. Record the resolution
and `targetPlan` in IR-33's frontmatter, and add a line to
`docs/improvement-requests/log.md`.


## Concrete Steps

M1, from the repository root, with Colima or Docker running:

```bash
docker run -d --name ep206-pg -e POSTGRES_USER=nagare -e POSTGRES_PASSWORD=pw postgres:18
docker run -d --name ep206-ch -e CLICKHOUSE_USER=nagare -e CLICKHOUSE_PASSWORD=pw \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 clickhouse/clickhouse-server:26.8
```

Replay the existing fixture blocks, then the reader blocks. Remove the containers with
`docker rm -f ep206-pg ep206-ch`.

For each Haskell commit:

```bash
cd cli/nagarectl
for p in AppDatabase Bindings; do cabal test nagarectl-test --test-options="-p $p"; done
cd ../.. && just haskell-style-check && just gate-fast HEAD
```

Land with `just land HEAD`.

M6, with the packaged CLI from an empty environment:

```bash
nix build --no-link --print-out-paths "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl"
NAGARE_SMOKE_CONTEXT=transition NAGARECTL=<out>/bin/nagarectl scripts/local-app-database-smoke.sh
```

The run should end with these two lines (the first is a new log line) and `PASS`:

```text
… app-database smoke: IR-33: readers read only their views under their limits; gamma bound both, delta refused; rotate and retire touched only the reader; scratch restore unreadable
app-database smoke: PASS
```


## Validation and Acceptance

- **AC-1.**
  - A plan test declares a reader with three ClickHouse views and a reader with a PostgreSQL
    schema's views. The operations name every object.
  - A loader test refuses an object in `beta`'s database.
- **AC-2.** In the world and in the smoke, the reader:
  - can `SELECT` each declared object;
  - is refused on the undeclared table in the same database, `INSERT`, `ALTER … UPDATE`,
    `DELETE`, DDL, temporary tables, `CREATE USER`, `system.parts`, and `beta`'s table.
- **AC-3.** On ClickHouse, a query over each ceiling is stopped. `SET` below a ceiling is
  accepted, and `SET` above it or to `0` is refused. `SET readonly = 0` is refused.
- **AC-4.** The reader reads a definer view, and is refused on its base table, on both engines.
- **AC-5.**
  - In the world, a reader declared before migrations plans and applies, reporting
    `pending: public.events_v`.
  - After the migration creates the view, the re-plan grants it, and the next plan prints
    `no operations`.
- **AC-6.**
  - Rotating `reader:dash` changes only `alpha-pg-reader-dash`'s Secret and the reader's
    password. Retiring it closes only its login.
  - A workload binding `appDatabases = ["alpha-pg"]` still references only `alpha-pg-runtime`.
- **AC-7.** `gamma`'s render references only `alpha-ch-reader-dash` and `alpha-pg-reader-dash`.
  `delta`'s plan refuses, naming the missing consumer declaration.
- **AC-8.**
  - After a rebuilt restore and re-plan, there are no operations, and the reader reads its
    views.
  - After a scratch restore, the reader's connection to `alpha_restore_<id>` fails on
    PostgreSQL, and its `SELECT` on `alpha_restore_<id>.v1` is refused on ClickHouse.
- **AC-9.**
  - Connection limit + 1 is refused.
  - After overriding the role defaults, all writes are refused.
  - With an executable migration-owned `SECURITY DEFINER` function in `public`, the plan
    refuses with `app-database-reader-definer-function`. After the app revokes `PUBLIC
    EXECUTE` on it, the plan passes.
  - A declared `security_invoker` view refuses with `app-database-reader-invoker-view`.


## Idempotence and Recovery

Every change is a reviewed plan. A reader's convergence is idempotent: the user is created only
when absent, the grants and settings statements converge, and an existing user is never
re-passworded except by rotation. That is the same contract as EP-202's users. A failed apply
resumes with `nagarectl inventory resume TX --yes`.

Retiring a reader keeps its Secret, so re-enabling it needs no new credential. The M1
containers and the M6 context are disposable.


## Interfaces and Dependencies

- **Prerequisite.** EP-204 M3 is landed: the user-spec extension and its codec, ClickHouse
  user settings, the PostgreSQL connection limit and role settings, and their classification.
- `Nagare.Dsl.AppDatabase` gains `ReaderName`, `AppDatabaseReader`, `ReaderObject`,
  `ReaderLimits` and `ReaderRole`. `AppDatabaseRole` loses `Enum` and `Bounded`.
- The deployment record in `Nagare.Dsl.Types` gains `appDatabaseReaders`.
- `Nagare.Database.AppDatabase.Catalog` gains `classifyReader` and relation observations.
  `classifyDatabase` takes the declared readers.
- `Nagare.Inventory.Adapters.AppDatabase.MemberKind` gains `ReaderMember`.
- `Nagare.Inventory.Application.Bindings` gains reader resolution, and changes its retired
  check.
- No new libraries.
