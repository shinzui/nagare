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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-20T01:56:28Z
      mode: "implement"
      note: "M1 onward: engine proof, readers, grants, bindings"
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

- [x] M1 (engine proof). Reader statements and observations are proven by hand against
  `postgres:18` and `clickhouse/clickhouse-server:26.8`. They are committed as `-- operation:`
  blocks in `cli/nagarectl/test/fixtures/app-database/clickhouse.sql` and `postgres.sql`, with
  captured observations under `observed/`. Every question listed under M1 in Plan of Work is
  answered in the Decision Log. M1 does not depend on EP-204 and may run before it lands.
  Done 2026-10-20 on 26.8.29.10 and 18. The new blocks are `reader-access alpha_reader_dash
  on|off` (both engines) and `observe-relations alpha`. The captures are
  `observed/clickhouse-reader.jsonl` and `postgres-{server,database,relations}-reader.json`.
- [x] M2 (declaration). `AppDatabase` declares readers, each with a name, objects, limits,
  consumers and a `retired` flag. `AppDatabaseRole` gains `ReaderRole`, and one token parser
  serves every consumer of the role token. Derived user and Secret names fit both engines'
  identifier limits. The loader refuses an object outside the app's own databases (IR-33
  AC-1), a repeated reader, a reader named `runtime` or `migration`, an invalid object
  identifier, and a reader missing any of its five ClickHouse ceilings.
  Done 2026-10-20. Evidence: `AppDatabaseSpec` "readers, their objects and a workload's reader
  bindings round-trip" and "a reader outside the app's databases ... refuses before planning".
- [x] M3 (members, grants and classification). Each reader compiles to a credential member and
  a user member. The adapter creates, grants, limits and observes readers. Logical-database
  members accept declared reader grants. Anything else stays drift. Absent PostgreSQL objects
  plan as pending and are printed by `db app-database plan`. The two PostgreSQL write-path
  refusals hold. `AppDatabaseWorldSpec` proves IR-33 AC-1, AC-2, AC-4, AC-5 and AC-9 in the
  interpreter, and AC-3 against the M1 semantics.
  Done 2026-10-20. Evidence: `AppDatabaseSqlSpec` pins the M1 blocks and classifies the
  captured observations; `AppDatabaseWorldSpec` runs the whole EP-202 matrix "with a reader"
  (every interruption, drift, rotation, retirement, server rebuild) and the "readers (EP-206)"
  group on both engines.
- [x] M4 (credentials and binding). `rotate --user reader-<r>` rotates one reader, and a reader
  declared `retired` is turned off by the next plan. Neither touches other users. A workload
  binds a reader through `appDatabaseReaders` only when the owning declaration lists its app,
  and then receives only that Secret. `appDatabases` never injects a reader. Render tests prove
  IR-33 AC-6 and AC-7.
  Done 2026-10-20. Evidence: `AppDatabaseSpec` "a reader binds its own Secret for a declared
  consumer only, after its user and databases, until it is retired", on both engines, including
  `app-database-reader-in-use`.
- [ ] M5 (backup, restore and docs). Rebuilt restore brings readers and their grants back, and
  scratch restore does not extend readers to scratch databases (IR-33 AC-8), on both engines.
  The "Sharing one server between apps" section of `docs/user/managed-databases.md` documents
  readers, including the advisory nature of the PostgreSQL role defaults. The change is landed
  with a green `just gate-fast`.
- [ ] M6 (native confirmation). `scripts/local-app-database-smoke.sh` declares one reader on
  `alpha-ch` and one on `alpha-pg`. It binds each from a second app, and proves AC-2, AC-3, AC-6,
  AC-7, AC-8 and AC-9 on a disposable local context with the packaged CLI.
