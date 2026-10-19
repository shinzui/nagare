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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-19T22:23:36Z
      mode: "implement"
      note: "M1-M3 implemented: engine proof, declaration, specs, SQL, catalog, adapter and world"
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
- each user can carry limits. ClickHouse has ceilings on memory per query, execution time and
  concurrent queries, which the server enforces: an app can lower one per query, but can
  neither raise it nor set it to zero. PostgreSQL has a connection limit, which the server
  enforces, and an optional role-level `statement_timeout`, which is a session default an app
  can override, not a ceiling;
- a hand change to any of these is refused as drift, and a hand removal is restored by the next
  plan. Removing a ClickHouse exception or any limit from the declaration revokes or resets it
  through review. Removing `pg_monitor` makes its grants drift again;
- an app database that declares none of this plans to `no operations` after the upgrade, with
  the same digests it had.


## Progress

- [x] M1 (engine proof). The new statements and observations are proven by hand against
  `postgres:18` and `clickhouse/clickhouse-server:26.8`. They are committed as new
  `-- operation:` blocks in `cli/nagarectl/test/fixtures/app-database/clickhouse.sql` and
  `postgres.sql`, with captured observations under `observed/`. The fixture answers every
  question listed under M1 in Plan of Work, and the answers are in the Decision Log.
  Done 2026-10-19 on 26.8.29.10 and 18: every fixture block was then replayed on fresh
  containers without error. Captures: `observed/clickhouse-access.jsonl`,
  `clickhouse-access-drifted.jsonl`, `postgres-server-access.json`,
  `postgres-database-pgmq.json`. Committed in 856c64ee.
- [x] M2 (declaration). `AppDatabase` gains an `access` field holding the closed allow-list and
  the limits. The config loader refuses an unknown exception, an exception on the wrong engine,
  and a non-positive limit, all before planning. A declaration without `access` emits
  byte-identical JSON. Tests: loader goldens and refusals in `AppDatabaseSpec`.
  Done 2026-10-19 in bc548f6e; `just gate-fast` green
  (`~/.local/state/nagare/gates/fast/bc548f6ef9e13e38989b7535e4fc9ebfde24eb42.json`).
- [x] M3 (inventory and adapter). The user and logical-database specs carry the declared
  extension, and their wire bytes are unchanged when it is empty. The adapter grants, sets and
  observes the extension, and the planned operation's summary names each exception and limit.
  Undeclared extras stay drift. A hand-changed value is drift; a hand-removed exception or
  limit is restored by the next plan. Removing a declared ClickHouse exception or any limit
  plans a revocation or reset. `AppDatabaseWorldSpec` covers converge, re-plan to no
  operations, resume after every fault, drift on a hand-added grant or setting, restoration
  after a hand removal, and revocation on removal from the declaration, on both engines. A
  test decodes a v0.7.1 accepted app-database scope and re-encodes it byte-identically.
  Implemented 2026-10-19 in 856c64ee: every EP-202 world test also runs with declared access
  (all fault placements), plus the EP-204 cases; the v0.7.1 records are
  `fixtures/app-database/v0.7.1/`; the two EP-202 mutation records were regenerated and each
  fails `/AppDatabase world/`. `just gate-fast` green
  (`~/.local/state/nagare/gates/fast/856c64ee043481eb747e0357e0e0e86423bd0503.json`). In
  4db79c8f, the two app-database scopes that the v0.7.1 smoke's review accepted on the local
  context `transition` (`v0.7.1/native-appdb-*.json`) also decode and re-encode
  byte-identically.
