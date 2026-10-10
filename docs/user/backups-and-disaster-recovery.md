---
type: Runbook
title: "Backups and disaster recovery"
description: "Back up Nagare state, recover platform and workload data, and drill the documented failure procedures safely."
docId: DOC-5
tags: [backups, disaster-recovery, restore, operations]
generated:
  by: human:nadeem
  at: 2026-08-23T20:57:05Z
---

# Backups and disaster recovery

> **Status:** 🟡 Database backups and app-volume snapshot and scratch restore planning support
> cloud mode (GCS) and local mode (MinIO). The previous direct local smoke
> script has not yet been migrated to reviewed data commands. Full host
> disaster-recovery drills and some app-specific backup patterns, such as
> continuous Litestream restore drills and dashboard export, are still deferred.
> Pulumi now declares daily data-disk snapshots plus protected, versioned backup
> storage, but those EP-99 changes still await live preview/apply/verification.

The guiding principle: **the machine is disposable.** Recovery is `pulumi up`,
`nixos-rebuild switch`, bootstrap the cluster, restore data, deploy apps. Nagare
is successful only if rebuilding it is *boring*.

Live `db backup` and `db restore` require saved reviews in every context. An
accepted database can use `db backup NAME --backup-id ID --save-plan DIR` or a
PostgreSQL, Redis, or ClickHouse scratch restore with `--restore-id ID --save-plan DIR`, followed by
`inventory apply DIR --yes`. An accepted app PVC can use
`storage snapshot APP VOLUME --snapshot-id ID --save-plan DIR`, followed by
`inventory apply DIR --yes`. Restore an accepted snapshot into a separate PVC
with `storage restore APP VOLUME BACKUP_ID --restore-id ID --save-plan DIR` and
then apply that review. Live PVC restore remains unavailable.
Scheduled database backups remain part of reviewed database scopes. The older
database Job renderers remain available only through `--dry-run`.

---

## What to back up (and where it already lives)

Most of Nagare is reproduced from Git; only a few things need real backup jobs.

