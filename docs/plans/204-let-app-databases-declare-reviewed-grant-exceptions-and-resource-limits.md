---
id: 204
slug: let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits
title: "Let app databases declare reviewed grant exceptions and resource limits"
kind: exec-plan
created_at: 2026-10-19T19:58:14Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-19T19:58:14Z
---

# Let app databases declare reviewed grant exceptions and resource limits

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This plan answers two improvement requests filed together from the Kansoku deployment
(`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`):

- [IR-30](../improvement-requests/declare-reviewed-app-database-privilege-exceptions.md): let an
  app database declare a small, Nagare-owned allow-list of extra privileges.
- [IR-32](../improvement-requests/per-app-database-resource-limits.md): let an app database
  declare per-user resource limits that the server enforces.

They are one plan because both add reviewed, per-user access beyond the fixed grant set that
EP-202 gives every app database. Both change the same four places: the declaration, the user
member's spec, the SQL the adapter sends, and the catalog classification that decides what is
drift. IR-33 (readers, [EP-206](206-give-app-databases-reviewed-read-only-consumer-users.md))
reuses the limit mechanism built here.

Kansoku is wedged on the intranet today, running v0.7.1:

- `kansoku-ch-migrate` cannot load its ledger, because `system.storage_policies` and
  `system.disks` are refused with code 497.
- `kansoku-server` cannot build its identity cache. It needs `system.parts` and session
  temporary tables with `ENGINE = Join`.
- `kansoku-pg` re-plans to `app-database-grant-drift`, because PGMQ's install grants
  `pg_monitor` read access on its schema.

After this plan:

- a `ClickHouse` app database can name, per user, any of `system.parts`, `system.mutations`,
  `system.disks`, `system.storage_policies` and arbitrary temporary tables. A name outside the
  list is refused when the config loads;
- a PostgreSQL app database can declare `pg_monitor`. Then the read-only grants that PGMQ's
  migration makes to it are not drift;
- each user can carry ceilings. ClickHouse has memory per query, execution time and concurrent
  queries. PostgreSQL has a connection limit and an optional role-level `statement_timeout`. An
  app can still lower a ClickHouse ceiling per query, but never raise it;
- a hand change to any of these is drift, and removing a ClickHouse declaration revokes it
  through review;
- an app database that declares none of this plans to `no operations` after the upgrade, with
  the same digests it had.


## Progress

- [ ] M1 (engine proof). The new statements and observations are proven by hand against
  `postgres:18` and `clickhouse/clickhouse-server:26.8`. They are committed as new
  `-- operation:` blocks in `cli/nagarectl/test/fixtures/app-database/clickhouse.sql` and
  `postgres.sql`, with captured observations under `observed/`. The fixture answers every
  question listed under M1 in Plan of Work, and the answers are in the Decision Log.
- [ ] M2 (declaration). `AppDatabase` gains an `access` field holding the closed allow-list and
  the limits. The config loader refuses an unknown exception, an exception on the wrong engine,
  and a non-positive limit, all before planning. A declaration without `access` emits
  byte-identical JSON. Tests: loader goldens and refusals in `AppDatabaseSpec`.
- [ ] M3 (inventory and adapter). The user and logical-database specs carry the declared
  extension, and their wire bytes are unchanged when it is empty. The adapter grants, sets and
  observes the extension. Undeclared extras stay drift. Removing a declared ClickHouse exception
  or limit plans a revocation. `AppDatabaseWorldSpec` covers converge, re-plan to no operations,
  resume after every fault, drift on a hand-added grant or setting, and revocation on removal,
  on both engines. A test decodes a v0.7.1 accepted app-database scope and re-encodes it
  byte-identically.
- [ ] M4 (lifecycle and docs). Rotation keeps the extension. Retirement turns it off with the
  other server grants. Scratch and rebuilt restores leave a declared app database complete on
  re-plan. `docs/user/managed-databases.md` documents the allow-list, the limits, what the
  ceilings mean, and why `system.processes` is not offered. `just haskell-style-check` and
  `just gate-fast` are green, and the change is landed.
