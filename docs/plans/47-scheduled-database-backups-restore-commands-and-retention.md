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

Full plan before trimming: [47-scheduled-database-backups-restore-commands-and-retention.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/47-scheduled-database-backups-restore-commands-and-retention.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] (2026-06-10) `Nagare.Database.Backup` registered in `nagarectl.cabal`.
- [x] (2026-06-10) Pure `dbBackupObjectPath`/`dbBackupGsUrl`/`dbBackupPrefix` + `backupExt`/`backupRawExt`.
- [x] (2026-06-10) Reuse `Nagare.Storage.Snapshot.snapshotsToPrune`/`snapshotTimestamp` (imported).
- [x] (2026-06-10) Pure `renderBackupJob` (engine-image `dump` initContainer + `google/cloud-sdk:slim`
      `upload` container sharing an `emptyDir`; `backupJobSpecValue` shared body).
- [x] (2026-06-10) `runDbBackup` (resolve via `Discover.getDatabase`, apply Job, wait, prune).
- [x] (2026-06-10) `backup` subcommand added to EP-45's `db` subparser (IP4 extend).
- [x] (2026-06-10) Pure tests for path/ext/schedule, the renderers, and prune-reuse.
- [x] (2026-06-10) Engine-image-vs-gsutil tension resolved (two-container Job); renderer unit-tested.
- [x] Validate live: `nagarectl db backup mydb` then `gsutil ls`. **Deferred to EP-48 AND blocked by the
      in-pod-ADC routing regression (EP-43 finding) until the node route is fixed.** (2026-10-17: on cloud context `mp23-c3m` a reviewed PostgreSQL backup to GCS restored into a scratch database with exactly the pre-backup rows; [C3 assertion](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c3-acceptance-83124396/assertions/postgresql-backup-restore.json); backups in GCS, [checklist §2](../releases/production-readiness-checklist.md).)

Milestone 2 — scheduled backups (CronJob renderer + provisioning):

- [x] (2026-06-10) Pure `renderBackupCronJob` (shared body + schedule, `concurrencyPolicy: Forbid`,
      self-pruning upload) and `renderDbBackupCronJob` convenience helper.
- [x] (2026-06-10) `defaultBackupSchedule` (daily 03:17 UTC). (`--schedule` override not added — the
      CronJob is provisioned at create; re-run `db create` to re-render.)
- [x] (2026-06-10) CronJob provisioned at `db create` (extends EP-45's create) unless
      `retention = Delete`; idempotent `kubectl apply`; shown in `db create --dry-run`.
- [x] (2026-06-10) `db backup --dry-run` prints both the Job and the CronJob YAML.
- [x] (2026-06-10) Pure tests for the CronJob renderer / schedule helper.

Milestone 3 — `nagarectl db restore NAME BACKUP_ID`, scratch-first:

- [x] (2026-06-10) Pure `renderRestoreJob` (`download` init + engine `restore` main; scratch target).
- [x] (2026-06-10) `runDbRestore` (resolve object, apply Job, wait), scratch-first; `--into-live` opt-in.
- [x] (2026-06-10) `restore` subcommand added to EP-45's `db` subparser (IP4 extend).
- [x] (2026-06-10) Listing backups + `--into-live` documented (runbook + user guide).
- [x] (2026-06-10) Pure tests for `resolveBackupObject`/`isGsUrl`/`renderRestoreJob`.

Milestone 4 — runbook + user-guide integration:

- [x] (2026-06-10) Managed-database row + restore sub-step in `docs/runbooks/disaster-recovery.md`.
- [x] (2026-06-10) Managed-database row + section in `docs/user/backups-and-disaster-recovery.md`.
- [x] (2026-06-10) Restore drill (disposable database) with exact VM commands + GCS-routing caveat.

## Surprises & Discoveries

- **The live backup/restore leg was blocked by a node routing bug — now FIXED (2026-06-10).** EP-43
  found in-pod GCS auth broken cluster-wide: k3s/flannel's IPv4LL `169.254.0.0/16` addresses hijacked the
  GCE metadata IP into the VXLAN overlay. The fix (in `nixos/hosts/nagare-01/networking.nix`): a `/32`
  metadata route on the primary NIC (beats the `/16`) + the MASQUERADE for pod SNAT; **and** this plan's
  backup/restore Job renderers now emit a `hostAliases` entry mapping `metadata.google.internal` to the
  metadata IP, because gcloud/gsutil look the canonical name up (just reaching the IP via
  `GCE_METADATA_HOST` was not enough for gsutil — it returned "401 Anonymous caller" until the name
  resolved). Verified live: in-pod `gsutil ls` reaches the bucket and the litestream sidecar resumed.
  Applied live + committed to NixOS; `just host-switch` persists it across reboots.

- **`db backup`/`db restore --dry-run` resolve the engine from the cluster.** Unlike `db create
  --dry-run` (engine is an argument), `db backup NAME` has only the name, so rendering the Job needs the
  engine — resolved read-only via `Discover.getDatabase`. Offline (cluster unreachable) the dry-run
  prints a clear "no managed database named …" rather than a Job. The offline proof of the renderers is
  therefore the pure unit tests (`renderBackupJob`/`renderBackupCronJob`/`renderRestoreJob` over
  hand-built inputs), not a CLI dry-run.

- **ClickHouse backup/restore commands are best-effort and need live validation.** ClickHouse's native
  `BACKUP ... TO File()` writes on the *server* pod, not the backup Job's shared `emptyDir`, so the
  Job uses a per-table `SELECT ... FORMAT Native` dump loop instead; the restore stub creates the
  scratch database but the full data reload needs live validation (EP-48). Postgres and Redis commands
  are straightforward (`pg_dump`/`redis-cli --rdb`).

- **CronJob provisioned at `db create`, not via a separate `--schedule` enable/disable.** A managed
  database is backup-included by default (a daily self-pruning CronJob), matching EP-36's volume policy;
  `retention = Delete` opts out. The `--schedule` override the plan sketched was dropped to keep the
  surface small — re-running `db create` re-renders the (idempotent) CronJob.

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

EP-47 is complete for its offline-provable scope. `nagarectl db backup NAME` renders and applies a
two-container Job (engine-client `dump` initContainer + `google/cloud-sdk:slim` `upload`), prunes to
keep-last-N reusing EP-36's pure `snapshotsToPrune`, and writes to the IP6 layout
`databases/<name>/<ts>.<ext>`. Each `db create` provisions a daily self-pruning CronJob (unless
`retention = Delete`). `nagarectl db restore NAME BACKUP_ID` renders a download+restore Job targeting a
scratch database by default (`--into-live` to override). The `db` subparser was extended (not forked)
with `backup`/`restore` per IP4. The runbook and user guide document the flow, the restore drill, and
the routing caveat. 12 new pure tests; 207 `nagarectl-test` pass.

Gaps / deferred: the **live** backup→`gsutil ls`→restore drill is deferred to EP-48 and is additionally
**blocked** by the cluster's in-pod-ADC routing regression (EP-43) until the node route is fixed; the
ClickHouse dump/restore commands are best-effort pending live validation. These are recorded in
Surprises and flagged in the runbook and MasterPlan.