- [ ] M7 (release). The change ships in a release. The intranet is upgraded on the candidate
  before the tag. `kansoku-ch` declares its `dashboards` reader in `mori://tan/tan-ng-labs`.
  IR-33 is completed in `docs/improvement-requests/log.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: M2 onwards starts after
  [EP-204](204-let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits.md) M3 is
  landed. M1 is independent of it. EP-204 has no code landed yet (as of 2026-10-19 both plans
  exist only as documents), so every EP-204 name this plan uses (`AppDatabaseAccess`,
  `UserLimits`, the user-spec extension, the settings and role-setting observation) is as
  EP-204's Plan of Work and Interfaces define it.
  Rationale: Reader limits reuse EP-204's ClickHouse user-level settings with constraints, its
  PostgreSQL connection limit and role settings, and their observation and classification.
  Building readers first would mean a second limits mechanism, which IR-33 asks Nagare to avoid.
  Date: 2026-10-19

- Decision: Readers are named `<appdb_with_underscores>_reader_<reader>`. Their Secrets are
  named `<appdb>-reader-<reader>`, and their spec role token is `reader-<reader>`. A reader
  name matches `[a-z][a-z0-9]{0,15}` and is neither `runtime` nor `migration`. One function,
  `parseAppDatabaseRole :: Text -> Maybe AppDatabaseRole`, inverts `appDatabaseRoleToken`,
  and it is the only place the tokens are parsed: spec validity in
  `Nagare.Resource.Inventory`, the adapter, `Bindings.hs` and the `rotate --user` option all
  call it.
  Rationale: An app-database name is at most 36 characters, so the longest user name is 60
  characters. That is under PostgreSQL's 63, and needs no quoting on either engine. The infix
  alone does not keep names distinct across app databases: app database `foo` with reader
  `runtime` and app database `foo-reader` would both own user `foo_reader_runtime` and Secret
  `foo-reader-runtime`; reserving the two words closes that, and hyphens are not allowed in a
  reader name, so no other pair collides. One parser keeps the four current spellings of the
  token check (`Inventory.hs`, the adapter, `Bindings.hs`, `Data/AppDatabase.hs`) from
  becoming eight.
  Date: 2026-10-19

- Decision: Reader limits are EP-204's `UserLimits`, extended with three optional ClickHouse
  fields, `maxResultRows`, `maxResultBytes` and `maxThreads`. There is no separate
  `ReaderLimits` type. `Nagare.Dsl.AppDatabase` exports `defaultReaderLimits`, which is
  Kansoku's profile: 30 s, 512 MiB, 10,000 rows, 10 MiB, 4 threads, and connection limit 5 with
  a 30 s statement timeout on PostgreSQL. A ClickHouse reader must set all five ceilings
  (`validateAppDatabase` refuses one that leaves any of them unset); a PostgreSQL reader must
  set its connection limit. `Nothing` keeps its EP-204 meaning, no ceiling, for every user.
  Rationale: One limits type and one rendering serve all three kinds of user. A reader's
  ceilings are mandatory because IR-33 AC-3 fixes them; making the loader fill defaults would
  give `Nothing` two meanings.
  Date: 2026-10-19

- Decision: ClickHouse reader settings are one `ALTER USER … SETTINGS` statement, as EP-204
  renders it, holding `readonly = 2 CONST`, `result_overflow_mode = 'throw' CONST`, and each
  ceiling as `<name> = <v> MIN 1 MAX <v>`: `max_execution_time`, `max_memory_usage`,
  `max_result_rows`, `max_result_bytes` and `max_threads`. A declaration may set different
  positive ceilings, and cannot change the two `CONST` settings.
  Rationale: EP-204 established that a constraint compares only against its own bounds, so
  `MAX` alone accepts `SET max_execution_time = 0`, which means unlimited; `MIN 1` is what
  refuses zero, and M1 confirms it for each of the five. Kansoku's own profile
  (`mori://shinzui/kansoku`, `db/clickhouse/reader-role.sql`) makes time and memory lowerable
  and the other three `CONST`; one rule for all five is simpler, lowering a result or thread
  ceiling is harmless, and IR-33 AC-3 only requires that none can be raised. Settings on the
  user avoid a named profile entity per reader. Kansoku's `date_time_output_format` is a
  presentation default and is not carried.
  Date: 2026-10-19

