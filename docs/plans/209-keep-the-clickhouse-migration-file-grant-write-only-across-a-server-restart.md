---
id: 209
slug: keep-the-clickhouse-migration-file-grant-write-only-across-a-server-restart
title: "Keep the ClickHouse migration FILE grant write-only across a server restart"
kind: exec-plan
created_at: 2026-10-20T15:05:24Z
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-20T15:05:24Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-20T17:22:09Z
      mode: "implement"
      note: "M1 engine proof and M2 fix implemented"
---

# Keep the ClickHouse migration FILE grant write-only across a server restart

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It fixes [BUG-7](../bug-reports/clickhouse-restart-widens-app-database-file-grant.md).


## Purpose / Big Picture

A ClickHouse app database (EP-202) gives its migration user one server-wide grant,
`WRITE ON FILE`, so the app's backup Job can run `BACKUP DATABASE ... TO File(...)`. ClickHouse
26.8 accepts that grant and enforces it as write-only, but it writes the user's access entity to
disk in the legacy form `FILE ON *.*`, which means read and write. After any server restart the
server reloads that form, the migration user holds `READ` as well, and Nagare's catalog
observation refuses every review of every ClickHouse app database on that server with
`app-database-grant-drift: <app>_migration: server-wide READ`. On the operator's intranet two app
databases have been stuck quiesced since a reviewed `db restart`, and the operator has stopped
restarting the shared ClickHouse server.

After this change a grant Nagare issues round-trips through ClickHouse's access storage
unchanged: the rendered ClickHouse server turns on the server setting
`access_control_improvements.enable_read_write_grants`, so `WRITE ON FILE` is stored and reloaded
as `WRITE ON FILE`. For a server that already holds the legacy form, the next plan treats the
reloaded `READ` as something to revoke rather than as drift, revokes it, and the entity is then
rewritten in the precise form, so it never comes back. Nagare's own `db restart` can no longer
invalidate reviews.

Observable outcome: on a server with at least one ClickHouse app database, a reviewed
`nagarectl db restart <server>` followed by `nagarectl db app-database plan --config ...` prints
`no operations`; a quiesce, a restart and a resume complete; and the migration user is refused
when it tries `SELECT * FROM file(...)`.


## Progress

- [x] M1: The defect and the fix are proven against the real engine (`clickhouse/clickhouse-server:26.8` in Docker): with the released configuration a restart turns `WRITE ON FILE` into `READ` and `WRITE`; with `enable_read_write_grants` on a restart keeps `WRITE` alone; a legacy entity reloaded under the new setting shows `READ` once, `REVOKE READ ON FILE` removes it, and it stays removed across the next restart. The re-proven `user-access alpha_migration` fixture blocks and the `SHOW GRANTS` texts are recorded here.
  Done 2026-10-20 on 26.8.29.10 (Colima profile `nagare-mp23`). The config file is copied in
  with `docker cp`; a bind mount from the scratchpad silently became an empty directory and the
  first Run B had no setting. `CREATE TEMPORARY TABLE ON *.*` was granted to `m` in Runs A and B
  only so that `file()` reaches the FILE check.

  ```text
  Run A  before restart: system.grants WRITE; SHOW GRANTS: GRANT FILE ON *.* TO m;
         entity: ATTACH GRANT FILE ON *.* TO m; file() read refused (497)
         after restart:  system.grants READ, WRITE; file() read succeeds
  Run B  REVOKE READ ON FILE on a user without it: ok
         before and after restart: system.grants WRITE; SHOW GRANTS: GRANT WRITE ON FILE TO m;
         entity: ATTACH GRANT WRITE ON FILE TO m; file() read refused (497);
         BACKUP DATABASE default TO File('m1.zip'): BACKUP_CREATED
  Run C  Run A's volume, setting on: system.grants READ, WRITE; SHOW GRANTS: GRANT READ, WRITE ON FILE TO m
         REVOKE READ ON FILE: WRITE; entity: ATTACH GRANT WRITE ON FILE TO m; after restart: WRITE
  No setting: REVOKE READ ON FILE on a user without it is accepted, and after a restart it reduces READ, WRITE to WRITE
  Fixture: the three alpha_migration user-access blocks, run in first-apply order with the setting on:
         every block accepted; server-wide WRITE before and after two restarts, none while off;
         BACKUP DATABASE alpha, DATABASE alpha_ledger: BACKUP_CREATED; file() read refused
         "it's necessary to have the grant READ ON FILE"
  ```
