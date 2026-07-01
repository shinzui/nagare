# Backups and disaster recovery

> **Status:** 🟡 Database backups and app-volume snapshots/restores are built for
> both cloud mode (GCS) and local mode (MinIO); the **local MinIO volume
> snapshot/restore path is verified end-to-end** by `just local-smoke` (see
> [Local development](local-development.md#run-the-local-smoke-test)). Full host
> disaster-recovery drills and some app-specific backup patterns, such as
> continuous Litestream restore drills and dashboard export, are still deferred.

The guiding principle: **the machine is disposable.** Recovery is `pulumi up`,
`nixos-rebuild switch`, bootstrap the cluster, restore data, deploy apps. Nagare
is successful only if rebuilding it is *boring*.

---

## What to back up (and where it already lives)

Most of Nagare is reproduced from Git; only a few things need real backup jobs.

| What | Backup mechanism | Status |
| --- | --- | --- |
| NixOS host config | **Git** (this repo) | ✅ |
| Pulumi infra program | **Git** (this repo) | ✅ |
| Pulumi **state** | Per-context `file://` backend under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state` | ✅ (back up the active context state directory until remote state lands) |
| Kubernetes manifests | **Git** (`cluster/`) | ✅ |
| Secrets | **sops-encrypted in Git** + host age key offline | 🟡 (see [Secrets](secrets.md)) |
| SQLite app data | PVC snapshot, or Litestream pattern for hot SQLite | 🟡 |
| Host Postgres | Restore from disk if data disk survives; use managed DBs for Nagare-owned backup tooling | 🟡 |
| App volumes (PVCs) | `nagarectl storage snapshot` → GCS or MinIO (`volumes/<app>/<volume>/`); excluded volumes warned at deploy | ✅ |
| Managed databases | `nagarectl db backup` / daily CronJob → GCS or MinIO (`databases/<name>/`); keep-last-N; scratch-first restore | ✅ |
| Grafana dashboards | **Git** (dashboard JSON under `cluster/observability`) | ✅ |
| Victoria metrics/logs/traces data | Optional — usually not worth backing up | — |

In cloud mode, the backup bucket is `tan-nb-exp-nagare-backups` by default
(uniform bucket-level access, `forceDestroy: false` so it can't be wiped by a
careless `pulumi destroy`). The node service account has object-admin on it, so
backup jobs running on the VM can write with ambient credentials. In local mode,
the same commands target MinIO at
`http://minio.nagare-system.svc.cluster.local:9000/nagare-backups`.

### App volumes: backup-included by default, opt out explicitly

A durable volume attached to an app (EP-34/EP-35) is part of the backup story by
default. `nagarectl storage snapshot APP VOLUME` tars the volume's contents to
the active object store:

```text
cloud: gs://<backup-bucket>/volumes/<app>/<volume>/<timestamp>.tar.gz
local: s3://nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz
```

A short-lived in-cluster Job mounts the PVC read-only and streams the archive to
the store, then keeps the last N snapshots per volume (`--keep`, default 7).
Restore a snapshot into a disposable scratch PVC — never over live data — with
`nagarectl storage restore APP VOLUME <ts>` (it restores into a scratch PVC by
default; pass `--into-live` to target the live PVC).

### Managed databases: backed up by default

See **[Managed databases](managed-databases.md)** for the full guide (declaring a
`Database`, connecting an app, the per-engine connection env). A managed database
(`nagarectl db create postgres|redis|clickhouse NAME`, EP-47) is backup-included
from the moment it is created. `db create` provisions a daily
**CronJob** that runs an engine-appropriate logical dump — `pg_dump` (Postgres),
an RDB dump (Redis), a native dump (ClickHouse) — gzips it, and uploads it to
`databases/<name>/<timestamp>.<ext>` in the active object store, keeping the last
N (`--keep`, default 7). Take one on demand with `nagarectl db backup NAME`; list
cloud backups with `gsutil ls gs://<backup-bucket>/databases/<name>/`, or inspect
local MinIO through the cluster when running local mode.

Restore is **scratch-first**: `nagarectl db restore NAME BACKUP_ID` loads the
chosen dump into a disposable target (`<db>_restore_scratch` for
Postgres/ClickHouse) so your live database is untouched until you compare and
promote manually; pass `--into-live` to target the live database directly. A
database declared `retention = Delete` is treated as throwaway and gets **no**
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

> **The three things you must keep off-machine yourself:** the **host age private
> key** (without it you cannot decrypt secrets to rebuild), a **copy of this Git
> repo**, and a **copy of the active context's Pulumi state directory** until
> remote Pulumi state lands. Everything else can be regenerated.

## The disaster-recovery runbook (target)

Rebuilding `nagare-01` from nothing:

```text
1. pulumi up
      → VPC, firewall, static IP, data disk, service account + IAM,
        DNS zone + wildcard record, Artifact Registry, GCS buckets.
        (The static IP is reserved, so the wildcard DNS record is still valid.)

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

Step-by-step, each maps to a page in this guide:

1. [Provisioning with Pulumi](provisioning-with-pulumi.md)
2. [Host image and first boot](host-image-and-boot.md)
3. [Secrets](secrets.md)
4. [Cluster bootstrap](cluster-bootstrap.md) + [Observability](observability.md)
5. this page (managed database, volume, and app-specific restore procedures)
6. [Deploying apps](deploying-apps.md)

## Two failure modes worth distinguishing

- **VM lost, data disk survives.** Re-run steps 1–4. The `nagare-data` disk is a
  separate Pulumi resource from the VM and is **not** destroyed with the
  instance, so `/var/lib/nagare` (SQLite, Postgres, Victoria data) comes back
  attached and intact. The host's first-boot format step is idempotent and skips
  a disk that already has a filesystem — your data is not touched.
- **Everything lost (disk too).** Same steps, but the new blank disk
  auto-formats and step 5's restore-from-GCS is mandatory. This is the case the
  database and volume backups protect against.

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
