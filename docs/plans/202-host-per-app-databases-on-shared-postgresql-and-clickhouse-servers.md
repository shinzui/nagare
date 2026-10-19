---
id: 202
slug: host-per-app-databases-on-shared-postgresql-and-clickhouse-servers
title: "Host per-app databases on shared PostgreSQL and ClickHouse servers"
kind: exec-plan
created_at: 2026-10-19T03:37:28Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-19T03:37:28Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-19T03:57:26Z
      mode: "update"
      note: "Validated against the working tree: DesiredSpec constructors, app-database credential template and key set, Deployment and Worker fields, Worker probes in the smoke, checkedPhysical accessor"
---

# Host per-app databases on shared PostgreSQL and ClickHouse servers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan implements improvement request IR-29,
[`docs/improvement-requests/shared-database-servers-with-per-app-databases.md`](../improvement-requests/shared-database-servers-with-per-app-databases.md).
Its acceptance criteria AC-1 to AC-5 are this plan's acceptance criteria. Each milestone below
names the criteria it proves.


## Purpose / Big Picture

The intranet runs every app on one small VM. The operator wants one PostgreSQL server and one
ClickHouse server for the whole cluster. Each app should get its own database on those servers,
with its own credentials, and no app should be able to reach another app's data. Today Nagare
cannot do this. A managed database *is* its server: it has one generated user, `nagare`, and one
Secret, `nagare-db-<name>`. Every app that lists the database receives that Secret, which on
PostgreSQL is a superuser credential. Backups dump only the server's initial database, so other
databases on the server are never backed up. The first consumer, Kansoku, is blocked at its
Milestone 2 until this exists
(`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`).
This plan moves the operator's requirement that "developers can deploy" for the first real app
that needs it.

After this plan, an operator declares an **app database** in an app's repository, for example
`kansoku-pg` on server `labs-postgres`. One reviewed inventory transaction creates three things
inside the existing server: the logical database, a runtime user and a migration user, each with
grants confined to that database. It also creates two Secrets, `kansoku-pg-runtime` and
`kansoku-pg-migration`. The app's `Config.hs` lists `appDatabases = ["kansoku-pg"]`, and a
deploy injects only the runtime Secret. A scheduled backup covers that app database. One app's
backup can be restored into a scratch database without touching any other app. You see it
working when the two-app local smoke test,
`just local-app-database-smoke`, prints `app-database smoke: PASS` on a k3d context. The test
checks own-database access, cross-app denial in both directions on both engines, and the backup
and scratch restore of each app.


## Progress

- [x] M1 (prototype). The SQL that creates, grants, observes, rotates, retires, backs up and
  restores an app database is proven by hand against the real PostgreSQL 18 and ClickHouse 26.8
  images on a local context. It is committed as reference fixtures under
  `cli/nagarectl/test/fixtures/app-database/`, and the answers to the open engine questions are in
  the Decision Log. Proves the engine half of AC-3.
  Done 2026-10-19. Evidence: `postgres:18` and `clickhouse/clickhouse-server:26.8` (26.8.29)
  containers with the server render's env (`PGDATA`, admin `nagare`, access management on). Both
  fixtures were replayed block by block (`awk` on `-- operation:`) on fresh volumes, and every block
  exited 0. Password checks used the non-loopback pod IP. Results, with alpha and beta as the two apps:
  - Each user reaches its own database. Every cross-app connect, SELECT, INSERT, CREATE TABLE,
    CREATE DATABASE and BACKUP is refused in both directions, on PostgreSQL with `permission
    denied for database` and on ClickHouse with code 497.
  - `CREATE ROLE/USER`, `GRANT` to self, `ALTER ROLE ... SUPERUSER` and `SYSTEM SHUTDOWN` are
    refused for both users. ClickHouse `system.query_log`, `system.processes`, `file()` and
    `url()` are refused.
  - Rotation rejects the old password and accepts the new one.
  - Retiring beta leaves alpha's ClickHouse `system.grants` md5 identical (`d3a15368…`).
  - The PostgreSQL dump by the migration user restores into scratch and into a rebuilt empty
    database with its rows, ACLs and sequence position. The ClickHouse two-database archive
    restores into scratch names and into existing empty databases.
  - Users and grants survive a ClickHouse restart.
- [ ] M2. The typed `AppDatabase` declaration loads and validates. It compiles into its own
  standalone inventory scope, `appdb-<key>`, which claims each logical database and user on its
  server and refuses collisions and reserved names. The ClickHouse server render enables SQL
  access management. Pure tests and goldens pass under `just gate-fast`. Proves the inventory half
  of AC-1.
- [ ] M3. `nagarectl db app-database plan|rotate|retire` provision, rotate and retire app
  databases through reviewed transactions. An effect-interpreter world covers each case: a re-plan
  of an unchanged declaration has no operations, an interrupted apply resumes without resetting a
  password or widening a grant, and a wider-than-declared grant refuses. Proves AC-4 in the
  interpreter.
- [ ] M4. Workloads bind app databases with `appDatabases`, and a deploy injects only the runtime
  Secret. Binding a server that hosts app databases directly is refused, and so is registering an
  app database on a directly bound server. Render tests prove a two-app fixture names only its own
  Secrets. Proves AC-2.
- [ ] M5. Each app database has its own scheduled backup, which runs with the app's migration
  credential. Restoring it into scratch recovers its data and its declared access, and leaves
  other apps untouched. Proves AC-5 in render and interpreter tests.
- [ ] M6. `db restore-rebuilt` loads an app database backup into its re-provisioned, empty
  database after a server rebuild. The restored data matches and the declared access is in place.
- [ ] M7. `just local-app-database-smoke` passes on a k3d context. It covers two apps on one
  server per engine and proves AC-1 to AC-5 natively. `docs/user/managed-databases.md` documents
  shared servers, IR-29 is marked completed, and ADR 30 records the model.
- [ ] M8. A release containing this plan is installed on the intranet, following EP-201's
  intranet-first order. The tan-ng-labs Kansoku plan can provision `labs-postgres` and
  `labs-clickhouse` with its app databases using the documented commands.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: An app database is a new standalone inventory scope, `appdb-<key>`, that references
  an accepted server scope, `database-<key>`. It is not a field on the server and not part of the
  application scope.
  Rationale: ADR 22 gives a shared resource one owner and lets consumers hold typed references.
  The server stays owned by platform operations. Each app database is owned on its own and can be
  provisioned, rotated and retired without revising the server or the app. The tan-ng-labs policy
  puts logical database declarations with the consuming app. A standalone scope declared from the
  app's repository (`apps/<app>/nagare/Databases.hs`) satisfies that and also works for Kansoku,
  which deploys as a `Deployment`, not an `Application`.
  Date: 2026-10-19

