---
id: 208
slug: let-an-app-database-declare-its-runtime-s-privileges-inside-its-own-databases
title: "Let an app database declare its runtime's privileges inside its own databases"
kind: exec-plan
created_at: 2026-10-20T14:59:59Z
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-20T14:59:59Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-20T15:27:40Z
      mode: "implement"
      note: "M1 engine proof and implementation"
---

# Let an app database declare its runtime's privileges inside its own databases

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This plan answers [IR-35](../improvement-requests/declare-runtime-privileges-within-an-app-database.md),
filed from the Kansoku deployment
(`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`)
on Nagare v0.8.0.

An app database gives every app two users. The migration user owns the app's databases and
changes their schema. The runtime user reads and writes rows and nothing else: on PostgreSQL
it holds `CONNECT`, `TEMPORARY`, schema `USAGE` and row DML, on ClickHouse `SELECT`, `INSERT`,
`ALTER UPDATE` and `ALTER DELETE`. Any other grant is drift, which refuses every later plan of
that app database. v0.8.0 (EP-204) relaxed this with a closed allow-list, which fits server-wide
and system-table grants but not privileges inside the app's own databases. The first real
consumer cannot run inside the fixed set. Every project the operator runs uses the same PGMQ
pattern: the server calls `pgmq.create` at startup, which runs `CREATE TABLE … pgmq.q_<name>`.
On the intranet Kansoku's server fails with `permission denied for schema pgmq` as its runtime
user, and the only paths today are a change to every app or a Nagare release per pattern.

After this plan an app database declares, in its `access` field and reviewed like the rest of
the declaration, any privilege that stays inside its own databases:

- On PostgreSQL the runtime user can be given `CREATE` on named schemas of the app's database
  (`pgmq`, say), and `CREATE` on the database itself for apps that create their own schemas.
  Whenever such a declaration lets the runtime own objects, Nagare also makes the migration user
  a member of the runtime role, so the scheduled `pg_dump` and the app's later migrations keep
  working on runtime-owned tables. The membership is derived from the declaration, shown in the
  plan and observed as declared. Objects the runtime creates inside declared schemas are
  expected; a runtime-owned object anywhere else, and every grant outside the declaration, stay
  drift.
- On ClickHouse either user can be given any privilege ClickHouse scopes to a database
  (`CREATE TABLE`, `DROP TABLE`, `ALTER TABLE`, `CREATE VIEW`, …), granted `ON <db>.*` for each
  of the app's own databases. The closed allow-list of EP-204 stays only for server-wide and
  system-table grants.
- An app database can name the workloads that bind its migration (owner) credential instead of
  the runtime credential, for apps that run their own migrations at startup. The binding injects
  the same variable names, and the migration Secret is never bindable by any other workload.

Rotation, retirement, quiesce and resume, backup, scratch restore and rebuilt restore cover the
declared privileges, the membership and the owner bindings. An app database that declares none
of this keeps today's behaviour and its accepted bytes. After the release, Kansoku's PostgreSQL
app database declares `CREATE` on schema `pgmq`, re-plans, and `kansoku-server` creates its
queue and serves `/health/live` as the runtime user, with one config change in
`mori://tan/tan-ng-labs` and no change to Kansoku.


## Progress

- [x] M1 (engine proof). Every new statement and observation is proven by hand against
  `postgres:18` and `clickhouse/clickhouse-server:26.8`, committed as `-- operation:` blocks in
  `cli/nagarectl/test/fixtures/app-database/postgres.sql` and `clickhouse.sql` with captured
  observations under `observed/`, including ClickHouse's `system.privileges` tree. Every
  question listed under M1 in Plan of Work is answered in the Decision Log.
  Done 2026-10-20 (postgres 18.6, ClickHouse 26.8.29.10): blocks `database-access alpha on
  with privileges`, `… removed`, `… off with privileges` and `restore-scratch with privileges`
  on both engines; observations `postgres-{server,database,relations}-privileges.json`,
  `postgres-relations-leak.json` and `clickhouse-privileges-declared.jsonl`. The answers are in
  the block comments and the three M1 decisions.
- [x] M2 (declaration). `AppDatabaseAccess` gains `privileges` (per user: PostgreSQL
  `createIn` and `createSchemas`, ClickHouse `clickhouse`) and `owners`. The loader refuses a
  privilege on the wrong engine or user, a schema that is not a valid identifier, a ClickHouse
  token of the wrong shape or already in the fixed set, and an owner that is not a service
  name. A declaration without them emits byte-identical JSON. Evidence: loader goldens and
  refusals in `AppDatabaseSpec`.
  Done 2026-10-20: `AppDatabasePrivilegeSpec` "declaration" group (round-trip, no key when
  undeclared, the spec layer, and ten refusals); the loader tests sit in a new module because
  `AppDatabaseSpec` reached the 1000-line ratchet.
- [x] M3 (PostgreSQL privileges and membership). The logical-database member carries the
  runtime's own-database privileges and the derived membership. The adapter grants `CREATE` on
  each declared schema that exists, `CREATE` on the database when declared, and the membership;
  a declared schema that does not exist yet is pending and printed as a note. The catalog
  expects runtime-owned relations in declared and runtime-owned schemas, accepts the declared
  membership, and reports everything else as drift. `AppDatabaseWorldSpec` proves IR-35 AC-1,
  AC-2 and AC-3 in the interpreter, including a PGMQ-shaped flow: migration installs the
  schema, the runtime creates a queue table, the migration user alters it, and a re-plan has no
  operations.
  Done 2026-10-20: `AppDatabaseSqlSpec` pins the four PostgreSQL blocks and classifies the M1
  observations (complete, pending, hand grant, runtime-owned schema and relation, admin option,
  removal rendering the proven block); `AppDatabasePrivilegeSpec` "Postgres world" runs the PGMQ
  flow, the drift cases, the removal and every fault of the grant. The world found that
  memberships are server-wide, so a database member judges only those naming its own users.
- [x] M4 (ClickHouse own-database privileges). The logical-database member carries each user's
  declared ClickHouse privileges. Observation reads the server's privilege tree; a declared
  token the server cannot grant on a database refuses the plan with
  `app-database-privilege-unknown`. Classification compares leaf privilege sets, so a declared
  group such as `ALTER TABLE` over the fixed `ALTER UPDATE, ALTER DELETE` converges and re-plans
  to no operations. Removal revokes through review; a hand grant beyond the declaration is
  drift. `AppDatabaseWorldSpec` proves IR-35 AC-4 in the interpreter.
  Done 2026-10-20: the world holds ClickHouse grants as leaves of the captured 26.8 tree and
  reports their minimal cover; `AppDatabasePrivilegeSpec` "ClickHouse world" and
  `AppDatabaseSqlSpec` prove AC-4 including the group, its removal and `ACCESS MANAGEMENT`.
- [x] M5 (owner bindings). A workload named in `owners` that lists the app database in
  `appDatabases` receives `<name>-migration`; every other workload receives `<name>-runtime` as
  today; the deploy's render references exactly one of them. Render tests in `AppDatabaseSpec`
  prove IR-35 AC-5.
  Done 2026-10-20: `acceptedAppDatabaseBindings` takes the workload's `ServiceName`; the AC-5
  test is in `AppDatabasePrivilegeSpec` on both engines (variables identical, ordering
  unchanged, no way to the migration Secret without the declaration).
