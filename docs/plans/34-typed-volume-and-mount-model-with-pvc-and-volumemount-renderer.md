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

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `VolumeName`, `MountPath`, `AccessMode`, `RetentionPolicy`, `Volume` types and their
      smart constructors added to `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`; exports updated.
- [ ] M1: `volumes :: ![Volume]` field added to `Deployment` (and `ServerSite`) with an empty-list
      default; every existing config and fixture still compiles.
- [ ] M1: `attachVolume` overlay added to `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`.
- [ ] M1: unit tests for the new smart constructors and negative tests (relative mount path,
      duplicate name, bad size) pass.
- [ ] M2: `volumes` emitted in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`; decoded in
      `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` with a load-time uniqueness check; emit→decode
      round-trip test passes; fixture `Config.hs` with a volume added and load-and-render test
      passes.
- [ ] M3: `pvcName` helper, `renderVolumeClaims` (PVC manifest), and container/pod
      `volumeMounts`/`volumes` rendering added to `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` and
      mirrored in `cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs`; `ranks` table extended;
      golden `.service.yaml` and `.pvc.yaml` files created and passing.
- [ ] M3: goldens reconciled against EP-33's verified YAML shape and any required Service
      annotation stamped (see Decision Log when this is done).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Everything you need is named by full
path. Work happens entirely inside `cli/nagare-dsl/`, the self-contained Haskell library that
defines the typed deployment model and renders Kubernetes/Knative YAML.

The library is built and tested with `cabal`. Terms you will meet:

A **smart constructor** is a function named `mkX :: ... -> Either Text X` that validates its input
and returns `Left "message"` on bad input or `Right value` on good input. The matching newtype's
data constructor is **not exported**, so the only way to obtain an `X` from outside the module is
through `mkX`. That makes an invalid value *unrepresentable*. For example, in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` lines 92–101:

```haskell
mkServiceName :: Text -> Either Text ServiceName
mkServiceName t
  | Text.null t = Left "service name must not be empty"
  | Text.length t > 63 = Left ("service name too long ...")
  ...
  | otherwise = Right (ServiceName t)
```

and the read-only accessor at line 103:

```haskell
serviceNameText :: ServiceName -> Text
serviceNameText (ServiceName t) = t
```

The same file already contains the `Quantity` newtype you will reuse for volume size. Its
constructor (lines 246–279) validates a number plus an optional Kubernetes suffix:

```haskell
mkQuantity :: Text -> Either Text Quantity
mkQuantity t
  | Text.null t = Left "quantity must not be empty"
  | otherwise = ... if validSuffix rest1 then Right (Quantity t) else Left (...)
  where
    validSuffix s = s `elem` ["", "m", "k", "M", "G", "T", "P", "E", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei"]
```

So `mkQuantity "1Gi"` is `Right`, `mkQuantity "1Gigs"` is `Left "unrecognised quantity suffix..."`.

The **`Deployment`** record (lines 331–348) is the central value. It has no hidden constructor —
safety comes from each field's type:

```haskell
data Deployment = Deployment
  { name :: !ServiceName
  , namespace :: !Namespace
  , image :: !ImageRef
  , build :: !BuildSpec
  , domain :: !(Maybe Domain)
  , port :: !Port
  , env :: !(Map EnvName ScopedEnvVar)
  , resources :: !(Maybe Resources)
  , scale :: !(Maybe Scale)
  }
  deriving stock (Generic, Eq, Show)
```

You will add a `volumes :: ![Volume]` field to this record. Because the field is a list with an
empty default, every existing config still compiles **once you add `volumes = []` to each record
literal that builds a `Deployment` or `ServerSite`** (record construction in Haskell requires every
field to be named). The record literals that need `volumes = []` added are: the loader at
`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` (`toDeployment`, `toServerSite`), the preset at
`cli/nagare-dsl/src/Nagare/Dsl/Presets.hs` (`webService`), the test fixtures
`cli/nagare-dsl/test/Spec.hs` (`helloDep`) and `cli/nagare-dsl/test/ServerSpec.hs` (`notesApp`),
and the example configs under `cluster/examples/*/nagare/Config.hs` *only if* one of them constructs
a full record literal (most use the `webService` preset, which means they need no change). The
fixture `cli/nagare-dsl/test/fixtures/nagare/Config.hs` constructs a literal and will need
`volumes = []`. Audit with the grep in Concrete Steps before assuming a file is unaffected.

A neighbouring newtype you should read but **not** reuse is `FilePathText` in
`cli/nagare-dsl/src/Nagare/Dsl/Path.hs` (lines 34–41):

```haskell
mkFilePathText :: Text -> Either Text FilePathText
mkFilePathText t
  | Text.null t = Left "path must not be empty"
  | Text.isPrefixOf "/" t = Left ("path must be relative, not absolute: " <> t)
  | "\NUL" `Text.isInfixOf` t = Left ("path must not contain NUL characters: " <> t)
  | ".." `elem` Text.split (== '/') t = Left ("path must not contain a '..' segment: " <> t)
  | otherwise = Right (FilePathText t)
```

Note it *rejects* a leading `/`. Your `mkMountPath` must do the opposite (*require* a leading `/`)
while keeping the `..` and NUL guards. That is why a new newtype is correct, not a reuse.