- Decision: PostgreSQL reader limits are `CONNECTION LIMIT`, plus role settings
  `default_transaction_read_only = on` and `statement_timeout`. The docs call the two
  settings advisory defaults. EP-204's role-setting classification, which treats any role
  setting other than `statement_timeout` as drift, accepts `default_transaction_read_only` on a
  reader. The read-only boundary is grants: `CONNECT` on the database, `USAGE` on the schemas
  of declared objects, and `SELECT` on each declared object. A reader never gets membership in
  any role, including `pg_read_all_data`, and never `TEMPORARY` or `CREATE`.
  Rationale: A session can `SET` either role setting back, as IR-33 AC-9 notes. Only grants and
  the connection limit are enforced by the server.
  Date: 2026-10-19

- Decision: Reader objects are typed, validated identifiers, never free text. `ReaderObject`
  is `ReaderRelation { database :: LogicalDatabaseName, schema :: Maybe SchemaName, relation ::
  RelationName }` or `ReaderSchemaViews { database :: LogicalDatabaseName, schema ::
  SchemaName }`. `SchemaName` and `RelationName` follow `LogicalDatabaseName`'s rule,
  `[a-z][a-z0-9_]{0,62}`. On PostgreSQL `schema` defaults to `public`; on ClickHouse a schema
  or `ReaderSchemaViews` is refused. A `ReaderSchemaViews` object stands for the views
  (`relkind` `v` or `m`) observed in that schema at plan time: zero views is complete, not
  pending, and a view created later is granted by the next plan.
  Rationale: `Sql.hs` relies on every name being a validated identifier so that quoting needs
  no escaping; a config-supplied `Text` in a `GRANT` would break that invariant. PostgreSQL
  has no `ALL VIEWS IN SCHEMA`, and `ALL TABLES IN SCHEMA` would include tables, so the set is
  expanded from the relation observation.
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

- Decision: Reader refusals are a new `MemberState` constructor, `MemberRefused !Text !Text`
  (code, reason). The adapter reports it as `ObservationUnavailable (code <> ": " <> reason)`,
  exactly as it reports drift, and refuses preflight and converge on it.
  `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs` is unchanged: its `appDatabaseRefusal`
  already routes any `ObservationUnavailable` reason that starts with `app-database-` to a
  plan error under that code.
  Rationale: Drift means access Nagare never granted; a definer function is not drift, and the
  code must differ so the operator reads the right exit. The routing exists, so no plan-side
  change is needed.
  Date: 2026-10-19

- Decision: `classifyReader` applies EP-204's one rule to each grant of the reader. A held
  grant on a declared object is complete. A held grant that the accepted declaration named but
  the desired one does not is incomplete, and the update revokes it. Any other held grant is
  drift. A declared object that exists and is not granted is incomplete, and the update grants
  it. A declared PostgreSQL object that does not exist is pending: the member is complete over
  the present objects, no operation is planned, and the plan prints `pending: <schema>.<object>`.
  ClickHouse is expected to accept a grant on a table that does not exist yet and to report it
  in `system.grants` exactly, in which case ClickHouse grants by name up front and has nothing
  pending; M1 confirms this.
  Rationale: IR-33 AC-5 requires that a reader declared before migrations neither fails nor
  wedges, and that the next plan after migrations ends with no operations. A perpetual update
  operation while objects are pending would make `no operations` useless as the converged
  signal, so pending is not drift.
  Date: 2026-10-19

- Decision: Pending objects are reported through an observation note. `ObservationSet` in
  `cli/nagarectl/src/Nagare/Inventory/Adapter.hs` gains a third map, `Map ResourceId Text`,
  beside the stuck-rollout map, with `observationNotes` and `withObservationNotes`. The
  app-database adapter fills it for a reader with pending objects. `db app-database plan`
  prints each note after the operations (or after `no operations`), and `inventory status`
  prints it beside the member. Notes never change planning.
  Rationale: No channel exists today for an informational per-member message: the plan output
  is the operations' public summaries, which are computed from the reviewed plan, not from
  observation, and the only side map carries stuck rollouts with planning semantics of its
  own. One generic note map is smaller than any reader-specific path.
  Date: 2026-10-19