- [ ] M6 (lifecycle, docs and ADR). Rotation, retirement, quiesce and resume, scratch restore
  and rebuilt restore leave a declared app database complete on re-plan, on both engines, with
  the membership and owner bindings in force (IR-35 AC-6 in the world). The "Sharing one server
  between apps" section of `docs/user/managed-databases.md` states the rule and shows the PGMQ
  example (AC-7). ADR 31 records the rule. `just haskell-style-check` and `just gate-fast` are
  green and the change is landed.
  2026-10-20: the world matrix has a "with own privileges" variant on both engines (first
  apply, every interruption, drift, rotation, retirement, rebuild), and quiesce and resume keep
  the privileges and the membership. The scratch restore's rendering is pinned to the M1 block
  and owners surviving `pg_restore` were proven in M1; the native confirmation is M7. Docs,
  ADR 31 and the capability evidence are written. Landing is next.
- [ ] M7 (native confirmation). `scripts/local-app-database-smoke.sh` declares `CREATE` on
  schema `pgmq` for `alpha-pg`, `CREATE TABLE` and `DROP TABLE` for `alpha-ch`'s runtime, and
  one owner workload, and proves AC-1 to AC-6 natively on a disposable local context with the
  packaged CLI, ending in `app-database smoke: PASS`.
- [ ] M8 (release). The change ships in a release; the intranet is upgraded on the candidate
  before the tag. Kansoku's PostgreSQL app database declares `createIn = [pgmq]` in
  `mori://tan/tan-ng-labs`, re-plans, and `kansoku-server` starts as the runtime user. IR-35 is
  completed in `docs/improvement-requests/log.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: IR-35's three parts are one plan, in the order PostgreSQL privileges and
  membership (M3), ClickHouse privileges (M4), owner bindings (M5). Each milestone lands on its
  own.
  Rationale: The two engine parts extend the same logical-database member, through the same
  render, observe and classify path, and the owner binding is a small change to one resolver.
  The PostgreSQL part is what blocks Kansoku on the intranet, so it comes first and does not
  wait for the others.
  Date: 2026-10-20

- Decision: The declaration lives in `AppDatabaseAccess` as two new fields, both emitted only
  when non-empty: `privileges :: DatabasePrivileges` with a `runtime` and a `migration` half,
  each an `OwnPrivileges { createIn :: [SchemaName], createSchemas :: Bool, clickhouse ::
  [ClickHousePrivilege] }`; and `owners :: [ServiceName]`. The fields are flat and
  engine-checked at load, as `UserLimits` already is: `createIn` and `createSchemas` are
  PostgreSQL fields allowed on the runtime half only (the migration user owns the database);
  `clickhouse` is a ClickHouse field allowed on either half. Readers never carry own-database
  privileges.
  Rationale: One record shape per engine pair is the precedent EP-204 set, and generic-lens
  labels make the config read as `#privileges . #runtime . #createIn`. Keeping the privileges
  out of `UserAccess` keeps them off the user member, whose digest would otherwise change for a
  grant that the database member renders (see the next decision). IR-35's sketch
  (`schemaPrivileges`) is illustrative; PostgreSQL has exactly two schema privileges, `USAGE`
  (already a default privilege of every migration-created schema) and `CREATE`, so a list of
  schema names is the whole declaration.
  Date: 2026-10-20

- Decision: Own-database privileges ride on the logical-database member, not on the user
  members. `LogicalDatabase` gains a seventh positional element, the `DatabasePrivileges`,
  written by omission when empty, and its digest gains a `privileges` key only when non-empty.
  `renderDatabaseAccess` renders the grants; `classifyDatabase` judges them against the desired
  and the accepted declaration.
  Rationale: Every new grant is scoped to one database and is sent inside the existing
  database-access block, which already connects to the database. A PostgreSQL app database has
  one logical database, so the membership (next decision) is rendered exactly once. A ClickHouse
  app database may have several, and the declared privileges apply to each of them, since
  "scoped to the app's own databases" is the rule. The user members and their digests are
  untouched by a privilege change, so a change plans one update of the database member, whose
  summary names the privileges.
  Date: 2026-10-20

- Decision: The membership `GRANT <runtime> TO <migration>` is derived, never declared: it is
  on exactly when the runtime half has a `createIn` schema or `createSchemas`. It is rendered in
  the PostgreSQL database-access block, which is ordered after both user members, so both roles
  exist. The enabled rendering always sends either the `GRANT` or the `REVOKE` of the
  membership, so it depends only on the desired declaration. It is observed from
  `pg_auth_members` with its admin option, carried in the catalog as a membership between the
  app's own users rather than as a user anomaly, and judged by the database member: declared and
  held is complete, declared and absent is incomplete (the update grants it), held and only the
  accepted declaration implies it is incomplete (the update revokes it), held otherwise is drift,
  and a membership with the admin option is always drift. Memberships involving any other role
  remain user anomalies and drift. The membership is kept through retirement and quiesce, like
  schema `USAGE` and default privileges are today.
  Rationale: IR-35 AC-2 asks that the membership never be drift and never be forgotten. A
  derived membership cannot be declared inconsistently with the privileges that need it. The
  migration user has `INHERIT`, so membership gives it the runtime's rights on runtime-owned
  tables (backups, `ALTER TABLE`); `SET ROLE` is not needed and the admin option would let the
  migration user grant the runtime role to others. Keeping it through retirement is harmless
  (the migration user cannot log in) and means resume has nothing to restore.
  Date: 2026-10-20

- Decision: A declared PostgreSQL schema that does not exist yet is pending, not an error and
  not drift: the member is complete over the schemas that exist, no operation is planned for the
  missing one, and the plan prints `pending: schema <name>` through EP-206's observation note.
  The next plan after the app's migrations create the schema grants `CREATE` on it. Nagare never
  creates an app's schema.
  Rationale: PGMQ's install (`CREATE SCHEMA IF NOT EXISTS pgmq`) is the app's migration, which
  runs after the app database exists. A plan that failed on the absent schema would wedge the
  first deploy; a Nagare-created schema would be an object Nagare does not own (the EP-204
  `pg_monitor` decision). Readers already use this pending rule for views.
  Date: 2026-10-20

- Decision: The catalog observes relation owners. `renderObserveRelations` adds `owner` to each
  relation (tables, partitioned tables, views, materialized views, as today), and
  `classifyDatabase` reports a relation owned by the runtime user as drift unless its schema is
  a declared `createIn` schema or is itself owned by the runtime under `createSchemas`. A schema
  owned by the runtime is expected only under `createSchemas`; a schema owned by any other role
  but the migration user stays drift. Default privileges set by the runtime stay drift.
  Sequences and functions are not observed, as today; identity sequences are owned with their
  table.
  Rationale: IR-35 AC-3. A hand grant that let the runtime create elsewhere is drift while it
  is held, but the object it created outlives the grant; owners are the only durable evidence.
  Date: 2026-10-20