- Decision: Workloads reference app databases through a new field, `appDatabases`. The existing
  `databases` field keeps its meaning (bind a server directly).
  Rationale: Resolving one name list against two kinds of scope invites ambiguity. A separate
  field makes the binding kind explicit in the type and in review output. Existing configs and the
  intranet's existing direct bindings keep working unchanged. The field is accepted on
  `Deployment` and `Worker`. An `Application`'s workloads bind only the databases that
  application declares today, and this plan keeps that rule; Kansoku deploys as a `Deployment`.
  Date: 2026-10-19

- Decision: A server is either *direct* (bound by `databases`, as today) or *shared* (hosts at
  least one accepted app database), never both. Planning refuses to bind a shared server directly,
  and refuses to register an app database on a server that an accepted workload binds directly.
  Rationale: This is how AC-2 is enforced. Otherwise a shared server's administrator Secret could
  still reach an app through the old field. Moving an existing direct consumer onto an app
  database is an explicit data migration, out of scope here (the tan-ng-labs policy requires one).
  Date: 2026-10-19

- Decision: Users and grants are recovered from the accepted app-database declaration, which each
  backup receipt pins by revision digest. Passwords are recovered from the retained Secrets.
  Backup objects hold data and object-level ACLs only, never role definitions or password hashes.
  Rationale: Backup objects are gzip with no encryption. `cli/nagarectl/src/Nagare/Database/Backup.hs`
  only gzips, and the recovery key version (`RecoveryIntent` in
  `cli/nagare-dsl/src/Nagare/Resource/Policy.hs`) names a key and version that no code uses to
  encrypt a dump. `pg_dumpall --roles-only` would put SCRAM verifiers into the bucket. Users and grants are fully determined by the typed
  declaration, so it is their authority. A restore re-applies them and verifies them.
  Date: 2026-10-19

- Decision: The app-database backup job runs with the app's own migration credential, not the
  server administrator Secret.
  Rationale: The migration user owns every object in its database, so `pg_dump` as that user is
  complete. On ClickHouse, `BACKUP` can be granted per database. The backup job then needs nothing
  another app could use. M1 confirms both and records the exact grants.
  Date: 2026-10-19

- Decision: Retirement disables an app database's users and keeps its database and Secrets.
  Collecting (dropping) a retired app database is not part of this plan, and `inventory collect`
  refuses app-database members with a message saying so.
  Rationale: IR-29 asks that retirement "revokes its access and retains its data per policy". No
  acceptance criterion asks for deletion, and deletion is where data risk lives.
  Date: 2026-10-19

- Decision: The intranet's direct-bound servers and their backups are unchanged. Turning on SQL
  access management on ClickHouse servers changes the pod template, so an existing ClickHouse
  server sees a reviewed update and one restart on its next apply.
  Rationale: The project keeps no compatibility shims. The change is a normal reviewed update,
  and the release notes name it.
  Date: 2026-10-19

- Decision: M1 answers the six engine questions as follows. The fixtures hold the exact
  statements.
  1. Yes. ClickHouse SQL users and grants persist under `/var/lib/clickhouse/access` across a
     restart.
  2. Yes, with two design changes.
     - The migration grant is an explicit list, not `ALL`: `SHOW TABLES, SHOW COLUMNS,
       SHOW DICTIONARIES, SELECT, INSERT, ALTER TABLE, ALTER VIEW, CREATE DATABASE, CREATE TABLE,
       CREATE VIEW, CREATE DICTIONARY, DROP TABLE, DROP VIEW, DROP DICTIONARY, TRUNCATE,
       OPTIMIZE, BACKUP, dictGet ON <db>.*`. `ALL ON db.*` expands to a version-dependent list
       (46 entries on 26.8, including row-policy and `SYSTEM` privileges), so observation could
       not compare it across an engine upgrade. `system.grants` reports the explicit list back
       exactly as granted. `DROP DATABASE` and `ALTER DATABASE` are left out on purpose.
     - `BACKUP ... TO File(...)` also needs the global `WRITE ON FILE`, so the migration user
       holds that one global grant. It is write-only: without `READ ON FILE` it cannot read a
       file or `RESTORE`, a path outside `backups.allowed_path` is refused, and an existing
       archive cannot be overwritten. Observation allows exactly this one global row.
     - The runtime list is as proposed.
  3. Yes. The ClickHouse query log records `IDENTIFIED WITH sha256_password`, and no hash, salt
     or password reached the server logs. The hash is `hex(SHA256(password ‖ salt))` where the
     salt is used as its text, not as decoded bytes. The renderer uses the uppercase hex of 16
     random bytes as the salt text.
  4. Yes. Client-side SCRAM-SHA-256 verifiers authenticate. There is one addition: PostgreSQL
     grants PUBLIC `CONNECT` on `postgres`, `template1` and the initial database, so the
     converge step also revokes `CONNECT, TEMPORARY` on those three from PUBLIC. That is safe
     because a shared server has no direct consumer, and the readiness probe and the
     administrator are superusers.
  5. Yes. `pg_dump -Fc` as the migration user is complete, and an administrator `pg_restore`
     reproduces the ACLs and default privileges. The owner can also `GRANT` its own database to
     another role, so observation treats an ACL entry for any role other than the two declared
     users as `app-database-grant-drift`.
  6. Yes. `RESTORE ... AS` works, and so does `RESTORE` into the existing empty declared
     databases, so the rebuilt-restore path needs no `DROP DATABASE`.

  Two smaller facts from the prototype:
  - ClickHouse users get `DEFAULT DATABASE <first logical database>`.
  - Retiring revokes all grants and sets `HOST NONE`, so re-enabling is `HOST ANY` followed by
    the converge step.

  One fact the smoke test must respect: the PostgreSQL image's `pg_hba` trusts the pod socket
  and `127.0.0.1`, so a password check must connect through the Service or pod IP. The transport
  relies on the socket as the administrator, as `scripts/local-smoke.sh` does.
  Date: 2026-10-19


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Terms.**
- A **server** is today's managed database: one StatefulSet (a Kubernetes controller for a single
  pod with a stable name and disk), a PersistentVolumeClaim (PVC, its disk), a ClusterIP Service
  (its in-cluster DNS name), and a credential Secret, `nagare-db-<name>`.
- An **app database** is the new resource. It is a logical database (or, on ClickHouse, a set of
  them) inside a server, with two users: a **runtime user** the app runs as and a **migration
  user** that owns the schema. Each user has its own Secret.
- A **grant** is an engine privilege. On PostgreSQL that means `GRANT CONNECT ON DATABASE`, schema,
  table, sequence and function privileges, and default privileges for future objects. On
  ClickHouse it means `GRANT SELECT ON db.*` and similar.
