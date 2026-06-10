---
id: 47
slug: scheduled-database-backups-restore-commands-and-retention
title: "Scheduled database backups, restore commands, and retention"
kind: exec-plan
created_at: 2026-06-10T14:25:20Z
intention: "intention_01ktryacjaezzbezmkt5j93abq"
master_plan: "docs/masterplans/9-managed-databases-for-nagare.md"
---

# Scheduled database backups, restore commands, and retention

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare can now run a managed database — a PostgreSQL, Redis, or ClickHouse instance declared in typed
config, provisioned by `nagarectl db create`, reachable in-cluster, and holding a generated password
in a Kubernetes Secret (this is the work of EP-43, EP-44, and EP-45, the sibling plans of this
MasterPlan). But that database has **no backup story**. If its data disk is lost, its contents are
gone, and there is no way to take a dump, schedule recurring dumps, or restore one. This ExecPlan
closes that gap so a managed database is a first-class part of the same GCS backup flow the app
volumes (`docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md`) and the host
Postgres (`scripts/backup-postgres.sh`) already use.

A reader who has never seen this repository needs three terms up front, defined here so the rest of
the plan needs no outside knowledge:

- **Managed database**: a long-lived, single-replica database (PostgreSQL, Redis, or ClickHouse) that
  Nagare runs as a Kubernetes **StatefulSet** (a controller for a workload that keeps a stable pod
  identity and durable disk across restarts), reachable by other pods at a stable in-cluster DNS name
  via a **ClusterIP Service** (an internal-only address, never exposed to the public internet). Its
  generated password lives in a Kubernetes **Secret** named `nagare-db-<name>`. The typed model and
  the renderer that produce these objects are owned by EP-44; the lifecycle commands (`db create`,
  `db list`, `db get`, `db shell`, `db restart`, `db delete`) and the password generation are owned by
  EP-45. **This plan assumes those exist** and extends them.
- **Backup (logical dump)**: a point-in-time, engine-appropriate export of a database's *data* — a
  `pg_dump` SQL script for Postgres, an RDB file for Redis, a native export for ClickHouse — gzipped
  and uploaded as one object to Google Cloud Storage (GCS). It is **not** a block-level disk image;
  the `local-path` storage this PaaS uses has no disk-snapshot driver (the same constraint EP-36
  documents for app volumes).
- **GCS backup bucket**: the single bucket `tan-nb-exp-nagare-backups`, already created by Pulumi
  (`infra/pulumi/src/components/NagarePerimeter.ts`), on which the VM's attached service account holds
  `roles/storage.objectAdmin`. Backups authenticate to it with **ADC (Application Default
  Credentials)** — the keyless auth Google client libraries use, which on this VM resolves to the
  node service account. There are no key files.

After this change, an operator can do four concrete, observable things:

1. **Take an on-demand backup of a live managed database into GCS.** Running `nagarectl db backup
   mydb` launches a short-lived in-cluster Kubernetes Job that connects to the database `mydb` using
   its managed credential Secret, produces an engine-appropriate gzipped dump, and uploads it to
   `gs://tan-nb-exp-nagare-backups/databases/mydb/<timestamp>.<ext>` (the extension is `.sql.gz` for
   Postgres, `.rdb.gz` for Redis, `.native.gz` for ClickHouse). They confirm it with `gsutil ls
   gs://tan-nb-exp-nagare-backups/databases/mydb/` and see the object appear.

2. **Rely on recurring scheduled backups.** Each managed database gets a Kubernetes **CronJob** (a
   controller that runs a Job on a cron schedule) that performs the same backup daily and prunes old
   backups, so a database is protected without anyone remembering to run a command. The CronJob is
   rendered by this plan and provisioned at `db create` time; `nagarectl db backup mydb --dry-run`
   prints both the one-shot Job and the CronJob YAML for inspection without touching the cluster.

3. **Restore a chosen backup, scratch-first.** Running `nagarectl db restore mydb <backup-id>`
   restores a chosen dump. Where the engine allows it, the restore lands in a *disposable* target (a
   scratch database name or a scratch instance) so a restore never clobbers live data unless the
   operator explicitly targets the live database. Listing the available backups to choose a
   `<backup-id>` is `gsutil ls gs://tan-nb-exp-nagare-backups/databases/mydb/`.

4. **Find the procedure in the runbook.** The disaster-recovery runbook
   (`docs/runbooks/disaster-recovery.md`) and the user backup guide
   (`docs/user/backups-and-disaster-recovery.md`) gain a managed-database row, a restore procedure,
   and a restore-drill description, so the backup is documented end to end.

Old backups are pruned so the bucket does not grow without bound (retention, default keep-last-7),
reusing the **exact** pure pruning helper EP-36 already wrote (`snapshotsToPrune` in
`cli/nagarectl/src/Nagare/Storage/Snapshot.hs`). The mechanism reuses the existing GCS bucket, the
existing `tan-nb-exp` project-isolation conventions, the existing `kubectl`/`gsutil` shell-out
plumbing, and the existing timestamp format — it adds one coherent capability without inventing new
infrastructure.


## Progress

Milestone 1 — on-demand `nagarectl db backup NAME` to GCS, with retention:

- [ ] Add the `Nagare.Database.Backup` module to `cli/nagarectl/nagarectl.cabal` `exposed-modules`.
- [ ] Implement the pure GCS object-path helper `dbBackupObjectPath` and the per-engine extension
      table `backupExt`.
- [ ] Reuse (import, do not reimplement) `Nagare.Storage.Snapshot.snapshotsToPrune` for keep-last-N
      retention.
- [ ] Implement the pure backup-Job manifest renderer `renderBackupJob` (engine-image dump container +
      `google/cloud-sdk:slim` upload container sharing an `emptyDir`).
- [ ] Wire `runDbBackup` (apply Job, wait, prune) into `cli/nagarectl/src/Nagare/Database/Backup.hs`.
- [ ] Add the `backup` subcommand to EP-45's `db` subparser in `cli/nagarectl/app/Main.hs` (IP4 extend).
- [ ] Add pure tests for `dbBackupObjectPath`, `backupExt`, and the prune-reuse to
      `cli/nagarectl/test/Spec.hs`.
- [ ] Resolve the engine-image-vs-gsutil tension (Decision Log) and prove it via `--dry-run` Job YAML.
- [ ] Validate live: `nagarectl db backup mydb` then `gsutil ls` shows the object. (Deferable to EP-48.)

Milestone 2 — scheduled backups (CronJob renderer + provisioning):

- [ ] Implement the pure CronJob manifest renderer `renderBackupCronJob` (wraps the M1 Job template
      with a `schedule`).