- [x] M2: The code change is in and gated: the rendered ClickHouse server turns the setting on and rolls its pod on a config change; the migration user's statement block always revokes `READ ON FILE`; observation classifies a reloaded `READ` as pending, never drift; the interpreter world restarts a server (legacy and fixed) and the new tests in `AppDatabaseWorldSpec` pass, with the legacy-restart test failing on the unfixed code. `just haskell-style-check` and `just gate-fast` are green.
  Done 2026-10-20 in `9e6ace41`. Before the `Catalog.hs` fix the legacy-restart case failed with
  `app-database-grant-drift: alpha_ch_migration: server-wide READ`; after it the 169 AppDatabase
  cases pass. The restart cases live in `cli/nagarectl/test/AppDatabaseRestartSpec.hs` (the
  world spec would have exceeded the 1000-line module bound), and the suite lists the five
  app-database trees under one `AppDatabase` group. The ClickHouse goldens gained only the
  setting block and `nagare.dev/config-digest: eea29667…` (the SHA-256 of the config text).
  `just gate-fast` green on `9e6ace41`.
- [x] M3: The native proof passes on a disposable local context: `scripts/local-app-database-smoke.sh` gains a final step that confirms the setting is live, restarts `smoke-ch` through review, re-plans to `no operations`, and shows the migration user cannot read through `file()`; `just local-app-database-smoke <context>` ends in `app-database smoke: PASS`.
  Done 2026-10-20 with the packaged CLI at `9e6ace41` on the local context `transition`, whose
  `smoke-ch` predated the setting: step 1 updated it (pod recreated with the config digest) and
  step 2's plan converged the reloaded `READ` without a refusal; the run ended
  `BUG-7: a reviewed restart of smoke-ch leaves the migration grant write-only; re-plan: no
  operations` and `app-database smoke: PASS`. Two earlier attempts stopped on defects of the
  script, fixed in it: EP-207's zeta used the fixed logical names `z` and `z_extra`, which an
  earlier run's retired zeta keeps (now `z_<run>`), and both prune reviews raced the 15-minute
  schedule's run in flight (they now wait for it and ingest it first).
- [x] M4: `docs/user/managed-databases.md` documents the grant, the setting and the one-time effect on existing servers; BUG-7 is `fixed` in `unreleased` with its resolution and a `docs/bug-reports/log.md` entry; the strict bundle validation passes; the work is landed with `just land`.
  Done 2026-10-20: the paragraph, ADR 30's consequence and BUG-7 `fixed` in `unreleased` (commit
  `9e6ace41`); `just user-documentation-validate` and the strict bug-report validation pass.
  The intranet rollout stays with the next release (Validation and Acceptance).
- [x] Intranet (release work, v0.9.0 candidate `e6314c40`, 2026-10-20): the transition
  committed with `platform status` exact on 0.9.0; a reviewed `db create` update of
  `labs-clickhouse` rolled it with the config digest, after which `SHOW GRANTS` printed
  `GRANT READ, WRITE ON FILE TO kansoku_ch_migration` (and the same for
  `isolation_probe_ch_migration`); the resumes of `kansoku-ch` and `isolation-probe-ch` were
  accepted and applied; both configs re-planned to `no operations`; a reviewed `db restart
  labs-clickhouse` (pod 19:52:46Z) left both migration users with `WRITE` only, and both configs
  still re-planned to `no operations` (tan-ng-labs `8d24a35`). Released 2026-10-20 as v0.9.0
  (signed tag `fca04e13` on `e6314c40`, evidence `8ba86a0f`; tan-ng-labs pinned to the tag in
  `32933ad`); BUG-7 is fixed in 0.9.0.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

- Decision: Fix the persistence, not the observation. The rendered ClickHouse server turns on
  `access_control_improvements.enable_read_write_grants`; Nagare does not widen the migration
  user's fixed set to `READ, WRITE ON FILE`.
  Rationale: `READ ON FILE` lets the migration user read every file under the server's
  `user_files` path and read any archive under the backup path with `RESTORE ... AS <own db>`,
  including another app's archive while that app's backup Job holds it on the volume. The
  tenancy boundary of [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md)
  is that an app reaches only its own data. BUG-7's second direction is rejected.
  Date: 2026-10-20

- Decision: A privilege ClickHouse itself derives from a fixed grant on reload (today only
  `READ` on `FILE` for the migration role) is a *revoked grant*: every user-access statement
  block revokes it, and observing it is pending (`keeps server-wide READ`), never drift. It is
  declared in one place, `Nagare.Dsl.AppDatabase.appDatabaseServerRevokedGrants`, beside the
  fixed set, and it is not part of the user's declaration digest.
  Rationale: Nagare cannot distinguish the reloaded `READ` from a hand `GRANT READ ON FILE` on
  the same user, so a hand grant of exactly that privilege to a migration user is revoked by the
  next plan instead of refused. Revoking restores the declared state, which is the safe
  direction; `READ` on any other user, and any other server-wide privilege, stay drift. Keeping
  the digest unchanged means no app database re-plans because of this change alone.
  Date: 2026-10-20

- Decision: A ClickHouse config change rolls the server pod through a pod-template annotation
  `nagare.dev/config-digest` carrying the SHA-256 of the rendered config file. The ConfigMap name
  (`nagare-db-<name>-mem`) and its key (`low-memory.xml`) are kept.
  Rationale: the config file is mounted with `subPath`, and Kubernetes never updates a
  `subPath` file in a running container, so without a template change the setting would not be
  live until an unrelated restart and the defect would silently persist. Renaming the ConfigMap
  or its key would retire and recreate reviewed resources for no gain. Every ClickHouse server
  created before this change therefore sees one reviewed StatefulSet update and restarts once,
  exactly as it did when v0.7.0 turned on SQL access management.
  Date: 2026-10-20