- Decision: Consumers are `ServiceName`s of applications or workers in the app database's own
  namespace. Cross-namespace readers are out of scope.
  Rationale: Applications and workers are named by `ServiceName` in `Nagare.Dsl.Types`. An app
  database, its server and its bound workloads are already in one namespace
  (`acceptedAppDatabaseServer` refuses otherwise), and a Secret can only be mounted in its own
  namespace.
  Date: 2026-10-19

- Decision: A reader binding injects the same variable names as a runtime binding, so a
  workload binds at most one credential per engine: a runtime or a reader. The existing
  `mergeConnectionEnvs` refusal enforces this; no new check is added. A reader binding orders
  the workload after the reader's credential and user members and the databases its objects
  live in, not after every member of the scope, so the binders of one reader are exactly the
  accepted members outside the scope ordered after that reader's credential member.
  Rationale: ADR 30 already limits a workload to one database per engine, because bindings
  inject fixed names. Runtime bindings today are ordered after every user and database member
  and are unchanged.
  Date: 2026-10-19

- Decision: Reader retirement is declared, not commanded. `AppDatabaseReader` carries
  `retired :: !Bool`, emitted only when true. A retired reader compiles to a disabled user
  spec, so the next plan closes its login and revokes its grants while keeping its Secret and
  its declaration; setting it back re-opens it. `db app-database plan` refuses with
  `app-database-reader-in-use` when a reader is declared retired while an accepted workload
  still binds it, mirroring `app-database-in-use`. There is no `retire --reader` command.
  Dropping a reader from the declaration, retired or not, is refused by the planner's existing
  `retirement-required` rule, because its members would be absent from the desired scope
  without a lifecycle decision; a reader therefore stays declared once accepted. Retiring the
  whole app database retires its readers too, since `retireAppDatabaseScope` disables every
  user spec.
  Rationale: A reader lives inside a declared scope. A command-based retirement would be
  undone by the next re-plan of the config, as app-database retirement is, and the operator
  could not then drop the reader to keep it retired. The flag is the one place the reader's
  state lives, and it needs no new command, decider or lifecycle path.
  Date: 2026-10-19


- Decision (M1): ClickHouse accepts a grant on a table that does not exist yet and reports it
  exactly in `system.grants`, so ClickHouse grants every declared object up front and has
  nothing pending. Only PostgreSQL objects can be pending.
  Date: 2026-10-20

- Decision (M1): each of the five ClickHouse ceilings is enforced: time (159 at 30 s), memory
  (241), result rows (396), result bytes (396) and threads (a `SET` above it is refused).
  - The result-bytes probe must send its rows to the client; under `FORMAT Null` the bytes are
    not counted.
  - `SET readonly = 0` is refused with 164, and a `SET` above a ceiling or to 0 with 452.
  Date: 2026-10-20

- Decision (M1): the PostgreSQL boundary is grants, as planned. With both role defaults
  overridden, every write, DDL and temporary table is refused. A migration-owned `SECURITY
  DEFINER` function that writes is callable through PUBLIC's default `EXECUTE` and does write;
  after the app revokes it, the reader is refused. The refusal code
  `app-database-reader-definer-function` closes that path.
  Date: 2026-10-20

- Decision: the reader rendering grants every declared object. It also revokes each held grant
  that only the accepted declaration named; the adapter takes that list from the catalog it
  has just read. Revoking a grant that is not held is a no-op, so a retry is still safe.
  Rationale: a reader's objects are named, unlike EP-204's closed exception list, so the
  rendering cannot revoke every possible other object.
  Date: 2026-10-20

- Decision: the PostgreSQL relation observation (`observe-relations`) runs for every app
  database. It covers every non-system schema, and restricts the reported grants to the
  scope's users.
  Rationale: the transport does not know which users are readers, and one query per database
  is cheap.
  Date: 2026-10-20

- Decision: readers live in `access`, which EP-204 left out of the backup schedule's
  declaration digest (4b5739fd). Adding or changing a reader therefore keeps the schedule
  revision, and M5's expectation that the digest changes is dropped.
  Rationale: a backup holds no reader bytes, and restore re-applies the readers from the
  accepted scope, not from the backup. A changed revision would block pruning of earlier runs
  for nothing.
  Date: 2026-10-20

