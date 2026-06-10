# Backups and disaster recovery

> **Status:** 🔭 Planned (EP-7) — automated backup tooling **not built yet.**
>
> The backup *destinations* exist today (Pulumi creates the
> `tan-nb-exp-nagare-backups` GCS bucket and grants the node service account
> `roles/storage.objectAdmin` on it). The *jobs* that write to it — Litestream
> for SQLite, Postgres dumps/WAL archiving, dashboard export — are EP-7 and not
> implemented. The recovery runbook below is the target end-state.

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
| Pulumi **state** | In-repo `file://` backend under `infra/pulumi/.pulumi-state` | ✅ (commit/back up the repo) |
| Kubernetes manifests | **Git** (`cluster/`) | ✅ once EP-4/5 land |
| Secrets | **sops-encrypted in Git** + host age key offline | 🟡 (see [Secrets](secrets.md)) |
| SQLite app data | **Litestream → GCS** (`/var/lib/nagare/sqlite`) | 🔭 EP-7 |
| Postgres | `pg_dump` / WAL archive → GCS (`/var/lib/nagare/postgres`) | 🔭 EP-7 |
| App volumes (PVCs) | `nagarectl storage snapshot` → GCS (`volumes/<app>/<volume>/`); excluded volumes warned at deploy | ✅ EP-36 |
| Grafana dashboards | **Git** (exported as code) | 🔭 EP-5/EP-7 |
| Victoria metrics/logs/traces data | Optional — usually not worth backing up | — |

The backup bucket is `tan-nb-exp-nagare-backups` (uniform bucket-level access,
`forceDestroy: false` so it can't be wiped by a careless `pulumi destroy`). The
node service account already has object-admin on it, so backup jobs running on
the VM can write with ambient credentials.

### App volumes: backup-included by default, opt out explicitly

A durable volume attached to an app (EP-34/EP-35) is part of the backup story by
default. `nagarectl storage snapshot APP VOLUME` tars the volume's contents to
`gs://tan-nb-exp-nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz` (a
short-lived in-cluster Job mounts the PVC read-only and streams the archive to
GCS), and keeps the last N snapshots per volume (`--keep`, default 7). Restore a
snapshot into a disposable scratch PVC — never over live data — with
`scripts/restore-volume.sh gs://…/<ts>.tar.gz`.

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

> **The two things you must keep off-machine yourself:** the **host age private
> key** (without it you cannot decrypt secrets to rebuild) and a **copy of this
> Git repo** including Pulumi state. Everything else can be regenerated.

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
      → Litestream restores SQLite from GCS; Postgres restores from dump/WAL.

6. Redeploy apps
      → nagarectl deploy for each app (or kubectl apply the manifests in Git).
```

Step-by-step, each maps to a page in this guide:

1. [Provisioning with Pulumi](provisioning-with-pulumi.md)
2. [Host image and first boot](host-image-and-boot.md)
3. [Secrets](secrets.md)
4. [Cluster bootstrap](cluster-bootstrap.md) + [Observability](observability.md)
5. this page (Litestream / Postgres restore — EP-7)
6. [Deploying apps](deploying-apps.md)

## Two failure modes worth distinguishing

- **VM lost, data disk survives.** Re-run steps 1–4. The `nagare-data` disk is a
  separate Pulumi resource from the VM and is **not** destroyed with the
  instance, so `/var/lib/nagare` (SQLite, Postgres, Victoria data) comes back
  attached and intact. The host's first-boot format step is idempotent and skips
  a disk that already has a filesystem — your data is not touched.
- **Everything lost (disk too).** Same steps, but the new blank disk
  auto-formats and step 5's restore-from-GCS is mandatory. This is the case the
  Litestream/Postgres backups protect against.

## Drill it

A backup you've never restored is a hypothesis. Once EP-7 lands, periodically:

- restore a SQLite DB from GCS into a scratch path and diff it, and
- spin a throwaway from-scratch rebuild (or at least `pulumi preview` + an image
  build) to confirm the runbook still matches reality.

If any step here stops matching the repo, fix the step — the runbook only has
value if it's boring *and* true.

## Next

When something goes wrong during any of the above:
**[Troubleshooting →](troubleshooting.md)**