- [ ] Add the pure default-schedule helper `defaultBackupSchedule` (daily) and a `--schedule` override.
- [ ] Provision the CronJob at `db create` (extend EP-45's create path) and re-provision idempotently.
- [ ] `nagarectl db backup mydb --dry-run` prints both the Job and the CronJob YAML.
- [ ] Add pure tests for the CronJob renderer / schedule helper.

Milestone 3 — `nagarectl db restore NAME BACKUP_ID`, scratch-first:

- [ ] Implement the pure restore-Job manifest renderer `renderRestoreJob` (download + engine restore).
- [ ] Implement `runDbRestore` (resolve backup object, apply Job, wait), scratch-first where feasible.
- [ ] Add the `restore` subcommand to EP-45's `db` subparser (IP4 extend).
- [ ] Document listing available backups (`gsutil ls gs://…/databases/<name>/`) and the `--into` target.
- [ ] Add pure tests for `renderRestoreJob` inputs / object resolution.

Milestone 4 — runbook + user-guide integration:

- [ ] Add the managed-database row + restore sub-step to `docs/runbooks/disaster-recovery.md`.
- [ ] Add the managed-database row + procedure to `docs/user/backups-and-disaster-recovery.md`.
- [ ] Describe the restore drill (against a disposable database) with exact VM commands.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Resolve the engine-image-vs-gsutil tension with a **two-container backup Job sharing an
  `emptyDir`** — a "dump" container running the engine's own client image writes the dump to a shared
  scratch directory, and an "upload" container running `google/cloud-sdk:slim` (which has `gsutil` but
  not `psql`/`redis-cli`/`clickhouse-client`) gzips and `gsutil cp`s it to GCS. The two run sequentially
  within one pod: the dump container is an **initContainer** (runs to completion first), and the upload
  container is the main container (runs after all initContainers succeed).
  Rationale: `google/cloud-sdk:slim` — the image EP-36's snapshot Job uses — has `gsutil` and a shell
  but lacks every database client; the official engine images (`postgres:<v>`, `redis:<v>`,
  `clickhouse/clickhouse-server:<v>`) have the client but lack `gsutil`. Three concrete options were
  weighed. **(a) Two containers / shared `emptyDir`** (chosen): no custom image to build, push, or
  maintain; both images are official and already pullable; the initContainer/main ordering guarantees
  the dump finishes before the upload starts; the dump never transits the operator's machine. **(b)
  `kubectl exec` from the CLI host capturing stdout piped to a local `gsutil`**: simpler to write but
  moves the entire dump through the operator's workstation (slow, and the workstation may not have
  `gsutil` configured), and it depends on a reachable, stable pod — the database StatefulSet pod is
  stable, but routing the whole backup through the operator is the wrong data path and breaks the
  scheduled-CronJob case entirely (a CronJob has no operator at the keyboard). Rejected. **(c) Bake a
  small combined image** with both the engine client and `gsutil`: introduces a build/push/registry
  dependency for a personal PaaS and three per-engine images to keep current with engine versions —
  too much maintenance for the benefit. Rejected. The `emptyDir` is sized modestly and the dump is
  gzipped in the upload container so the scratch volume holds the uncompressed dump only transiently;
  for very large databases a future plan can stream `engine-dump | gzip | gsutil cp -` within a single
  combined image, noted as a follow-up.
  Date: 2026-06-10

- Decision: GCS object layout is
  `gs://tan-nb-exp-nagare-backups/databases/<name>/<timestamp>.<ext>` in the **existing** backup
  bucket, with the timestamp formatted exactly like `scripts/backup-postgres.sh` and EP-36
  (`date -u +%Y%m%dT%H%M%SZ`, e.g. `20260610T141503Z`), and a per-engine extension: `.sql.gz`
  (Postgres), `.rdb.gz` (Redis), `.native.gz` (ClickHouse).
  Rationale: this is the contract MasterPlan Integration Point IP6 fixes
  (`docs/masterplans/9-managed-databases-for-nagare.md`). It sits beside the existing `volumes/`,
  `postgres/`, and `litestream/` prefixes in the same bucket, so the node service account already has
  write access and `forceDestroy:false` already protects it. A per-`<name>` prefix keeps each
  database's backups independently listable and prunable. The shared timestamp format keeps every
  backup class sortable the same way, which is exactly what `snapshotsToPrune` relies on (fixed-width
  zero-padded timestamps sort lexicographically as newest-first under a descending sort).
  Date: 2026-06-10

- Decision: Reuse the **pure** `snapshotsToPrune :: Int -> [Text] -> [Text]` from
  `cli/nagarectl/src/Nagare/Storage/Snapshot.hs` for keep-last-N retention rather than writing a new
  pruning function.
  Rationale: it is exactly the keep-last-N policy needed, already exported, already unit-tested, and
  already idempotent (re-running on an already-pruned set returns `[]`). The MasterPlan IP6 explicitly
  directs reuse. Reimplementing it would duplicate logic and risk drift. Default keep count is 7
  (matching EP-36's `--keep` default), exposed as `--keep N` on `db backup`.
  Date: 2026-06-10

- Decision: Run backups and restores inside short-lived in-cluster Kubernetes **Jobs** (and a
  **CronJob** for the schedule), not via a host-side script or `kubectl exec`.
  Rationale: the database StatefulSet pod is stable, but the backup must (a) authenticate with the
  managed credential Secret `nagare-db-<name>` (IP3), (b) write to GCS via the node service account's
  ambient ADC, and (c) run unattended on a schedule. A dedicated Job that mounts the Secret and runs in
  the cluster satisfies all three and reuses EP-36's exact Job mechanics (`google/cloud-sdk:slim`,
  `GCE_METADATA_HOST=169.254.169.254` so ADC resolves the node service account, `restartPolicy: Never`,
  `backoffLimit: 0`, `CLOUDSDK_CORE_PROJECT=tan-nb-exp`). The CronJob is the same Job template wrapped
  in a schedule. This matches the in-cluster snapshot pattern in `Nagare.Storage.Snapshot.runSnapshot`.
  Date: 2026-06-10

- Decision: Provision the scheduled backup **CronJob at `db create` time** (extending EP-45's create
  path), with a default daily schedule, rather than introducing a separate `db backup --schedule`
  enable/disable subcommand.
  Rationale: a managed database is backup-included by default — the safe default, mirroring EP-36's
  "backup-included by default" policy for volumes — so the CronJob should exist as soon as the database
  exists. Provisioning it at create keeps the surface small (no extra subcommand to remember) and means
  a database is never silently unprotected. A `--schedule CRON` override on `db backup` lets an operator
  re-render the CronJob with a different cadence (it is an idempotent `kubectl apply` of the same named
  CronJob), and `RetentionPolicy = Delete` on the database opts it out of scheduled backups (the CronJob
  is not created), exactly as `Delete` opts an app volume out of snapshots in EP-36. This is recorded
  explicitly because the CronJob is the one piece of this plan that lives in EP-45's create path; if
  EP-45 is not yet wired to call this plan's renderer at create time, M2 provisions the CronJob from
  `db backup` on first run instead (a documented fallback, see Idempotence and Recovery).
  Date: 2026-06-10

- Decision: Restores are **scratch-first / disposable-target where the engine allows it**, mirroring
  `scripts/restore-volume.sh` and `scripts/restore-postgres.sh`.
  Rationale: a restore that overwrites a live database is catastrophic if the wrong backup is chosen.
  For Postgres, restore into a scratch database name (`<db>_restore_scratch`) so row counts can be
  compared before promotion — exactly what `scripts/restore-postgres.sh` does (it restores into
  `notes_restore_scratch`). For ClickHouse, restore into a scratch database. For Redis (whose restore
  is "place `dump.rdb` and restart", which is inherently whole-instance), restore into a *disposable
  scratch Redis instance* the restore Job stands up, so the live instance is untouched; promoting is a
  deliberate manual step. The live target is used only when the operator passes an explicit
  `--into live` flag. This keeps a botched or repeated restore from clobbering live data.
  Date: 2026-06-10