- Decision: one `ReaderAccess` record carries a reader command: its login, limits, granted and
  revoked objects, and on PostgreSQL its databases and its (database, schema) pairs, each with
  a revoked list. A schema counts only once it exists in that database, so a reader whose
  objects are all pending still gets `CONNECT` and never a `USAGE` on a missing schema. The
  reader user is ordered after the database members of its objects.
  Rationale: the positional command granted `CONNECT` only through present objects, so a reader
  declared before its views stayed incomplete forever, and a schema or database dropped from
  the declaration could not be revoked.
  Date: 2026-10-20

- Decision: notes print on stderr as `note: <resource>: <text>` for every inventory plan, and
  become the finding's `reason` in `inventory status`.
  Rationale: one place serves `db app-database plan` and every other planner, and stdout keeps
  its contract.
  Date: 2026-10-20

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
  - `AppDatabaseRole = RuntimeRole | MigrationRole`, which derives `Enum` and `Bounded`
    (nothing enumerates it; `compileAppDatabase` lists the two roles explicitly);
  - `appDatabaseUser`, `appDatabaseSecretName` and `appDatabaseRoleToken`;
  - the grant functions `appDatabaseAttributes`, `appDatabaseServerGrants` and
    `appDatabaseDatabaseGrants`, which pattern-match on the role;
  - EP-204's `AppDatabaseAccess` and `UserLimits`.
- **Members.** `compileAppDatabase` in `cli/nagare-dsl/src/Nagare/Resource/AppDatabase.hs`
  builds a credential and a user member per role, plus the logical-database and backup members.
  `appDatabaseCredentialTemplate` writes the Secret's labels and annotations, including
  `nagare.dev/app-database-role` and `nagare.dev/app-database-db`. Spec validity, which today
  allows only the role tokens `runtime` and `migration`, is in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` near line 222.
- **SQL and observation.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`. Every name
  it interpolates is a validated identifier, so quoting needs no escaping.
  - PostgreSQL observation reads database, schema and default ACLs, not per-relation ACLs. A
    reader's per-object `SELECT` needs a new per-database relation observation.
  - ClickHouse observation already returns every `system.grants` row of the app's users, plus
    every grant on the app's databases.
- **Classification.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs`.
  - `classifyDatabase` treats a ClickHouse grant on the app's database to anyone but the two
    users as `granted to …` drift.
  - `postgresGrant` treats any PostgreSQL grantee except the two users, `PUBLIC` and
    `pg_database_owner` as drift.
  - ClickHouse table-level grants are anomalies of the user that holds them.

  All of these must learn the declared readers.
- **Adapter.** `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs`:
  `AppDatabaseMember`, `MemberKind`, `UserMember role user secretNs secretName`, and
  `mkAppDatabaseAdapter`. `appDatabaseMembersFromDeclarations` parses the role token and
  collects every `DatabaseUser` member of the scope as `scopeUsers`, so reader users are
  observed without further change. The operation summary is computed at prepare time from the
  reviewed plan, not from observation.
- **Refusal routing.** `appDatabaseRefusal` in `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`
  turns any `ObservationUnavailable` reason of an app-database member that starts with
  `app-database-<code>: ` into a plan error under that code.
- **Rotation and retirement.** `rotateAppDatabaseScope` and `retireAppDatabaseScope` are in
  `cli/nagarectl/src/Nagare/Inventory/AppDatabase.hs`. Rotation is keyed on the role token
  (`rotate-<token>` is the operation name), and retirement disables every `DatabaseUserSpec`
  and `LogicalDatabase` spec of the scope, refusing with `app-database-in-use` while any
  accepted member outside the scope is ordered after one of its members. Their CLI is
  `cli/nagarectl/app/Nagare/Cli/Parser/AppDatabase.hs` and
  `cli/nagarectl/app/Nagare/Cli/Data/AppDatabase.hs`, where `--user runtime|migration` is
  checked by a literal match. `db app-database plan` prints the review's operation summaries
  or `no operations` (`planReview`).
- **Bindings.** `appDatabases :: ![AppDatabaseName]` on the deployment record is in
  `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` near line 716. It is loaded in
  `cli/nagare-dsl/src/Nagare/Dsl/Load/Deployment.hs` and emitted only when non-empty by
  `appDatabasesJSON` in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`.
  `acceptedAppDatabaseBindings` in `cli/nagarectl/src/Nagare/Inventory/Application/Bindings.hs`
  resolves each name to the `<name>-runtime` Secret in the namespace. It refuses a retired app
  database by requiring every user spec to be enabled. That check must become "the runtime
  user is enabled", or a retired reader would block every binding; `appDatabaseRows` (the
  `retired` column of `db app-database list`) uses the same rule. The variables are injected
  by `appDatabase` in `cli/nagarectl/src/Nagare/Inventory/Application/Environment.hs`, and
  `mergeConnectionEnvs` in `cli/nagarectl/src/Nagare/Database/Connection.hs` refuses two
  bindings of one engine.