The serialization layer is `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`. Its `deploymentJSON`
(lines 52–66) emits a **flat** JSON object: `cpuRequest`, `memoryRequest`, `scaleMin`, `scaleMax`
are top-level keys, and `env` is a list of discriminated objects built by `envJSON`. You will add a
single `"volumes" .= [...]` key here whose value is a list of per-volume objects.

The decoder is `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`. It defines an intermediate record
`JsonDeployment` (lines 126–139) with a `FromJSON` instance (lines 141–154) that reads the flat
JSON, then `toDeployment` (lines 159–193) re-runs every smart constructor, mapping each failure to
`MarshalError "<field>" "<message>"`. `MarshalError` is one variant of `LoadError` (lines 44–61).
You will add a `jdVolumes` field to `JsonDeployment`, a `toVolumes` step that re-validates each
volume and enforces uniqueness, and wire it into `toDeployment`.

The renderer is `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`. It serializes through
`Data.Yaml.Pretty.encodePretty` with a custom key comparator (`knativeConfig`, lines 85–131) driven
by a `ranks :: [(Text, Int)]` table that assigns each key a sort rank so the YAML key order is
deterministic and matches the cluster contract (it is **not** alphabetical). The container is built
by `containerValue` (lines 171–184) as `object (required <> optionals)`, where each helper such as
`resourcesField` (lines 232–238) returns `[Pair]` — an **empty list when the field is absent**, so
no empty YAML key is emitted. You will add a `volumeMountsField` helper to the container and a
`volumesField` helper to the pod spec (`specValue`, line 168), plus `pvcName`/`renderVolumeClaims`
producing standalone PVC manifests, and add `("volumeMounts", N)` and `("volumes", N)` to the
`ranks` table.

`cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs` defines `ServerSite` (lines 110–122), a parallel
record that already has `env`, `resources`, `scale`, and `domains :: ![Domain]`. Add the same
`volumes :: ![Volume]` field here. `cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs` mirrors the
`Render.hs` rendering logic (its own `ranks` table at lines 228–258, its own `containerValue` at
134–147). Add the same volume rendering there for parity.

The test suite is `cli/nagare-dsl/test/Spec.hs` (plus `ServerSpec.hs`, `StaticSpec.hs`,
`LoadSpec.hs`), built with **tasty** and **tasty-golden**. A golden test is written with
`goldenVsString "name" "test/golden/<file>" (pure (fromStrict (renderService fixture tag)))`: it
renders, then compares the bytes to the checked-in file at `test/golden/<file>`, failing with a diff
if they differ. The existing golden `cli/nagare-dsl/test/golden/hello.service.yaml` shows the exact
shape you are extending:

```yaml
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: '0'
        autoscaling.knative.dev/max-scale: '3'
    spec:
      containers:
      - image: gcr.io/knative-samples/helloworld-go:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: TARGET
          value: Nagare
        envFrom:
        - configMapRef:
            name: nagare-env-hello-runtime
            optional: true
        - secretRef:
            name: nagare-secret-hello-runtime
            optional: true
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
```

Negative tests (see `cli/nagare-dsl/test/ServerSpec.hs`, the `decodeFailureTests` group) assert a
precise `MarshalError "<field>"` by pattern-matching `Left (MarshalError f _) | f == field`.

The package's dependencies (`cli/nagare-dsl/nagare-dsl.cabal`) already include `aeson`, `yaml`,
`containers`, `generic-lens`, `lens`, `text`, `tasty`, `tasty-golden`, `tasty-hunit`. **No new
dependency is needed.** Do not edit `build-depends`. You *will* edit the test suite's
`other-modules` only if you add a new test module; this plan adds tests to the existing modules, so
no `.cabal` edit is required.

This plan is **EP-34**, a child of MasterPlan `docs/masterplans/7-persistent-storage-for-nagare.md`.
It owns three Integration Points the MasterPlan names: **IP1** (the typed `Volume` model and its
JSON shape), **IP2** (the rendered PVC / volume / volumeMount YAML shape), and **IP3** (the PVC
naming convention and labels). EP-35
(`docs/plans/35-deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands.md`)
and EP-36 consume all three. EP-33
(`docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md`) verifies IP2's YAML
against a live cluster; this plan's goldens must match that verified shape (see the Decision Log
entry on EP-33).


## Plan of Work

The work is three milestones. Each is independently verifiable with `cabal test` and leaves the
tree compiling.


### Milestone M1 — the typed model, smart constructors, presets overlay, and unit/negative tests

Scope: add the `Volume` type and its leaf types to the model, place an empty-default `volumes`
field on `Deployment` and `ServerSite`, add an `attachVolume` overlay, and prove the constructors
accept good input and reject bad input. At the end, the model compiles, every existing record
literal carries `volumes = []`, and unit tests pass — but nothing is serialized or rendered yet.

In `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, add four leaf types and the `Volume` record near the
end of the type definitions (before the `Deployment` record), and extend the module export list.

The `VolumeName` newtype is a DNS-1123 label, same character rules as `ServiceName` (1–63 chars,
lowercase letters/digits/hyphens, no leading/trailing hyphen). Reuse the existing private
`validLabelChar` helper (line 355). Its constructor:

```haskell
newtype VolumeName = VolumeName Text
  deriving stock (Generic, Eq, Ord, Show)

