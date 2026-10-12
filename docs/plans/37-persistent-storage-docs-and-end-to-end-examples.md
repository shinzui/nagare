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

Full plan before trimming: [37-persistent-storage-docs-and-end-to-end-examples.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/37-persistent-storage-docs-and-end-to-end-examples.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

