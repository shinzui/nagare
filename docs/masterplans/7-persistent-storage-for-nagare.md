---
id: 7
slug: persistent-storage-for-nagare
title: "Persistent Storage for Nagare"
kind: master-plan
created_at: 2026-06-10T00:44:28Z
intention: "intention_01ktqfjpdqewga3t0rm9crehxx"
---

# Persistent Storage for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


This initiative implements **Phase 3 (Persistent Storage)** of the PaaS capability roadmap at
`docs/roadmaps/paas-gap-roadmap.md`. It is the fourth initiative in the roadmap's recommended order,
following static hosting (`docs/masterplans/3-static-hosting-for-nagare.md`), application build modes
(`docs/masterplans/4-application-build-modes-for-nagare.md`), environment and secret management
(`docs/masterplans/5-environment-and-secret-management-for-nagare.md`), and application lifecycle
(`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`). Persistent storage is, per the
roadmap, "a prerequisite for many 'service' and 'database' templates" and for the managed-database
work of Phase 4, so it is sequenced before them.


## Vision & Scope

Today a Nagare application is stateless by construction. A developer writes a typed
`nagare/Config.hs` that produces a `Deployment` value (the record defined in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), runs `nagarectl deploy`, and the CLI builds, pushes, and
applies a Knative Service. That Service has nowhere to keep data: when its pod restarts or scales to
zero, anything written to the container filesystem is gone. The repository *demonstrates* persistence
at the raw-Kubernetes level — `cluster/examples/sqlite-litestream/` runs a plain Kubernetes
`Deployment` (not a Knative Service) with an `emptyDir` and a Litestream sidecar that replicates a
SQLite file to the GCS backup bucket — but there is no typed, app-level way to attach durable storage
to an ordinary Nagare app, and the Knative platform itself is not even configured to allow it: the
Knative Serving `config-features` ConfigMap that gates `PersistentVolumeClaim` (PVC) volumes is not
present in `cluster/bootstrap/knative-serving/`, so a Knative Service that asks for a PVC is rejected
today.

A **PersistentVolumeClaim (PVC)** is the Kubernetes object an app uses to request a durable disk; on
this single-node k3s cluster it is satisfied by the built-in **`local-path`** StorageClass, which
carves a directory out of the host data disk at `/var/lib/nagare/local-path` and mounts it into the
pod. A **volume mount** is the in-container path at which that disk appears (for example `/data`).

After this initiative, a developer can declare durable storage in the typed config and operate it
from the CLI, and the platform actually honors it:

- **Typed volumes in the DSL.** The `Deployment` record (and the `ServerSite` record in
  `cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs`) gains a typed list of volumes: each has a name, a
  requested size (for example `1Gi`), a mount path, an access mode, a read-only flag, and a
  **retention policy** that says whether the underlying disk is deleted or kept when the app is
  removed. Illegal storage — duplicate names, relative or colliding mount paths, malformed sizes — is
  unrepresentable, caught at config-load time with a precise error, exactly as the existing typed
  model rejects bad images and ports.
- **Rendered PVCs and mounts.** `nagarectl deploy` renders, applies, and waits for one PVC per
  declared volume (named deterministically, labelled as Nagare-managed) *before* it applies the
  Service, and the rendered Knative Service carries the matching `volumes` and `volumeMounts` so the
  container sees its disk. The Knative cluster is configured to permit this.
- **Storage CLI.** `nagarectl storage list APP` shows an app's volumes with their PVC name, size,
  bound status, and node-path; `nagarectl storage inspect APP VOLUME` describes one in detail; and
  `nagarectl storage snapshot APP VOLUME` captures a point-in-time copy of a volume's contents into
  the existing GCS backup bucket.
- **Defined backup ownership.** Every app volume is, by an explicit and documented policy, either
  *included* in the GCS backup flow (via the snapshot mechanism and a labelled retention policy) or
  *explicitly excluded with a warning surfaced at deploy time*, so no volume is silently
  unprotected. The disaster-recovery runbook is extended to cover restoring an app volume.
