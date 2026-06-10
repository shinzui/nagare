---
id: 36
slug: app-volume-backup-ownership-snapshot-to-gcs-and-retention
title: "App volume backup ownership snapshot to GCS and retention"
kind: exec-plan
created_at: 2026-06-10T00:44:35Z
intention: "intention_01ktqfjpdqewga3t0rm9crehxx"
master_plan: "docs/masterplans/7-persistent-storage-for-nagare.md"
---

# App volume backup ownership snapshot to GCS and retention

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a Nagare app can declare a durable disk (a "volume") and `nagarectl deploy` provisions it,
but that disk has **no place in the backup story**. If the data disk is lost, the volume's contents
are gone, and nothing warns the operator that a volume is unprotected. This ExecPlan closes that gap
and makes app volumes a first-class part of the same GCS backup flow the Postgres and SQLite data
already use.

After this change, an operator can do three concrete, observable things:

1. **Take a point-in-time snapshot of a live app volume into GCS.** Running
   `nagarectl storage snapshot myapp data` packages the entire contents of the volume named `data`
   on the app `myapp` into a gzip-compressed tar archive and uploads it to
   `gs://tan-nb-exp-nagare-backups/volumes/myapp/data/<timestamp>.tar.gz`. They can then confirm it
   with `gsutil ls gs://tan-nb-exp-nagare-backups/volumes/myapp/data/` and see the object appear.

2. **Be warned at deploy time about any volume that is not backed up.** Every declared volume is, by
   an explicit policy, either *backup-included* (the default — `storage snapshot` and, optionally, a
   scheduled snapshot cover it) or *backup-excluded* (the developer opts out for throwaway data like
   a cache). When a config declares a backup-excluded volume, `nagarectl deploy` prints a clear
   warning naming it, e.g. `warning: volume 'cache' on app 'myapp' is NOT backed up (backup excluded
   in config)`. No volume is ever silently unprotected.

3. **Restore a volume snapshot back into a disposable disk and verify it, then promote.** The
   disaster-recovery runbook gains an "app volumes" row and a step-by-step restore procedure that,
   exactly like the existing `scripts/restore-sqlite.sh` and `scripts/restore-postgres.sh`, restores
   into a **scratch** PVC first and never clobbers a live volume.

Old snapshots are pruned so the bucket does not grow without bound (retention). The mechanism reuses
the existing GCS backup bucket, the existing `tan-nb-exp` project-isolation conventions, and the
existing `kubectl` shell-out plumbing, so it adds one coherent capability without inventing new
infrastructure.

A note on terms used throughout, defined here so the rest of the plan needs no outside knowledge:

- **Volume**: a durable disk attached to an app, declared in the typed config. EP-34 (see below)
  defines the `Volume` record with a name, size, mount path, access mode, read-only flag, and a
  `RetentionPolicy`.
- **PVC (PersistentVolumeClaim)**: the Kubernetes object that represents a volume's request for a
  disk. On this single-node k3s cluster the built-in **`local-path`** StorageClass satisfies a PVC
  by carving a host directory under `/var/lib/nagare/local-path/<pvc>` and mounting it into the pod.
- **Snapshot**: a point-in-time copy of a volume's *file contents* (not a block-level disk image),
  produced by `tar`-ing the mounted directory and uploading the archive to GCS.
- **ADC (Application Default Credentials)**: the keyless auth Google client libraries use. On this VM
  it resolves to the node's attached service account, which Pulumi grants
  `roles/storage.objectAdmin` on the backup bucket (`infra/pulumi/src/components/NagarePerimeter.ts`
  lines 88–91). No key files are involved.


## Progress

Milestone 1 — `storage snapshot` writes a verified tar.gz to GCS, plus retention pruning:

- [x] Add the `Nagare.Storage.Snapshot` module to `cli/nagarectl/nagarectl.cabal` `exposed-modules`. (2026-06-09)
- [x] Implement the pure GCS object-path helper `snapshotObjectPath` and the timestamp formatter. (2026-06-09; + `snapshotGsUrl`, `snapshotTimestamp`.)
- [x] Implement the pure retention-pruning selector `snapshotsToPrune` (keep-last-N). (2026-06-09)
- [x] Implement the snapshot Job manifest renderer `renderSnapshotJob`. (2026-06-09; `batch/v1` Job, RO PVC co-mount, `google/cloud-sdk:slim`, ADC via metadata IP, project pinned, `tar | gsutil cp -`.)
- [x] Wire `runSnapshot` (apply Job, wait for completion, prune) into the CLI. (2026-06-09; in `Nagare.Storage.Snapshot`, dispatched from Main.)
- [x] Add the `snapshot` subcommand to the `storage` subparser in `cli/nagarectl/app/Main.hs`. (2026-06-09; `StorageSnapshot` + `--bucket`/`--keep`; extends EP-35's subparser, IP5.)
- [x] Add pure tests for `snapshotObjectPath` and `snapshotsToPrune` to `cli/nagarectl/test/Spec.hs`. (2026-06-09; new `Nagare.Storage.Snapshot` group — 118 tests pass.)
- [ ] Validate end to end: `nagarectl storage snapshot myapp data` then `gsutil ls` shows the object. (Deferred to EP-37 — needs a deployed app + cluster API access; IAP forwards only SSH/22. See Surprises.)

Milestone 2 — backup-ownership policy + runbook + tested restore:

- [x] Implement the pure `backupExcludedWarnings` check over a loaded config's volumes. (2026-06-09; `Delete` ⇒ excluded.)
- [x] Emit the warnings from `runDeploy` in `cli/nagarectl/app/Main.hs`. (2026-06-09; stderr, both dry-run and live — verified via the real CLI on a `Delete`-volume config.)
- [x] Add the `scripts/restore-volume.sh` scratch-first restore script. (2026-06-09; `bash -n` clean, `chmod +x`, scratch PVC + restore Job, never touches the live PVC.)
- [x] Add the "app volumes" row + restore procedure to `docs/runbooks/disaster-recovery.md`. (2026-06-09; inventory row + step-7 sub-step + hot-DB caveat.)
- [x] Add the "app volumes" row to `docs/user/backups-and-disaster-recovery.md`. (2026-06-09; row + include/exclude policy section.)
- [x] Add a pure test for `backupExcludedWarnings` to `cli/nagarectl/test/Spec.hs`. (2026-06-09)
- [ ] Validate end to end: restore a snapshot into a disposable PVC and compare contents. (Deferred to EP-37 — needs cluster API access; same IAP constraint.)


## Surprises & Discoveries

- **EP-34's `attachVolume` only produces `Retain` volumes — there is no preset for a backup-excluded
  (`Delete`) volume.** To mark a volume backup-excluded today a config must build a `Volume` record
  literal directly (the `Volume(..)` constructor and `mkVolumeName`/`mkQuantity`/`mkMountPath` are
  exported), e.g. `pure base { volumes = [Volume { … retention = Delete }] }`. This works (verified
  via the real CLI — the deploy-time warning fired for such a config) but is clunky. **Follow-up for
  EP-34/EP-37:** consider an `attachVolumeExcluded` (or an `attachVolumeWith` taking a
  `RetentionPolicy`) preset so opting out is ergonomic; the docs example in EP-37 should show the
  literal form until then.

- **`StdoutUntrimmed` is `Text`, `StdoutRaw` is `ByteString`.** `pruneSnapshots` captures the
  `gsutil ls` output as `StdoutUntrimmed` (already `Text`, no decode); `Nagare.Storage.Discover`
  captures `kubectl get … -o json` as `StdoutRaw` for `aeson`. Mixing them up is a type error.

- **Snapshot resolves the PVC name deterministically (`pvcName`), like `storage inspect`.** Rather
  than querying the cluster to map `VOLUME → claimName`, `runSnapshot` loads the config
  (`resolveStorageDep`), verifies the volume is declared, and computes `pvcName app volume` — the same
  approach EP-35's `inspect` uses. The PVC must exist on the cluster (the deploy created it); if it
  doesn't, the Job fails to schedule and `kubectl wait` surfaces it.

- **`renderSnapshotJob` builds the Job via `Data.Yaml.encode` of an aeson `Value`,** not a text
  template — this quotes the `tar … | gsutil cp -` shell pipeline as a proper YAML string scalar with
  no indentation/escaping pitfalls. No golden test is needed (the Job is applied, not compared to a
  cluster contract); the pure path/prune/warning logic is what the suite covers.

- **The live snapshot/restore transcripts are deferred to EP-37 (same IAP constraint as EP-35).** A
  workstation `kubectl`/`gsutil` against `nagare-01` can't reach the k3s API (IAP forwards only
  SSH/22), and a real snapshot needs a *deployed* volume app. The pure logic (path, prune, warnings)
  is unit-tested; the deploy-time warning and the restore script's `bash -n` are verified locally;
  the on-cluster `storage snapshot … → gsutil ls` and the restore drill belong to EP-37's end-to-end
  examples (run `nagarectl` on the VM or SSH-forward 6443, per EP-35's Surprises).


## Decision Log

- Decision: Snapshot a volume by `tar`-ing its file contents and streaming the archive to GCS,
  rather than using a CSI/block-level disk snapshot.
  Rationale: the `local-path` provisioner satisfies PVCs with a plain host directory and has **no CSI
  volume-snapshot driver**, so block snapshots are not available. The MasterPlan fixes this approach
  in its scope: "CSI volume snapshots … this initiative snapshots by copying file contents to GCS,
  because the `local-path` provisioner has no CSI snapshot support"
  (`docs/masterplans/7-persistent-storage-for-nagare.md`, Vision & Scope). A file-level tar to GCS
  reuses the exact bucket and ADC conventions the Postgres/SQLite backups already use.
  Date: 2026-06-09

- Decision: Run the snapshot inside a short-lived in-cluster Kubernetes **Job** that mounts the PVC
  by `claimName`, rather than via `kubectl exec` into the app pod or a host-side script on the VM.
  Rationale: a Nagare app is a Knative Service whose pod **scales to zero** when idle and whose pod
  name/identity is not stable, so `kubectl exec … tar` into the app container is unreliable — there
  may be no pod to exec into. A host-side `tar` of `/var/lib/nagare/local-path/<pvc>` would work on
  this single node but couples the CLI to SSH/host access, whereas `nagarectl` already talks to the
  *cluster* (it shells out to `kubectl`), not the host. A dedicated Job that mounts the same PVC by
  `claimName` is portable, needs only `kubectl`, and runs whether or not the app pod is up. EP-33
  established that on this single node a `ReadWriteOnce` `local-path` PVC can be co-mounted on the
  same node, so the Job can mount the PVC while the app keeps running (see the consistency caveat
  below).
  Date: 2026-06-09

- Decision: GCS object layout is
  `gs://tan-nb-exp-nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz`, in the **existing**
  backup bucket, with the timestamp formatted exactly like `scripts/backup-postgres.sh`
  (`date -u +%Y%m%dT%H%M%SZ`, e.g. `20260609T141503Z`).
  Rationale: this is the contract MasterPlan Integration Point IP4 fixes
  (`docs/masterplans/7-persistent-storage-for-nagare.md`). Reusing the existing bucket means the
  node service account already has write access and `forceDestroy:false` already protects it. A
  per-`<app>/<volume>` prefix keeps each volume's snapshots independently listable, prunable, and
  lifecycle-able. The shared timestamp format keeps every backup class sortable the same way.
  Date: 2026-06-09

- Decision: Volumes are **backup-included by default**; a developer must explicitly opt a volume out,
  and `nagarectl deploy` warns for each excluded volume.
  Rationale: the roadmap's headline deliverable is that "app volumes should either be included in the
  existing GCS backup flow or explicitly excluded with a warning." Defaulting to *included* is the
  safe default (no volume is silently unprotected); making exclusion explicit and loud at deploy
  time satisfies the "with a warning" half. The warning lives at deploy time because that is the one
  command every app run passes through.
  Date: 2026-06-09

- Decision: Express backup exclusion by **reusing EP-34's `RetentionPolicy = Retain | Delete`** field
  as the exclusion signal: a volume whose `RetentionPolicy` is `Delete` is treated as backup-excluded
  (throwaway data), and `Retain` means backup-included. No new config field is added in this plan.
  Rationale: keeping the policy SIMPLE and avoiding a config-schema change (which would belong to
  EP-34, the owner of the typed model — IP1). `Delete` already means "this disk is disposable when
  the app is removed," which lines up with "don't bother backing it up." This is recorded explicitly
  because `RetentionPolicy` *also* governs whether the PVC disk is deleted on app deletion — a
  *different* concern — so the plan documents the overload clearly to avoid confusion. If a future
  need arises for an independent `backup :: Bool` field, that is an EP-34 change; this plan notes it
  as a possible follow-up but does not require it.
  Date: 2026-06-09

- Decision: Snapshot **retention** prunes old snapshots by keeping the last N (default 7) per
  `<app>/<volume>` prefix, implemented in `nagarectl` after each successful snapshot. This is
  **distinct** from the PVC `RetentionPolicy`.
  Rationale: snapshot retention answers "how many historical archives do we keep in GCS," which is
  unrelated to whether the live disk is deleted on app removal (`RetentionPolicy`). Implementing the
  prune in `nagarectl` (rather than a GCS lifecycle rule) keeps the policy visible, testable as pure
  logic, and per-volume; a GCS Object Lifecycle rule on the `volumes/` prefix is documented as an
  optional belt-and-suspenders alternative but not required for the core. Keeping the two retentions
  named differently in code and docs prevents the overload from confusing operators.
  Date: 2026-06-09

- Decision: Reuse `scripts/`' project-isolation preflight assertion and ADC auth conventions verbatim
  in any new shell script, and target only `tan-nb-exp`.
  Rationale: the repository `CLAUDE.md` mandates it; `scripts/backup-postgres.sh` and
  `scripts/restore-*.sh` already encode the exact preflight pattern, so the new
  `scripts/restore-volume.sh` mirrors them line-for-line.
  Date: 2026-06-09

- Decision: A scheduled-snapshot Kubernetes **CronJob** is out of core scope; the core deliverable is
  the manual `storage snapshot` command plus retention pruning.
  Rationale: keeps M1 small and verifiable. The CronJob is a thin wrapper around the same Job
  manifest and is noted as a stretch/Phase-5 task-model item, not built here, so the plan does not
  grow a scheduling subsystem.
  Date: 2026-06-09

- Decision: Snapshot of a *hot* (actively-written) SQLite database is documented as potentially
  inconsistent; the recommendation is to quiesce the app or use the Litestream continuous-replication
  pattern for hot DBs.
  Rationale: a file-level tar of a database mid-write can capture a torn page. The
  `cluster/examples/sqlite-litestream/` example is the continuous, point-in-time-recoverable
  complement; `storage snapshot` is the point-in-time, whole-volume complement for data that is not
  being mutated during the snapshot (uploaded files, generated assets, a stopped app's DB). This
  caveat is stated in the user docs and runbook.
  Date: 2026-06-09


## Outcomes & Retrospective

**Result: both milestones implemented; build clean; all 118 `nagarectl` tests pass (incl. the new
`Nagare.Storage.Snapshot` group). Pure logic + the deploy-time warning + the restore script verified
locally; the live snapshot/restore transcripts are deferred to EP-37 (IAP/cluster-access constraint).**

- **M1 — `storage snapshot` (IP4).** `nagarectl storage snapshot APP VOLUME [--bucket B] [--keep N]`
  resolves the PVC deterministically, renders and applies a short-lived `batch/v1` Job that
  co-mounts the PVC read-only and streams `tar … | gsutil cp -` to
  `gs://<bucket>/volumes/<app>/<volume>/<ts>.tar.gz`, waits for completion (surfacing logs on
  failure), deletes the Job, and prunes to the newest N. Pure helpers (`snapshotObjectPath`,
  `snapshotGsUrl`, `snapshotTimestamp`, `snapshotsToPrune`) are unit-tested. The snapshot command
  extends EP-35's `storage` subparser (IP5) — it did not fork it.

- **M2 — backup-ownership + restore.** `backupExcludedWarnings` (a volume is excluded iff
  `retention = Delete`) is emitted to stderr from `runDeploy` in both dry-run and live deploys
  (verified through the real CLI). `scripts/restore-volume.sh` restores a snapshot into a *scratch*
  PVC via a one-off Job and prints the restored tree for comparison, never touching the live volume
  (mirrors `restore-sqlite.sh`/`restore-postgres.sh`). The disaster-recovery runbook and the user
  backup guide gained app-volume rows, a restore sub-step, and the hot-DB consistency caveat.

- **Decisions honored / deviations.** The `RetentionPolicy` overload (`Delete` = both "disposable
  disk" and "backup-excluded") is implemented as decided; snapshot retention (keep-last-N in
  `nagarectl`) is kept distinct from the PVC retention policy. Deviation: `runSnapshot`/`storage`
  commands take the resolved `Deployment` (not the plan's `(Text, FilePath, …)` signatures) for the
  same reason EP-35 did — the declared volume set is needed. Follow-up surfaced: EP-34 lacks an
  ergonomic preset for a `Delete` (excluded) volume (see Surprises) — noted for EP-37/EP-34.

- **Gaps.** Live `storage snapshot … → gsutil ls` and the restore drill are deferred to EP-37's
  on-cluster examples (IAP forwards only SSH/22; a real snapshot needs a deployed volume app). The
  snapshot/restore Job manifests, `runSnapshot` IO, `pruneSnapshots`, and the restore script's Job
  body are not unit-tested (they shell to `kubectl`/`gsutil`), matching the repo convention that
  cluster IO is exercised by `--dry-run`/by hand. A scheduled-snapshot CronJob remains out of scope
  (Decision Log).


## Context and Orientation

This plan extends an existing, working backup story and an existing storage CLI. Read this section
as if you know nothing about the repository; every file is named by full path.

**The existing backup flow you are mirroring.** The repository already backs up two data classes to
one GCS bucket:

- `scripts/backup-postgres.sh` dumps Postgres and uploads to
  `gs://${BUCKET}/postgres/<timestamp>.sql.gz`. Its first 14 lines are the *project-isolation
  preflight* the repository `CLAUDE.md` requires — it refuses to run unless the active gcloud project
  is `tan-nb-exp`:

  ```bash
  PROJECT=tan-nb-exp
  ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
    echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
    exit 1
  fi
  ```

  The script then uses the timestamp `STAMP="$(date -u +%Y%m%dT%H%M%SZ)"` and uploads with
  `gsutil cp` (lines 18, 24–25). Auth is ambient ADC (the VM's service account); there are no key
  files.

- `scripts/restore-postgres.sh` and `scripts/restore-sqlite.sh` restore **into a scratch target,
  never over live data** — the postgres one restores into `notes_restore_scratch` and prints a row
  count to compare (lines 13, 16–20); the sqlite one restores into `/tmp/restore-app.db`
  (line 12). Both begin with the identical preflight block. Your new restore script copies this
  scratch-first shape exactly.

**The bucket.** The bucket name is `tan-nb-exp-nagare-backups`. It is created in
`infra/pulumi/src/components/NagarePerimeter.ts` (line 79, `new gcp.storage.Bucket(...)`) from the
Pulumi naming `${gcpProject}-nagare-backups` (`infra/pulumi/index.ts` line 22). It has
`forceDestroy: false` (line 83) so a careless `pulumi destroy` cannot wipe it, and the VM service
account is granted `roles/storage.objectAdmin` on it (lines 88–91). The Pulumi stack output is
`backupBucket` (`infra/pulumi/index.ts` line 53), retrieved at runtime with
`pulumi stack output backupBucket`.

**The Litestream example (the continuous complement).** `cluster/examples/sqlite-litestream/`
replicates a SQLite WAL to `gcs://tan-nb-exp-nagare-backups/litestream/app.db` continuously
(`litestream.yml` line 9). Its `deployment.yaml` shows a crucial cluster fact you must reproduce in
the snapshot Job: pods on this node **cannot resolve `metadata.google.internal` by name**, so any
Google client using ADC (here Litestream, in your case `gsutil`) must be pointed at the metadata IP
directly. The example sets `GCE_METADATA_HOST=169.254.169.254` (lines 48–49). Your Job uses the
equivalent variable for the gcloud/gsutil toolchain (see the Job manifest in Plan of Work). The
Litestream pattern is the *continuous* backup for hot databases; your `storage snapshot` is the
*point-in-time* whole-volume complement.

**The runbook and user docs you extend.** `docs/runbooks/disaster-recovery.md` has a "Backup
inventory" code block (lines 21–37) mapping each data class to its restore script, and step 7
"Restore data" (lines 147–161) that runs the restore scripts. `docs/user/backups-and-disaster-recovery.md`
has a "What to back up" table (lines 21–32). You add an **app-volumes** entry to each, plus a restore
procedure in the runbook. EP-37 (`docs/plans/37-persistent-storage-docs-and-end-to-end-examples.md`)
references these documents, so keep them accurate.

**The CLI you extend.** `cli/nagarectl/app/Main.hs` is the `nagarectl` entry point. It uses
`optparse-applicative` `subparser`s; the `storage` subparser is introduced by **EP-35**
(`docs/plans/35-deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands.md`)
following the `site` subparser pattern visible at lines 271–277 of the current Main.hs. You add
`command "snapshot" snapshotCmd` to that subparser (Integration Point IP5: *extend, do not fork*).
Library modules live under `cli/nagarectl/src/`; the cabal file
(`cli/nagarectl/nagarectl.cabal`) lists `exposed-modules` (lines 33–45). You add a new module
`Nagare.Storage.Snapshot` there.

**The kubectl / process conventions.** `cli/nagarectl/src/Nagare/Deploy.hs` shows the house pattern
for shelling out: it imports `Cradle` and builds commands as `cmd "kubectl" & addArgs [...]`, then
runs them with `run_` (lines 39, 45–54). `applyManifests` writes a manifest to a temp file and runs
`kubectl apply -f <file>` (lines 33–39). You reuse exactly this style: write the snapshot Job
manifest to a temp file, `kubectl apply -f`, `kubectl wait` for the Job to complete, then read its
logs / prune.

**The types and helpers you consume (from EP-34 and EP-35).** These two plans are checked in but, at
the time this plan was authored, are still skeletons; their *contracts* are fixed by the MasterPlan's
Integration Points, which you must treat as the source of truth:

- From **EP-34** (IP1, `docs/masterplans/7-persistent-storage-for-nagare.md`): the `Volume` record
  in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` with fields `volName :: VolumeName`,
  `size :: Quantity`, `mountPath :: MountPath`, `accessMode :: AccessMode`, `readOnly :: Bool`, and
  `retention :: RetentionPolicy`, where `RetentionPolicy = Retain | Delete`. Accessors named
  `volumeNameText`, `mountPathText`, etc., are exported. `Deployment` and `ServerSite` gain a
  `volumes` field (a list of `Volume`), defaulting to empty.
- From **EP-34** (IP3): PVCs are named deterministically as `nagare-vol-<app>-<volume>` and labelled
  with `nagare.dev/managed-by: nagarectl` plus a per-volume label that joins a PVC back to its app
  and volume name. EP-36 must discover PVCs **by these labels**, never re-derive names by hand.
- From **EP-35** (IP5): a PVC-discovery helper module under `cli/nagarectl/src/Nagare/Storage/`
  (called `Nagare.Storage.Discover` in this plan) that resolves an `APP`+`VOLUME` to the concrete
  PVC name (and its labels/size) by querying `kubectl get pvc -l <label>`. You reuse it to turn the
  `snapshot APP VOLUME` arguments into a `claimName` for the Job.

Because EP-34 and EP-35 are hard dependencies, this plan assumes their types and helpers exist when
M1 implementation begins. If, when you start, those modules are not yet present, implement the small
piece you need (e.g. a minimal `discoverVolume :: Text -> Text -> IO (Either Text PvcRef)` that runs
`kubectl get pvc -l nagare.dev/app=<app>,nagare.dev/volume=<volume> -o name`) in `Nagare.Storage.Snapshot`
and leave a `-- TODO(EP-35): replace with Nagare.Storage.Discover` note, recording the deviation in
the Decision Log.


## Plan of Work

The work is two milestones. M1 delivers the `storage snapshot` command (with the in-cluster Job
mechanism) and snapshot retention pruning. M2 delivers the backup-ownership deploy-time warning, the
runbook/user-doc updates, and a tested restore. Each milestone is independently verifiable.

### Milestone 1 — `nagarectl storage snapshot APP VOLUME` to GCS, with retention

**Scope and outcome.** At the end of M1, running `nagarectl storage snapshot myapp data` resolves the
volume `data` on app `myapp` to its PVC, launches a short-lived Kubernetes Job that mounts that PVC,
tars its contents, gzips them, and uploads the archive to
`gs://tan-nb-exp-nagare-backups/volumes/myapp/data/<timestamp>.tar.gz`; then prunes older snapshots
for that volume down to the last N. A novice can verify the new object with `gsutil ls`. The pure
path-construction and pruning logic is unit-tested.

**New module `cli/nagarectl/src/Nagare/Storage/Snapshot.hs`.** Register it in
`cli/nagarectl/nagarectl.cabal` under `library` `exposed-modules` (add the line
`    Nagare.Storage.Snapshot` after the other `Nagare.*` entries, lines 33–45). The module owns:

- The pure GCS object-path helper. The signature is
  `snapshotObjectPath :: Text -> Text -> Text -> Text` taking `app`, `volume`, and a formatted
  `timestamp` and returning the object **path within the bucket**, i.e.
  `"volumes/" <> app <> "/" <> volume <> "/" <> timestamp <> ".tar.gz"`. A companion
  `snapshotGsUrl :: Text -> Text -> Text -> Text -> Text` prepends `"gs://" <> bucket <> "/"`. Keep
  the bucket out of the path helper so the path is trivially testable without a bucket name.

- The pure timestamp formatter `snapshotTimestamp :: UTCTime -> Text` producing the
  `YYYYMMDDTHHMMSSZ` form (e.g. `20260609T141503Z`) — the same shape `scripts/backup-postgres.sh`
  produces with `date -u +%Y%m%dT%H%M%SZ`. Use `Data.Time.Format.formatTime defaultTimeLocale
  "%Y%m%dT%H%M%SZ"` (the `time` package is already a dependency, cabal line 62).

- The pure retention selector
  `snapshotsToPrune :: Int -> [Text] -> [Text]` taking the keep-count `n` and the list of existing
  object paths (or basenames) for one `<app>/<volume>` prefix, returning the subset to delete:
  sort the names descending (they sort lexicographically because the timestamp is zero-padded and
  fixed-width), keep the first `n`, return the rest. This is the keep-last-N policy; it is pure and
  directly unit-testable.

- The Job manifest renderer
  `renderSnapshotJob :: SnapshotJobInputs -> ByteString` where
  `SnapshotJobInputs` carries the namespace, a unique Job name (e.g.
  `nagare-snapshot-<app>-<volume>-<timestamp>` lowercased and DNS-safe), the PVC `claimName`, the
  destination `gs://…` URL, and the mount path inside the Job (e.g. `/vol`). It produces a `batch/v1`
  Job that:
  - mounts the PVC read-only at `/vol` by `claimName`;
  - runs a small image that has `tar`, `gzip`, and `gsutil`/`gcloud` available (use
    `google/cloud-sdk:slim`, which ships `gsutil` and a busybox-style shell);
  - sets `GCE_METADATA_HOST=169.254.169.254` and the gcloud equivalent so ADC resolves the node
    service account (mirroring `cluster/examples/sqlite-litestream/deployment.yaml` lines 48–49);
  - runs `tar -C /vol -czf - . | gsutil -o GSUtil:parallel_composite_upload_threshold=150M cp - <gsUrl>`
    so the archive is streamed straight to GCS with **no large temp file**;
  - has `restartPolicy: Never` and `backoffLimit: 0` so a failure surfaces rather than looping;
  - carries the `nagare.dev/managed-by: nagarectl` label.

  The Job mounts the PVC by `claimName`, which on this single node co-mounts the same `local-path`
  `ReadWriteOnce` PVC the app uses. EP-33 established that single-node RWO co-mount is permitted
  (`docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md`); the Job and the app
  schedule onto the same node so the `ReadWriteOnce` constraint is satisfied. The Job mounts
  **read-only** to avoid any chance of corrupting live data.

**The Job's shell body, made concrete.** The container command is, in YAML:

```yaml
command: ["/bin/sh", "-c"]
args:
  - >
    set -e;
    tar -C /vol -czf - . |
    gsutil -o GSUtil:parallel_composite_upload_threshold=150M cp - "${DEST}"
env:
  - { name: DEST, value: "gs://tan-nb-exp-nagare-backups/volumes/myapp/data/20260609T141503Z.tar.gz" }
  - { name: GCE_METADATA_HOST, value: "169.254.169.254" }
  - { name: CLOUDSDK_CORE_PROJECT, value: "tan-nb-exp" }
```

Setting `CLOUDSDK_CORE_PROJECT=tan-nb-exp` in the Job is the in-cluster analogue of the shell
preflight: every gsutil call the Job makes targets `tan-nb-exp` only.

**The IO driver `runSnapshot`.** Also in `Nagare.Storage.Snapshot` (or a thin wrapper in Main.hs),
add `runSnapshot :: SnapshotOpts -> IO ()` that:
1. resolves the bucket name (from `--bucket`, then `NAGARE_BACKUP_BUCKET`, defaulting to
   `tan-nb-exp-nagare-backups`);
2. resolves `APP`+`VOLUME` → PVC `claimName` via `Nagare.Storage.Discover` (EP-35), dying with a
   clear message if the volume is unknown;
3. computes the timestamp and `gsUrl` from the pure helpers;
4. renders the Job, applies it with the `Nagare.Deploy.applyManifests`-style temp-file +
   `kubectl apply -f` pattern, and `kubectl wait --for=condition=complete --timeout=600s job/<name>
   -n <ns>` (mirroring `Nagare.Deploy.waitForReady`);
5. on success, deletes the completed Job (`kubectl delete job/<name> -n <ns>`), then lists existing
   objects under the prefix with `gsutil ls`, computes `snapshotsToPrune 7`, and deletes the surplus
   with `gsutil rm`;
6. prints `Snapshot written: <gsUrl>`.

**Main.hs wiring.** In `cli/nagarectl/app/Main.hs`, add a `SnapshotOpts` record (fields: `app`,
`volume`, optional `bucket`, optional `keep` count, plus the shared `ghcEnv`), a `Snapshot
SnapshotOpts` constructor to the `Command` sum type (line 121 region), a `snapshotCmd` `ParserInfo`,
and `<> command "snapshot" snapshotCmd` inside the `storage` subparser EP-35 created (mirror the
`site` subparser at lines 271–277). Dispatch `Snapshot sopts -> runSnapshot sopts` in `main`
(line 326 region).

**Tests.** In `cli/nagarectl/test/Spec.hs` add a `testGroup "Nagare.Storage.Snapshot"` with cases for
`snapshotObjectPath` (exact string) and `snapshotsToPrune` (keep-last-N on a fixed list). No cluster
is needed; these are pure.

**Acceptance for M1.** `cabal test` passes including the new group; and on a live cluster with a
deployed app that has a `data` volume, `nagarectl storage snapshot myapp data` followed by
`gsutil ls gs://tan-nb-exp-nagare-backups/volumes/myapp/data/` shows the new `*.tar.gz` object.

### Milestone 2 — backup-ownership policy, runbook/user-doc updates, tested restore

**Scope and outcome.** At the end of M2, `nagarectl deploy` warns (on stderr) for every
backup-excluded volume; the disaster-recovery runbook and the user backup guide document app-volume
backup/restore; and a restore drill proves a snapshot can be brought back into a *disposable* PVC and
its contents compared, scratch-first, without touching live data.

**The backup-ownership check (pure).** Add to `Nagare.Storage.Snapshot` (or a small sibling module
`Nagare.Storage.Backup`):

```haskell
-- | One warning line per volume that is excluded from backups, given the app
-- name and its declared volumes. A volume is backup-excluded iff its
-- RetentionPolicy is Delete (see Decision Log). Empty list ⇒ all volumes backed up.
backupExcludedWarnings :: Text -> [Volume] -> [Text]
```

returning, for each excluded volume, a line of the exact form
`"warning: volume '" <> vol <> "' on app '" <> app <> "' is NOT backed up (backup excluded in config)"`.

**Emit at deploy time.** In `cli/nagarectl/app/Main.hs` `runDeploy` (lines 335–374), after the config
loads successfully (`dep`) and before/around the apply, compute
`backupExcludedWarnings (serviceNameText (dep ^. #name)) (dep ^. #volumes)` and print each line to
**stderr** with `TIO.hPutStrLn stderr`. Do this in both the dry-run and real branches so a developer
sees the warning on `--dry-run` too. Warnings never fail the deploy — they inform.

**The restore script `scripts/restore-volume.sh`.** New file mirroring `scripts/restore-sqlite.sh`
exactly in structure: the same project-isolation preflight (copied verbatim), `BACKUP_BUCKET`
required, the snapshot object passed as `$1`, and a **scratch** target. Because a volume restore must
land in a Kubernetes PVC rather than a local file, the scratch-first semantics are realized as: create
a *disposable* PVC named `<pvc>-restore-scratch`, run a one-off Job that mounts it and untars the
downloaded archive into it, and print a file listing for the operator to compare. It never writes to
the live PVC. The script's shape:

```bash
#!/usr/bin/env bash
# scripts/restore-volume.sh — restore an app-volume snapshot from GCS into a
# SCRATCH PVC, never over the live volume. Mirrors restore-sqlite.sh.
set -euo pipefail
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi
OBJECT="${1:?usage: restore-volume.sh gs://BUCKET/volumes/<app>/<volume>/<ts>.tar.gz [SCRATCH_PVC]}"
SCRATCH_PVC="${2:-vol-restore-scratch}"
NS="${NAGARE_NAMESPACE:-personal}"
# 1) create the scratch PVC (local-path, RWO, sized generously)
# 2) apply a one-off Job that: gsutil cp "$OBJECT" - | tar -C /restore -xzf -
#    mounting the scratch PVC at /restore, with GCE_METADATA_HOST + CLOUDSDK_CORE_PROJECT
# 3) kubectl wait --for=condition=complete the Job, then a `find /restore | head` listing Job
#    so the operator can eyeball the restored tree before promoting.
echo "restored into scratch PVC '$SCRATCH_PVC' in namespace '$NS'; listing above. Promote manually."
```

Keep the heredoc-applied Job manifests inline in the script (as the postgres/sqlite scripts keep their
logic inline). The script must be `chmod +x`.

**Runbook update.** In `docs/runbooks/disaster-recovery.md`, add a row to the "Backup inventory" code
block (lines 21–37):

```text
App volume data ........... tar.gz snapshots in
                            gcs://<backupBucket>/volumes/<app>/<volume>/  -> scripts/restore-volume.sh (scratch)
```

and add an app-volume restore sub-step under "7. Restore data" (lines 147–161) showing
`scripts/restore-volume.sh gs://$BACKUP_BUCKET/volumes/<app>/<volume>/<latest>.tar.gz` and the
observation (the scratch PVC's file listing matches the source). Include the hot-DB consistency
caveat (quiesce or use Litestream for actively-written databases).

**User-doc update.** In `docs/user/backups-and-disaster-recovery.md`, add a row to the "What to back
up" table (lines 21–32):

```text
| App volumes (PVCs) | `nagarectl storage snapshot` → GCS (`volumes/<app>/<volume>/`); excluded volumes warned at deploy | ✅ EP-36 |
```

and a short paragraph describing the include/exclude policy and that excluded volumes are warned at
deploy time.

**Tests.** Add a `backupExcludedWarnings` case to `cli/nagarectl/test/Spec.hs`: build a `Deployment`
(or just a `[Volume]`) with one `Retain` and one `Delete` volume and assert exactly one warning line
with the expected text. Use EP-34's smart constructors to build the `Volume`s.

**Acceptance for M2.** `cabal test` passes; `nagarectl deploy --dry-run` on a config with a `Delete`
volume prints the warning line to stderr; the restore drill below produces a scratch PVC whose
contents match the snapshotted source.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` inside the dev shell
(`nix develop` or `direnv allow`), which provides `cabal`/`ghc`, `kubectl`, and `gcloud`/`gsutil`,
unless a different working directory is stated.

### M1 steps

1. Register the new module. Edit `cli/nagarectl/nagarectl.cabal`, adding `Nagare.Storage.Snapshot`
   (and, if EP-35 has not yet added it, `Nagare.Storage.Discover`) to the `library`
   `exposed-modules` list (lines 33–45).

2. Create `cli/nagarectl/src/Nagare/Storage/Snapshot.hs` with the pure helpers
   (`snapshotObjectPath`, `snapshotGsUrl`, `snapshotTimestamp`, `snapshotsToPrune`), the
   `SnapshotJobInputs` record + `renderSnapshotJob`, and the `runSnapshot` IO driver.

3. Wire the subcommand into `cli/nagarectl/app/Main.hs`: add `SnapshotOpts`, the `Snapshot`
   constructor, `snapshotCmd`, the `<> command "snapshot" snapshotCmd` line in the `storage`
   subparser, and the `Snapshot sopts -> runSnapshot sopts` dispatch.

4. Build:

   ```bash
   cabal build nagarectl
   ```

   Expected: it compiles. A typical first failure is a missing import (`Data.Time.Format`,
   `Cradle`); add it and rebuild.

5. Add pure tests to `cli/nagarectl/test/Spec.hs` and run them:

   ```bash
   cabal test nagarectl-test
   ```

   Expected tail:

   ```text
   nagarectl
     Nagare.Storage.Snapshot
       snapshotObjectPath builds volumes/<app>/<volume>/<ts>.tar.gz: OK
       snapshotsToPrune keeps the last N newest:                     OK
   All N tests passed
   ```

6. (Live, requires a cluster with a deployed app + a `data` volume — soft-depends on EP-33/EP-35.)
   Export the bucket and run a snapshot:

   ```bash
   export NAGARE_BACKUP_BUCKET=$(cd infra/pulumi && pulumi stack output backupBucket)
   cabal run nagarectl -- storage snapshot myapp data
   gsutil ls "gs://${NAGARE_BACKUP_BUCKET}/volumes/myapp/data/"
   ```

   Expected transcript:

   ```text
   job.batch/nagare-snapshot-myapp-data-20260609t141503z created
   job.batch/nagare-snapshot-myapp-data-20260609t141503z condition met
   Snapshot written: gs://tan-nb-exp-nagare-backups/volumes/myapp/data/20260609T141503Z.tar.gz
   gs://tan-nb-exp-nagare-backups/volumes/myapp/data/20260609T141503Z.tar.gz
   ```

### M2 steps

7. Implement `backupExcludedWarnings` and emit it from `runDeploy` in
   `cli/nagarectl/app/Main.hs`.

8. Create and mark executable the restore script:

   ```bash
   chmod +x scripts/restore-volume.sh
   ```

9. Update `docs/runbooks/disaster-recovery.md` (inventory row + restore sub-step) and
   `docs/user/backups-and-disaster-recovery.md` (table row + policy paragraph).

10. Add the `backupExcludedWarnings` test and re-run `cabal test nagarectl-test`.

11. Show the deploy-time warning (no cluster needed — dry run):

    ```bash
    cabal run nagarectl -- deploy --dry-run -f path/to/Config.hs 2>warn.txt; cat warn.txt
    ```

    Expected (for a config with a `Delete` volume named `cache`):

    ```text
    warning: volume 'cache' on app 'myapp' is NOT backed up (backup excluded in config)
    ```

12. Restore drill (live). Pick a snapshot object from M1 and restore into a scratch PVC:

    ```bash
    export BACKUP_BUCKET=$(cd infra/pulumi && pulumi stack output backupBucket)
    OBJ=$(gsutil ls "gs://${BACKUP_BUCKET}/volumes/myapp/data/" | tail -1)
    scripts/restore-volume.sh "$OBJ"
    ```

    Expected: a scratch PVC `vol-restore-scratch` is created, a restore Job completes, and the script
    prints a `find` listing of the restored tree for comparison, ending with
    `restored into scratch PVC 'vol-restore-scratch' …; Promote manually.` The live `data` PVC is
    untouched.


## Validation and Acceptance

The change is proven by behavior, not compilation alone.

**Pure logic (always runnable, no cluster).** `cabal test nagarectl-test` exercises
`snapshotObjectPath`, `snapshotsToPrune`, and `backupExcludedWarnings`. The path test asserts the
exact string `volumes/myapp/data/20260609T141503Z.tar.gz`. The prune test feeds a list of nine
fixed-width timestamped names with `n = 7` and asserts the two **oldest** are returned for deletion
(and that re-running on the kept set returns `[]` — idempotent). The warnings test asserts that a
two-volume config (`data` = `Retain`, `cache` = `Delete`) yields exactly the one `cache` warning line
with the precise wording above. These tests fail before the code exists and pass after — run them on a
clean checkout to confirm.

**Snapshot end to end (live).** After `nagarectl storage snapshot myapp data`,
`gsutil ls gs://tan-nb-exp-nagare-backups/volumes/myapp/data/` lists a `*.tar.gz` whose timestamp
matches the run, and `gsutil cat <obj> | tar -tzf - | head` lists the expected files from the volume.
Running the command a second time produces a *second* object (append-only) and, once more than N exist,
the oldest is pruned (`gsutil ls` count stays at N).

**Deploy-time warning (live or dry-run).** `nagarectl deploy --dry-run` on a config containing a
`Delete` volume prints the warning to stderr; a config whose volumes are all `Retain` prints nothing
about backups. This is the observable form of the backup-ownership policy.

**Restore drill (live).** `scripts/restore-volume.sh <gs-object>` creates the scratch PVC, untars the
snapshot into it, and prints a file listing. Comparing that listing (and, for a file-based payload,
`sha256sum` of a known file) against the source proves the snapshot round-trips. The live PVC is never
mounted writable by the drill, so live data cannot be clobbered — the same guarantee
`scripts/restore-sqlite.sh` provides for SQLite.

**Runbook truth.** `docs/runbooks/disaster-recovery.md` now lists app-volume data in its inventory and
gives a restore command that actually runs; this satisfies the MasterPlan Progress item "disaster-
recovery runbook updated and a restore tested."


## Idempotence and Recovery

Snapshots are **append-only**: each run writes a new timestamped object, so taking a snapshot twice is
always safe and never overwrites an earlier one. The snapshot Job is named with the timestamp, so a
re-run gets a fresh Job name; a leftover completed Job is deleted by `runSnapshot` after success, and
a failed Job (with `backoffLimit: 0`) leaves a single inspectable Job you can `kubectl logs` then
`kubectl delete` before retrying. Retention pruning is idempotent: `snapshotsToPrune` on an
already-pruned set returns `[]`, so re-running prunes nothing.

Restore is **scratch-first and non-destructive**, exactly like `scripts/restore-sqlite.sh`: it writes
only to a disposable `*-restore-scratch` PVC and never mounts the live PVC writable, so a botched or
repeated restore cannot corrupt live data. To retry, delete the scratch PVC
(`kubectl delete pvc vol-restore-scratch -n personal`) and re-run the script.

The bucket itself has `forceDestroy: false`
(`infra/pulumi/src/components/NagarePerimeter.ts` line 83), so an accidental `pulumi destroy` cannot
wipe the snapshots. All gcloud/gsutil/kubectl operations target `tan-nb-exp` only — the shell scripts
carry the project-isolation preflight, and the in-cluster Job sets `CLOUDSDK_CORE_PROJECT=tan-nb-exp`,
so no operation can touch another project even if the ambient default were wrong.


## Interfaces and Dependencies

**New module `Nagare.Storage.Snapshot`** (`cli/nagarectl/src/Nagare/Storage/Snapshot.hs`, registered
in `cli/nagarectl/nagarectl.cabal` `exposed-modules`). Public signatures that must exist at the end of
M1/M2:

```haskell
-- Pure: GCS object path within the bucket.
snapshotObjectPath :: Text -> Text -> Text -> Text          -- app -> volume -> timestamp -> path
snapshotGsUrl      :: Text -> Text -> Text -> Text -> Text   -- bucket -> app -> volume -> timestamp -> gs:// URL
snapshotTimestamp  :: UTCTime -> Text                        -- YYYYMMDDTHHMMSSZ

-- Pure: keep-last-N retention. Given keep-count and existing object names,
-- returns the names to delete.
snapshotsToPrune   :: Int -> [Text] -> [Text]

-- Pure: backup-ownership warnings for a deploy.
backupExcludedWarnings :: Text -> [Volume] -> [Text]         -- app -> volumes -> warning lines

-- Pure: render the in-cluster snapshot Job manifest.
data SnapshotJobInputs = SnapshotJobInputs
  { sjiNamespace :: !Text
  , sjiJobName   :: !Text
  , sjiClaimName :: !Text
  , sjiDestUrl   :: !Text       -- gs://… URL from snapshotGsUrl
  , sjiMountPath :: !Text       -- e.g. "/vol"
  }
renderSnapshotJob :: SnapshotJobInputs -> ByteString

-- IO: the command driver.
runSnapshot :: SnapshotOpts -> IO ()
```

**Consumed from EP-34** (`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, MasterPlan IP1/IP3): the `Volume`
type and accessors (`volumeNameText`, `mountPathText`), `RetentionPolicy(Retain, Delete)`, the
`volumes` field on `Deployment`/`ServerSite`, the deterministic PVC name `nagare-vol-<app>-<volume>`,
and the `nagare.dev/managed-by: nagarectl` label.

**Consumed from EP-35** (`cli/nagarectl/src/Nagare/Storage/Discover.hs`, MasterPlan IP5): the
`storage` subparser in `cli/nagarectl/app/Main.hs` (extended here, not forked) and a PVC-discovery
helper resolving `APP`+`VOLUME` → PVC reference by the IP3 labels. If absent when M1 starts, implement
the minimal `discoverVolume` locally and note the deviation (see Context and Orientation).

**Libraries.** `cradle` (already a dependency, cabal line 51) for `kubectl`/`gsutil` shell-outs, used
as in `cli/nagarectl/src/Nagare/Deploy.hs` (`cmd "kubectl" & addArgs […]`, `run_`); `time` (cabal
line 62) for `snapshotTimestamp`; `bytestring`/`text` for manifest rendering; `temporary` for the
temp-file apply pattern. `tasty`/`tasty-hunit` (test stanza, cabal lines 110–111) for the new tests.

**Services.** The GCS bucket `tan-nb-exp-nagare-backups` (Pulumi output `backupBucket`), reached with
ambient ADC (node service account, `roles/storage.objectAdmin`); the k3s cluster via `kubectl`. All
targeting `tan-nb-exp` per the repository `CLAUDE.md`.

**New shell script.** `scripts/restore-volume.sh` (scratch-first restore), mirroring
`scripts/restore-sqlite.sh` including the project-isolation preflight block.

**Docs touched.** `docs/runbooks/disaster-recovery.md` (inventory row + restore sub-step) and
`docs/user/backups-and-disaster-recovery.md` (table row + policy paragraph), both referenced by EP-37
(`docs/plans/37-persistent-storage-docs-and-end-to-end-examples.md`).
