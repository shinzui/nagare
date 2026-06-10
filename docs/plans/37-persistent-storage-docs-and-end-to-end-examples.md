---
id: 37
slug: persistent-storage-docs-and-end-to-end-examples
title: "Persistent storage docs and end-to-end examples"
kind: exec-plan
created_at: 2026-06-10T00:44:35Z
intention: "intention_01ktqfjpdqewga3t0rm9crehxx"
master_plan: "docs/masterplans/7-persistent-storage-for-nagare.md"
---

# Persistent storage docs and end-to-end examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the fifth and final child of the MasterPlan at
`docs/masterplans/7-persistent-storage-for-nagare.md` ("Persistent Storage for Nagare"). The
persistent-storage *behavior* is built by its sibling plans: the cluster enablement spike
(`docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md`), the typed volume model and
renderer (`docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md`), deploy-time
PVC provisioning and the read-only storage commands
(`docs/plans/35-deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands.md`), and the
backup-ownership policy with snapshots
(`docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md`). This plan makes that
behavior **discoverable and learnable**: it writes the user guide, extends the config and operator
references, and ships two runnable, deployable example apps that prove the whole pipeline end to end.

This plan **hard-depends** on EP-35 and EP-36 — a docs plan must describe commands that actually work, so
the read-only `nagarectl storage list|inspect` (EP-35), deploy-time PVC provisioning (EP-35), and
`nagarectl storage snapshot` plus the backup-ownership warning and restore procedure (EP-36) must already
exist. It **soft-depends** on EP-34 (the typed `Volume` model) so the config reference can document the
`volumes` field accurately; if EP-34's exact constructor or accessor names differ from what this plan
assumes, reconcile against EP-34's final Interfaces section before writing the Haskell snippets, and update
this plan's Decision Log with any name change. The contract this plan relies on is fixed by the
MasterPlan's Integration Points IP1–IP5 (`docs/masterplans/7-persistent-storage-for-nagare.md`), which are
reproduced where needed below so this plan is self-contained.


## Purpose / Big Picture

Today a Nagare application is **stateless**: a developer writes a typed `nagare/Config.hs`, runs
`nagarectl deploy`, and gets a Knative Service whose container filesystem is wiped on every pod restart or
scale-to-zero. The Persistent Storage initiative changes that — an app can now declare a durable disk in
its typed config, and the platform provisions it, mounts it, lists it, and backs it up. But a capability
nobody can find is a capability that does not exist. This plan is what turns the shipped machinery into
something a developer can actually use without reading Haskell source or the plan files.

After this plan, a developer can open a single new page,
[`docs/user/persistent-storage.md`](../user/persistent-storage.md), and learn the whole story: what a
*volume* and a *PVC* are on this single-node cluster, how to declare a `volumes` entry in `Config.hs`, how
to operate it with `nagarectl storage list|inspect|snapshot`, what the backup-ownership policy guarantees,
and where the restore runbook lives. The typed `Volume` fields are catalogued in
`docs/user/config-reference.md`, the operator quick-lookup `docs/user/reference.md` gains a
`nagarectl storage` command table, the backup guide `docs/user/backups-and-disaster-recovery.md` is
cross-linked for restores, and `docs/user/README.md` indexes the new page.

The proof that the documentation is correct is two **runnable example apps** under `cluster/examples/`:

1. **`sqlite-pvc-litestream`** — a small web app that keeps a SQLite database on a `1Gi` durable volume
   mounted at `/data`, with a Litestream sidecar continuously replicating the database to GCS. Following
   its README, a reader deploys it, writes a row, rolls a new revision (or deletes the pod), and confirms
   the row survives (durable PVC, unlike the old `emptyDir` example) *and* that Litestream replicated to
   `gs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/`.

2. **`uploads-volume`** — a web app that accepts file uploads onto a durable volume mounted at `/uploads`.
   Following its README, a reader deploys it, uploads a file with `curl`, rolls the app, confirms the file
   is still served (durability), then runs `nagarectl storage snapshot uploads-volume uploads`, confirms a
   tarball lands in `gs://tan-nb-exp-nagare-backups/volumes/uploads-volume/uploads/<timestamp>.tar.gz`, and
   walks a restore drill.

You can see this working by following each example README top to bottom against a live cluster: every
command runs and produces the shown output, and data demonstrably survives a revision roll. Where no
cluster is reachable in the implementation environment, the examples are still verifiable offline via
`nagarectl deploy --dry-run` (which renders the PVC + volumeMount YAML without touching a cluster), and the
live legs are marked "verified by dry-run; live run deferred" exactly as the sibling docs plan
`docs/plans/32-application-lifecycle-docs-and-end-to-end-examples.md` recorded a deferred cluster step.

Terms used throughout this plan, defined once here in plain language:

- A **volume** is a durable disk attached to an app. In the typed config it is one entry in the new
  `volumes` list on a `Deployment`; it has a name, a size, a mount path, an access mode, a read-only flag,
  and a retention policy.
- A **PersistentVolumeClaim (PVC)** is the Kubernetes object that requests that durable disk. On this
  single-node k3s cluster a PVC is satisfied by the built-in **`local-path`** StorageClass, which carves a
  directory out of the host data disk at `/var/lib/nagare/local-path` and mounts it into the pod.
- A **mount path** is the in-container directory at which the disk appears, for example `/data`.
- **ReadWriteOnce (RWO)** is the access mode meaning "one node may mount this disk read-write at a time."
  Nagare is intentionally single-node, so every app volume is RWO.
- A **retention policy** says what happens to the underlying disk when the app is deleted: `Retain` (keep
  the disk and its data) or `Delete` (destroy it). This is independent of GCS backups.
- A **snapshot** here means a point-in-time *copy of the volume's files* tarred into the GCS backup bucket.
  It is not a CSI block snapshot (the `local-path` provisioner does not support those); it is a file copy.


## Progress