- Decision: Retirement withholds `CREATE` on the database together with `CONNECT` and
  `TEMPORARY` (one database-level revoke list), and classification of a retired database
  expects the runtime to hold nothing on the database. Schema `CREATE` and the membership stay
  through retirement and quiesce, as schema `USAGE` and the default privileges do today; they
  are unreachable without `CONNECT`. Resume on PostgreSQL reopens the login as today. On
  ClickHouse a quiesced user's grants are withheld with `REVOKE ALL ON <db>.*` as today, and
  resume grants the fixed set together with the declared privileges.
  Rationale: IR-35 AC-6 asks that the declared privileges be withheld like the fixed grants,
  and this is exactly the fixed grants' rule on each engine. No second classification branch.
  Date: 2026-10-20

- Decision: A ClickHouse privilege is a validated token, `ClickHousePrivilege`, checked at load
  for shape only (letters, single spaces, at most 48 characters, not `ALL` or `NONE`, not a
  privilege of the fixed set of the same user). The server's own privilege tree decides what
  the token means: `renderObserveClickHouse` adds one `privilege` row per entry of
  `system.privileges` (name, parent group, level), parsed into `Catalog.privilegeTree`. At plan
  time a declared token that is not in the tree, or whose level cannot be granted on a database
  (`GLOBAL` and the parameterised kinds), refuses with `MemberRefused
  "app-database-privilege-unknown"`, which names the token, before any statement is sent. Nagare
  ships no list of ClickHouse privileges.
  Rationale: IR-35 AC-4 asks for any own-database privilege without a code change. The engine
  owns the list, which changes with its version, and reading it at observation keeps Nagare
  exact across the ClickHouse upgrades EP-199 prepared. `Sql.hs` interpolates only validated
  identifiers, which the shape check preserves. Refusing at plan time with a code is the same
  exit readers use for a write path, and routes through `appDatabaseRefusal` unchanged.
  Date: 2026-10-20

