---
id: 34
slug: typed-volume-and-mount-model-with-pvc-and-volumemount-renderer
title: "Typed volume and mount model with PVC and volumeMount renderer"
kind: exec-plan
created_at: 2026-06-10T00:44:35Z
intention: "intention_01ktqfjpdqewga3t0rm9crehxx"
master_plan: "docs/masterplans/7-persistent-storage-for-nagare.md"
---

# Typed volume and mount model with PVC and volumeMount renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today a Nagare application is stateless. A developer writes a typed Haskell file at
`nagare/Config.hs` that builds a `Deployment` value (the record in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), and `nagarectl` turns that value into a Knative
`Service` — a Kubernetes object that runs a container and scales it up and down. When the
container restarts or scales to zero, everything it wrote to its own filesystem is lost. There
is no typed, app-level way to ask for a durable disk.

A **durable disk** in Kubernetes is requested through a **PersistentVolumeClaim** (PVC): a small
object that says "give me 1 gibibyte of storage." On this single-node k3s cluster the request is
satisfied by the built-in **`local-path`** StorageClass, which carves a directory out of the host
disk and mounts it into the pod. The path inside the container where that disk appears (for
example `/data`) is called a **volume mount**.

After this ExecPlan, a developer can declare durable storage directly in the typed config, like
this (the `attachVolume` helper is added by this plan):

```haskell
deployment =
  attachVolume "data" "1Gi" "/data"
    =<< webService "notes" "gcr.io/myproject/notes"
```

and the tooling produces two things the cluster understands: a standalone `PersistentVolumeClaim`
manifest (one per declared volume, named deterministically so other tools can find it), and the
matching `volumes`/`volumeMounts` stanzas inside the rendered Knative `Service` so the container
actually sees its disk at `/data`. Illegal storage — a duplicate volume name, a relative or
colliding mount path, a malformed size like `"1Gigs"` — is rejected at config-load time with a
precise error, exactly the way the existing model already rejects a bad image reference or an
out-of-range port.

This plan is **pure DSL work**: it adds types, a JSON round-trip, and a YAML renderer, all
covered by golden tests (tests that compare rendered output byte-for-byte against a checked-in
expected file). It does **not** touch the cluster, does not run `nagarectl deploy`, and has **no
hard dependency** on any other plan. You can implement and verify all of it on a laptop with no
Kubernetes access. The observable proof is a passing test suite that renders a PVC manifest and a
Service-with-volumes that match checked-in golden files, plus negative tests proving bad input is
rejected.

What someone can do after this change that they could not before: express "this app needs a 1Gi
durable disk mounted at `/data`" in the typed config and get correct, deterministic PVC and
Service YAML out of the renderer — the foundation that the deploy-time provisioner (EP-35) and the
backup tooling (EP-36) build on.

## Progress

- [x] M1: `VolumeName`, `MountPath`, `AccessMode`, `RetentionPolicy`, `Volume` types and their
      smart constructors added to `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`; exports updated. (2026-06-09)
- [x] M1: `volumes :: ![Volume]` field added to `Deployment` (and `ServerSite`) with an empty-list
      default; every existing config and fixture still compiles. (2026-06-09; `volumes = []` added to
      `webService`, loader literals, `helloDep`, `notesApp`, both test fixtures, and the full-literal
      examples `hello-knative-service`, `env-and-secrets`, `tanstack-start`.)
- [x] M1: `attachVolume` overlay added to `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`. (2026-06-09)
- [x] M1: unit tests for the new smart constructors and negative tests (relative mount path,
      duplicate name, bad size) pass. (2026-06-09)