- **Inventory** is Nagare's typed desired-state model (ADR 22). Each context stores scopes:
  independently revised groups of declared resources. `nagarectl ... --save-plan DIR` writes a
  reviewed plan, and `nagarectl inventory apply DIR --yes` executes it. Accepted history is
  stored in `NAGARE_INVENTORY_STORE` (local filesystem, or the context's GCS state bucket).
- An **effect interpreter** (or "world") is a pure, adversarial fake of an external system, used
  in tests to find defects before any native run (ADR 25).

**How managed databases work today.** All paths below are repository-relative.
- *Declaration.* `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` defines `Database`. Its fields are
  name, optional logical key, engine `Postgres | Redis | ClickHouse`, pinned version, namespace,
  size, resources and retention. It has no field for logical databases, users or grants.
  - `dbSecretName n = "nagare-db-" <> n`.
  - `cli/nagare-dsl/src/Nagare/Dsl/Load/Database.hs` decodes the JSON a config emits.
  - `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` renders PVC `nagare-db-<n>-data`, Service
    `<n>`, StatefulSet `<n>` and, for ClickHouse, a `config.d` memory cap. Goldens live in
    `cli/nagare-dsl/test/golden/db-*.yaml`.
  - The ClickHouse container sets neither `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT` nor `users.d`.
    So the image's `nagare` user cannot `CREATE USER` or `GRANT`. On PostgreSQL, `POSTGRES_USER`
    is the initdb superuser.
- *Inventory compile.* `cli/nagare-dsl/src/Nagare/Resource/Database.hs` compiles a server into
  members `credential, pvc, [configmap], service, statefulset` and a backup bundle (service
  account, read role and its binding, signing Secret, CronJob).
  - A member's desired state is one constructor of the closed type `DesiredSpec` in
    `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs`. `LogicalBrokerTopic` is the constructor for
    a logical thing inside a StatefulSet; its claim derivation is in the same module.
    `cli/nagare-dsl/src/Nagare/Resource/Wire.hs` encodes addresses and specs for the review
    format.
  - `cli/nagarectl/src/Nagare/Inventory/DataService.hs` (`compileStandaloneDatabase`) places it in
    the standalone scope `database-<key>`.
  - The collision type `ProviderAddress` in `cli/nagare-dsl/src/Nagare/Resource/Types.hs`
    already has a `DatabaseName ResourceId Name` constructor, which nothing emits yet.
  - The closest precedent for "a logical thing inside a StatefulSet" is broker topics:
    `cli/nagare-dsl/src/Nagare/Resource/Broker.hs` (`BrokerTopic stateful name`),
    `cli/nagarectl/src/Nagare/Inventory/Adapters/Broker.hs` and
    `cli/nagarectl/src/Nagare/Inventory/Adapters/BrokerRuntime.hs`, a context-guarded kubectl
    transport against the exact reviewed StatefulSet.
- *Credentials.*
  - `cli/nagarectl/src/Nagare/Database/Secret.hs` composes the Secret keys.
    `composeConnectionUrl` has no database path for ClickHouse.
  - The password is generated only at apply time, in `materializeCredential`
    (`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`), with
    `openssl rand -hex 24`. The template is recognised by the annotation
    `nagare.dev/credential-template: database-v1` (`databaseCredentialKind`), which also requires
    the Secret name `nagare-db-<n>` and the engine's server key set (`engineSecretKeys`).
  - `credentialDataMatches` compares only key presence, so a re-plan never rotates a password.
  - ADR 27's checked accessor is `checkedPhysical` in
    `cli/nagarectl/src/Nagare/Inventory/Identity.hs`. It compares a live UID with the recorded
    incarnation and reports a member without a record as unrecorded, never as matching.
- *Lifecycle CLI.*
  - `cli/nagarectl/app/Nagare/Cli/Commands/Database.hs` (`runDbCreatePlan`) builds the scope and
    either converges it or saves a plan.
  - `cli/nagarectl/app/Nagare/Cli/Parser/Data.hs` holds the `db` subcommands.
  - Retirement is `runStandaloneRetirePlan` in `cli/nagarectl/app/Nagare/Cli/Data/Lifecycle.hs`
    and `decideRetirement` in `cli/nagarectl/src/Nagare/Inventory/Lifecycle.hs`, which retains
    every member.
- *Binding.*
  - `Deployment` (`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`) and `Worker`
    (`cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`) carry `databases :: ![DatabaseName]`, loaded by
    `cli/nagare-dsl/src/Nagare/Dsl/Load/Deployment.hs` and `Load/Worker.hs`. An `Application`
    instead carries full `Database` declarations it owns, and its workloads may bind only those
    (`databaseDependencies` in the environment module below).
  - At deploy, `reviewedStandaloneDatabases` (`cli/nagarectl/app/Nagare/Cli/Application/Inputs.hs`)
    loads accepted scopes. `acceptedDatabaseBindings`
    (`cli/nagarectl/src/Nagare/Inventory/Application/Bindings.hs`) finds the server's Service,
    StatefulSet and credential.
  - `standaloneDatabaseEnvironment` (`cli/nagarectl/src/Nagare/Inventory/Application/Environment.hs`)
    produces the env. Host and port are literals; user, database, password and URL are
    `secretKeyRef`s into `nagare-db-<n>` (`databaseConnectionEnv`, same module, over
    `connectionEnv` in `cli/nagarectl/src/Nagare/Database/Connection.hs`).
  - `mergeConnectionEnvs` (`cli/nagarectl/src/Nagare/Database/Connection.hs`) refuses two
    same-engine databases on one workload. That rule stays.
- *Backups.* `cli/nagarectl/src/Nagare/Database/Backup.hs` renders CronJob `nagare-dbbackup-<n>`.
  - It probes the source, dumps, then uploads with a sha256 read-back and an HMAC-signed receipt
    under `databases/<n>/<jobUID>.<ext>`.
  - It dumps with the server Secret: `pg_dump --no-owner --no-privileges -d "$POSTGRES_DB"`, or on
    ClickHouse `BACKUP DATABASE default TO File(...)`, then copies the zip off the mounted PVC.
  - Receipts become restore authority through `db backup-receipts`
    (`cli/nagarectl/src/Nagare/Inventory/ScheduledIngest.hs`).
  - `cli/nagarectl/src/Nagare/Database/Restore.hs` and
    `cli/nagarectl/src/Nagare/Inventory/Restore.hs` restore into a scratch database
    `<db>_restore_<id>` on the same server. `renderRebuildRestoreJob` loads into a rebuilt server.
- *Tests.*
  - `cli/nagarectl/test/Nagare/Test/Database.hs` and `cli/nagarectl/test/Nagare/Test/Backup/*.hs`.
  - Interpreter fixtures: `cli/nagarectl/test/Nagare/Test/Effectful/Fixture.hs` and
    `cli/nagarectl/test/Nagare/Test/World/*`.
  - Mutation records: `cli/nagarectl/test/mutations/`.
  - The local end-to-end check is `scripts/local-smoke.sh` (`just local-smoke`; its step 5 is
    PostgreSQL only, one database).

**ADRs that apply.**
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md):
  - One owner per resource. Consumers hold typed references.
  - An address claim includes what a controller creates.
  - Validated values have one construction route, and no type with a hidden constructor derives
    `Generic`.
  - Credentials have no representation in the review format.
  - Authority to cause effects exists only under the writer lock.
  - Omission never means deletion.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
  defects are found by adversarial effect interpreters, and native runs only confirm. M3 and M5
  therefore need a catalog world before M7's native run.