- Decision: Defer the **live** backup→`gsutil ls`→restore-drill leg to EP-48 (the docs-and-examples
  plan), fully specified here, while everything else is provable offline.
  Rationale: the live cluster is frequently unreachable (the VM `nagare-01` is often TERMINATED; IAP
  forwards only SSH/22, so a workstation `kubectl`/`gsutil` cannot reach the k3s API; a real backup
  needs a *running* managed database, which is EP-45's live `db create`). EP-36 set this precedent
  exactly — it deferred the live `storage snapshot … → gsutil ls` and restore drill to EP-37. The pure
  helpers (object path, extension table, prune reuse) are unit-tested, and the Job/CronJob/restore
  manifests are proven via `--dry-run`. The exact VM commands for the live drill are written in
  Validation and Acceptance so EP-48 (or anyone with a running database) can run them verbatim.
  Date: 2026-06-10

- Decision: Every gcloud/gsutil reference is scoped to `tan-nb-exp`; the in-cluster Jobs set
  `CLOUDSDK_CORE_PROJECT=tan-nb-exp`, and any new shell helper carries the project-isolation preflight
  from the repository `CLAUDE.md`.
  Rationale: the repository mandates project isolation; EP-36's snapshot Job and `scripts/restore-volume.sh`
  already encode the in-cluster project pin and the shell preflight respectively, so this plan mirrors
  them line-for-line.
  Date: 2026-06-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan extends three already-built things — a managed-database substrate, a `db` command group, and
a GCS backup flow — and reuses a fourth — a pure retention helper. Read this section as if you know
nothing about the repository; every file is named by full path.

**The managed-database substrate you back up (EP-43/EP-44/EP-45 — sibling plans of this MasterPlan).**
The MasterPlan `docs/masterplans/9-managed-databases-for-nagare.md` is checked in; treat its Integration
Points as the source of truth for the contracts this plan consumes:

- From **EP-44 (IP1)**: a typed `Database` record lives in `cli/nagare-dsl/src/Nagare/Dsl/Database.hs`
  with fields `dbName :: DatabaseName`, `engine :: Engine` (where `Engine = Postgres | Redis |
  ClickHouse`), `version :: EngineVersion`, `namespace :: Namespace`, `size :: Quantity`,
  `resources :: Maybe Resources`, and `retention :: RetentionPolicy` (where `RetentionPolicy = Retain |
  Delete`, reused from `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`). This plan reads the loaded `Database`,
  never the raw JSON, and uses `engine`, `dbName`, `namespace`, and `retention`.
- From **EP-44 (IP2)**: the renderer `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` produces, per
  database, a StatefulSet running the engine's official image at the pinned version, a ClusterIP
  Service giving stable in-cluster DNS (e.g. `mydb.personal.svc.cluster.local`), a PVC for data, and
  the *structure* of the credential Secret. This plan does not render those; it renders backup/restore
  Jobs that *connect to* the running database by its Service DNS name.
- From **EP-43/EP-44/EP-45 (IP3)**: the managed credential **Secret** is named deterministically
  `nagare-db-<name>`, labelled `nagare.dev/managed-by: nagarectl`, `nagare.dev/database: <name>`,
  `nagare.dev/engine: <engine>`, and its keys are engine-specific but fixed — Postgres:
  `POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB`, `DATABASE_URL`; Redis: `REDIS_PASSWORD`,
  `REDIS_URL`; ClickHouse: `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_USER`, `CLICKHOUSE_URL`. The backup and
  restore Jobs authenticate by **referencing this Secret's keys as environment variables** (via
  `valueFrom.secretKeyRef`), never by re-deriving credentials. The password is generated once by EP-45's
  `db create` and lives only in this Secret.
- From **EP-45 (IP4)**: `cli/nagarectl/app/Main.hs` gains a `db` subparser (following the existing
  `storage`/`secret`/`app` subparser pattern visible in the same file) with subcommands `list`, `create`,
  `get`, `shell`, `restart`, `delete`, plus `Nagare.Database.*` modules under
  `cli/nagarectl/src/Nagare/Database/` (e.g. `Discover.hs` for label-based discovery of a database's
  resources). **This plan extends that subparser with `backup` and `restore` and adds modules under the
  same namespace — it does not fork them** (the MasterPlan IP4 mandate: "EP-47 must extend, not fork").

If, when M1 implementation begins, EP-45's `db` subparser or `Nagare.Database.Discover` is not yet
present, implement the minimal piece needed (e.g. a `discoverDatabase :: Text -> IO (Either Text
DbRef)` that runs `kubectl get statefulset,svc,secret -l nagare.dev/database=<name> -o name`) inside
`Nagare.Database.Backup` with a `-- TODO(EP-45): replace with Nagare.Database.Discover` note, and
record the deviation in the Decision Log. This mirrors how EP-36 handled a not-yet-present
`Nagare.Storage.Discover`.

**The GCS backup flow you mirror (EP-36 — checked in).**
`docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md` and its module
`cli/nagarectl/src/Nagare/Storage/Snapshot.hs` are the direct precedent. Read that module: it is the
database-level analog you are writing. Specifically:

- The pure object-path helper `snapshotObjectPath :: Text -> Text -> Text -> Text` builds
  `volumes/<app>/<volume>/<timestamp>.tar.gz`; your `dbBackupObjectPath` builds
  `databases/<name>/<timestamp>.<ext>` the same way (bucket kept out so the path is trivially testable).
- The pure timestamp formatter `snapshotTimestamp :: UTCTime -> Text` produces `YYYYMMDDTHHMMSSZ` via
  `Data.Time.Format.formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ"`. **Reuse it** — it is exported.
- The pure retention selector `snapshotsToPrune :: Int -> [Text] -> [Text]` (defined as
  `drop (max 0 n) (sortBy (comparing Down) names)`) is the keep-last-N policy. **Reuse it** — do not
  reimplement.
- The in-cluster Job renderer `renderSnapshotJob :: SnapshotJobInputs -> ByteString` builds a `batch/v1`
  Job via `Data.Yaml.encode` of an `aeson` `Value` (not a text template — this quotes shell pipelines
  as proper YAML string scalars with no escaping pitfalls). It uses image `google/cloud-sdk:slim`, sets
  `GCE_METADATA_HOST=169.254.169.254` (so ADC resolves the node service account — pods on this node
  cannot resolve `metadata.google.internal` by name, a fact `cluster/examples/sqlite-litestream/`
  established) and `CLOUDSDK_CORE_PROJECT=tan-nb-exp`, with `restartPolicy: Never` and `backoffLimit: 0`
  so a failure surfaces rather than looping, and labels the Job `nagare.dev/managed-by: nagarectl`. Your
  backup/restore Job renderers extend this exact shape with a second (init) container for the engine
  client. Note: `renderSnapshotJob` has **no golden test** — the Job is applied, not compared to a
  cluster contract; the pure path/prune logic is what the suite covers. Follow that convention.
- The IO driver `runSnapshot :: Deployment -> Text -> Text -> Int -> IO ()` applies the Job via a temp
  file + `kubectl apply -f` (mirroring `cli/nagarectl/src/Nagare/Deploy.hs` `applyManifests`), waits
  with `kubectl wait --for=condition=complete --timeout=600s job/<name> -n <ns>`, deletes the completed
  Job, then lists existing objects under the prefix with `gsutil ls`, computes `snapshotsToPrune keep`,
  and deletes the surplus with `gsutil rm`. On failure it prints `kubectl logs job/<name> --tail 50`
  and exits non-zero. Your `runDbBackup` follows this shape exactly.

**The existing host-Postgres backup mechanics (`scripts/backup-postgres.sh`, checked in).** This script
is the closest existing Postgres→GCS mechanic. It runs `pg_dump --no-owner --no-privileges "$DB" | gzip
-9 > "$OUT"` then `gsutil -o "GSUtil:parallel_composite_upload_threshold=150M" cp "$OUT" "gs://${BUCKET}/postgres/..."`,
with the timestamp `STAMP="$(date -u +%Y%m%dT%H%M%SZ)"` and the project-isolation preflight
(`PROJECT=tan-nb-exp` … `refusing to run …`) as its first lines. Build the Postgres dump command in the
backup Job's dump container on this (`pg_dump --no-owner --no-privileges` piped to a file in the shared
`emptyDir`). The `scripts/restore-postgres.sh` companion restores into a **scratch** database
(`notes_restore_scratch`) and prints a row count to compare — the scratch-first shape your Postgres
restore Job reproduces.

**The scratch-first volume restore (`scripts/restore-volume.sh`, checked in, written by EP-36).** Read
this script: it is the structural template for a restore that lands in a disposable target. It carries
the project-isolation preflight verbatim, creates a *disposable* scratch PVC (never the live one), runs
a one-off Job that `gsutil cp "$OBJECT" - | tar -C /restore -xzf -` (ADC via `GCE_METADATA_HOST`,
project pinned to `tan-nb-exp`), waits for the Job, prints a file listing for comparison, and ends with
"Promote manually." Your restore Job reproduces this download-then-restore-into-scratch shape with the
engine-appropriate restore command in place of the `tar`.

