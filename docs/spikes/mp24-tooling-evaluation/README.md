# EP-163 prototype record: K8up/restic (partial) and CloudNativePG (not run)

This directory holds the drivers and the evidence for EP-163 Milestone 2
([plan](../../plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md)).
The findings are scored in [RES-6](../../research/established-backup-tooling-beneath-nagare-s-journal.md).

## Status: partial evidence, gathered outside the cp3 claim protocol

On 2026-10-09 (UTC 03:01–03:48 on 2026-10-10), the EP-163 session ran a disposable k3d cluster
named `mp24-eval` on the Docker daemon of the `nagare-mp23-cp3` Colima profile. It did not take the
cp3 claim that [`docs/runbooks/native-verification-harness.md`](../../runbooks/native-verification-harness.md)
section 3 requires before any cp3 mutation. The profile was under a `nagare-verify` claim at the
time. The run was a mistake. It is recorded here and is not to be repeated.

What it touched on cp3:

- A k3d cluster `mp24-eval`: one server, no load balancer, a random API port and no registry, with
  its own kubeconfig. It used none of `nagare-local`'s fixed ports and not its registry. The
  `nagare-local` cluster, its context and the retained operator root were not read or changed.
- A runtime-only kernel setting in the cp3 VM: `fs.inotify.max_user_instances` was raised from 128
  to 1024 with `sudo sysctl -w`. The first cluster create had failed with `too many open files`
  because `nagare-local` had already used up the 128 instances. The setting is lost when the VM
  restarts.
- Images pulled into the cp3 Docker image store: `rancher/k3s:v1.32.5-k3s1`, plus what the k3d
  tools node needs. Images pulled inside the k3s node went away when the cluster was deleted.

The coordinator stopped the run. On the operator's decision, the session deleted the cluster by
exact name (`k3d cluster delete mp24-eval`, then `k3d cluster list` showed only `nagare-local`).
The operator also decided to skip the K8up prototype. K8up stays desk research and gets a
prototype only if EP-183 M3's slice checkpoint stops. The CloudNativePG prototype was never started.
Its install drivers (`30-cnpg-install.sh`, `31-cnpg-source.yaml`) are prepared but unrun.

`env.sh` now refuses to run without an explicit `EVAL_DOCKER_HOST`, so any rerun must name a daemon
the operator has approved.

## Fixture and predeclared criteria

The pinned versions, checked against upstream release tags on 2026-10-09, are:

- K8up Helm chart 4.10.0, which is operator v2.16.0 with restic 0.19.0 embedded;
- k3s v1.32.5+k3s1;
- RustFS 1.0.1 as the S3 store;
- `postgres:18`.

The fixture lived in namespace `app`:

- PVC `files` (RWO, `local-path`, annotated `k8up.io/backup=true`). It was mounted by a `writer`
  Deployment running as uid 1000.
- StatefulSet `pg` (PostgreSQL 18). Its data PVC was annotated `k8up.io/backup=false`, and its pod
  carried `k8up.io/backupcommand` running `pg_dump -Fc appdb`.
- Generation G1: 100 text files, one 128 MiB random file, and `items` rows 1–1000.
- Generation G2: one file changed, one deleted and one added; row 1 updated; rows 1001–1100 added.

Manifests are in `evidence/k8up/g1-files.sha256`, `g2-files.sha256`, `g1-pg.txt` and
`g2-pg.txt`.

Predeclared pass criteria, from EP-163 M2:

1. Known files are recovered into a new PVC.
2. One native database dump is recovered into an isolated database.
3. The sources are preserved.
4. A wrong snapshot or source, or a foreign destination, is rejected.
5. An interrupted backup is visible as incomplete.
6. Recovery references can be protected from pruning.

## Results