- Decision: The interpreter world tracks which users' access entities are stored in the legacy
  form (`legacyEntities`), beside the server setting `legacySourceGrants`. After the setting is
  turned off (the rollout), a restart still reloads `READ` until the next converge rewrites the
  entity, so the second restart case expects one more `update` per migration user after the
  rollout instead of `[]`.
  Rationale: M1 Run C. Turning the setting on does not rewrite stored entities. The plan's
  first draft expected an empty re-plan right after the rollout restart, which the engine
  contradicts. M3 already expected this path natively.
  Date: 2026-10-20

- Decision: An existing ClickHouse server takes the setting through its own reviewed `db create`
  update, not through the release transition, which carries no database-server scopes. The user
  guide and the v0.9.0 notes say so; the notes shipped in the candidate claimed the transition
  updated the servers, and are corrected on master and in the release description.
  Rationale: The intranet's 0.8.0 → 0.9.0 transition (host stage, 210 verifications and the
  stamp, then an empty review) left `labs-clickhouse` unchanged; `db create clickhouse
  labs-clickhouse --config databases/nagare/ClickHouse.hs ...` planned exactly its ConfigMap and
  StatefulSet.
  Date: 2026-10-20

- Decision: The intranet rollout is release work, not this plan's acceptance. The plan completes
  on the engine proof, the interpreter-world tests and the local native run (ADR 25). The
  operator sequence for `labs-clickhouse` is written in Validation and Acceptance so the
  release can run it.
  Rationale: operator rule of 2026-10-10 (releases prove the full gate, the EP-172 rehearsal and
  the intranet upgrade); cloud mutations need the operator's go-ahead.
  Date: 2026-10-20


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

**Terms.** An *app database* is a reviewed tenant of a shared managed database server: its
own logical databases, a *migration* user that owns them and a *runtime* user that reads and
writes rows (`docs/user/managed-databases.md`, "Sharing one server between apps"). Each user,
logical database and credential Secret is a *member* of the app database's inventory scope.
*Observation* is Nagare reading the server's catalogs (`system.users`, `system.grants`, ...)
and *classification* compares what it finds with the declaration: a member is absent, complete,
incomplete (the next plan converges it) or *drifted* (it holds access Nagare never grants, which
is refused with `app-database-grant-drift` and never repaired). A *review* is a saved plan
applied with `nagarectl inventory apply DIR --yes`. ClickHouse's *access storage* is the
directory `/var/lib/clickhouse/access/` on the server's data volume; each SQL-created user is an
*access entity* stored as one `.sql` file of `ATTACH` statements that the server replays at
start-up.

**Where the grant comes from.** `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs` holds the fixed
grant sets. `appDatabaseServerGrants ClickHouse MigrationRole` is `[Grant "file" ["WRITE"]]` and
every other engine and role has none. `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`
renders it in `renderUserAccess`: for ClickHouse the block is `ALTER USER ... HOST ANY|NONE;`,
then `GRANT WRITE ON FILE TO <user>;` when the user is enabled or `REVOKE WRITE ON FILE FROM
<user>;` when it is not, then one `GRANT`/`REVOKE` per allow-listed exception (EP-204), then
`ALTER USER ... SETTINGS ...`. Every rendering is pinned byte for byte to a block of
`cli/nagarectl/test/fixtures/app-database/clickhouse.sql` by `cli/nagarectl/test/AppDatabaseSqlSpec.hs`
(`ClickHouse commands match the proven fixture`); the blocks were proven by hand against the
real engine, and the fixture's header says how. The three blocks that carry the FILE grant are
`user-access alpha_migration on`, `user-access alpha_migration off` and
`user-access alpha_migration on with declared access`.

**Where the refusal comes from.** `renderObserveClickHouse` in the same `Sql.hs` selects
`user_name, access_type, database, table, column, is_partial_revoke, grant_option` from
`system.grants`. `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs` parses the rows
(`parseClickHouseCatalog`): a row with a null `database` becomes a bare server-grant token on the
user, so the migration user's `serverGrants` is `["WRITE"]` on a healthy server. `classifyUser`
builds `revocableGrants` from the fixed set plus the desired and accepted exceptions and reports
any other server-wide token as drift (`"server-wide " <> ...`), which the adapter in
`cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabase.hs` turns into
`ObservationUnavailable (grantDriftCode <> ": " <> reason)` for plan, preflight, recovery and
converge alike. A token the user holds but should not (`kept`) that *is* revocable is reported as
pending (`"keeps server-wide " <> ...`), the member is `MemberIncomplete`, and the planner issues an
`update` whose converge sends `SetUserAccess`, i.e. the statement block above.