- [x] M2: `volumes` emitted in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`; decoded in
      `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` with a load-time uniqueness check; emit→decode
      round-trip test passes. (2026-06-09; see Decision Log re: not adding a volume to the shared
      `hello` fixture — a dedicated `volumeDep` is used instead.)
- [x] M3: `pvcName` helper, `renderVolumeClaims` (PVC manifest), and container/pod
      `volumeMounts`/`volumes` rendering added to `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` and
      mirrored in `cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs`; `ranks` table extended;
      golden `.service.yaml` and `.pvc.yaml` files created and passing. (2026-06-09; 4 goldens,
      all 185 tests pass, no existing golden changed.)
- [x] M3: goldens reconciled against EP-33's verified YAML shape and the required rollout-safety
      Service annotation stamped (`volumeAnnotationPairs`: min-scale=1/max-scale=1/rollout-duration=0s
      when volumes present). (2026-06-09; byte-matches EP-33's IP2 stanza — see Decision Log.)

## Surprises & Discoveries

- **The actual `Deployment` record had drifted from the plan's snapshot.** It has `domains ::
  ![DomainSpec]` (not `domain :: !(Maybe Domain)`) and a `healthCheck :: !(Maybe HealthCheck)` field;
  `volumes` was appended after `healthCheck`. The full-literal sites needing `volumes = []` were
  therefore: `webService`, `toDeployment`/`toServerSite`, `helloDep`, `notesApp`, both nagare/server
  fixtures, and the examples `hello-knative-service`, `env-and-secrets`, `tanstack-start`. The
  record-update examples (`dockerfile-app`, `nixpacks-app`, `prebuilt-image-app`,
  `app-lifecycle-demo`) inherit `volumes` from `webService` and needed no change.

- **`volumeJSON` is a single top-level helper in `Config.hs`, shared by `deploymentJSON` and
  `serverSiteJSON`.** The plan suggested a per-`where`-block helper; one top-level function avoids
  duplicating the access-mode/retention token encoders.

- **PVC rendering is owned once, in `Render.hs`.** `Server/Render.hs` delegates to the exported
  `renderPersistentVolumeClaims` and reuses `volumeMountsField`/`volumesField`/`volumeAnnotationPairs`,
  so a `Deployment` and a `ServerSite` emit byte-identical PVC and volume YAML. The PVC-document key
  ranks live only in `Render.hs`; `Server/Render.hs`'s `ranks` only gained the *embedded* Service keys
  (`rollout-duration`, `volumeMounts`, `volumes`, `mountPath`, `readOnly`, `persistentVolumeClaim`,
  `claimName`).

- **`rollout-duration` renders unquoted as `0s`** (while `min-scale`/`max-scale` render quoted as
  `'1'`). This is correct and equivalent to EP-33's `"0s"`: `0s` is not a valid YAML number, so the
  pretty-printer emits it as a plain string scalar; a quoted-int like `1` must be quoted to stay a
  string. Both parse to the string Kubernetes annotation value.

- **A volume forces the rollout-safety annotations, *replacing* the author's `scale`.** Per EP-33, a
  writable RWO `local-path` volume must not have concurrent writers and must stay warm, so when
  `volumes` is non-empty the renderer stamps min-scale=1/max-scale=1/rollout-duration=0s and ignores
  the `Scale` field. This is a deliberate override, documented in the Decision Log, not a merge.

## Decision Log

- Decision: Reuse the existing `Quantity` newtype (from `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`)
  for a volume's requested size rather than introducing a new size type.
  Rationale: `mkQuantity` already validates Kubernetes quantity strings such as `"512Mi"`, `"1Gi"`,
  `"2"` (an integer/decimal followed by a recognised suffix in `m k M G T P E Ki Mi Gi Ti Pi Ei`),
  which is exactly the syntax a PVC's `resources.requests.storage` field expects. Reusing it keeps
  the validation surface small and consistent, and the MasterPlan's IP1 explicitly calls for it.
  Date: 2026-06-09

- Decision: Store volumes as `volumes :: ![Volume]` (a plain list) on `Deployment` and `ServerSite`,
  with a load-time uniqueness check on both volume names and mount paths, rather than as a
  `Map VolumeName Volume`.
  Rationale: a list preserves author-declared order (so the rendered YAML and goldens are
  deterministic without sorting decisions leaking into the model) and matches the existing
  `domains :: ![Domain]` field on `ServerSite`. A `Map` keyed on name would silently de-duplicate a
  repeated name and could not catch a duplicate *mount path* at all, whereas the requirement is that
  duplicates produce a precise `MarshalError`. The empty list `[]` is the backward-compatible
  default so every existing config compiles unchanged.
  Date: 2026-06-09

- Decision: Introduce a new `MountPath` newtype with `mkMountPath` that requires an **absolute**
  path (a leading `/`), forbids any `..` segment and NUL, rather than reusing `FilePathText` from
  `cli/nagare-dsl/src/Nagare/Dsl/Path.hs`.
  Rationale: `FilePathText` is deliberately the opposite — it *rejects* absolute paths because it
  models a path *inside the project/build context*. A container mount path must be absolute
  (Kubernetes requires `volumeMounts[].mountPath` to start with `/`). The two constraints are
  contradictory, so a separate validator is correct, not a reuse.
  Date: 2026-06-09

- Decision: Model `AccessMode` as a sum type whose only constructor is `ReadWriteOnce`.
  Rationale: Nagare is intentionally single-node (see MasterPlan 7 scope), so `ReadWriteMany` is out
  of scope. Modelling it as a one-constructor sum (rather than hard-coding the string in the
  renderer) keeps the field present in the type and the JSON for forward-compatibility and lets a
  future plan add modes without changing call sites that already pattern-match exhaustively.
  Date: 2026-06-09

- Decision: Model retention as `data RetentionPolicy = Retain | Delete`, carried in the typed model.
  Rationale: this is the value EP-36 (backup ownership) reads to decide whether a volume's
  underlying disk is kept or deleted when the app is removed, and to drive its include/exclude
  backup warning. Placing it in the model now (IP1) means EP-36 reads a loaded `Deployment`, never
  re-parses JSON.
  Date: 2026-06-09

- Decision: Name PVCs deterministically as `nagare-vol-<app>-<volume>` and stamp the labels
  `nagare.dev/managed-by: nagarectl`, `nagare.dev/app: <app>`, `nagare.dev/volume: <volume>` on
  every rendered PVC, exposing a `pvcName :: Text -> Text -> Text` helper from
  `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`.
  Rationale: EP-35 and EP-36 must *discover* an app's PVCs by label
  (`kubectl get pvc -l nagare.dev/app=<app>`) and join a PVC back to its app/volume, never
  re-derive the name by hand. The `nagare.dev/managed-by: nagarectl` key aligns with the label
  EP-29 (MasterPlan 6) stamps on Services, so all Nagare-managed objects share one convention.
  This is MasterPlan IP3, owned by this plan.
  Date: 2026-06-09

- Decision: Treat EP-33 (`docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md`)
  as a **soft** dependency and reconcile the renderer goldens against its verified YAML before
  finalizing M3.
  Rationale: EP-33 produces the canonical, cluster-verified `volumes`/`volumeMounts` stanza and
  determines whether a single-node `ReadWriteOnce` PVC needs a rollout-safety annotation on the
  Service (so the old and new revisions of a Knative rollout do not deadlock on the mount). The pure
  model and renderer can be written first against the shape below, but the goldens are not "final"
  until they byte-match EP-33's proof. If EP-33 reports a required Service annotation, the renderer
  must stamp it on any Service that declares at least one volume.
  Date: 2026-06-09

- Decision: RESOLVED — EP-33 (now Complete) verified the IP2 shape and finalized the rollout-safety
  annotation set, and EP-34's renderer reproduces it exactly. The renderer stamps
  `autoscaling.knative.dev/min-scale: "1"`, `autoscaling.knative.dev/max-scale: "1"`, and
  `serving.knative.dev/rollout-duration: "0s"` (via `volumeAnnotationPairs`) on any Service whose
  `volumes` list is non-empty, **replacing** the author's `scale` annotations for that Service.
  Rationale: EP-33 proved a single-node RWO `local-path` PVC survives a Knative revision roll without
  a Multi-Attach deadlock, but that a writable volume must avoid concurrent writers and stay warm —
  exactly what min=max=1 + immediate cutover provide. The goldens
  `cli/nagare-dsl/test/golden/hello-volume.service.yaml` and `…/server-site-volume.service.yaml`
  byte-match EP-33's recorded IP2 stanza (`rollout-duration` renders unquoted `0s`, equivalent to
  EP-33's `"0s"` — both are string scalars).
  Date: 2026-06-09

- Decision: Do NOT add a volume to the shared `hello` fixture
  (`cli/nagare-dsl/test/fixtures/nagare/Config.hs`) or to `helloDep`/`notesApp`; use a dedicated
  `volumeDep`/`notesVolApp` for the volume round-trip and render goldens instead.
  Rationale: the plan suggested adding a volume to the hello fixture, but `helloDep` feeds the
  `dep @?= helloDep` load assertion and the *shared* `hello.service.yaml` golden, and `buildOnlyDep`/
  `richDep`/the build-spec fixtures all derive from `helloDep` by record update. Adding a volume there
  would have rippled volume YAML (and the rollout-annotation override) into many unrelated goldens and
  broken the load-equality test. A separate `volumeDep = attachVolume "data" "1Gi" "/data" helloDep`
  keeps the stateless goldens byte-identical (confirmed: no existing golden changed) while still
  exercising load round-trip, uniqueness, and the new render path. The `hello` fixtures carry only
  `volumes = []`.
  Date: 2026-06-09

## Outcomes & Retrospective

**Result: all three milestones complete; IP1, IP2, and IP3 delivered. All 185 `nagare-dsl` tests
pass; no existing golden changed (full backward compatibility).**

- **IP1 (typed model + JSON).** `Volume` plus `VolumeName`/`MountPath`/`AccessMode`/`RetentionPolicy`
  live in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` with smart constructors; `volumes :: ![Volume]`
  (empty default) is on both `Deployment` and `ServerSite`. `Config.hs` emits `volumes`; `Load.hs`
  decodes it and enforces name + mount-path uniqueness as `MarshalError "volumes"`. The emit→decode
  round-trip is golden via `volumeDep`. `attachVolume` is the ergonomic overlay.