mkVolumeName :: Text -> Either Text VolumeName
mkVolumeName t
  | Text.null t = Left "volume name must not be empty"
  | Text.length t > 63 = Left ("volume name too long (" <> tshow (Text.length t) <> " chars, max 63)")
  | Text.isPrefixOf "-" t = Left "volume name must not start with a hyphen"
  | Text.isSuffixOf "-" t = Left "volume name must not end with a hyphen"
  | not (Text.all validLabelChar t) =
      Left ("volume name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise = Right (VolumeName t)

volumeNameText :: VolumeName -> Text
volumeNameText (VolumeName t) = t
```

The `MountPath` newtype requires an absolute path and forbids `..` and NUL:

```haskell
newtype MountPath = MountPath Text
  deriving stock (Generic, Eq, Ord, Show)

mkMountPath :: Text -> Either Text MountPath
mkMountPath t
  | Text.null t = Left "mount path must not be empty"
  | not (Text.isPrefixOf "/" t) = Left ("mount path must be absolute (start with '/'): " <> t)
  | "\NUL" `Text.isInfixOf` t = Left ("mount path must not contain NUL characters: " <> t)
  | ".." `elem` Text.split (== '/') t = Left ("mount path must not contain a '..' segment: " <> t)
  | otherwise = Right (MountPath t)

mountPathText :: MountPath -> Text
mountPathText (MountPath t) = t
```

`AccessMode` and `RetentionPolicy` are plain sum types with deriving — no smart constructor needed
because every constructor is valid:

```haskell
-- | Single-node access mode. Only 'ReadWriteOnce' today (Nagare is single-node).
data AccessMode = ReadWriteOnce
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | What happens to the underlying disk when the app is deleted. 'Retain' keeps
-- it (the default, safest); 'Delete' removes it. Read by EP-36 (backup).
data RetentionPolicy = Retain | Delete
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)
```

The `Volume` record:

```haskell
-- | A durable disk attached to an app. Every constrained field goes through a
-- smart constructor, so an illegal mount path or size cannot be written down.
-- Uniqueness of names and mount paths *within an app* is a cross-field
-- invariant enforced at load time (see Nagare.Dsl.Load.toVolumes), not here.
data Volume = Volume
  { volName    :: !VolumeName
  , size       :: !Quantity
  , mountPath  :: !MountPath
  , accessMode :: !AccessMode
  , readOnly   :: !Bool
  , retention  :: !RetentionPolicy
  }
  deriving stock (Generic, Eq, Show)