**Where the server is rendered.** `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` holds
`engineMemoryConfig`, the one `config.d` file Nagare gives ClickHouse (a memory cap and a mark
cache size). `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` renders it into the ConfigMap
`nagare-db-<name>-mem` (`configMapValue`, key `low-memory.xml`), mounts it with `subPath` at
`/etc/clickhouse-server/config.d/low-memory.xml` (`volumeMounts`, `podVolumes`) and sets
`CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1` (`literalEnv`). Goldens:
`cli/nagare-dsl/test/golden/db-clickhouse.configmap.yaml` and `db-clickhouse.statefulset.yaml`,
checked by `cli/nagare-dsl/test/Spec.hs`. A reviewed `db restart` stamps
`nagare.dev/restartedAt` into the accepted StatefulSet's pod-template annotations
(`cli/nagarectl/src/Nagare/Inventory/DataService.hs`, `stampPodTemplate`); any pod-template change
makes the StatefulSet replace its pod. An existing server receives a changed rendering as one
reviewed update, either through `nagarectl db create <engine> <name> ...` on an accepted server
("For a standard create or update" in `docs/user/managed-databases.md`) or through a release
transition, as `docs/releases/v0.7.0.md` records for the access-management change.

**Where the backup uses the grant.** `appDatabaseDumpShell ClickHouse` in
`cli/nagarectl/src/Nagare/Database/Backup.hs` runs, as the migration user,
`BACKUP DATABASE a, DATABASE b TO File('${BACKUP_RUN_ID}.zip')`, copies the archive off the
server volume and removes it. `BACKUP ... TO File(...)` is authorised against `WRITE ON FILE`;
nothing in Nagare needs `READ ON FILE`.

