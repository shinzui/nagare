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

Status: **In Progress** — M1 complete; M2–M4 remaining.

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
- [ ] M3: Delete `scripts/restore-volume.sh`, `scripts/backup-postgres.sh`,
      `scripts/restore-postgres.sh`, `scripts/restore-sqlite.sh`; update
      `docs/runbooks/disaster-recovery.md`, `docs/user/backups-and-disaster-recovery.md`, and
      `docs/user/persistent-storage.md` to call `nagarectl` verbs; record the
      `nagarectl`-is-a-DR-prerequisite note.
- [ ] M4: Add the recurrence-prevention test asserting every data-movement Job renderer
      includes the metadata `hostAliases`; confirm `cabal test nagarectl-test` is green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### Where the code lives

The CLI is a Cabal package at `cli/nagarectl/`. Its build description is
`cli/nagarectl/nagarectl.cabal`. There are three build targets plus a test suite:

- `library` — the reusable modules under `cli/nagarectl/src/`. The list of modules is the
  `exposed-modules:` stanza in the cabal file; **a new module must be added there or it will
  not compile.**
- `executable nagarectl` — the command-line entry point, a single file
  `cli/nagarectl/app/Main.hs`, which defines the option parser and dispatches subcommands.
- `executable nagared` — an unrelated webhook daemon (not touched by this plan).
- `test-suite nagarectl-test` — one file, `cli/nagarectl/test/Spec.hs`, run with
  `cabal test nagarectl-test`. It has 258 tests today, built on the `tasty` framework
  (`tasty`, `tasty-hunit` for unit assertions, `tasty-golden` for golden-file comparisons).

The build runs inside a Nix development shell. Enter it with `nix develop` (or, if `direnv`
is set up in this repo, simply `cd` into the repo and run `direnv allow` once). All `cabal`
commands in this plan are run from `cli/nagarectl/` unless stated otherwise.

### The four modules that render GCS data-movement Jobs today

A "data-movement Job" here means a Kubernetes `batch/v1` Job whose pod copies bytes to or
from GCS using `gsutil`. Three such renderers exist today; this plan adds a fourth.

1. `cli/nagarectl/src/Nagare/Database/Backup.hs` — renders the database-backup Job and
   CronJob (`nagarectl db backup NAME`). Key definitions:
   - `metadataHostAliases :: Value` (around line 210) — the `hostAliases` helper. It is an
     Aeson `Value` (a JSON value; Aeson is the Haskell JSON library) equal to
     `[ { ip: "169.254.169.254", hostnames: ["metadata.google.internal"] } ]`. It is
     **exported** from the module's export list.
   - `backupJobSpecValue :: BackupJobInputs -> Value` — the shared Job `.spec` body, which
     references `"hostAliases" .= metadataHostAliases`.
   - `uploadContainer :: BackupJobInputs -> Value` — the `google/cloud-sdk:slim` container.
     Its `env` list includes `plainEnv "GCE_METADATA_HOST" "169.254.169.254"` and
     `plainEnv "CLOUDSDK_CORE_PROJECT" (bjiProject i)`.
   - `plainEnv :: Text -> Text -> Value` — a tiny helper rendering `{ name, value }`.
   This module also depends on `Nagare.Storage.Snapshot` (`import Nagare.Storage.Snapshot
   (snapshotTimestamp, snapshotsToPrune)` at line 55). That import is the load-bearing half
   of the cycle.

2. `cli/nagarectl/src/Nagare/Database/Restore.hs` — renders the database-restore Job
   (`nagarectl db restore NAME BACKUP_ID`). It **imports** the helper from Backup:
   `import Nagare.Database.Backup (backupExt, backupRawExt, dbBackupGsUrl, metadataHostAliases)`
   (line 34) and uses `"hostAliases" .= metadataHostAliases` in `renderRestoreJob`. Its
   `downloadContainer` sets the same two env vars inline. It also imports
   `Nagare.Storage.Snapshot (snapshotTimestamp)` (line 37).

3. `cli/nagarectl/src/Nagare/Storage/Snapshot.hs` — renders the volume-snapshot Job
   (`nagarectl storage snapshot APP VOLUME`). During the 2026-06-10 audit a **local copy** of
   `metadataHostAliases` was added inside the `jobValue` `where`-clause (lines 196–208), with a
   comment explaining it could not be imported from `Database.Backup` because that would form a
   cycle. It also sets `GCE_METADATA_HOST`/`CLOUDSDK_CORE_PROJECT` inline in the container env.
   This module is the *bottom* of the existing pair: `Database.Backup` and `Database.Restore`
   import it, and it imports `Nagare.Storage.Discover (pvcName)`.

The shape of all three is the same JSON skeleton:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: <job-name>
  namespace: <ns>
  labels: { nagare.dev/managed-by: nagarectl, ... }
spec:
  backoffLimit: 0
  template:
    metadata: { labels: { ... } }      # snapshot omits the template labels today
    spec:
      restartPolicy: Never
      hostAliases:
        - ip: "169.254.169.254"
          hostnames: ["metadata.google.internal"]
      initContainers: [ ... ]          # backup/restore have one; snapshot has none
      containers:
        - name: <name>
          image: google/cloud-sdk:slim # the GCS container (snapshot/restore-volume only)
          command: ["/bin/sh", "-c"]
          args: [ "<shell>" ]
          env:
            - { name: <data env>, value: ... }
            - { name: GCE_METADATA_HOST, value: "169.254.169.254" }
            - { name: CLOUDSDK_CORE_PROJECT, value: "<project>" }
          volumeMounts: [ ... ]
      volumes: [ ... ]