- [ ] M5 (native confirmation). `scripts/local-app-database-smoke.sh` declares exceptions and
  limits on `alpha-ch` and `alpha-pg` and proves IR-30 AC-2 and AC-4, and IR-32 AC-1 to AC-4,
  on a disposable local context with the packaged CLI.
- [ ] M6 (release). The change ships in a release (it may share one with
  [EP-205](205-quiesce-one-app-database-and-back-it-up-on-demand.md)). The intranet is upgraded
  on the candidate before the tag. Kansoku's app databases then declare their exceptions in
  `mori://tan/tan-ng-labs`, re-plan, and `kansoku-ch-migrate` loads its ledger. IR-30 and IR-32
  are completed in `docs/improvement-requests/log.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: IR-30 and IR-32 are one plan. IR-31 and IR-33 are separate plans: 205 and 206.
  Rationale: IR-30 and IR-32 extend the same user member, through the same render, observe and
  classify path. IR-31 is a lifecycle operation that touches none of that. IR-33 adds a new kind
  of user and depends on the limits built here.
  Date: 2026-10-19

- Decision: The allow-list is a closed Haskell sum type in `Nagare.Dsl.AppDatabase`, not a list
  of SQL strings. The JSON loader maps fixed tokens onto it and refuses any other token.
  - ClickHouse tokens: `system-parts`, `system-mutations`, `system-disks`,
    `system-storage-policies`, `arbitrary-temporary-tables`.
  - PostgreSQL token: `pg_monitor`.
  Rationale: IR-30 asks for no arbitrary grants. A sum type makes "outside the allow-list"
  impossible to compile, and gives the loader one place to refuse.
  Date: 2026-10-19

- Decision: `system.processes` is not on the allow-list.
  Rationale: Kansoku stops needing it
  (`mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-2`). Limiting its rows to one
  app would need a row policy on a system table. That is a new kind of access entity, which
  Nagare would then also have to observe and classify. IR-30 AC-3 accepts omission with
  documentation.
  Date: 2026-10-19

- Decision: ClickHouse system-table exceptions are table-level `SELECT` on the four tables, not
  column-level grants.
  Rationale: `system.parts` and `system.mutations` already filter rows to the tables a user can
  `SHOW`, which M1 proves. Column lists change between engine versions, so column grants would
  turn an engine upgrade into drift.
  Date: 2026-10-19

- Decision: ClickHouse limits are user-level settings with `MAX` constraints, set by
  `ALTER USER <u> SETTINGS <s> = <v> MAX <v>, …`. They are not a Nagare-created settings profile
  or quota, and not `readonly`.
  Rationale: There is one statement per user, which replaces the user's whole settings list, so
  converging is idempotent. They are observed in `system.settings_profile_elements` by
  `user_name`. No extra named entity can collide between app databases. The default equals the
  ceiling, so an app that sets nothing gets the ceiling. An app can lower a setting per query
  (IR-32 AC-2), and undeclared settings stay writable.
  Date: 2026-10-19

- Decision: PostgreSQL `pg_monitor` is tolerated, not granted. When declared, grants to
  `pg_monitor` are not drift. The tolerated grants are USAGE on a schema the migration user
  owns, and SELECT in that user's default privileges on tables and sequences. Nagare never
  issues these grants itself, and never grants membership in `pg_monitor`. Removing the
  declaration makes them drift again, so the next plan refuses and names them.
  Rationale: PGMQ's migration makes the grants on the app's own objects. Nagare re-granting them
  would mean acting on objects it does not own. The app-database dump keeps object ACLs
  (`appDatabaseDumpShell`), so restores bring the grants back without Nagare.
  Date: 2026-10-19

- Decision: The extension rides inside the existing `DatabaseUserSpec` and `LogicalDatabase`
  constructors. Each gets a hand-written codec that writes and reads the v0.7 positional shape
  when the extension is empty. The declaration JSON and the spec digest objects likewise emit
  the new keys only when non-empty.
  Rationale: Accepted v0.7.1 history must still decode. An unchanged app database must keep its
  spec, digest, declaration digest and backup schedule revision. Otherwise every intranet app
  database would re-plan, and its earlier backup runs would be tied to an old revision. This is
  one explicit decoding rule for one reviewed release transition, not a second constructor or a
  compatibility layer.
  Date: 2026-10-19

- Decision: A ClickHouse exception or limit that the accepted spec declared, but the desired
  spec does not, is a declared revocation. The member is classified incomplete, so the plan
  revokes it. Anything that neither spec declared is still drift.
  Rationale: IR-30 AC-5 asks that removal revoke through review. ADR 30 forbids repairing
  access Nagare never granted. The adapter already receives the accepted members
  (`mkAppDatabaseAdapter accepted`).
  Date: 2026-10-19

- Decision: Nagare does not check the sum of declared PostgreSQL connection limits against the
  server's `max_connections`.
  Rationale: IR-32 asks only for the per-user part. The consuming deployment owns aggregate
  capacity. A check would also need `max_connections` to become a declared server setting,
  which is outside both requests.
  Date: 2026-10-19


## Outcomes & Retrospective

(None yet.)


## Context and Orientation

Nagare is a single-node PaaS. Operators drive it with `nagarectl`, a Haskell CLI under
`cli/nagarectl/`. Its declaration types live in the `nagare-dsl` package under `cli/nagare-dsl/`.
Every change is a saved, reviewed plan that `nagarectl inventory apply DIR --yes` executes.

**App databases** came with EP-202
([plan](202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md),
[ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md)). An app database
is a tenant of a shared PostgreSQL or ClickHouse server. It is its own inventory scope,
`appdb-<key>`, with these members:

- two credential Secrets, `<name>-runtime` and `<name>-migration`;
- two users, `<name_with_underscores>_runtime` and `_migration`;
- one logical-database member per database;
- a signed backup schedule, `nagare-appdb-<name>`.

ADR 30 states the rule this plan extends: "The declaration is the authority for users and
grants … access Nagare never grants is refused as drift, not revoked."

Where each part lives today:

- **Declaration.** `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs` defines the record
  `AppDatabase` (name, logicalKey, server, engine, namespace, logicalDatabases) and
  `validateAppDatabase`. The fixed grants are functions of engine and role:
  - `appDatabaseAttributes`;
  - `appDatabaseServerGrants`, where only the ClickHouse migration user has `WRITE ON FILE`;
  - `appDatabaseDatabaseGrants`.

  The config program emits JSON through `appDatabaseJSON` in
  `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`. `cli/nagare-dsl/src/Nagare/Dsl/Load/AppDatabase.hs`
  decodes it (`JsonAppDatabase`, `toAppDatabase`).
- **Members.** `compileAppDatabase` in `cli/nagare-dsl/src/Nagare/Resource/AppDatabase.hs`
  builds each user as `DatabaseUserSpec engine role enabled digest` and each database as
  `LogicalDatabase engine migration runtime enabled digest`. Both constructors are in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`. The digest covers a JSON object of
  the user's attributes and server grants, or of the database's grant lists. The specs are
  encoded with `genericToJSON options` in `cli/nagare-dsl/src/Nagare/Resource/Wire.hs`, as
  positional `contents`. Spec validity, including the allowed role tokens, is checked in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` near line 215.
- **Backup schedule digest.** `compileStandaloneAppDatabase` in
  `cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs` puts
  `contentDigest (encodeAppDatabases [db])` into the backup receipt metadata as `declaration`.
  So any change to the emitted declaration JSON changes the schedule revision.
- **SQL.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs` renders each member-level
  command:
  - `renderCreateUser`;
  - `renderUserAccess`, for login and server grants;
  - `renderDatabaseAccess`.

  It also renders the observation queries: `renderObserveServer` and `renderObserveDatabase`
  for PostgreSQL, and `renderObserveClickHouse` as tagged JSONEachRow rows.