**What ClickHouse does, verified in its source (`src/Access/Common/AccessRightsElement.cpp`,
master, 2026-10-20).** `makeBackwardCompatible()` reads
`access_control.isEnabledReadWriteGrants()`; when it is false and an element's flags are exactly
`READ`, `WRITE` or `READ | WRITE` on a named source, it replaces them by the legacy source
privilege (`WRITE ON FILE` becomes `FILE`) and clears the parameter. `formatElementsWithoutOptions`
applies it unless called in *precise* mode, and the access storage writes entities in the
non-precise form, which is why `/var/lib/clickhouse/access/<uuid>.sql` holds
`ATTACH GRANT FILE ON *.*`. On parse, `replaceDeprecated()` turns the legacy `FILE` into
`READ | WRITE` with parameter `FILE` unconditionally. `system.grants`
(`src/Storages/System/StorageSystemGrants.cpp`) writes one row per access type with `database`
null for a global element, so a reloaded user shows `READ` and `WRITE`. The setting is consulted
only when formatting and serialising grants, never when enforcing them (ClickHouse PR #117895),
which is why the running server honoured write-only access when the fixture was proven. The
ClickHouse documentation states that the separation of `READ` and `WRITE` grants for sources is
available from 25.7 "only with server setting
`access_control_improvements.enable_read_write_grants`", default `false`. The intranet server runs
26.8.28.14; the fixture was proven on 26.8.29.

**The interpreter world.** `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs` is the fake
server the adapter is tested against (ADR 25): `World` holds users with `serverGrants`, databases,
Secrets, sessions and a `server` identity map (`podUID`, `podStarted`, `serverUUID`,
`processStarted`). `interpret` applies each `CatalogCommand` with the engine's proven semantics;
for ClickHouse `SetUserAccess` replaces the *managed* server grants (the fixed set and every
allow-listed exception) and leaves any other token alone, which is how hand drift survives a
converge. `cli/nagarectl/test/AppDatabaseWorldSpec.hs` drives it with `setup`, `converge`,
`replan`, `observeAll`, `seedDrift`, `quiesceAlpha`, `sessionReviewFor` and `applySession`.
`cli/nagarectl/src/Nagare/Inventory/Adapters/AppDatabaseSessions.hs` records the server identity
when a drain or resume step is *prepared* and refuses the step if the identity changed before its
apply; a resume reviewed after a restart therefore passes that check.

**Native proofs.** `scripts/local-app-database-smoke.sh` (run as `just local-app-database-smoke
<context>`) exercises app databases on a `mode=local` k3d context with the packaged `nagarectl`,
with helpers `n`, `apply`, `ch_admin`, `ch_as`, `refused`, `expect` and `log`; its step 5a asserts
the servers were not restarted during a maintenance window. `scripts/clickhouse-drill.sh` shows a
reviewed restart of a server (`saved restart db restart "$DB" -n "$NS"` and the wait for a new
pod UID). The packaged binary comes from
`nix build --no-link --print-out-paths "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl"`.

**ADRs.** [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md): the
declaration is the authority for users and grants, grants are explicit lists, access Nagare never
grants is refused as drift and not revoked, and turning on SQL access management restarted
existing ClickHouse servers once. This plan keeps those rules and adds one engine-derived
revoked grant beside the fixed set. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
the defect is reproduced and fixed in the interpreter world first; the local native run
confirms. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
is the scope model the reviews use. No ADR needs to change: the decision that a server setting
owns the persistence form is recorded in ADR 30's consequences at completion (one sentence).

**Related plans.** [EP-202](202-host-per-app-databases-on-shared-postgresql-and-clickhouse-servers.md)
chose the write-only FILE grant (its Decision Log, item 2); [EP-204](204-let-app-databases-declare-reviewed-grant-exceptions-and-resource-limits.md)
added the exception grants and the `revocable` notion in `classifyUser`;
[EP-205](205-quiesce-one-app-database-and-back-it-up-on-demand.md) added quiesce, drain and
resume; [EP-199](199-prepare-clickhouse-26-8-for-first-production-use.md) made 26.8 the default
and proved a reviewed restart keeps data.


## Plan of Work

### M1: Prove the defect and the fix against the real engine

Run `clickhouse/clickhouse-server:26.8` three times in Docker (Colima on the operator's machine
is fine; the smoke script already pulls this image). Run A uses the released configuration
(`CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1`, no `access_control_improvements`) on a named volume:
create a user, `GRANT WRITE ON FILE`, read back `SHOW GRANTS`, `system.grants` and the access
file, restart the container, read back again. Expected: before the restart `system.grants` holds
`WRITE` only while `SHOW GRANTS` and the access file already show the legacy `FILE ON *.*`; after
the restart `system.grants` holds `READ` and `WRITE`. Run B mounts a `config.d` file with
`enable_read_write_grants` on and repeats the sequence on a fresh volume. Expected: `SHOW GRANTS`
prints `GRANT WRITE ON FILE TO m`, the access file holds `ATTACH GRANT WRITE ON FILE TO m`, and
after the restart `system.grants` still holds `WRITE` alone; as the user, `SELECT * FROM
file('x.csv')` is refused with code 497 and `BACKUP DATABASE default TO File('m1.zip')` is
allowed. Run C starts the setting-on configuration on Run A's volume (the legacy entity):
`system.grants` shows `READ` and `WRITE`; `REVOKE READ ON FILE FROM m` leaves `WRITE`; the access
file now holds the precise form; a restart keeps `WRITE` alone. Also confirm in Run B that
`REVOKE READ ON FILE FROM m` on a user that does not hold it succeeds, as the fixture already
relies on for `REVOKE SELECT ON system.parts`.

Record the three transcripts in Progress (short, `text` fences). Re-prove the three
`user-access alpha_migration` blocks with their new `REVOKE READ ON FILE FROM alpha_migration;`
line in Run B, in the order the block sends them, and update the fixture header's date and
version.

### M2: The code change

In `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs` add, beside `appDatabaseServerGrants`,

```haskell
-- | Privileges the engine adds to a user by itself from the persisted form of
-- a fixed grant, so they are revoked by every user-access block and pending,
-- never drift, when observed. ClickHouse without
-- @enable_read_write_grants@ stores @WRITE ON FILE@ as the legacy @FILE@,
-- which reloads as READ and WRITE (BUG-7).
appDatabaseServerRevokedGrants :: Engine -> AppDatabaseRole -> [Grant]
appDatabaseServerRevokedGrants ClickHouse MigrationRole = [Grant "file" ["READ"]]
appDatabaseServerRevokedGrants _ _ = []
```

and export it. Do not add it to the user's declaration digest in
`cli/nagare-dsl/src/Nagare/Resource/AppDatabase.hs` (the `serverGrants` field of the digest
object stays as it is).

In `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs`, `renderUserAccess ClickHouse`, after
the fixed-grant line(s) emit `"REVOKE " <> privilege <> " ON " <> T.toUpper objectClass <> " FROM "
<> user <> ";"` for every privilege of `appDatabaseServerRevokedGrants ClickHouse role`, whether
the user is enabled or not. The three fixture blocks gain the line right after the `WRITE ON FILE`
line (M1 proves them in that order).

In `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs`, `classifyUser`, add the revoked
privileges to `revocableGrants` only. `wantedGrants` is unchanged, so a reloaded `READ` is
reported by the existing `keeps server-wide READ` pending reason and converges through the
normal `update`. Update the module comment that explains drift to mention the revoked grants.

In `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` extend `engineMemoryConfig ClickHouse` to

```xml
<clickhouse>
  <max_server_memory_usage>1610612736</max_server_memory_usage>
  <mark_cache_size>268435456</mark_cache_size>
  <access_control_improvements>
    <enable_read_write_grants>true</enable_read_write_grants>
  </access_control_improvements>
</clickhouse>
```

and update its comment. In `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` give the
StatefulSet's `spec.template.metadata` an `annotations` object with
`nagare.dev/config-digest` set to the lowercase SHA-256 hex of the UTF-8 bytes of that config,
only for an engine whose `engineMemoryConfig` is `Just` (`Crypto.Hash` from `crypton`, as
`Nagare.Resource.Canonical` already uses). Re-accept the two ClickHouse goldens and read the
diff: the ConfigMap gains the block, the StatefulSet gains the annotation, nothing else moves.

In `cli/nagarectl/test/Nagare/Test/World/AppDatabase.hs`: add a `legacySourceGrants :: Bool`
field to `World` (`False` in `newWorld`: the server Nagare now renders); include the revoked
privileges in the `managed` list of the ClickHouse `SetUserAccess` branch so a converge always
drops `READ`; export `restartServer :: World -> World`, which gives the server a new `podUID`,
`podStarted` and `processStarted` and, when the engine is ClickHouse and `legacySourceGrants` is
on, gives every user holding `READ` or `WRITE` both (the reload of the legacy `FILE` entity).
Keep `worldCatalog` a pure view; the restart is a world step the test applies with
`modifyIORef'`, not a fault.

In `cli/nagarectl/test/AppDatabaseWorldSpec.hs` add a ClickHouse-only group
`server restart (BUG-7)` with these cases, using the existing helpers. First, on the default
world: converge, restart, `replan` is `[]` and `observeAll` has no refusal. Second, on a legacy
world (`#legacySourceGrants .~ True` after `setup`): converge, restart, `observeAll` has no
refusal, `replan` is exactly one `update` per migration user (alpha's and beta's) and none for
any runtime user; converge; both migration users' `serverGrants` are `["WRITE"]`; `replan` is
`[]`; a further legacy restart brings `READ` back and the plan converges again without refusing;
then clear the flag (the config rollout), restart, `replan` is `[]`. Third, the reporter's
situation: quiesce alpha's runtime user and drain (`quiesceAlpha`, `sessionReviewFor ... DrainStep`,
`applySession`), restart the legacy server, then prepare and apply the resume step and converge
the resumed scope: nothing refuses, alpha's runtime user can log in again, and alpha's migration
user ends with `["WRITE"]`. Fourth, the boundary: `READ` seeded on the runtime user with `onUser`
is still refused as drift, and `READ` seeded on the migration user is revoked by the next
converge (Decision Log). Before fixing `Catalog.hs`, run the second case and confirm it fails with
`app-database-grant-drift: alpha_migration: server-wide READ`; that is the regression guard.