- [x] M1: `docs/user/persistent-storage.md` written (concepts, typed `volumes` config, `storage`
  commands, backup-ownership policy, restore pointer); linked from `docs/user/README.md` and
  `docs/user/deploying-apps.md`; the typed `Volume` fields documented in `docs/user/config-reference.md`
  (new "Volumes" section); the `nagarectl storage` table added to `docs/user/reference.md`;
  `docs/user/backups-and-disaster-recovery.md` cross-linked (EP-36 added its app-volume row). (2026-06-09;
  reconciled to the real API — `attachVolume`, not `mkVolume`; raw `Volume` literal for a `Delete`/excluded
  volume; real `--dry-run` output format; rollout-scaling note.)
- [x] M2: `cluster/examples/sqlite-pvc-litestream/` built — `nagare/Config.hs` (`attachVolume "data" "1Gi"
  "/data"`), a dependency-free `app.py` (stdlib SQLite HTTP server) + `Dockerfile`, `litestream.yml`, and a
  README contrasting durable PVC vs the old `emptyDir` example. Dry-run verified (renders the `1Gi`
  `local-path` PVC + `/data` mount); live deploy/roll/Litestream legs deferred (cluster access). The
  Litestream sidecar is a documented supplementary step (the DSL has no sidecar field — see Surprises).
- [x] M3: `cluster/examples/uploads-volume/` built — `nagare/Config.hs` (`attachVolume "uploads" "1Gi"
  "/uploads"`), a dependency-free `app.py` (stdlib upload server) + `Dockerfile`, and a README with the
  upload → roll → snapshot → restore-drill walk-through. Dry-run verified (renders the `/uploads` PVC +
  mount); live deploy/snapshot/restore legs deferred (cluster access).


## Surprises & Discoveries

- **The shipped API is `attachVolume`, not `mkVolume`.** EP-34 shipped
  `attachVolume :: Text -> Text -> Text -> Deployment -> Either Text Deployment` (name, size,
  mountPath; defaults RWO / not-read-only / `Retain`) — there is no `mkVolume name size mountPath
  retention`. The docs and example configs use `webService … >>= attachVolume "data" "1Gi" "/data"`.
  Because `attachVolume` only builds `Retain` volumes, the docs show a raw `Volume` record literal
  (`Volume(..)` + `mkVolumeName`/`mkQuantity`/`mkMountPath`, all exported) for a `Delete`/backup-excluded
  volume. **Follow-up for EP-34:** an `attachVolumeWith retention …` or `attachVolumeExcluded` preset
  would make opting out ergonomic; logged here and in EP-36.

- **Attaching a volume overrides the app's `scale`** (EP-34/EP-33): any volume-bearing Service renders
  `min-scale = 1` / `max-scale = 1` / `rollout-duration = 0s` (single-writer + stay-warm). The guide
  calls this out explicitly so users aren't surprised their `scale` is ignored. The real `--dry-run`
  output (captured into the docs) confirms it.

