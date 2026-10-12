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

Full plan before trimming: [84-local-data-services-and-gcs-free-backups-and-snapshots-for-nagare.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/84-local-data-services-and-gcs-free-backups-and-snapshots-for-nagare.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M1.1 — On the EP-82 local cluster, `nagarectl db create postgres pgdemo` brought up the
      Postgres StatefulSet `pgdemo 1/1` (pod `Running`, PVC `nagare-db-pgdemo-data Bound` on
      `local-path`). The backup CronJob it applies rendered the local MinIO backend
      (`amazon/aws-cli`, `aws s3 … --endpoint-url`, `s3://`, `nagare-minio-credentials`, no
      metadata) — proving end-to-end local-mode wiring through `db create`. (Done 2026-06-29.)
- [x] M1.2 — `nagarectl db create redis rdemo` brought up `rdemo 1/1` (PVC `nagare-db-rdemo-data
      Bound`, 2Gi `local-path`). (Done 2026-06-29.)
- [x] M1.3 — `nagarectl broker create redpanda demo` brought up the broker StatefulSet `demo
      1/1`, ClusterIP Service `demo` (9092/9644), and PVC `nagare-broker-demo-data Bound` (5Gi
      `local-path`). (Done 2026-06-29.)
- [x] M1.4 — `nagarectl deploy -f cluster/examples/heartbeat-task/nagare/Config.hs --dry-run`
      rendered a native `kind: CronJob` (`schedule '*/15 * * * *'`, `concurrencyPolicy: Forbid`,
      `date -u`) referencing the local registry (`k3d-registry.localhost:5000/...`) — GCP-free.
      Applying that CronJob and `kubectl create job --from=cronjob/heartbeat heartbeat-manual`
      reached `Complete 1/1` (pod logged the UTC date). (Done 2026-06-29.)
- [x] M1.5 — `nagarectl deploy` of `cluster/examples/uploads-volume` created the Knative
      Service and its `local-path` PVC `nagare-vol-uploads-volume-uploads`, which deploy
      reported `Bound`. No GCP assumption surfaced. (Done 2026-06-29.)
- [x] M2.1 — Added `cluster/local/minio/minio.yaml` (Namespace `nagare-system` + Deployment +
      ClusterIP Service on 9000/9001 + the `nagare-minio-credentials` Secret + a one-shot
      `minio-make-bucket` Job creating `nagare-backups`). (Done 2026-06-29.)
- [x] M2.2 — Added the `just local-minio` recipe (`[group('local')]`, matching EP-82's local
      recipes) that applies the manifest, waits on `deploy/minio` rollout, and waits for the
      bucket Job to complete; it references but does not duplicate `just local-bootstrap`. (Done 2026-06-29.)
- [x] M2.3 — `just local-minio` brought MinIO up (`deploy/minio 1/1`, `job/minio-make-bucket
      Complete`); an in-cluster `amazon/aws-cli` probe pod ran
      `aws s3 ls s3://nagare-backups --endpoint-url http://minio:9000` and exited 0. (Done 2026-06-29.)
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
- [x] M4.1 — End-to-end DB round-trip on the local cluster: wrote `sentinel('hello-local')`
      into `pgdemo`, `db backup pgdemo` → `s3://nagare-backups/databases/pgdemo/20260630T043501Z.sql.gz`
      (550 bytes, in MinIO), dropped the table, `db restore pgdemo 20260630T043501Z --into-live`,
      `SELECT v FROM sentinel` returned `hello-local`. No GCS, no metadata server (the rendered
      Job uses `amazon/aws-cli` + `aws s3 … --endpoint-url` + `secretKeyRef
      nagare-minio-credentials`, no `169.254.169.254`/`metadata.google.internal`). (Done 2026-06-29.)
- [x] M4.2 — End-to-end volume round-trip: wrote `hello-volume` to `/uploads/sentinel.txt`,
      `storage snapshot uploads-volume uploads` →
      `s3://nagare-backups/volumes/uploads-volume/uploads/20260630T043902Z.tar.gz`, deleted the
      file, `storage restore uploads-volume uploads 20260630T043902Z --into-live` (Job listed
      `/restore/sentinel.txt`), `cat /uploads/sentinel.txt` returned `hello-volume`. (Done 2026-06-29.)
- [x] M4.3 — Confirmed cloud bytes unchanged: with `NAGARE_MODE` unset, `db backup pgdemo
      --dry-run` renders only the GCS shape (`google/cloud-sdk:slim`, `169.254.169.254`,
      `metadata.google.internal`, `gs://tan-nb-exp-nagare-backups/...`, `gsutil`) and zero MinIO
      markers (no `amazon/aws-cli`, `s3://`, `--endpoint-url`, or `dnf install`). The
      `gcsJobHostAliasesTests`/`backupProjectTests`/`backupRestoreTests` stay green as the
      machine-checkable guardrail. (Done 2026-06-29.)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`amazon/aws-cli:latest` ships neither `tar` nor `gzip` (M3/M4 → fix landed).** The plan's
  Decision Log assumed "the image's Amazon Linux base ships tar and gzip"; on 2026-06-29 a
  probe (`command -v gzip tar` in both `amazon/aws-cli:latest` and `minio/mc:latest`) found
  __both images ship neither__. The first live `db backup` therefore wrote a **0-byte** object:
  `gzip -9 -c … | aws s3 cp -` failed on the missing `gzip` (no `pipefail`, so the Job still
  "succeeded") and streamed empty stdin. Because the volume snapshot/restore Jobs are
  single-container (they co-mount the PVC and must `tar` in the same container as the S3
  client), the work cannot be offloaded to the engine container — so the fix is a
  `storeShellPreamble` that runs `dnf install -y -q tar gzip` (the image has `dnf`) before the
  transfer, in local mode only; cloud shells get an empty preamble and stay byte-for-byte
  identical. The install adds ~12 s per local Job and needs a package mirror (the Job already
  pulls its image over the network, so no new offline assumption). After the fix the same
  backup wrote a 550-byte object and the M4.1 round-trip returned `hello-local`. EP-86's smoke
  test inherits this (its first local backup pays the one-time install). Date: 2026-06-29.

- **The MinIO credentials Secret is namespace-local, but the data-movement Job runs in the
  app/db namespace (M4 → manifest fix).** The Job's `secretKeyRef` to `nagare-minio-credentials`
  resolves in the Job's __own__ namespace (`personal` by default), not `nagare-system` where
  MinIO lives — the first live backup hit `CreateContainerConfigError` because the Secret was
  absent from `personal`. Fix: `cluster/local/minio/minio.yaml` now seeds
  `nagare-minio-credentials` into both `nagare-system` (for MinIO itself) and `personal` (the
  default app/db namespace), and `just local-minio` ensures `personal` exists first. Apps or
  databases created in a non-default namespace need the Secret copied there too — a documented
  prerequisite (EP-86's runbook should note it), analogous to EP-82's insecure-registry
  prerequisite. Date: 2026-06-29.

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
  - **Correction (2026-06-29):** `amazon/aws-cli:latest` ships __neither__ `tar` nor `gzip`
    (and `minio/mc:latest` doesn't either — the recorded `mc` fallback would not have helped).
    The image is kept (`aws s3` against `--endpoint-url` is still the right client), but the
    snapshot/backup/restore shells now run a `storeShellPreamble` (`dnf install -y -q tar gzip`)
    in local mode before the transfer; the volume Job is single-container, so offloading the
    `tar`/`gzip` to the engine container is not possible. See Surprises & Discoveries for the
    0-byte-backup evidence that surfaced this.

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

**Outcome — the purpose is met.** An operator in local mode (`NAGARE_MODE=local`) can now
exercise nagare's whole data plane on a laptop with no GCP account: managed Postgres/Redis
(M1.1/M1.2), the Redpanda broker (M1.3), a scheduled-task CronJob (M1.4), and a `local-path`
volume app (M1.5) all came up `Ready`/`Bound`/`Complete` on the EP-82 k3d cluster; an in-cluster
MinIO object store (M2) stands in for GCS; and both data round-trips proved end-to-end with no
GCS and no metadata server — `db backup`/`db restore --into-live` returned `hello-local` (M4.1)
and `storage snapshot`/`storage restore --into-live` returned `hello-volume` (M4.2). With
`NAGARE_MODE` unset the rendered Jobs are byte-for-byte the GCS shape (M4.3), so there is no
cloud regression.

**The single code-behavior change held to one rendering point.** As designed (MasterPlan 16
Integration Point 3), the cloud-vs-local decision is a `StoreBackend` value constructed once
(`Nagare.Target.storeBackendFor`) and threaded as data through the one shared
`Nagare.Cluster.GcsJob` module that all four verbs render through. Cloud invariance is locked by
the pre-existing cloud tests staying green; both modes are exercised by `storeBackendModeTests`.

**Two assumptions in the authored plan were wrong and are corrected (see Surprises):** (1) the
data-movement client image ships `tar`/`gzip` — it does not (neither `amazon/aws-cli` nor
`minio/mc`), so a `storeShellPreamble` installs them in local mode (cloud unchanged); (2) the
credentials Secret is reachable by the Job — `secretKeyRef` is namespace-local, so the manifest
now seeds `nagare-minio-credentials` into the app/db namespace (`personal`) as well as
`nagare-system`.

**Gaps / follow-ups (out of this plan's acceptance):** the in-pod self-prune for MinIO is
rendered (basename list + re-qualified delete) and unit-reasoned but not live-exercised (the M4
round-trip does not depend on prune, per the Decision Log); the MinIO store uses an `emptyDir`
(disposable) — a durable local store is a one-line swap to a `local-path` PVC; and apps/databases
in a non-default namespace need `nagare-minio-credentials` copied there — a documented
prerequisite EP-86's runbook should surface. The ~12 s per-Job `dnf install` of `tar`/`gzip` is
an accepted cost for a local test harness (EP-86's first smoke backup pays it once).