### M3: The native proof on a local context

Append a final step to `scripts/local-app-database-smoke.sh`, after the EP-207 step and before
`echo "app-database smoke: PASS"`, so the earlier "servers not restarted" assertions are
untouched. The step: `expect` that `SHOW GRANTS FOR <alpha-ch migration user>` printed by
`ch_admin` contains `GRANT WRITE ON FILE TO` (the setting is live; the legacy form would print
`GRANT FILE ON *.*`); record the pod UID of `smoke-ch-0`; save and apply
`n db restart smoke-ch -n "$NS" --save-plan "$REVIEWS/restart-smoke-ch"`; wait until the pod UID
changes and the StatefulSet is rolled out and `ch_admin 'SELECT 1'` answers; `expect` that
`system.grants` for the two migration users (alpha-ch's and, if still present, beta-ch's retired
one) with `database IS NULL` lists no `READ`; `n db app-database plan --config` with the
configuration in force at that point prints `no operations`; and `refused "alpha-ch migration
reads a file" ch_as alpha-ch-migration "SELECT * FROM file('bug7.csv')"`. Log the step as
`BUG-7: a reviewed restart of smoke-ch leaves the migration grant write-only; re-plan: no
operations`. Run the whole script on a disposable local context with the packaged `nagarectl`
built from the committed revision.

A context that already holds `smoke-ch` from an earlier `nagarectl` has a server without the
setting. Extend step 1 of the script: when the accepted StatefulSet's pod template lacks the
`nagare.dev/config-digest` annotation (`kubectl -n "$NS" get statefulset smoke-ch -o
jsonpath='{.spec.template.metadata.annotations.nagare\.dev/config-digest}'` is empty), run the
same `n db create clickhouse smoke-ch ...` line as a standard update and wait for the rollout.
That is the existing-server path run natively: the pod restarts once with the setting on, the
migration users of the earlier run's app databases reload holding `READ`, and step 2's plan
applies one `update` per migration user before its re-plan prints `no operations`. A fresh
context takes the create branch and never sees `READ`.

### M4: Documentation, the bug report, and landing

In `docs/user/managed-databases.md`, "Sharing one server between apps", add a short paragraph
after the drift sentence: the migration user's only server-wide grant is `WRITE ON FILE`, which
the app's backup needs; Nagare's ClickHouse servers turn on
`access_control_improvements.enable_read_write_grants` so the grant survives a server restart as
written; a ClickHouse server created before this setting sees one reviewed StatefulSet update
and restarts once on its next `db create` update or release transition, and each of its app
databases then plans one `update` per migration user that revokes the `READ` the old storage
form had reloaded. Run `just user-documentation-validate`.

Mark BUG-7 `status: fixed`, `fixedVersion: unreleased`, with a `resolution` naming this plan and
the fix commit (the docs commit comes after the fix commit, since a commit cannot name its own
hash), add the `docs/bug-reports/log.md` entry under today's date, and run the strict bundle
validation. Land with `just land` after a green `just gate-fast` on a clean tree.


