---
id: 84
slug: local-data-services-and-gcs-free-backups-and-snapshots-for-nagare
title: "Local data services and GCS-free backups and snapshots for nagare"
kind: exec-plan
created_at: 2026-06-30T00:56:38Z
intention: "intention_01kwb012h6ebgs5qjn5r12nyda"
master_plan: "docs/masterplans/16-local-development-and-testing-for-nagare.md"
---

# Local data services and GCS-free backups and snapshots for nagare

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today **nagare** (a single-node personal platform-as-a-service driven by the Haskell
command-line tool `nagarectl`) can only back up and restore its data to **Google Cloud
Storage (GCS)**. Four `nagarectl` verbs move data — `db backup`, `db restore`,
`storage snapshot`, and `storage restore` — and all four render the *same* short-lived
Kubernetes Job: a pod running the `google/cloud-sdk:slim` container that authenticates to a
GCS bucket through the **GCE metadata server** (a link-local HTTP service at IP
`169.254.169.254` that hands a pod the node service account's access token) and then runs
`gsutil cp`. On a laptop there is no metadata server and no GCS bucket, so those four verbs
cannot run; and although nagare's *other* data subsystems — managed databases (Postgres,
Redis, ClickHouse) running as Kubernetes StatefulSets, the Redpanda messaging broker, native
Kubernetes CronJob scheduled tasks, and `local-path` persistent volumes — are already
written to run on any Kubernetes cluster, no one has demonstrated them running locally.

After this change, an operator running nagare in **local mode** (a parallel target selected
by the environment variable `NAGARE_MODE=local`, established by the prerequisite plans EP-82
and EP-83 described below) can exercise nagare's whole data plane on their own machine with
no Google Cloud account and no cloud resources. Concretely, the user-visible behaviors you
will be able to demonstrate at the end are:

- `nagarectl db create postgres mydb` (and `redis`), `nagarectl broker create`, a scheduled
  task, and an app declaring a persistent volume all come up `Ready` on the local
  [k3d](https://k3d.io/) cluster that EP-82 stands up — proving the already-portable
  subsystems need no GCP and actually run locally (verified with `kubectl` output).
- A local **MinIO** object store (an S3-API-compatible server, the local stand-in for GCS)
  runs inside the cluster, exposing the bucket named by the `NAGARE_LOCAL_OBJECT_STORE`
  contract variable.
- `nagarectl db backup mydb` followed by `nagarectl db restore mydb <id>`, and
  `nagarectl storage snapshot myapp data` followed by `nagarectl storage restore myapp data
  <id>`, round-trip a real value through MinIO with **no GCS and no metadata server**: you
  write a sentinel row/file, back it up, delete it, restore it, and read it back.
- With `NAGARE_MODE` unset (cloud mode), every one of those verbs renders a Job that is
  **byte-for-byte identical** to today's — the GCS path is untouched, proving no regression.

The single behavioral change in the Haskell is concentrated in one module,
`cli/nagarectl/src/Nagare/Cluster/GcsJob.hs`, which renders the canonical data-movement Job
that all four verbs share. This plan generalizes that one module into a small **object-store
backend abstraction** driven by the resolved *mode* from `cli/nagarectl/src/Nagare/Target.hs`
(the `tpMode` field that EP-83 adds): in cloud mode it emits exactly the GCS Job it does
today; in local mode it emits a Job targeting the in-cluster MinIO endpoint with static
credentials from a Kubernetes Secret. Because all four verbs render through that one module,
this is exactly one rendering point to change (MasterPlan 16, Integration Point 3).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1.1 — On the EP-82 local cluster, `nagarectl db create postgres pgdemo` brings up a
      Postgres StatefulSet `Ready`; capture `kubectl get statefulset,pod,pvc,svc` evidence.
- [ ] M1.2 — `nagarectl db create redis rdemo` brings up a Redis StatefulSet `Ready`;
      capture evidence.
- [ ] M1.3 — `nagarectl broker create demo` (Redpanda) brings up the broker StatefulSet,
      ClusterIP Service, and PVC `Ready`; capture evidence.
- [ ] M1.4 — A scheduled task deploys as a native CronJob and a manually-triggered run
      `Complete`s; capture `kubectl get cronjob,job` evidence.
- [ ] M1.5 — An app declaring a persistent volume deploys and its `local-path` PVC binds
      `Bound`; capture evidence. Note and fix any incidental GCP assumption that surfaces
      (none expected).
- [ ] M2.1 — Add `cluster/local/minio/minio.yaml` (Namespace + Deployment + Service + the
      `nagare-minio-credentials` Secret + a one-shot bucket-create Job).
- [ ] M2.2 — Add a `just local-minio` recipe that applies the MinIO manifest and waits for it
      `Ready`; reference (do not duplicate) EP-82's `just local-bootstrap`.
- [ ] M2.3 — `just local-minio` brings MinIO up; `mc ls`/`aws s3 ls` against the bucket
      succeeds from an in-cluster probe pod; capture evidence.
- [x] M3.1 — Add `tpLocalObjectStore :: Text` to `TargetProfile` (resolved from
      `NAGARE_LOCAL_OBJECT_STORE`) in `cli/nagarectl/src/Nagare/Target.hs`. (Done 2026-06-29.)
- [x] M3.2 — Introduce the `StoreBackend` type and its helpers in
      `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs`; add `dmjHostAliases :: Maybe Value` to
      `DataMovementJob` and make `dataMovementJobSpec` omit `hostAliases` when `Nothing`.
      Cloud rendering stays byte-for-byte identical. (Done 2026-06-29.)
- [x] M3.3 — Thread `StoreBackend` through `Nagare.Database.Backup`, `Nagare.Database.Restore`,
      `Nagare.Storage.Snapshot`, and `Nagare.Storage.Restore` (replacing the per-input
      `*Project` field), and construct it once from `tpMode` in the `app/Main.hs` `run*`
      handlers and in `Nagare.Database.Create`. Centralized in
      `Nagare.Target.storeBackendFor` so Main and Create share one constructor. (Done 2026-06-29.)
- [x] M3.4 — Added `storeBackendModeTests` asserting each of the four renderers differs
      correctly by mode (GCS image + metadata + `gs://` vs `amazon/aws-cli` + `s3://` +
      `--endpoint-url` + `nagare-minio-credentials` secret ref, no metadata); cloud-invariance
      held by the still-green `gcsJobHostAliasesTests`/`backupProjectTests`/`backupRestoreTests`.
      `cabal test`: all 338 pass. (Done 2026-06-29.)
- [ ] M4.1 — End-to-end DB round-trip on the local cluster: write a sentinel row,
      `db backup`, delete it, `db restore --into live`, read it back. Capture transcript.
- [ ] M4.2 — End-to-end volume round-trip: write a sentinel file, `storage snapshot`, delete
      it, `storage restore --into-live`, read it back. Capture transcript.
- [ ] M4.3 — Confirm cloud-mode bytes unchanged: `nagarectl db backup --dry-run` /
      `storage snapshot` dry-run with `NAGARE_MODE` unset matches the pre-change golden.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The local self-prune lists basenames, not URLs, so its `storeLs`/`storeRmStdin` pair is
  internally consistent rather than symmetric with the GCS pair (M3).** `gsutil ls "$PREFIX"`
  emits full `gs://…` URLs that `gsutil -m rm -I` consumes directly. `aws s3 ls "$PREFIX"`
  emits bare object basenames (its last whitespace column), and `aws s3 rm` takes no stdin —
  so the MinIO `storeLs` pipes `… | awk '{print $NF}'` (basenames) and `storeRmStdin` reads
  basenames and re-qualifies each against the `$PREFIX` env the upload container already
  exports (`while read k; do aws s3 rm "$PREFIX$k" …; done`). The `storeLs | sort -r | tail |
  storeRmStdin` pipeline therefore works for both backends because each backend's listing
  format matches its own delete. This only affects the in-pod CronJob self-prune; the M4
  round-trip does not exercise prune (EP-84 Decision Log). Date: 2026-06-29.


## Decision Log

Record every decision made while working on the plan.

- Decision: the local object store is **MinIO**, not LocalStack or moto.
  Rationale: MinIO is a single self-contained S3-API server (one Deployment + Service +
  bucket-create Job, a few megabytes of manifest) with no AWS-account or feature-emulation
  surface. LocalStack and moto emulate the broad AWS API (and gate S3 behind a service
  selector and, for LocalStack, a heavier image and licensing tiers); we need only an S3
  `cp`/`ls`/`rm` target reachable in-cluster. MinIO is also the de-facto local S3 used by the
  `mc`/`aws s3` clients we render into the Job, so the same commands that work locally are a
  faithful analogue of the GCS path. (Date: 2026-06-30.)

- Decision: generalize the **single** `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs` module into
  a backend abstraction rather than adding a mode branch in each of the four caller modules.
  Rationale: all four verbs already render through `GcsJob` precisely because a prior live
  audit (recorded in that module's header) found the GCS scaffolding had been copy-pasted and
  drifted — one path was fixed while another stayed broken. Branching in four callers would
  re-introduce exactly that drift risk for the local backend. Centralizing the
  image/`hostAliases`/env/URL/command vocabulary behind one `StoreBackend` value keeps the
  "which backend?" decision in exactly one place (constructing the value from `tpMode`),
  threaded everywhere else as data. (Date: 2026-06-30.)

- Decision: local credentials are supplied by a Kubernetes **Secret**
  (`nagare-minio-credentials`, keys `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, default
  `minioadmin` / `minioadmin`), injected into the Job container via `secretKeyRef`; the MinIO
  endpoint is passed per-command with `--endpoint-url`.
  Rationale: this mirrors how the cloud Job obtains credentials ambiently (the node service
  account) but in a way that exists on a laptop — static keys are appropriate for a local
  test store, never leave the cluster, and are referenced by name so no secret material is
  rendered into a manifest. Standard AWS env-var names mean the `amazon/aws-cli` client reads
  them with no extra configuration. (Date: 2026-06-30.)

- Decision: the local data-movement container is **`amazon/aws-cli`** running `aws s3`
  (against `--endpoint-url`), not `minio/mc`.
  Rationale: `aws s3 cp - s3://…` / `aws s3 cp s3://… -` stream stdin/stdout exactly like
  `gsutil cp -`, and `aws s3 ls` / `aws s3 rm` mirror `gsutil ls` / `gsutil rm`, so the only
  per-command change is the binary and an `--endpoint-url` flag — the surrounding shell
  (`tar -czf - | …`, `… | gunzip`) is unchanged. The image's Amazon Linux base ships `tar`
  and `gzip`, which the snapshot/backup pipelines need. (If a future base image drops `tar`,
  fall back to `minio/mc` with `mc pipe`; recorded so the fallback is explicit.)
  (Date: 2026-06-30.)

- Decision: keep the **object key layout stable** across backends —
  `databases/<name>/<ts>.<ext>` and `volumes/<app>/<vol>/<ts>.tar.gz` — changing only the URL
  scheme/bucket (`gs://<backup-bucket>/<key>` in cloud, `s3://<minio-bucket>/<key>` in local).
  Rationale: the retention/listing logic (`snapshotsToPrune`, the `db restore` /
  `storage restore` bare-timestamp resolution) is purely a function of the key tail, so
  preserving the layout reuses every pure helper unchanged and keeps backups taken in one mode
  legible to the listing code in the other. (Date: 2026-06-30.)

- Decision: the cloud-vs-local backend is constructed in __one pure function__,
  `Nagare.Target.storeBackendFor :: TargetProfile -> Text -> Either Text StoreBackend`, rather
  than duplicated in `app/Main.hs` and `Nagare.Database.Create`. `Main.resolveStoreBackend`
  and `Database.Create` both call it; a `Local` profile with an unset/malformed
  `NAGARE_LOCAL_OBJECT_STORE` returns `Left` so the caller fails loudly instead of silently
  targeting GCS from a laptop. `Nagare.Target` already bridges the resolved profile to its
  consumers and importing `StoreBackend` from `Nagare.Cluster.GcsJob` is acyclic (GcsJob is a
  leaf), so it is the natural single home for the mode→backend mapping. (Date: 2026-06-29.)

- Decision: the database-restore URL predicate `isGsUrl` is generalized to
  `isObjectUrl` (recognizing both `gs://` and `s3://`) and both restore paths
  (`Nagare.Database.Restore`, `Nagare.Storage.Restore`) compose bare timestamps via
  `storeObjectUrl backend (…ObjectPath …)`, so a backup id may be passed as a full URL in
  either scheme or as a bare timestamp in either mode. The bucket-bound URL helpers
  `dbBackupGsUrl`/`dbBackupPrefix`/`snapshotGsUrl` are removed in favor of the pure key
  builders (`dbBackupObjectPath`, `dbBackupKeyPrefix`, `snapshotObjectPath`) wrapped by
  `storeObjectUrl`/`storePrefixUrl`, keeping the key layout identical across backends.
  (Date: 2026-06-29.)

- Decision: in local mode, on-demand pruning (the laptop-side `gsutil ls | … | gsutil rm` in
  `runDbBackup`/`runSnapshot`) is **skipped on the laptop**; retention is exercised only by
  the in-pod self-prune path (the backup CronJob, now backend-aware) and proven by the pure
  `snapshotsToPrune` unit tests.
  Rationale: the MinIO Service is in-cluster (ClusterIP) and not reachable from the laptop
  without a port-forward; the M4 round-trip acceptance (write → back up → delete → restore →
  read) does not depend on prune, and the pure retention logic is already unit-tested. Adding
  laptop→MinIO connectivity would pull EP-82 scope (a stable cross-vantage endpoint) into this
  plan for no acceptance gain. (Date: 2026-06-30.)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### What the pieces are (terms of art)

- **`nagarectl`** — the Haskell command-line program operators run to deploy apps, manage
  databases, snapshot volumes, and check health. Its library is under
  `cli/nagarectl/src/`, its `main` entry point is `cli/nagarectl/app/Main.hs`, and its tests
  are in `cli/nagarectl/test/Spec.hs`. It is built with `cabal`; the toolchain comes from the
  repo's Nix dev shell (run commands under `nix develop -c <cmd>` if `cabal`/`ghc` are not on
  the PATH).

- **data-movement Job** — a short-lived Kubernetes `batch/v1` Job (a pod that runs once to
  completion and is then deleted) that copies bytes between the cluster and an object store.
  All four data verbs render one. Its shared pod scaffolding is produced by
  `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs` so it cannot drift between verbs.

- **GCE metadata server** — a link-local HTTP endpoint at IP `169.254.169.254` that, on a
  Google Compute Engine VM, hands a process an OAuth access token minted from the VM's
  attached service account (this is "Application Default Credentials", ADC). `gsutil`/`gcloud`
  reach it by the DNS name `metadata.google.internal`, which a pod cannot resolve through
  cluster DNS — hence the Job's `hostAliases` entry mapping that name to the IP. On a laptop
  there is no metadata server, so this whole mechanism is absent in local mode.

- **MinIO** — a small server that speaks the Amazon S3 HTTP API. In local mode it runs as a
  Deployment inside the cluster and is the destination for backups/snapshots. The S3 clients
  `aws s3` and `mc` talk to it by URL (`--endpoint-url`), which is how we point the standard
  GCS-shaped commands at a non-GCS store.

- **target profile** — the resolved description of *where* nagare acts, produced once by
  `resolveTargetProfile :: IO TargetProfile` in `cli/nagarectl/src/Nagare/Target.hs` from the
  process environment with built-in defaults. EP-83 (a checked-in prerequisite,
  `docs/plans/83-decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode.md`) adds a
  resolved **mode** to this record: a field `tpMode :: Mode` where `data Mode = Cloud | Local`,
  read from the environment variable `NAGARE_MODE` (`local` selects local mode; unset or
  `cloud` preserves today's behavior). This plan reads `tpMode` to choose the object-store
  backend; it never re-derives the mode from the environment itself.

- **`StatefulSet` / `local-path` PVC** — a `StatefulSet` is a Kubernetes controller that runs
  a pod with stable identity and storage; nagare's managed databases and the Redpanda broker
  are StatefulSets. A `PersistentVolumeClaim` (PVC) requests disk; `local-path` is the
  storage class k3s/k3d provides by carving the volume out of the node's filesystem. Both are
  cluster-portable: nothing in them references GCP.

### The current state (what works, and the one thing that does not, locally)

The four data verbs share one Job renderer, `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs`. It
exports the canonical scaffolding fragments and the Job `.spec` assembler:

- `metadataHostAliases :: Value` (lines ~47–54) — the `hostAliases` entry mapping
  `metadata.google.internal` to `169.254.169.254`.
- `metadataEnv :: Text -> [Value]` (lines ~60–64) — the two env entries
  `GCE_METADATA_HOST=169.254.169.254` and `CLOUDSDK_CORE_PROJECT=<project>`.
- `gcsContainerImage :: Text = "google/cloud-sdk:slim"` (line ~69).
- `data DataMovementJob` (lines ~75–84) — the per-Job variation: optional pod-template
  labels, init containers, containers, volumes.
- `dataMovementJobSpec :: DataMovementJob -> Value` (lines ~91–110) — assembles the `.spec`,
  unconditionally inserting `"hostAliases" .= metadataHostAliases` right after
  `"restartPolicy"`.

The four callers use it like this (each builds its own URL, env, and shell):

- `cli/nagarectl/src/Nagare/Database/Backup.hs` — `db backup`. Pure path helpers
  `dbBackupObjectPath`/`dbBackupGsUrl`/`dbBackupPrefix` (lines ~64–75) build
  `gs://<bucket>/databases/<name>/<ts>.<ext>`. `uploadContainer` (lines ~171–187) runs
  `gcsContainerImage`, sets env `metadataEnv (bjiProject i)`, and `uploadShell` (lines
  ~233–245) runs `gzip … | gsutil … cp - "$DEST"` plus an optional in-pod self-prune
  (`gsutil ls "$PREFIX" | sort -r | tail | gsutil -m rm -I`). `runDbBackup` (line ~308) also
  prunes laptop-side via `gsutil ls`/`gsutil rm` (`pruneBackups`, lines ~385–393).
- `cli/nagarectl/src/Nagare/Database/Restore.hs` — `db restore`. `downloadContainer` (lines
  ~99–110) runs `gcsContainerImage` with `metadataEnv (rjiProject i)`; `downloadShell` (line
  ~146) runs `gsutil cp "$SRC" - | gunzip`.
- `cli/nagarectl/src/Nagare/Storage/Snapshot.hs` — `storage snapshot`. `snapshotObjectPath`/
  `snapshotGsUrl` (lines ~69–76) build `gs://<bucket>/volumes/<app>/<vol>/<ts>.tar.gz`; the
  container (lines ~152–169) runs `gcsContainerImage` with `metadataEnv (sjiProject i)`, and
  `snapshotShell` (lines ~181–185) runs `tar -C … -czf - . | gsutil … cp - "$DEST"`.
  `pruneSnapshots` (lines ~256–267) prunes laptop-side via `gsutil`.
- `cli/nagarectl/src/Nagare/Storage/Restore.hs` — `storage restore`. `restoreContainer`
  (lines ~96–107) runs `gcsContainerImage` with `metadataEnv (sriProject i)`; `restoreShell`
  (lines ~111–117) runs `gsutil cp "$SRC" - | tar -C … -xzf -`.

Each input record already carries a `*Project :: Text` field (`bjiProject`, `rjiProject`,
`sjiProject`, `sriProject`) added by EP-62 so the rendered `CLOUDSDK_CORE_PROJECT` follows the
target. The handlers in `app/Main.hs` construct these and call the drivers (lines ~2741–2824):
they resolve the profile, resolve the backup bucket (`resolveBackupBucket`, line ~2913 —
falls back to `tpBackupBucket`), and pass `bucket` and `tpProject tp` separately. The scheduled
backup CronJob is rendered at database-create time in
`cli/nagarectl/src/Nagare/Database/Create.hs` (lines ~137–138) via `renderDbBackupCronJob …
(tpProject tp)`.

The other data subsystems have **no** GCP coupling and need no code change:

- Managed-database CREATE renders a StatefulSet + Service + Secret via
  `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs`, applied by
  `cli/nagarectl/src/Nagare/Database/Create.hs`. Storage is a `local-path` PVC.
- The Redpanda broker renders a StatefulSet (ClusterIP Service, `local-path` PVC) via
  `cli/nagare-dsl/src/Nagare/Dsl/Broker/Render.hs` — already provider-neutral and
  cloud-agnostic (it pulls the public `redpandadata/redpanda` image and uses
  `storageClassName: local-path`).
- Scheduled tasks render native Kubernetes CronJobs (`cli/nagarectl/src/Nagare/Task/*`).
- Persistent volumes use the `local-path` provisioner k3d ships.

So M1 of this plan is *verification with evidence*, not code: prove these four run on the
EP-82 cluster.

### Prerequisites this plan consumes (checked-in plans)

- **EP-82** (`docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md`,
  soft dependency) stands up the local k3d cluster and local registry, defines the
  `nagare.local.env` profile and the `NAGARE_MODE=local` switch, installs Knative/Kourier
  locally, and owns the `just local-up` / `just local-bootstrap` recipes and the
  `NAGARE_LOCAL_OBJECT_STORE` contract variable (MasterPlan 16 Integration Point 1). This plan
  does not create the cluster; it runs on it and adds the MinIO install on top of EP-82's
  bootstrap.
- **EP-83** (`docs/plans/83-decouple-nagarectl-deploy-and-build-from-gcp-for-local-mode.md`,
  hard dependency) adds `tpMode :: Mode` (with `data Mode = Cloud | Local`) to `TargetProfile`
  and resolves it from `NAGARE_MODE` (MasterPlan 16 Integration Point 2). This plan imports
  `Mode` and `tpMode`; it must not re-derive the mode itself.

### The `NAGARE_LOCAL_OBJECT_STORE` contract value

EP-82 fixes this variable's exact string and owns its documentation. For this plan it has the
form `<endpoint-url>/<bucket>`, for example:

```text
NAGARE_LOCAL_OBJECT_STORE=http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
```

The endpoint (everything up to the last path segment) is the in-cluster S3 endpoint a Job
container reaches; the final path segment (`nagare-backups`) is the bucket. This plan parses
it into `(endpoint, bucket)`; the object **key** under that bucket keeps the stable layout
(`databases/…`, `volumes/…`). The endpoint is the in-cluster DNS name, so it resolves from a
pod; the laptop never contacts MinIO (see the prune Decision above).

### Files this plan creates

- `cluster/local/minio/minio.yaml` — NEW. The local MinIO Namespace, Deployment, Service, the
  `nagare-minio-credentials` Secret, and a one-shot bucket-create Job. Placed under
  `cluster/local/` (a local-only path) so it is never applied to the cloud cluster.

### Files this plan edits

- `cli/nagarectl/src/Nagare/Target.hs` — add the `tpLocalObjectStore` field + its resolution.
- `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs` — the backend abstraction (`StoreBackend` and
  its helpers); make `hostAliases` conditional.
- `cli/nagarectl/src/Nagare/Database/Backup.hs`, `…/Database/Restore.hs`,
  `…/Storage/Snapshot.hs`, `…/Storage/Restore.hs` — thread `StoreBackend` (replace `*Project`).
- `cli/nagarectl/src/Nagare/Database/Create.hs` — construct the backend for the CronJob.
- `cli/nagarectl/app/Main.hs` — construct the backend once from `tpMode` in the four `run*`
  handlers; guard the laptop-side prune by mode.
- `cli/nagarectl/test/Spec.hs` — the per-mode renderer tests.
- `justfile` — the `just local-minio` recipe.

### Scope boundary — what this plan does NOT do

It does not create the k3d cluster, the local registry, the Knative/Kourier bootstrap, the
`nagare.local.env` profile, or the `NAGARE_MODE`/`tpMode` resolution (EP-82 and EP-83). It does
not touch the auth plane or TLS (EP-85). It does not write the `just local-smoke` harness or
the local-development runbook (EP-86). It makes no change to the cloud GCS path's rendered
bytes.


## Plan of Work

The work is four milestones. **M1** is verification-only: demonstrate the already-portable
subsystems (databases, broker, scheduled tasks, volumes) running on EP-82's local cluster,
fixing any incidental GCP assumption that surfaces. **M2** deploys MinIO into the cluster and
wires its install behind a `just local-minio` recipe. **M3** is the one code change: generalize
`Nagare.Cluster.GcsJob` into a `StoreBackend` abstraction driven by `tpMode`, keeping the cloud
branch byte-for-byte identical, with unit tests proving the four renderers differ correctly by
mode. **M4** is the end-to-end acceptance: a real value round-trips through MinIO for both the
database and the volume paths, with no GCS and no metadata server. Each milestone ends in an
observable result.


### Milestone 1 — verify the portable data subsystems run locally

Scope: with EP-82's cluster up (`just local-up && just local-bootstrap`) and local mode
selected (`NAGARE_MODE=local`, the `nagare.local.env` profile sourced), demonstrate that
`nagarectl db create postgres`, `db create redis`, `broker create`, a scheduled-task deploy,
and an app with a persistent volume all reach `Ready`/`Bound`/`Complete` with no code change.
This proves the create/connect/list paths are cloud-agnostic. At the end of M1, the Progress
checklist M1.1–M1.5 carry captured `kubectl` evidence. If any command assumes GCP (it should
not), note it in Surprises & Discoveries and fix it minimally.

Commands to run (from the repo root, in a shell where the local profile is sourced): the
`nagarectl …` create commands plus `kubectl get …` (exact transcripts in Concrete Steps).
Acceptance: each resource reports `Ready`/`Bound`/`Complete` in `kubectl` output.


### Milestone 2 — deploy MinIO into the local cluster

Scope: add `cluster/local/minio/minio.yaml` (Namespace `nagare-system`, a MinIO Deployment, a
ClusterIP Service on port 9000, the `nagare-minio-credentials` Secret, and a one-shot Job that
runs `mc mb` to create the `nagare-backups` bucket), and a `just local-minio` recipe that
applies it and waits for readiness. The recipe references EP-82's bootstrap (it is meant to run
after `just local-bootstrap`) and does not duplicate any cluster setup. At the end of M2, MinIO
is reachable in-cluster at the `NAGARE_LOCAL_OBJECT_STORE` endpoint and the bucket exists.

Commands to run: `just local-minio`, then an in-cluster probe (a throwaway pod running
`aws s3 ls`/`mc ls`). Acceptance: the probe lists the bucket with exit code 0; `kubectl -n
nagare-system get deploy,svc,job` shows MinIO `Available` and the bucket Job `Complete`.


### Milestone 3 — generalize `GcsJob` into a mode-driven `StoreBackend`

Scope: this is the only code-behavior change. Introduce a `StoreBackend` value in
`cli/nagarectl/src/Nagare/Cluster/GcsJob.hs` that captures everything that differs between GCS
and MinIO — the container image, whether to render the metadata `hostAliases`, the env block
(metadata env vs. MinIO endpoint + `secretKeyRef` creds), the destination/prefix **URL**
(`gs://bucket/key` vs `s3://bucket/key`), and the `cp`/`ls`/`rm` shell verbs (`gsutil` vs
`aws s3 … --endpoint-url`). Thread one `StoreBackend` through the four caller modules, replacing
the per-input `*Project` field, and construct it **once** from `tpMode` in `app/Main.hs` (and in
`Database.Create` for the CronJob). In cloud mode the rendered Job is byte-for-byte identical to
today. At the end of M3, `cabal test` proves each of the four renderers emits the GCS shape in
cloud mode and the MinIO shape in local mode.

Commands to run: `cd cli/nagarectl && cabal build && cabal test`. Acceptance: a new test group
renders each verb's Job under both backends and asserts — cloud: contains
`google/cloud-sdk:slim`, `metadata.google.internal`, `169.254.169.254`, `gs://`, `gsutil`;
local: contains `amazon/aws-cli`, `s3://`, `--endpoint-url`, a `secretKeyRef` to
`nagare-minio-credentials`, and does **not** contain `metadata.google.internal` or
`169.254.169.254`. The existing `gcsJobHostAliasesTests` (cloud) stays green unchanged.


### Milestone 4 — end-to-end round-trip through MinIO

Scope: on the local cluster with MinIO up and `NAGARE_MODE=local`, prove a real value survives
a backup/restore and a snapshot/restore with no GCS and no metadata server. Database path:
create `pgdemo`, write a sentinel row, `db backup pgdemo`, drop the row, `db restore pgdemo
<id> --into live`, read the row back. Volume path: deploy an app with a volume, write a sentinel
file into it, `storage snapshot myapp data`, delete the file, `storage restore myapp data <id>
--into-live`, read the file back. At the end of M4 both transcripts are captured in Concrete
Steps and the Progress list is complete.

Commands to run: the `nagarectl` verbs plus `kubectl exec` to write/read the sentinels (exact
transcripts in Concrete Steps). Acceptance: the restored row/file matches the sentinel, and the
MinIO Job logs show `aws s3 cp … s3://nagare-backups/…` with no `169.254.169.254` and no
`metadata.google.internal`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a
working directory is stated. A shell with the local profile sourced means EP-82's
`nagare.local.env` is in effect and `NAGARE_MODE=local`; verify with `echo "$NAGARE_MODE"`
printing `local` and `kubectl config current-context` pointing at the k3d cluster (e.g.
`k3d-nagare`). The Haskell toolchain comes from the Nix dev shell; prefix with
`nix develop -c` if `cabal` is not found.


### Step M1.1–M1.5 — verify databases, broker, task, and volume

```bash
# Cluster up and local mode selected (EP-82 provides these recipes).
just local-up
just local-bootstrap
echo "$NAGARE_MODE"            # -> local
kubectl config current-context # -> k3d-nagare (or the EP-82 name)

# Postgres + Redis managed databases (StatefulSets, local-path PVCs).
cabal run nagarectl -- db create postgres pgdemo
cabal run nagarectl -- db create redis rdemo
kubectl get statefulset,pod,pvc,svc -l nagare.dev/managed-by=nagarectl
```

Expected (abridged): the StatefulSets report `READY 1/1`, the pods `Running`, the PVCs
`Bound` on `local-path`:

```text
NAME                        READY   AGE
statefulset.apps/pgdemo     1/1     40s
statefulset.apps/rdemo      1/1     30s
NAME          READY   STATUS    RESTARTS   AGE
pod/pgdemo-0  1/1     Running   0          40s
pod/rdemo-0   1/1     Running   0          30s
NAME                              STATUS   VOLUME    CAPACITY   STORAGECLASS
persistentvolumeclaim/...pgdemo   Bound    pvc-...   1Gi        local-path
```

```bash
# Redpanda broker (StatefulSet + ClusterIP Service + PVC), already cloud-agnostic.
cabal run nagarectl -- broker create demo
kubectl get statefulset,svc,pvc -l nagare.dev/broker=demo
```

Expected: `statefulset.apps/demo 1/1`, a `ClusterIP` service exposing `kafka`/`admin`, a
`Bound` PVC.

```bash
# A scheduled task renders a native CronJob; trigger one run by hand and watch it complete.
cabal run nagarectl -- deploy --dry-run   # or the task-create path EP-51 defines
kubectl get cronjob
kubectl create job --from=cronjob/<name> <name>-manual
kubectl get job <name>-manual -w          # -> COMPLETIONS 1/1
```

```bash
# An app with a persistent volume: its local-path PVC binds.
cabal run nagarectl -- deploy             # an example app declaring a volume
kubectl get pvc -l nagare.dev/managed-by=nagarectl
```

Record the captured output under Progress M1.1–M1.5. No code change is expected; if a command
fails because it assumes a GCP project (it should not — the create paths carry no GCP), record
it in Surprises & Discoveries and fix it minimally.


### Step M2.1 — add `cluster/local/minio/minio.yaml`

Create the manifest. It is a self-contained local store: a `nagare-system` namespace, the
credentials Secret, a MinIO Deployment + ClusterIP Service, and a one-shot bucket-create Job.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nagare-system
---
apiVersion: v1
kind: Secret
metadata:
  name: nagare-minio-credentials
  namespace: nagare-system
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: minioadmin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: nagare-system
  labels: { app: minio }
spec:
  replicas: 1
  selector: { matchLabels: { app: minio } }
  template:
    metadata:
      labels: { app: minio }
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: { secretKeyRef: { name: nagare-minio-credentials, key: AWS_ACCESS_KEY_ID } }
            - name: MINIO_ROOT_PASSWORD
              valueFrom: { secretKeyRef: { name: nagare-minio-credentials, key: AWS_SECRET_ACCESS_KEY } }
          ports:
            - { name: s3, containerPort: 9000 }
            - { name: console, containerPort: 9001 }
          readinessProbe:
            httpGet: { path: /minio/health/ready, port: 9000 }
            periodSeconds: 5
          volumeMounts:
            - { name: data, mountPath: /data }
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: nagare-system
spec:
  type: ClusterIP
  selector: { app: minio }
  ports:
    - { name: s3, port: 9000, targetPort: s3 }
    - { name: console, port: 9001, targetPort: console }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-make-bucket
  namespace: nagare-system
spec:
  backoffLimit: 6
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: minio/mc:latest
          command: ["/bin/sh", "-c"]
          args:
            - >
              until mc alias set local http://minio:9000 "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY";
              do echo waiting for minio; sleep 2; done;
              mc mb --ignore-existing local/nagare-backups;
              mc ls local
          env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom: { secretKeyRef: { name: nagare-minio-credentials, key: AWS_ACCESS_KEY_ID } }
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom: { secretKeyRef: { name: nagare-minio-credentials, key: AWS_SECRET_ACCESS_KEY } }
```

The data volume is an `emptyDir` (the local store is disposable test storage; for a durable
local store, swap to a `local-path` PVC — recorded as a follow-up, not required for the
round-trip). The bucket name `nagare-backups` matches the `NAGARE_LOCAL_OBJECT_STORE` example.


### Step M2.2 — add the `just local-minio` recipe

Add to `justfile`, in the `cluster` group, a recipe that applies the manifest and waits.
It is meant to run after EP-82's `just local-bootstrap`; it does not duplicate cluster setup.

```just
# Install the local MinIO object store (EP-84). Run after `just local-bootstrap`.
[group('cluster')]
local-minio:
    kubectl apply -f cluster/local/minio/minio.yaml
    kubectl -n nagare-system rollout status deploy/minio
    kubectl -n nagare-system wait --for=condition=complete --timeout=120s job/minio-make-bucket
    @echo "MinIO ready at http://minio.nagare-system.svc.cluster.local:9000 (bucket: nagare-backups)"
```

If EP-82's `just local-bootstrap` grows a hook to call sub-steps, add `local-minio` there;
otherwise it is a standalone step documented in the runbook EP-86 writes.


### Step M2.3 — verify MinIO from an in-cluster probe

```bash
just local-minio
kubectl run minio-probe --rm -it --restart=Never --image=amazon/aws-cli:latest \
  --namespace nagare-system \
  --env AWS_ACCESS_KEY_ID=minioadmin --env AWS_SECRET_ACCESS_KEY=minioadmin \
  --env AWS_DEFAULT_REGION=us-east-1 --env AWS_EC2_METADATA_DISABLED=true \
  -- s3 ls s3://nagare-backups --endpoint-url http://minio:9000
```

Expected: exit code 0 (an empty bucket lists nothing, which is success). `kubectl -n
nagare-system get deploy,svc,job` shows `deployment.apps/minio  1/1`, `service/minio`, and
`job.batch/minio-make-bucket  Complete`.


### Step M3 — the `StoreBackend` abstraction

The full signatures are in **Interfaces and Dependencies**; this step is the edit order.

1. `cli/nagarectl/src/Nagare/Target.hs` — add `tpLocalObjectStore :: !Text` to `TargetProfile`
   and resolve it: `localObjectStore <- envOr "NAGARE_LOCAL_OBJECT_STORE" ""`. (Empty string
   means "unset"; it is only read in local mode, where EP-82's profile sets it.)

2. `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs` — add the backend:

```haskell
-- | Where a data-movement Job sends/reads bytes. Constructed once from the
-- resolved mode (cloud vs local) and threaded as data, so the "which store?"
-- decision lives in exactly one place.
data StoreBackend
  = GcsBackend !Text !Text
  -- ^ Cloud: the GCP project (for CLOUDSDK_CORE_PROJECT) and the GCS bucket.
  | MinioBackend !MinioRef
  -- ^ Local: the in-cluster MinIO endpoint, bucket, and credentials Secret.

data MinioRef = MinioRef
  { mrEndpoint   :: !Text  -- ^ e.g. http://minio.nagare-system.svc.cluster.local:9000
  , mrBucket     :: !Text  -- ^ the bucket, from NAGARE_LOCAL_OBJECT_STORE
  , mrSecretName :: !Text  -- ^ k8s Secret with AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  }

-- | Parse NAGARE_LOCAL_OBJECT_STORE ("<endpoint>/<bucket>") into endpoint+bucket.
parseLocalObjectStore :: Text -> Maybe (Text, Text)

-- | The container image for the backend's data-movement container.
storeImage :: StoreBackend -> Text
-- GcsBackend{} -> "google/cloud-sdk:slim" ; MinioBackend{} -> "amazon/aws-cli:latest"

-- | The pod-level hostAliases: Just metadataHostAliases for GCS, Nothing for MinIO.
storeHostAliases :: StoreBackend -> Maybe Value

-- | The container env: metadataEnv project for GCS; for MinIO the AWS creds via
-- secretKeyRef plus AWS_DEFAULT_REGION/AWS_EC2_METADATA_DISABLED.
storeEnv :: StoreBackend -> [Value]

-- | The full object URL for a stable key ("databases/…"/"volumes/…").
-- GcsBackend -> "gs://<bucket>/<key>" ; MinioBackend -> "s3://<bucket>/<key>".
storeObjectUrl :: StoreBackend -> Text -> Text
storePrefixUrl :: StoreBackend -> Text -> Text

-- | The shell command verbs, parameterised by a shell expression for the URL.
-- GCS uses gsutil; MinIO uses `aws s3 … --endpoint-url <endpoint>`.
storeCpFromStdin :: StoreBackend -> Text -> Text  -- copy stdin -> dest expr
storeCpToStdout  :: StoreBackend -> Text -> Text  -- copy src expr -> stdout
storeLs          :: StoreBackend -> Text -> Text  -- list a prefix expr
storeRmStdin     :: StoreBackend -> Text          -- delete object names read on stdin
```

   Then add `dmjHostAliases :: !(Maybe Value)` to `DataMovementJob` and change
   `dataMovementJobSpec` to insert the `hostAliases` pair only when it is `Just`, using the
   same `++ [… | cond]` pattern already used for `initContainers`. With
   `dmjHostAliases = Just metadataHostAliases` the cloud bytes are unchanged.

3. The four caller modules: replace each `*Project :: Text` input field with
   `*Backend :: StoreBackend`, set `dmjHostAliases = storeHostAliases backend`, set each
   container's `"image" .= storeImage backend` and `"env"` to include `storeEnv backend`, build
   destination/prefix URLs via `storeObjectUrl`/`storePrefixUrl`, and build each shell from the
   `storeCp*`/`storeLs`/`storeRmStdin` verbs instead of literal `gsutil`. The pure path helpers
   (`dbBackupObjectPath`, `snapshotObjectPath`) keep building the **key**; only the URL
   wrapper changes. Example for the snapshot container shell:

```haskell
-- before: "set -e; tar -C " <> mp <> " -czf - . | gsutil … cp - \"$DEST\""
-- after:  "set -e; tar -C " <> mp <> " -czf - . | " <> storeCpFromStdin backend "\"$DEST\""
```

4. `cli/nagarectl/app/Main.hs` — add `resolveStoreBackend :: Maybe String -> IO StoreBackend`
   that resolves the profile once and returns `GcsBackend (tpProject tp) bucket` when
   `tpMode tp == Cloud` (with `bucket` from `resolveBackupBucket`), or `MinioBackend` (parsing
   `tpLocalObjectStore tp`, secret `nagare-minio-credentials`) when `Local`. The four handlers
   (lines ~2741–2824) call it instead of computing `bucket`/`project` separately, and the two
   drivers that prune laptop-side (`runDbBackup`, `runSnapshot`) skip the laptop prune when the
   backend is `MinioBackend`. `Nagare.Database.Create` builds the same backend for the CronJob.

5. `cli/nagarectl/test/Spec.hs` — add `storeBackendModeTests` (see Validation).

Build and test:

```bash
cd cli/nagarectl && cabal build && cabal test
```


### Step M4.1 — database round-trip through MinIO

```bash
# (pgdemo exists from M1; MinIO up from M2; NAGARE_MODE=local)
kubectl exec -it pgdemo-0 -- psql -U postgres -d postgres -c \
  "CREATE TABLE IF NOT EXISTS sentinel(v text); INSERT INTO sentinel VALUES ('hello-local');"

cabal run nagarectl -- db backup pgdemo
# -> "Backup written: s3://nagare-backups/databases/pgdemo/<ts>.sql.gz"

kubectl exec -it pgdemo-0 -- psql -U postgres -d postgres -c "DROP TABLE sentinel;"

cabal run nagarectl -- db restore pgdemo <ts> --into live
kubectl exec -it pgdemo-0 -- psql -U postgres -d postgres -c "SELECT v FROM sentinel;"
# -> hello-local
```

Inspect the restore Job logs (captured before the Job is deleted) and confirm
`aws s3 cp s3://nagare-backups/databases/pgdemo/<ts>.sql.gz -` appears and neither
`169.254.169.254` nor `metadata.google.internal` does.


### Step M4.2 — volume round-trip through MinIO

```bash
# myapp declares a volume 'data' mounted at /data (deployed in M1).
POD=$(kubectl get pod -l serving.knative.dev/service=myapp -o name | head -1)
kubectl exec -it "$POD" -- sh -c 'echo hello-volume > /data/sentinel.txt'

cabal run nagarectl -- storage snapshot myapp data
# -> "Snapshot written: s3://nagare-backups/volumes/myapp/data/<ts>.tar.gz"

kubectl exec -it "$POD" -- rm /data/sentinel.txt
cabal run nagarectl -- storage restore myapp data <ts> --into-live
kubectl exec -it "$POD" -- cat /data/sentinel.txt
# -> hello-volume
```


### Step M4.3 — confirm cloud bytes unchanged

```bash
# In a cloud-mode shell (NAGARE_MODE unset / cloud), the dry-run rendering is identical
# to the pre-change golden.
unset NAGARE_MODE
cabal run nagarectl -- db backup pgdemo --dry-run | grep -E "google/cloud-sdk:slim|169.254.169.254|gs://"
```

Expected: the GCS image, the metadata IP, and the `gs://` destination all still appear — the
cloud branch is byte-for-byte unchanged.


## Validation and Acceptance

Acceptance is the M4 round-trip: a value written before a backup/snapshot is readable after a
restore, through MinIO, with no GCS and no metadata server. That is behavior a human verifies
with the transcripts above (`SELECT v FROM sentinel` returns `hello-local`; `cat
/data/sentinel.txt` returns `hello-volume`), and the Job logs show `aws s3` against
`s3://nagare-backups/…` with no `169.254.169.254`.

Beyond the end-to-end run, M3 is locked in by unit tests that fail before and pass after.
Mirror the existing `gcsJobHostAliasesTests` in `cli/nagarectl/test/Spec.hs` (which renders all
four verbs through the shared module and asserts the GCS scaffolding). Add a
`storeBackendModeTests` group that renders each of the four verbs' Jobs under both a
`GcsBackend "tan-nb-exp" "tan-nb-exp-nagare-backups"` and a
`MinioBackend (MinioRef "http://minio.nagare-system.svc.cluster.local:9000" "nagare-backups"
"nagare-minio-credentials")` and asserts:

```haskell
-- cloud backend:
assertBool "cloud image"  ("google/cloud-sdk:slim"     `T.isInfixOf` y)
assertBool "metadata dns" ("metadata.google.internal"  `T.isInfixOf` y)
assertBool "metadata ip"  ("169.254.169.254"           `T.isInfixOf` y)
assertBool "gs url"       ("gs://"                      `T.isInfixOf` y)
-- local backend:
assertBool "minio image"  ("amazon/aws-cli"            `T.isInfixOf` y)
assertBool "s3 url"       ("s3://"                      `T.isInfixOf` y)
assertBool "endpoint"     ("--endpoint-url"            `T.isInfixOf` y)
assertBool "secret ref"   ("nagare-minio-credentials"  `T.isInfixOf` y)
assertBool "no metadata"  (not ("169.254.169.254"      `T.isInfixOf` y))
assertBool "no metadns"   (not ("metadata.google.internal" `T.isInfixOf` y))
```

Run with `cd cli/nagarectl && cabal test`. The existing cloud-only
`gcsJobHostAliasesTests`, the `backupRestoreTests`, and the EP-62 `backupProjectTests` must
stay green (they construct `GcsBackend` inputs, exercising the unchanged cloud path).


## Idempotence and Recovery

M1 is read-mostly: `db create`/`broker create` are idempotent at the apply level (re-running
re-applies the same manifests; an existing database errors cleanly rather than corrupting). To
reset, `nagarectl db delete pgdemo` / `kubectl delete statefulset,pvc -l nagare.dev/broker=demo`.

`just local-minio` is idempotent: `kubectl apply` reconciles, the bucket Job uses
`mc mb --ignore-existing`, and re-running re-waits on readiness. To reset MinIO entirely:
`kubectl delete -f cluster/local/minio/minio.yaml` then re-run `just local-minio` (the
`emptyDir` store is recreated empty).

M3 is additive and behind the mode switch: cloud mode is byte-for-byte unchanged, so the change
is safe to land before the local cluster exists — the cloud tests are the guardrail. If a local
backup Job fails (e.g. MinIO not yet up), the Job surfaces the failure (`restartPolicy: Never`,
`backoffLimit: 0`) and the driver prints its logs; re-run the verb after `just local-minio`
reports ready. No destructive operation runs on the laptop; the only state touched is in-cluster
MinIO and the managed database/volume the operator explicitly targets.

M4 restores default to a scratch target (`db restore` into `<db>_restore_scratch`,
`storage restore` into a `…-restore-scratch` PVC); the round-trip uses `--into live` /
`--into-live` deliberately to read the value back from the live target. To redo a round-trip,
re-write the sentinel and repeat; backups accumulate in MinIO under the stable key prefix and
are listed by the same code the cloud path uses.


## Interfaces and Dependencies

This plan adds no third-party Haskell dependency. It uses the in-cluster services
**MinIO** (S3 API) and the public client images `minio/minio`, `minio/mc`, and
`amazon/aws-cli`. It imports from EP-83's `cli/nagarectl/src/Nagare/Target.hs` the mode it
branches on; it must not re-read `NAGARE_MODE` itself.

At the end of **M1**, no new interface exists — the milestone is evidence that the existing
create paths run locally.

At the end of **M2**, `cluster/local/minio/minio.yaml` and the `just local-minio` recipe exist;
MinIO answers S3 at `http://minio.nagare-system.svc.cluster.local:9000` with bucket
`nagare-backups`, credentials in Secret `nagare-minio-credentials`.

At the end of **M3**, these must exist:

- In `cli/nagarectl/src/Nagare/Target.hs`:

```haskell
data TargetProfile = TargetProfile
  { -- … existing fields …
  , tpLocalObjectStore :: !Text  -- ^ NAGARE_LOCAL_OBJECT_STORE, default "" (local mode only)
  }
```

  and from EP-83 (imported, not defined here): `data Mode = Cloud | Local` and the field
  `tpMode :: Mode`.

- In `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs` (new exports):

```haskell
data StoreBackend = GcsBackend !Text !Text | MinioBackend !MinioRef
data MinioRef = MinioRef { mrEndpoint :: !Text, mrBucket :: !Text, mrSecretName :: !Text }

parseLocalObjectStore :: Text -> Maybe (Text, Text)
storeImage        :: StoreBackend -> Text
storeHostAliases  :: StoreBackend -> Maybe Value
storeEnv          :: StoreBackend -> [Value]
storeObjectUrl    :: StoreBackend -> Text -> Text
storePrefixUrl    :: StoreBackend -> Text -> Text
storeCpFromStdin  :: StoreBackend -> Text -> Text
storeCpToStdout   :: StoreBackend -> Text -> Text
storeLs           :: StoreBackend -> Text -> Text
storeRmStdin      :: StoreBackend -> Text

-- DataMovementJob gains:
data DataMovementJob = DataMovementJob
  { -- … existing fields …
  , dmjHostAliases :: !(Maybe Value)  -- ^ Just metadataHostAliases (GCS) | Nothing (MinIO)
  }
```

  The existing `metadataHostAliases`, `metadataEnv`, `gcsContainerImage`, and
  `dataMovementJobSpec` remain (the cloud path is built from them); `dataMovementJobSpec` reads
  `dmjHostAliases` and omits the `hostAliases` key when it is `Nothing`.

- In the four caller modules, each input record's `*Project :: Text` field is replaced by
  `*Backend :: StoreBackend`, and `renderDbBackupCronJob` / the four `run*` drivers take a
  `StoreBackend` where they previously took `bucket`/`project`. In
  `cli/nagarectl/app/Main.hs`:

```haskell
resolveStoreBackend :: Maybe String -> IO StoreBackend
-- resolves the profile once; GcsBackend (tpProject tp) <bucket> when tpMode tp == Cloud,
-- MinioBackend (MinioRef endpoint bucket "nagare-minio-credentials") when Local
-- (endpoint/bucket from parseLocalObjectStore (tpLocalObjectStore tp)).
```

At the end of **M4**, no new interface exists; the milestone is the round-trip behavior.


---

Revision note (2026-06-30): initial authored draft of EP-84 from the skeleton. Filled every
required section: Purpose, the milestone-granular Progress checklist (M1–M4), the seeded
Decision Log (MinIO over LocalStack/moto; one-module generalization; Secret-supplied local
credentials; `amazon/aws-cli` over `mc`; stable key layout; skip laptop-side local prune),
Context and Orientation (current `GcsJob` shape and the four callers, the EP-82/EP-83
prerequisites, the `NAGARE_LOCAL_OBJECT_STORE` form), the four-milestone Plan of Work, Concrete
Steps with commands and expected transcripts, the round-trip Validation/Acceptance and the
per-mode renderer tests, Idempotence and Recovery, and the Interfaces (the `StoreBackend`
abstraction's signatures and what it imports from `Nagare.Target`). Surprises & Discoveries and
Outcomes are left as placeholders per the spec. Commits implementing this plan use Conventional
Commit subjects (e.g. `feat(backup): render data-movement Job for the local MinIO backend`,
`feat(cluster): add local MinIO object store and just local-minio`,
`test(backup): assert data-movement Job differs by store backend`) and carry the trailers
`MasterPlan: docs/masterplans/16-local-development-and-testing-for-nagare.md`,
`ExecPlan: docs/plans/84-local-data-services-and-gcs-free-backups-and-snapshots-for-nagare.md`,
and `Intention: intention_01kwb012h6ebgs5qjn5r12nyda`.