- **Guidance for real workloads.** User documentation shows two concrete patterns end to end: a
  SQLite-on-a-PVC app with Litestream-style continuous backup, and an uploaded-files app that keeps
  user uploads on a durable volume.

What is **in scope**: enabling and verifying Knative PVC support on the cluster; the typed
`Volume`/`Mount` model and its JSON round-trip; the PVC and volumeMount/volume renderer; deploy-time
PVC provisioning; the `nagarectl storage` command group; the backup-ownership policy with
snapshot-to-GCS, retention, and runbook integration; and user documentation with two working
examples.

What is **out of scope** (deferred to later roadmap phases or noted as integration points): managed
databases (Postgres, Redis) and their generated connection env — Phase 4
(`docs/roadmaps/paas-gap-roadmap.md`), which will *consume* the volume primitive defined here;
continuous block-level replication as a platform feature (the SQLite/Litestream example remains an
application-level pattern, documented but not productized as a Nagare-managed sidecar); volume
*resizing* and *migration* between StorageClasses; multi-node `ReadWriteMany` storage (Nagare is
intentionally single-node, so volumes are `ReadWriteOnce`); CSI volume snapshots (this initiative
snapshots by copying file contents to GCS, because the `local-path` provisioner has no CSI snapshot
support); and a web UI for storage (Phase 10). The env/secret store from
`docs/masterplans/5-environment-and-secret-management-for-nagare.md` is reused conceptually for the
"Nagare-managed" labelling convention but its ConfigMap/Secret machinery is not extended here.


## Decomposition Strategy

The initiative is decomposed into five child ExecPlans. The guiding principle is the same seam the
sibling MasterPlans use: separate the *platform enablement* from the *typed model* from the *renderer
and CLI surfaces* from the *backup policy* from the *documentation*, so that each plan produces an
independently verifiable behavior and groups one functional concern rather than one file.

The decisive finding from research is that **Knative Serving on this cluster cannot mount a PVC at
all today** — the `config-features` ConfigMap that enables `kubernetes.podspec-persistent-volume-claim`
and `kubernetes.podspec-persistent-volume-write` is absent from `cluster/bootstrap/knative-serving/`.
Worse, there is a genuine open question about whether a Knative Service — which during a rollout runs
the *old* and *new* revision concurrently — can hold a single-node `ReadWriteOnce` `local-path` PVC
without the two revisions deadlocking on the mount. This is a feasibility risk that gates the entire
initiative: if a Knative Service cannot durably mount a `local-path` PVC, the typed model renders
YAML the cluster rejects. Per the ExecPlan specification's guidance to de-risk significant unknowns
with an explicit spike, this enablement-and-feasibility work is its own first plan (**EP-33**). It
produces both committed cluster config (the `config-features` patch) and a verified, documented
raw-YAML proof that a Knative Service mounts a `local-path` PVC and that data survives a revision
roll — and it determines the rollout knob (for example a Knative `serving.knative.dev/rolloutDuration`
or a min/max-scale constraint) that the renderer must stamp onto any Service with a volume.

The typed model and renderer (**EP-34**) is the foundation every later plan imports: it owns the
`Volume` type, its placement on `Deployment` and `ServerSite`, the JSON round-trip
(`Config.hs` emit / `Load.hs` decode), the PVC manifest renderer, and the container/pod
`volumeMounts`/`volumes` rendering, all with golden tests. It is pure DSL work and can be fully
unit- and golden-tested without a live cluster, so it only *soft*-depends on EP-33 — but the exact
YAML it emits must match the shape EP-33 verified, which is an explicit integration point.

The deploy-time provisioning and the read-only CLI (**EP-35**) is the first *operational* consumer:
it makes `nagarectl deploy` apply the rendered PVCs before the Service and adds
`nagarectl storage list|inspect`. The backup concern (**EP-36**) is deliberately a separate plan
because "define backup ownership" is its own coherent, separately demonstrable policy: it adds
`nagarectl storage snapshot`, the include/exclude-with-warning decision, retention handling, and the
disaster-recovery runbook update, reusing the existing GCS bucket and restore-script conventions.
Documentation and two end-to-end examples (**EP-37**) are last, mirroring how every sibling initiative
finished with a docs/example plan (`docs/plans/17-...`, `docs/plans/22-...`,
`docs/plans/28-...`, `docs/plans/32-...`).