```

The differences across the four Jobs are: which containers run (an engine-client
initContainer for db backup/restore; none for volume snapshot/restore), the shell each
container runs, the volume(s) mounted (an `emptyDir` scratch for db jobs; a PVC for volume
jobs), and the GCS container's data-specific env (`DEST`, `SRC`, `PREFIX`, `KEEP`,
`OBJECT`). What is **identical** across all four is the metadata-auth scaffolding:
`restartPolicy: Never`, `backoffLimit: 0`, the `hostAliases`, and the
`GCE_METADATA_HOST`/`CLOUDSDK_CORE_PROJECT` env pair. That identical part is what the shared
module will own.

### How GCS-bucket and project values are resolved at the command layer

`cli/nagarectl/app/Main.hs` resolves the GCP project and backup bucket through two helpers
already present there:

- `resolveTargetProfile :: IO TargetProfile` (from `Nagare.Target`) reads the operator's
  target profile (the git-ignored `nagare.target.env`, with built-in defaults). The record
  field `tpProject :: Text` is the GCP project id; `tpBackupBucket :: Text` is the backup
  bucket name.
- `resolveBackupBucket :: Maybe String -> IO Text` (defined in `Main.hs`) returns the
  `--bucket` override if given, else `tpBackupBucket` from the profile.

The existing `StorageSnapshot` dispatch in `runStorage` (around line 2361) shows the exact
pattern the new restore verb must follow:

```haskell
StorageSnapshot copts vol bucket keep -> do
  dep <- resolveStorageDep copts
  tp <- resolveTargetProfile
  b <- resolveBackupBucket bucket
  runSnapshot dep (T.pack vol) b keep (tpProject tp)
```

`resolveStorageDep :: StoreCommonOpts -> IO Deployment` loads the app's typed config and
verifies the positional `APP` matches the config's name. The loaded `Deployment` exposes the
declared volumes (`dep ^. #volumes`) and identity (`serviceNameText (dep ^. #name)`,
`namespaceText (dep ^. #namespace)`).

### How a volume's PVC name is resolved

A **PVC** (PersistentVolumeClaim) is the Kubernetes object that requests durable disk for a
pod. `nagarectl storage snapshot` resolves the live PVC name with `pvcName :: Text -> Text ->
Text` from `Nagare.Storage.Discover` (re-exported from the EP-34 renderer); `pvcName app
volume` is the deterministic PVC name. `Nagare.Storage.Snapshot.runSnapshot` uses
`claim = pvcName app volume`. The new restore verb resolves the **live** PVC name the same
way, and constructs a **scratch** PVC name from it (see M2).

### The four bash scripts being deleted

- `scripts/restore-volume.sh` — restores a `tar.gz` volume snapshot from GCS into a scratch
  PVC via a heredoc-rendered Job that *does* set the `hostAliases`. This is the live behavior
  the new `nagarectl storage restore` verb replaces. (The script's Job is the template for
  the new renderer.)
- `scripts/backup-postgres.sh` — an EP-7-era host-side `pg_dump` + `gsutil cp` of the
  *host* Postgres. It is **not** invoked by any NixOS systemd timer or the `justfile`
  (verified: no references in `nixos/` or `justfile`). Scheduled database backups are now the
  managed-DB CronJob rendered by `Nagare.Database.Backup`. On-demand database backup is
  `nagarectl db backup NAME`.
- `scripts/restore-postgres.sh` — restores a `pg_dump` from GCS into a scratch database. The
  managed-DB equivalent is `nagarectl db restore NAME BACKUP_ID` (scratch-first).
- `scripts/restore-sqlite.sh` — restores a Litestream-backed SQLite db into a scratch file.