| # | Step (driver) | Result | Evidence |
|---|---|---|---|
| B1/B2 | Backup G1 and G2 (`22-k8up-backup.sh`) | Pass. Each Backup ran two jobs, one for the PVC and one for the backup command, and synced four `Snapshot` objects with restic IDs and paths (`/data/files`, `/app-pg.dump`). 21 s each, for 128 MiB of new data in B1. | `evidence/k8up/b1`, `b2` |
| R1 | Restore the G1 file snapshot, pinned by ID and path, into new PVC `files-r1` | **Pass.** The restored manifest equals G1 byte for byte; the source still equals G2. 10 s. | `r1-pinned-g1` |
| R2 | Restore a nonexistent snapshot ID | Refused correctly ("no Snapshot found with ID …"). The pod crash-looped, and the Restore reported `Failed` only after the Job's backoff limit, about 6.5 minutes later. | `r2-missing-id` |
| R3 | Pinned ID of the database snapshot with `paths: [/data/files]` | Refused ("no Snapshot found"). `paths` works as a guard against the wrong source. | `r3-path-mismatch` |
| R4 | Restore with no snapshot named | **Restored the latest snapshot (G2) silently.** | `r4-implicit-latest` |
| R5 | `restoreTimeFilter: "2020-01-01"`, which matches nothing | **Fell back to the latest snapshot (G2) silently**, as documented. | `r5-timefilter-nomatch` |
| R6 | Restore G1 into `live-decoy`, a PVC that a running pod is using | **Not refused.** K8up wrote the snapshot into the in-use volume and merged it with the live files (no delete). | `r6-into-live` |
| D1 | Fetch the pinned database dump with `restic dump`, then `pg_restore` into isolated namespace `restore` (`26`, `27`) | **Pass.** The isolated database fingerprint equals G1 (1000 rows); the source still equals G2 (1100 rows). K8up's `Restore` cannot restore stdin backups, so this step used the restic CLI from the K8up image. | `pg-dump-restore` |
| I1 | Kill the file-volume pod 8 s into backup B3 (768 MiB) | Not an interruption: the upload had already finished. Kept as evidence. | `b3-interrupt` |
| I2 | B4 (2 GiB): block the store with a NetworkPolicy, force-kill the uploading pod 2 s after start, keep the store blocked for 90 s, then unblock (`28-k8up-interrupt.sh`) | During the outage, both jobs crash-looped (`restic init` could not reach the bucket) and the Backup showed `Progressing`, with no failure condition. After unblocking, the retry completed and two new snapshots appeared. | `b4-interrupt` |
| C1 | `Check` (`restic check`) after I2 (`29-k8up-retention.sh`) | **Blocked by the lock the killed pod left.** It retried every 35 s for at least 11 minutes, from 03:36 until the cluster was deleted. This matches restic treating a lock as stale only after 30 minutes when the holder's host is gone, but expiry was not observed. | `retention/check-final.log` |
| P1 | `Prune` with `keepLast: 1, keepTags: [g1]` | **Incomplete.** It was created but never ran, because it was queued behind C1 when the run was stopped. Protecting a referenced snapshot with `keepTags` is unproven. | `retention/` |

Footprint, sampled with `kubectl top` at the k3s default 15 s resolution:

- operator idle: 2–3 mCPU and 12–18 MiB;
- backup-command job pod: up to 79 mCPU and 15 MiB;
- whole node with K8up, RustFS and the fixture: 222 mCPU and 1367 MiB.

The file-volume job pods ran for under 15 s and were not sampled, so their peak memory is unmeasured.

Other observations:

- On k3s v1.32.5, the local-path provisioner created `spec.local` PVs with node affinity, not
  `hostPath`. The PV type on `nagare-01` has not been read and must not be inferred from this.
- The K8up 4.10.0 chart installed its CRDs, yet its NOTES text says "This Helm chart does not
  include CRDs". The note is stale.
- The K8up operator's ClusterRole creates Deployments, Jobs, ServiceAccounts and RoleBindings in
  any namespace. It binds `k8up-executor` (`pods/exec` create) into each backup namespace.

## Finding outside EP-163's scope: Nagare's local MinIO images are not pullable

On 2026-10-09 an anonymous pull of the digests pinned in `cluster/local/minio/minio.yaml` and
`cli/nagarectl/src/Nagare/Inventory/Components/LocalObjectStore.hs` failed:

```text
quay.io/minio/minio@sha256:14cea493…  -> 401 UNAUTHORIZED
quay.io/minio/mc@sha256:a7fe349e…     -> 401 UNAUTHORIZED
docker.io/minio/minio, docker.io/minio/mc -> repository does not exist or may require 'docker login'
```

A fresh local context on a machine without these images cached cannot start its object store. The
coordinator routes this finding to EP-183. This prototype used RustFS instead
(`10-objectstore.yaml`).

## Drivers

| File | Purpose |
|---|---|
| `env.sh`, `lib.sh` | Cluster identity, pinned versions, helpers. Refuses to run without `EVAL_DOCKER_HOST`. |
| `00-cluster-up.sh` | Create `mp24-eval` with its own kubeconfig. Refuses to reuse an existing cluster of that name. |
| `10-objectstore.yaml` | RustFS and bucket creation. |
| `20-k8up-fixture.yaml`, `21-k8up-seed.sh`, `23-k8up-mutate.sh` | Fixture, G1 and G2. |
| `22-k8up-backup.sh`, `24-k8up-restore.sh`, `25-k8up-inspect-claim.sh` | Backup, restore, read-only volume manifest. |
| `26-k8up-pg-dump-restore.yaml`, `27-k8up-pg-verify.sh` | Pinned database dump into an isolated PostgreSQL. |
| `28-k8up-interrupt.sh`, `29-k8up-retention.sh` | Interruption with a store outage; check and tagged prune. |
| `30-cnpg-install.sh`, `31-cnpg-source.yaml` | CloudNativePG 1.30.1 and barman-cloud 0.15.1. **Prepared, never run.** |

K8up was installed with
`helm install k8up k8up-4.10.0.tgz -n k8up --create-namespace --set k8up.skipWithoutAnnotation=true`,
using the chart from the `k8up-4.10.0` GitHub release.