Alternatives considered and rejected. **A single ExecPlan**: the roadmap itself says "one MasterPlan
if backup integration is included; otherwise one ExecPlan," and backup integration *is* included, so
a MasterPlan is warranted; additionally the cluster-enablement feasibility risk is large enough to
deserve isolation. **Folding the enablement spike into the model plan**: rejected because they touch
entirely different parts of the repo (`cluster/bootstrap/knative-serving/` vs `cli/nagare-dsl/`) and
because the spike is the de-risking gate — keeping it separate lets the model proceed in parallel
against the verified YAML shape. **Putting `storage snapshot` in EP-35 with the other storage
commands**: rejected because snapshotting *is* the backup concern (it writes to the GCS backup bucket
and honors retention), so it belongs with the backup-ownership policy in EP-36; EP-35 keeps only the
read-only `list`/`inspect`. **Splitting backup into "snapshot" and "runbook/policy" plans**: rejected
to keep the plan count at five — they share the same precondition and are both "make app volumes part
of the backup story," so they are one plan with two milestones.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 33 | Knative PVC enablement spike and cluster feature flags | docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md | None | None | Complete |
| 34 | Typed volume and mount model with PVC and volumeMount renderer | docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md | None | EP-33 | Complete |
| 35 | Deploy-time PVC provisioning and nagarectl storage list and inspect commands | docs/plans/35-deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands.md | EP-34 | EP-33 | Complete |
| 36 | App volume backup ownership, snapshot to GCS, and retention | docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md | EP-34, EP-35 | EP-33 | Complete |
| 37 | Persistent storage docs and end-to-end examples | docs/plans/37-persistent-storage-docs-and-end-to-end-examples.md | EP-35, EP-36 | EP-34 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-33, EP-35). The numbers
continue the repository's sequential plan numbering; the most recent existing plan is EP-32 (a child
of MasterPlan 6).


## Dependency Graph

EP-33 (the enablement spike) has no dependencies and is the root in practice: it enables PVC volumes
on the Knative cluster and verifies, with raw YAML, that a Knative Service can durably mount a
`local-path` `ReadWriteOnce` PVC across a revision roll. It produces two artifacts the rest of the
initiative relies on: the committed `config-features` change under `cluster/bootstrap/knative-serving/`,
and the *verified rendered shape* (the exact `volumes`/`volumeMounts` stanza plus whatever rollout
annotation the single-node RWO constraint requires).

EP-34 (the typed model and renderer) has no *hard* dependency because it is pure DSL work: the
`Volume` type, the JSON round-trip, and the renderer can be written and golden-tested without a
cluster. It *soft*-depends on EP-33 because the YAML it renders must match the shape EP-33 proved the
cluster accepts (Integration Point IP2); if EP-34 ran first, its goldens would encode an unverified
guess. The recommended order is therefore EP-33 then EP-34, but EP-34 can begin in parallel as soon
as EP-33's spike has produced the verified YAML stanza, even before the config commit lands.

EP-35 (deploy-time provisioning + `storage list`/`inspect`) hard-depends on EP-34: it applies the PVC
manifests EP-34 renders and enumerates the typed volumes EP-34 defines on a loaded `Deployment`. It
soft-depends on EP-33 only because a *live* end-to-end deploy needs the feature flags enabled on the
cluster; its pure logic (rendering the apply order, formatting the list/inspect tables) is testable
without the cluster via `--dry-run`.

EP-36 (backup ownership + `storage snapshot`) hard-depends on EP-34 (the retention policy and volume
identity live in the typed model) and on EP-35 (it extends the `storage` command group EP-35
introduces and reuses its PVC-discovery helpers). It soft-depends on EP-33 because an actual snapshot
of live data needs a mounted PVC.

EP-37 (docs and examples) hard-depends on EP-35 and EP-36 because it documents and exercises their
command surfaces end to end, and soft-depends on EP-34 to document the typed `Volume` fields
accurately.