- [x] M4 (lifecycle and docs). Rotation keeps the extension. Retirement revokes the exceptions
  with the other server grants; limits follow the declaration whether or not the user can log
  in. Scratch and rebuilt restores leave a declared app database complete on re-plan.
  `docs/user/managed-databases.md` documents the allow-list, the limits, which of them are
  ceilings and which are defaults, that the migration user's ceilings bound its scheduled
  backup, and why `system.processes` is not offered. `just haskell-style-check` and
  `just gate-fast` are green, and the change is landed.
  Done 2026-10-19:
  - The EP-202 world tests now also run with declared access. Covered: rotation, which leaves
    every field but the password unchanged; retirement, which revokes the exceptions and keeps
    the limits; and a rebuilt re-apply.
  - A PostgreSQL case covers PGMQ's pg_monitor grants through rotation, retirement and a
    rebuild whose restore brings them back.
  - A scratch restore beside declared access classifies complete.
  - Docs are in 17ac2bf4.
  - The tip 4db79c8f passed `just gate-fast`
    (`~/.local/state/nagare/gates/fast/4db79c8f8bc6e2481b17fdedd67c9e01789da718.json`) and was
    landed with `just land`.
- [x] M5 (native confirmation). `scripts/local-app-database-smoke.sh` declares exceptions and
  limits on both users of `alpha-ch` and on `alpha-pg` and proves IR-30 AC-2, AC-4 and AC-5,
  and IR-32 AC-1 to AC-4, on a disposable local context with the packaged CLI. The smoke's
  rotation, retirement, backup and restore steps then run with the exceptions declared.
  Done 2026-10-19 with the packaged CLI from 4b5739fd, from an empty environment, on a fresh
  disposable context `transition`. The context was rebuilt 0.7.0 → 0.7.1 with
  `scripts/transition-rehearsal.sh`, then the v0.7.1 smoke ran on it with the v0.7.1 CLI.
  - The new CLI's first plan over those v0.7.1 app databases only re-enabled `beta-ch`, which
    the v0.7.1 smoke had retired. Re-planning then printed `no operations`.
  - The EP-204 line printed, then rotation, retirement, backup with restore, and the prune
    review ran with the access declared, and the run ended in `app-database smoke: PASS`.
  - The saved review names `exceptions system-parts, system-storage-policies,
    arbitrary-temporary-tables; limits maxMemoryBytes 268435456, maxExecutionSeconds 5,
    maxConcurrentQueries 2`.
  - Earlier runs found two defects, fixed and landed: fb3dcbf0 makes a plan refusal print the
    drift reason, and 4b5739fd keeps the backup schedule revision when access changes (both in
    the Decision Log).
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

- Decision: ClickHouse limits are user-level settings with `MIN 1` and `MAX` constraints, set
  by `ALTER USER <u> SETTINGS <s> = <v> MIN 1 MAX <v>, …`, or `SETTINGS NONE` when none is
  declared. They are not a Nagare-created settings profile or quota, and not `readonly`.
  Rationale: There is one statement per user, which replaces the user's whole settings list, so
  converging is idempotent. They are observed in `system.settings_profile_elements` by
  `user_name`. No extra named entity can collide between app databases. The default equals the
  ceiling, so an app that sets nothing gets the ceiling. An app can lower a setting per query
  (IR-32 AC-2), and undeclared settings stay writable. A constraint only compares against its
  own bounds, so with `MAX` alone `SET max_memory_usage = 0` is accepted, and zero means
  unlimited for all three settings. `MIN 1` closes that, and M1 confirms it.
  Date: 2026-10-19

- Decision: The PostgreSQL `statement_timeout` is kept as an optional role-level default, set
  with `ALTER ROLE … SET`, and the docs call it a default, not a ceiling. The connection limit
  is the only PostgreSQL ceiling.
  Rationale: `statement_timeout` is a session setting any role may `SET`, including to `0`, so
  PostgreSQL cannot make it a ceiling. IR-32 lists it as optional. EP-206 reuses the role
  setting observation built here and calls its own role settings advisory defaults. `pg_dump`
  sets `statement_timeout = 0` in its own session, so the scheduled backup is not affected.
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