Each of the four begins by sourcing `scripts/lib/target.sh` and calling
`_require_target_project` (the configurable, fail-closed project-isolation preflight). That
preflight is a property of the *shell* tooling; the typed `nagarectl` verbs enforce the same
single-project guarantee differently (they read the target profile and pass `tpProject` into
the rendered Job's `CLOUDSDK_CORE_PROJECT`). `scripts/lib/target.sh` itself is **not** deleted
— other scripts use it; only the four data-movement scripts are removed.

### Docs that reference the scripts

- `docs/runbooks/disaster-recovery.md` — the rebuild runbook. Its "Backup inventory" table
  and step 7 ("Restore data") invoke `scripts/restore-sqlite.sh`,
  `scripts/restore-postgres.sh`, and `scripts/restore-volume.sh`.
- `docs/user/backups-and-disaster-recovery.md` (line 48) — references
  `scripts/restore-volume.sh`.
- `docs/user/persistent-storage.md` (line 235) — references `scripts/restore-volume.sh`.

These three are updated in M3.

### The test file

`cli/nagarectl/test/Spec.hs` is a single `tasty` test tree. The `main` builds one big
`testGroup` whose children are per-module sub-groups (e.g. `testGroup "Nagare.Storage.Snapshot"
storageSnapshotTests`, `testGroup "Nagare.Database.Backup/Restore (EP-47)" backupRestoreTests`).
Renderer assertions follow a pattern: build a fixture inputs record, render to YAML bytes,
decode to `Text` with `TE.decodeUtf8`, then `assertBool "..." (... \`T.isInfixOf\` y)`. Existing
fixtures `backupJobInputsPg :: BackupJobInputs` (line 1970) and `restoreJobInputsPg ::
RestoreJobInputs` (line 1987) show the style, and `backupRestoreTests` already asserts the
backup Job contains `"metadata.google.internal"`. M4 adds the parallel assertion for the
snapshot and storage-restore renderers, and groups all four under one recurrence-prevention
test.


## Plan of Work

The work is four milestones. M1 creates the shared abstraction and refactors the existing
consumers onto it (this is the piece that breaks the import cycle). M2 adds the new volume
restore renderer and CLI verb. M3 deletes the bash scripts and rewrites the docs. M4 adds the
test that prevents the `401` regression from ever recurring in one renderer while another is
fixed. Each milestone leaves the tree building and the test suite green.


### Milestone M1 — The shared `Nagare.Cluster.GcsJob` module; refactor the three existing consumers; break the cycle

Goal: a new leaf module renders the canonical GCS-Job scaffolding once, and the three existing
renderers consume it with their duplicated helpers removed. At the end, `cabal build
exe:nagarectl` reports no module cycle, `cabal test nagarectl-test` is green, and grepping the
source shows exactly one definition of the `metadata.google.internal` `hostAliases` literal.

What will exist that did not before: `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs`, listed in
`nagarectl.cabal`, exporting at minimum:

```haskell
module Nagare.Cluster.GcsJob
  ( metadataHostAliases   -- :: Value
  , metadataEnv           -- :: Text -> [Value]   (the GCE_METADATA_HOST + CLOUDSDK_CORE_PROJECT pair, given the project)
  , gcsContainerImage     -- :: Text              ("google/cloud-sdk:slim")
  , dataMovementJobSpec   -- :: DataMovementJob -> Value   (the full .spec body)
  ) where
```

Design the module so that it owns the *whole* `.spec` body, not merely the `hostAliases`
fragment, so the `restartPolicy: Never` / `backoffLimit: 0` shape and the `hostAliases` cannot
drift between renderers. Introduce a small record describing the per-Job variation:

```haskell
-- | The parts of a GCS data-movement Job that vary across renderers. The shared
-- scaffolding (restartPolicy: Never, backoffLimit: 0, the metadata hostAliases) is
-- supplied by 'dataMovementJobSpec'; the caller supplies only the variable pieces.
data DataMovementJob = DataMovementJob
  { dmjTemplateLabels :: !(Maybe Value)  -- ^ optional pod-template metadata.labels
  , dmjInitContainers :: ![Value]        -- ^ zero or more initContainers
  , dmjContainers     :: ![Value]        -- ^ one or more containers
  , dmjVolumes        :: ![Value]        -- ^ pod volumes (emptyDir / PVC)
  }
```

`dataMovementJobSpec` assembles:

```haskell
dataMovementJobSpec :: DataMovementJob -> Value
dataMovementJobSpec j =
  object
    [ "backoffLimit" .= (0 :: Int)
    , "template" .= object
        ( maybe [] (\ls -> ["metadata" .= object ["labels" .= ls]]) (dmjTemplateLabels j)
            ++
            [ "spec" .= object
                ( [ "restartPolicy" .= ("Never" :: Text)
                  , "hostAliases" .= metadataHostAliases
                  ]
                    ++ ["initContainers" .= toJSON (dmjInitContainers j) | not (null (dmjInitContainers j))]
                    ++ [ "containers" .= toJSON (dmjContainers j)
                       , "volumes" .= toJSON (dmjVolumes j)
                       ]
                )
            ]
        )
    ]
```

`metadataHostAliases` is the exact `Value` currently in `Database.Backup` (verbatim copy of
the literal). `metadataEnv project` returns the two env entries
`[{name: GCE_METADATA_HOST, value: "169.254.169.254"}, {name: CLOUDSDK_CORE_PROJECT, value:
project}]` so callers append it to their container `env` rather than spelling the literals
out. `gcsContainerImage = "google/cloud-sdk:slim"`. The module imports only Aeson and the DSL
prelude (`Nagare.Dsl.Prelude hiding ((.=))`, matching the other renderers) and **must not**
import any `Nagare.Database.*` or `Nagare.Storage.*` module — that is what keeps it a leaf.

Exact edits:

1. Create the module file with the above. Mirror the file header/pragma style of the existing
   renderers: `{-# LANGUAGE PackageImports #-}`, the `import Nagare.Dsl.Prelude hiding ((.=))`
   line, `import Data.Aeson (Value, object, toJSON, (.=))`, and `import Data.Text (Text)` as
   needed. Add a Haddock module comment explaining (in plain words) the metadata-auth problem
   this module centralizes and that it sits below `Database` and `Storage` to break the cycle.

2. In `cli/nagarectl/nagarectl.cabal`, add `Nagare.Cluster.GcsJob` to the `exposed-modules:`
   list under `library` (alphabetically before `Nagare.Database.Backup`).

3. Refactor `cli/nagarectl/src/Nagare/Database/Backup.hs`:
   - Add `import Nagare.Cluster.GcsJob (dataMovementJobSpec, metadataEnv, gcsContainerImage,
     DataMovementJob (..))`.
   - Delete the local `metadataHostAliases` definition (lines ~206–217) and remove it from the
     module export list (line ~34). (Callers — `Database.Restore` — will import it from the
     shared module instead; see edit 4.)
   - Rewrite `backupJobSpecValue` to build a `DataMovementJob` and call `dataMovementJobSpec`,
     instead of spelling out `restartPolicy`/`hostAliases` inline. The `initContainers` is
     `[dumpContainer i]`, the `containers` is `[uploadContainer i]`, the `volumes` is the
     `dump` `emptyDir`, and `dmjTemplateLabels = Just (labelsValue i)`.
   - In `uploadContainer`, replace the two inline `plainEnv "GCE_METADATA_HOST" ...` /
     `plainEnv "CLOUDSDK_CORE_PROJECT" ...` entries with `metadataEnv (bjiProject i)` appended
     to the data env list (`DEST`/`PREFIX`/`KEEP`). Replace the literal
     `"google/cloud-sdk:slim"` image with `gcsContainerImage`.

4. Refactor `cli/nagarectl/src/Nagare/Database/Restore.hs`:
   - Change the import on line 34 from `import Nagare.Database.Backup (backupExt, backupRawExt,
     dbBackupGsUrl, metadataHostAliases)` to drop `metadataHostAliases`, and add
     `import Nagare.Cluster.GcsJob (dataMovementJobSpec, metadataEnv, gcsContainerImage,
     DataMovementJob (..))`.
   - Rewrite `renderRestoreJob`'s `.spec` to call `dataMovementJobSpec` with
     `dmjInitContainers = [downloadContainer i]`, `dmjContainers = [restoreContainer i]`,
     `dmjVolumes = [the dump emptyDir]`, `dmjTemplateLabels = Just labels`.
   - In `downloadContainer`, replace the inline metadata env entries with
     `metadataEnv (rjiProject i)`, and replace the `"google/cloud-sdk:slim"` literal with
     `gcsContainerImage`.

5. Refactor `cli/nagarectl/src/Nagare/Storage/Snapshot.hs`:
   - Add `import Nagare.Cluster.GcsJob (dataMovementJobSpec, metadataEnv, gcsContainerImage,
     DataMovementJob (..))`.
   - Delete the local `metadataHostAliases` definition in the `jobValue` `where`-clause (lines
     ~196–208) and the stale comment about the cycle.
   - Rewrite `jobValue`'s `.spec` to call `dataMovementJobSpec` with no initContainers, one
     `snapshot` container, and the PVC volume. Snapshot has no pod-template labels today, so
     `dmjTemplateLabels = Nothing` (this preserves the current output exactly).
   - In the snapshot container, replace the inline `GCE_METADATA_HOST`/`CLOUDSDK_CORE_PROJECT`
     env entries with `metadataEnv (sjiProject i)`, and replace the `"google/cloud-sdk:slim"`
     literal with `gcsContainerImage`.

Acceptance:

```bash
cd cli/nagarectl
cabal build exe:nagarectl
cabal test nagarectl-test
```

`cabal build` completes with **no** "Module graph contains a cycle" error. `cabal test`
reports the same 258 tests passing (M1 changes the internals but is designed to preserve every
renderer's byte output, so the existing golden/`isInfixOf` assertions still hold). Prove the
de-duplication:

```bash
grep -rn 'metadata.google.internal' cli/nagarectl/src/
```

Expected: exactly one source line (the `metadataHostAliases` literal in
`Nagare/Cluster/GcsJob.hs`); none in `Database/Backup.hs`, `Database/Restore.hs`, or
`Storage/Snapshot.hs`.

Note on output stability: M1 must not change the rendered YAML for the existing three Jobs. The
field assembly order in `dataMovementJobSpec` is chosen to match each renderer's current order
(`restartPolicy`, `hostAliases`, then `initContainers`, `containers`, `volumes`). If any
existing assertion in `backupRestoreTests` or `storageSnapshotTests` fails, treat the
difference as a regression in the shared assembly, not in the test, and fix the assembly order
— unless a deliberate change is recorded in the Decision Log.


### Milestone M2 — `Nagare.Storage.Restore` renderer and the `nagarectl storage restore` verb

Goal: a new typed renderer + driver and a new CLI verb give volume restore the same
scratch-first treatment that `nagarectl db restore` already has, all rendered through the
shared module from M1. At the end, `nagarectl storage restore --help` lists the verb, and
`nagarectl storage restore myapp data <id> --dry-run` prints a Job manifest containing the
`metadata.google.internal` `hostAliases`, the `google/cloud-sdk:slim` image, and a scratch PVC.

What will exist that did not before: `cli/nagarectl/src/Nagare/Storage/Restore.hs` (added to
`nagarectl.cabal`) and a new `StorageRestore` constructor wired into `app/Main.hs`.

The renderer mirrors `Nagare.Database.Restore` (scratch-first) but for a volume. The model is
the deleted `scripts/restore-volume.sh`: it (1) applies a disposable scratch PVC and (2) runs
a one-off Job that streams the `tar.gz` from GCS and untars it into that scratch PVC, then
lists the restored tree. By default the restore lands in a scratch PVC; `--into-live` restores
into the live PVC.

Define the renderer module `Nagare.Storage.Restore` exporting:

```haskell
module Nagare.Storage.Restore
  ( StorageRestoreJobInputs (..)
  , renderStorageRestoreJob   -- :: StorageRestoreJobInputs -> ByteString  (the Job YAML)
  , renderScratchPvc          -- :: Text -> Text -> Text -> ByteString     (ns, name, size)
  , runStorageRestore         -- :: Deployment -> Text -> Text -> Bool -> Text -> Text -> Bool -> IO ()
  ) where
```

with inputs:

```haskell
data StorageRestoreJobInputs = StorageRestoreJobInputs
  { sriNamespace :: !Text
  , sriJobName   :: !Text
  , sriClaimName :: !Text   -- ^ the PVC the restore writes into (scratch or live)
  , sriSrcUrl    :: !Text   -- ^ the gs:// tar.gz object to restore
  , sriMountPath :: !Text   -- ^ in-Job mount path, e.g. /restore
  , sriProject   :: !Text   -- ^ CLOUDSDK_CORE_PROJECT
  }
  deriving stock (Generic, Eq, Show)
```

`renderStorageRestoreJob` builds a single `restore` container on
`gcsContainerImage`, command `/bin/sh -c`, args a shell equal to the script's:

```text
set -e; gsutil cp "$SRC" - | tar -C <mount> -xzf -; echo '--- restored tree (first 50 entries) ---'; find <mount> -maxdepth 3 | head -50
```

env `plainEnv "SRC" (sriSrcUrl i)` appended with `metadataEnv (sriProject i)`, a `volumeMount`
of the `restore` volume at `sriMountPath`, and a single pod volume that is a
`persistentVolumeClaim` with `claimName = sriClaimName i`. The whole `.spec` comes from
`dataMovementJobSpec` (M1) with `dmjInitContainers = []`. Labels:
`{ nagare.dev/managed-by: nagarectl }`, matching the snapshot Job.

`renderScratchPvc ns name size` renders the disposable PVC YAML the script created
(`storageClassName: local-path`, `accessModes: [ReadWriteOnce]`, `resources.requests.storage =
size`, labels `nagare.dev/managed-by: nagarectl` and `nagare.dev/restore-scratch: "true"`).

The driver `runStorageRestore dep volume backupId live bucket project dryRun`:
1. Resolve `app = serviceNameText (dep ^. #name)`, `ns = namespaceText (dep ^. #namespace)`.
   Validate `volume` is in `map (volumeNameText . (^. #volName)) (dep ^. #volumes)`, erroring
   like `runSnapshot` does if not.
2. Resolve the live PVC name with `pvcName app volume` (from `Nagare.Storage.Discover`).
   The target claim is the live PVC when `live`, else a scratch PVC named
   `pvcName app volume <> "-restore-scratch"` (truncated to the 63-char Kubernetes name limit
   with `T.take 63 . T.toLower`, mirroring the job-name handling in the other drivers).
3. Resolve the `gs://` source. `backupId` may be a full `gs://` URL (used verbatim) or a bare
   timestamp composed against the bucket/app/volume via `snapshotGsUrl bucket app volume
   backupId` (re-use `Nagare.Storage.Snapshot.snapshotGsUrl`; note this introduces a
   `Storage.Restore -> Storage.Snapshot` import, which is fine — both sit *above* the leaf
   `Cluster.GcsJob`, and `Snapshot` does not import `Restore`, so no cycle). Reuse the
   `isGsUrl` predicate (either import `Nagare.Database.Restore (isGsUrl)` or define a local
   one; importing is simpler and `Database.Restore` is already above `Cluster.GcsJob`).
4. Compute a timestamped `jobName` like `T.take 63 (T.toLower ("nagare-volrestore-" <> app <>
   "-" <> volume <> "-" <> ts))` using `snapshotTimestamp now`.
5. If `dryRun`: print the scratch-PVC manifest (when not `--into-live`) and the Job manifest;
   apply nothing. Else: when not `live`, `kubectl apply` the scratch PVC first; `kubectl apply`
   the Job; `waitForJob`; print the Job logs (the restored tree listing); delete the Job
   (`--ignore-not-found`). Mirror the apply/wait/logs/delete IO helpers already present in
   `Nagare.Storage.Snapshot` / `Nagare.Database.Restore` (they are private there; copy the
   small `applyJob`/`waitForJob`/`die` helpers into this module, matching the repo's existing
   "local copies" convention).
6. On success, print guidance: when scratch, `"Restored <app>/<volume> into scratch PVC
   '<scratch>' — compare the listing above, then promote manually."`; when live, a louder
   `"Restored <app>/<volume> into the LIVE PVC '<pvc>'."`.

Exact CLI wiring in `cli/nagarectl/app/Main.hs`:

1. Add to the `data StorageCommand` type (around line 372) a new constructor:
   `| StorageRestore StoreCommonOpts String String (Maybe String) Bool Bool`
   — the fields are `VOLUME`, `BACKUP_ID`, `--bucket`, `--into-live`, `--dry-run`. (Match the
   tuple-style other `Storage*` constructors use; or, preferred, introduce a small
   `StorageRestoreOpts` record like `DbRestoreOpts` to keep the call site readable — pick one
   and keep it consistent with `DbRestore`.)
2. In `storageSubparser` (around line 1289), add a `command "restore"` alongside `list`,
   `inspect`, `snapshot`. Its parser takes `storeCommonOptsParser`, a `VOLUME` `strArgument`, a
   `BACKUP_ID` `strArgument` (`help "Snapshot timestamp (or full gs:// URL) to restore"`), the
   `--bucket` `strOption` (reuse the same help text as snapshot), a `switch (long "into-live"
   <> help "Restore into the LIVE volume PVC (default: a scratch PVC)")`, and `dryRunOpt`.
   `progDesc "Restore a volume snapshot from GCS into a scratch PVC (or --into-live)"`.
3. Add the import `import Nagare.Storage.Restore (runStorageRestore)` near the other
   `Nagare.Storage.*` imports (around line 183).
4. Extend `runStorage` (around line 2355) with the new case, following the `StorageSnapshot`
   pattern exactly:

```haskell
StorageRestore copts vol backupId bucket live dryRun -> do
  dep <- resolveStorageDep copts
  tp <- resolveTargetProfile
  b <- resolveBackupBucket bucket
  runStorageRestore dep (T.pack vol) (T.pack backupId) live b (tpProject tp) dryRun
```

5. Add `Nagare.Storage.Restore` to `exposed-modules:` in `nagarectl.cabal`.

Acceptance:

```bash
cd cli/nagarectl
cabal build exe:nagarectl
cabal run exe:nagarectl -- storage restore --help
```

The `--help` output shows the `restore` verb with `VOLUME`, `BACKUP_ID`, `--bucket`,
`--into-live`, and `--dry-run`. A dry run prints a manifest you can eyeball (run it against any
example app config that declares a volume, e.g. `cluster/examples/uploads-volume`):

```bash
cabal run exe:nagarectl -- storage restore <app> <volume> 20260101T000000Z --dry-run \
  --file <path-to-Config.hs>
```

Expected manifest fragments: `kind: Job`, `image: google/cloud-sdk:slim`,
`hostAliases:` with `metadata.google.internal`, `claimName: <pvc>-restore-scratch`, and a
preceding scratch-PVC manifest with `nagare.dev/restore-scratch: "true"`. With `--into-live`,
no scratch PVC is printed and the `claimName` is the live PVC.


### Milestone M3 — Delete the four bash scripts; rewrite the runbook and user docs

Goal: the four hand-rolled scripts are gone, and every doc that referenced them now calls the
equivalent `nagarectl` verb, with disaster recovery explicitly listing `nagarectl` as a
prerequisite. At the end, `git grep` finds no reference to the deleted scripts anywhere in
`scripts/` or `docs/runbooks/` or `docs/user/`.

Exact edits:

1. Delete the files:

```bash
git rm scripts/restore-volume.sh scripts/backup-postgres.sh \
       scripts/restore-postgres.sh scripts/restore-sqlite.sh
```

   (`scripts/lib/target.sh` is **not** deleted.)

2. `docs/runbooks/disaster-recovery.md`:
   - In the "Backup inventory" table, change the three "how it is restored" cells:
     - SQLite: `-> nagarectl storage restore <app> <volume> <id> (scratch)` if the SQLite db
       lives on an app volume; otherwise keep the Litestream description but note the restore is
       now manual (`litestream restore` invoked directly) — the SQLite scratch script is gone.
       (Pick the wording that matches how SQLite is actually backed up in this repo; the
       managed path is the app-volume snapshot. State plainly that the old
       `scripts/restore-sqlite.sh` helper is removed and the equivalent is the documented
       `litestream restore` one-liner or `nagarectl storage restore`.)
     - Postgres: `-> nagarectl db restore <name> <id> (scratch)` (managed databases) — and note
       the host-side `scripts/restore-postgres.sh` / `scripts/backup-postgres.sh` helpers are
       removed; managed-DB backup/restore is the supported path.
     - App volume: `-> nagarectl storage restore <app> <volume> <id> (scratch)`.
   - In step 7 ("Restore data"), replace the three script invocations:

```bash
# App volume (EP-36) into a SCRATCH PVC, eyeball the restored tree, then promote:
nagarectl storage restore <app> <volume> <latest-id> --file <path-to-Config.hs>
# Managed database (EP-47) into a SCRATCH target, compare, then promote manually:
nagarectl db restore <name> "$(gsutil ls gs://$BACKUP_BUCKET/databases/<name>/ | tail -1)"
```

     For Postgres/SQLite that previously used the deleted scripts, document the
     `nagarectl`-verb or direct-`litestream` equivalent and remove the script lines.
   - Add a short prerequisite note near the top of the runbook (e.g. just after the dev-shell
     paragraph): "**`nagarectl` is a disaster-recovery prerequisite.** The restore steps below
     call `nagarectl` verbs (`db restore`, `storage restore`) directly; the former
     hand-rolled `scripts/restore-*.sh` helpers have been removed so that all control-plane
     logic lives in the typed CLI. Build it once with `cabal build exe:nagarectl` in
     `cli/nagarectl/` (inside `nix develop`), or have it on `PATH`, before starting a
     restore."
   - Leave the "In-pod GCS auth (fixed 2026-06-10)" note, but you may append one sentence that
     the `hostAliases` is now rendered by the shared `Nagare.Cluster.GcsJob` module for every
     data-movement Job.

3. `docs/user/backups-and-disaster-recovery.md` (line ~48): replace
   `scripts/restore-volume.sh gs://…/<ts>.tar.gz` with
   `nagarectl storage restore <app> <volume> <ts>` (note it restores into a scratch PVC by
   default; `--into-live` targets the live PVC).

4. `docs/user/persistent-storage.md` (line ~235): replace the
   `scripts/restore-volume.sh gs://…/<timestamp>.tar.gz` reference with the
   `nagarectl storage restore <app> <volume> <timestamp>` verb and the same scratch-first
   wording.

Acceptance:

```bash
git grep -n 'restore-volume.sh\|backup-postgres.sh\|restore-postgres.sh\|restore-sqlite.sh' \
  -- scripts/ docs/runbooks/ docs/user/
```

Expected: no output (the only remaining matches in the repo are in `docs/masterplans/` and
`docs/plans/` — historical plan text, which is acceptable to leave). The runbook now contains
the `nagarectl`-prerequisite note and the `nagarectl storage restore` / `nagarectl db restore`
invocations.


### Milestone M4 — Recurrence-prevention test: every data-movement Job renderer emits the metadata `hostAliases`

Goal: a single test exercises **all four** data-movement Job renderers and asserts each
rendered manifest contains the `metadata.google.internal` `hostAliases` and the
`google/cloud-sdk:slim` image, so the `401 Anonymous` bug cannot recur in one renderer while
another is fixed. At the end, `cabal test nagarectl-test` runs the new test and is green; if
any renderer is later changed to drop the `hostAliases`, this test fails.

What will exist that did not before: a new `testGroup` (e.g. `gcsJobHostAliasesTests`) added to
the top-level tree in `main`, and a `StorageRestoreJobInputs` fixture in the test file.

Exact edits to `cli/nagarectl/test/Spec.hs`:

1. Add imports for the new renderer: `import Nagare.Storage.Restore (StorageRestoreJobInputs
   (..), renderStorageRestoreJob)`. Ensure `renderSnapshotJob` and `SnapshotJobInputs` are
   imported (the `Nagare.Storage.Snapshot` import block at line ~159 — add them if absent), and
   `renderBackupJob`/`renderRestoreJob` (already imported).
2. Add fixtures: a `snapshotJobInputs :: SnapshotJobInputs` and a `storageRestoreJobInputs ::
   StorageRestoreJobInputs`, alongside the existing `backupJobInputsPg` / `restoreJobInputsPg`.
3. Add the test group:

```haskell
gcsJobHostAliasesTests :: [TestTree]
gcsJobHostAliasesTests =
  [ testCase (name <> " renders the metadata hostAliases and the cloud-sdk image") $ do
      let y = TE.decodeUtf8 rendered
      assertBool "hostAliases for metadata.google.internal"
        ("metadata.google.internal" `T.isInfixOf` y)
      assertBool "metadata IP" ("169.254.169.254" `T.isInfixOf` y)
      assertBool "cloud-sdk image" ("google/cloud-sdk:slim" `T.isInfixOf` y)
      assertBool "restartPolicy Never" ("Never" `T.isInfixOf` y)
  | (name, rendered) <-
      [ ("db backup Job",      renderBackupJob backupJobInputsPg)
      , ("db restore Job",     renderRestoreJob restoreJobInputsPg)
      , ("volume snapshot Job", renderSnapshotJob snapshotJobInputs)
      , ("volume restore Job",  renderStorageRestoreJob storageRestoreJobInputs)
      ]
  ]
```

4. Register it in `main`'s top-level `testGroup` list (near the other renderer groups, e.g.
   after `testGroup "Nagare.Storage.Snapshot" storageSnapshotTests`):
   `, testGroup "GCS data-movement Job hostAliases (EP-1)" gcsJobHostAliasesTests`.

This intentionally drives all four renderers through the same assertion table, so adding a
fifth data-movement renderer later means adding one row here — the natural place to keep the
guarantee centralized.

Acceptance:

```bash
cd cli/nagarectl
cabal test nagarectl-test
```

Expected: the suite passes, now with four additional cases under "GCS data-movement Job
hostAliases (EP-1)". To prove the test actually guards the regression, temporarily delete the
`"hostAliases" .= metadataHostAliases` line from `Nagare.Cluster.GcsJob.dataMovementJobSpec`,
re-run `cabal test nagarectl-test`, and observe **all four** new cases fail (every renderer
loses the `hostAliases` at once, because they all render through the shared module) — then
restore the line. Record that demonstration in Surprises & Discoveries.


## Concrete Steps

Run everything from `cli/nagarectl/` inside the Nix dev shell (`nix develop`, or `direnv
allow` once at the repo root). The full sequence:

```bash
cd cli/nagarectl

# M1
cabal build exe:nagarectl      # must NOT print "Module graph contains a cycle"
cabal test nagarectl-test      # still 258 green
grep -rn 'metadata.google.internal' src/   # expect exactly one hit: Nagare/Cluster/GcsJob.hs

# M2
cabal build exe:nagarectl
cabal run exe:nagarectl -- storage restore --help          # shows the new verb
cabal run exe:nagarectl -- storage restore <app> <vol> <id> --dry-run --file <Config.hs>

# M3 (run from repo root)
cd ../..
git rm scripts/restore-volume.sh scripts/backup-postgres.sh \
       scripts/restore-postgres.sh scripts/restore-sqlite.sh
git grep -n 'restore-volume.sh\|backup-postgres.sh\|restore-postgres.sh\|restore-sqlite.sh' \
  -- scripts/ docs/runbooks/ docs/user/                    # expect no output

# M4
cd cli/nagarectl
cabal test nagarectl-test      # now 262 green (258 + 4 hostAliases cases)
```

Expected transcript shape for the dry run (abridged):

```text
--- Scratch PVC manifest ---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc>-restore-scratch
  labels:
    nagare.dev/restore-scratch: "true"
...
--- Restore Job manifest ---
apiVersion: batch/v1
kind: Job
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      hostAliases:
      - ip: 169.254.169.254
        hostnames:
        - metadata.google.internal
      containers:
      - name: restore
        image: google/cloud-sdk:slim
        ...
```


## Validation and Acceptance

The change is internal plumbing plus one new user-visible verb, so prove it three ways, each a
behavior a human can check:

1. **The cycle is gone and the helper is de-duplicated.** `cabal build exe:nagarectl` succeeds
   with no "Module graph contains a cycle" diagnostic, and `grep -rn 'metadata.google.internal'
   cli/nagarectl/src/` returns exactly one line, in `Nagare/Cluster/GcsJob.hs`. Before this
   plan the literal appears in three source files (and the audit proved you *cannot* simply
   import it across `Database`↔`Storage`); after, it appears once.

2. **The new verb exists and renders the auth scaffolding.** `nagarectl storage restore --help`
   lists `restore` with its arguments and flags. `nagarectl storage restore <app> <vol> <id>
   --dry-run` prints a Job whose pod spec contains the `metadata.google.internal` `hostAliases`,
   `image: google/cloud-sdk:slim`, `restartPolicy: Never`, `backoffLimit: 0`, and a
   `claimName` of `<pvc>-restore-scratch` (or the live PVC under `--into-live`).

3. **The regression guard runs and bites.** `cabal test nagarectl-test` is green with four new
   "GCS data-movement Job hostAliases" cases. Temporarily removing the shared `hostAliases`
   line makes all four fail at once; restoring it makes them pass — demonstrating that the
   guarantee is centralized and enforced for every renderer.

There is no live-cluster step in this plan: rendering, the cycle break, and the verb wiring are
all verifiable offline. The live exercise of the rendered Jobs (a real snapshot + restore round
trip against `nagare-01`) belongs to EP-5 (`docs/plans/69-ci-pipeline-and-live-smoke-test.md`),
which consumes this module's output but does not edit it.


## Idempotence and Recovery

All edits are additive-then-subtractive and safe to re-run. Creating `Nagare.Cluster.GcsJob`
and refactoring the consumers is a pure code change validated by `cabal build`/`cabal test`; if
a refactor changes a renderer's byte output, the existing assertions fail loudly and you adjust
the shared assembly order (see the M1 note on output stability) rather than the test.

Deleting the four scripts (`git rm`) is reversible with `git checkout -- <path>` until the
commit; nothing on the cluster depends on the scripts at runtime (no systemd timer or
`justfile` target invokes them — verified). The doc rewrites are plain Markdown edits.

The new `storage restore` driver is scratch-first by default: an aborted or botched restore
writes only to a disposable `<pvc>-restore-scratch` PVC and never touches live data unless
`--into-live` is passed. Re-running the verb re-applies the scratch PVC (`kubectl apply` is
idempotent) and re-runs the Job (the driver deletes the prior Job with `--ignore-not-found`
first, as the existing snapshot/restore drivers do). `--into-live` is the only destructive
path and prints a loud confirmation line in its output.


## Interfaces and Dependencies

Libraries already in `cli/nagarectl/nagarectl.cabal` and reused here: `aeson` (JSON
`Value`/`object`/`(.=)`), `yaml` (`Data.Yaml.encode` to serialize the `Value` to a manifest),
`bytestring`, `text`, `time` (`getCurrentTime` for the timestamp), `cradle` (the `kubectl`
process runner: `cmd`, `addArgs`, `run`, `run_`, `silenceStderr`), `temporary`
(`withSystemTempFile` for applying a manifest), and `nagare-dsl` (`Nagare.Dsl.Prelude`,
`Nagare.Dsl.Types`). No new dependency is added.

Module-graph contract (MasterPlan 13 Integration Point #1): the new module
`Nagare.Cluster.GcsJob` is **owned solely by this plan**. It sits *below* both
`Nagare.Database.*` and `Nagare.Storage.*` and imports neither, which is what breaks the
existing `Nagare.Database.Backup`↔`Nagare.Storage.Snapshot` cycle. Its consumers are exactly
`Nagare.Database.Backup`, `Nagare.Database.Restore`, `Nagare.Storage.Snapshot`, and the new
`Nagare.Storage.Restore`. EP-5 (`docs/plans/69-ci-pipeline-and-live-smoke-test.md`) exercises
the rendered Jobs via a live smoke test but does not edit this module.

Signatures that must exist at the end of each milestone:

End of M1, in `Nagare.Cluster.GcsJob`:

```haskell
metadataHostAliases :: Value
metadataEnv         :: Text -> [Value]
gcsContainerImage   :: Text
data DataMovementJob = DataMovementJob
  { dmjTemplateLabels :: !(Maybe Value)
  , dmjInitContainers :: ![Value]
  , dmjContainers     :: ![Value]
  , dmjVolumes        :: ![Value]
  }
dataMovementJobSpec :: DataMovementJob -> Value
```

and the three existing renderers (`backupJobSpecValue`, `renderRestoreJob`,
`Nagare.Storage.Snapshot` internal `jobValue`) call `dataMovementJobSpec` with their
per-Job pieces; no module under `src/` defines a second `metadata.google.internal` literal.

End of M2, in `Nagare.Storage.Restore`:

```haskell
data StorageRestoreJobInputs = StorageRestoreJobInputs
  { sriNamespace :: !Text
  , sriJobName   :: !Text
  , sriClaimName :: !Text
  , sriSrcUrl    :: !Text
  , sriMountPath :: !Text
  , sriProject   :: !Text
  }
renderStorageRestoreJob :: StorageRestoreJobInputs -> ByteString
renderScratchPvc        :: Text -> Text -> Text -> ByteString
runStorageRestore       :: Deployment -> Text -> Text -> Bool -> Text -> Text -> Bool -> IO ()
```

and in `app/Main.hs` a `StorageRestore` constructor on `StorageCommand`, a `command "restore"`
in `storageSubparser`, and a matching `runStorage` case calling `runStorageRestore`.

End of M4, in `cli/nagarectl/test/Spec.hs`: a `gcsJobHostAliasesTests :: [TestTree]` group,
registered in `main`, that drives `renderBackupJob`, `renderRestoreJob`, `renderSnapshotJob`,
and `renderStorageRestoreJob` through one `metadata.google.internal` / `google/cloud-sdk:slim`
/ `restartPolicy: Never` assertion table.