**Parallelism.** EP-33 and the non-rendering parts of EP-34 (the `Volume` type, smart constructors,
JSON round-trip) can proceed concurrently; EP-34's renderer goldens should be finalized only once
EP-33's verified YAML shape exists. After EP-34 completes, EP-35 proceeds; EP-36 can begin its model
and snapshot-format work in parallel with EP-35 but gates on EP-35 for the shared `storage` command
plumbing. EP-37 is last.


## Integration Points

**IP1 — The typed `Volume` model and its JSON shape.** Defined by **EP-34** in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` and serialized in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` / decoded in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`. The
shared contract is a validated record placed in a new `volumes` field on both `Deployment` and
`ServerSite` (`cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs`):

```haskell
-- | A durable disk attached to an app. All fields are validated by smart
-- constructors; the data constructor is not exported, so an illegal Volume
-- cannot be built (mirrors mkServiceName/mkQuantity in Nagare.Dsl.Types).
data Volume = Volume
  { volName    :: !VolumeName   -- ^ DNS-label name, unique within the app
  , size       :: !Quantity     -- ^ reuses the existing Quantity newtype, e.g. "1Gi"
  , mountPath  :: !MountPath    -- ^ absolute, non-colliding in-container path
  , accessMode :: !AccessMode   -- ^ ReadWriteOnce (single-node default)
  , readOnly   :: !Bool         -- ^ mount read-only
  , retention  :: !RetentionPolicy -- ^ Retain | Delete on app deletion
  }