**The CLI you extend (`cli/nagarectl/app/Main.hs`, checked in).** This is the `nagarectl` entry point,
an `optparse-applicative` program. The top-level `subparser` (in `opts`, around the `commandParser`
where-binding) lists `command "deploy"`, `command "site"`, `command "storage"`, etc. EP-45 adds
`command "db" dbCmd`. The pattern for a subparser with subcommands is visible in `storageCmd` /
`storageSubparser` (which already grew a `snapshot` subcommand from EP-36 alongside `list` and
`inspect`) and in `appSubparser`. The `Command` sum type enumerates every command; `main` dispatches it
in a `case` (e.g. `Storage scmd -> runStorage scmd`). EP-45 introduces a `Db DbCommand` constructor and
a `DbCommand` sum type. **You add `DbBackup`/`DbRestore` constructors to `DbCommand` and `backup`/`restore`
commands to `dbSubparser`, and `runDb` dispatches them** — the same way `StorageSnapshot` was added to
`StorageCommand` and `storageSubparser` by EP-36.

**The kubectl / process conventions.** `cli/nagarectl/src/Nagare/Deploy.hs` shows the house pattern for
shelling out: it imports `Cradle` and builds commands as `cmd "kubectl" & addArgs [...]`, run with
`run_` (no output) or `run` (capturing `StdoutUntrimmed`/`StdoutRaw`). `Nagare.Storage.Snapshot` already
demonstrates the full pattern (apply via temp file, `kubectl wait`, `gsutil ls`/`gsutil rm`). Reuse this
exact style. `StdoutUntrimmed` is `Text` (no decode); `StdoutRaw` is `ByteString` (for `aeson`).

**The runbook and user docs you extend.** `docs/runbooks/disaster-recovery.md` has a "Backup inventory"
code block (around line 27) mapping each data class to its restore path — it already lists `SQLite
app data`, `Postgres data`, and `App volume data`. It also has a "7. Restore data" section (around line
169) that runs the restore scripts. `docs/user/backups-and-disaster-recovery.md` has a "What to back up"
table (around line 21) that already lists "App volumes (PVCs)". You add a **managed-databases** entry to
each, plus a restore sub-step and a restore-drill description in the runbook. EP-48
(`docs/plans/48-managed-databases-docs-and-end-to-end-examples.md`) references these documents, so keep
them accurate.

**The cabal file.** `cli/nagarectl/nagarectl.cabal` lists `library` `exposed-modules`; the `Nagare.Storage.*`
entries are at the end of that list. You add `Nagare.Database.Backup` and `Nagare.Database.Restore`
there (and EP-45 will have added `Nagare.Database.Discover`). The `time`, `bytestring`, `text`, `aeson`,
`yaml`, `cradle`, `temporary` dependencies this plan needs are all already declared (they are used by
`Nagare.Storage.Snapshot`).


## Plan of Work

The work is four milestones. M1 delivers on-demand `db backup` with the two-container Job and retention.
M2 delivers the scheduled-backup CronJob. M3 delivers scratch-first `db restore`. M4 delivers the
runbook/user-doc integration. Each milestone is independently verifiable; M1–M3 are provable offline via
`--dry-run` and pure unit tests, with the live legs deferable to EP-48 per the Decision Log.

### Milestone 1 — `nagarectl db backup NAME` to GCS, with retention

**Scope and outcome.** At the end of M1, running `nagarectl db backup mydb` resolves the database `mydb`
(its engine, namespace, Service DNS, and credential Secret name), launches a short-lived Kubernetes Job
that produces an engine-appropriate gzipped dump and uploads it to
`gs://tan-nb-exp-nagare-backups/databases/mydb/<timestamp>.<ext>`, then prunes older backups for that
database down to the last N (default 7). `nagarectl db backup mydb --dry-run` prints the rendered Job
YAML. The pure path/extension/prune-reuse logic is unit-tested. A novice can verify a live backup with
`gsutil ls`.

**New module `cli/nagarectl/src/Nagare/Database/Backup.hs`.** Register it in
`cli/nagarectl/nagarectl.cabal` under `library` `exposed-modules` (add `Nagare.Database.Backup` after the
`Nagare.Database.*` entries EP-45 added, or after `Nagare.Storage.Snapshot` if EP-45's are not yet
present). The module owns:

- The pure GCS object-path helper `dbBackupObjectPath :: Text -> Text -> Text -> Text` taking the
  database `name`, the `timestamp`, and the `ext` (without leading dot, e.g. `"sql.gz"`), returning the
  object **path within the bucket**: `"databases/" <> name <> "/" <> timestamp <> "." <> ext`. A
  companion `dbBackupGsUrl :: Text -> Text -> Text -> Text -> Text` prepends `"gs://" <> bucket <> "/"`.
  Keep the bucket out of the path helper so the path is trivially testable without a bucket name —
  exactly as `snapshotObjectPath` does.

- The pure per-engine extension table `backupExt :: Engine -> Text` returning `"sql.gz"` for `Postgres`,
  `"rdb.gz"` for `Redis`, and `"native.gz"` for `ClickHouse`. This is the engine data dimension of the
  GCS layout. (Import `Engine(..)` from `Nagare.Dsl.Database`.)

- The timestamp: **reuse** `Nagare.Storage.Snapshot.snapshotTimestamp :: UTCTime -> Text` (import it).

- Retention: **reuse** `Nagare.Storage.Snapshot.snapshotsToPrune :: Int -> [Text] -> [Text]` (import
  it). Do not reimplement.