- [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
  physical identity (here, the server StatefulSet and PVC UIDs) is recorded at creation and read
  through one checked accessor. SQL runs only against the exact accepted server incarnation.
- [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md):
  the intranet stays single-node with hourly recovery points and a four-hour rebuild. App-database
  backups follow the same `NAGARE_BACKUP_RECOVERY_POINT` schedule as servers.
- [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md): production Haskell
  conventions. Every `data` record field is strict, labels go through generic-lens, deriving is
  explicit, and `just haskell-style-check` runs before every commit.
- The consumer's policy is tan-ng-labs ADR 0001,
  `mori://tan/tan-ng-labs` `docs/adr/0001-shared-database-servers-with-isolated-app-databases.md`
  (artifact-level URI pending). No Nagare ADR covers per-app databases, roles or grants yet.
  ADR 30 is written in M7.

**Facts about the consumer that shape the design.**
- Kansoku needs PostgreSQL database `kansoku`, and ClickHouse databases `analytics` and
  `kansoku_migration_ledger`.
- Its ClickHouse migrator (`mori://shinzui/clickhouse-migrate`, `LedgerSchema.createDatabase`)
  runs `CREATE DATABASE IF NOT EXISTS kansoku_migration_ledger ENGINE=Atomic` and then creates its
  own ledger tables. Registration may create the empty databases but must never create tables,
  and the migration user needs `CREATE DATABASE` on its own databases.
- The migrator speaks HTTP on 8123 and checks `serverUUID()` and `version()`. The server Service
  already exposes 8123 and 9000.
- The Kansoku plan expects Secrets named `kansoku-pg-runtime`, `kansoku-pg-migration`,
  `kansoku-ch-runtime` and `kansoku-ch-migration`. The `<app-database>-runtime` and
  `<app-database>-migration` naming below produces exactly those for app databases named
  `kansoku-pg` and `kansoku-ch`.


## Plan of Work

### M1 — prototype: prove the engine SQL by hand

This is a bounded prototype. Its output is SQL, not Haskell. On a local context
(`docs/user/local-development.md`), create one PostgreSQL 18 and one ClickHouse server with
today's `nagarectl db create ... --dry-run` manifests. For ClickHouse, add
`CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1` to the container env by hand. Then run, as the
administrator, the SQL each operation will emit for two app databases, `alpha` and `beta`.
Answer these questions with evidence, and record each answer in the Decision Log:

1. ClickHouse SQL-created users and grants persist across a pod restart. They are stored under
   `/var/lib/clickhouse/access` on the PVC.
2. The exact ClickHouse grant sets.
   - Migration: proposed `ALL ON <db>.*` for each declared database.
   - Runtime: proposed `SELECT, INSERT, ALTER UPDATE, ALTER DELETE, SHOW TABLES, SHOW COLUMNS,
     dictGet ON <db>.*`.
   - `SHOW GRANTS FOR` shows no global privilege.
   - `CREATE DATABASE IF NOT EXISTS <own>` succeeds for the migration user, and fails for
     `<other>`.
   - A fully qualified `SELECT`, `INSERT` and `CREATE TABLE` on the other app's database fail.
   - `CREATE USER`, `GRANT` and `SYSTEM SHUTDOWN` fail for both users.
   - `BACKUP DATABASE <own>` works for the migration user given `BACKUP ON <db>.*`.
3. ClickHouse masks the password of `CREATE USER ... IDENTIFIED BY` in `system.query_log` and
   the server log, and `IDENTIFIED WITH sha256_hash BY '<hex>' SALT '<hex>'` accepts
   `hex(SHA256(password ‖ salt))` computed off the server, so plaintext need not be sent at all.
4. The exact PostgreSQL statements.
   - `CREATE ROLE ... LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD
     '<SCRAM-SHA-256 verifier>'`. The verifier is computed client-side, so plaintext never
     reaches the server or its error log.
   - `CREATE DATABASE <db> OWNER <migration>`.
   - `REVOKE ALL ON DATABASE <db> FROM PUBLIC`.
   - `GRANT CONNECT, TEMPORARY ON DATABASE <db> TO <runtime>`.
   - Inside `<db>`: `ALTER SCHEMA public OWNER TO <migration>`,
     `REVOKE ALL ON SCHEMA public FROM PUBLIC`, `GRANT USAGE ON SCHEMA public TO <runtime>`, and
     `ALTER DEFAULT PRIVILEGES FOR ROLE <migration>` granting the runtime role `USAGE` on schemas,
     `SELECT, INSERT, UPDATE, DELETE` on tables, `USAGE, SELECT` on sequences and `EXECUTE` on
     functions.
   - Then show that a connection to the other app's database fails for both users, and that
     runtime can read and write a table that migration creates in a new schema.
5. `pg_dump -Fc` run as the migration user is complete and keeps owners and ACLs.
   A `pg_restore` by the administrator into `<db>_restore_<id>`, without `--no-owner`,
   reproduces those ACLs. Then apply the database-level ACL to the scratch database.
6. ClickHouse `BACKUP DATABASE a, DATABASE b TO File(...)` gives one consistent archive for
   Kansoku's two databases. `RESTORE DATABASE a AS a_restore_<id>, DATABASE b AS b_restore_<id>`
   works, and re-granting the declared set on the scratch names gives the owning app back exactly
   its access.

Commit the working statements as reference fixtures:
- `cli/nagarectl/test/fixtures/app-database/postgres.sql`
- `cli/nagarectl/test/fixtures/app-database/clickhouse.sql`

Each is commented per operation (create, observe, rotate, retire, backup, restore). M3's SQL
renderer is tested against them. The prototype is accepted when every question has a recorded
answer. A "no" answer changes the design in the Decision Log before M2 starts.

### M2 — the declaration and its inventory scope

**Make room first.** `scripts/check-haskell-architecture.py` caps a module at 1000 lines and
`scripts/haskell-size-allowances.json` may only ever lower an allowance. Two modules this
milestone extends have no headroom: `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` is at its
allowance of 1011 lines, and `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`
is three lines under its 1180. Adding a constructor to either fails the first commit. So the first
commit of M2 is two extractions, with no behaviour change:
- Move the credential-template functions, `metadataOf` through `validCachePublicKey` (about 400
  lines: `materializeCredential`, the `*CredentialKind` detectors, `fillCredential`,
  `credentialDataMatches` and the cache-key helpers), into
  `cli/nagarectl/src/Nagare/Inventory/Adapters/CredentialTemplate.hs`, re-exported from
  `KubernetesRuntime.hs`. The six mutation diffs under `cli/nagarectl/test/mutations/` that patch
  `KubernetesRuntime.hs` touch observations, `waitForReadiness` and `parseObserved`, all above
  line 500, so they still apply; prove it with `just mutation-check <commit> <parent>`, the
  per-change proof (`just mutation-sweep` is the release-wide one). A refactor on 2026-10-07
  silently broke old records, so do not skip this.
- Split the data types of `Resource/Inventory.hs` (`Executor`, `DesiredSpec`, `ManagedResource`,
  `Declaration`, `OperationKind`, `Contribution`, `ResourceBundle`, `ScopeDeclaration`, roughly
  lines 78 to 290) into `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`, re-exported from
  `Nagare.Resource.Inventory` so no importer changes. No mutation diff patches `Inventory.hs`.
- Add both modules to their `.cabal` files and lower the two allowances to the new sizes.
  `just haskell-style-check` runs `cabal-gild`; check its exit code, not its output.

Add `AppDatabase` to a new module, `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`, with a
loader in `cli/nagare-dsl/src/Nagare/Dsl/Load/AppDatabase.hs` and an `emitAppDatabases` in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` beside `emitDatabase`. It writes one JSON array, so a
config can declare several app databases in one file. The shape is in Interfaces and
Dependencies.

Loading refuses each of these with a precise message:
- Redis.
- A PostgreSQL app database with other than exactly one logical database.
- An invalid identifier: the rule is `[a-z][a-z0-9_]{0,47}`.
- A reserved name. On PostgreSQL that is `postgres`, `template0`, `template1`, and the server's
  initial database `sanitizeDbName server`. On ClickHouse it is `default`, `system`,
  `information_schema` and `INFORMATION_SCHEMA`.

User names derive from the app-database name: `sanitizeDbName name <> "_runtime"` and
`<> "_migration"`. Secret names are `name <> "-runtime"` and `name <> "-migration"`.

Compile an app database in `cli/nagare-dsl/src/Nagare/Resource/AppDatabase.hs` into the
standalone scope `appdb-<logicalKey or name>`, through a `compileStandaloneAppDatabase` beside
`compileStandaloneDatabase` in `cli/nagarectl/src/Nagare/Inventory/DataService.hs`. Members:

- `runtime-credential` and `migration-credential`: data-free Secret templates, `Retain`,
  `Durable`, `Secret` sensitivity. They carry a new annotation value,
  `nagare.dev/credential-template: app-database-v1`, recognised beside `database-v1` in
  `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs` by `materializeCredential`
  and `credentialDataMatches`. The server template cannot be reused: it requires the Secret name
  `nagare-db-<server>` and the server key set. The app-database key set is in Interfaces and
  Dependencies.
- One `logical-database/<db>` member per logical database. Its address is the existing
  `DatabaseName serverStatefulSetId db`, and its spec is a new `DesiredSpec` constructor,
  `LogicalDatabase`, in `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` (follow
  `LogicalBrokerTopic`, including the claim derivation there and the encoding in
  `cli/nagare-dsl/src/Nagare/Resource/Wire.hs`). Its dependency is the server StatefulSet's
  resource id.
- `runtime-user` and `migration-user` members. Their address is a new constructor,
  `DatabaseUser ResourceId Name`, in `cli/nagare-dsl/src/Nagare/Resource/Types.hs`, with its
  canonical claim and `Wire.hs` encoding. Their spec is a new `DesiredSpec` constructor,
  `DatabaseUserSpec`, whose content digest covers the declared grant set (not the password).
- All four non-Secret members run under a new `Executor` constructor, `AppDatabaseExecutor`,
  beside `BrokerExecutor`. The kind-totality suite (`cli/nagarectl/test/InventoryKindTotalitySpec.hs`)
  generates a `DocumentedLimit` row for every non-Kubernetes executor, so it passes without a
  table edit. The compiler then names every `case` over `Executor` that must learn the new
  constructor; today `BrokerExecutor` is matched in `Nagare.Resource.Broker`,
  `Nagare.Access.Reviewed`, `Nagare.Inventory.Command`, `Nagare.Inventory.DataService`,
  `Nagare.Inventory.ManifestAdapter`, `Nagare.Inventory.Execute.AdapterEnv`,
  `Nagare.Inventory.Application.Bindings` and the three `Nagare.Inventory.Plan.*` modules
  (`Changes`, `Lifecycle`, `Observation`). Expect the same ten sites.

Composition must refuse, with tests:
- Two app databases claiming the same logical database or user on one server.
- An app database whose server is not accepted, or whose engine or namespace differ from the
  server's.
- An app database on a server that an accepted workload binds directly (see the Decision Log).

In `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs`, add
`CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1` to the ClickHouse container env, and update
`cli/nagare-dsl/test/golden/db-clickhouse.statefulset.yaml`. Acceptance: the pure tests and
goldens above pass under `just gate-fast`. One test composes `alpha` and `beta` on one server per
engine and asserts the composed inventory has exactly one StatefulSet, PVC and Service per engine
(AC-1).

### M3 — provision, rotate and retire through reviewed transactions

Write an adapter pair following the broker-topic precedent:
- `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs`: a pure plan, decode and match,
  behind an `AppDatabaseOps` record (as `TopicAdapterOps` is for topics).
- `cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabaseRuntime.hs`: the context-guarded
  transport that implements `AppDatabaseOps` with `kubectl exec`.
- The assembly in `cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs`, following
  `inventoryBrokerAdapter`: `executionBlockedAdapterFor AppDatabaseExecutor` when the review
  holds no app-database specs, a refusal when the review belongs to another context, otherwise
  the runtime ops under the Kubernetes context guard.

The transport runs `kubectl exec -i` into the exact server pod. Before each call it checks the
StatefulSet and PVC UIDs through `checkedPhysical`
(`cli/nagarectl/src/Nagare/Inventory/Identity.hs`) against the recorded incarnations. It runs `psql`/`clickhouse-client` inside the
pod with the container's own administrator env (`sh -c` so the env expands in the pod). It sends
SQL on stdin only, never in argv.

A pure SQL renderer, `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`, emits the M1
statements. It is tested against the M1 fixtures. PostgreSQL passwords are sent as SCRAM-SHA-256
verifiers, computed with `crypton` (already a `nagarectl` dependency): PBKDF2-HMAC-SHA-256 with
4096 iterations and a random 16-byte salt, per RFC 7677. ClickHouse passwords use
`IDENTIFIED WITH sha256_hash BY '<hex>' SALT '<hex>'`, also computed client-side. Plaintext
leaves the workstation only inside the Kubernetes Secret.

**Observation** reads catalogs into a typed `ObservedAppDatabase`.
- PostgreSQL: `pg_roles` attributes, `pg_database` owner and ACL, schema ACLs and `pg_default_acl`.
- ClickHouse: `system.users`, `system.grants` and `system.databases`.

Observation runs at plan time through the same transport, as topic inspection does today. So
`db app-database plan` is not a pure render: it needs the context guard and cluster access, and
`no operations` is a statement about the live catalogs. Every statement the transport sends has
no idempotency token, so a statement whose acknowledgement is lost is classified
`PartialOrUnknown` (`FailureClass` in `cli/nagarectl/src/Nagare/Inventory/Journal.hs`), never
`KnownNoEffect`, and a resume re-observes before sending anything.

**Ordering within one transaction:**
1. Create the two Secrets create-only, through the existing `materializeCredential` path.
2. Read their passwords from the Secret.
3. Create the users if absent.
4. Create the databases if absent.
5. Converge grants.

Each step is idempotent:
- An existing user is never re-passworded.
- An existing database is never re-created.
- A grant is only ever added, toward the declared set.

If the observation shows a grant *wider* than declared, or a role attribute such as `SUPERUSER`,
planning refuses with `app-database-grant-drift`. It never revokes silently. If a user exists but
its Secret does not, planning refuses with `app-database-credential-missing`, and the reviewed
exit is `rotate`.

**CLI**, in `cli/nagarectl/app/Nagare/Cli/Parser/Data.hs` and
`cli/nagarectl/app/Nagare/Cli/Commands/Database.hs`:
- `nagarectl db app-database plan --config FILE [--save-plan DIR]`: every `AppDatabase` in the
  config's `emitAppDatabases` list becomes its own scope in one transaction.
- `nagarectl db app-database rotate NAME --user runtime|migration --save-plan DIR`: generates a
  new password, then runs `ALTER ROLE`/`ALTER USER`, then replaces that Secret's data under a
  resourceVersion precondition. When the Secret is absent (the `app-database-credential-missing`
  exit) it creates the Secret instead. Pods read the Secret at start, so the docs say to restart
  bound workloads afterwards.
- `nagarectl db app-database retire NAME --save-plan DIR`: PostgreSQL `ALTER ROLE ... NOLOGIN`
  and `REVOKE CONNECT`. ClickHouse `REVOKE ALL ... FROM` both users, then `ALTER USER ... HOST
  NONE`. Databases and Secrets are kept. It refuses while an accepted workload still lists the
  app database (follow F87 in `cli/nagarectl/src/Nagare/Inventory/Application/Retire.hs`).
- `nagarectl db list` gains app databases, with their server.

Register each new command with `scripts/audit-managed-commands.py`.

**Interpreter world**, in `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs`: an in-memory
catalog of databases, users, attributes and grants per engine, implementing `AppDatabaseOps`.
It does not sit behind the kubectl fake: `cli/nagarectl/test/Nagare/Test/World/Kubectl.hs`
answers only the request grammar the Kubernetes runtime emits and refuses anything else, and
`kubectl exec` with SQL on stdin is outside it. The guard and UID checks in the runtime module
therefore get pure tests only. This is the first world for an exec-style adapter; broker topics
have pure tests and none. The harness rules from the 2026-10-06 deep-tier failure apply: the checker
reads the catalog through a read-only view type, never the faulting store; there is one retry
wrapper; a fast self-test proves every fault placement fires; violations are reported as they
happen, not collected. Its adversary can interrupt after any statement, lose an
acknowledgement, or pre-seed drift. Tests prove:
- An unchanged re-plan has zero operations.
- Every interruption point resumes to the declared state with the original password.
- Drift and missing-credential refuse with the named codes.
- Rotation changes only the selected user of the selected app database. Retiring `alpha` leaves
  `beta`'s users, grants and databases byte-identical.

Add mutation records under `cli/nagarectl/test/mutations/` for the drift refusal and the
create-only password, and prove each with its exact `records.json` pattern. Acceptance:
`just test-inventory-effects` and `just gate-fast` pass (AC-4 in the interpreter).

### M4 — bind only the runtime Secret

Add `appDatabases :: ![AppDatabaseName]` to `Deployment` in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` and to `Worker` in
`cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`, defaulting to `[]` in every smart constructor, and to
their loaders `cli/nagare-dsl/src/Nagare/Dsl/Load/Deployment.hs` and
`cli/nagare-dsl/src/Nagare/Dsl/Load/Worker.hs`. Then add two functions:
- `acceptedAppDatabaseBindings`, beside `acceptedDatabaseBindings` in
  `cli/nagarectl/src/Nagare/Inventory/Application/Bindings.hs`. It resolves an `appdb-` scope, its
  server's Service, and its `runtime-credential` member.
- `appDatabaseEnvironment`, beside `standaloneDatabaseEnvironment` in
  `cli/nagarectl/src/Nagare/Inventory/Application/Environment.hs`. It emits:
  - PostgreSQL: literals `POSTGRES_HOST` (the server's host) and `POSTGRES_PORT`. Secret refs
    into `<name>-runtime`: `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD`, `DATABASE_URL`.
    The URL's path selects the app database.
  - ClickHouse: literals `CLICKHOUSE_HOST` and `CLICKHOUSE_PORT`. Secret refs:
    `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DB` (the first logical database), and
    `CLICKHOUSE_URL`, whose path is that database.

The two maps go through the existing `mergeConnectionEnvs`. So a workload may bind one
PostgreSQL and one ClickHouse database (direct or app), not two of one engine. The dependency is
the app database's user members, so a deploy waits for provisioning.

The deploy commands `cli/nagarectl/app/Nagare/Cli/Commands/Deployment.hs` and
`cli/nagarectl/app/Nagare/Cli/Commands/Worker.hs` read the field and load the accepted scopes
through `cli/nagarectl/app/Nagare/Cli/Application/Inputs.hs`, beside
`reviewedStandaloneDatabases`. `cli/nagarectl/src/Nagare/Inventory/Application/Service.hs` and
`cli/nagarectl/src/Nagare/Inventory/Application/Worker.hs` merge the env. An `Application`'s
workloads bind only the databases that application declares (`databaseDependencies`), so
`cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` refuses a non-empty `appDatabases`
there with `app-database-not-bindable-from-application`. Scheduled tasks inherit the env as they
do today.

`acceptedDatabaseBindings` refuses a server that hosts any accepted app database, with
`shared-server-direct-binding`. The migration Secret is never bindable. Acceptance: a render test
deploys `alpha-svc` and `beta-svc` against `alpha`/`beta` on one server per engine. Every
`secretKeyRef` in each rendered workload names only its own `-runtime` Secret, and no
`nagare-db-` or `-migration` Secret appears (AC-2).

### M5 — per-app scheduled backups and scratch restore

Give each app-database scope its own backup bundle, compiled the way the server's is in
`cli/nagare-dsl/src/Nagare/Resource/Database.hs`. It has CronJob `nagare-dbbackup-<appdb>`, its
service account, role and signing Secret, and the same `NAGARE_BACKUP_RECOVERY_POINT` schedule.

The dump step's env comes from `<appdb>-migration`, not `nagare-db-<server>`. The commands
extend `cli/nagarectl/src/Nagare/Database/Backup.hs` with app-database variants:
- PostgreSQL: `pg_dump -Fc -d <db>` without `--no-owner`/`--no-privileges`.
- ClickHouse: one `BACKUP DATABASE a, DATABASE b, ... TO File('${BACKUP_RUN_ID}.zip')`, copied
  off the mounted PVC exactly as the server backup does today.

The source probe checks the server's StatefulSet and PVC UIDs. Each receipt also records the app
database's accepted declaration digest, and that is a format change, not a field. The scheduled
receipt is an HMAC-signed envelope whose verifier in
`cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs` accepts versions 4 and 5 and checks the
exact payload field count (six for version 5). The app-database receipt is version 6 with seven
payload fields; the renderer's `printf` in `Backup.hs`, the verifier, and the ingest in
`cli/nagarectl/src/Nagare/Inventory/ScheduledIngest.hs` all learn it, and ingest keeps accepting
4 and 5 because the intranet's bucket holds version-5 receipts from its servers. Receipts ingest
through the existing `db backup-receipts`, keyed by the app-database name. Objects go under
`databases/<appdb>/<jobUID>.<ext>`.

`db restore` accepts an app-database name and restores into scratch names `<db>_restore_<id>`,
running as the server administrator (an operator action):
- PostgreSQL: `createdb`, then `pg_restore`, then the declaration's database-level ACL on the
  scratch database.
- ClickHouse: `RESTORE ... AS`, then the declaration's grant set on the scratch names.

Tests extend `cli/nagarectl/test/Nagare/Test/Backup/Rendering.hs`, `Scheduled.hs` and
`Restore.hs`. One interpreter test restores `alpha` while asserting `beta`'s catalog entries
and objects are unchanged. Acceptance: `just gate-fast` (AC-5 in tests).

### M6 — restore an app database after a server rebuild

The disaster path today is: rebuild the server, then `db restore-rebuilt` loads its backup. For
an app database the order becomes:
1. Rebuild and restore the server (unchanged).
2. Re-apply the app-database scope. This creates the empty database and the users with the
   retained Secrets' passwords. Retained Secrets survive because credentials are `Retain`.
3. Run `db restore-rebuilt <appdb> --backup-id ID`, which loads the dump into the empty database
   and re-verifies the declared grants.

Extend `renderRebuildRestoreJob` in `cli/nagarectl/src/Nagare/Database/Restore.hs` for both
engines. It refuses unless the target database is empty. Acceptance: an interpreter test runs
this sequence from an empty server and ends with the declared catalog and the backed-up rows.
`docs/runbooks/inventory-operations.md` gains the three-step order.

### M7 — native confirmation, documentation, ADR

Write `scripts/local-app-database-smoke.sh` (recipe `just local-app-database-smoke`, registered
in the command audit), in the style of `scripts/local-smoke.sh`, on a fresh k3d context with the
packaged `nagarectl`. It runs:
1. Create servers `smoke-pg` and `smoke-ch`.
2. Declare app databases `alpha-pg`, `alpha-ch`, `beta-pg` and `beta-ch`, and plan and apply them.
3. Re-plan and expect `no operations`.
4. Publish the two pinned engine images through the same `app image-plan` review that
   `scripts/local-smoke.sh` uses for its app, then deploy four `Worker`s with
   `nagarectl worker deploy --image-resource`: `alpha-pg-probe` and `beta-pg-probe` on the
   PostgreSQL image, `alpha-ch-probe` and `beta-ch-probe` on the ClickHouse image, each with
   `command = sleep infinity` and `appDatabases` naming its one app database. A `Deployment` is a
   Knative Service that must answer HTTP, so it cannot be the probe; a `Worker` has no such
   requirement and carries the same env. `nagarectl worker deploy` requires `--image-resource`, so
   the images go through review. Each probe pod's env is what AC-2 inspects. The two images are
   the ones the servers already run, `postgres:18` and `clickhouse/clickhouse-server:26.8`; the
   ClickHouse one is about a gigabyte, so saving and pushing it dominates the smoke's run time.
   Key each publication by image digest so a rerun reuses it, and keep the archives under the
   smoke's review root, not under `/private/tmp`, which macOS purges after about three days.
5. Assert own-database read and write, and every cross-app denial from AC-3. Runtime users run
   through `kubectl exec` into their probe pod with its own env (`psql "$DATABASE_URL"`,
   `clickhouse-client --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password
   "$CLICKHOUSE_PASSWORD" --database "$CLICKHOUSE_DB"`). Migration users run through the server
   pod with the migration Secret read by `kubectl get secret`, as `psql_in_pod` in
   `scripts/local-smoke.sh` does today; the password is passed only as process env in the pod.
6. Rotate `alpha-pg` runtime and retire `beta-ch`, and assert the other app's state is unchanged.
7. Run each backup CronJob once, ingest the receipts, restore `alpha-*` into scratch, and assert
   rows and denials there.
8. Print `app-database smoke: PASS`.

Update `docs/user/managed-databases.md`:
- A new section, "Sharing one server between apps", with the declaration, the commands, the
  injected variables, rotation and its restart, retirement, backups and the three-step rebuild.
- Remove "multi-tenant users" from "Out of scope".
- Replace "Referencing two databases of the same engine is rejected" with the precise rule.

Set IR-29's `status` to `completed` and add a line to `docs/improvement-requests/log.md`.
Write ADR 30, `docs/adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md`, from the
Decision Log.

### M8 — in real use

The next release includes this work and follows the intranet-first order from
`docs/plans/201-upgrade-the-intranet-on-the-release-candidate-before-tagging.md`. The real
intranet upgrades and passes the deploy-and-login check. The release notes say that ClickHouse
servers restart once. The tan-ng-labs Kansoku plan then takes it from there. This plan is
complete when that plan's Milestone 2 has run its commands against the released version, or
reports a defect here.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`, in a shell
loaded by `direnv` for a **local** context (`NAGARE_MODE=local`). M1 to M7 need no cloud
mutation. Any step that touches a cluster (the M1 prototype, every `db app-database plan`
against a live context, the M7 smoke) runs from a clean environment, `env -i` plus
`nagarectl context env`, and asserts the kube server before acting; a `direnv` shell carries
stale values between contexts.

Per Haskell commit:

```bash
just haskell-style-check && just gate-fast
```

Land once per milestone, not per commit: each `just land` starts a full gate of about an hour,
and a red one blocks the next land until a gated fix lands. Keep at most two full gates running.
M1 produces SQL and M2 produces Haskell, and neither depends on the other, so run them in two
worktree sessions at once; M3 starts when both have landed.

Focused loops while developing:

```bash
cd cli/nagarectl && cabal test nagarectl-test --offline --test-show-details=failures -p '/AppDatabase/'
just test-inventory-effects
cd cli/nagare-dsl && cabal test --offline -p '/db-clickhouse/'
```

The M1 prototype on a local context (illustrative; record the real transcripts in the Decision
Log):

```bash
R="$(mktemp -d)"
nagarectl db create postgres smoke-pg --dry-run > "$R/smoke-pg.yaml"
kubectl apply -f "$R/smoke-pg.yaml"
kubectl exec -i smoke-pg-0 -- sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres' \
  < cli/nagarectl/test/fixtures/app-database/postgres.sql
```

The finished flow, after M4. This is the shape the user doc will show:

```bash
nagarectl db app-database plan --config apps/alpha/nagare/Databases.hs --save-plan "$R/appdb-plan"
nagarectl inventory apply "$R/appdb-plan" --yes
nagarectl db app-database plan --config apps/alpha/nagare/Databases.hs
```

The last command is expected to print:

```text
no operations
```

The native confirmation:

```bash
just local-app-database-smoke
```

It is expected to end with:

```text
app-database smoke: PASS
```

Commit trailers: `ExecPlan: docs/plans/202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md`.
Land with `just gate-fast` clean, then `just land`.


## Validation and Acceptance

| IR-29 criterion | Proven by |
| --- | --- |
| AC-1 (one server per engine hosts many app databases) | M2 composition test; M7 smoke counts one StatefulSet, PVC and Service per engine |
| AC-2 (deploy injects only the app's own Secret) | M4 two-app render test; M7 inspects the four probe Workers' env |
| AC-3 (users confined to own database) | M1 by hand; M3 grant-set tests against M1 fixtures; M7 live denials for runtime and migration users of both apps on both engines |
| AC-4 (reviewed, repeatable provisioning, rotation, retirement) | M3 interpreter world; M7 re-plan `no operations`, rotate and retire with the other app unchanged |
| AC-5 (backups of every app database, independent restore) | M5 tests; M6 rebuild test; M7 scheduled backup, receipt ingest and scratch restore of one app |

Failure is visible:
- A test names the refusal code (`app-database-grant-drift`, `app-database-credential-missing`,
  `shared-server-direct-binding`).
- The smoke script exits non-zero at the first failed assertion, printing the user, statement and
  engine.

The required acceptance is AC-1 to AC-5 and M8's use on the intranet. These are proposals, not
required: per-user ClickHouse query and memory limits, collection of retired app databases, and
moving an existing direct consumer onto an app database.


## Idempotence and Recovery

Every operation is designed to be re-run:
- Secrets are create-only.
- Users and databases are created only when absent.
- Grants converge upward to the declared set.
- A re-plan of an unchanged declaration is empty.

An interrupted `inventory apply` is resumed with `nagarectl inventory resume` (the journal
records intent before each effect). The interpreter world proves every interruption point. A
SQL statement has no idempotency token, so the journal records a lost acknowledgement as
`PartialOrUnknown`, and the resume re-observes the catalogs before it sends anything.

Drift is never repaired silently, because planning refuses. An operator inspects the server as
administrator, removes the extra grant by hand or declares it, and re-plans. A lost Secret makes
the user's password unknowable, so the exit is `rotate`.

Retirement keeps data and Secrets. Re-declaring a retired app database is a new reviewed plan
that re-enables login (PostgreSQL `LOGIN`, ClickHouse `HOST ANY`) and re-grants.

The prototype in M1 runs only on a disposable local context. Delete that context afterwards with
the documented local teardown.


## Interfaces and Dependencies

New DSL value, in `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`. The name types are smart-
constructed newtypes with hidden constructors and no `Generic`, per ADR 22:

```haskell
data AppDatabase = AppDatabase
  { name :: !AppDatabaseName                        -- DNS label, e.g. "kansoku-pg"
  , logicalKey :: !(Maybe LogicalKey)
  , server :: !DatabaseName                         -- accepted server, e.g. "labs-postgres"
  , engine :: !Engine                               -- Postgres | ClickHouse
  , namespace :: !Namespace                         -- must equal the server's
  , logicalDatabases :: !(NonEmpty LogicalDatabaseName)
  }
  deriving stock (Generic, Eq, Show)

mkAppDatabaseName :: Text -> Either DslError AppDatabaseName
mkLogicalDatabaseName :: Text -> Either DslError LogicalDatabaseName
appDatabaseUsers :: AppDatabase -> (Text, Text)        -- (runtime, migration) user names
appDatabaseSecretNames :: AppDatabaseName -> (SecretName, SecretName)
emitAppDatabases :: [AppDatabase] -> IO ()             -- in Nagare.Dsl.Config; one JSON array
```

Kansoku's declarations, which tan-ng-labs will write against this interface. The literals stand
for the results of the smart constructors above:

```haskell
kansokuPg = AppDatabase { name = "kansoku-pg", logicalKey = Nothing, server = "labs-postgres"
                        , engine = Postgres, namespace = personal, logicalDatabases = "kansoku" :| [] }
kansokuCh = AppDatabase { name = "kansoku-ch", logicalKey = Nothing, server = "labs-clickhouse"
                        , engine = ClickHouse, namespace = personal
                        , logicalDatabases = "analytics" :| ["kansoku_migration_ledger"] }

main :: IO ()
main = emitAppDatabases [kansokuPg, kansokuCh]
```

The two Secrets of an app database. Both are data-free templates at review time, annotated
`nagare.dev/credential-template: app-database-v1` and labelled with the app database, its server
and its engine. `materializeCredential` fills them at the create-only mutation:
- PostgreSQL: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` (the one logical database) and
  `DATABASE_URL`, whose path is that database.
- ClickHouse: `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DB` (the first logical
  database) and `CLICKHOUSE_URL`, whose path is that database. `composeConnectionUrl` in
  `cli/nagarectl/src/Nagare/Database/Secret.hs` gains a ClickHouse database path for this; the
  server Secret's URL is unchanged.

Inventory additions:
- An `Executor` constructor, `AppDatabaseExecutor`, in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` (after the M2 split, in
  `Nagare.Resource.Inventory.Types`).
- A `ProviderAddress` constructor, `DatabaseUser ResourceId Name`, in
  `cli/nagare-dsl/src/Nagare/Resource/Types.hs`, with its canonical claim. `DatabaseName
  ResourceId Name` already exists there; only `cli/nagare-dsl/src/Nagare/Resource/Wire.hs`
  decodes it today, and nothing emits it.
- `DesiredSpec` constructors `LogicalDatabase` and `DatabaseUserSpec` in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs`, with their encodings in `Wire.hs`.
- Two recurring compile-time snags. `DatabaseName` is both the DSL newtype in
  `Nagare.Dsl.Types` and a `ProviderAddress` constructor in `Nagare.Resource.Types`; a module
  that needs both imports one qualified. `Wire.hs` parses every object strictly against an
  allowed-key list (`strictObject`), so a new field goes into that list and is parsed as
  optional, because accepted history written before the field has no value for it.

Binding additions:
- `AppDatabaseBinding` beside `DatabaseBinding` in
  `cli/nagarectl/src/Nagare/Inventory/Application/Types.hs`, holding the server Service, the
  runtime credential and the engine.
- `appDatabases :: ![AppDatabaseName]` on the workload record.

Libraries:
- `crypton` (PBKDF2, HMAC-SHA-256, SHA-256) for the SCRAM verifier and the ClickHouse hash. It is
  already in `cli/nagarectl/nagarectl.cabal`.

External tools, in-pod only:
- `psql`, `pg_dump` and `pg_restore` from the pinned `postgres:<version>` image.
- `clickhouse-client` from the pinned `clickhouse/clickhouse-server:<version>` image.

No new runtime dependency is added to the workstation.

Prerequisites:
- None among plans.
- The consumer, tan-ng-labs Kansoku Milestone 2, depends on M8.