- **Backups.** `appDatabaseDumpShell` in `cli/nagarectl/src/Nagare/Database/Backup.hs` dumps
  PostgreSQL in custom format, with owners and ACLs, as the migration user, and ClickHouse with
  `BACKUP DATABASE`, which carries no user grants. Restores run `pg_restore --exit-on-error`,
  so a reader's ACL in a dump loads only because the reader role exists on the server, which a
  re-applied declaration guarantees. Scratch restore (`renderScratchRestore` in `Sql.hs`)
  revokes `ALL ON DATABASE` from `PUBLIC` and grants only the runtime user `CONNECT`. So a
  reader's restored ACLs on scratch objects are unreachable without `CONNECT`.
- **Tests and smoke.**
  - `cli/nagarectl/test/AppDatabaseSqlSpec.hs` (fixtures, group `AppDatabase SQL`);
  - `cli/nagarectl/test/AppDatabaseSpec.hs` (compile, bindings, schedules, group `AppDatabase`);
  - `cli/nagarectl/test/AppDatabaseWorldSpec.hs` with
    `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs` (interpreter world, group
    `AppDatabase world`);
  - `scripts/local-app-database-smoke.sh` (native).
- **Command audit.** `scripts/audit-managed-commands.py` registers CLI constructors, not their
  options; `AppDatabaseRotate` and `AppDatabaseRetire` are already registered, and this plan
  adds no constructor.

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
- **Ceilings.** Is each of the five ceilings enforced when exceeded? For each, is `SET` below it
  accepted, above it refused and `= 0` refused? Is `SET readonly = 0` refused?
- **Early grants.** Is a grant on a table that does not exist yet accepted, and is it reported
  in `system.grants` exactly? This confirms the ClickHouse pending rule.

PostgreSQL questions:

- **Grants.** With `CONNECT`, `USAGE ON SCHEMA public` and `SELECT` on two views owned by
  `alpha_migration`, can the reader read the views but not the base table?
- **Write path.** After `SET default_transaction_read_only = off; SET statement_timeout = 0`,
  are `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE` and `CREATE TEMPORARY TABLE` refused?
- **Definer function.** Is a migration-owned `SECURITY DEFINER` function that inserts callable
  by default? It is expected to be, through `PUBLIC EXECUTE`. Is it refused after
  `REVOKE EXECUTE … FROM PUBLIC`?
- **Invoker view.** Does a `security_invoker = true` view fail for the reader?
- **Connection limit.** Is connection limit + 1 refused?
- **Role settings.** How does `pg_db_role_setting` report `default_transaction_read_only`, so
  EP-204's role-setting observation classifies it?
- **Observation.** Write a relation-ACL observation query for one database. It returns, for each
  relation of `relkind` `r`, `p`, `v` or `m` in the given schemas, the schema, name, `relkind`,
  `reloptions` and the reader's privileges from its ACL. It also returns `SECURITY DEFINER`
  functions (`pg_proc.prosecdef`) in the given schemas, with their ACLs. Capture its output.

**M2, declaration.** In `Nagare.Dsl.AppDatabase`:

- Add `ReaderName`, `SchemaName` and `RelationName` (validated), `ReaderObject` as the
  Decision Log defines it, and `AppDatabaseReader { name, objects :: NonEmpty ReaderObject,
  limits :: !UserLimits, consumers :: ![ServiceName], retired :: !Bool }`.