- **The typed model has no sidecar field, so the SQLite example's Litestream is a documented
  supplementary step,** not part of `Config.hs`. The example ships `litestream.yml` and the README
  shows adding the Litestream container to the deployed Service (referencing the old
  `sqlite-litestream/deployment.yaml` sidecar spec). The typed config's job is the durable PVC; the
  continuous-backup sidecar is layered on. (Matches the plan's allowance for this limitation.)

- **The examples are real, dependency-free stdlib Python apps with a Dockerfile** (built by
  `webService`'s default Dockerfile build), not third-party images — a Knative Service needs an HTTP
  server on `$PORT`, and the app must write to the mount path to demonstrate durability. `app.py` for
  each (`py_compile`-clean) is small enough to read in one screen.

- **Concurrent uncommitted work touched `docs/user/README.md` and `config-reference.md`.** During this
  session another process had already added capability-matrix rows (including a now-stale "Persistent
  storage … DSL pending" row) and a deferred-note tweak to those two files (and created the untracked
  MasterPlan-8 / EP-38–42 files). EP-37 edits the same two files; the small pre-existing hunks are
  benign and consistent with EP-37 (I corrected the stale row to "Built; live deploy/snapshot
  pending"), so they are carried in EP-37's docs commit — noted here for honest attribution.


## Decision Log

- Decision: Ship exactly two end-to-end examples — a SQLite-on-PVC app with Litestream continuous backup,
  and an uploaded-files app on a durable volume.
  Rationale: the MasterPlan's Vision & Scope names precisely these two patterns as "two concrete patterns
  end to end" (`docs/masterplans/7-persistent-storage-for-nagare.md`), so documenting both covers the
  roadmap's stated storage use cases. The SQLite example demonstrates the typed volume *and* the backup
  story; the uploads example demonstrates the typed volume *and* the on-demand `nagarectl storage snapshot`
  + restore drill. Together they exercise every storage surface EP-34/35/36 ship.
  Date: 2026-06-09

- Decision: Put the persistent-storage user documentation in a new dedicated page
  `docs/user/persistent-storage.md`, mirroring the other per-feature guides
  (`docs/user/static-hosting.md`, `docs/user/build-modes.md`, `docs/user/secrets.md`), rather than
  expanding `docs/user/deploying-apps.md` in place.
  Rationale: persistent storage is a focused, sizeable sub-topic (concepts + a typed field group + three
  CLI verbs + a backup policy + a restore runbook). Every sibling per-feature initiative finished with its
  own page linked from `deploying-apps.md` and the README index; following that convention keeps the docs
  navigable and consistent.
  Date: 2026-06-09

- Decision: Place the two examples under `cluster/examples/` as **typed Nagare apps** (a `nagare/Config.hs`
  deployed with `nagarectl deploy`), not raw `kubectl apply` manifests.
  Rationale: the existing `cluster/examples/sqlite-litestream/` is a raw-Kubernetes `Deployment` on an
  `emptyDir` (its own comment says "a real app would use a PVC on the data disk"); converting it to a typed
  app on a real PVC proves the whole new pipeline — typed `volumes` → rendered PVC → deploy-time
  provisioning → durable mount → snapshot — which raw YAML cannot demonstrate. This matches how every other
  `cluster/examples/*` project teaches a feature through a runnable typed config.
  Date: 2026-06-09

- Decision: Document the typed `Volume` *fields* in `docs/user/config-reference.md` (the per-field
  constructor catalogue) and the operational `nagarectl storage` *commands* in `docs/user/reference.md`
  (the operator quick-lookup), with the conceptual narrative in the new `docs/user/persistent-storage.md`.
  Rationale: in this repo `config-reference.md` is the catalogue that documents every `Deployment` field
  and its smart constructor (it already covers `build`, `env`, `resources`, `scale`), so the `volumes`
  field belongs there; `reference.md` already carries the `nagarectl site` command table and operator
  identifiers, so the `nagarectl storage` table belongs there. The new guide ties them together for a
  reader learning the feature for the first time. (The MasterPlan's wording "config reference" maps to
  `config-reference.md` in practice.)
  Date: 2026-06-09


## Outcomes & Retrospective

**Result: all three milestones delivered; the persistent-storage feature is now discoverable and
learnable. Docs reconciled to the shipped API; both examples dry-run-verified; live legs deferred to a
running cluster (IAP/cluster-access constraint shared with EP-35/EP-36).**

- **M1 — docs.** New `docs/user/persistent-storage.md` (concepts → typed `volumes` config → offline
  `--dry-run` proof → `nagarectl storage` verbs → backup-ownership policy → restore pointer → two
  worked examples). `config-reference.md` gained a "Volumes" field table; `reference.md` gained a
  `nagarectl storage` command table + PVC-naming/GCS-layout note; `deploying-apps.md` "data tier" and
  `README.md` index link the new page; `backups-and-disaster-recovery.md` is cross-linked (EP-36
  added the row). Every snippet/command matches IP1–IP5 as actually shipped.

- **M2/M3 — examples.** `cluster/examples/sqlite-pvc-litestream/` and `cluster/examples/uploads-volume/`
  are runnable typed Nagare apps (stdlib `app.py` + `Dockerfile` + `nagare/Config.hs` + README), each
  proving durable storage via one `attachVolume` line. Both render the correct `1Gi` `local-path` PVC +
  volumeMount under `nagarectl deploy --dry-run` (verified through the real binary). The SQLite example
  contrasts durable PVC vs the old `emptyDir`/raw-`kubectl` `sqlite-litestream`; the uploads example
  walks snapshot → `gsutil ls` → scratch-first restore.

- **Gaps / follow-ups.** Live deploy/roll/snapshot/restore transcripts are deferred (cluster not
  reachable from a workstation — IAP forwards only SSH/22; run the READMEs on the VM or via an
  SSH-forwarded API port). EP-34 lacks an ergonomic preset for a `Delete`/excluded volume (raw `Volume`
  literal used in docs meanwhile). Litestream remains a documented supplementary sidecar step (no DSL
  sidecar field). These are noted in Surprises and the MasterPlan.


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/nagare`. This plan writes and
edits **Markdown** under `docs/user/` and adds two example directories (`nagare/Config.hs`, a README, and a
small amount of supporting YAML/source) under `cluster/examples/`. It contains **no library code**; it
consumes the behavior the sibling plans ship.

**The user docs directory — `docs/user/`.** It is the developer- and operator-facing guide. The pages
relevant here are `README.md` (the index), `deploying-apps.md` (the first-deploy on-ramp for app
developers), `config-reference.md` (the per-field catalogue of the typed `Deployment` config),
`reference.md` (the operator quick-lookup of fixed identifiers, recipes, and the `nagarectl site` command
table), and `backups-and-disaster-recovery.md` (what to back up and the rebuild-from-zero runbook). The
house style, visible at the top of `deploying-apps.md`, `static-hosting.md`, and `build-modes.md`:

- An H1 title (`# Persistent storage`).
- A `>` status box using one of the badges from `docs/user/README.md`'s "Status legend": ✅ Working,
  🟡 In progress, or 🔭 Planned, with plain-English caveats.
- An intro paragraph naming the audience ("for **app developers** who need their app to keep data") and the
  promise.
- A fenced block showing "the smallest thing that works," then progressive detail.
- `>` callout blocks linking to related pages and rationale.

Formatting rules that this plan must obey (per `.claude/skills/exec-plan/PLANS.md` and the existing docs):
two newlines after every heading, and **every fenced code block carries a language tag** — `haskell`,
`bash`, `text`, `yaml`, or `markdown` — never a bare ```` ``` ````.

**What the sibling plans deliver — the source of truth for what to document.** Because EP-34/35/36 may not
be fully fleshed out when this plan is written, the binding contract is the MasterPlan's Integration Points
(`docs/masterplans/7-persistent-storage-for-nagare.md`), reproduced here so this plan is self-contained:

- **The typed `Volume` model (IP1, owned by EP-34).** A new validated record lives in
  `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` and is placed in a new `volumes :: [Volume]` field on both
  `Deployment` and the `ServerSite` record (`cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs`). Its fields,
  exactly as the MasterPlan specifies:

  ```haskell
  -- | A durable disk attached to an app. All fields are validated by smart
  -- constructors; the data constructor is not exported, so an illegal Volume
  -- cannot be built (mirrors mkServiceName/mkQuantity in Nagare.Dsl.Types).
  data Volume = Volume
    { volName    :: !VolumeName       -- ^ DNS-label name, unique within the app
    , size       :: !Quantity         -- ^ reuses the existing Quantity newtype, e.g. "1Gi"
    , mountPath  :: !MountPath        -- ^ absolute, non-colliding in-container path
    , accessMode :: !AccessMode       -- ^ ReadWriteOnce (single-node default)
    , readOnly   :: !Bool             -- ^ mount read-only
    , retention  :: !RetentionPolicy  -- ^ Retain | Delete on app deletion
    }
  ```

  Smart constructors validate each field (a `mkVolume`/`mkVolumeName`/`mkMountPath` family, mirroring the
  existing `mkServiceName`/`mkQuantity`/`mkImageRef`), so duplicate names, relative or colliding mount
  paths, and malformed sizes are rejected at config-load time with a precise error. EP-34 provides an
  empty-`volumes` default so every existing config compiles unchanged. EP-34 is also expected to provide a
  preset/overlay helper (named in the MasterPlan as `attachVolume`) for the `Nagare.Dsl.Presets` module so
  a config author can write `attachVolume <volume> =<< webService …` without hand-assembling a record. When
  writing the config snippets, **prefer the helper if EP-34 ships one**; otherwise fall back to a record
  update on the `webService` result (the pattern the build-modes examples use, because the loader runs
  configs with `runghc -XGHC2024` which does not enable `OverloadedLabels`). Reconcile the exact names
  against EP-34's final Interfaces section before finalizing the snippets, and note any divergence in this
  plan's Decision Log.

- **The rendered YAML (IP2).** Each volume renders a standalone `PersistentVolumeClaim` with
  `storageClassName: local-path`, the requested size, and `accessModes: [ReadWriteOnce]`; a
  `spec.template.spec.volumes` entry of kind `persistentVolumeClaim` referencing that PVC by name; and a
  container `volumeMounts` entry with the mount path and read-only flag. This is what `nagarectl deploy
  --dry-run` prints — the offline proof a reader can run without a cluster.

- **The PVC naming and labels (IP3).** PVCs are named deterministically from the app and volume names —
  `nagare-vol-<app>-<volume>` — and stamped with the `nagare.dev/managed-by: nagarectl` label plus a
  per-volume label, so `nagarectl storage` commands can join a PVC back to its app and volume.

- **The backup-ownership policy and GCS layout (IP4, owned by EP-36).** `nagarectl storage snapshot APP
  VOLUME` writes a tar of the volume's contents to
  `gs://tan-nb-exp-nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz` (the same bucket the existing
  `scripts/backup-postgres.sh` and the Litestream example already use). Every volume is *either* included
  in the backup story *or* explicitly excluded with a **warning surfaced at deploy time**, so no volume is
  silently unprotected. The disaster-recovery runbook (`docs/runbooks/disaster-recovery.md`) and the user
  backup guide (`docs/user/backups-and-disaster-recovery.md`) are extended by EP-36 to cover restoring an
  app volume; this plan cross-links them.

- **The `nagarectl storage` command group (IP5).** EP-35 introduces the `storage` subparser with
  `nagarectl storage list APP` (lists an app's volumes: PVC name, size, bound status, node path) and
  `nagarectl storage inspect APP VOLUME` (one volume in detail). EP-36 extends the same subparser with
  `nagarectl storage snapshot APP VOLUME`.

**The existing raw example — `cluster/examples/sqlite-litestream/`.** It is the conceptual ancestor of
this plan's Example 1 but is *not* a Nagare app: it is a raw Kubernetes `apps/v1` `Deployment` (not a
Knative Service) whose SQLite database sits on an `emptyDir` (ephemeral — gone on pod restart) with a
Litestream sidecar replicating to `gs://tan-nb-exp-nagare-backups/litestream/app.db`. Its own header
comment says "a real app would use a PVC on the data disk (local-path)." Example 1 in this plan is that
real app: a typed Nagare config on a durable PVC, deployed with `nagarectl deploy`. The new guide must
explain the difference plainly: **durable PVC vs ephemeral emptyDir; deployed via `nagarectl deploy` vs raw
`kubectl apply`.** Reuse the Litestream sidecar/config pattern from
`cluster/examples/sqlite-litestream/litestream.yml` (the GCE-metadata-IP env trick for Application Default
Credentials is load-bearing — see below).

**Examples — `cluster/examples/`.** Existing example projects show the layout: a `nagare/Config.hs` plus a
`README.md`, and any source the app needs. The model config using presets is
`cluster/examples/preset-app-a/nagare/Config.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (production, webService)
import Nagare.Dsl.Types (Deployment)

deployment :: Either String Deployment
deployment = do
  base <- mapLeft show (webService "notes" "gcr.io/myproject/notes")
  mapLeft show (production base)
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
```

The deploy command for an example config (the form used in the build-modes example READMEs) is
`nagarectl deploy -f cluster/examples/<name>/nagare/Config.hs [--dry-run]`. When running from a source
checkout where `nagarectl` is not on `PATH`, the equivalent is
`cabal --project-dir=cli/nagarectl run nagarectl -- deploy -f <config> --dry-run`.

**The GCP isolation rule.** Every cloud resource and read targets the `tan-nb-exp` project, region
`us-west1`, zone `us-west1-a` (repo `CLAUDE.md`). The backup bucket is `tan-nb-exp-nagare-backups`. Both
examples and all `gsutil`/`nagarectl` commands in the docs target only that project.


## Plan of Work

The work is three milestones: write the docs (M1), then build-and-verify each example (M2, M3). Each
milestone ends with an observable acceptance a reader can reproduce.

### Milestone 1 — The persistent-storage guide and reference updates

Scope: create `docs/user/persistent-storage.md`, extend `docs/user/config-reference.md` and
`docs/user/reference.md`, cross-link `docs/user/backups-and-disaster-recovery.md`, and index the new page
in `docs/user/README.md`. At the end of this milestone the conceptual and reference documentation is
complete and internally consistent; the examples it references are added in M2/M3.

Create **`docs/user/persistent-storage.md`** in the house style, with these sections in order:

1. **Title + status box + intro.** H1 `# Persistent storage`, a `>` status box (use 🟡 In progress, or 🔭
   Planned if the cluster legs are still deferred, with the same honest caveat the sibling pages use:
   "Built and dry-run-verified; live end-to-end run pending until `nagare-01` is back up"). One paragraph
   naming the audience ("for **app developers** whose app needs to keep data across restarts") and the
   promise (declare a disk in your typed config; Nagare provisions, mounts, and can back it up).

2. **Concepts.** Define, in prose, *volume*, *PersistentVolumeClaim (PVC)*, the single-node `local-path`
   StorageClass (data lands under `/var/lib/nagare/local-path` on the host data disk), *ReadWriteOnce*
   (single-node, one writer), and *retention* (`Retain` vs `Delete` on app deletion, independent of GCS
   backups). Keep each definition to a sentence or two — reuse the wording from this plan's "Terms" list.
   Add a `>` callout that contrasts a durable volume with the container filesystem: anything written
   *outside* a mount path is lost on restart; anything written *inside* a mount path survives.

3. **Declaring a volume in `Config.hs`.** A copy-pasteable Haskell snippet that attaches a `1Gi` volume at
   `/data` to a `webService`. Use EP-34's helper if it exists, otherwise the record-update fallback; show
   both forms only if needed for clarity. Annotate each field (name, size, mountPath, accessMode, readOnly,
   retention). Point at `docs/user/config-reference.md` for the full field table. The canonical snippet to
   include (record-update fallback form, which works under the loader's `-XGHC2024`):

   ```haskell
   {-# LANGUAGE OverloadedStrings #-}

   module Main (main) where

   import Nagare.Dsl.Config (emitDeployment)
   import Nagare.Dsl.Presets (webService)
   import Nagare.Dsl.Types
     (Deployment (..), RetentionPolicy (..), mkVolume)

   deployment :: Either String Deployment
   deployment = do
     base <- mapLeft show (webService "notes" "gcr.io/myproject/notes")
     vol  <- mapLeft show
       (mkVolume "data" "1Gi" "/data" Retain)  -- name size mountPath retention
     pure base {volumes = [vol]}
     where
       mapLeft f = either (Left . f) Right

   main :: IO ()
   main = case deployment of
     Left err -> ioError (userError err)
     Right dep -> emitDeployment dep
   ```

   Immediately below the snippet, note that `mkVolume`'s exact arity/argument order is defined by EP-34;
   if EP-34 ships an `attachVolume` overlay helper, show that simpler form too (`attachVolume vol =<<
   webService …`). The point the reader must take away: the volume is *typed*, validated at load time
   (duplicate names, relative paths, malformed sizes are rejected with a precise message), and renders a
   PVC plus a `volumeMount`.

4. **Seeing the rendered storage offline.** Show `nagarectl deploy -f <config> --dry-run` and an
   abbreviated `text` transcript of the rendered `PersistentVolumeClaim` (storageClassName `local-path`,
   `1Gi`, `accessModes: [ReadWriteOnce]`), the pod `volumes` entry, and the container `volumeMounts` entry.
   This is the no-cluster proof that the config is correct.

5. **Operating volumes: `nagarectl storage`.** Document the three verbs with one transcript each:
   `nagarectl storage list APP` (the table: volume, PVC name `nagare-vol-<app>-<volume>`, size, bound
   status, node path), `nagarectl storage inspect APP VOLUME` (the detail view), and
   `nagarectl storage snapshot APP VOLUME` (writes a tar to GCS — see backup section). State that PVCs are
   discovered by the `nagare.dev/managed-by: nagarectl` label plus a per-volume label (IP3), so the
   commands always reflect what `nagarectl deploy` provisioned.

6. **Backup ownership and the deploy-time exclusion warning.** State the policy in plain language: every
   app volume is *either* included in the GCS backup flow *or* explicitly excluded, and an excluded volume
   triggers a **warning at deploy time** so nothing is silently unprotected. Document the GCS layout
   `gs://tan-nb-exp-nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz`. Explain `Retain` vs `Delete`
   retention once more in the backup context: retention controls the *local disk* on app deletion; GCS
   snapshots are a *separate* durable copy. Add the warning that `nagarectl storage snapshot` copies files
   at the moment it runs — for a live SQLite database, prefer the Litestream pattern (Example 1) for
   continuous, consistent replication over periodic file snapshots.

7. **Restoring (pointer to the runbook).** Do not duplicate the restore procedure; link to
   `docs/user/backups-and-disaster-recovery.md` (extended by EP-36) and
   `docs/runbooks/disaster-recovery.md` for the step-by-step restore of an app volume. Summarize the
   scratch-first principle in one sentence: restore into a scratch path, compare, then promote — never
   restore directly over a live volume.

8. **Two worked examples.** Two short subsections, each one paragraph plus the deploy command, pointing at
   `cluster/examples/sqlite-pvc-litestream/` and `cluster/examples/uploads-volume/` (added in M2/M3) for
   the full walk-throughs. Explicitly contrast the SQLite example with the old raw
   `cluster/examples/sqlite-litestream/`: durable PVC vs `emptyDir`, `nagarectl deploy` vs raw
   `kubectl apply`.

Extend **`docs/user/config-reference.md`**: add a "Volumes" section documenting the `volumes` field and the
`Volume` record's six fields in the file's existing per-field table style. The table:

```markdown
| Field | Type | Meaning |
| --- | --- | --- |
| `volName` | `VolumeName` (via `mkVolumeName`) | DNS-label name, unique within the app. |
| `size` | `Quantity` (via `mkQuantity`, e.g. `"1Gi"`) | Requested disk size. |
| `mountPath` | `MountPath` (via `mkMountPath`) | Absolute in-container path; must not collide. |
| `accessMode` | `AccessMode` | `ReadWriteOnce` (single-node default). |
| `readOnly` | `Bool` | Mount the volume read-only. |
| `retention` | `RetentionPolicy` | `Retain` or `Delete` on app deletion. |
```

Add a one-line note that `volumes` defaults to `[]` (so existing configs are unaffected) and a
type-checking snippet using `mkVolume` (or `attachVolume`) matching EP-34's exported API.

Extend **`docs/user/reference.md`**: add a "`nagarectl storage` commands" table mirroring the existing
"`nagarectl site` commands" table:

```markdown
| Command | Does |
| --- | --- |
| `nagarectl storage list APP` | List an app's volumes: volume name, PVC name, size, bound status, node path. |
| `nagarectl storage inspect APP VOLUME` | Describe one volume in detail. |
| `nagarectl storage snapshot APP VOLUME` | Tar the volume's contents to the GCS backup bucket. |
```

Add a short note on the PVC naming convention (`nagare-vol-<app>-<volume>`) and the GCS layout
(`gs://tan-nb-exp-nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz`) to the reference's "On-host
storage layout" / backup context, since `reference.md` already documents `/var/lib/nagare/local-path`.

Cross-link **`docs/user/backups-and-disaster-recovery.md`**: add a row to its "What to back up" table for
"App volumes (PVCs) → `nagarectl storage snapshot` → GCS" and a one-line pointer from its restore section
to `docs/user/persistent-storage.md` for the volume context. (EP-36 owns the actual restore *steps* in this
file; this plan only ensures the cross-links exist and are consistent.)

Index the new page in **`docs/user/README.md`**: add a bullet under item 8 ("Deploying apps"), alongside
the existing "Build modes" and "Static & full-stack site hosting" sub-bullets, linking
`persistent-storage.md` with a one-line description and a status badge.

Acceptance for M1: `docs/user/persistent-storage.md` exists and renders; every command and field name in
it matches the MasterPlan's IP1–IP5 contract (and EP-34/35/36's final Interfaces if available);
`config-reference.md` lists all six `Volume` fields; `reference.md` lists the three `storage` commands;
`backups-and-disaster-recovery.md` and `README.md` link the new page; no bare ```` ``` ```` fences exist in
any edited file.

### Milestone 2 — Example 1: SQLite on a PVC with Litestream continuous backup

Scope: create `cluster/examples/sqlite-pvc-litestream/` as a typed Nagare app whose `nagare/Config.hs`
declares a `1Gi` volume at `/data`, stores a SQLite database there, and runs a Litestream sidecar
replicating to `gs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/`. At the end of this
milestone the example deploys (or dry-runs), and its README proves durability across a revision roll plus
Litestream replication to GCS.

Files to create:

- `cluster/examples/sqlite-pvc-litestream/nagare/Config.hs` — a `Deployment` from `webService` with a
  `1Gi` volume named `data` mounted at `/data`, `retention = Retain` (you do not want the database deleted
  when the app is removed). Use EP-34's helper or the record-update fallback. The image should be one that
  contains both `sqlite3` and Litestream, or the Config declares the app container and the README documents
  the Litestream sidecar. **Important constraint:** Knative Services run a single user container by
  default; the Litestream "sidecar" must be a second container in the rendered pod. Knative multi-container
  support is on; if EP-34's typed model does not expose sidecars, the README documents the sidecar as a
  supplementary `kubectl patch`/manifest step layered onto the deployed Service, and this plan records that
  limitation in the Decision Log. Reconcile against EP-34's model before finalizing.
- `cluster/examples/sqlite-pvc-litestream/litestream.yml` — the Litestream config, adapted from
  `cluster/examples/sqlite-litestream/litestream.yml`, with the replica URL
  `gcs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/app.db` and the db path `/data/app.db`.
- `cluster/examples/sqlite-pvc-litestream/README.md` — the deploy + verify walk-through.

The Litestream config (reuse the working pattern; the GCE-metadata-host env trick is required because pods
cannot resolve `metadata.google.internal` on this cluster, so Application Default Credentials must be
pointed at the metadata IP directly):

```yaml
# Litestream config for the sqlite-pvc-litestream example.
# Litestream watches the SQLite db on the durable PVC at /data and continuously
# ships its write-ahead log to the GCS backup bucket. Auth uses Application
# Default Credentials = the node service account, which has
# roles/storage.objectAdmin on tan-nb-exp-nagare-backups (no key files).
dbs:
  - path: /data/app.db
    replicas:
      - url: gcs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/app.db
```

The README walk-through (capture real transcripts as evidence; mark live-deferred if no cluster):

```bash
# 1. Render offline (no cluster) to confirm the PVC + volumeMount appear.
nagarectl deploy -f cluster/examples/sqlite-pvc-litestream/nagare/Config.hs --dry-run

# 2. Deploy for real.
nagarectl deploy -f cluster/examples/sqlite-pvc-litestream/nagare/Config.hs

# 3. Confirm the volume is provisioned and bound.
nagarectl storage list sqlite-pvc-litestream

# 4. Write a row into the SQLite db on the volume.
POD=$(kubectl get pod -n personal -l serving.knative.dev/service=sqlite-pvc-litestream \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n personal "$POD" -c user-container -- \
  sqlite3 /data/app.db "CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, body TEXT); \
  INSERT INTO notes(body) VALUES ('persisted at '||datetime('now'));"

# 5. Roll a new revision (or delete the pod) to prove durability.
nagarectl deploy -f cluster/examples/sqlite-pvc-litestream/nagare/Config.hs   # or: kubectl delete pod -n personal "$POD"

# 6. Re-fetch the row from the NEW pod — it must still be there (durable PVC).
POD=$(kubectl get pod -n personal -l serving.knative.dev/service=sqlite-pvc-litestream \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n personal "$POD" -c user-container -- \
  sqlite3 /data/app.db "SELECT count(*) FROM notes;"

# 7. Confirm Litestream replicated to GCS.
gsutil ls "gs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/app.db/"
```

Expected observations (the acceptance):

```text
# Step 3: storage list shows the bound 1Gi volume
VOLUME  PVC                                  SIZE  STATUS  NODE PATH
data    nagare-vol-sqlite-pvc-litestream-data  1Gi  Bound   /var/lib/nagare/local-path/...

# Step 6: the row survived the revision roll (durable PVC, unlike emptyDir)
1

# Step 7: Litestream generation/WAL objects exist in GCS
gs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/app.db/generations/...
```

The README must explicitly contrast this with `cluster/examples/sqlite-litestream/`: there the db was on an
`emptyDir`, so step 6 would return `0` (data lost on pod restart); here the durable PVC makes it `1`. That
contrast is the whole point of the example.

Acceptance for M2: `nagarectl deploy --dry-run` renders a `1Gi` `local-path` RWO PVC and a `/data`
volumeMount; on a live cluster the row written in step 4 survives the revision roll in step 5 (step 6
returns the row), and `gsutil ls` in step 7 shows Litestream objects in GCS. If no cluster is reachable,
record "dry-run verified; live legs deferred" in the README status box and this plan's Progress, mirroring
`docs/plans/32-...`.

### Milestone 3 — Example 2: uploaded files on a durable volume + snapshot/restore drill

Scope: create `cluster/examples/uploads-volume/` as a typed Nagare app that accepts file uploads onto a
durable volume mounted at `/uploads`. At the end of this milestone the example deploys (or dry-runs), and
its README proves upload durability across a roll, then a `nagarectl storage snapshot` lands a tarball in
GCS, followed by a restore drill.

Files to create:

- `cluster/examples/uploads-volume/nagare/Config.hs` — a `Deployment` from `webService` with a volume
  named `uploads` (e.g. `1Gi`) mounted at `/uploads`, `retention = Retain`. The app image must be a tiny
  web server that serves and accepts uploads under `/uploads` (a minimal HTTP file server, e.g. a small Go
  or Node uploader, or a prebuilt public image that does this). If the example needs source, add it
  alongside `nagare/` (matching how `cluster/examples/tanstack-start/` and `static-site/` carry app
  source); keep it minimal. The Config sets `port` to whatever the server listens on (default `8080`).
- `cluster/examples/uploads-volume/README.md` — the deploy + verify + snapshot + restore walk-through.

The README walk-through (capture real transcripts; mark live-deferred if no cluster):

```bash
# 1. Render offline to confirm the PVC + /uploads volumeMount.
nagarectl deploy -f cluster/examples/uploads-volume/nagare/Config.hs --dry-run

# 2. Deploy for real, then discover the app URL.
nagarectl deploy -f cluster/examples/uploads-volume/nagare/Config.hs
URL=$(nagarectl app get uploads-volume | sed -n 's/^URL: //p')   # or read from deploy output

# 3. Upload a file via curl.
echo "hello durable storage" > /tmp/hello.txt
curl -fsS -F file=@/tmp/hello.txt "$URL/upload"

# 4. Confirm it is served back.
curl -fsS "$URL/files/hello.txt"          # -> hello durable storage

# 5. Roll the app to prove durability.
nagarectl deploy -f cluster/examples/uploads-volume/nagare/Config.hs   # or: nagarectl app restart uploads-volume

# 6. Re-fetch from the new pod — the file must still be served (durable PVC).
curl -fsS "$URL/files/hello.txt"          # -> hello durable storage

# 7. Snapshot the volume to GCS and confirm the tarball landed.
nagarectl storage snapshot uploads-volume uploads
gsutil ls "gs://tan-nb-exp-nagare-backups/volumes/uploads-volume/uploads/"

# 8. Restore drill (scratch-first): pull the snapshot into a scratch dir and inspect.
SNAP=$(gsutil ls "gs://tan-nb-exp-nagare-backups/volumes/uploads-volume/uploads/" | tail -1)
mkdir -p /tmp/restore && gsutil cp "$SNAP" /tmp/restore/snap.tar.gz
tar -tzf /tmp/restore/snap.tar.gz                 # lists hello.txt without touching the live volume
```

Expected observations (the acceptance):

```text
# Step 4 and Step 6: the upload is served, before and after the roll
hello durable storage

# Step 7: the snapshot tarball exists in GCS under the documented layout
gs://tan-nb-exp-nagare-backups/volumes/uploads-volume/uploads/2026-06-09T... .tar.gz

# Step 8: the restore drill lists the file from the tar without overwriting the live volume
uploads/hello.txt
```

The README must state the scratch-first restore principle plainly: the drill copies the snapshot into
`/tmp/restore` and only *inspects* it; a real restore promotes the verified contents back into the volume
per `docs/user/backups-and-disaster-recovery.md` and `docs/runbooks/disaster-recovery.md` — never restore
directly over a live volume.

Acceptance for M3: `nagarectl deploy --dry-run` renders the `/uploads` PVC and volumeMount; on a live
cluster the uploaded file survives the roll (step 6 serves it), `nagarectl storage snapshot` produces a tar
under `gs://tan-nb-exp-nagare-backups/volumes/uploads-volume/uploads/`, and the restore drill lists the
file from the snapshot. If no cluster is reachable, record "dry-run verified; live legs deferred."


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Write the docs (M1), then create the two example directories (M2, M3). After each example's `Config.hs`,
verify it loads and renders the PVC + volumeMount offline (no cluster required — the `--dry-run` path
renders manifests from the typed config):

```bash
nagarectl deploy -f cluster/examples/sqlite-pvc-litestream/nagare/Config.hs --dry-run
nagarectl deploy -f cluster/examples/uploads-volume/nagare/Config.hs --dry-run
```

From a source checkout without `nagarectl` on `PATH`, use the cabal form (the `--ghc-env` mechanism lets
the loader's `runghc` find `nagare-dsl`):

```bash
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/sqlite-pvc-litestream/nagare/Config.hs --dry-run
```

Expected (abbreviated) dry-run output showing the rendered PVC and mount:

```text
--- PersistentVolumeClaim: nagare-vol-sqlite-pvc-litestream-data ---
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
--- Knative Service manifest ---
...
        volumeMounts:
          - name: data
            mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: nagare-vol-sqlite-pvc-litestream-data
URL: https://sqlite-pvc-litestream.apps.<base-domain>
```

Check that the docs render and links resolve, and that no bare fences slipped in:

```bash
grep -rn "persistent-storage.md" docs/user/
grep -rn '^```$' docs/user/persistent-storage.md docs/user/config-reference.md \
  docs/user/reference.md cluster/examples/sqlite-pvc-litestream/README.md \
  cluster/examples/uploads-volume/README.md || echo "all fences tagged"
```

There is no separate doc build; the docs are read as Markdown in the repo. The "test" is that every command
in each example README runs and matches its shown output (or is marked live-deferred).


## Validation and Acceptance

Acceptance is documentation-by-demonstration. Concretely:

1. `docs/user/persistent-storage.md` exists, is linked from `docs/user/README.md` and
   `docs/user/backups-and-disaster-recovery.md`, and every concept, field name, and command in it matches
   the MasterPlan's IP1–IP5 contract and EP-34/35/36's shipped surface (verified by reading their final
   Interfaces sections, or by running the commands).
2. `docs/user/config-reference.md` documents the `volumes` field and all six `Volume` fields with a
   type-checking `mkVolume`/`attachVolume` snippet; `docs/user/reference.md` lists the three
   `nagarectl storage` commands and the PVC-naming / GCS-layout conventions.
3. `cluster/examples/sqlite-pvc-litestream/` loads (`nagarectl deploy --dry-run` renders a `1Gi`
   `local-path` RWO PVC and a `/data` volumeMount); on a live cluster, a row written to `/data/app.db`
   survives a revision roll (proving durable PVC vs the old `emptyDir`), and `gsutil ls` shows Litestream
   objects under `gs://tan-nb-exp-nagare-backups/litestream/sqlite-pvc-litestream/app.db/`.
4. `cluster/examples/uploads-volume/` loads (`--dry-run` renders the `/uploads` PVC and volumeMount); on a
   live cluster, an uploaded file survives a roll, `nagarectl storage snapshot uploads-volume uploads`
   writes a tar under `gs://tan-nb-exp-nagare-backups/volumes/uploads-volume/uploads/`, and the restore
   drill lists the file from the snapshot without touching the live volume.
5. No bare ```` ``` ```` fences in any new or edited file (every block has a language tag).

Where a live cluster is unavailable in the implementation environment, items 3 and 4's live legs are marked
"dry-run verified; live run deferred" in the example READMEs and this plan's Progress, mirroring how
`docs/plans/32-application-lifecycle-docs-and-end-to-end-examples.md` recorded a deferred cluster step. The
offline dry-run rendering of the PVC and volumeMount is mandatory and must pass regardless.


## Idempotence and Recovery

All work here is additive: new Markdown pages and example directories, plus edits to existing docs. Every
step is safe to re-run and re-render. `nagarectl deploy --dry-run` has no side effects, so example
verification can be repeated freely. `git checkout <file>` recovers any bad edit.

The examples are deployable repeatedly: `nagarectl deploy` is declarative (`kubectl apply` with a fresh
image tag per build), and **re-deploying reuses the existing PVC** — that is precisely the durability the
examples demonstrate, so data persists across re-deploys. The PVC is named deterministically
(`nagare-vol-<app>-<volume>`, IP3), so a second deploy binds the same disk rather than creating a new one.

Cleanup is documented in each example README per the retention policy:

```bash
# Delete the example app (Service, DomainMappings, history):
nagarectl app delete sqlite-pvc-litestream
nagarectl app delete uploads-volume

# With retention = Retain, the PVC and its data SURVIVE app deletion. To reclaim the
# disk, delete the PVC explicitly (this is destructive — data is gone):
kubectl delete pvc -n personal nagare-vol-sqlite-pvc-litestream-data
kubectl delete pvc -n personal nagare-vol-uploads-volume-uploads
```

State in each README that with `retention = Delete` the PVC is removed when the app is deleted, whereas
`retention = Retain` (the examples' choice) keeps it — so deleting the disk is an explicit, separate,
destructive step. GCS snapshots are never touched by app deletion and must be removed manually if desired
(`gsutil rm -r gs://tan-nb-exp-nagare-backups/volumes/<app>/`), respecting the backup bucket's
`forceDestroy: false` protection.


## Interfaces and Dependencies

No code dependencies; this plan writes Markdown and example `Config.hs`/`litestream.yml`/source files. It
consumes the user-facing surfaces of the sibling plans, named here by path:

- `docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md` — the typed `Volume`
  record (`volName`, `size`, `mountPath`, `accessMode`, `readOnly`, `retention`) on `Deployment`, its smart
  constructors (`mkVolume`/`mkVolumeName`/`mkMountPath`) and any `attachVolume` overlay, the empty-`volumes`
  default, and the rendered PVC + `volumeMount` YAML shape (IP1, IP2, IP3). The config snippets in M1 and
  the example `Config.hs` files in M2/M3 consume these from `Nagare.Dsl.Types` and `Nagare.Dsl.Presets`.
- `docs/plans/35-deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands.md` —
  deploy-time PVC provisioning (so a real deploy binds the disk before serving) and
  `nagarectl storage list APP` / `nagarectl storage inspect APP VOLUME` (IP5). The examples and the guide
  document and exercise these commands.
- `docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md` —
  `nagarectl storage snapshot APP VOLUME`, the GCS layout
  `gs://tan-nb-exp-nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz`, the deploy-time
  backup-exclusion warning, and the restore procedure added to
  `docs/user/backups-and-disaster-recovery.md` and `docs/runbooks/disaster-recovery.md` (IP4). The guide
  documents the policy and the uploads example exercises the snapshot + restore drill.

New files this plan creates:

- `docs/user/persistent-storage.md` (the new guide).
- `cluster/examples/sqlite-pvc-litestream/nagare/Config.hs`,
  `cluster/examples/sqlite-pvc-litestream/litestream.yml`,
  `cluster/examples/sqlite-pvc-litestream/README.md`.
- `cluster/examples/uploads-volume/nagare/Config.hs`, `cluster/examples/uploads-volume/README.md`, and any
  minimal app source the uploader needs.

Files this plan edits:

- `docs/user/config-reference.md` (the `volumes` field and `Volume` field table),
  `docs/user/reference.md` (the `nagarectl storage` command table and PVC/GCS conventions),
  `docs/user/backups-and-disaster-recovery.md` (the cross-link and the app-volume backup row), and
  `docs/user/README.md` (index the new page).

The only "interface" this plan must keep accurate is that documented field names, command names, flags, the
PVC naming convention (`nagare-vol-<app>-<volume>`), the labels (`nagare.dev/managed-by: nagarectl` plus the
per-volume label), and the GCS layout match what EP-34/35/36 actually shipped. Re-read their final
Interfaces sections before writing the snippets and transcripts, and record any name change in this plan's
Decision Log. All cloud reads and writes target the `tan-nb-exp` project / `us-west1` region only, per the
repository `CLAUDE.md`.