```

EP-35, EP-36, and EP-37 all import these types and the accessors (`volumeNameText`, `mountPathText`,
etc.). The JSON field names are owned by EP-34; later plans read the loaded `Deployment`, never the
raw JSON. EP-34 must provide a backward-compatible default (an empty `volumes` list) so every existing
config (`cluster/examples/*/nagare/Config.hs`, `cli/nagare-dsl/test/fixtures/`) compiles unchanged.

**IP2 — The rendered PVC / volume / volumeMount YAML shape.** *Verified* by **EP-33** (as raw YAML
applied by hand) and *produced* by **EP-34** in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` (and
`cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs`). The two must agree exactly. The contract is:
each volume renders (a) a standalone `PersistentVolumeClaim` manifest with `storageClassName:
local-path`, the requested size, and `accessModes: [ReadWriteOnce]`; (b) a `spec.template.spec.volumes`
entry of kind `persistentVolumeClaim` referencing that PVC by name; and (c) a container
`volumeMounts` entry with the mount path and read-only flag. EP-33 owns the *facts* about what
Knative accepts (the required feature flags and the rollout annotation needed so a single-node RWO
PVC survives a revision roll); EP-34 encodes those facts into the renderer and its golden files. The
renderer's YAML key ordering must be extended in `Render.hs`'s `knativeConfig`/`ranks` table to place
`volumeMounts` and `volumes` deterministically (the existing pattern for `env`/`resources`).

**IP3 — The PVC naming convention and Nagare-managed labels.** Defined by **EP-34** (the renderer
must name PVCs deterministically from the app and volume names, e.g. `nagare-vol-<app>-<volume>`, and
stamp a managed-by label) and consumed by **EP-35** (to discover an app's PVCs for `storage list`/
`inspect` via `kubectl get pvc -l <label>`) and **EP-36** (to discover which PVCs to snapshot and how
to honor retention). The label convention should align with the `nagare.dev/managed-by: nagarectl`
label that MasterPlan 6 (`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`, EP-29)
stamps on Services, extended with a per-volume label so `storage` commands can join a PVC back to its
app and volume name. EP-34 owns the exact label keys/values; EP-35 and EP-36 must query by them, never
re-derive names by hand.

**IP4 — The backup-ownership policy: retention, labels, and the GCS layout.** Defined by **EP-36**,
building on the `RetentionPolicy` field EP-34 places in the model (IP1) and the labels EP-34 stamps
(IP3). The contract: `nagarectl storage snapshot APP VOLUME` writes a tar of the volume's contents to
`gs://tan-nb-exp-nagare-backups/volumes/<app>/<volume>/<timestamp>.tar.gz` (the same bucket the
existing `scripts/backup-postgres.sh` and Litestream example use), and the deploy path emits a warning
for any volume whose policy marks it excluded from backups. EP-37 documents this layout and the
restore procedure; the disaster-recovery runbook (`docs/runbooks/disaster-recovery.md`) and user
backup guide (`docs/user/backups-and-disaster-recovery.md`) are updated by EP-36 and referenced by
EP-37. The GCS bucket name and project-isolation rules (`tan-nb-exp` only, per the repository
`CLAUDE.md`) are fixed constraints both plans must respect.

**IP5 — The `nagarectl storage` command group plumbing.** Introduced by **EP-35** in
`cli/nagarectl/app/Main.hs` (a new `storage` subparser following the existing `site` subparser
pattern) and a new module namespace `cli/nagarectl/src/Nagare/Storage/`. **EP-36** extends the same
subparser with the `snapshot` subcommand and adds modules under the same namespace, reusing EP-35's
PVC-discovery helper (which queries by the IP3 labels) and the `kubectl` shell-out conventions from
`cli/nagarectl/src/Nagare/Deploy.hs`. EP-35 owns the subparser wiring and the shared discovery helper;
EP-36 must extend, not fork, them.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-33: Knative `config-features` patch committed enabling PVC volume + write flags. (2026-06-09)
- [x] EP-33: Raw-YAML proof that a Knative Service mounts a `local-path` RWO PVC and data survives a revision roll; rollout knob determined and documented. (2026-06-09; min-scale=1/max-scale=1/rollout-duration=0s, no Multi-Attach.)
- [x] EP-34: `Volume`/`VolumeName`/`MountPath`/`AccessMode`/`RetentionPolicy` types + smart constructors; existing configs compile with an empty `volumes` default. (2026-06-09)
- [x] EP-34: JSON round-trip (Config.hs emit / Load.hs decode) carries volumes; golden tests pass. (2026-06-09; load-time name + mount-path uniqueness as MarshalError "volumes".)
- [x] EP-34: PVC manifest renderer + container/pod `volumeMounts`/`volumes` rendering + key ordering; golden tests match EP-33's verified shape. (2026-06-09; all 185 tests pass, no existing golden changed.)
- [x] EP-35: `nagarectl deploy` provisions PVCs before applying the Service; demonstrated via the real CLI `--dry-run` (PVC block first + EP-33 rollout annotations; no-volume path byte-compatible). (2026-06-09)
- [x] EP-35: `nagarectl storage list|inspect` commands working (verified end-to-end through the real binary; live-PVC-data path unit-tested + the on-cluster transcript deferred to EP-37 — IAP forwards only SSH/22). (2026-06-09)
- [x] EP-36: `nagarectl storage snapshot APP VOLUME` writes a tar to the GCS backup bucket; retention honored. (2026-06-09; in-cluster Job renderer + keep-last-N pruning; pure logic unit-tested, live `→ gsutil ls` deferred to EP-37.)
- [x] EP-36: Backup-ownership policy: deploy warns on backup-excluded volumes (`retention = Delete`, verified via real CLI); disaster-recovery runbook + user guide updated; `scripts/restore-volume.sh` scratch-first restore added (live restore drill deferred to EP-37). (2026-06-09)
- [ ] EP-37: User guide written; SQLite-on-PVC and uploaded-files examples deploy with durable storage end to end.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- **EP-33 cleared the gating feasibility risk — and reframed it.** The feared deadlock (old + new
  revision both mounting a single-node RWO `local-path` PVC during a roll) does **not** occur:
  RWO is per-*node* and Nagare is single-node, so same-node pods co-mount freely. Live proof: new
  revisions reached Ready in 5–9s across rolls with zero `Multi-Attach`/`FailedMount` events, and
  the marker survived a revision roll, a full Service delete+recreate (different image), and a
  scale-to-zero → scale-from-zero cycle. The residual risk is a brief **concurrent-writer overlap**
  during Knative's create-before-delete roll — an *application* concern (SQLite needs WAL /
  Litestream), which **EP-37's SQLite example and user docs must call out**. Evidence:
  `docs/plans/33-…`, Surprises + Outcomes.

- **IP2 verified shape is final (input to EP-34).** The renderer in EP-34 must stamp, on any `ksvc`
  with a volume, the annotations `autoscaling.knative.dev/min-scale: "1"`,
  `autoscaling.knative.dev/max-scale: "1"`, `serving.knative.dev/rollout-duration: "0s"`, plus the
  `persistentVolumeClaim` `volumes` entry, the container `volumeMounts` (with `readOnly`), and a
  standalone PVC manifest (`storageClassName: local-path`, `accessModes: [ReadWriteOnce]`, requested
  size). Verbatim YAML is in EP-33's *Interfaces and Dependencies*.

- **Cluster access reality (operational).** The `config-features` ConfigMap already existed (only an
  `_example` key) — EP-33 patches it, it is not absent. The `nagare-01` VM is often `TERMINATED`;
  reach the cluster as the `deploy` user with `~/.ssh/id_ed25519` via `scripts/iap-ssh.sh` and run
  `sudo k3s kubectl` on the node (the workstation's default kubectl context points at an unrelated
  GKE cluster). Documented in `docs/runbooks/cluster-access.md`. EP-35/EP-36 live deploys need the
  VM started and the EP-33 flags applied (already enabled on the live cluster).

- **EP-34 delivered IP1/IP2/IP3; the renderer overrides `scale` for volume-bearing apps.** Any
  Service with ≥1 volume is stamped with min-scale=1/max-scale=1/rollout-duration=0s
  (`volumeAnnotationPairs`), **replacing** the author's `Scale` — required by EP-33 (single writer +
  stay warm). EP-37's docs must state that attaching a volume pins scaling. PVC discovery contract for
  EP-35/EP-36: `pvcName app vol == "nagare-vol-<app>-<vol>"`, labels `nagare.dev/managed-by:
  nagarectl` + `nagare.dev/app=<app>` + `nagare.dev/volume=<vol>` (query by label, never re-derive).
  `Deployment`/`ServerSite` PVC YAML is byte-identical (Server/Render delegates to Render). All 185
  `nagare-dsl` tests pass; existing stateless goldens unchanged.

- **EP-35 delivered deploy-time PVC provisioning + the `storage` command group (IP5).** `nagarectl
  deploy` now applies an app's PVCs before the Service (idempotent, never deletes), and
  `nagarectl storage list|inspect` discover PVCs by the IP3 labels. The shared `Nagare.Storage.Discover`
  module (`appPVCLabelSelector`, `listAppPVCs`, `PVCRow`, re-exported `pvcName`) and the `storage`
  subparser are EP-36's extension points — EP-36 adds `command "snapshot"` + a `StorageSnapshot`
  constructor and reuses the discovery helper (extend, not fork). **Live-cluster access constraint
  (input to EP-36/EP-37):** a workstation `kubectl` cannot reach the k3s API — IAP forwards only SSH
  (port 22). Run `nagarectl` on the VM, or SSH-forward 6443 over the port-22 tunnel
  (`ssh -L 16443:127.0.0.1:6443 …`) with `KUBECONFIG` pointed at a rewritten copy of
  `/etc/rancher/k3s/k3s.yaml`. EP-35's on-cluster transcript is deferred to EP-37 accordingly.

- **EP-36 delivered backup ownership + `storage snapshot` (IP4), extending EP-35's subparser (IP5).**
  Snapshots are file-level `tar.gz` to `gs://…/volumes/<app>/<volume>/<ts>.tar.gz` via a short-lived
  in-cluster Job (keep-last-N pruning); `retention = Delete` marks a volume backup-excluded and
  `nagarectl deploy` warns about it (the `RetentionPolicy` field is intentionally overloaded:
  disposable-disk *and* backup-excluded). `scripts/restore-volume.sh` restores scratch-first.
  **Surfaced gap for EP-37/EP-34:** EP-34's `attachVolume` only builds `Retain` volumes — a config
  must use a raw `Volume { … retention = Delete }` literal to opt out today; EP-37's docs should show
  that form (or EP-34 could add an `attachVolumeExcluded` preset). Live snapshot/restore transcripts
  are deferred to EP-37 (IAP/cluster-access).

- **Namespace deletion does NOT cascade-clean storage (input to EP-35/EP-36).** `kubectl delete
  namespace` left the Knative `ksvc`/route/revision and the PVC stuck on finalizers for minutes;
  explicit `delete ksvc` + `delete pvc` finalized it in ~85s, after which the `local-path` host
  directory was reclaimed (reclaimPolicy `Delete`). App/volume deletion in EP-35/EP-36 must delete
  the `ksvc` and PVCs **explicitly and in order**, and honor `RetentionPolicy` (`Retain` ⇒ do not
  delete the PVC). local-path PV node-path: `kubectl get pv <name> -o
  jsonpath='{.spec.local.path}'`; host dir naming `pvc-<uid>_<ns>_<pvc>` (feeds EP-35
  `storage list`/`inspect` node-path column).


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose Persistent Storage (roadmap Phase 3) into a MasterPlan with five child plans
  rather than the single ExecPlan the roadmap allows for the no-backup case.
  Rationale: the roadmap explicitly says "one MasterPlan if backup integration is included; otherwise
  one ExecPlan," and this initiative includes backup ownership (snapshot-to-GCS, retention, runbook).
  The MasterPlan shape also lets the high-risk cluster-enablement spike be isolated from the pure DSL
  work so they can proceed in parallel.
  Date: 2026-06-09

- Decision: Make the Knative PVC enablement-and-feasibility spike (EP-33) the first child plan, with
  no dependencies, and gate the rest of the initiative's *cluster-touching* behavior on it as a soft
  dependency.
  Rationale: research found the Knative `config-features` ConfigMap is absent from
  `cluster/bootstrap/knative-serving/`, so Knative Services cannot mount PVCs today, and there is a
  real open question whether a single-node `ReadWriteOnce` `local-path` PVC survives a Knative
  revision roll (old + new revision mount concurrently). The ExecPlan spec encourages an explicit
  spike to de-risk significant unknowns; isolating it prevents EP-34's golden files from encoding an
  unverified guess about what YAML the cluster accepts.
  Date: 2026-06-09

- Decision: Keep EP-34 (typed model + renderer) free of any *hard* dependency on EP-33, making the
  link a soft dependency plus the IP2 integration point.
  Rationale: the `Volume` type, JSON round-trip, and renderer are pure and fully golden-testable
  without a cluster, so the model work can begin immediately; only the *finalized* renderer goldens
  must wait for EP-33's verified YAML shape. This maximizes parallelism without letting EP-34 commit
  to an unverified output.
  Date: 2026-06-09

- Decision: Place `nagarectl storage snapshot` in the backup plan (EP-36), not with the other
  `storage` subcommands in EP-35.
  Rationale: snapshotting writes to the GCS backup bucket and honors the retention policy, so it is
  part of the backup-ownership concern, not the read-only inspection concern. EP-35 owns the
  `storage` subparser wiring and the read-only `list`/`inspect`; EP-36 extends that subparser with
  `snapshot` (Integration Point IP5), keeping each plan to one coherent functional concern.
  Date: 2026-06-09

- Decision: Reuse the typed `Quantity` newtype from `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` for
  volume sizes, the existing `local-path` StorageClass, the existing GCS bucket
  `tan-nb-exp-nagare-backups`, and the `nagare.dev/managed-by` label convention from MasterPlan 6,
  rather than introducing new primitives.
  Rationale: these already exist, are tested, and respect the repository's GCP project-isolation rule
  (`tan-nb-exp` only); reusing them keeps the surface small and consistent with sibling initiatives.
  Date: 2026-06-09

- Decision: Number the initiative MasterPlan as 7 and its children as EP-33 through EP-37 (the next
  sequential numbers; the init scripts assign them, continuing past EP-32, the last child of
  MasterPlan 6).
  Rationale: follows the repository's sequential numbering with no manual renumbering.
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