- **Classification.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs` parses the
  observations into `Catalog`. `classifyUser` and `classifyDatabase` then return a
  `MemberState`: absent, complete, incomplete (fixable by the declared statements) or drift
  (refused with `app-database-grant-drift`). Two rules matter here:
  - ClickHouse table-level grants, and grants on any database not the app's own, including
    `system`, are anomalies, which means drift.
  - A PostgreSQL grant to anyone other than the two users, `PUBLIC` or `pg_database_owner` is
    drift (`postgresGrant`).

  PostgreSQL observation reads database, schema and default ACLs only, not per-table ACLs. So
  PGMQ's `GRANT USAGE ON SCHEMA pgmq TO pg_monitor` and its `ALTER DEFAULT PRIVILEGES … TO
  pg_monitor` are the rows that wedge `kansoku-pg`. Its `GRANT SELECT ON ALL TABLES …` is not
  observed.
- **Adapter.** `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs` defines:
  - `AppDatabaseMember`, which the adapter resolves from declarations;
  - `CatalogCommand`, the commands `CreateUser`, `SetUserAccess`, `CreateDatabase`,
    `SetDatabaseAccess` and `SetPassword`;
  - `AppDatabaseOps`, the transport boundary;
  - `mkAppDatabaseAdapter accepted members ops`.

  The kubectl transport is `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabaseRuntime.hs`.
  It runs SQL as the server administrator inside the server pod, after checking the recorded
  incarnations
  ([ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)).
- **Tests.**
  - `cli/nagarectl/test/AppDatabaseSqlSpec.hs` pins every rendering byte for byte to a
    `-- operation:` block of the fixtures. It also classifies the captured catalogs in
    `cli/nagarectl/test/fixtures/app-database/observed/`.
  - `cli/nagarectl/test/AppDatabaseSpec.hs` covers compile, validation and schedules.
  - `cli/nagarectl/test/AppDatabaseWorldSpec.hs` runs the adapter against the interpreter
    world in `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs`, with an adversary that
    refuses statements, loses acknowledgements and kills the executor.
- **Native smoke.** `scripts/local-app-database-smoke.sh` (`just local-app-database-smoke
  CONTEXT`) runs four app databases on two local servers and asserts EP-202's acceptance
  criteria.
- **User docs.** The "Sharing one server between apps" section of
  `docs/user/managed-databases.md`.

Relevant ADRs:

- [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md): the tenant
  model and the drift rule summarised above.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
  defects are found by the interpreter world and fixtures, and the native smoke only confirms.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
  the transport checks the server's recorded identity before every call.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): an app
  database is an independent scope; this plan adds nothing outside it.

Terms:

- **Exception**: an allow-listed privilege beyond the fixed grant set.
- **Limit** or **ceiling**: a server-enforced maximum on one user.
- **Extension**: the exceptions plus the limits of one user, or the tolerated monitoring roles
  of one logical database.


## Plan of Work

**M1, engine proof.** Prove every new statement and observation by hand before writing Haskell,
as EP-202 M1 did. Use `postgres:18` and `clickhouse/clickhouse-server:26.8` containers with the
server render's environment: admin `nagare`, `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1`. Set up
users `alpha_*` and `beta_*` as in the existing fixtures. Answer each question below and append
the blocks to the fixtures.

ClickHouse questions:

- **System-table grants.** Do `GRANT SELECT ON system.parts`, `system.mutations`,
  `system.disks` and `system.storage_policies` let `alpha_runtime` read them? Does
  `system.parts` then show no rows of `beta`'s tables, and `system.mutations` none of `beta`'s
  mutations?
- **Temporary tables.** Does `GRANT CREATE ARBITRARY TEMPORARY TABLE ON *.*` allow
  `CREATE TEMPORARY TABLE t (k UInt64) ENGINE = Join(ANY, LEFT, k)`? Is a temporary table with
  `ENGINE = File(...)`, `URL(...)` or `S3(...)` still refused?
- **Exact rows.** What exact rows does `system.grants` report for each of these grants? Record
  any implied privilege rows: the classification must match them exactly.
- **Ceilings.** Does `ALTER USER alpha_runtime SETTINGS max_memory_usage = 1073741824 MAX
  1073741824, max_execution_time = 60 MAX 60, max_concurrent_queries_for_user = 4 MAX 4` give
  each ceiling as the default? Is `SET max_memory_usage = 536870912` accepted and
  `SET max_memory_usage = 2147483648` refused?
- **Zero.** Is `SET max_memory_usage = 0` refused? Zero means unlimited, so it must be refused.
  If it is not, add `MIN 1` and record that in the Decision Log. Ask the same for
  `max_execution_time = 0`.
- **Enforcement.** Is a query over each ceiling stopped (memory, time, a fifth concurrent
  query) while `beta_runtime` runs the same query unaffected?
- **Undeclared settings.** Can `enable_analyzer`, `async_insert` and `mutations_sync` still be
  set?
- **Observation.** What does `system.settings_profile_elements` return for the user? Does
  `ALTER USER … SETTINGS NONE` clear it?

PostgreSQL questions:

- **Connection limit.** After `ALTER ROLE "alpha_runtime" CONNECTION LIMIT 2`, is a third
  connection refused with `too many connections for role`? Is the limit observed in
  `pg_roles.rolconnlimit`?
- **Statement timeout.** After `ALTER ROLE "alpha_runtime" SET statement_timeout = '30s'`, is
  the setting observed in `pg_db_role_setting` (`setdatabase = 0`)? Does `RESET` clear it?
- **PGMQ rows.** Run PGMQ's `0001-install-v1.11.0.sql` grants as `alpha_migration` (the five
  statements quoted in IR-30). What rows do `renderObserveServer` and `renderObserveDatabase`
  report for `pg_monitor`?

**M2, declaration.** In `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`:

- Add `AppDatabaseAccess { runtime :: !UserAccess, migration :: !UserAccess, monitoring ::
  ![MonitoringRole] }`.
- Add `UserAccess { exceptions :: ![GrantException], limits :: !UserLimits }`.
- Add `GrantException`, the five ClickHouse constructors, and `MonitoringRole = PgMonitor`.
- Add `UserLimits`. Its fields are `Maybe`: `maxMemoryBytes`, `maxExecutionSeconds` and
  `maxConcurrentQueries` for ClickHouse, and `connectionLimit` and `statementTimeoutSeconds` for
  PostgreSQL.
- Export an empty value, `noAppDatabaseAccess`.

`validateAppDatabase` refuses:

- ClickHouse exceptions or limits on a PostgreSQL app database, and the reverse;
- `monitoring` on ClickHouse;
- a repeated exception;
- a limit that is not positive.

Extend `appDatabaseJSON` and the loader with an optional `access` object. It is emitted only
when not empty, so declarations without it keep their bytes, their `declaration` digest, and
the schedule revision.

**M3, inventory and adapter.**

- **Specs.** Add the user's extension to `DatabaseUserSpec` and the monitoring roles to
  `LogicalDatabase`, as plain data (tokens and integers), not as a digest.
  - Write their codec by hand in `cli/nagare-dsl/src/Nagare/Resource/Wire.hs`, so that empty
    extensions emit the v0.7 positional contents and legacy contents decode as empty.
  - Validate the tokens in `Nagare.Resource.Inventory`.
  - In `compileAppDatabase`, add `exceptions`, `limits` or `monitoring` keys to the digest
    objects only when they are non-empty.
- **SQL** (`Sql.hs`).
  - `renderUserAccess` adds the exception grants or revocations, the `ALTER USER … SETTINGS`
    statement (or `SETTINGS NONE`), and, for PostgreSQL, `CONNECTION LIMIT` and `SET` or
    `RESET statement_timeout`. Each must be pinned to an M1 block.
  - `renderObserveClickHouse` gains a `setting` row from `system.settings_profile_elements`,
    and keeps table-level grants as structured rows.
  - `renderObserveServer` gains `rolconnlimit` and the role's `pg_db_role_setting` entries.
- **Classification** (`Catalog.hs`).
  - `CatalogUser` gains observed settings, a connection limit and role settings.
  - ClickHouse `SELECT` on a declared `system.<table>` is a server grant, not an anomaly.
  - `classifyUser` compares the user's server grants and settings against fixed grants plus the
    declared extension, with the accepted extension as the revocable set (see the Decision
    Log).
  - `postgresGrant` accepts declared monitoring roles for exactly the read-only privileges in
    the Decision Log.
  - Any settings profile inherited by an app user, or any role setting other than
    `statement_timeout`, is drift.
- **Adapter.** `AppDatabaseMember` carries the desired and accepted extensions.
  `SetUserAccess` carries the extension, so `converge` sends one statement set per member.
- **World.** Extend `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs` to interpret the new
  statements with M1's semantics. Add an adversary fault that hand-adds an undeclared setting
  and one that hand-adds an undeclared grant on `system.parts`.

**M4, lifecycle and docs.**

- **Rotation.** `rotateAppDatabaseScope` is unchanged; a test confirms the extension survives
  it.
- **Retirement.** `retireAppDatabaseScope` already turns user specs off; the disabled path of
  `renderUserAccess` now also revokes the exceptions. Limits stay set, because a user that
  cannot log in is not limited by them. `classifyUser` must accept that state for a disabled
  user.
- **Restore.** ClickHouse exceptions are server-wide, not per database, so scratch restore
  needs nothing new. A test asserts that a re-plan after a rebuilt restore is `no operations`
  for an app database with PGMQ grants in its dump.
- **Docs.** Write the docs section, with a worked Kansoku-shaped example.

**M5, native confirmation.** Extend the smoke after its AC-3 step:

- declare `system-parts`, `system-storage-policies` and `arbitrary-temporary-tables`, plus all
  three ClickHouse ceilings, on `alpha-ch`;
- declare a connection limit of 3 and `pg_monitor` on `alpha-pg`;
- re-plan, apply, and assert the probes listed in Validation;
- remove one exception, and assert the plan revokes it.

Run the smoke from an empty environment with the packaged CLI.

**M6, release.** Follow `docs/runbooks/releases.md`: upgrade the intranet on the candidate,
then tag. Coordinate the Kansoku declarations with the tan-ng-labs plan. Record the resolution
and `targetPlan` in each IR's frontmatter and add a line to `docs/improvement-requests/log.md`.


## Concrete Steps

M1, from the repository root, with Colima or Docker running. Use the same setup as EP-202 M1:

```bash
docker run -d --name ep204-pg -e POSTGRES_USER=nagare -e POSTGRES_PASSWORD=pw postgres:18
docker run -d --name ep204-ch -e CLICKHOUSE_USER=nagare -e CLICKHOUSE_PASSWORD=pw \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 clickhouse/clickhouse-server:26.8
```

Replay the existing fixture blocks, then each new block, with the `awk` split on
`-- operation:` described in the fixture headers. Capture observations with the rendered
observation queries into `cli/nagarectl/test/fixtures/app-database/observed/`. Remove the
containers afterwards with `docker rm -f ep204-pg ep204-ch`.

For each Haskell commit:

```bash
cd cli/nagarectl
for p in AppDatabase; do cabal test nagarectl-test --test-options="-p $p"; done
cd ../.. && just haskell-style-check && just gate-fast HEAD
```

Land with `just land HEAD`.

M5, from an empty environment against a `mode=local` context, with the packaged CLI built from
the landed revision:

```bash
nix build --no-link --print-out-paths "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl"
NAGARE_SMOKE_CONTEXT=transition NAGARECTL=<out>/bin/nagarectl scripts/local-app-database-smoke.sh
```

The run should end with these two lines (the first is a new log line) and `PASS`:

```text
… app-database smoke: EP-204: alpha-ch exceptions and ceilings hold, beta unaffected; alpha-pg connection limit and pg_monitor grants hold; removal revoked
app-database smoke: PASS
```


## Validation and Acceptance

**IR-30.**

- **AC-1.**
  - A loader test refuses `"exceptions": ["system-query-log"]` with a message that names the
    token.
  - A plan test shows the user member's update and names each exception.
- **AC-2.**
  - The fixture and the smoke both show `alpha_runtime` reading the four system tables, and
    creating a `Join` temporary table.
  - Its `system.parts` has no `beta` rows.
  - `CREATE TEMPORARY TABLE x (s String) ENGINE = URL('http://example.invalid/', CSV)` is
    refused with code 497.
- **AC-3.** The docs state that `system.processes` is not offered, and why.
- **AC-4.**
  - The world test runs the PGMQ grants and declares `pg_monitor`; the re-plan is
    `no operations`, and rotate and retire still plan.
  - The same world without the declaration refuses with `app-database-grant-drift … pg_monitor`.
- **AC-5.**
  - World tests rotate, retire and rebuilt-restore with exceptions declared.
  - Removing `system-disks` plans an update whose execution revokes it, and the next plan has no
    operations.

**IR-32.**

- **AC-1.** The smoke runs a query that exceeds each ClickHouse ceiling as `alpha_runtime`:
  - `SELECT count() FROM numbers(1e10) SETTINGS max_threads = 1` stops at the time ceiling;
  - a `groupArray` over `numbers(1e9)` stops at the memory ceiling;
  - the query over the concurrency limit is refused.

  The same queries as `beta_runtime` are not stopped by `alpha`'s ceilings.
- **AC-2.** As `alpha_runtime`:
  - `SET max_memory_usage` below the ceiling is accepted;
  - above it, and to `0`, is refused;
  - `SET enable_analyzer = 0` is accepted.
- **AC-3.** As `alpha_pg_runtime`, opening connection 4 when the limit is 3 fails with
  `too many connections for role`.
- **AC-4.**
  - In the world, a hand-applied `ALTER USER … SETTINGS max_memory_usage = 0` and a hand
    `ALTER ROLE … CONNECTION LIMIT -1` each make the re-plan refuse with drift.
  - Changing the declared ceiling plans an update.

**Transition.** A test loads the accepted `appdb-*` scope bytes that the v0.7.1 smoke produced,
decodes and re-encodes them byte-identically, and re-plans the unchanged declaration to
`no operations`. If the test needs captured bytes, record them as a fixture, from
`nagarectl inventory show` on the M5 context before the upgrade.


## Idempotence and Recovery

Every change is a reviewed plan. Re-planning an unchanged declaration prints `no operations`.
The ClickHouse settings statement replaces the user's whole settings list, and the grant and
revoke statements are idempotent, so a lost acknowledgement retries safely. The world tests
prove this.

A failed apply resumes with `nagarectl inventory resume TX --yes`. The M1 containers are
disposable. The M5 context is a disposable local context.


## Interfaces and Dependencies

These types and functions change:

- `Nagare.Dsl.AppDatabase` gains `AppDatabaseAccess`, `UserAccess`, `GrantException`,
  `MonitoringRole`, `UserLimits` and `noAppDatabaseAccess`, and `AppDatabase` gains
  `access :: !AppDatabaseAccess`. Every construction of `AppDatabase`, in tests and in config
  programs, sets it.
- `DatabaseUserSpec` and `LogicalDatabase` in `Nagare.Resource.Inventory.Types` gain the
  extension. Every pattern match on them must be updated. They are matched in:
  - `Nagare.Inventory.AppDatabase`;
  - `Nagare.Inventory.Application.Bindings`;
  - `Nagare.Inventory.Adapters.AppDatabase`;
  - `Nagare.Resource.Inventory`.
- `CatalogUser` and the `SetUserAccess` command change shape.

No new libraries. EP-206 depends on the ClickHouse user-settings mechanism, and on the
`CatalogUser` settings observation, from M3.