- Extend EP-204's `UserLimits` with `maxResultRows`, `maxResultBytes` and `maxThreads`, and
  export `defaultReaderLimits`.
- Add `readers :: ![AppDatabaseReader]` to EP-204's `AppDatabaseAccess`.
- `AppDatabaseRole` gains `ReaderRole !ReaderName`; drop the `Enum` and `Bounded` derivations.
  Add `parseAppDatabaseRole`. Extend `appDatabaseUser`, `appDatabaseSecretName` and
  `appDatabaseRoleToken`. A reader has no server grants and no database-level grants
  (`appDatabaseServerGrants` and `appDatabaseDatabaseGrants` return `[]` for it); its PostgreSQL
  attributes are the same `LOGIN NOSUPERUSER …` list as the other users.

`validateAppDatabase` refuses:

- an object whose database is not one of the app's `logicalDatabases`;
- a schema or `ReaderSchemaViews` on ClickHouse;
- a repeated reader or object, or a reader named `runtime` or `migration`;
- a reader missing any of the five ClickHouse ceilings, or a PostgreSQL reader without a
  connection limit;
- a non-positive limit.

The loader takes an optional `readers` array inside `access`, emitted only when non-empty;
`retired` is emitted only when true.

**M3, members, grants and classification.**

- **Members.** `compileAppDatabase` emits, per reader, a credential member and a user member
  with the `reader-<r>` token, enabled unless `retired`. The user spec's extension (from EP-204)
  carries the objects, limits and consumers. The Secret's `nagare.dev/app-database-db`
  annotation, and so its `POSTGRES_DB` or `CLICKHOUSE_DB`, is the database of the reader's
  first object. Spec validity in `Nagare.Resource.Inventory` calls `parseAppDatabaseRole`.
- **SQL.**
  - The create, access and password renderings take the reader role.
  - New renderings: `renderReaderAccess`, which takes the reader's resolved object list (the
    declaration expanded against the observed relations, which the adapter computes from the
    catalog it has just read) and renders, for an enabled reader, `CONNECT`, schema `USAGE`,
    one `GRANT SELECT` per object, and EP-204's settings or connection-limit and role-setting
    statements; and for a disabled reader, login off, the revocations of the same grants, and
    the same limit statements. `renderObserveRelations` is M1's query.
- **Classification.**
  - Add `classifyReader`, which applies the Decision Log's rule to the reader's observed grants,
    settings and role settings, returning complete with a pending list, incomplete, drift, or
    `MemberRefused` for the two write-path codes.
  - Teach `classifyDatabase` and `postgresGrant` to accept a declared reader's `CONNECT` and
    schema `USAGE`, and on ClickHouse its table-level `SELECT` on the app's databases. Leave
    judging those grants to the reader member. Any other grantee stays drift.
- **Adapter.** `MemberKind` gains `ReaderMember`. `converge` creates the user, applies the
  access and verifies. A pending list becomes an observation note.
- **Notes.** Add the notes map to `ObservationSet`, print notes in `db app-database plan`
  (`planReview`) and `inventory status`.
- **World.** Extend the interpreter world with relations (tables, views, definer and invoker
  views), functions, and per-relation ACLs, all with M1's semantics.

**M4, credentials and binding.**

- **Rotation.** `rotate --user` accepts any role token: `runtime`, `migration` or
  `reader-<r>`, checked by `parseAppDatabaseRole`. `rotateAppDatabaseScope` already keys
  rotation on the token.
- **Retirement.** None beyond the declaration: a `retired` reader compiles disabled. The
  `db app-database plan` runner refuses `app-database-reader-in-use` for a retired reader whose
  credential member an accepted member outside the scope is ordered after.
- **Bindings.**
  - Add `appDatabaseReaders :: ![AppDatabaseReaderRef]`, where `AppDatabaseReaderRef
    { appDatabase :: AppDatabaseName, reader :: ReaderName }`, to the deployment record, loader
    and emitter, emitted only when non-empty.
  - In `Bindings.hs`, resolve each reference to `<appdb>-reader-<r>`, given the deploying
    application's `ServiceName`. Refuse when the reader spec's consumers do not list it, or
    when the reader is retired. The binding orders the workload after the reader's credential
    and user members and its objects' databases. Two bindings of one engine are refused by
    `mergeConnectionEnvs` as today.
  - Change the retired check of `acceptedAppDatabaseBindings`, and `appDatabaseRows`, to the
    runtime user's spec.

