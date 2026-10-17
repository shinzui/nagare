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

Full plan before trimming: [36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] Validate end to end: `nagarectl storage snapshot myapp data` then `gsutil ls` shows the object. (Deferred to EP-37 — needs a deployed app + cluster API access; IAP forwards only SSH/22. See Surprises.) (2026-10-17: on cloud context `mp23-c3m` a reviewed service-volume snapshot converged and was restored from the bucket, which shows the object exists; [C3 assertion](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c3-acceptance-83124396/assertions/volume-backup-restore.json).)

Milestone 2 — backup-ownership policy + runbook + tested restore:

- [x] Implement the pure `backupExcludedWarnings` check over a loaded config's volumes. (2026-06-09; `Delete` ⇒ excluded.)
- [x] Emit the warnings from `runDeploy` in `cli/nagarectl/app/Main.hs`. (2026-06-09; stderr, both dry-run and live — verified via the real CLI on a `Delete`-volume config.)
- [x] Add the `scripts/restore-volume.sh` scratch-first restore script. (2026-06-09; `bash -n` clean, `chmod +x`, scratch PVC + restore Job, never touches the live PVC.)
- [x] Add the "app volumes" row + restore procedure to `docs/runbooks/disaster-recovery.md`. (2026-06-09; inventory row + step-7 sub-step + hot-DB caveat.)
- [x] Add the "app volumes" row to `docs/user/backups-and-disaster-recovery.md`. (2026-06-09; row + include/exclude policy section.)
- [x] Add a pure test for `backupExcludedWarnings` to `cli/nagarectl/test/Spec.hs`. (2026-06-09)
- [x] Validate end to end: restore a snapshot into a disposable PVC and compare contents. (Deferred to EP-37 — needs cluster API access; same IAP constraint.) (2026-10-17: the same C3 check restored the snapshot-time file after the live file was changed; [C3 assertion](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c3-acceptance-83124396/assertions/volume-backup-restore.json).)

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