| What | Backup mechanism | Status |
| --- | --- | --- |
| NixOS host config | **Git** (this repo) | ✅ |
| Pulumi infra program | **Git** (this repo) | ✅ |
| Pulumi **state** | Per-context `file://` backend under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state`, **or** an opt-in versioned GCS backend (`NAGARE_PULUMI_BACKEND=gcs`) | ✅ (back up the local state directory; a GCS backend is versioned server-side — see [Target contexts › Remote GCS Pulumi state](contexts.md#remote-gcs-pulumi-state-opt-in-cloud-contexts-only)) |
| Resource inventory history | Private local directory under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/inventory`, or opt-in GCS prefix in the context state bucket | 🟡 (back up a local store with `nagarectl inventory export --out DIRECTORY` and restore it only into an empty, matching local context with `inventory restore --from DIRECTORY --yes`; a two-state-root GCS migration rehearsal passed, while complete application and platform recovery remains open — see [Shared inventory history](contexts.md#shared-inventory-history-cloud-contexts)) |
| Kubernetes manifests | **Git** (`cluster/`) | ✅ |
| Secrets | **sops-encrypted in your private operator repository** (host flake `secrets.yaml`, `cluster-secrets/<context>/`) + age private keys offline | 🟡 (see [Secrets](secrets.md) and [Keeping contexts in a private repository](contexts.md#keeping-contexts-in-a-private-repository)) |
| SQLite app data | PVC snapshot, or Litestream pattern for hot SQLite | 🟡 |
| Host Postgres | Restore from disk if data disk survives; use managed DBs for Nagare-owned backup tooling | 🟡 |
| Whole data disk | Daily GCE snapshot at 08:00 UTC, retained seven days and kept if the source disk is deleted | 🟡 (declared; live apply/verification pending) |
| App volumes (PVCs) | Reviewed fixed-key snapshot and separate scratch restore Jobs → GCS or MinIO (`manual-volumes/<namespace>/<app>/<volume>/`) | 🟡 (live provider proof, exact pruning, and live-target recovery pending) |
| Managed databases | Reviewed CronJob every 15 minutes → GCS or MinIO (`databases/<name>/`); reviewed schedules verify stored bytes without pruning; accepted databases can save reviewed manual backup, expired manual pruning, PostgreSQL and ClickHouse scratch restore Jobs, and Redis scratch instances | 🟡 (live-target restore and complete cloud provider proof pending) |
| Attic signing identity and metadata | Managed PostgreSQL `nix-cache` / reviewed `nagare-dbbackup-nix-cache` CronJob | 🟡 (provider implemented; live restore acceptance pending) |
| Attic cache chunks | Reproducible producer inputs; optionally export the dedicated GCS bucket before retirement | Rebuildable |
| Grafana dashboards | **Git** (dashboard JSON under `cluster/observability`) | ✅ |
| Victoria metrics/logs/traces data | Optional — usually not worth backing up | — |

In cloud mode, the backup bucket is `<project>-nagare-backups`. It has uniform
bucket-level access, public access prevention, `forceDestroy: false`, object
versioning, and Pulumi protection. Deletes and overwrites become noncurrent
versions; a lifecycle rule removes those versions after 30 days. The node
service account has object-admin on this bucket only, so backup jobs running on
the VM can write with ambient credentials. In local mode, the same commands
target MinIO at
`http://minio.nagare-system.svc.cluster.local:9000/nagare-backups`.

The node credential can still delete current backup objects. Versioning gives
an operator a 30-day recovery window from accidental or malicious deletion; it
is not an immutable/off-account backup. For higher assurance, replicate the
bucket into a separately administered project or account.

The optional [in-cluster Nix binary cache](nix-binary-cache.md) deliberately uses a
separate, unversioned bucket so garbage collection can reclaim chunks. Its PostgreSQL backup is the
important recovery artifact because it preserves metadata and the NAR signing identity. Bucket loss
is recovered by rebuilding and repushing closures; database loss requires a restore and public-key
comparison before clients resume.

### App volumes: backup-included by default, opt out explicitly

A durable volume attached to an app (EP-34/EP-35) is part of the backup story by
default. For an accepted PVC, save and apply a snapshot review:

```bash
nagarectl storage snapshot APP VOLUME --snapshot-id ID --save-plan DIR
nagarectl inventory apply DIR --yes
```

The fixed object addresses are:

```text
cloud: gs://<backup-bucket>/manual-volumes/<namespace>/<app>/<volume>/<id>.tar.gz
local: s3://nagare-backups/manual-volumes/<namespace>/<app>/<volume>/<id>.tar.gz
```

A reviewed Job mounts the accepted PVC read-only, creates the archive at that
ID only if the key is empty, then reads back and hashes the stored bytes. It
creates a separate `.receipt.json` object and checks its readback. Apply
rechecks the PVC identity before submitting and accepting the Job. There is no
automatic pruning; an occupied ID or partial upload needs explicit recovery.
Snapshots default to `retain`. To permit later pruning, add a future
`--expires-at YYYY-MM-DDTHH:MM:SSZ` when planning the snapshot. Once it
expires, save and apply an exact prune review:

```bash
nagarectl storage prune-snapshot APP VOLUME BACKUP_ID --save-plan DIR
nagarectl inventory apply DIR --yes
```

Pruning refuses retained or unexpired snapshots and accepted restore
dependencies. The fixed Job rereads both exact objects, checks their hashes
and provider versions, then deletes only those versions. A partial deletion
needs explicit recovery. A finite-expiry snapshot cannot be restored after
expiry; the restore Job checks the deadline again before reading it.
Restore an accepted snapshot into a separate scratch PVC:

```bash
nagarectl storage restore APP VOLUME BACKUP_ID --restore-id RESTORE_ID --save-plan DIR
nagarectl inventory apply DIR --yes
```

Planning reads the completed backup Job's UID-bound Pod receipt. Apply
rechecks that Job, the current target PVC, and the local store credential
where applicable. The restore Job rereads both object-store objects and
checks their hashes before extracting into the new scratch PVC. An uncertain
partial restore needs explicit recovery; `--into-live` is unavailable for live
execution. The older snapshot and restore renderers are read-only `--dry-run`
previews.

If extraction fails, keep the failed Job and scratch PVC for inspection. A
version 1 `inventory recover` decision with the exact transaction, failed Job
operation, review digest, and action `abandon-partial-volume-restore` closes
only an adapter-proved terminal restore Job. It leaves the possibly partial PVC
unaccepted. Recover or retire those provider objects through a separate review,
then restore again with a fresh restore ID and PVC. Do not retry extraction
into the partial PVC.

### Managed databases: backed up by default

See **[Managed databases](managed-databases.md)** for the full guide (declaring a
`Database`, connecting an app, the per-engine connection env). A managed database
(`nagarectl db create postgres|redis|clickhouse NAME`, EP-47) is backup-included
from the moment it is created. Newly reviewed `db create` scopes provision a
**CronJob** that runs an engine-appropriate logical dump — `pg_dump` (Postgres),
an RDB dump (Redis), a ClickHouse database backup ZIP — gzips it, and uploads it to
`databases/<name>/<Job UID>.<ext>` in the active object store. Newly reviewed
schedules read stored bytes back, compare SHA-256, and publish an authenticated
per-object receipt bound to the source StatefulSet/PVC identities, accepted
schedule template and the UTC time captured before the dump starts. The CronJob
never deletes anything. Existing accepted schedules keep their earlier scripts
until a review updates them.

**Retention** ([ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md)).
Nagare keeps every scheduled recovery point for 48 hours, the newest point of
each UTC day for 30 days, and always the newest point. The release fixes the
policy; no context value changes it. Only the signed recovery-point time of an
accepted receipt counts. A receipt accepted without one (a v4 receipt) is kept
and never selected. `server status` shows one `retention` row per database: OK
when no accepted run is past policy, WARN with the count otherwise. Nothing
removes those runs in the background. Review and apply their removal:

```bash
nagarectl db prune-scheduled-backups pg-main --save-plan ./scheduled-prune
nagarectl inventory apply ./scheduled-prune --yes
```

The review names each run past policy as one exact prune scope, pinned to its
provider versions. Admission evaluates the policy again against the accepted
receipts and refuses the whole review if any named run is the newest, inside
the 48-hour window, or the newest of a retained day. Each Job deletes the
archive before its receipt, by the exact reviewed version (MinIO) or
generation (GCS), and proves each key has no live object before it succeeds.
A prune stopped part way closes by per-operation proof. If its Job failed,
whether before deleting anything or after deleting only the archive, `db
recover-scheduled-prune` reviews a recovery Job that finishes the same
deletion and nothing more. Ingest first with `db backup-receipts NAME --all
--save-plan DIR`, which ingests every verified, not-yet-ingested run in one
review. A run uploaded later, strictly newer than every accepted run, does not
refuse the prune: it is reported as not yet ingested and never pruned. An
un-ingested run that is not newer refuses until it is ingested.

Each prune review also cleans up runs pruned by earlier reviews. Once a run's
prune has converged, the next review retires its receipt and prune scopes. The
review after collects the retained prune Job, and the one after that collects
the ingestion Job. A prune that stopped and was closed is left for `db
recover-scheduled-prune`. When nothing new is past policy, `db
prune-scheduled-backups` still offers a review that carries only this cleanup.

On GCS the backup bucket is versioned (EP-99), so a pruned generation becomes
noncurrent and the bucket's lifecycle rule deletes it 30 days later. A pruned
copy of personal data therefore lingers for up to 30 more days, plus GCS's
soft-delete window, before it is gone. On MinIO the deleted version is removed
at once.

The schedule follows the context's recovery-point objective,
`NAGARE_BACKUP_RECOVERY_POINT` (see [Contexts](contexts.md)):

| Objective | Schedule | Warning | Breach |
| --- | --- | --- | --- |
| `hourly` (default) | every 15 minutes | 30 minutes | one hour |
| `daily` | once a day at 03:17 UTC | 25 hours | 26 hours |

Use `daily` only for clusters that can lose up to a day of data. The objective is
written into each reviewed CronJob's signed receipt metadata, so status always
grades a database against the objective its accepted schedule was reviewed with,
not against the current environment. To change it, set the variable in the
context, then review the CronJob-only update with
`db disable-backup-prune NAME --save-plan DIR` (or any ordinary database review)
and apply it.

List and accept a scheduled receipt after its producer Job has gone:

```bash
nagarectl db backup-receipts pg-main
nagarectl db backup-receipts pg-main --backup-id JOB_UID --save-plan ./scheduled-receipt
nagarectl inventory apply ./scheduled-receipt --yes
```

Or ingest every verified run that is not yet accepted, in one review
([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md),
2026-10-10 amendment). Each run is still verified on its own and keeps its own
receipt scope, Job and proof; a run that does not verify is reported and left
unresolved:

```bash
nagarectl db backup-receipts pg-main --all --save-plan ./scheduled-receipts
nagarectl inventory apply ./scheduled-receipts --yes
```

Listing distinguishes verified candidates, accepted receipts and unresolved
objects.

**Unresolved objects stay unresolved.** An object whose upload or receipt did not
complete is listed as unresolved, and it stays that way. This covers an archive
without a receipt (an interrupted upload), a receipt without its archive, and an
unrecognized key under the database prefix. Nagare never ingests such an object,
never counts it toward freshness, and never restores from it. Nagare also never
deletes it: no command resolves or removes it, a retry refuses to overwrite it,
and scheduled pruning removes only accepted runs. These objects stay in the backup bucket, and
their storage cost is the operator's responsibility. If you remove one, you do
it outside Nagare with the provider's own tools: `gcloud storage rm` on that
exact generation, or `mc rm --version-id` on that exact version for local MinIO.
First confirm that `db backup-receipts` lists it as unresolved and that no
accepted receipt names it. Nagare records no history of that removal, and the
object simply stops being listed.

Ingestion rereads exact MinIO versions or GCS generations and checks
receipt authentication, source identity, lengths and archive hashes. Only the
accepted receipt may authorize a later isolated restore. GCS scheduled ingestion
has installed native evidence on a disposable cloud context: signed receipts were
ingested after their producer Job was removed and restored into an isolated
PostgreSQL target, an earlier receipt still restored after a schedule change,
and a genuine automatic producer reported freshness. That evidence predates the
final release candidate, so it is not yet release acceptance. Existing schedules change only through a reviewed update. Version-4 receipts
remain restorable but cannot establish freshness because they lack a signed
recovery-point timestamp.

For an accepted earlier signed schedule, save a bounded update with
`db disable-backup-prune pg-main --save-plan DIRECTORY`, inspect its CronJob-only
change, then apply that review. This installs the current signed producer and
cadence while preserving database credentials and existing receipt history.
Unknown customized schedule scripts refuse this migration.

`nagarectl server status` and `nagarectl doctor` show the same freshness as one
`recovery point` row per accepted scheduled database backup; `doctor` exits
nonzero on a breach. For a single database, or a monitoring exit code, use
`db backup-receipts pg-main --check-freshness`.
It freshly verifies receipt and archive versions and grades the newest verified
recovery point against the schedule's objective. Both accepted receipts and
verified uploads still awaiting ingestion count. A pending upload counts only after
its exact stored bytes, HMAC signature and current source StatefulSet/PVC identities
have been checked, and the output says when the newest point is still pending. So
an unattended context stays healthy while its schedule runs. Only an accepted
receipt can authorize a restore, so ingest the receipt you intend to restore.
Warnings, breaches, missing timestamps and future timestamps exit nonzero. The age
starts before the dump, so upload and verification delays count against the
objective. The hourly schedule leaves time for retries; it does not by itself
establish the recovery guarantee, and monitoring must run often enough to act on
the warning.

Backup-included application volumes (every volume with `retention = Retain`)
have the same scheduled producer. An application's reviewed deploy adds, per
volume, a CronJob `nagare-volbackup-<app>-<volume>` with its own reader account
and signing Secret. It mounts the claim read-only, writes a gzipped `tar` under
`scheduled-volumes/<namespace>/<app>/<volume>/<run>.tar.gz`, reads the stored
bytes back, and uploads a signed version-5 receipt whose source is the claim's
UID. `server status` shows one `recovery point` row per volume, labelled by the
schedule name and graded against the same objective as the databases.

A volume archive is consistent per file, not per volume: files an application
writes while the archive runs may be captured mid-change, and two files may come
from slightly different moments. An application that needs transactional
consistency across its data belongs in a managed database. This is the same
contract the manual snapshot has.

Ingesting a scheduled volume receipt as restore authority, and restoring from
one, are not available yet; restore a volume from a manual snapshot.

#### Escrow the signing key off the cluster

Pending receipts are verified with each database's HMAC signing key, which lives in
an in-cluster Secret. Escrow it once per database so receipts stay verifiable if
the cluster is lost:

```bash
nagarectl db escrow-signing-key pg-main
nagarectl db verify-escrowed-backup pg-main --backup-id JOB_UID
```

The escrow reads the live key, binds it to the observed Secret, StatefulSet and
PVC UIDs, and writes a sops-encrypted file. By default the file goes to
`$XDG_CONFIG_HOME/nagare/cluster-secrets/<context>/backup-signing/<namespace>-<name>.sops.yaml`;
`--output` overrides that. sops finds the `.sops.yaml` creation rules from that
directory, as for other operator secrets ([Secrets](secrets.md)). The plaintext
never touches disk or argv. The command refuses to overwrite a different escrow,
and it checks that the result decrypts with your available age key. Keep the file
in the context's private operator repository. Re-run it after a database is
replaced, because a new incarnation has a new key.

`verify-escrowed-backup` needs only the escrow and the object store, not the
cluster. It rereads the exact receipt and archive versions, checks the signature,
source identities and archive hash, and prints the recovery point. It is evidence
only and grants no restore authority. Recovering the data after total cluster
loss is the procedure in [Total cluster loss: recover the data](#total-cluster-loss-recover-the-data).
Its output also names the backup as a rebuild recovery point
(`RECEIPT_URL@RECEIPT_SHA256`), for a reviewed rebuild of the same context
([Rebuild the service after losing the VM](../runbooks/disaster-recovery.md#rebuild-the-service-after-losing-the-vm)).

In local mode the object store is the in-cluster MinIO, so by default the command
reads it through the cluster (its credential Secret and a port-forward). When the
source cluster is unavailable, serve a copy of the bucket from a disposable MinIO
on a loopback port and point the command at it. Put the copy's credentials in a
private file (mode `0600`) with exactly `AWS_ACCESS_KEY_ID=` and
`AWS_SECRET_ACCESS_KEY=` lines:

```bash
nagarectl db verify-escrowed-backup pg-main --backup-id JOB_UID \
  --offline-object-store http://127.0.0.1:19000 --offline-credentials ./minio-copy.env
```

Only a loopback `http://127.0.0.1:PORT` or `http://localhost:PORT` endpoint is
accepted, and the credentials never appear in arguments or output (finding F41).

 For an accepted database, save a manual
backup review with `nagarectl db backup NAME --backup-id ID --save-plan DIR`,
then run `nagarectl inventory apply DIR --yes`. The ID fixes the Job and object
key under `manual-databases/<namespace>/<name>/<id>.<ext>`, outside the
legacy schedule's broad pruning prefix and separate from other namespaces. An optional
`--expires-at YYYY-MM-DDTHH:MM:SSZ` records expiry without
deleting the object; the default is `retain`. The review pins the source
StatefulSet and PVC UIDs and apply checks them again before submission. The
Job reads the stored object back and compares SHA-256 before completion, but
its upload refuses to replace an existing object at that ID. After verifying
the backup, it creates and reads back a separate
`<backup-object>.receipt.json` containing the checked checksum, source
StatefulSet/PVC identities, accepted source revision, and expiry choice. If the
backup upload succeeds but receipt creation fails, the Job fails and that ID
requires explicit recovery before it can be trusted for restore or pruning.
The upload container also leaves its stored-receipt readback in the completed
Pod. Apply checks that Pod belongs to the exact Job UID and that the receipt
matches the reviewed address and metadata before recording completion. If the
Pod receipt is unavailable, completion remains unresolved. This proves what
the Job read at completion; restore and pruning still need a fresh object read
and checksum. List cloud backups
with `gsutil ls gs://<backup-bucket>/databases/<name>/`, or inspect local MinIO
through the cluster when running local mode. Expired reviewed manual backups
can be pruned with `nagarectl db prune-backup NAME BACKUP_ID --save-plan DIR`
and a separate `inventory apply DIR --yes`. The Job checks the exact receipt
and data hashes before version-specific deletion. Accepted restore scopes
block pruning; accepted prune scopes block new restores. Local MinIO backups
enable versioning on upload, and older unversioned objects refuse pruning.
List reviewed manual backups
under `gs://<backup-bucket>/manual-databases/<namespace>/<name>/` in cloud
mode.

To preserve a completed manual backup for restores after Job cleanup, save
and apply a separate receipt review:

```bash
nagarectl db backup-receipt pg-main --backup-id run-001 --save-plan ./pg-main-receipt
nagarectl inventory apply ./pg-main-receipt --yes
```

The command verifies the accepted Job and completed Pod receipt, then checks
the stored receipt and archive before pinning their provider versions and
hashes. Applying the review retains the Job; collect it only through a
separate reviewed conditional collection. An isolated restore can then use
the accepted receipt record after Job collection. Exact manual pruning still
requires its supported Job-backed path.

For an accepted PostgreSQL database, save and apply a reviewed restore into a
new scratch database:

```bash
nagarectl db restore pg-main run-001 --restore-id restore-001 --save-plan ./pg-main-restore
nagarectl inventory apply ./pg-main-restore --yes
```

Planning requires the accepted completed Job and Pod receipt, or an accepted
durable manual receipt record bound to that Job's retained or collected
identity. The restore Job checks the current receipt and backup bytes against
the saved checksums and, for a durable record, provider versions; it checks
expiry again and creates
`<database>_restore_<restore-id>` only if absent. A failed restore leaves that
scratch database for explicit forward recovery. If the PostgreSQL or ClickHouse
scratch Job fails terminally, a version 1 `inventory recover` decision with the
exact transaction, Job operation, review digest, and action
`abandon-partial-database-restore` closes only that unaccepted review. The
scratch database remains unaccepted for separate reviewed recovery, regardless
of its observed content; restore again under
a fresh restore ID. New live database overwrite reviews are deferred.

For ClickHouse, the same reviewed command downloads a `zip.gz` database archive,
checks the accepted receipt and object bytes, and uses ClickHouse's native
`RESTORE DATABASE default AS` operation to create a separate scratch database.
The Job mounts the accepted source PVC on the source node only to stage the ZIP
for the server, then removes that temporary copy. Compare known tables and rows
in the scratch database; an uncertain restore remains for explicit recovery.

For Redis, the same command creates a separate scratch Service, PVC, and
StatefulSet named `<database>-restore-<restore-id>`, then verifies the loaded
server with a Job. It checks exact accepted backup/receipt versions and hashes
before loading the RDB. A failed or uncertain first load retains the scratch
PVC for explicit recovery. A local scheduled Redis run has passed receipt
ingestion after producer Job cleanup and a real key-content restore; Redis
live-target restore remains unavailable.

New live database and volume overwrite reviews are deferred. An earlier
admitted PostgreSQL live restore retains its exact transaction, review, backup
receipts, provider versions, and writer fence. A lost or failed effect remains
fenced until explicit recovery proves its outcome. Use a
`verify-fenced-effect` recovery decision to prove the source landed, or
`recover-fenced-backup` to restore and prove the pinned pre-change content
under that fence. The latter abandons the original review after writer release;
it does not mark the source restore complete. Use `forward-fenced-release` if
the writer release is observed partial. The old
`db restore NAME BACKUP_ID --dry-run` output renders a Job but does not submit
it. A database declared `retention = Delete` is treated as throwaway and gets **no**
scheduled backup.

A volume you don't want backed up (a cache, scratch space) is opted out by
declaring it with `retention = Delete` in the typed config: such a volume is
treated as throwaway, and **`nagarectl deploy` prints a warning naming it at
deploy time** so no volume is ever *silently* unprotected. Volumes with
`retention = Retain` (the default) are backup-included.

Caveat: a file-level snapshot of a *hot* (actively written) SQLite database can
capture a torn page. Quiesce the app before snapshotting a live database, or use
the continuous Litestream pattern (`cluster/examples/sqlite-litestream/`) for
databases written while serving. Uploaded files, generated assets, and a stopped
app's database snapshot cleanly.

Keep the host age private key offline, and preserve the private operator repository
(contexts, host flake and encrypted secrets), exact platform release, Pulumi state,
and accepted inventory history off-machine. A GCS state backend protects its state
from workstation loss; it does not back up Kubernetes Secret values automatically.
`inventory export` preserves reviewed native material, which can contain secrets,
but generated database passwords, authentication keys, backup HMAC keys and local
object-store credentials exist only in Kubernetes after creation. Their reviewed
templates contain no generated values.

Recovering the *data* after total cluster loss needs only three things kept off
the cluster: each database's escrowed signing key, the age key that decrypts it,
and read access to the backup bucket. Generated service passwords are not needed
to load a dump into a new engine. Keep the escrow files, the age key and the
context in the private operator repository (ADR 13). The procedure is
[Total cluster loss](#total-cluster-loss-recover-the-data) below.

## Total cluster loss: recover the data

This is the drill for "the cluster is gone, is the data?". Run it before trusting
the platform with real data, then on a schedule. It recovers each managed
database's newest verified backup into a disposable engine, checks the content,
and records how long that took. It reads only the backup bucket and the material
in the private operator repository: no cluster, no inventory store, and no
workstation state.

This drill proves the data is recoverable and how fast; it does not bring the
service back. To rebuild the same context with its databases restored into
service, follow
[Rebuild the service after losing the VM](../runbooks/disaster-recovery.md#rebuild-the-service-after-losing-the-vm):
a reviewed rebuild recreates each lost durable member as a new incarnation, and
each database restores the one recovery point its rebuild named.

### Prerequisites, before you need them

- **Hourly objective.** The context uses `NAGARE_BACKUP_RECOVERY_POINT=hourly`
  (the default): a backup every 15 minutes, a warning at 30 minutes and a breach
  at one hour, measured including upload and verification
  ([Managed databases](#managed-databases-backed-up-by-default)).
- **Escrow per database.** Run `nagarectl db escrow-signing-key NAME` for every
  managed database, and again after a database is replaced
  ([Escrow the signing key](#escrow-the-signing-key-off-the-cluster)). Commit the
  sops file to the private operator repository.
- **Private material off this machine.** The private operator repository holds
  the context, the escrow files and the sops rules; the age private key is kept
  offline. In cloud mode the backup bucket is GCS (versioned and protected). In
  local mode it is the in-cluster MinIO, so a total-loss drill needs a copy of the
  bucket that keeps its object versions (copy MinIO's data directory, not
  `mc mirror`).

### Detect

`nagarectl server status` and `nagarectl doctor` grade every accepted database's
recovery point from verified receipts, and exit nonzero on a breach. For one
database or a monitoring probe:

```bash
nagarectl db backup-receipts pg-main --check-freshness
```

A warning means the next missed schedule breaches the objective. Act on the
warning, not the breach.

### Recover, from a fresh operator root

Use a clean checkout and a fresh operator root: clone the private operator
repository, place the age key, and select the context. Do not reuse the lost
cluster's workstation state. Note the start time.

1. **Choose the backup.** `db backup-receipts pg-main` lists receipts only while
   the cluster and the inventory store answer. With the cluster gone, list the
   candidates in the context's backup bucket (`NAGARE_BACKUP_BUCKET`). Each
   scheduled backup is `JOB_UID.sql.gz`, with its receipt beside it:

   ```bash
   gcloud storage objects list "gs://$NAGARE_BACKUP_BUCKET/databases/pg-main/*.sql.gz" \
     --format='table(name,generation,creation_time)'
   ```

   Verify candidates, newest first, with only the escrow and the object store,
   and pick the newest that verifies:

   ```bash
   nagarectl db verify-escrowed-backup pg-main --backup-id JOB_UID \
     --escrow PATH/TO/personal-pg-main.sops.yaml
   ```

   Without `--escrow` it reads the escrow from its default location under
   `$XDG_CONFIG_HOME/nagare/cluster-secrets/<context>/backup-signing/`. It reads
   neither the cluster nor the inventory store. It prints the exact archive and
   its version (in cloud mode, the GCS generation), the receipt version, the
   archive's SHA-256 and the recovery point. It refuses a receipt whose signature,
   source identities or archive hash do not check, so a corrupt or incomplete
   upload is never chosen.

   In local mode, serve the bucket copy from a disposable MinIO on a loopback port
   and add `--offline-object-store http://127.0.0.1:PORT --offline-credentials
   FILE` ([Escrow the signing key](#escrow-the-signing-key-off-the-cluster)).

2. **Fetch exactly that archive** by the version the command printed, and check
   its hash against the printed SHA-256:

   ```bash
   # cloud: the version is the GCS generation
   gcloud storage cp "gs://$NAGARE_BACKUP_BUCKET/databases/pg-main/JOB_UID.sql.gz#GENERATION" dump.sql.gz
   # local: the bucket copy, by MinIO version
   mc cp --version-id VERSION copy/nagare-backups/databases/pg-main/JOB_UID.sql.gz dump.sql.gz
   shasum -a 256 dump.sql.gz
   ```

3. **Restore into a disposable engine** of the database's engine version, for
   example PostgreSQL:

   ```bash
   docker run -d --name pg-recovered -e POSTGRES_PASSWORD=drill postgres:18-alpine
   docker exec pg-recovered createdb -U postgres recovered
   gunzip -c dump.sql.gz | docker exec -i pg-recovered psql -U postgres -d recovered -q -v ON_ERROR_STOP=1
   ```

   The restore must report no errors (`ON_ERROR_STOP=1` makes psql stop at the
   first one). Backups are taken with `pg_dump --no-owner --no-privileges`, so
   restoring as `postgres` into a new database needs no roles from the source.

4. **Compare the content** with what you know was written before the recovery
   point: known rows, counts, or an application-level checksum.

5. **Record** the start and end times, the backup's job UID, the archive version,
   the SHA-256 and the recovery point. The difference between the end time and
   the start time is the recovery time; the recovery point's age at the loss is
   the data lost.

Remove the disposable engine and the downloaded dump when you are done; the dump
holds the database's data in plaintext.

### Drill it

A backup you have never restored is a hypothesis. On a schedule:

- run the total-loss procedure above against one database from a fresh operator
  root, with the cluster stopped or unreachable, and record the times. On a cloud
  context, stop the VM through a review and start it again afterwards:

  ```bash
  nagarectl host stop --operation-id drill-stop --save-plan reviews/vm-stop
  nagarectl inventory apply reviews/vm-stop --yes
  # the total-loss procedure, with the VM TERMINATED
  nagarectl host start --operation-id drill-start --save-plan reviews/vm-start
  nagarectl inventory apply reviews/vm-start --yes
  ```

  Choose a backup taken after the rows you seeded for the comparison, so they
  must be present;
- restore a managed database into its scratch target with `db restore`;
- restore an app volume into a scratch PVC with `storage restore` (volumes are
  outside the recovery objective; see above).

If a step here stops matching the commands, fix the step.

## Rebuilding the host

The host itself is disposable: [Provisioning with Pulumi](provisioning-with-pulumi.md),
[Host image and first boot](host-image-and-boot.md), [Secrets](secrets.md) and
[Cluster bootstrap](cluster-bootstrap.md) recreate it. A rebuilt cluster's databases return to service through
[Rebuild the service after losing the VM](../runbooks/disaster-recovery.md#rebuild-the-service-after-losing-the-vm).
For an intentional replacement of a live VM, disable and apply
`nagare:vmDeletionProtection` **before** changing the image self-link, preserve the
protected data disk through the replacement, then re-enable VM protection. See
[Provisioning with Pulumi](provisioning-with-pulumi.md#review-replacements-and-protected-resources).

- **VM lost, data disk survives.** The `nagare-data` disk is a protected Pulumi
  resource separate from the VM. A replacement VM re-attaches it, and the first-boot
  format step skips a disk that already has a filesystem.
- **Everything lost (disk too).** Recover the data with the total-loss procedure.
  Before declaring the disk lost, inspect the retained daily GCE snapshots.

## Next

When something goes wrong during any of the above:
**[Troubleshooting →](troubleshooting.md)**

## Replacement-cutover retention

Transaction seed and final-transfer objects are not ordinary backups and do not replace this
recovery policy. Keep a recent independent backup through cutover and former-host retention. Before
candidate write admission, the old host and its storage remain authoritative; afterwards, recovery
must preserve any candidate-only writes. Replacement finalization verifies backup and evidence
retention and never prunes ordinary backup objects.