```

Then add `volumes :: ![Volume]` to the `Deployment` record (line 347, after `scale`) and export
`VolumeName`, `mkVolumeName`, `volumeNameText`, `MountPath`, `mkMountPath`, `mountPathText`,
`AccessMode (..)`, `RetentionPolicy (..)`, and `Volume (..)` in the module header.

In `cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs`, import `Volume` from `Nagare.Dsl.Types` (add it
to the import list at lines 35–45) and add `volumes :: ![Volume]` to the `ServerSite` record
(line 120, after `domains`).

In `cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`, add `volumes = []` to the `webService` record literal
(after `scale = Just sc`, line 62) and add the overlay helper plus export it:

```haskell
-- | Attach a durable volume to a deployment. Validates the volume name, size,
-- and mount path through the smart constructors; defaults accessMode to
-- ReadWriteOnce, readOnly to False, and retention to Retain (safest). Appends to
-- any existing volumes; the load-time uniqueness check (Nagare.Dsl.Load) is what
-- finally rejects a duplicate name or mount path, mirroring how mkScale rejects
-- max<min only at construction.
attachVolume :: Text -> Text -> Text -> Deployment -> Either Text Deployment
attachVolume nameText sizeText mountText dep = do
  vn <- mkVolumeName nameText
  sz <- mkQuantity sizeText
  mp <- mkMountPath mountText
  let v = Volume
            { volName = vn
            , size = sz
            , mountPath = mp
            , accessMode = ReadWriteOnce
            , readOnly = False
            , retention = Retain
            }
  pure (dep & #volumes %~ (<> [v]))
```

Add `volumes = []` to the `helloDep` literal in `cli/nagare-dsl/test/Spec.hs` and the `notesApp`
literal in `cli/nagare-dsl/test/ServerSpec.hs`, and to the `toDeployment`/`toServerSite` record
literals in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` (they will be filled properly in M2; for M1 a
literal `[]` keeps the tree compiling). Add `volumes = []` to the fixture
`cli/nagare-dsl/test/fixtures/nagare/Config.hs` record literal.

Add unit and negative tests to `cli/nagare-dsl/test/Spec.hs` `unitTests` group:

```haskell
, testGroup "mkVolumeName"
    [ testCase "accepts data" $ assertRight (mkVolumeName "data")
    , testCase "rejects empty" $ assertLeftContains "empty" (mkVolumeName "")
    , testCase "rejects uppercase" $ assertLeftContains "invalid" (mkVolumeName "Data")
    ]
, testGroup "mkMountPath"
    [ testCase "accepts /data" $ assertRight (mkMountPath "/data")
    , testCase "rejects relative" $ assertLeftContains "absolute" (mkMountPath "data")
    , testCase "rejects parent segment" $ assertLeftContains ".." (mkMountPath "/a/../b")
    , testCase "rejects empty" $ assertLeftContains "empty" (mkMountPath "")
    ]
```

Acceptance for M1: from `cli/nagare-dsl/`, `cabal build` succeeds and `cabal test` passes the new
`mkVolumeName`/`mkMountPath` groups. No serialization or rendering exists yet — that is expected.


### Milestone M2 — JSON round-trip with load-time uniqueness

Scope: emit `volumes` in `Config.hs`, decode them in `Load.hs` with a uniqueness check that rejects
duplicate names and duplicate mount paths as `MarshalError`, and prove the value survives the
emit→decode round-trip. At the end, a `Deployment` with volumes encodes to JSON and decodes back to
an equal value, and a fixture config carrying a volume loads and renders.

In `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, add a `"volumes"` key to `deploymentJSON` (after
`scaleMax`, line 65) and a `volumeJSON` helper in the `where` block:

```haskell
    , "volumes" .= map volumeJSON (dep ^. #volumes)
```

```haskell
    volumeJSON v =
      object
        [ "name" .= volumeNameText (v ^. #volName)
        , "size" .= quantityText (v ^. #size)
        , "mountPath" .= mountPathText (v ^. #mountPath)
        , "accessMode" .= accessModeText (v ^. #accessMode)
        , "readOnly" .= (v ^. #readOnly)
        , "retention" .= retentionText (v ^. #retention)
        ]
    accessModeText ReadWriteOnce = ("ReadWriteOnce" :: Text)
    retentionText Retain = ("Retain" :: Text)
    retentionText Delete = ("Delete" :: Text)
```

Add the same `"volumes" .= map volumeJSON (site ^. #volumes)` key and helper to `serverSiteJSON`
(after `domains`, line 183).

In `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, add a `JsonVolume` intermediate record and `FromJSON`
instance near `JsonEnvEntry` (after line 100):

```haskell
data JsonVolume = JsonVolume
  { jvName :: !Text
  , jvSize :: !Text
  , jvMountPath :: !Text
  , jvAccessMode :: !(Maybe Text)
  , jvReadOnly :: !Bool
  , jvRetention :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonVolume where
  parseJSON = withObject "Volume" $ \o ->
    JsonVolume
      <$> o .: "name"
      <*> o .: "size"
      <*> o .: "mountPath"
      <*> o .:? "accessMode"
      <*> o .:? "readOnly" .!= False
      <*> o .:? "retention"
```

Add `jdVolumes :: ![JsonVolume]` to `JsonDeployment` (after `jdScaleMax`, line 137) and to its
`FromJSON` instance with a default-empty parse so an older JSON without the key still decodes:

```haskell
      <*> o .:? "volumes" .!= []
```

Add a `toVolumes` step. It re-validates each volume and then enforces the two cross-field
uniqueness invariants, producing a precise `MarshalError` on a clash. Each error is keyed
`"volumes"` (or a sub-field) so the negative tests can match it:

```haskell
toVolume :: JsonVolume -> Either LoadError Volume
toVolume jv = do
  vn <- mapLeft (MarshalError "volumes.name") $ mkVolumeName (jvName jv)
  sz <- mapLeft (MarshalError "volumes.size") $ mkQuantity (jvSize jv)
  mp <- mapLeft (MarshalError "volumes.mountPath") $ mkMountPath (jvMountPath jv)
  am <- case fromMaybe "ReadWriteOnce" (jvAccessMode jv) of
    "ReadWriteOnce" -> Right ReadWriteOnce
    other -> Left (MarshalError "volumes.accessMode" ("unknown access mode: " <> other))
  rp <- case fromMaybe "Retain" (jvRetention jv) of
    "Retain" -> Right Retain
    "Delete" -> Right Delete
    other -> Left (MarshalError "volumes.retention" ("unknown retention policy: " <> other))
  Right Volume
    { volName = vn, size = sz, mountPath = mp
    , accessMode = am, readOnly = jvReadOnly jv, retention = rp
    }

toVolumes :: [JsonVolume] -> Either LoadError [Volume]
toVolumes jvs = do
  vols <- traverse toVolume jvs
  let names = map (volumeNameText . volName) vols
      paths = map (mountPathText . mountPath) vols
  ensureUnique "volumes" "duplicate volume name" names
  ensureUnique "volumes" "duplicate mount path" paths
  Right vols
  where
    ensureUnique field msg xs =
      case firstDup xs of
        Nothing -> Right ()
        Just d  -> Left (MarshalError field (msg <> ": " <> d))
    firstDup = go Set.empty
      where
        go _ [] = Nothing
        go seen (x : xs)
          | Set.member x seen = Just x
          | otherwise = go (Set.insert x seen) xs
```

(`Set` is already imported in `Load.hs` at line 28.) Wire `toVolumes` into `toDeployment`
(after `scale'`, before the final `Right Deployment {...}`):

```haskell
  vols' <- toVolumes (jdVolumes jd)
```

and set `volumes = vols'` in the `Deployment {...}` literal (replacing the temporary `volumes = []`
from M1). Do the same for `toServerSite`: add `jsvVolumes` to `JsonServerSite` and its instance
(default-empty), call `toVolumes`, and set `volumes = vols'`.

Add to the fixture `cli/nagare-dsl/test/fixtures/nagare/Config.hs` an `attachVolume`-built volume so
the load-and-render path exercises a real volume. Because the fixture builds a literal `Deployment`
through `Either String`, add a volume to the literal directly:

```haskell
      , volumes =
          [ Volume
              { volName = vol
              , size = volSize
              , mountPath = volMount
              , accessMode = ReadWriteOnce
              , readOnly = False
              , retention = Retain
              }
          ]
```

binding `vol <- mapLeft show (mkVolumeName "data")`, `volSize <- mapLeft show (mkQuantity "1Gi")`,
`volMount <- mapLeft show (mkMountPath "/data")` in the `do` block.

Add round-trip and negative tests to `cli/nagare-dsl/test/Spec.hs`:

```haskell
, testCase "deployment with a volume survives emit -> decode round-trip" $ do
    let dep = unsafe (attachVolume "data" "1Gi" "/data" helloDep)
    decodeDeployment (toStrict (encodeDeployment dep)) @?= Right dep
, testCase "duplicate volume name rejected as MarshalError volumes" $
    case decodeDeployment (jsonWithVolumes
            "[{\"name\":\"d\",\"size\":\"1Gi\",\"mountPath\":\"/a\"},\
            \{\"name\":\"d\",\"size\":\"1Gi\",\"mountPath\":\"/b\"}]") of
      Left (MarshalError "volumes" msg) -> assertContains "duplicate volume name" msg
      other -> assertFailure ("expected MarshalError volumes, got: " <> show other)
, testCase "duplicate mount path rejected as MarshalError volumes" $
    case decodeDeployment (jsonWithVolumes
            "[{\"name\":\"a\",\"size\":\"1Gi\",\"mountPath\":\"/x\"},\
            \{\"name\":\"b\",\"size\":\"1Gi\",\"mountPath\":\"/x\"}]") of
      Left (MarshalError "volumes" msg) -> assertContains "duplicate mount path" msg
      other -> assertFailure ("expected MarshalError volumes, got: " <> show other)
, testCase "relative mount path rejected as MarshalError volumes.mountPath" $
    case decodeDeployment (jsonWithVolumes
            "[{\"name\":\"a\",\"size\":\"1Gi\",\"mountPath\":\"data\"}]") of
      Left (MarshalError "volumes.mountPath" msg) -> assertContains "absolute" msg
      other -> assertFailure ("expected MarshalError volumes.mountPath, got: " <> show other)
, testCase "bad size rejected as MarshalError volumes.size" $
    case decodeDeployment (jsonWithVolumes
            "[{\"name\":\"a\",\"size\":\"1Gigs\",\"mountPath\":\"/a\"}]") of
      Left (MarshalError "volumes.size" _) -> pure ()
      other -> assertFailure ("expected MarshalError volumes.size, got: " <> show other)
```

with a `jsonWithVolumes` helper modelled on the existing `jsonWithBuild` (a minimal valid
`Deployment` JSON whose `volumes` array is the given literal):

```haskell
    jsonWithVolumes volsArr =
      TE.encodeUtf8 $
        "{\"name\":\"hello\",\"namespace\":\"personal\""
          <> ",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[]"
          <> ",\"volumes\":" <> volsArr <> "}"
```

Acceptance for M2: from `cli/nagare-dsl/`, `cabal test` passes the round-trip and all four negative
tests, and the existing `loadDeployment hello` test still passes (now with a volume in the fixture).


### Milestone M3 — the renderer: PVC manifest, volumeMounts/volumes, key ordering, ServerSite parity

Scope: render one standalone `PersistentVolumeClaim` per volume, add the container `volumeMounts`
and pod `volumes` stanzas to the Service, extend the key-ordering table so the output is
deterministic, mirror all of it in `Server/Render.hs`, and lock the output with golden files. At the
end, `renderVolumeClaims` produces PVC YAML and `renderService` produces a Service whose container
mounts each volume — both byte-matching checked-in goldens.

In `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`:

Add the deterministic naming helper and export it (add `pvcName` and `renderVolumeClaims` to the
module export list at lines 22–29):

```haskell
-- | The deterministic PVC name for an app/volume pair (MasterPlan IP3).
-- EP-35 and EP-36 must discover PVCs by the labels below, never re-derive this.
pvcName :: Text -> Text -> Text
pvcName app vol = "nagare-vol-" <> app <> "-" <> vol
```

Add the PVC manifest renderer. It produces one YAML document per volume; the helper renders a list
so a caller can write each, or `BS.intercalate "---\n"` them (as `renderServerDomainMappings` does):

```haskell
-- | Render one PersistentVolumeClaim manifest per declared volume (MasterPlan
-- IP2/IP3). storageClassName is the cluster's built-in 'local-path'; accessModes
-- is the single-node [ReadWriteOnce]; the requested size becomes
-- resources.requests.storage. Labels let EP-35/36 discover the PVC by app/volume.
renderVolumeClaims :: Deployment -> [ByteString]
renderVolumeClaims dep =
  map (YP.encodePretty knativeConfig . pvcValue app ns) (dep ^. #volumes)
  where
    app = serviceNameText (dep ^. #name)
    ns = namespaceText (dep ^. #namespace)

pvcValue :: Text -> Text -> Volume -> Value
pvcValue app ns v =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("PersistentVolumeClaim" :: Text)
    , "metadata" .= object
        [ "name" .= pvcName app (volumeNameText (v ^. #volName))
        , "namespace" .= ns
        , "labels" .= object
            [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
            , "nagare.dev/app" .= app
            , "nagare.dev/volume" .= volumeNameText (v ^. #volName)
            ]
        ]
    , "spec" .= object
        [ "accessModes" .= toJSON [accessModeText (v ^. #accessMode)]
        , "storageClassName" .= ("local-path" :: Text)
        , "resources" .= object ["requests" .= object ["storage" .= quantityText (v ^. #size)]]
        ]
    ]

accessModeText :: AccessMode -> Text
accessModeText ReadWriteOnce = "ReadWriteOnce"
```

Add the two stanza helpers. `volumeMountsField` goes on the container (the `optionals` list of
`containerValue`, line 181), `volumesField` goes on the pod `spec` (`specValue`, line 168). Each
returns `[Pair]` and is empty when there are no volumes, so no empty key is ever emitted (the
existing `resourcesField` convention):

```haskell
-- | The container 'volumeMounts:' block, one entry per volume (empty when none).
volumeMountsField :: [Volume] -> [Pair]
volumeMountsField [] = []
volumeMountsField vs = ["volumeMounts" .= toJSON (map mountEntry vs)]
  where
    mountEntry v =
      object
        [ "name" .= volumeNameText (v ^. #volName)
        , "mountPath" .= mountPathText (v ^. #mountPath)
        , "readOnly" .= (v ^. #readOnly)
        ]

-- | The pod 'volumes:' block, one persistentVolumeClaim entry per volume
-- referencing the deterministic PVC name (empty when none).
volumesField :: Text -> [Volume] -> [Pair]
volumesField _ [] = []
volumesField app vs = ["volumes" .= toJSON (map volEntry vs)]
  where
    volEntry v =
      object
        [ "name" .= volumeNameText (v ^. #volName)
        , "persistentVolumeClaim" .=
            object ["claimName" .= pvcName app (volumeNameText (v ^. #volName))]
        ]
```

Wire `volumeMountsField (dep ^. #volumes)` into `containerValue`'s `optionals` (append after
`resourcesField ...`), and change `specValue` so the pod spec carries the `volumes` block:

```haskell
specValue :: Deployment -> Text -> Value
specValue dep tag =
  object
    ( ["containers" .= toJSON [containerValue dep tag]]
        <> volumesField (serviceNameText (dep ^. #name)) (dep ^. #volumes)
    )
```

Extend the `ranks` table (lines 102–131) so the new keys order deterministically. Within the
container, `volumeMounts` should follow `resources`; within the pod spec, `volumes` should follow
`containers`; and within a PVC, `accessModes`/`storageClassName`/`resources`/`labels`/`storage`
order their objects. Add these entries (ranks need be distinct only within one object, so reuse is
safe):

```haskell
      , ("volumeMounts", 5)
      , ("volumes", 1)
      , ("mountPath", 1)
      , ("readOnly", 2)
      , ("persistentVolumeClaim", 1)
      , ("claimName", 0)
      , ("labels", 5)
      , ("accessModes", 0)
      , ("storageClassName", 1)
      , ("storage", 0)
```

Be careful: `("volumes", 1)` must place `volumes` after `containers` (rank 0) inside the pod spec.
`name` already has rank 2, which sits correctly before `mountPath`(1)? No — verify the within-object
order for each object you emit by reading the golden after the first run; adjust ranks until the
golden matches the intended order shown below. The exact numbers matter only relative to siblings in
the same object.

Mirror every change in `cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs`: add `pvcName` import (or
re-export it from `Render` and import it here, since `Server/Render` already imports
`managedConfigMapName`/`managedSecretName` from `Nagare.Dsl.Render`), add `renderServerVolumeClaims`,
the `volumeMountsField`/`volumesField` helpers (using `siteNameText (site ^. #name)` for the app
name, mirroring `serviceNameFor`/`envFromField`), wire them into that module's `containerValue` and
`specValue`, and add the same entries to its own `ranks` table (lines 228–258).

Now create the golden files. The intended Service shape (for a `helloDep` with one volume `data`,
size `1Gi`, mount `/data`) extends the existing `hello.service.yaml`:

```yaml
    spec:
      containers:
      - image: gcr.io/knative-samples/helloworld-go:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: TARGET
          value: Nagare
        envFrom:
        - configMapRef:
            name: nagare-env-hello-runtime
            optional: true
        - secretRef:
            name: nagare-secret-hello-runtime
            optional: true
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
        volumeMounts:
        - name: data
          mountPath: /data
          readOnly: false
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: nagare-vol-hello-data
```

The intended PVC manifest (`hello.pvc.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nagare-vol-hello-data
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/app: hello
    nagare.dev/volume: data
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
```

Add the golden tests to `cli/nagare-dsl/test/Spec.hs` `goldenTests`. Build a fixture deployment with
a volume (reuse `attachVolume`), render the Service to `test/golden/hello-volume.service.yaml`, and
intercalate the PVCs to `test/golden/hello-volume.pvc.yaml`:

```haskell
, goldenVsString
    "renderService hello with volume"
    "test/golden/hello-volume.service.yaml"
    (pure (fromStrict (renderService volumeDep "20260602-120000")))
, goldenVsString
    "renderVolumeClaims hello volume"
    "test/golden/hello-volume.pvc.yaml"
    (pure (fromStrict (BS.intercalate (BC.pack "---\n") (renderVolumeClaims volumeDep))))
```

with `volumeDep = unsafe (attachVolume "data" "1Gi" "/data" helloDep)` and the needed `BS`/`BC`
imports (mirror `ServerSpec.hs`'s `Data.ByteString qualified as BS` / `Data.ByteString.Char8 qualified as BC`).
Add the parallel ServerSite golden in `ServerSpec.hs` (a `notesApp` with one volume rendered through
`renderServerService` and `renderServerVolumeClaims`).

**Generate** the golden files by running the suite with tasty-golden's accept flag (it writes the
actual output to the golden path the first time), then **inspect** each generated file against the
intended shapes above before committing. If the key order differs, fix the `ranks` table — do not
edit the golden by hand to mask a wrong order.

**Reconcile with EP-33.** Before considering M3 done, open
`docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md` and compare its
verified `volumes`/`volumeMounts` stanza to your golden. If EP-33 specifies a required Service
annotation for single-node RWO rollout safety (for example a
`serving.knative.dev/rolloutDuration` or a min/max-scale constraint), add a helper that stamps that
annotation onto `templateValue`'s annotations whenever `dep ^. #volumes` is non-empty, regenerate
the golden, and note the reconciliation in the Decision Log. If EP-33 is not yet complete, leave a
clearly-marked note in Progress that the goldens are provisional pending EP-33, and keep the
annotation helper as a single well-named function so adding it later is a one-line change.

Acceptance for M3: from `cli/nagare-dsl/`, `cabal test` passes; the two new goldens exist and match
the intended shapes; the PVC name in both the Service `claimName` and the PVC `metadata.name` is
`nagare-vol-hello-data`; and the ServerSite parity golden passes.


## Concrete Steps

All commands run from the package directory unless noted:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
```

Before editing, find every record literal that builds a `Deployment` or `ServerSite`, so you know
exactly which files need a `volumes = []` (or a real volume) added once the field exists:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
grep -rn "Deployment$\|ServerSite$" --include=*.hs cli cluster/examples | grep -v "::"
grep -rln "= webService\|webService " cluster/examples cli/nagare-dsl/test
```

Apps that build through `webService` (the preset) need **no** change, because the preset's literal
already gets `volumes = []`. Apps that write a full record literal (the loader, the fixture
`cli/nagare-dsl/test/fixtures/nagare/Config.hs`, the test fixtures `helloDep`/`notesApp`) need the
field added.

Build after M1:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build 2>&1 | tail -20
```

Expected tail on success:

```text
[ 9 of 12] Compiling Nagare.Dsl.Presets
...
Linking ...
```

A missing-field error looks like this and tells you exactly which literal still needs `volumes`:

```text
error: [GHC-???] Fields of 'Deployment' not initialised: volumes
```

Run the full suite at any milestone:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test 2>&1 | tail -30
```

There is no `just` recipe for the DSL tests (the repository `justfile` has none), so `cabal test`
from this directory is the canonical command. Expected success tail:

```text
All N tests passed (0.NNs)
Test suite nagare-dsl-test: PASS
```

Generate (or regenerate) golden files for the new tests. tasty-golden writes the actual output into
the golden path when run with `--accept`:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test --test-options=--accept 2>&1 | tail -10
```

Then inspect the generated goldens against the intended shapes in M3 (use `git diff` to see exactly
what was written):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
git status --short cli/nagare-dsl/test/golden/
git --no-pager diff --stat cli/nagare-dsl/test/golden/
```

Run only the volume-related tests during development (tasty's `-p` pattern filter):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test --test-options='-p volume' 2>&1 | tail -20
```


## Validation and Acceptance

The change is "effective beyond compilation" through tests that fail before the feature exists and
pass after, plus golden files a human can read.

Behavioural acceptance, phrased as input → observable output:

Given a `Deployment` built with `attachVolume "data" "1Gi" "/data"`, `renderVolumeClaims` produces a
`PersistentVolumeClaim` YAML document whose `metadata.name` is `nagare-vol-hello-data`,
`metadata.labels."nagare.dev/managed-by"` is `nagarectl`, `spec.storageClassName` is `local-path`,
`spec.accessModes` is `[ReadWriteOnce]`, and `spec.resources.requests.storage` is `1Gi`. This is
the golden `cli/nagare-dsl/test/golden/hello-volume.pvc.yaml`.

Given the same `Deployment`, `renderService` produces a Knative Service whose container carries a
`volumeMounts` entry `{name: data, mountPath: /data, readOnly: false}` and whose pod spec carries a
`volumes` entry `{name: data, persistentVolumeClaim: {claimName: nagare-vol-hello-data}}`. This is
the golden `cli/nagare-dsl/test/golden/hello-volume.service.yaml`. The `claimName` in the Service
and the `metadata.name` in the PVC are identical, which is what makes the mount resolve on the
cluster.

Given malformed input, the loader rejects it with a precise `MarshalError`. Two duplicate volume
names produce:

```text
nagare: field 'volumes' failed validation: duplicate volume name: d
```

A relative mount path produces:

```text
nagare: field 'volumes.mountPath' failed validation: mount path must be absolute (start with '/'): data
```

(These are the `renderLoadError` renderings of the `MarshalError` values; the tests assert the
`MarshalError "<field>"` constructor and a substring of the message, exactly as the existing
`ServerSpec.hs` negative tests do.)

The exact test commands and what to look for:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test 2>&1 | tail -30
```

Look for `All N tests passed` and `Test suite nagare-dsl-test: PASS`. The new tests appear under the
groups `Nagare.Dsl.Types` (the `mkVolumeName`/`mkMountPath` cases), `Nagare.Dsl.Render` (the two new
goldens), the `Nagare.Dsl.Load` round-trip and negative cases, and the `Nagare.Dsl.Server` parity
golden.

To prove the tests are meaningful (fail before, pass after): temporarily change the expected PVC
name in a golden (or break `pvcName`) and re-run; the golden test must fail with a unified diff
showing the mismatch. Revert afterward.


## Idempotence and Recovery

Every step is repeatable and safe. The work is additive: new types, a new JSON key, new render
helpers, new tests. No file is deleted and no cluster is touched, so there is nothing to roll back
on a half-finished run beyond `git checkout` of the working tree.

`cabal build` and `cabal test` are idempotent — re-running them recompiles only what changed and
re-runs the suite. The golden tests are deterministic: the renderer takes a fixed image tag argument
(`"20260602-120000"` in the fixtures), so repeated runs produce byte-identical output.

Golden files are regenerated, never hand-edited to mask a real difference. To (re)generate them:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test --test-options=--accept
```

`--accept` writes the *actual* render output to each golden path. After running it, review
`git diff` on `cli/nagare-dsl/test/golden/` and confirm the bytes match the intended shapes in the
Plan of Work before committing. If a golden looks wrong, the fix is in the renderer or the `ranks`
ordering table, then regenerate — do not edit the golden by hand.

If a build fails with `Fields of 'Deployment'/'ServerSite' not initialised: volumes`, a record
literal somewhere still lacks the field; the grep in Concrete Steps lists every literal. Add
`volumes = []` (or a real volume in the fixture) and rebuild.

The JSON decoder reads `volumes` with `.:? "volumes" .!= []`, so an older JSON payload that predates
this field still decodes (to an empty volume list). This keeps the emit/decode round-trip
backward-compatible and means a partially-migrated tree never hard-fails on load.


## Interfaces and Dependencies

Libraries and modules used, and why: `aeson` (already a dependency) for the JSON emit in
`Nagare.Dsl.Config` and decode in `Nagare.Dsl.Load`; `yaml` (`Data.Yaml.Pretty`) for the
deterministic-key YAML in `Nagare.Dsl.Render` and `Nagare.Dsl.Server.Render`; `containers`
(`Data.Set`) for the load-time uniqueness check; `tasty` + `tasty-golden` + `tasty-hunit` for the
tests. **No new dependency is added**; do not edit `build-depends` in
`cli/nagare-dsl/nagare-dsl.cabal`.

These signatures must exist at the end of each milestone, by full module path.

At the end of **M1**, `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` exports:

```haskell
data VolumeName
mkVolumeName     :: Text -> Either Text VolumeName
volumeNameText   :: VolumeName -> Text
data MountPath
mkMountPath      :: Text -> Either Text MountPath
mountPathText    :: MountPath -> Text
data AccessMode  = ReadWriteOnce
data RetentionPolicy = Retain | Delete
data Volume = Volume
  { volName :: !VolumeName, size :: !Quantity, mountPath :: !MountPath
  , accessMode :: !AccessMode, readOnly :: !Bool, retention :: !RetentionPolicy }
-- and the Deployment record gains:  volumes :: ![Volume]
```

`cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs`: the `ServerSite` record gains `volumes :: ![Volume]`
(importing `Volume` from `Nagare.Dsl.Types`).

`cli/nagare-dsl/src/Nagare/Dsl/Presets.hs` exports:

```haskell
attachVolume :: Text -> Text -> Text -> Deployment -> Either Text Deployment
```

At the end of **M2**, `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`'s `deploymentJSON` and
`serverSiteJSON` emit a `"volumes"` array, and `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` provides
(internal, not necessarily exported):

```haskell
toVolume  :: JsonVolume -> Either LoadError Volume
toVolumes :: [JsonVolume] -> Either LoadError [Volume]
```

with `toDeployment` and `toServerSite` populating `volumes` and rejecting duplicate names or mount
paths as `MarshalError "volumes" ...`.

At the end of **M3**, `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` exports:

```haskell
pvcName            :: Text -> Text -> Text          -- "nagare-vol-<app>-<vol>"  (IP3)
renderVolumeClaims :: Deployment -> [ByteString]    -- one PVC manifest per volume (IP2)
```

and `renderService` includes the container `volumeMounts` and pod `volumes` stanzas when the
deployment has volumes. `cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs` exports the parallel
`renderServerVolumeClaims :: ServerSite -> ServerDeployContext -> [ByteString]` and renders the same
stanzas. `pvcName` is the single owner of the PVC naming convention; it is re-exported or imported
by `Server/Render` so the name is defined once.

Dependencies on other plans. This plan has **no hard dependency**. It *soft*-depends on **EP-33**
(`docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md`): the M3 goldens (the
`volumes`/`volumeMounts` shape and any rollout-safety Service annotation) must be reconciled against
EP-33's cluster-verified YAML before they are finalized — see the EP-33 entry in the Decision Log.
This plan's outputs are consumed by **EP-35**
(`docs/plans/35-deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands.md`),
which applies the PVC manifests `renderVolumeClaims` produces and discovers them by the
`nagare.dev/app`/`nagare.dev/volume` labels (never re-deriving `pvcName`), and by **EP-36**, which
reads the `RetentionPolicy` field for its backup-ownership policy. All three Integration Points the
MasterPlan (`docs/masterplans/7-persistent-storage-for-nagare.md`) assigns to EP-34 — IP1 (the typed
model and JSON shape), IP2 (the rendered PVC/volume/volumeMount YAML), and IP3 (the PVC naming and
labels) — are owned and delivered here.