- Decision: ClickHouse database grants are classified by leaf expansion. `system.grants`
  reports the minimal cover of what a user holds, so a user holding the fixed `ALTER UPDATE`
  and `ALTER DELETE` plus a declared `ALTER TABLE` reports one `ALTER TABLE` row. Both the held
  tokens and the fixed-plus-declared tokens are expanded to leaves through the observed tree
  before comparison: equal leaf sets is complete; held leaves within fixed plus desired plus
  accepted is incomplete (the update revokes); held leaves beyond that is drift; desired leaves
  missing is incomplete (the update grants). The rendering first revokes each held token that
  is not covered by fixed plus desired, exactly as `system.grants` reported it (the adapter
  takes that list from the catalog it has just read, as it does for a reader's objects), then
  grants the fixed and declared tokens in one `GRANT`. A revoke of a group also drops the fixed
  leaves under it, which the following grant restores; a revoke of a grant not held is a
  no-op, so a retry is safe.
  Rationale: Exact token comparison would make a declared group incomplete forever. Revoking
  before granting leaves the desired set and nothing else without history beyond the catalog;
  M1 proves the sequence and the exact rows.
  Date: 2026-10-20

- Decision: An owner binding is decided by the app database's declaration alone. A workload
  whose service name is in `owners` and whose `appDatabases` lists the app database receives
  `<name>-migration`; no workload-side field exists. The migration user's spec extension carries
  `owners`, emitted only when non-empty, so `acceptedAppDatabaseBindings` resolves against the
  accepted declaration, takes the deploying workload's `ServiceName` (as the reader resolver
  already does), and orders the workload after the same members as a runtime binding. A
  workload still binds one credential per engine. A retired app database refuses the binding as
  today, and a quiesced migration user binds like a quiesced runtime user (its pods fail to
  connect until resume).
  Rationale: IR-35 AC-5's verification deploys two workloads that both name the app database
  and expects one to receive the migration credential. One reviewed place, the app database's
  declaration, decides who holds the owner credential; a second, workload-side list
  (EP-206's `appDatabaseReaders` shape) would only add a way for the two to disagree. The
  owner's deploy still shows the Secret reference change in its own review.
  Date: 2026-10-20

- Decision: Scratch restore grants the declared own-database privileges on the scratch names:
  on ClickHouse the fixed set plus each user's declared privileges, on PostgreSQL `CREATE` on
  the scratch database when `createSchemas` is declared. Schema `CREATE` and relation owners
  come from the dump (`pg_dump -Fc` keeps ACLs and owners and `pg_restore` runs as the
  administrator), and the membership is server-wide. Rebuilt restore needs nothing new: the
  re-applied declaration creates the users, the membership and the database, the declared
  schemas are pending, and the restored dump brings the schemas with their `CREATE` grant and
  the runtime-owned tables, so the next plan is complete with no operations.
  Rationale: IR-35 AC-6 and the docs' promise that a scratch restore carries the app's declared
  access. IR-35's rehearsal confirmed owners survive the scratch path.
  Date: 2026-10-20

- Decision: BUG-7 (a ClickHouse restart widens the migration user's `FILE` grant into drift) is
  fixed outside this plan. M1 here does include a container restart between two observations
  for the new database-level grants, including a group, so this plan does not add a second
  grant that changes shape across a restart. On the intranet, Kansoku's ClickHouse declaration
  waits for BUG-7's fix; its PostgreSQL declaration does not.
  Rationale: The two ClickHouse app databases on the intranet cannot re-plan until BUG-7 is
  fixed, whatever this plan does; the PostgreSQL path is the one Kansoku's server is blocked
  on.
  Date: 2026-10-20

- Decision (M1): Every revocation is driven by the catalog just read, as a reader's already
  are, not sent on every converge. `DatabaseAccess` carries `revokedCreateIn`,
  `revokeDatabaseCreate`, `revokeMembership` and `revoked` (ClickHouse tokens per user); the
  grants depend only on the desired declaration. The membership `GRANT` is sent whenever it is
  derived. This supersedes "always sends either the GRANT or the REVOKE" above.
  Rationale: An app database that declares nothing renders the v0.8.0 blocks byte for byte (no
  `REVOKE` of a membership it never had, which PostgreSQL answers with a WARNING on every
  converge). Retry safety is unchanged: a lost acknowledgement re-observes, and a revoke of
  what is not held is a no-op on both engines (M1).
  Date: 2026-10-20

- Decision (M1): A declared ClickHouse token is accepted only when every leaf it stands for in
  the observed tree is at `DATABASE`, `TABLE`, `VIEW`, `DICTIONARY` or `COLUMN` level, and then
  it means exactly those leaves. Otherwise the plan refuses with
  `app-database-privilege-unknown`.
  Rationale: The server refuses a `GLOBAL` privilege `ON alpha.*` with 509 `INVALID_GRANT`, but
  silently accepts a group and grants only its database-level subset: `ACCESS MANAGEMENT ON
  alpha.*` grants the four row-policy privileges, `CREATE` and `ALTER` drop their global and
  named-collection leaves, `SYSTEM` grants 23 leaves, and `SHOW FILESYSTEM CACHES` (a
  `NULL`-level leaf) grants nothing. Accepting such a token would make the declaration say
  more than the server holds and never converge. `ALTER TABLE`, `SHOW` and the leaves are
  exact; `ACCESS MANAGEMENT` refuses, as AC-4 requires.
  Date: 2026-10-20

- Decision (M1): A relation owned by the runtime is drift unless its schema is in the desired
  `createIn` or is a runtime-owned schema under the desired `createSchemas`; the accepted
  declaration does not excuse it. Removing `createIn` while the runtime owns tables there
  therefore refuses, naming them, until the app reassigns or drops them, which the migration
  user can do through the membership (`ALTER TABLE … OWNER TO <migration>`, M1).
  Rationale: Revoking the schema `CREATE` cannot take away objects the runtime already owns;
  planning the removal would leave drift that the next plan refuses with no reviewed exit. The
  refusal names the objects and the exit is the app's own migration.
  Date: 2026-10-20

- Decision: The backup schedule's declaration digest keeps leaving `access` out (EP-204), so
  declaring privileges or owners keeps the schedule revision and earlier runs stay prunable.
  Rationale: A backup holds no grant or binding bytes; restore re-applies them from the
  accepted scope.
  Date: 2026-10-20


## Outcomes & Retrospective

(None yet.)


## Context and Orientation

Nagare is a single-node PaaS driven by `nagarectl`, a Haskell CLI under `cli/nagarectl/`. Its
declaration types live in the `nagare-dsl` package under `cli/nagare-dsl/`. Every change is a
saved, reviewed plan that `nagarectl inventory apply DIR --yes` executes. Read
[EP-202](202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md),
[ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md),
[EP-204](204-let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits.md) and
[EP-206](206-give-app-databases-reviewed-read-only-consumer-users.md) first; this plan extends
their mechanisms and uses their vocabulary.

An **app database** is the inventory scope `appdb-<key>`, a tenant of a shared PostgreSQL or
ClickHouse server. Its members are credential Secrets `<name>-runtime` and `<name>-migration`
(plus one per reader), users `<name_with_underscores>_runtime` and `_migration` (plus readers),
one **logical-database member** per declared database, and a backup schedule. The **declaration**
is the `AppDatabase` record a config emits; the **accepted declaration** is what the last
reviewed plan recorded, kept in inventory history as the members' specs. **Drift** is access the
server holds that neither the desired nor the accepted declaration explains; it is never
repaired, and planning refuses it with `app-database-grant-drift`. A member that is short of its
declaration is **incomplete**, and the planned update converges it. A declared object the server
does not have yet is **pending**, which plans no operation and prints a note. An
**own-database privilege** is one scoped to the app's own databases: a PostgreSQL schema or
database privilege inside the app's one database, or a ClickHouse privilege `ON <db>.*`. The
**membership** is PostgreSQL role membership, `GRANT <runtime> TO <migration>`, which lets the
migration user act on tables the runtime owns. An **owner binding** injects the migration
credential into a workload instead of the runtime credential. In ClickHouse, privileges form a
**tree**: a **group** such as `ALTER TABLE` stands for its children (`ALTER UPDATE`, `ALTER ADD
COLUMN`, …), and a **leaf** has no children; `system.privileges` lists every privilege with its
parent group and the finest level it can be granted at.

Where each part lives today:

- **Declaration.** `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs` defines `AppDatabase`
  (name, logicalKey, server, engine, namespace, logicalDatabases, access),
  `AppDatabaseAccess { runtime, migration :: UserAccess, monitoring :: [MonitoringRole],
  readers :: [AppDatabaseReader] }`, `UserAccess { exceptions, limits }`, the validated
  identifiers `SchemaName` and `RelationName` (`[a-z][a-z0-9_]{0,62}`), the roles
  (`AppDatabaseRole`, `parseAppDatabaseRole`, `appDatabaseRoles`), the derived names, and the
  fixed grants: `appDatabaseAttributes`, `appDatabaseServerGrants` (only the ClickHouse migration
  user's `WRITE ON FILE`) and `appDatabaseDatabaseGrants` (the per-engine lists quoted in
  Purpose). `validateAppDatabase` and `validUserAccess :: Engine -> UserAccess -> Either Text ()`
  check the rules that span fields. Every JSON instance writes a key only when it has a value and
  refuses an unknown key, so a declaration without new fields keeps its bytes.
  `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` (`appDatabaseJSON`) emits the declaration and
  `cli/nagare-dsl/src/Nagare/Dsl/Load/AppDatabase.hs` decodes it. The workload side,
  `appDatabases :: [AppDatabaseName]` and `appDatabaseReaders`, is on the deployment record in
  `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` (near line 745) and on workers in
  `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`.
- **Members.** `compileAppDatabase` in `cli/nagare-dsl/src/Nagare/Resource/AppDatabase.hs`
  builds, per role, a credential member and a user member with spec
  `DatabaseUserSpec engine roleToken login digest (UserExtension access reader)`, and per
  logical database a member with spec
  `LogicalDatabase engine migration runtime enabled digest monitoring`, ordered after the
  server, the migration user and the runtime user. Both constructors are in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`. The user digest adds an `access` key
  only when declared; the database digest adds `monitoring` only when non-empty. The specs'
  hand-written codec is in `cli/nagare-dsl/src/Nagare/Resource/Wire.hs` near line 375: a
  `DatabaseUserSpec` has four or five positional elements and a `LogicalDatabase` five or six,
  the last written by omission when empty, so accepted v0.7.1 and v0.8.0 history decodes
  unchanged. Spec validity is in `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` near line
  225. `UserExtension` is encoded as the `UserAccess` object plus a `reader` key.
- **SQL.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`. Every interpolated name is a
  validated identifier, so quoting needs no escaping. `renderUserAccess` renders a user's login,
  server grants, exceptions and limits; `renderDatabaseAccess` takes a `DatabaseAccess` record
  (engine, initial database, database, migration, runtime, enabled, monitoring, withheld,
  readers) and renders the database's grants, on PostgreSQL inside a `\connect`; it has an
  enabled and a disabled rendering per engine. `renderScratchRestore` grants the fixed access on
  scratch names. `renderObserveServer` reads PostgreSQL roles, memberships (role and member
  only), database ACLs and foreign access; `renderObserveDatabase` reads schema owners, schema
  ACLs and default ACLs; `renderObserveRelations` reads every table and view outside the system
  schemas with the scope users' grants, and every `SECURITY DEFINER` function, and runs for
  every PostgreSQL app database. `renderObserveClickHouse` returns tagged JSONEachRow rows:
  `user`, `grant` (every `system.grants` row of the app's users anywhere and of anyone on the
  app's databases), `role`, `setting` and `database`.
- **Classification.** `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs` parses the
  observations into `Catalog { users, databases, publicSystemAccess }`. `CatalogUser.anomalies`
  holds facts that are drift by themselves, and today includes every membership that names one
  of the app's users (`"membership <role> > <member>"`). `CatalogDatabase` holds the database's
  grants (`CatalogGrant grantee target privilege`, targets `database`, `schema:<name>` and
  `default-<objects>`), `schemaOwners`, `defaultAclRoles`, `relations` (`CatalogRelation
  schema name kind options grants`, no owner) and `definerFunctions`. `classifyUser` applies
  EP-204's one rule to a user's items; `classifyDatabase :: DatabaseAccess -> Catalog ->
  MemberState` has no accepted declaration: on ClickHouse any held database grant beyond the
  fixed set is `grants beyond the declared set` drift, and on PostgreSQL `postgresGrant` is
  drift for any grantee but the two users, `PUBLIC`, `pg_database_owner`, a declared reader's
  `CONNECT` and `USAGE`, and a declared monitoring role's read-only grants; a schema other than
  `public` owned by anyone but the migration user is drift (`foreignSchemas`). `classifyReader`
  returns a state and a pending list. `MemberState` is absent, complete, incomplete, drift, or
  `MemberRefused code reason`.
- **Adapter.** `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs`. `MemberKind` is
  `UserMember role user secretNs secretName extension` or `DatabaseMember db migration runtime
  monitoring`; `AppDatabaseMember` adds the server, enabled, scope users and databases,
  quiesced, withheld and readers, derived from the scope's siblings in
  `appDatabaseMembersFromDeclarations`. `CatalogCommand` is `CreateUser`, `SetUserAccess`,
  `SetReaderAccess`, `CreateDatabase`, `SetDatabaseAccess DatabaseAccess` and `SetPassword`.
  `mkAppDatabaseAdapter accepted members ops` observes, classifies and converges; it reads the
  accepted spec of a user from `accepted` (`acceptedAccess`) and computes a reader's revocations
  from the catalog it has just read (`accessCommand`). A pending list becomes an observation note
  (`pending: …`), printed by `db app-database plan` on stderr and shown by `inventory status`.
  The operation `summary` names each exception, limit and reader object. The kubectl transport
  is `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabaseRuntime.hs`.
- **Refusal routing.** `appDatabaseRefusal` in `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`
  turns any `ObservationUnavailable` reason that starts with `app-database-<code>: ` into a plan
  error under that code. Nothing there changes.
- **Bindings.** `acceptedAppDatabaseBindings` in
  `cli/nagarectl/src/Nagare/Inventory/Application/Bindings.hs` resolves each name in a
  workload's `appDatabases` to the `<name>-runtime` Secret in the namespace, refuses a retired
  app database (the runtime user's login is closed), and orders the workload after every
  non-reader member of the scope; its comment says the migration credential is never bindable.
  `acceptedAppDatabaseReaderBindings` takes the deploying workload's `ServiceName` and checks the
  reader's `consumers`. Both are called from `cli/nagarectl/app/Nagare/Cli/Application/Inputs.hs`
  near line 116. `AppDatabaseBound` in `cli/nagarectl/src/Nagare/Inventory/Application/Types.hs`
  carries the Secret name, and `appDatabase` in
  `cli/nagarectl/src/Nagare/Inventory/Application/Environment.hs` injects the variables from it;
  `mergeConnectionEnvs` refuses two bindings of one engine.
- **Backups and restores.** `appDatabaseDumpShell` in `cli/nagarectl/src/Nagare/Database/Backup.hs`
  runs `pg_dump -Fc` as the migration user, keeping owners and ACLs. In
  `cli/nagarectl/src/Nagare/Inventory/AppDatabaseRestore.hs`, `appDatabaseRestoreShell` creates
  the scratch database with `renderScratchRestore` and loads the dump with `pg_restore
  --exit-on-error` as the administrator; `appDatabaseRebuiltShell` loads it into the re-applied
  empty databases.
- **Tests and smoke.** `cli/nagarectl/test/AppDatabaseSqlSpec.hs` pins every rendering byte for
  byte to a `-- operation: NAME` block of the fixtures and classifies the captured observations
  in `cli/nagarectl/test/fixtures/app-database/observed/`. `cli/nagarectl/test/AppDatabaseSpec.hs`
  covers load, compile, bindings and schedules. `cli/nagarectl/test/AppDatabaseWorldSpec.hs` runs
  the adapter against the interpreter world in
  `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs`, whose `WorldDatabase` holds grants,
  schema owners, relations and functions, and whose `interpret` applies each `CatalogCommand`
  with the semantics M1 proved, under an adversary that refuses statements, loses
  acknowledgements and kills the executor. `scripts/local-app-database-smoke.sh`
  (`NAGARE_SMOKE_CONTEXT=NAME NAGARECTL=… scripts/local-app-database-smoke.sh`) runs four app
  databases on two local servers through staged configs (`none`, `declared`, `removed`,
  `retired`), probe Workers, and every EP-202 to EP-207 assertion.
- **Docs.** The "Sharing one server between apps" section of `docs/user/managed-databases.md`,
  whose "Reviewed exceptions and limits" and "Read-only readers" subsections this plan extends.

Relevant ADRs:

- [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md): the tenant
  model; the declaration is the authority for users and grants, undeclared access is drift, a
  workload binds one database per engine, backups dump with the migration credential and keep
  object ACLs. This plan adds the rule that own-database privileges are declarable while
  server-wide and cross-app access are not, and records it as ADR 31 in M6.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): the
  interpreter world and the fixtures find defects; the smoke only confirms.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
  every transport call checks the server's recorded identity first; unchanged here.

PGMQ's install, which this plan's PostgreSQL example follows, is
`mori://shinzui/pgmq-hs` at `pgmq-migration/migrations/0001-install-v1.11.0.sql`: it runs
`CREATE SCHEMA IF NOT EXISTS pgmq` and defines `pgmq.create`, which creates
`pgmq.q_<queue>` and `pgmq.a_<queue>` with their indexes and inserts into `pgmq.meta`, all as
the caller. The queue tables are therefore owned by whoever first calls `pgmq.create`.


## Plan of Work

**M1, engine proof.** Prove every new statement and observation by hand before writing Haskell,
as EP-202, EP-204 and EP-206 did. Use `postgres:18` and `clickhouse/clickhouse-server:26.8`
containers with the server render's environment, the fixtures' `alpha` and `beta` app databases,
and append `-- operation:` blocks to `cli/nagarectl/test/fixtures/app-database/postgres.sql`
and `clickhouse.sql`. Capture the observation outputs under `observed/`.

PostgreSQL questions:

- **Schema CREATE.** After PGMQ's schema exists (the existing `pgmq-install` block runs as
  `alpha_migration`), does `GRANT CREATE ON SCHEMA "pgmq" TO "alpha_runtime"` let the runtime run
  `SELECT pgmq.create('events')`? Confirm the queue tables, indexes and `meta` row are created
  and that `pgmq.q_events` is owned by `alpha_runtime`. Confirm the runtime is still refused in
  `public` and in a second migration-owned schema.
- **Membership.** Without `GRANT "alpha_runtime" TO "alpha_migration"`, does `pg_dump -Fc` as
  the migration user fail on the queue table, and does `ALTER TABLE pgmq.q_events ADD COLUMN`
  fail with `must be owner`? With it, do both succeed? What does `pg_auth_members` report for
  the pair (`admin_option`, `inherit_option`, `set_option`)? Does `REVOKE "alpha_runtime" FROM
  "alpha_migration"` when there is no membership complete under `ON_ERROR_STOP` (a warning, not
  an error)?
- **Database CREATE.** After `GRANT CREATE ON DATABASE "alpha" TO "alpha_runtime"`, can the
  runtime `CREATE SCHEMA scratch` and a table in it? Is the schema owned by the runtime in
  `observe-database`? Does `REVOKE CREATE ON DATABASE` leave the schema and its tables in place?
- **Observation.** Extend `observe-server` so each membership row carries `admin`, and
  `observe-relations` so each relation carries `owner`. Capture both after the queue exists.
  Confirm `observe-database` reports `CREATE` for the runtime on `schema:pgmq` and, under
  database CREATE, on `database`.
- **Backup and restore.** Run the `backup` block (`pg_dump -Fc` as `alpha_migration`) with the
  membership in place, then `restore-scratch` as the administrator into `alpha_restore_m1`:
  are the queue table's owner and rows intact? Run `restore-rebuilt` into a fresh `alpha` after
  re-running `database-access alpha on with privileges`: is the schema's `CREATE` grant back
  from the dump and the owner kept?
- **Retirement.** Does `REVOKE CONNECT, TEMPORARY, CREATE ON DATABASE "alpha" FROM
  "alpha_runtime"` leave the schema grant and the membership in place, and does the enabled
  block restore the database grants exactly?

Write the blocks `database-access alpha on with privileges` (schema CREATE on `pgmq`, database
CREATE, membership grant), `database-access alpha on with privileges removed` (the revokes of a
schema's CREATE and of the membership, with the database grants as the fixed set), and
`database-access alpha off with privileges`.

ClickHouse questions:

- **The tree.** Capture `SELECT privilege, parent_group, level FROM system.privileges ORDER BY
  privilege FORMAT JSONEachRow` as `observed/clickhouse-privileges.jsonl`. Which levels can be
  granted `ON alpha.*`? Confirm by granting one privilege of each level: a `GLOBAL` one
  (`ACCESS MANAGEMENT`) must be refused, and record the exact error code and message.
- **Round trip.** For `CREATE TABLE`, `DROP TABLE`, `CREATE VIEW`, `DROP VIEW`, `TRUNCATE`,
  `OPTIMIZE`, `ALTER TABLE` and `ALTER` granted `ON alpha.*` to `alpha_runtime`: what rows does
  `system.grants` report? Which tokens come back under another name (an alias)?
- **Groups.** With the fixed runtime set held, grant `ALTER TABLE ON alpha.*`: does
  `system.grants` report one `ALTER TABLE` row and no `ALTER UPDATE` or `ALTER DELETE` rows?
  Then `REVOKE ALTER TABLE ON alpha.* FROM alpha_runtime` followed by the fixed `GRANT`: are the
  rows exactly the fixed set again?
- **Isolation.** With `CREATE TABLE` and `DROP TABLE` declared, can the runtime create and drop
  a table in `alpha` and in `alpha_ledger`, and is the same in `beta` refused with code 497? Is
  `CREATE TABLE alpha.u (s String) ENGINE = URL('http://example.invalid/', CSV)` refused, since
  no source privilege is granted?
- **Restart.** Restart the container with the grants above in place and observe again: are the
  rows identical? This is the BUG-7 class of defect, checked here for the new grants only.
- **Withheld and resume.** After `REVOKE ALL ON alpha.* FROM alpha_runtime` (quiesce), does one
  `GRANT <fixed>, CREATE TABLE, DROP TABLE ON alpha.* TO alpha_runtime` restore exactly the
  expected rows?

Write the blocks `database-access alpha on with privileges`, `database-access alpha on with
privileges removed` (a held `ALTER TABLE` revoked, then the fixed and declared grant) and
`observe` extended with the `privilege` rows; the `restore-scratch` block gains the declared
privileges on the scratch names.

**M2, declaration.** In `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`:

- Add `ClickHousePrivilege` (validated token, `mkClickHousePrivilege`,
  `clickHousePrivilegeText`), `OwnPrivileges { createIn :: ![SchemaName], createSchemas ::
  !Bool, clickhouse :: ![ClickHousePrivilege] }` with `noOwnPrivileges`, `DatabasePrivileges
  { runtime, migration :: !OwnPrivileges }` with `noDatabasePrivileges`, and the fields
  `privileges :: !DatabasePrivileges` and `owners :: ![ServiceName]` on `AppDatabaseAccess`.
  `noAppDatabaseAccess` sets both empty. Export `runtimeOwnsObjects :: AppDatabaseAccess ->
  Bool`, true when the runtime half names a schema or `createSchemas`.
- JSON: `privileges` is emitted only when either half is non-empty, each half only when
  non-empty, each field only when set; `owners` only when non-empty. Decoding refuses unknown
  keys as the other objects do.
- `validateAppDatabase` refuses: `createIn` or `createSchemas` on a ClickHouse app database or on
  the migration half; `clickhouse` on a PostgreSQL app database; a repeated schema, token or
  owner; and a token that is `ALL` or `NONE`, or that already appears in that user's fixed
  database grants (`appDatabaseDatabaseGrants`). An owner may also be a reader consumer of the
  same app database (the Secrets differ), so no rule is needed there.

Extend `appDatabaseJSON` and the loader with the new keys. The backup schedule's declaration
digest already leaves `access` out, so nothing changes there.

**M3, PostgreSQL privileges and membership.**

- **Specs.** `LogicalDatabase` gains a seventh positional element, the `DatabasePrivileges`,
  written by omission when empty (extend the codec in `Wire.hs` and spec validity in
  `Inventory.hs`, which checks the privileges fit the engine). In `compileAppDatabase` the
  database digest adds `"privileges"` only when non-empty, and the migration user's
  `UserExtension` gains `owners` (M5 uses it; add the field now so the codec changes once).
- **SQL.** `DatabaseAccess` gains `privileges :: !DatabasePrivileges`, `createIn :: ![Text]`
  (the declared schemas that exist now), `revokedCreateIn :: ![Text]` (schemas holding the
  runtime's `CREATE` that the declaration no longer names), `membership :: !Bool` and
  `revoked :: ![(Text, Text)]` (M4). The PostgreSQL enabled rendering grants `CONNECT,
  TEMPORARY` plus `CREATE` when `createSchemas` on the database, then inside the database
  `GRANT CREATE ON SCHEMA <s>` per `createIn` and `REVOKE CREATE ON SCHEMA <s>` per
  `revokedCreateIn`, always `REVOKE CREATE ON DATABASE` when not declared, and always the
  membership `GRANT` or `REVOKE`. The disabled rendering revokes `CONNECT, TEMPORARY, CREATE` on
  the database and nothing else. `renderObserveServer` adds `admin` to each membership row and
  `renderObserveRelations` adds `owner`. Each rendering is pinned to an M1 block.
- **Catalog.** `Catalog` gains `memberships :: [(Text, Text, Bool)]` (role, member, admin) for
  pairs among the scope's users; other memberships stay user anomalies. `CatalogRelation` gains
  `owner`. `classifyDatabase` takes a `DatabaseDeclaration { desired :: DatabaseAccess, accepted
  :: Maybe DatabaseAccess }` and returns the state with a pending schema list. `postgresGrant`
  accepts the runtime's `CREATE` on a declared schema, on a schema the accepted declaration
  named (incomplete), and on the database under `createSchemas`; the membership follows the
  Decision Log; `foreignSchemas` tolerates runtime-owned schemas under `createSchemas`; a
  runtime-owned relation outside the declared and runtime-owned schemas is drift naming the
  relation.
- **Adapter.** `DatabaseMember` carries the privileges. `accessOf` computes `createIn`,
  `revokedCreateIn` and `membership` from the catalog just read and the accepted spec (read
  from `accepted`, as `acceptedAccess` does for users). The pending schemas become the member's
  note, `pending: schema pgmq`. The summary names `createIn`, `createSchemas` and
  `migration member of runtime`.
- **World.** `WorldDatabase` gets per-relation owners and a server-level membership set;
  `interpret` applies the new statements with M1's semantics (a `CREATE` on a missing schema
  stops the block; the membership grant and revoke are idempotent). Add helpers that create a
  schema as the migration user, a table as the runtime user, and a hand grant, and the tests
  listed in Validation.

**M4, ClickHouse own-database privileges.**

- **Observation.** `renderObserveClickHouse` adds the `privilege` rows; `Catalog` gains
  `privilegeTree :: Map Text (Maybe Text, Text)` (parent group, level), empty on PostgreSQL.
  Export `expandPrivileges :: Map Text (Maybe Text, Text) -> [Text] -> Set Text` (leaves) and
  `grantableOnDatabase :: Map Text (Maybe Text, Text) -> Text -> Bool`.
- **Classification.** `classifyDatabase` on ClickHouse: a declared token not grantable on a
  database refuses with `app-database-privilege-unknown` (the reason names the token and the
  user); otherwise compare leaf sets as the Decision Log states, per user, with withheld users
  expected to hold nothing.
- **SQL and adapter.** The ClickHouse enabled rendering sends, per user, `REVOKE <t> ON <db>.*`
  for each `revoked` token, then `GRANT <fixed>, <declared> ON <db>.* TO <user>` (or `REVOKE
  ALL` for a withheld user). `accessOf` fills `revoked` from the catalog: each held token whose
  leaves are not all within fixed plus desired. `renderScratchRestore` grants fixed plus
  declared on the scratch names. The summary names each user's tokens.
- **World.** The world loads `observed/clickhouse-privileges.jsonl` as its tree, stores held
  grants as leaf sets, and reports them compressed as `system.grants` does (the minimal cover
  from the tree), so the interpreter exercises the same expansion the catalog does.

**M5, owner bindings.** `acceptedAppDatabaseBindings` takes the deploying workload's
`ServiceName`. For each name in `appDatabases`, if the accepted migration user's extension
lists that service in `owners`, resolve the `<name>-migration` Secret (checking its template's
role is `migration`), otherwise `<name>-runtime` as today. `AppDatabaseBound.appCredentialName`
carries whichever was chosen; ordering and the retired check are unchanged. Update the two
callers in `Inputs.hs` and the tests. `appDatabases` in a config is untouched. The user-member
summary names `owners`.

**M6, lifecycle, docs and ADR.**

- **Rotation** is unchanged; a test confirms the privileges, membership and owners survive it.
- **Retirement, quiesce and resume**: world tests on both engines, with the privileges declared,
  confirm the Decision Log's withholding rule and that resume re-plans to no operations.
- **Restores**: a scratch restore of an app database with a runtime-owned table classifies
  complete beside the live one and keeps the owner (interpreter); a rebuilt restore after
  re-apply ends with `no operations`.
- **Docs.** In `docs/user/managed-databases.md`, add a subsection "Privileges inside the app's
  own databases" after "Reviewed exceptions and limits" with: the rule (own-database privileges
  are declarable; server-wide and cross-app access are not); the PostgreSQL declaration, the
  derived membership and why it exists, the pending rule, and that objects the runtime creates
  are expected only inside declared schemas; the ClickHouse declaration, that the engine's own
  privilege list decides, and that groups converge; owner bindings, with the change to the
  sentence that the migration credential is never bindable; and the PGMQ startup-queue example.
  Correct the comment on `acceptedAppDatabaseBindings` to match.
- **ADR 31**, `docs/adr/0031-own-database-privileges-are-declarable-server-wide-access-is-not.md`,
  in the local filesystem convention of `docs/adr/` (no OKF profile there): the rule, the
  derived membership, the pending rule, the engine-owned ClickHouse privilege list, and owner
  bindings, with ADR 30 as related.

**M7, native confirmation.** Extend `scripts/local-app-database-smoke.sh`:

- In the `declared` and later stages, `alpha-pg` declares `createIn = [pgmq]` on the runtime
  half and `owners = [gamma-pg-probe]`; `alpha-ch` declares `clickhouse = [CREATE TABLE, DROP
  TABLE]` on the runtime half.
- After the EP-204 step: as `alpha-pg`'s migration user, create schema `pgmq` with a `meta`
  table (the existing PGMQ grant step already runs there); re-plan and assert the note
  `pending: schema pgmq` is gone and the plan granted `CREATE`; as the runtime, create
  `pgmq.q_smoke` and insert a row; assert `has_schema_privilege('alpha_runtime', 'pgmq',
  'CREATE')`; as the migration user, `ALTER TABLE pgmq.q_smoke ADD COLUMN note text`; re-plan to
  `no operations`; as the runtime, attempt `CREATE TABLE public.t ()` and assert `permission
  denied`.
- Probe `gamma-pg-probe` (already deployed as the reader consumer) also lists `alpha-pg` in
  `appDatabases`: assert its render references `alpha-pg-migration` and no `-runtime` Secret,
  and that `alpha-pg-probe` still references `alpha-pg-runtime`.
- ClickHouse: as `alpha-ch`'s runtime, create and drop `alpha.t_smoke`, and assert `CREATE
  TABLE beta.t_smoke` fails with code 497.
- The later steps (rotation, retirement of `beta-ch`, the scheduled backup of `alpha-pg` and its
  scratch restore) then run with the declaration in force; after the scratch restore, assert
  the restored `pgmq.q_smoke` is owned by `alpha_runtime` and holds its row.

**M8, release.** Follow `docs/runbooks/releases.md`: upgrade the intranet on the candidate, then
tag. In `mori://tan/tan-ng-labs`, Kansoku's PostgreSQL app database declares `createIn =
[pgmq]`; the plan shows the database update and the membership; apply; `kansoku-server` starts
as the runtime. Record the resolution and `targetPlan` in IR-35's frontmatter and add a line to
`docs/improvement-requests/log.md`.


## Concrete Steps

M1, from the repository root, with Colima or Docker running:

```bash
docker run -d --name ep208-pg -e POSTGRES_USER=nagare -e POSTGRES_PASSWORD=pw postgres:18
docker run -d --name ep208-ch -e CLICKHOUSE_USER=nagare -e CLICKHOUSE_PASSWORD=pw \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 clickhouse/clickhouse-server:26.8
```

Replay the existing fixture blocks in order (split on `-- operation:` as the fixture headers
describe), then each new block, and capture the observation queries' output into
`cli/nagarectl/test/fixtures/app-database/observed/`. For the restart question:

```bash
docker restart ep208-ch && sleep 5   # then re-run the observe block and diff the grant rows
```

Remove the containers afterwards with `docker rm -f ep208-pg ep208-ch`.

For each Haskell commit (the three app-database test groups match one pattern):

```bash
cd cli/nagarectl && cabal test nagarectl-test --test-options="-p AppDatabase"
cd ../.. && just haskell-style-check && just gate-fast HEAD
```

Land with `just land HEAD`. Every commit carries the trailer
`ExecPlan: docs/plans/208-let-an-app-database-declare-its-runtime-s-privileges-inside-its-own-databases.md`.

M7, from an empty environment against a `mode=local` context, with the packaged CLI built from
the landed revision:

```bash
nix build --no-link --print-out-paths "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl"
NAGARE_SMOKE_CONTEXT=transition NAGARECTL=<out>/bin/nagarectl scripts/local-app-database-smoke.sh
```

The run should print these new lines and end with `PASS`:

```text
… app-database smoke: IR-35: alpha-pg runtime created its pgmq queue under declared CREATE; migration altered it; owner probe holds the migration Secret; alpha-ch runtime created and dropped its own table, beta refused
… app-database smoke: IR-35: scratch restore kept the runtime-owned queue and its row
app-database smoke: PASS
```


## Validation and Acceptance

- **AC-1.** A loader test refuses `createIn` on a ClickHouse app database and on the migration
  half, and a plan test over a PostgreSQL app database declaring `createIn = [pgmq]` shows one
  update of database `alpha` whose summary names `createIn pgmq` and `migration member of
  runtime`. In the world: with schema `pgmq` present, apply grants `CREATE`; the catalog shows
  the runtime holding `CREATE` on `schema:pgmq`; a re-plan prints `no operations`. The same
  grant made by hand without the declaration refuses with `app-database-grant-drift: … runtime
  holds CREATE on schema:pgmq`. With the schema absent, the plan prints `pending: schema pgmq`
  and no operation for it; after the schema appears, the next plan grants it.
- **AC-2.** In the world, after AC-1 the runtime creates `pgmq.q_events` (owner runtime); the
  scheduled backup's dump as the migration user and an `ALTER TABLE` as the migration user are
  modelled as requiring the membership, and both succeed; the membership is observed and the
  re-plan has no operations. A hand `REVOKE` of the membership re-plans to an update that
  restores it; a hand membership with `ADMIN OPTION` is drift. Natively (M7), `pg_dump` and
  the `ALTER TABLE` succeed and the scratch restore keeps the owner and the row.
- **AC-3.** After AC-2, re-plan: no operations. A table created by the runtime in an
  undeclared schema (through a temporary hand grant that is then revoked) refuses with
  `app-database-grant-drift: … runtime owns <schema>.<table>`. Under `createSchemas`, a
  runtime-created schema and its tables are expected.
- **AC-4.** In the world and the fixture: `CREATE TABLE` and `DROP TABLE` declared for the
  runtime grant on `alpha` and `alpha_ledger`; the runtime creates and drops in both and is
  refused in `beta` (497, natively in M7). A declared `ALTER TABLE` over the fixed `ALTER UPDATE,
  ALTER DELETE` converges and re-plans to no operations. Removing it plans an update whose
  execution revokes `ALTER TABLE` and re-grants the fixed set; the next plan has no operations.
  A declared `ACCESS MANAGEMENT` refuses with `app-database-privilege-unknown`. A hand
  `GRANT TRUNCATE ON alpha.*` is drift.
- **AC-5.** A render test deploys `gamma` (declared owner) and `delta` (undeclared), both
  naming `alpha-pg`: `gamma`'s render references only `alpha-pg-migration`, `delta`'s only
  `alpha-pg-runtime`; the injected variable names are identical. A third app `epsilon` has no
  way to name the migration credential: its render with `appDatabases = [alpha-pg]` references
  `alpha-pg-runtime`, and no deployment field can request the migration Secret.
- **AC-6.** The world runs the EP-202 matrix (every interruption and drift case, rotation,
  retirement, quiesce and resume, server rebuild, scratch restore) in a "with own privileges"
  variant on both engines, asserting the observed grants, membership and owner bindings equal
  the declaration at each step.
- **AC-7.** `docs/user/managed-databases.md` states the rule, shows both declarations, the
  membership consequence, the pending rule, owner bindings and the PGMQ example.

**Transition.** A test decodes the accepted `appdb-*` scope records of a v0.8.0 context (captured
with `nagarectl inventory export --out DIR` from the M7 context before the upgrade, as
`cli/nagarectl/test/fixtures/app-database/v0.8.0/`) and re-encodes them byte-identically, and
compiles the unchanged declarations to members equal to the accepted ones.


## Idempotence and Recovery

Every change is a reviewed plan, and re-planning an unchanged declaration prints
`no operations`. The PostgreSQL statements are idempotent: a repeated `GRANT` or `REVOKE` of a
privilege or a membership is a no-op (a `REVOKE` of a membership that is not held warns and
continues). The ClickHouse revoke-then-grant sequence ends in the declared set from any starting
point among the states review can reach, and a revoke of a grant not held is a no-op, so a
lost acknowledgement retries safely. The world tests prove both under the adversary.

A failed apply resumes with `nagarectl inventory resume TX --yes`. A pending schema never blocks
an apply. The M1 containers and the M7 context are disposable.


## Interfaces and Dependencies

- `Nagare.Dsl.AppDatabase` gains `ClickHousePrivilege`, `OwnPrivileges`, `DatabasePrivileges`,
  `noOwnPrivileges`, `noDatabasePrivileges`, `runtimeOwnsObjects`, the fields
  `AppDatabaseAccess.privileges` and `AppDatabaseAccess.owners`, and `UserExtension.owners`.
  `validUserAccess` is unchanged; the new rules live in `validateAppDatabase`.
- `LogicalDatabase` in `Nagare.Resource.Inventory.Types` gains a seventh field. It is matched
  in `Nagare.Resource.AppDatabase`, `Nagare.Resource.Inventory`, `Nagare.Resource.Wire`,
  `Nagare.Inventory.Adapters.AppDatabase`, `Nagare.Inventory.AppDatabase`, and the tests
  `AppDatabaseSpec` and `InventoryRebuildSpec`.
- `Nagare.Database.AppDatabase.Sql.DatabaseAccess` gains `privileges`, `createIn`,
  `revokedCreateIn`, `membership` and `revoked`; it is constructed in the adapter, the SQL
  spec and the world. `renderScratchRestore` takes the declared privileges.
- `Nagare.Database.AppDatabase.Catalog` gains `Catalog.memberships`, `Catalog.privilegeTree`,
  `CatalogRelation.owner`, `DatabaseDeclaration`, `expandPrivileges`,
  `grantableOnDatabase` and the code `app-database-privilege-unknown`; `classifyDatabase`
  takes a `DatabaseDeclaration` and returns a pending list.
- `Nagare.Inventory.Application.Bindings.acceptedAppDatabaseBindings` takes the deploying
  `ServiceName`; both callers in `Nagare.Cli.Application.Inputs` change.
- `Nagare.Inventory.Plan.Changes` is unchanged. No new CLI constructor, so
  `scripts/audit-managed-commands.py` needs nothing. No new libraries.
- M8 depends on BUG-7 only for the intranet's ClickHouse app databases; the PostgreSQL
  declaration for Kansoku does not wait for it.