- Decision: Each observed item of a user's extension is classified by one rule. An item equal
  to the desired declaration is complete. An item equal to the accepted declaration but not the
  desired one is incomplete, and the update revokes or resets it. Any other item is drift. A
  desired item that is absent is incomplete, and the update restores it. The items are: each
  allow-listed exception (held or not), each ClickHouse user setting (name, value, min, max,
  writability), any inherited settings profile (always drift), the PostgreSQL connection limit
  (`-1` when none is declared), and the role's `statement_timeout` (any other role setting is
  drift). The accepted declaration is read from the accepted user spec, which
  `mkAppDatabaseAdapter accepted` already receives.
  Rationale: IR-30 AC-5 asks that removal revoke through review, and IR-32 AC-4 that a hand
  change be reported. ADR 30 forbids repairing access Nagare never granted, which is why a
  value neither declaration names refuses rather than converges. A hand removal is the same
  case as a hand-revoked grant today: the declared state is restored.
  Date: 2026-10-19

- Decision: The renderings depend only on the desired extension, never on the accepted one.
  The ClickHouse user-access statements grant each declared exception and revoke every other
  allow-listed exception, then send the one settings statement. The PostgreSQL statements
  always send `CONNECTION LIMIT` (`-1` when none is declared) and `SET` or `RESET
  statement_timeout`. `SetUserAccess` therefore carries the desired extension only.
  Rationale: Every statement is idempotent and complete on its own, so a retry after a lost
  acknowledgement needs no history, and the fixture can pin one rendering per declaration.
  Revoking a grant the user does not hold is a no-op, which the existing retirement path
  already relies on and M1 confirms.
  Date: 2026-10-19

- Decision: Retirement revokes the exceptions, as it revokes the other server grants. Limits
  follow the declaration whether or not the user can log in, so the disabled rendering sends
  the same settings, connection-limit and role-setting statements as the enabled one.
  Rationale: One rule for limits, no second classification branch, and a user re-enabled after
  retirement is limited from its first query.
  Date: 2026-10-19

- Decision: The migration user's ceilings apply to the scheduled backup it runs. On ClickHouse
  the backup is one `BACKUP DATABASE … TO File(…)` query as the migration user, so a declared
  execution-time or memory ceiling on that user bounds it, and the concurrency ceiling counts
  it. Nagare does not exempt the backup. The docs say so, and M1 confirms which ceilings
  `BACKUP` is subject to. On PostgreSQL the connection limit must leave one connection for
  `pg_dump`, and `pg_dump` resets `statement_timeout` itself.
  Rationale: An exemption would need a second credential or a server-side setting per backup,
  and the operator who declares the ceiling owns the app's backup size.
  Date: 2026-10-19

- Decision: The specs carry the typed `UserAccess` and `[MonitoringRole]` from
  `Nagare.Dsl.AppDatabase`, not tokens checked in `Nagare.Resource.Inventory`. Decoding a spec
  refuses an unknown token, and spec validity checks only that the access fits the engine.
  Rationale: `Nagare.Dsl.AppDatabase` imports no inventory module, so there is no cycle. One
  JSON encoding then serves the declaration, the spec and the digests, and the adapter never
  re-parses tokens.
  Date: 2026-10-19

- Decision: `AppDatabase` gains a strict `access` field, so a config program must set it
  (`access = noAppDatabaseAccess` for none). The tan-ng-labs `isolation-probe` and `kansoku`
  configs change with the M6 upgrade.
  Rationale: one reviewed record shape, no defaulting constructor; the field's JSON is omitted
  when empty, so the change reaches only the Haskell source of a config.
  Date: 2026-10-19

- Decision (M1): the time probe never finishes on its own, so `beta`'s comparison runs it with
  its own per-query `max_execution_time = 7`. It stops at 7 s, not at `alpha`'s 5 s. The
  memory probe stopped `alpha` at "would use 384.62 MiB" (code 241), and `beta` finished it
  with a 512.14 MiB peak. The smoke uses the same probes.
  Date: 2026-10-19