**M5, backup, restore and docs.**

- **Tests.**
  - A rebuilt restore after re-apply leaves every reader complete, on both engines, and a
    PostgreSQL dump holding reader ACLs loads under `--exit-on-error`.
  - A scratch restore leaves the reader unable to connect to, or read, the scratch databases.
  - The schedule's declaration digest changes when a reader is added. This is expected, because
    a restore must re-apply the readers.
- **Docs.** Document readers with the Kansoku example and the Grafana-over-PostgreSQL example,
  including declared retirement and that a reader stays declared once accepted.

**M6, native confirmation.** Extend the smoke after its AC-3 step:

1. Create a definer view and a parameterized view on `alpha-ch`, and a view on `alpha-pg`.
   Declare reader `dash` on each over those views, with consumer `gamma`.
2. Re-plan and apply, and assert the probes listed in Validation.
3. Deploy probe workload `gamma` binding both readers, and probe workload `delta` binding one
   without being a declared consumer. `delta` must be refused.
4. Rotate `alpha-pg`'s reader, then declare it retired and re-plan.
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

For each Haskell commit (the three app-database test groups all match the one pattern):

```bash
cd cli/nagarectl && cabal test nagarectl-test --test-options="-p AppDatabase"
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
  - A loader test refuses an object in `beta`'s database, and a reader named `runtime`.
- **AC-2.** In the world and in the smoke, the reader:
  - can `SELECT` each declared object;
  - is refused on the undeclared table in the same database, `INSERT`, `ALTER … UPDATE`,
    `DELETE`, DDL, temporary tables, `CREATE USER`, `system.parts`, and `beta`'s table.
- **AC-3.** On ClickHouse, a query over each ceiling is stopped. `SET` below a ceiling is
  accepted, and `SET` above it or to `0` is refused. `SET readonly = 0` is refused.
- **AC-4.** The reader reads a definer view, and is refused on its base table, on both engines.
- **AC-5.**
  - In the world, a reader declared before migrations plans and applies with no operation for
    the missing object, and `db app-database plan` prints `pending: public.events_v`.
  - After the migration creates the view, the re-plan grants it, and the next plan prints
    `no operations` and no note.
- **AC-6.**
  - Rotating `reader-dash` changes only `alpha-pg-reader-dash`'s Secret and the reader's
    password. Declaring it retired closes only its login and grants, and keeps its Secret.
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

A retired reader keeps its Secret and its declaration, so re-enabling it is one flag change and
one plan. The M1 containers and the M6 context are disposable.


## Interfaces and Dependencies

- **Prerequisite.** EP-204 M3 is landed before M2 here: the user-spec extension and its codec,
  `UserLimits`, ClickHouse user settings, the PostgreSQL connection limit and role settings,
  and their classification.
- `Nagare.Dsl.AppDatabase` gains `ReaderName`, `SchemaName`, `RelationName`, `ReaderObject`,
  `AppDatabaseReader`, `defaultReaderLimits`, `ReaderRole` and `parseAppDatabaseRole`.
  `UserLimits` gains `maxResultRows`, `maxResultBytes` and `maxThreads`. `AppDatabaseRole`
  loses `Enum` and `Bounded`.
- The deployment record in `Nagare.Dsl.Types` gains `appDatabaseReaders`.
- `Nagare.Database.AppDatabase.Catalog` gains `classifyReader`, `MemberRefused` and relation
  observations. `classifyDatabase` takes the declared readers.
- `Nagare.Inventory.Adapter.ObservationSet` gains a notes map.
- `Nagare.Inventory.Adapters.AppDatabase.MemberKind` gains `ReaderMember`.
- `Nagare.Inventory.Application.Bindings` gains reader resolution, takes the deploying
  application's `ServiceName`, and changes its retired check.
- `Nagare.Inventory.Plan.Changes` is unchanged.
- No new libraries.