## Concrete Steps

All commands run from the repository root unless stated. Replace `$SCRATCH` by this session's
scratchpad directory.

M1, the engine proof:

```bash
mkdir -p "$SCRATCH/bug7" && cd "$SCRATCH/bug7"
cat > access-control.xml <<'XML'
<clickhouse>
  <access_control_improvements>
    <enable_read_write_grants>true</enable_read_write_grants>
  </access_control_improvements>
</clickhouse>
XML
q() { docker exec "$1" clickhouse-client --user admin --password pw --query "$2"; }
entity() { docker exec "$1" sh -c 'grep -h "GRANT" /var/lib/clickhouse/access/*.sql'; }
grants() { q "$1" "SELECT access_type FROM system.grants WHERE user_name = 'm' AND database IS NULL ORDER BY 1"; }

# Run A: the released configuration on a named volume.
docker run -d --name bug7-a -v bug7-legacy:/var/lib/clickhouse \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 -e CLICKHOUSE_USER=admin -e CLICKHOUSE_PASSWORD=pw \
  clickhouse/clickhouse-server:26.8
sleep 5
q bug7-a "CREATE USER m IDENTIFIED WITH sha256_password BY 'pw-m' HOST ANY"
q bug7-a "GRANT WRITE ON FILE TO m"
grants bug7-a; q bug7-a "SHOW GRANTS FOR m"; entity bug7-a
docker restart bug7-a && sleep 5
grants bug7-a
docker stop bug7-a

# Run B: the setting on, a fresh volume.
docker run -d --name bug7-b -v bug7-fixed:/var/lib/clickhouse \
  -v "$PWD/access-control.xml:/etc/clickhouse-server/config.d/access-control.xml:ro" \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 -e CLICKHOUSE_USER=admin -e CLICKHOUSE_PASSWORD=pw \
  clickhouse/clickhouse-server:26.8
sleep 5
q bug7-b "CREATE USER m IDENTIFIED WITH sha256_password BY 'pw-m' HOST ANY"
q bug7-b "GRANT WRITE ON FILE TO m"
q bug7-b "REVOKE READ ON FILE FROM m"          # must succeed although m never held it
q bug7-b "GRANT BACKUP ON default.* TO m"       # the database-level half a BACKUP needs
grants bug7-b; q bug7-b "SHOW GRANTS FOR m"; entity bug7-b
docker restart bug7-b && sleep 5
grants bug7-b
docker exec bug7-b clickhouse-client --user m --password pw-m --query "SELECT * FROM file('bug7.csv')" ; echo "exit $?"
docker exec bug7-b clickhouse-client --user m --password pw-m --query "BACKUP DATABASE default TO File('m1.zip')"

# Run C: the setting on over the legacy entity from Run A.
docker run -d --name bug7-c -v bug7-legacy:/var/lib/clickhouse \
  -v "$PWD/access-control.xml:/etc/clickhouse-server/config.d/access-control.xml:ro" \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 -e CLICKHOUSE_USER=admin -e CLICKHOUSE_PASSWORD=pw \
  clickhouse/clickhouse-server:26.8
sleep 5
grants bug7-c                                   # READ, WRITE: the legacy entity reloaded
q bug7-c "REVOKE READ ON FILE FROM m"
grants bug7-c; entity bug7-c                    # WRITE; ATTACH GRANT WRITE ON FILE TO m
docker restart bug7-c && sleep 5
grants bug7-c                                   # WRITE
docker rm -f bug7-a bug7-b bug7-c; docker volume rm bug7-legacy bug7-fixed
```

Expected, Run A (the defect):

```text
WRITE
GRANT FILE ON *.* TO m
ATTACH GRANT FILE ON *.* TO m;
READ
WRITE
```

Expected, Run B (the fix) and Run C (the migration path): `WRITE` alone after each restart,
`GRANT WRITE ON FILE TO m`, `ATTACH GRANT WRITE ON FILE TO m;`, the `file()` read refused with
`Code: 497` and a non-zero exit, and the `BACKUP` accepted.

M2, the tests (run the two Haskell suites serially, never in parallel):

```bash
cabal test nagare-dsl-test --project-dir=cli/nagare-dsl --test-options='-p clickhouse --accept'
git diff --stat cli/nagare-dsl/test/golden/     # exactly the two ClickHouse goldens
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/AppDatabase/"' --test-show-details=direct
just haskell-style-check
just gate-fast
```

Commit the fix with the Conventional Commits type `fix(app-database)` and the trailer
`ExecPlan: docs/plans/209-keep-the-clickhouse-migration-file-grant-write-only-across-a-server-restart.md`.

M3, the native run (a `mode=local` context on the k3d cluster, from a clean environment as
`docs/user/local-development.md` describes):