- Decision (M1): a migration user's ceilings bound its `BACKUP` as follows:
  - `max_execution_time` stops it, though late: with a 1 s ceiling, a 3.8 GiB backup failed with
    code 159 after 22 s;
  - `max_concurrent_queries_for_user` counts it (code 202 with two queries running);
  - `max_memory_usage` does not bound it: its tracked memory stayed near 5 MiB, and it finished
    under a 256 MiB ceiling.

  The docs therefore say that the execution-time ceiling must exceed the backup's duration and
  the concurrency ceiling must leave it a slot. `pg_dump` completed under `CONNECTION LIMIT 1`
  and a 1 ms role `statement_timeout`.
  Date: 2026-10-19

- Decision: the v0.7.1 transition records were captured from the v0.7.1 compiler with
  `encodeCanonicalScope`: at 25a41216, `cli/` is identical to `v0.7.1`. They were not exported
  from a live context. Accepted history stores exactly these bytes
  (`Nagare.Inventory.Plan.History`), and the revision digest is their content digest.
  Date: 2026-10-19

- Decision: the world tests apply hand changes to the world directly, as EP-202's drift test
  does. They do not add adversary faults.
  Rationale: the adversary models transport faults (a refusal, a lost acknowledgement, an
  interrupt); a hand change is a state of the server.
  Date: 2026-10-19

- Decision (M5): the backup schedule's declaration digest leaves `access` out, so declaring or
  changing access keeps the schedule revision. Earlier the plan said that adding access moves
  the revision, as any declaration change does.
  Rationale: the native smoke found that a prune refuses every run accepted under an earlier
  schedule revision ("admitted under an older source or schedule"). With access in the
  digest, Kansoku could never prune the runs taken before it declared its exceptions. Access
  changes no byte a backup holds. That any other declaration change (a new logical database)
  makes earlier runs unprunable is EP-203 behaviour and outside this plan; it is reported to
  the operator.
  Date: 2026-10-19

- Decision (M5): a plan refusal prints an app-database member's drift and credential reasons,
  as it prints access observations. Other providers' reasons stay redacted.
  Rationale: the native smoke found that the refusal named only the member id, so IR-30
  AC-4's "report app-database-grant-drift" was not observable to an operator. A world test now
  requires the code and the grant in the rendered refusal.
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
- **Limit**: a declared per-user value the server applies. A **ceiling** is a limit the app
  cannot exceed: the three ClickHouse settings and the PostgreSQL connection limit. The
  PostgreSQL `statement_timeout` is a role default, not a ceiling.
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
- **Ceilings.** Does `ALTER USER alpha_runtime SETTINGS max_memory_usage = 268435456 MIN 1 MAX
  268435456, max_execution_time = 5 MIN 1 MAX 5, max_concurrent_queries_for_user = 2 MIN 1 MAX
  2` give each ceiling as the default? Is `SET max_memory_usage = 134217728` accepted and
  `SET max_memory_usage = 536870912` refused?
- **Zero.** Is `SET max_memory_usage = 0`, `max_execution_time = 0` and
  `max_concurrent_queries_for_user = 0` each refused under `MIN 1`? Record the exact error.
- **Enforcement.** Is a query over each ceiling stopped while `beta_runtime` runs the same
  query unaffected? The probes must not be optimised away and must fit under the server's
  1.5 GiB `max_server_memory_usage` for `beta`:
  - time: `SELECT sum(cityHash64(number)) FROM numbers(100000000000) SETTINGS max_threads = 1`.
    A `count()` over `numbers(N)` is answered without reading rows, so it is not a probe;
  - memory: `SELECT length(groupArray(number)) FROM numbers(30000000)`, which needs more than
    256 MiB and well under 1.5 GiB. Record `beta`'s peak from `system.query_log`;
  - concurrency: three `SELECT sleep(3)` at once; the third is refused.
- **Undeclared settings.** Can `enable_analyzer`, `async_insert` and `mutations_sync` still be
  set?
- **Observation.** What does `system.settings_profile_elements` return for the user? Does
  `ALTER USER … SETTINGS NONE` clear it? Does a second `ALTER USER … SETTINGS` replace, not
  add to, the list?
- **Revoke of an absent grant.** Does `REVOKE SELECT ON system.disks FROM alpha_runtime`
  succeed when the grant is not held? The renderings revoke every undeclared allow-listed
  exception on each converge.
