---
id: 65
slug: unified-gcs-data-movement-job-abstraction-and-restore-unification
title: "Unified GCS Data-Movement Job Abstraction and Restore Unification"
kind: exec-plan
created_at: 2026-06-11T02:37:50Z
intention: "intention_01ktt8he4vepkb0gbp2k9z5fc3"
master_plan: "docs/masterplans/13-live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration.md"
---

# Unified GCS Data-Movement Job Abstraction and Restore Unification

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [65-unified-gcs-data-movement-job-abstraction-and-restore-unification.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/65-unified-gcs-data-movement-job-abstraction-and-restore-unification.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

`nagarectl` is a command-line tool (its source is the Haskell package under
`cli/nagarectl/`) that operates a small single-node Kubernetes cluster on a Google Compute
Engine (GCE) virtual machine. Several of its subcommands move data to and from Google Cloud
Storage (GCS, Google's object store, accessed by `gs://bucket/path` URLs) by rendering a
short-lived Kubernetes **Job** — a one-shot pod that runs to completion — whose container is
the `google/cloud-sdk:slim` image (it ships the `gsutil` and `gcloud` command-line tools).
That pod authenticates to GCS with **Application Default Credentials (ADC)**: it asks the GCE
**metadata server** (a special HTTP endpoint at the link-local IP `169.254.169.254`) for an
access token minted from the VM's attached service account. No key files are involved.

On 2026-06-10 a live audit of the running `nagare-01` cluster found that this GCS
authentication only worked in *some* of these Jobs. To reach the metadata server, the
`gsutil`/`gcloud` tools look it up by the canonical DNS name `metadata.google.internal`. A
pod cannot resolve that name through cluster DNS, so the Job's pod specification needs a
`hostAliases` entry — a per-pod `/etc/hosts` line — mapping `metadata.google.internal` to
`169.254.169.254`, plus the environment variables `GCE_METADATA_HOST=169.254.169.254` and
`CLOUDSDK_CORE_PROJECT=<the target project>`. That helper existed in the database-backup
renderer but was **missing** from the volume-snapshot renderer and from
`scripts/restore-volume.sh`; both failed live with `401 Anonymous` (an HTTP 401 from GCS
because the pod fell back to anonymous, unauthenticated access). Worse, volume *restore*
existed only as a hand-written bash script (`scripts/restore-volume.sh`) — it was never part
of the typed control plane at all — alongside three other bash scripts
(`backup-postgres.sh`, `restore-postgres.sh`, `restore-sqlite.sh`) that re-implemented the
same GCS plumbing in shell heredocs.

After this change, **one typed Haskell module renders the canonical GCS-Job pod scaffolding
exactly once** — the `google/cloud-sdk:slim` container, the `metadata.google.internal`
`hostAliases`, the `GCE_METADATA_HOST`/`CLOUDSDK_CORE_PROJECT` environment, and the
`restartPolicy: Never` / `backoffLimit: 0` shape (so a failure surfaces instead of looping).
Database backup, database restore, volume snapshot, and a brand-new volume restore all render
through it, so the `401 Anonymous` bug cannot recur in one path while another is fixed. A new
`nagarectl storage restore APP VOLUME BACKUP_ID [--into-live]` verb gives volume restore the
same scratch-first safety database restore already has (it restores into a disposable
"scratch" volume by default; live data is touched only when you ask). The four hand-rolled
bash scripts are **deleted**, and the disaster-recovery runbook calls `nagarectl` verbs
directly.

You can see it working three ways: `cabal test nagarectl-test` is green (with a new test
proving every data-movement Job renderer emits the metadata `hostAliases`); `nagarectl
storage restore --help` shows the new verb; and `nagarectl storage restore myapp data <id>
--dry-run` prints a Job manifest that contains the `metadata.google.internal` `hostAliases`
and the `google/cloud-sdk:slim` image.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Status: **Complete** — M1–M4 done; `cabal test nagarectl-test` is green at 262 tests.

- [x] M1: Create the shared module `Nagare.Cluster.GcsJob` (canonical pod scaffolding) and
      add it to `nagarectl.cabal`.
- [x] M1: Refactor `Nagare.Database.Backup`, `Nagare.Database.Restore`, and
      `Nagare.Storage.Snapshot` to consume it; delete the three duplicated
      `metadataHostAliases` copies and the inline `GCE_METADATA_HOST` env literals; confirm
      `cabal build` no longer reports a module cycle. (Built clean, 258 tests still green,
      `grep metadata.google.internal src/` now hits only `Nagare/Cluster/GcsJob.hs`.)
- [x] M2: Add `Nagare.Storage.Restore` (renderer + driver) and wire the new
      `nagarectl storage restore APP VOLUME BACKUP_ID [--into-live]` verb in `app/Main.hs`.
      (`--help` lists the verb; dry-run against `uploads-volume` prints the scratch-PVC +
      Job manifests with the metadata `hostAliases`, `google/cloud-sdk:slim`, and a
      `-restore-scratch` claim; `--into-live` omits the scratch PVC and targets the live PVC.)
- [x] M3: Delete `scripts/restore-volume.sh`, `scripts/backup-postgres.sh`,
      `scripts/restore-postgres.sh`, `scripts/restore-sqlite.sh`; update
      `docs/runbooks/disaster-recovery.md`, `docs/user/backups-and-disaster-recovery.md`, and
      `docs/user/persistent-storage.md` to call `nagarectl` verbs; record the
      `nagarectl`-is-a-DR-prerequisite note. (Also updated two further in-scope references the
      audit grep surfaced: `docs/runbooks/server-operations.md` and `docs/user/reference.md`.
      Acceptance grep over `scripts/ docs/runbooks/ docs/user/` now returns nothing.)
- [x] M4: Add the recurrence-prevention test asserting every data-movement Job renderer
      includes the metadata `hostAliases`; confirm `cabal test nagarectl-test` is green.
      (New `gcsJobHostAliasesTests` drives all four renderers through one assertion table;
      262 tests pass. Demonstrated the guard bites — see Surprises & Discoveries.)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The recurrence guard was proven to bite.** With the new test in place, deleting
  `"hostAliases" .= metadataHostAliases` from `Nagare.Cluster.GcsJob.dataMovementJobSpec` and
  re-running `cabal test nagarectl-test` failed **all four** new cases at once (db backup, db
  restore, volume snapshot, volume restore) — plus the pre-existing `backupRestoreTests`
  hostAliases assertion, for 5 failures total — because every renderer now shares one assembly.
  Restoring the line returned the suite to 262 green. This is exactly the centralization the
  plan aimed for: the 401-Anonymous regression can no longer hide in one renderer.

- **The M3 acceptance grep was broader than the plan's enumerated file list.** Beyond the three
  docs the plan named, the audit grep over `scripts/ docs/runbooks/ docs/user/` also matched
  `docs/runbooks/server-operations.md` (a `run scripts/backup-postgres.sh` remediation hint) and
  `docs/user/reference.md` (a `scripts/restore-volume.sh` restore pointer). Both were updated to
  the `nagarectl` equivalents. The explanatory "these helper scripts are removed" notes were
  reworded to drop the literal `*.sh` filename tokens so the acceptance grep stays clean.

## Decision Log

Record every decision made while working on the plan.

- Decision: The shared module is named `Nagare.Cluster.GcsJob` and lives at
  `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs`. It sits **below** both `Nagare.Database.*`
  and `Nagare.Storage.*` in the module graph and imports neither.
  Rationale: it is the only placement that lets `Database.Backup`, `Database.Restore`,
  `Storage.Snapshot`, and the new `Storage.Restore` all share the `hostAliases`/metadata-env
  helper without forming an import cycle. The cycle already exists in spirit: `Database.Backup`
  and `Database.Restore` import `Nagare.Storage.Snapshot` (for `snapshotTimestamp` /
  `snapshotsToPrune`), so `Storage.Snapshot` cannot import back from `Database.Backup` — which
  is exactly why the audit's attempt to import `metadataHostAliases` from `Database.Backup`
  into `Storage.Snapshot` failed with "Module graph contains a cycle." A new leaf module that
  nobody below it imports breaks the knot. The `Cluster` namespace is chosen because the helper
  is about the Kubernetes/cluster pod shape, not about databases or storage specifically.
  Date: 2026-06-11 (inherited from MasterPlan 13 Decision Log).

- Decision: The four hand-rolled bash scripts (`scripts/restore-volume.sh`,
  `scripts/backup-postgres.sh`, `scripts/restore-postgres.sh`, `scripts/restore-sqlite.sh`)
  are **deleted**, not reduced to thin break-glass wrappers. The disaster-recovery runbook
  calls `nagarectl` verbs directly.
  Rationale: user decision (2026-06-11, recorded in MasterPlan 13) — control-plane logic must
  live solely in the typed app, not be hidden in or duplicated by shell. Trade-off accepted:
  disaster recovery now requires the `nagarectl` binary on the operator box, which this plan
  records as an explicit DR prerequisite in the runbook.
  Date: 2026-06-11.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Delivered against the purpose in full, offline-verifiable:

1. **The cycle is gone and the helper is de-duplicated.** `Nagare.Cluster.GcsJob` is a leaf
   module rendering the canonical GCS data-movement pod scaffolding once. `cabal build
   exe:nagarectl` reports no module cycle, and `grep -rn 'metadata.google.internal'
   cli/nagarectl/src/` now hits only `Nagare/Cluster/GcsJob.hs` (the literal plus its Haddock),
   where it previously appeared in three renderers. M1 preserved every renderer's byte output:
   the field-assembly order in `dataMovementJobSpec` matches the prior inline order, so all 258
   pre-existing tests stayed green through the refactor.

2. **Volume restore now exists in the typed control plane.** `nagarectl storage restore APP
   VOLUME BACKUP_ID [--into-live]` is scratch-first by default: it applies a disposable
   `<pvc>-restore-scratch` PVC and untars the GCS snapshot into it, touching the live PVC only
   under `--into-live` (which prints a loud confirmation). The dry-run against `uploads-volume`
   renders the scratch-PVC manifest, the `google/cloud-sdk:slim` image, the
   `metadata.google.internal` `hostAliases`, and the `-restore-scratch` claim — exactly the
   shape the deleted `scripts/restore-volume.sh` produced, now type-checked and shared.

3. **The four hand-rolled scripts are deleted and every doc calls `nagarectl` verbs.** No
   systemd timer or justfile target referenced them. The disaster-recovery runbook now opens
   with a "`nagarectl` is a DR prerequisite" note and its restore steps call `nagarectl db
   restore` / `nagarectl storage restore` (and `litestream restore` for SQLite).

4. **The regression guard is centralized and enforced.** A single `gcsJobHostAliasesTests` table
   drives all four renderers; adding a fifth data-movement renderer means adding one row.

No gaps against scope. The live exercise of these rendered Jobs (a real snapshot+restore round
trip on `nagare-01`) is intentionally out of this plan and belongs to EP-5
(`docs/plans/69-ci-pipeline-and-live-smoke-test.md`), which consumes this module's output but
does not edit it.

Lessons: (a) putting the *whole* `.spec` body (not just the `hostAliases` fragment) behind the
shared module is what makes the recurrence guard total — a renderer cannot partially adopt the
scaffolding. (b) Acceptance greps that scope by directory can be broader than a plan's
enumerated file list; running the acceptance command (not just editing the named files) caught
two extra in-scope references.

