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
| Managed databases | Reviewed CronJob every 15 minutes → GCS or MinIO (`databases/<name>/`); reviewed schedules verify stored bytes without pruning; accepted databases can save reviewed manual backup, expired manual pruning, PostgreSQL and ClickHouse scratch restore Jobs, and Redis scratch instances | 🟡 (scheduled pruning, live-target restore, and complete cloud provider proof pending) |
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
schedule template and the UTC time captured before the dump starts. They retain backups by default: keep-N and expiry are
unenforced, and new scheduled pruning is deferred. Existing accepted schedules
keep their earlier scripts until a review updates them.

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

Listing distinguishes verified candidates, accepted receipts and unresolved
objects.

**Unresolved objects stay unresolved.** An object whose upload or receipt did not
complete is listed as unresolved, and it stays that way. This covers an archive
without a receipt (an interrupted upload), a receipt without its archive, and an
unrecognized key under the database prefix. Nagare never ingests such an object,
never counts it toward freshness, and never restores from it. Nagare also never
deletes it: no command resolves or removes it, a retry refuses to overwrite it,
and scheduled pruning is deferred. These objects stay in the backup bucket, and
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

Volumes are outside the recovery-point objective in this release: there is no
scheduled volume backup, so volume data has only the manual snapshots described
above. Status does not grade volumes.

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
only and grants no restore authority. A full restore after total cluster loss
remains outside this release's accepted evidence.

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

Before admitting company data, capture the required live credentials into an
encrypted recovery archive under the operator's recovery-key policy, retain it
off-cluster, and prove decryption from a separate operator root. Record the exact
context, Secret names and UIDs, accepted scope revisions, backup object generations
and receipt digests alongside the encrypted archive. Keep plaintext out of Git,
public reviews and diagnostic output. An inventory export alone does not satisfy
this recovery-material requirement. The source-cluster-unavailable drill remains
unaccepted until that archive and the exact backups recover verified content and
usable service without the original cluster or workstation.

## The disaster-recovery runbook (target)

Rebuilding `nagare-01` from nothing:

```text
1. pulumi up
      → VPC, firewall, static IP, data disk, service account + IAM,
        DNS zone + wildcard record, Artifact Registry, GCS buckets.
        (The static IP is reserved, so the wildcard DNS record is still valid.
        The data disk and backup bucket are Pulumi-protected.)

2. Build + register the NixOS image, set nagareImageSelfLink, pulumi up again
      → nagare-01 boots NixOS + k3s from the baked image; the data disk
        re-attaches. (If the disk survived, data is intact; if it's new, it
        auto-formats blank — restore in step 5.)

3. Re-place the host age key at /var/lib/sops-nix/age-key.txt
      → sops-nix can decrypt secrets; Tailscale rejoins.

4. just cluster-bootstrap  &&  just observability
      → Knative + Kourier + cert-manager, then the Victoria stack + Grafana.
        Dashboards restore from Git.

5. Restore data
      → managed database restores and volume restores read from GCS; app-specific
        Litestream or host-Postgres restores are run by the app/host runbook.

6. Redeploy apps
      → nagarectl deploy for each app (or kubectl apply the manifests in Git).
```

The from-zero path has no existing VM to protect. For an intentional replacement
of a live VM, disable and apply `nagare:vmDeletionProtection` **before** changing
the image self-link, preserve the protected data disk through the replacement,
then re-enable VM protection. See
[Provisioning with Pulumi](provisioning-with-pulumi.md#review-replacements-and-protected-resources).

Step-by-step, each maps to a page in this guide:

1. [Provisioning with Pulumi](provisioning-with-pulumi.md)
2. [Host image and first boot](host-image-and-boot.md)
3. [Secrets](secrets.md)
4. [Cluster bootstrap](cluster-bootstrap.md) + [Observability](observability.md)
5. this page (managed database, volume, and app-specific restore procedures)
6. [Deploying apps](deploying-apps.md)

## Two failure modes worth distinguishing

- **VM lost, data disk survives.** Re-run steps 1–4. The `nagare-data` disk is a
  protected Pulumi resource separate from the VM, so destroying the instance
  does not destroy it. `/var/lib/nagare` (SQLite, Postgres, Victoria data) comes
  back attached and intact. The host's first-boot format step is idempotent and
  skips a disk that already has a filesystem — your data is not touched.
- **Everything lost (disk too).** Same steps, but the new blank disk
  auto-formats and step 5's restore-from-GCS is mandatory. This is the case the
  database and volume backups protect against. Before declaring the disk lost,
  inspect the retained daily GCE snapshots and restore the newest usable one.

## Drill it

A backup you've never restored is a hypothesis. Periodically:

- restore a managed database into its scratch target,
- restore an app volume into its scratch PVC,
- restore a SQLite/Litestream app through that app's runbook, and
- spin a throwaway from-scratch rebuild (or at least `pulumi preview` + an image
  build) to confirm the runbook still matches reality.

If any step here stops matching the repo, fix the step — the runbook only has
value if it's boring *and* true.

## Next

When something goes wrong during any of the above:
**[Troubleshooting →](troubleshooting.md)**

## Replacement-cutover retention

Transaction seed and final-transfer objects are not ordinary backups and do not replace this
recovery policy. Keep a recent independent backup through cutover and former-host retention. Before
candidate write admission, the old host and its storage remain authoritative; afterwards, recovery
must preserve any candidate-only writes. Replacement finalization verifies backup and evidence
retention and never prunes ordinary backup objects.