- **Backup under ceilings.** With the ceilings on `alpha_migration`, is
  `BACKUP DATABASE alpha TO File('m1.zip')` subject to `max_execution_time` and
  `max_memory_usage`? Record which apply.

PostgreSQL questions:

- **Connection limit.** After `ALTER ROLE "alpha_runtime" CONNECTION LIMIT 2`, is a third
  connection refused with `too many connections for role`? Is the limit observed in
  `pg_roles.rolconnlimit`?
- **Statement timeout.** After `ALTER ROLE "alpha_runtime" SET statement_timeout = '30s'`, is
  the setting observed in `pg_db_role_setting` (`setdatabase = 0`), and in which text form?
  Does `RESET` clear it? Is `SET statement_timeout = 0` in a session still accepted, which is
  why the docs call it a default?
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
the schedule revision. The backup schedule's declaration digest leaves `access` out, so
declaring or changing access keeps the schedule revision too (see the Decision Log).

**M3, inventory and adapter.**

- **Specs.** Add the user's extension to `DatabaseUserSpec` and the monitoring roles to
  `LogicalDatabase`, as plain data (tokens and integers), not as a digest.
  - Write their codec by hand in `cli/nagare-dsl/src/Nagare/Resource/Wire.hs`, so that empty
    extensions emit the v0.7 positional contents and legacy contents decode as empty.
  - Validate the tokens in `Nagare.Resource.Inventory`.
  - In `compileAppDatabase`, add `exceptions`, `limits` or `monitoring` keys to the digest
    objects only when they are non-empty.
- **SQL** (`Sql.hs`).
  - `renderUserAccess` takes the desired extension. On ClickHouse it grants each declared
    exception, revokes every other allow-listed exception, and sends one
    `ALTER USER … SETTINGS … MIN 1 MAX …` statement, or `SETTINGS NONE`. On PostgreSQL it
    always sends `CONNECTION LIMIT` (`-1` when none) and `SET` or `RESET statement_timeout`.
    The disabled rendering revokes all exceptions and sends the same limit statements. Each
    rendering is pinned to an M1 block.
  - `renderObserveClickHouse` gains a `setting` row per `system.settings_profile_elements`
    entry of the user: name, value, min, max, writability and inherited profile. Table-level
    grants stay structured rows.
  - `renderObserveServer` gains `rolconnlimit` and the role's `pg_db_role_setting` entries
    with `setdatabase = 0`.
- **Classification** (`Catalog.hs`).
  - `CatalogUser` gains observed settings (name, value, min, max, writability), inherited
    profiles, the connection limit and the role settings. EP-206 reads the same fields.
  - Parsing turns a ClickHouse `SELECT` on one of the four allow-listed `system` tables into a
    server-grant token such as `SELECT ON system.parts`. Any other grant with a table or
    column is still an anomaly. Classification, not parsing, decides whether the token is
    declared.
  - `classifyUser` takes the desired and the accepted extension and applies the one rule in
    the Decision Log to each exception, setting, inherited profile, connection limit and role
    setting.
  - `postgresGrant` accepts declared monitoring roles for exactly the read-only privileges in
    the Decision Log.
- **Adapter.** `AppDatabaseMember` carries the desired extension; the accepted one is read
  from the accepted spec. `SetUserAccess` carries the desired extension, so `converge` sends
  one statement set per member. The operation `summary` names each declared exception and
  limit, so the saved plan shows them (IR-30 AC-1).
- **World.** Extend `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs` to interpret the new
  statements with M1's semantics. Add an adversary fault that hand-adds an undeclared setting
  and one that hand-adds an undeclared grant on `system.parts`.

**M4, lifecycle and docs.**

- **Rotation.** `rotateAppDatabaseScope` is unchanged; a test confirms the extension survives
  it.
- **Retirement.** `retireAppDatabaseScope` already turns user specs off; the disabled path of
  `renderUserAccess` now also revokes the exceptions and sends the declared limits.
  `classifyUser` expects no exceptions and the declared limits for a disabled user.