```bash
NAGARECTL="$(nix build --no-link --print-out-paths "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl")/bin/nagarectl"
env -i HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}" \
  NAGARE_SMOKE_CONTEXT=<context> NAGARECTL="$NAGARECTL" scripts/local-app-database-smoke.sh
```

Expected tail:

```text
HH:MM:SS app-database smoke: BUG-7: a reviewed restart of smoke-ch leaves the migration grant write-only; re-plan: no operations
app-database smoke: PASS
```

M4, the bundle and the landing:

```bash
just user-documentation-validate
okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
just gate-fast
just land
```


## Validation and Acceptance

Required for this plan:

1. M1's three transcripts match the expectations above on `clickhouse/clickhouse-server:26.8`.
2. `AppDatabaseSqlSpec` pins the new `REVOKE READ ON FILE` line in the three migration blocks,
   and the fixture header names the proof run.
3. In `AppDatabaseWorldSpec`, the legacy-restart case refuses with
   `app-database-grant-drift: alpha_migration: server-wide READ` on the unfixed `Catalog.hs` and
   passes on the fixed one; all four restart cases pass; every existing app-database, EP-204,
   EP-205 and EP-206 case still passes.
4. The ClickHouse goldens show the setting block and the `nagare.dev/config-digest` annotation;
   the Postgres and Redis goldens are unchanged.
5. `just local-app-database-smoke <context>` passes with the new final step.
6. `just gate-fast` is green on the fix commit and on the docs commit; `just land` starts the
   full gate.

On the intranet, after the release that carries the fix (release work, operator go-ahead
required; recorded here so the release can run it and close BUG-7's current state):

1. Upgrade the `tan-ng-labs` context to that release. The transition review updates
   `labs-clickhouse`'s ConfigMap and StatefulSet; its pod restarts once. Confirm the setting is
   live: `SHOW GRANTS FOR kansoku_ch_migration` as the administrator names `READ` and `WRITE`
   `ON FILE` (the legacy entity reloaded, now shown in the precise form), not
   `GRANT FILE ON *.*`.
2. `nagarectl db app-database resume kansoku-ch --save-plan DIR` is no longer refused; its review
   carries the runtime user's reopening and an `update` of `kansoku_ch_migration` with reason
   `keeps server-wide READ`. Apply it. Repeat for `isolation-probe-ch`.
3. `nagarectl db app-database plan --config ...` prints `no operations`.
4. A reviewed `nagarectl db restart labs-clickhouse --save-plan DIR`, applied, followed by the
   same plan, prints `no operations`, and `SELECT access_type FROM system.grants WHERE user_name
   LIKE '%_migration' AND database IS NULL` lists `WRITE` only. Then BUG-7's `fixedVersion` is the
   release's version.


## Idempotence and Recovery

Every statement Nagare adds is idempotent: `REVOKE READ ON FILE` on a user that does not hold it
succeeds (M1 confirms), and a repeated converge sends the same block. The Docker runs use named
volumes that the last command removes; rerunning M1 from the top is safe. Re-accepting goldens is
safe as long as the diff is read. The smoke script reuses its publications on rerun; the new
step's reviewed restart is a normal `db restart` and can be repeated.

If the setting turns out not to be honoured by 26.8 in Run B, stop: the plan's premise is wrong,
record the transcript in Progress and return to the operator with the observation; do not fall
back to accepting `READ` (Decision Log).

A server created before this change that restarts *before* its reviewed update still behaves as
BUG-7 describes, and the fixed `nagarectl` already classifies its `READ` as pending, so its app
databases can be planned, resumed and converged; the `READ` comes back on each further restart
until the server's update lands. Nothing is lost either way.


## Interfaces and Dependencies

- `Nagare.Dsl.AppDatabase.appDatabaseServerRevokedGrants :: Engine -> AppDatabaseRole -> [Grant]`
  (new, `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`), consumed by
  `Nagare.Database.AppDatabase.Sql.renderUserAccess`,
  `Nagare.Database.AppDatabase.Catalog.classifyUser` and the world's `SetUserAccess` branch.
- `Nagare.Dsl.Database.engineMemoryConfig` (changed content) and the pod-template annotation
  `nagare.dev/config-digest` rendered by `Nagare.Dsl.Database.Render`.
- `Nagare.Test.World.AppDatabase.restartServer :: World -> World` and the `World` fields
  `legacySourceGrants :: Bool` and `legacyEntities :: Set Text` (test-only; Decision Log).
- The proven fixture `cli/nagarectl/test/fixtures/app-database/clickhouse.sql` and the goldens
  `cli/nagare-dsl/test/golden/db-clickhouse.{configmap,statefulset}.yaml`.
- ClickHouse server setting `access_control_improvements.enable_read_write_grants` (25.7 and
  later; the default and intranet line is 26.8). Docker (Colima) for M1; a `mode=local` k3d
  context and the packaged `nagarectl` for M3.
- No new Haskell dependency: `nagare-dsl` already depends on `crypton`, and
  `Nagare.Resource.Canonical` already imports `Crypto.Hash` for its digests.