- The Job manifest renderer `renderBackupJob :: BackupJobInputs -> ByteString` where `BackupJobInputs`
  carries the namespace, a unique Job name (e.g. `nagare-dbbackup-<name>-<timestamp>` lowercased and
  truncated to a DNS-safe 63 chars), the engine, the engine client image (`postgres:<v>` /
  `redis:<v>` / `clickhouse/clickhouse-server:<v>`), the database's in-cluster Service host (e.g.
  `mydb`), the credential Secret name (`nagare-db-<name>`), the destination `gs://…` URL, and the shared
  scratch path inside the Job (e.g. `/dump`). It produces a `batch/v1` Job that:
  - has an **initContainer** named `dump` running the engine client image, mounting the shared `emptyDir`
    at `/dump`, with the password and connection vars wired from the credential Secret via
    `valueFrom.secretKeyRef`, running the engine dump command (table below) to write
    `/dump/backup.<rawext>` (the uncompressed dump);
  - has a **main container** named `upload` running `google/cloud-sdk:slim`, mounting the same `emptyDir`
    at `/dump`, with env `DEST` (the `gs://…` URL), `GCE_METADATA_HOST=169.254.169.254`, and
    `CLOUDSDK_CORE_PROJECT=tan-nb-exp`, running `set -e; gzip -9 -c /dump/backup.<rawext> | gsutil -o
    GSUtil:parallel_composite_upload_threshold=150M cp - "$DEST"` so the gzip+upload streams with no
    extra temp file;
  - declares one `emptyDir` volume `dump`;
  - has `restartPolicy: Never` and `backoffLimit: 0`;
  - carries the labels `nagare.dev/managed-by: nagarectl` and `nagare.dev/database: <name>`.

  Build the Job via `Data.Yaml.encode` of an `aeson` `Value`, exactly as `renderSnapshotJob` does, so
  shell pipelines are quoted as proper YAML scalars. No golden test (the Job is applied, not compared);
  the pure path/ext logic is what the suite covers.

  **Per-engine backup commands (the dump container's shell), refined against EP-43's chosen approaches:**

  ```text
  Engine      Dump command (writes the uncompressed dump to /dump/backup.<rawext>)
  ---------   -------------------------------------------------------------------------------
  Postgres    pg_dump --no-owner --no-privileges -h <svc> -U "$POSTGRES_USER" -d "$POSTGRES_DB"
              > /dump/backup.sql            (PGPASSWORD from the Secret's POSTGRES_PASSWORD)
  Redis       redis-cli -h <svc> -a "$REDIS_PASSWORD" --rdb /dump/backup.rdb
              (or: redis-cli ... SAVE then copy the dump.rdb the server wrote)
  ClickHouse  clickhouse-client -h <svc> --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"
              --query "BACKUP DATABASE <db> TO Disk('backups','/dump/backup')"  (the approach EP-43
              selects: native BACKUP, or clickhouse-backup, or per-table dumps — match EP-43's choice)
  ```

  The upload container's `<rawext>` is `sql` / `rdb` / `native` matching the dump file, and the final
  GCS object extension is `<rawext>.gz` from `backupExt`. (Postgres `pg_dump` reads `PGPASSWORD` from
  the environment; set it from the Secret's `POSTGRES_PASSWORD` key via `secretKeyRef`.)

- The IO driver `runDbBackup :: Database -> Text -> Int -> Maybe Text -> IO ()` (database, bucket, keep
  count, optional `--schedule` for M2) that:
  1. resolves the bucket name (from `--bucket`, then `NAGARE_BACKUP_BUCKET`, defaulting to
     `tan-nb-exp-nagare-backups`);
  2. reads `name = databaseNameText (db ^. #dbName)`, `ns = namespaceText (db ^. #namespace)`,
     `eng = db ^. #engine`, the Service host (the database's stable DNS name, `name`), the Secret name
     `nagare-db-<name>`, and the engine client image at the pinned version;
  3. computes `ts <- snapshotTimestamp <$> getCurrentTime`, `ext = backupExt eng`,
     `dest = dbBackupGsUrl bucket name ts ext`, and the Job name;
  4. renders the Job, applies it with the temp-file + `kubectl apply -f` pattern, and `kubectl wait
     --for=condition=complete --timeout=600s job/<name> -n <ns>` (printing `kubectl logs --tail 50` and
     exiting non-zero on failure);
  5. on success deletes the completed Job (`kubectl delete job/<name> -n <ns> --ignore-not-found`), then
     lists existing objects under `gs://<bucket>/databases/<name>/` with `gsutil ls`, computes
     `snapshotsToPrune keep`, and deletes the surplus with `gsutil rm`;
  6. prints `Backup written: <dest>`.

**Main.hs wiring (IP4 — extend, do not fork).** In `cli/nagarectl/app/Main.hs`: add a `DbBackup`
constructor to EP-45's `DbCommand` sum type carrying the database identity options plus `--bucket`,
`--keep`, and (M2) `--schedule`; add a `<> command "backup" dbBackupCmd` line to EP-45's `dbSubparser`
(mirroring how `command "snapshot"` was added to `storageSubparser`); and dispatch it in `runDb`
(`DbBackup … -> runDbBackup …`). The database identity comes from the loaded typed config (the same way
`storage` commands take the resolved `Deployment`) or, if EP-45's `db` commands resolve a database by
name from the cluster, follow EP-45's resolution path. If EP-45 is not yet present, add `command "db"
dbCmd` to the top-level `subparser` with just the `backup` subcommand and a minimal `Db DbCommand`
constructor, noting the deviation.

**Tests.** In `cli/nagarectl/test/Spec.hs` add a `testGroup "Nagare.Database.Backup"` with cases for
`dbBackupObjectPath` (exact string `databases/mydb/20260610T141503Z.sql.gz`), `backupExt` (one case per
engine), and a prune-reuse case asserting `snapshotsToPrune 7` over nine fixed-width timestamped
`databases/mydb/…` names returns the two oldest. Pure; no cluster.

**Acceptance for M1.** `cabal test` passes including the new group; `nagarectl db backup mydb --dry-run`
prints the two-container Job YAML; and on a live cluster with a running database, `nagarectl db backup
mydb` followed by `gsutil ls gs://tan-nb-exp-nagare-backups/databases/mydb/` shows the new object
(deferable to EP-48).

### Milestone 2 — scheduled backups (CronJob renderer + provisioning)

**Scope and outcome.** At the end of M2, each managed database has a Kubernetes CronJob that runs the M1
backup on a default daily schedule and prunes old backups; `nagarectl db backup mydb --dry-run` prints
both the one-shot Job and the CronJob YAML; and the CronJob is provisioned at `db create` (or, fallback,
on first `db backup`). A database declared `retention = Delete` gets no CronJob (opt-out, matching EP-36).

**Add to `Nagare.Database.Backup`:**

- The pure default-schedule helper `defaultBackupSchedule :: Text` returning a daily cron expression,
  e.g. `"17 3 * * *"` (03:17 UTC daily — a quiet, deterministic time; the odd minute avoids the
  top-of-hour thundering herd). A `--schedule CRON` CLI override replaces it.

- The pure CronJob renderer `renderBackupCronJob :: BackupCronInputs -> ByteString` where
  `BackupCronInputs` carries the same fields as `BackupJobInputs` plus the `schedule :: Text`. It
  produces a `batch/v1` CronJob whose `spec.schedule` is the cron expression, whose
  `spec.jobTemplate.spec` is the **same** Job spec body `renderBackupJob` builds (factor the shared Job
  `spec` into a helper `backupJobSpecValue :: BackupJobInputs -> Value` so the Job and CronJob share one
  definition — do not duplicate the two-container body), with `spec.concurrencyPolicy: Forbid` (never
  overlap a running backup), `spec.successfulJobsHistoryLimit: 3`, `spec.failedJobsHistoryLimit: 1`. The
  CronJob is named deterministically `nagare-dbbackup-<name>` (no timestamp — it is the singleton
  schedule for that database) and labelled `nagare.dev/managed-by: nagarectl`, `nagare.dev/database:
  <name>`. The CronJob's pruning is handled by the same prune step the Job's command performs after the
  upload (add a third sequential shell step in the upload container: after `gsutil cp`, run a small
  keep-last-N `gsutil ls | tail`-style prune inline — or, simpler and matching EP-36, leave pruning to
  the `nagarectl`-side `runDbBackup` for on-demand backups and add an inline shell prune in the CronJob's
  upload container so the scheduled path is self-pruning without a `nagarectl` process at the keyboard).

**Provisioning.** Extend EP-45's `db create` path to call `renderBackupCronJob` and `kubectl apply` the
CronJob after the database's StatefulSet/Service/PVC/Secret are applied, **unless** `retention = Delete`
(opt-out). If EP-45's create path is not yet wired to this plan, the fallback is: `runDbBackup` renders
and `kubectl apply`s the CronJob on first run (idempotent `apply` of the named CronJob), so a database
gains its schedule the first time it is backed up. Record which path was taken in the Decision Log.

**Dry-run.** `nagarectl db backup mydb --dry-run` prints `--- Backup Job manifest ---` then the Job YAML,
then `--- Backup CronJob manifest ---` then the CronJob YAML (mirroring how `deploy --dry-run` prints
the PVC then the Service manifests).

**Tests.** Add cases for `defaultBackupSchedule` (exact string) and `renderBackupCronJob` (assert the
encoded YAML contains `kind: CronJob`, the schedule, `concurrencyPolicy: Forbid`, and the shared
two-container body — a substring/`Data.Yaml.decode` round-trip check, since there is no cluster golden).

**Acceptance for M2.** `cabal test` passes; `nagarectl db backup mydb --dry-run` prints both manifests;
the CronJob YAML carries the default daily schedule and the same backup body as the one-shot Job.

### Milestone 3 — `nagarectl db restore NAME BACKUP_ID`, scratch-first

**Scope and outcome.** At the end of M3, `nagarectl db restore mydb 20260610T141503Z` (the `BACKUP_ID`
is the timestamp, or the full object name) restores that backup into a **disposable scratch target**
(scratch database for Postgres/ClickHouse; scratch instance for Redis), never over live data unless
`--into live` is passed; `nagarectl db restore mydb <id> --dry-run` prints the restore Job YAML; and the
operator is told how to list available backups to pick a `BACKUP_ID`.

**New module `cli/nagarectl/src/Nagare/Database/Restore.hs`.** Register it in the cabal `exposed-modules`.
It owns:

- The pure backup-object resolver `resolveBackupObject :: Text -> Text -> Text -> Text -> Text` taking
  bucket, name, ext, and the `BACKUP_ID` (a bare timestamp), returning the `gs://…` URL — i.e.
  `dbBackupGsUrl bucket name backupId ext`. If the operator passes a full `gs://…` URL as the
  `BACKUP_ID`, use it verbatim (a pure `isGsUrl :: Text -> Bool` guard).

- The pure restore-Job renderer `renderRestoreJob :: RestoreJobInputs -> ByteString` where
  `RestoreJobInputs` carries the namespace, a unique Job name (`nagare-dbrestore-<name>-<ts>`), the
  engine, the engine client image, the Service host, the credential Secret name, the source `gs://…`
  URL, the **scratch target** identifier (e.g. `<db>_restore_scratch`), a `liveTarget :: Bool` flag, and
  the shared scratch path. It produces a two-container `batch/v1` Job mirroring the backup Job but
  reversed: an **initContainer** `download` running `google/cloud-sdk:slim` that `gsutil cp "$SRC" - |
  gunzip > /dump/backup.<rawext>` (ADC via `GCE_METADATA_HOST`, project pinned), and a **main container**
  `restore` running the engine client image that loads the dump into the scratch (or, with `--into live`,
  the live) target. Per-engine restore commands:

  ```text
  Engine      Restore command (reads /dump/backup.<rawext> into the scratch target)
  ---------   -------------------------------------------------------------------------------
  Postgres    createdb -h <svc> -U "$POSTGRES_USER" <db>_restore_scratch  (idempotent: drop+create);
              psql -h <svc> -U "$POSTGRES_USER" -d <db>_restore_scratch -f /dump/backup.sql;
              psql ... -c "SELECT count(*) FROM ..."   (print a count to compare, like restore-postgres.sh)
  Redis       stand up a disposable scratch redis in the Job (redis-server &), then
              redis-cli --pipe < /dump/backup.rdb  (or place dump.rdb and restart the scratch server);
              the LIVE instance is untouched unless --into live
  ClickHouse  clickhouse-client -h <svc> --query "RESTORE DATABASE <db> AS <db>_restore_scratch
              FROM Disk('backups','/dump/backup')"  (match EP-43's chosen restore approach)
  ```

  When `liveTarget` is `True`, the scratch identifier is replaced by the live database name and the Job
  prints a loud warning first. The default is always scratch-first.

- The IO driver `runDbRestore :: Database -> Text -> Text -> Bool -> IO ()` (database, bucket,
  `BACKUP_ID`, liveTarget) that resolves the source object, renders the Job, applies it, waits, prints
  the Job's logs (the row count / restored listing for comparison), and — for the scratch case — ends
  with a "Promote manually" message like `scripts/restore-volume.sh`. It deletes the completed Job on
  success.

**Main.hs wiring (IP4 — extend).** Add a `DbRestore` constructor to `DbCommand` carrying the database
identity, the positional `BACKUP_ID`, `--bucket`, and an `--into live` switch (default scratch); add `<>
command "restore" dbRestoreCmd` to `dbSubparser`; dispatch `DbRestore … -> runDbRestore …` in `runDb`.

**Tests.** Add a `testGroup "Nagare.Database.Restore"` with cases for `resolveBackupObject` (bare
timestamp → full `gs://…` URL; full URL passed through unchanged) and `isGsUrl`. Pure; no cluster.

**Acceptance for M3.** `cabal test` passes; `nagarectl db restore mydb 20260610T141503Z --dry-run`
prints the restore Job YAML targeting the scratch identifier; and on a live cluster the restore lands in
the scratch target with the live database untouched (deferable to EP-48).

### Milestone 4 — runbook + user-guide integration

**Scope and outcome.** At the end of M4, the disaster-recovery runbook and the user backup guide
document the managed-database backup/restore procedure and a restore drill, so the backup is documented
end to end and EP-48 can reference it.

**Runbook update (`docs/runbooks/disaster-recovery.md`).** Add a row to the "Backup inventory" code block
(beside the existing `App volume data` row):

```text
Managed database data ..... pg_dump/.rdb/.native dumps in
                            gcs://<backupBucket>/databases/<name>/      -> nagarectl db restore (scratch)
```

Add a managed-database sub-step under "7. Restore data" showing `nagarectl db restore <name> <backup-id>`
(scratch-first) and the observation (the scratch database's row count, or the restored listing, matches
the source). Note that `nagarectl server status`'s backup-freshness report should also surface the
`databases/` prefix age (a follow-up for the status probe; mention it).

**User-doc update (`docs/user/backups-and-disaster-recovery.md`).** Add a row to the "What to back up"
table:

```text
| Managed databases | `nagarectl db backup` / scheduled CronJob → GCS (`databases/<name>/`); keep-last-N retention | ✅ EP-47 |
```

Add a short "Managed databases: backed up by default" section describing: on-demand `nagarectl db
backup NAME`; the per-database CronJob that runs daily; the per-engine dump formats; the keep-last-N
retention (`--keep`, default 7); scratch-first restore with `nagarectl db restore NAME BACKUP_ID`; and
that a `retention = Delete` database is treated as throwaway and gets no scheduled backup.

**Restore-drill description.** In the runbook, describe a drill against a *disposable* database: create a
throwaway database, write known data, `nagarectl db backup`, then `nagarectl db restore` into the
scratch target and compare. Give the exact VM commands (see Validation and Acceptance), noting they run
on the VM or through a forwarded kube API since IAP forwards only SSH/22.

**Acceptance for M4.** Both docs render with the new rows/sections; the runbook's managed-database
restore command matches the M3 CLI surface.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` inside the dev shell
(`nix develop` or `direnv allow`), which provides `cabal`/`ghc`, `kubectl`, and `gcloud`/`gsutil`, unless
a different working directory is stated.

### M1 steps

1. Register the new module. Edit `cli/nagarectl/nagarectl.cabal`, adding `Nagare.Database.Backup` to the
   `library` `exposed-modules` list (after the `Nagare.Database.*` entries EP-45 added, or after
   `Nagare.Storage.Snapshot`).

2. Create `cli/nagarectl/src/Nagare/Database/Backup.hs` with the pure helpers (`dbBackupObjectPath`,
   `dbBackupGsUrl`, `backupExt`), the `BackupJobInputs` record + `renderBackupJob` (and the shared
   `backupJobSpecValue` helper), and the `runDbBackup` IO driver — importing `snapshotTimestamp` and
   `snapshotsToPrune` from `Nagare.Storage.Snapshot` and `Engine(..)`/`Database`/accessors from
   `Nagare.Dsl.Database`.

3. Wire the subcommand into `cli/nagarectl/app/Main.hs`: add the `DbBackup` constructor to `DbCommand`,
   the `dbBackupCmd` `ParserInfo`, the `<> command "backup" dbBackupCmd` line in EP-45's `dbSubparser`,
   and the `DbBackup … -> runDbBackup …` dispatch in `runDb`.

4. Build:

   ```bash
   cabal build nagarectl
   ```

   Expected: it compiles. A typical first failure is a missing import (`Data.Time`, `Cradle`,
   `Nagare.Dsl.Database`); add it and rebuild.

5. Add pure tests to `cli/nagarectl/test/Spec.hs` and run them:

   ```bash
   cabal test nagarectl-test
   ```

   Expected tail:

   ```text
   nagarectl
     Nagare.Database.Backup
       dbBackupObjectPath builds databases/<name>/<ts>.<ext>: OK
       backupExt maps each engine to its extension:           OK
       snapshotsToPrune keeps the last N newest (reused):     OK
   All N tests passed
   ```

6. Inspect the rendered Job offline (no cluster):

   ```bash
   cabal run nagarectl -- db backup mydb --dry-run
   ```

   Expected (abbreviated): a `--- Backup Job manifest ---` header, then YAML with `kind: Job`, an
   `initContainers` entry named `dump` using the engine image and a `pg_dump`/`redis-cli`/`clickhouse-client`
   command, a main container named `upload` using `google/cloud-sdk:slim` with `gzip … | gsutil cp - "$DEST"`,
   `GCE_METADATA_HOST: 169.254.169.254`, `CLOUDSDK_CORE_PROJECT: tan-nb-exp`, an `emptyDir` volume, and
   `backoffLimit: 0` / `restartPolicy: Never`.

7. (Live, requires a running managed database — soft-depends on EP-43/EP-45; deferable to EP-48.)

   ```bash
   export NAGARE_BACKUP_BUCKET=$(cd infra/pulumi && pulumi stack output backupBucket)
   cabal run nagarectl -- db backup mydb
   gsutil ls "gs://${NAGARE_BACKUP_BUCKET}/databases/mydb/"
   ```

   Expected transcript:

   ```text
   job.batch/nagare-dbbackup-mydb-20260610t141503z created
   job.batch/nagare-dbbackup-mydb-20260610t141503z condition met
   Backup written: gs://tan-nb-exp-nagare-backups/databases/mydb/20260610T141503Z.sql.gz
   gs://tan-nb-exp-nagare-backups/databases/mydb/20260610T141503Z.sql.gz
   ```

### M2 steps

8. Add `defaultBackupSchedule`, `BackupCronInputs`, and `renderBackupCronJob` (reusing
   `backupJobSpecValue`) to `Nagare.Database.Backup`; add the `--schedule` option to `db backup`; make
   `--dry-run` print both manifests.

9. Extend EP-45's `db create` path to `kubectl apply` the CronJob (skip when `retention = Delete`), or
   provision it from `runDbBackup` as the documented fallback. Add the CronJob tests and re-run
   `cabal test nagarectl-test`.

10. Inspect both manifests offline:

    ```bash
    cabal run nagarectl -- db backup mydb --dry-run
    ```

    Expected: the Job manifest (as in step 6) followed by a `--- Backup CronJob manifest ---` header and
    YAML with `kind: CronJob`, `schedule: "17 3 * * *"`, `concurrencyPolicy: Forbid`, and the same
    two-container body.

### M3 steps

11. Add `Nagare.Database.Restore` to the cabal `exposed-modules`; create
    `cli/nagarectl/src/Nagare/Database/Restore.hs` with `resolveBackupObject`, `isGsUrl`,
    `RestoreJobInputs` + `renderRestoreJob`, and `runDbRestore`.

12. Wire `db restore` into `cli/nagarectl/app/Main.hs` (the `DbRestore` constructor, `command "restore"`,
    the `--into live` switch, the `runDbRestore` dispatch).

13. Add restore tests, build, and run `cabal test nagarectl-test`.

14. Inspect the restore Job offline:

    ```bash
    cabal run nagarectl -- db restore mydb 20260610T141503Z --dry-run
    ```

    Expected: `--- Restore Job manifest ---` then YAML with an init container `download` running
    `gsutil cp … | gunzip` and a main container `restore` running the engine restore command targeting
    `mydb_restore_scratch` (NOT the live database).

15. (Live, deferable to EP-48.)

    ```bash
    export BACKUP_BUCKET=$(cd infra/pulumi && pulumi stack output backupBucket)
    cabal run nagarectl -- db restore mydb "$(gsutil ls gs://$BACKUP_BUCKET/databases/mydb/ | tail -1)"
    ```

    Expected: a restore Job completes; its logs print a row count / restored listing for comparison; the
    live `mydb` is untouched; the command ends with a "Promote manually" message.

### M4 steps

16. Update `docs/runbooks/disaster-recovery.md` (inventory row + restore sub-step + drill) and
    `docs/user/backups-and-disaster-recovery.md` (table row + section).

### Commit conventions (every commit)

Use Conventional Commits, commit directly to the current branch (no feature branch), and put these
trailers on every commit:

```text
feat(cli): EP-47 nagarectl db backup with two-container Job + GCS layout

MasterPlan: docs/masterplans/9-managed-databases-for-nagare.md
ExecPlan: docs/plans/47-scheduled-database-backups-restore-commands-and-retention.md
Intention: intention_01ktryacjaezzbezmkt5j93abq
```

Commit at each milestone boundary (and at any stopping point), updating Progress first.


## Validation and Acceptance

The change is proven by behavior, not compilation alone.

**Pure logic (always runnable, no cluster).** `cabal test nagarectl-test` exercises `dbBackupObjectPath`,
`backupExt`, the reused `snapshotsToPrune`, `defaultBackupSchedule`, `resolveBackupObject`, and `isGsUrl`.
The path test asserts the exact string `databases/mydb/20260610T141503Z.sql.gz`. The extension test
asserts `Postgres → "sql.gz"`, `Redis → "rdb.gz"`, `ClickHouse → "native.gz"`. The prune test feeds nine
fixed-width timestamped `databases/mydb/…` names with `n = 7` and asserts the two **oldest** are returned
for deletion (and that re-running on the kept set returns `[]` — idempotent). These fail before the code
exists and pass after — run them on a clean checkout to confirm.

**Dry-run manifests (no cluster).** `nagarectl db backup mydb --dry-run` prints a `batch/v1` Job with the
two-container (dump initContainer + upload main container) shape, the credential `secretKeyRef`s, the
metadata-IP ADC env, the project pin, and `backoffLimit: 0`; followed by a `batch/v1` CronJob with the
daily schedule, `concurrencyPolicy: Forbid`, and the same body. `nagarectl db restore mydb <ts> --dry-run`
prints a restore Job targeting the scratch identifier. These prove the rendering offline.

**Backup end to end (live; deferable to EP-48).** After `nagarectl db backup mydb`,
`gsutil ls gs://tan-nb-exp-nagare-backups/databases/mydb/` lists a `*.sql.gz` (or `.rdb.gz`/`.native.gz`)
whose timestamp matches the run, and `gsutil cat <obj> | gunzip | head` shows the dump's first lines.
Running again produces a second object (append-only); once more than N exist, the oldest is pruned
(`gsutil ls` count stays at N). The scheduled CronJob, after its first fire, writes an object the same
way (confirm with `kubectl get cronjob -l nagare.dev/database=mydb` and `gsutil ls` after the schedule).

**Restore drill (live; deferable to EP-48).** The exact VM commands, runnable verbatim on the VM (or
through a forwarded kube API, since IAP forwards only SSH/22 — start the VM first with `gcloud compute
instances start nagare-01 --project=tan-nb-exp --zone=us-west1-a` and follow the runbook's "Reach the
cluster" forward):

```bash
# 1. Create a throwaway database and write known data (Postgres example).
cabal run nagarectl -- db create postgres drilldb
# ... connect (nagarectl db shell drilldb) and INSERT a row whose count you note ...
# 2. Back it up.
export BACKUP_BUCKET=$(cd infra/pulumi && pulumi stack output backupBucket)
cabal run nagarectl -- db backup drilldb
gsutil ls "gs://${BACKUP_BUCKET}/databases/drilldb/"
# 3. Restore scratch-first and compare.
cabal run nagarectl -- db restore drilldb "$(gsutil ls gs://$BACKUP_BUCKET/databases/drilldb/ | tail -1)"
# The restore Job's logs print the scratch db's row count; it must match step 1.
# 4. Tear down the throwaway database.
cabal run nagarectl -- db delete drilldb
```

Observe: the scratch database's row count matches what was written; the live `drilldb` is never mounted
or overwritten by the drill; the command ends with "Promote manually." This is the database-level analog
of EP-36's volume restore drill.

**Runbook truth.** `docs/runbooks/disaster-recovery.md` now lists managed-database data in its inventory
and gives a restore command that matches the M3 CLI; `docs/user/backups-and-disaster-recovery.md` has the
managed-database row and section. This satisfies the MasterPlan IP6 obligation that EP-47 update both
documents.


## Idempotence and Recovery

Backups are **append-only**: each run writes a new timestamped object, so backing up twice is always safe
and never overwrites an earlier backup. The backup Job is named with the timestamp, so a re-run gets a
fresh Job name; `runDbBackup` deletes the completed Job after success, and a failed Job (with
`backoffLimit: 0`) leaves a single inspectable Job you can `kubectl logs` then `kubectl delete` before
retrying. Retention pruning is idempotent: `snapshotsToPrune` on an already-pruned set returns `[]`, so
re-running prunes nothing.

The scheduled **CronJob** is named deterministically (`nagare-dbbackup-<name>`, no timestamp), so
`kubectl apply` of it is idempotent — re-provisioning (at `db create`, on a `--schedule` change, or via
the first-`db backup` fallback) replaces the same object rather than accumulating duplicates.
`concurrencyPolicy: Forbid` ensures a slow backup never overlaps the next scheduled fire.

Restores are **scratch-first and non-destructive by default**, exactly like
`scripts/restore-postgres.sh`/`scripts/restore-volume.sh`: they write only to a disposable
`<db>_restore_scratch` database (or a disposable scratch Redis instance) and never touch the live
database unless the operator passes `--into live`. To retry a restore, drop the scratch database (e.g.
`psql … -c 'DROP DATABASE IF EXISTS mydb_restore_scratch'`) and re-run. The restore Job's `createdb`
step is written to drop-and-recreate the scratch target so a repeated restore is clean.

The bucket itself has `forceDestroy: false` (`infra/pulumi/src/components/NagarePerimeter.ts`), so an
accidental `pulumi destroy` cannot wipe the backups. All gcloud/gsutil/kubectl operations target
`tan-nb-exp` only — any new shell helper carries the project-isolation preflight, and the in-cluster
Jobs/CronJob set `CLOUDSDK_CORE_PROJECT=tan-nb-exp`, so no operation can touch another project even if
the ambient default were wrong. If the VM is TERMINATED when a live backup/restore is attempted, start it
(`gcloud compute instances start nagare-01 --project=tan-nb-exp --zone=us-west1-a`) and reach the cluster
per the runbook before retrying; the offline `--dry-run` and unit-test paths need no cluster at all.


## Interfaces and Dependencies

**New module `Nagare.Database.Backup`** (`cli/nagarectl/src/Nagare/Database/Backup.hs`, registered in
`cli/nagarectl/nagarectl.cabal` `exposed-modules`). Public signatures that must exist at the end of M1/M2:

```haskell
-- Pure: GCS object path within the bucket, and the full gs:// URL.
dbBackupObjectPath :: Text -> Text -> Text -> Text          -- name -> timestamp -> ext -> path
dbBackupGsUrl      :: Text -> Text -> Text -> Text -> Text   -- bucket -> name -> timestamp -> ext -> URL

-- Pure: per-engine backup file extension (the engine data dimension of IP6).
backupExt :: Engine -> Text                                  -- Postgres->"sql.gz", Redis->"rdb.gz", ClickHouse->"native.gz"

-- Pure: render the in-cluster backup Job (dump initContainer + gsutil upload container).
data BackupJobInputs = BackupJobInputs
  { bjiNamespace  :: !Text
  , bjiJobName    :: !Text
  , bjiEngine     :: !Engine
  , bjiImage      :: !Text       -- engine client image, e.g. "postgres:16"
  , bjiSvcHost    :: !Text       -- in-cluster Service DNS, e.g. "mydb"
  , bjiSecretName :: !Text       -- "nagare-db-<name>"
  , bjiDestUrl    :: !Text       -- gs://… from dbBackupGsUrl
  , bjiDumpPath   :: !Text       -- shared emptyDir path, e.g. "/dump"
  }
renderBackupJob   :: BackupJobInputs -> ByteString
backupJobSpecValue :: BackupJobInputs -> Value               -- shared body for Job and CronJob

-- Pure: scheduled-backup CronJob.
defaultBackupSchedule :: Text                                -- "17 3 * * *"
data BackupCronInputs = BackupCronInputs                     -- BackupJobInputs fields + schedule :: Text
renderBackupCronJob :: BackupCronInputs -> ByteString

-- IO: the on-demand backup driver (the Maybe Text is the optional --schedule for the CronJob).
runDbBackup :: Database -> Text -> Int -> Maybe Text -> IO () -- db -> bucket -> keep -> schedule
```

**New module `Nagare.Database.Restore`** (`cli/nagarectl/src/Nagare/Database/Restore.hs`, registered in
the cabal `exposed-modules`). Public signatures at the end of M3:

```haskell
-- Pure: resolve a BACKUP_ID (bare timestamp or full gs:// URL) to a gs:// source URL.
isGsUrl             :: Text -> Bool
resolveBackupObject :: Text -> Text -> Text -> Text -> Text  -- bucket -> name -> ext -> backupId -> gs:// URL

-- Pure: render the in-cluster restore Job (gsutil download initContainer + engine restore container).
data RestoreJobInputs = RestoreJobInputs
  { rjiNamespace  :: !Text
  , rjiJobName    :: !Text
  , rjiEngine     :: !Engine
  , rjiImage      :: !Text
  , rjiSvcHost    :: !Text
  , rjiSecretName :: !Text
  , rjiSrcUrl     :: !Text       -- gs://… from resolveBackupObject
  , rjiScratch    :: !Text       -- scratch target, e.g. "mydb_restore_scratch"
  , rjiLiveTarget :: !Bool       -- True only with --into live
  , rjiDumpPath   :: !Text
  }
renderRestoreJob :: RestoreJobInputs -> ByteString

-- IO: the restore driver (scratch-first by default).
runDbRestore :: Database -> Text -> Text -> Bool -> IO ()    -- db -> bucket -> backupId -> liveTarget
```

**Reused from EP-36** (`cli/nagarectl/src/Nagare/Storage/Snapshot.hs`, checked in): the pure
`snapshotTimestamp :: UTCTime -> Text` (the `YYYYMMDDTHHMMSSZ` formatter) and `snapshotsToPrune :: Int ->
[Text] -> [Text]` (keep-last-N retention). **Imported, not reimplemented** (MasterPlan IP6 mandate). The
in-cluster Job mechanics — `google/cloud-sdk:slim`, `GCE_METADATA_HOST=169.254.169.254`,
`CLOUDSDK_CORE_PROJECT=tan-nb-exp`, `restartPolicy: Never`, `backoffLimit: 0`, `Data.Yaml.encode` of an
`aeson` `Value`, and the apply/wait/prune IO shape of `runSnapshot` — are copied from that module.

**Consumed from EP-44** (`cli/nagare-dsl/src/Nagare/Dsl/Database.hs`, MasterPlan IP1): the `Database`
record and its accessors (`dbName`/`databaseNameText`, `engine`, `version`/`engineVersionText`,
`namespace`/`namespaceText`, `retention`), and the `Engine(Postgres, Redis, ClickHouse)` enum. The
engine client images and the in-cluster Service DNS name are derived from the engine + version + name.

**Consumed from EP-45** (`cli/nagarectl/src/Nagare/Database/Discover.hs` and the `db` subparser in
`cli/nagarectl/app/Main.hs`, MasterPlan IP4): the `db` subparser (extended here with `backup`/`restore`,
not forked), the `DbCommand` sum type (extended with `DbBackup`/`DbRestore`), the `runDb` dispatcher, and
the database resource-discovery helper (resolving a name to its StatefulSet/Service/Secret by the IP3
labels). The managed credential **Secret** `nagare-db-<name>` (MasterPlan IP3) is read by the Job
manifests via `valueFrom.secretKeyRef`, never re-derived. If EP-45's pieces are absent when M1 starts,
implement the minimal `discoverDatabase`/`db` wiring locally and note the deviation (see Context).

**Libraries (all already declared in `cli/nagarectl/nagarectl.cabal`).** `cradle` for `kubectl`/`gsutil`
shell-outs (as in `Nagare.Deploy`/`Nagare.Storage.Snapshot`); `time` for the reused `snapshotTimestamp`;
`aeson` + `yaml` for `Data.Yaml.encode` of the manifest `Value`s; `bytestring`/`text` for rendering;
`temporary` for the temp-file apply pattern; `tasty`/`tasty-hunit` (test stanza) for the new tests.

**Services.** The GCS bucket `tan-nb-exp-nagare-backups` (Pulumi output `backupBucket`), reached with
ambient ADC (node service account, `roles/storage.objectAdmin`); the k3s cluster via `kubectl`; the
running managed-database StatefulSet/Service/Secret EP-45 provisions. All targeting `tan-nb-exp` per the
repository `CLAUDE.md`.

**Docs touched.** `docs/runbooks/disaster-recovery.md` (inventory row + restore sub-step + drill) and
`docs/user/backups-and-disaster-recovery.md` (table row + managed-database section), both referenced by
EP-48 (`docs/plans/48-managed-databases-docs-and-end-to-end-examples.md`).