- **Restore.** ClickHouse exceptions are server-wide, not per database, so scratch restore
  needs nothing new. A test asserts that a re-plan after a rebuilt restore is `no operations`
  for an app database with PGMQ grants in its dump.
- **Docs.** Write the docs section, with a worked Kansoku-shaped example. It states which
  limits are ceilings and that `statement_timeout` is a default, that the migration user's
  ceilings bound its scheduled backup and its connection limit must leave one connection for
  `pg_dump`, and why `system.processes` is not offered.

**M5, native confirmation.** Extend the smoke after its AC-3 step:

- declare `system-parts`, `system-storage-policies` and `arbitrary-temporary-tables` on
  `alpha-ch`'s runtime user, and all three ClickHouse ceilings on both of its users, with the
  migration user's ceilings large enough for the step 7 backup;
- declare a connection limit of 3 and `pg_monitor` on `alpha-pg`;
- re-plan, apply, and assert the probes listed in Validation;
- remove one exception, and assert the plan revokes it.

The smoke's later steps then rotate `alpha-pg`, retire `beta-ch`, and back up and restore
`alpha-ch` with its exceptions and ceilings in force, which is IR-30 AC-5's native evidence.
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
cd cli/nagarectl && cabal test nagarectl-test --test-options="-p AppDatabase"
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

- **AC-1.** The smoke runs the M1 probes as `alpha_runtime`, with M1's proven sizes:
  - the `cityHash64` sum over `numbers(100000000000)` stops at the time ceiling;
  - the `groupArray` over `numbers(30000000)` stops at the memory ceiling;
  - the third concurrent `sleep(3)` is refused.

  The same queries as `beta_runtime` complete, so they were stopped by `alpha`'s ceilings and
  not by the server's own limits.
- **AC-2.** As `alpha_runtime`:
  - `SET max_memory_usage` below the ceiling is accepted;
  - above it, and to `0`, is refused;
  - `SET enable_analyzer = 0` is accepted.
- **AC-3.** As `alpha_pg_runtime`, opening connection 4 when the limit is 3 fails with
  `too many connections for role`.
- **AC-4.** In the world:
  - a hand-applied `ALTER USER … SETTINGS max_memory_usage = 0` and a hand
    `ALTER ROLE … CONNECTION LIMIT 10`, neither value declared, each make the re-plan refuse
    with drift;
  - a hand `ALTER USER … SETTINGS NONE` and a hand `ALTER ROLE … CONNECTION LIMIT -1` each
    make the re-plan show the update that restores the declared limit;
  - changing the declared ceiling plans an update, and after it the old value is gone.

**Transition.** A test loads the accepted `appdb-*` scope records that the v0.7.1 smoke
produced, decodes and re-encodes them byte-identically, and compiles the unchanged declaration
to members equal to the accepted ones, so the planner sees no change. Record the records as a
fixture under `cli/nagarectl/test/fixtures/app-database/`, taken from
`nagarectl inventory export --out DIR` on the M5 context before the upgrade; the scope
records are the `appdb-*` entries under its `scopes/` directory.


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
  - `Nagare.Inventory.AppDatabaseRestore`;
  - `Nagare.Inventory.Application.Bindings`;
  - `Nagare.Inventory.Adapters.AppDatabase`;
  - `Nagare.Resource.Inventory`;
  - the tests `AppDatabaseSpec` and `AppDatabaseWorldSpec`.
- `CatalogUser` gains settings, inherited profiles, the connection limit and role settings.
  `SetUserAccess` carries the desired extension. `classifyUser` takes the desired and accepted
  extensions. `DatabaseAccess` carries the declared monitoring roles.

No new libraries. EP-206 depends on the ClickHouse user-settings mechanism, the PostgreSQL
role-setting observation, and the `CatalogUser` fields, from M3. EP-205 changes the same
`DatabaseUserSpec` constructor (its login flag); whichever lands first writes the hand-written
codec, and the other extends it.