- **IP2 (rendered shape).** `renderVolumeClaims`/`renderServerVolumeClaims` emit one PVC manifest per
  volume; the Service carries container `volumeMounts`, pod `volumes`, and the EP-33 rollout-safety
  annotations. Goldens byte-match EP-33's verified stanza.

- **IP3 (naming + labels).** `pvcName app vol == "nagare-vol-<app>-<vol>"` is the single owner of the
  PVC name; every PVC carries `nagare.dev/managed-by: nagarectl`, `nagare.dev/app`, `nagare.dev/volume`
  for EP-35/EP-36 discovery.

- **Gaps / notes for downstream plans.** (1) EP-35 must discover PVCs by the IP3 labels (e.g.
  `kubectl get pvc -l nagare.dev/app=<app>`) and apply `renderVolumeClaims` *before* the Service, and
  honor `RetentionPolicy` on delete (EP-33 found namespace deletion does not cascade-clean PVCs). (2)
  The rollout-safety annotations *override* the author's `scale` for any volume-bearing app — EP-37's
  docs should state this so users aren't surprised their `scale` is ignored when they attach a volume.
  (3) `accessMode` is a one-constructor sum (`ReadWriteOnce`); the JSON/loader already reject unknown
  modes, so a future `ReadWriteMany` is an additive change.

- **Deviation from the plan.** The plan's "add a volume to the hello fixture" step was replaced by a
  dedicated `volumeDep`/`notesVolApp` to avoid rippling volume YAML into unrelated shared goldens (see
  Decision Log). Net effect is stronger: stateless goldens are provably unchanged *and* the volume
  path is fully exercised.

