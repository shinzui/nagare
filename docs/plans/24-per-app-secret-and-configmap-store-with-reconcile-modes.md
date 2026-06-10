---
id: 24
slug: per-app-secret-and-configmap-store-with-reconcile-modes
title: "Per-app Secret and ConfigMap store with reconcile modes"
kind: exec-plan
created_at: 2026-06-09T23:52:37Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
master_plan: "docs/masterplans/5-environment-and-secret-management-for-nagare.md"
---

# Per-app Secret and ConfigMap store with reconcile modes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare deploys small apps to a Kubernetes cluster (Knative Serving). Each app needs
two kinds of configuration that live outside the deploy file itself: ordinary
environment variables (non-secret strings like `LOG_LEVEL=info`) and secrets
(sensitive strings like `DATABASE_URL=postgres://...`). Today there is no place to
*put* those values: the deploy file can name a secret reference, but nothing writes
the secret, and there is no per-app store an operator can read, edit, and re-apply.

This plan delivers that missing piece: a single, tested Haskell library module,
`cli/nagarectl/src/Nagare/Env/Store.hs`, that any command can call to **read**,
**merge or replace**, and **write** a per-app, per-scope key/value store. Non-secret
values are stored in a Kubernetes **ConfigMap** (an unencrypted bag of strings the
cluster injects into the container as environment variables). Secret values are
stored in a Kubernetes **Secret** (the same shape, but values are base64-encoded and
the cluster treats it as sensitive). The resource *names* the store creates are not
invented here — they come from helper functions defined in a sibling plan (EP-23) so
that the names match exactly what the rendered Knative Service is already looking for
via its `envFrom` list. That match is the whole point: write the store, redeploy (or
let Knative pick it up), and the app sees the new variables.

After this change, the following becomes possible — and is proven by unit tests in
this plan and exercised end-to-end by later plans:

- A pure function `reconcile` computes the desired key/value set from an existing set
  and an incoming set, in one of two modes. **Merge** keeps existing keys and lets
  incoming keys win on collision. **ReconcileExact** makes the incoming set the entire
  store, dropping any existing-only keys. A single-key *set* or *delete* is expressed
  through the same function.
- Pure renderers turn a key/value map into the exact JSON bytes that
  `kubectl apply -f` accepts for a ConfigMap (plaintext values) or a Secret
  (base64-encoded values), under the IP2 resource name for the given app and scope.
- Pure extractors parse what `kubectl get ... -o json` prints back into a key/value
  map; the Secret extractor base64-decodes, so a value survives a full
  render → apply → get → extract round-trip unchanged.
- A thin IO layer reads and writes those resources against the live cluster, treating
  a missing resource as an empty store (so a never-configured app is not an error) and
  a *present-but-malformed* resource as a hard error (so we never silently lose data).

What a human can verify after this plan: run the unit tests and watch the reconcile,
base64 round-trip, and rendering assertions pass; and, against a live cluster (the
optional manual check in Milestone 2), `kubectl apply -f` a rendered ConfigMap and see
a resource named `nagare-env-<app>-runtime` appear with the expected keys.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Confirmed EP-23 is merged and exports `EnvScope`, `scopeToken`,
      `managedConfigMapName`, `managedSecretName` from the `nagare-dsl` library
      (EP-23 marked Complete in the MasterPlan registry). (2026-06-09)
- [x] base64 codec resolved: used `Data.ByteArray.Encoding` from the `memory`
      package (already a `nagarectl` dependency) instead of adding `base64` —
      no cabal `build-depends` change, no nix-flake resolution risk. Isolated in
      `b64encode`/`b64decode`. (See Decision Log.) (2026-06-09)
- [x] M1: Created `cli/nagarectl/src/Nagare/Env/Store.hs` with the pure layer:
      `ReconcileMode`, `reconcile`, `renderEnvConfigMap`, `renderEnvSecret`,
      `extractConfigMapData`, `extractSecretData`. (2026-06-09)
- [x] M1: Added `Nagare.Env.Store` to `exposed-modules` (not `other-modules`) in
      `cli/nagarectl/nagarectl.cabal` — the test-suite is an external consumer of
      the library and cannot see `other-modules`. (See Decision Log.) (2026-06-09)
- [x] M1: Added a tasty test group `Nagare.Env.Store` to
      `cli/nagarectl/test/Spec.hs` (10 cases) covering reconcile (both modes),
      base64 round-trip, plaintext round-trip, apply-able ConfigMap/Secret JSON
      with the IP2 names + `Opaque` type + on-the-wire base64 encoding, and the
      malformed-input (no silent loss) cases. (2026-06-09)
- [x] M1: `cd cli/nagarectl && cabal test` is green (62 tests, +10). (2026-06-09)
- [x] M2: Added the thin kubectl IO layer (`readEnvStore`, `readSecretStore`,
      `writeEnvStore`, `writeSecretStore`) to `Nagare.Env.Store` in the same file. (2026-06-09)
- [x] M2: `cd cli/nagarectl && cabal build` is green (IO layer compiles; both
      `nagarectl` and `nagared` executables link). (2026-06-09)
- [x] M2: Manual live-cluster check **skipped** — it is optional and no live
      cluster is exercised in this session. The IO layer is verified by compilation
      against `cradle`/`applyManifests`; EP-25/EP-28 exercise it against
      `tan-nb-exp` end to end. (2026-06-09)
- [x] Filled in Outcomes & Retrospective. (2026-06-09)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Mirror `cli/nagarectl/src/Nagare/Static/Release.hs` structure exactly —
  a pure layer (types, JSON render, extract) separated from a thin kubectl IO layer.
  Rationale: that module is the established, reviewed pattern in this repo for
  "store a small per-resource blob in a ConfigMap and round-trip it through
  `kubectl`." Reusing the shape keeps the schema unit-testable without a cluster and
  makes the code reviewable by analogy. The masterplan (IP4) explicitly directs this.
  Date: 2026-06-09.

- Decision: Store secret values base64-encoded in a Kubernetes `Secret` (`data`
  field, type `Opaque`); store non-secret values in plaintext in a `ConfigMap`
  (`data` field). Rationale: this is exactly how Kubernetes models the two resource
  kinds, and it is what `envFrom` (IP3, EP-23) expects. base64 is an *encoding*, not
  encryption — see the security caveat in Context and Orientation. Date: 2026-06-09.

- Decision: `Merge` is the default reconcile mode for callers; `ReconcileExact` is
  opt-in (it is the destructive one). Rationale: a `set` of one key should never
  silently delete the operator's other variables; only an explicit `sync --exact`
  (EP-25) should. Making `Merge` the conservative default matches least-surprise.
  This plan does not pick a default in the type itself (callers pass the mode), but
  documents `Merge` as the intended default for the EP-25 CLI. Date: 2026-06-09.

- Decision: Add the `base64` Haskell package (not `base64-bytestring`) to
  `nagarectl.cabal`. Rationale: neither is currently a dependency of `nagarectl`
  (verified: `grep -rn base64 cli/` returns nothing). `base64` (the modern API by the
  same author as `base64-bytestring`) exposes `Data.Base64.Types` and
  `encodeBase64'`/`decodeBase64Untyped` over strict `ByteString`, which is the type we
  already hold. If the nix flake's package set pins only `base64-bytestring`, fall
  back to it (`Data.ByteString.Base64.encode`/`decode`) — the Store module isolates
  the choice behind two private helpers `b64encode`/`b64decode` so the rest of the
  code is unaffected. Resolve the actual availability during implementation and record
  it here. Date: 2026-06-09.

- Decision (RESOLVED at implementation): Used **neither** `base64` nor
  `base64-bytestring`; instead used `convertToBase`/`convertFromBase Base64` from
  `Data.ByteArray.Encoding` in the **`memory`** package, which is already a
  `build-depends` of the `nagarectl` library (alongside `crypton`). Rationale: the
  build runs under a nix flake whose Haskell package set is the source of truth; both
  base64 packages are only in the local Hackage cache, not confirmed in the flake set,
  so adding either risked an unresolved dependency. `memory` is guaranteed present (it
  already builds), so reusing it adds zero dependency-resolution risk and no cabal
  `build-depends` change at all. The codec choice stays isolated behind the two
  private helpers `b64encode`/`b64decode` exactly as the original decision intended, so
  swapping to `base64` later is a two-line change. `convertFromBase` returns
  `Either String ByteString`, so malformed base64 is a `Left` (no silent loss),
  satisfying the contract. Date: 2026-06-09.

- Decision: Registered `Nagare.Env.Store` under `exposed-modules` (not
  `other-modules`) of the library stanza. Rationale: the `nagarectl-test` suite
  depends on the `nagarectl` library as an external package, and Cabal does not expose
  a library's `other-modules` to external consumers; the test could not import the
  module otherwise. The plan anticipated this fallback. The executables also gain
  direct access for EP-25/EP-27. Date: 2026-06-09.

- Decision: A *missing* resource (kubectl exits non-zero) reads as `Right` empty map;
  a *present-but-malformed* one reads as `Left`. Rationale: identical to
  `readReleaseLog`/`extractReleaseLog` — never treat malformed data as "empty" because
  that would silently overwrite real values on the next write. Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-09): complete.** `cli/nagarectl/src/Nagare/Env/Store.hs` exists
with the full public contract from Interfaces and Dependencies, unchanged: the pure
`reconcile` (both modes), `renderEnvConfigMap`/`renderEnvSecret`,
`extractConfigMapData`/`extractSecretData`, and the thin IO layer
`readEnvStore`/`readSecretStore`/`writeEnvStore`/`writeSecretStore`. The names come
from EP-23's IP2 helpers (imported, never re-derived), so the store writes exactly
the resources the rendered Service's `envFrom` references. 10 new unit tests pass
(62 total); the library and both executables build.

**Against the purpose:** the missing per-app, per-scope store now exists and is
tested without a cluster — reconcile semantics, the base64 round-trip, the
apply-able manifests with the right names/type, and the strict "malformed ≠ empty"
rule are all proven. EP-25 (CLI) and EP-27 (build/preview) can consume the stable
signatures.

**Notes / lessons:**
- The single non-trivial deviation from the written plan is the base64 codec: used
  the already-present `memory` package rather than adding `base64`, eliminating a
  dependency-resolution risk under the nix flake. Recorded in the Decision Log; the
  `b64encode`/`b64decode` isolation the plan mandated made this a clean swap.
- `exposed-modules` (not `other-modules`) was required so the external test suite can
  import the module — also recorded.
- The live-cluster check was skipped (optional); the IO layer is covered by
  compilation and will be exercised end to end by EP-28.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before
editing.

### Where the code lives

`nagarectl` is the deploy CLI, a Haskell (GHC 9.12, `cabal`) project built through a
nix flake. Its library sources are under `cli/nagarectl/src/`, its tasty test suite is
the single file `cli/nagarectl/test/Spec.hs`, and its build configuration is
`cli/nagarectl/nagarectl.cabal`. A sibling library, `nagare-dsl`, under
`cli/nagare-dsl/`, holds the typed deployment model and the Knative manifest renderer;
`nagarectl` already depends on it.

You will create exactly one new source file, `cli/nagarectl/src/Nagare/Env/Store.hs`,
register it in the cabal file, and add tests to `cli/nagarectl/test/Spec.hs`.

### The template you are mirroring: `Nagare.Static.Release`

The file `cli/nagarectl/src/Nagare/Static/Release.hs` already does, for a different
payload (a per-site release history), exactly what this plan does for env/secret
key/value maps. Study it; your module mirrors its structure. The relevant patterns:

**Rendering JSON that `kubectl apply -f` accepts.** Kubernetes manifests are usually
YAML, but JSON is a subset of YAML, so a JSON document is a valid manifest. `Release`
builds an Aeson `Value` and serialises it with `encode`, then `kubectl apply -f` reads
the bytes from a temp file. The shape is:

```haskell
renderReleaseConfigMap :: Text -> Text -> StaticReleaseLog -> ByteString
renderReleaseConfigMap site ns logv =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("ConfigMap" :: Text)
      , "metadata"
          .= object
            [ "name" .= configMapName site
            , "namespace" .= ns
            ]
      , "data"
          .= object
            [ Key.fromText releaseDataKey .= TE.decodeUtf8 (LBS.toStrict (encode logv))
            ]
      ]
```

Your renderers produce the same outer envelope (`apiVersion`/`kind`/`metadata`/
`data`), but the `data` object is the key/value map itself (one JSON string per entry),
not a single serialised blob under one key. The Secret renderer adds
`"type" .= ("Opaque" :: Text)` and base64-encodes each value.

**Extracting from `kubectl get -o json`.** `kubectl get configmap <name> -o json`
prints a JSON object whose `data` field is a map of string → string. `Release` parses
it defensively: a decode failure is `Left`, a ConfigMap with no `data` is the empty
log, anything else is parsed. The shape is:

```haskell
extractReleaseLog :: ByteString -> Either Text StaticReleaseLog
extractReleaseLog bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode ConfigMap JSON: " <> T.pack e)
    Right cm -> case lookupData cm of
      Nothing -> Right emptyReleaseLog
      Just inner -> ...
```

Your extractors read the entire `data` object into a `Map Text Text`. The ConfigMap
extractor takes the values as-is; the Secret extractor base64-*decodes* each value (a
decode failure there is a `Left`, never silent loss).

**The thin kubectl IO layer.** `Release` shells out through the `cradle` process
library. `cradle` builds a command value with `cmd "kubectl"` and `& addArgs [...]`,
runs it with `run`, and lets you capture stdout as raw bytes via the `StdoutRaw`
pattern and suppress the child's stderr via `silenceStderr`. A non-zero exit is read
as "resource absent." The shape is:

```haskell
readReleaseLog :: Text -> Text -> IO (Either Text StaticReleaseLog)
readReleaseLog site ns = do
  (exitCode, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", "configmap", T.unpack (configMapName site), "-n", T.unpack ns, "-o", "json"]
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> Right emptyReleaseLog
    ExitSuccess -> extractReleaseLog out
```

In plain words: `cmd`/`addArgs` assemble an argv; `run` executes it; `StdoutRaw out`
binds the child's standard output as a strict `ByteString`; `silenceStderr` throws away
the child's standard-error text (so a "NotFound" message does not clutter our output);
`ExitFailure`/`ExitSuccess` come from `System.Exit`. Your `readEnvStore`/
`readSecretStore` follow this verbatim, swapping `configmap`/`secret` and the IP2
resource name, and returning an empty `Map` on `ExitFailure`.

**The write path reuses `applyManifests`.** `Release.writeReleaseLog` is one line:

```haskell
writeReleaseLog site ns logv =
  applyManifests [renderReleaseConfigMap site ns logv]
```

`Nagare.Deploy.applyManifests` (in `cli/nagarectl/src/Nagare/Deploy.hs`) takes a list
of manifest `ByteString`s, writes each to a temp file, and runs
`kubectl apply -f <file>`:

```haskell
applyManifests :: [BS.ByteString] -> IO ()
applyManifests = mapM_ applyOne
  where
    applyOne m = withSystemTempFile "nagare-manifest.yaml" $ \fp h -> do
      BS.hPut h m
      hClose h
      run_ $ cmd "kubectl" & addArgs ["apply", "-f", fp]
```

Your `writeEnvStore`/`writeSecretStore` are likewise one-liners that call
`applyManifests` with the rendered manifest.

### ConfigMap vs Secret, and what base64 is (and is not)

A **ConfigMap** is a Kubernetes object holding a flat map of string keys to string
values, stored *in cleartext* in the cluster's datastore. It is meant for non-secret
configuration. An app gets its values as environment variables when the Pod spec
references the ConfigMap via `envFrom`.

A **Secret** is the same flat map, but values are written base64-encoded under the
`data` field, the object is typed `Opaque`, and the cluster treats it as sensitive
(RBAC, optional encryption-at-rest configured at the cluster level). An app consumes a
Secret the same way (via `envFrom`), and Kubernetes decodes the base64 before injecting
the variable.

**base64 is an encoding, not encryption.** It maps arbitrary bytes to a printable-ASCII
string and back, with no key and no secrecy: anyone holding the encoded text can decode
it. We base64-encode Secret values only because the Kubernetes Secret `data` field
*requires* base64 — it is the wire format, not a protection. The actual protection for
secret values (encryption of the cluster datastore at rest, RBAC on who can `get`
Secrets) is a property of the *cluster configuration* and is explicitly **out of scope
for this plan**; it is owned by the infrastructure plans that stand up the cluster. A
later docs plan (EP-28) restates this caveat for operators. The Store module documents
it in its Haddock header so no reader mistakes base64 for security.

### The names come from EP-23 (do not re-derive them)

A separate plan, `docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md`
(EP-23), defines the *scope* concept and the *naming* helpers, and exports them from
the `nagare-dsl` library. A **scope** answers "*when* does this variable apply?" — at
runtime, at build time, or only in preview deployments. The type and helpers are:

```haskell
-- Exported by nagare-dsl (EP-23). Import; do not redefine.
data EnvScope = Runtime | Build | Preview

scopeToken :: EnvScope -> Text                    -- "runtime" / "build" / "preview"
managedConfigMapName :: Text -> EnvScope -> Text  -- "nagare-env-<app>-<scope>"
managedSecretName :: Text -> EnvScope -> Text     -- "nagare-secret-<app>-<scope>"
```

For example, `managedConfigMapName "notes" Runtime == "nagare-env-notes-runtime"` and
`managedSecretName "notes" Runtime == "nagare-secret-notes-runtime"`. Per the master
plan's Integration Point IP2, `EnvScope` and `scopeToken` live in
`Nagare.Dsl.Types` and the two name helpers live in `Nagare.Dsl.Render`; both modules
are re-exported by the `nagare-dsl` library that `nagarectl` already depends on. The
Store module **imports** these and never re-derives the string format — if the naming
ever changes, it changes in one place (EP-23) and every consumer follows. The Service
that EP-23's renderer emits references exactly `nagare-env-<app>-runtime` and
`nagare-secret-<app>-runtime` in its `envFrom` list, which is why the store must use
the same helpers: writing the store under those names is what makes the app pick up the
values.

If EP-23 is not yet merged when you start, you cannot import these symbols and must
coordinate — see Interfaces and Dependencies for the exact fallback.

### Security caveat (restated for the implementer)

ConfigMap values are plaintext in the cluster datastore. Secret values are base64 (an
encoding, reversible by anyone) in a Secret object. Neither this module nor this plan
provides encryption. Cluster-level secret-at-rest protection and RBAC are out of scope
and live in the cluster configuration. The Store module's Haddock header states this so
a future reader does not over-trust the `Secret` path.


## Plan of Work

The work splits into two independently verifiable milestones. Milestone 1 is entirely
pure and fully unit-tested without a cluster. Milestone 2 adds the thin kubectl IO
shell and an optional live check. Before either, a short prerequisite step confirms the
EP-23 dependency and adds the base64 package.

### Prerequisite: dependency and package

Confirm EP-23 is merged by checking that the `nagare-dsl` library exports `EnvScope`,
`scopeToken`, `managedConfigMapName`, and `managedSecretName` (grep the source — see
Concrete Steps). Then add `base64` to the `build-depends` of both the `library` and
`test-suite nagarectl-test` stanzas of `cli/nagarectl/nagarectl.cabal`. If the flake's
package set does not provide `base64`, use `base64-bytestring` instead and adjust the
two private helpers in the Store module (recorded in the Decision Log).

### Milestone 1 — Pure reconcile, rendering, and extraction (unit-tested)

**Scope.** Create `cli/nagarectl/src/Nagare/Env/Store.hs` containing only pure
functions plus the `ReconcileMode` type, register it in the cabal `library` stanza's
`other-modules`, and add a tasty test group exercising it. At the end of this
milestone, `cd cli/nagarectl && cabal test` builds the module and runs the new tests
green, with no cluster involved.

**What will exist that did not before.** A pure, tested library API:

```haskell
data ReconcileMode = Merge | ReconcileExact

reconcile :: ReconcileMode -> Map Text Text -> Map Text Text -> Map Text Text

renderEnvConfigMap :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
renderEnvSecret    :: Text -> Text -> EnvScope -> Map Text Text -> ByteString

extractConfigMapData :: ByteString -> Either Text (Map Text Text)
extractSecretData    :: ByteString -> Either Text (Map Text Text)
```

The argument order for the renderers is `app`, `namespace`, `scope`, `values` (the
`Text` args are the app name and the Kubernetes namespace).

**Implementation notes.**

- `reconcile Merge existing incoming = Map.union incoming existing`. `Map.union` is
  left-biased, so `incoming` wins on collision and existing-only keys are kept. A
  single-key *set* is `reconcile Merge existing (Map.singleton k v)`. A single-key
  *delete* is `Map.delete k existing` expressed through reconcile as
  `reconcile ReconcileExact mempty (Map.delete k existing)` — or, more directly, the
  module exposes the deletion as a plain `Map.delete` and documents that delete is
  "reconcile of the remaining set". To keep the contract crisp, the module provides
  `reconcile` (the two-mode core) and the CLI computes the incoming set; delete is just
  passing the post-deletion map as `incoming` with `ReconcileExact`. Document this in
  the Haddock so EP-25 uses it consistently.
- `reconcile ReconcileExact _existing incoming = incoming`. The incoming set *is* the
  whole desired set; existing-only keys are dropped.
- `renderEnvConfigMap app ns scope kvs` builds the ConfigMap envelope with
  `name = managedConfigMapName app scope`, `namespace = ns`, and a `data` object whose
  entries are the map's keys to their plaintext values, **in sorted key order** (use
  `Map.toAscList`, which is already ascending, and build the Aeson object from that
  list so the byte output is stable and golden-friendly).
- `renderEnvSecret app ns scope kvs` is the same but `kind = "Secret"`,
  `type = "Opaque"`, `name = managedSecretName app scope`, and each value is
  base64-encoded (UTF-8 encode the `Text`, base64-encode the bytes, decode the base64
  bytes back to `Text` for the JSON string). Stable key order, same as above.
- `extractConfigMapData bs` decodes the outer JSON; a decode failure is `Left`; a
  missing `data` object yields `Right Map.empty`; otherwise every `data` entry whose
  value is a JSON string becomes a `Map` entry (non-string values are an error — they
  cannot occur in a real ConfigMap, but be strict rather than silent).
- `extractSecretData bs` is the same but base64-*decodes* each value; a base64 decode
  failure is `Left` (never silent loss).

**Acceptance.** Unit tests pass (see Validation and Acceptance): reconcile in both
modes, base64 round-trip through `renderEnvSecret`/`extractSecretData`, and a rendered
ConfigMap that decodes to a JSON object with the IP2 `name`.

### Milestone 2 — Thin kubectl IO layer (with optional live check)

**Scope.** Add the four IO functions to `Nagare.Env.Store`, mirroring
`readReleaseLog`/`writeReleaseLog`. These are not unit-tested (they shell out); they are
covered by a `cabal build` (they compile against `cradle` and `applyManifests`) and an
optional manual live-cluster check.

**What will exist that did not before.** The cluster-facing API:

```haskell
readEnvStore    :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
readSecretStore :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
writeEnvStore   :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
writeSecretStore:: Text -> Text -> EnvScope -> Map Text Text -> IO ()
```

Args are `app`, `namespace`, `scope`, and (for writes) `values`. `readEnvStore` runs
`kubectl get configmap <managedConfigMapName app scope> -n <ns> -o json` with
`silenceStderr`; `ExitFailure` ⇒ `Right Map.empty`; `ExitSuccess` ⇒
`extractConfigMapData out`. `readSecretStore` is the same with `secret` and
`extractSecretData`. `writeEnvStore` is
`applyManifests [renderEnvConfigMap app ns scope kvs]`; `writeSecretStore` likewise with
`renderEnvSecret`.

**Acceptance.** `cd cli/nagarectl && cabal build` is green. Optionally (Validation and
Acceptance, "live check"), against GCP project `tan-nb-exp`/region `us-west1`, apply a
rendered ConfigMap and confirm `kubectl get configmap nagare-env-<app>-runtime`
returns the expected keys. Per the repository policy in `CLAUDE.md`, all live `kubectl`
work targets only `tan-nb-exp`; the unit tests in M1 are pure and touch no cluster.


## Concrete Steps

Run everything from the repository root unless a step says otherwise. The repository
root is the directory containing `cli/`, `docs/`, and `CLAUDE.md`.

### Step 0 — Confirm the EP-23 dependency

```bash
grep -rn "managedConfigMapName\|managedSecretName\|scopeToken\|data EnvScope" cli/nagare-dsl/src
```

Expected (once EP-23 is merged): hits showing `data EnvScope = Runtime | Build |
Preview` in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` and the three name/token helpers
in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`. If you get no output, EP-23 is not merged
— stop and coordinate (see Interfaces and Dependencies).

### Step 1 — Add the base64 dependency

Edit `cli/nagarectl/nagarectl.cabal`. In the `library` stanza's `build-depends`, add
`base64,` (alphabetically near the top). In the `test-suite nagarectl-test` stanza's
`build-depends`, add `base64,` and `containers,` is already present. Also add the new
module to the library's module list — because `Nagare.Env.Store` is an internal helper
consumed by other library modules and the test suite, list it under `other-modules`
(create that field if absent) in the `library` stanza:

```cabal
  other-modules:
    Nagare.Env.Store
```

(If you prefer it exported for direct use by the `nagarectl`/`nagared` executables,
`exposed-modules` works too; `other-modules` is sufficient because the test-suite
depends on the `nagarectl` library and internal modules are visible to in-tree
consumers via the library. If the test-suite cannot see it as `other-modules`, move it
to `exposed-modules` — record which you chose in the Decision Log.)

### Step 2 — Create the module (Milestone 1 pure layer)

Create `cli/nagarectl/src/Nagare/Env/Store.hs`. Use this as the skeleton; fill in the
bodies per the Implementation notes above. The IO layer (Step 4) is appended to the
same file in Milestone 2.

```haskell
{-# LANGUAGE PackageImports #-}

-- | Per-app, per-scope environment and secret store (EP-24).
--
-- A small, tested library any command can use to read, merge or replace, and
-- write the key/value store backing an app's environment variables. Non-secret
-- values live in a Kubernetes ConfigMap (plaintext @data@); secret values live
-- in a Kubernetes Secret (base64-encoded @data@, type @Opaque@). The resource
-- names come from EP-23's IP2 helpers so they match what the rendered Knative
-- Service references via @envFrom@.
--
-- SECURITY CAVEAT: ConfigMap values are plaintext. Secret values are base64 —
-- an encoding, not encryption: anyone holding the bytes can decode them. The
-- base64 is only the Kubernetes Secret wire format. Real protection
-- (encryption-at-rest, RBAC) is cluster configuration and is OUT OF SCOPE here.
--
-- The pure layer (reconcile, render, extract) is separated from the thin
-- @kubectl@ IO layer, mirroring "Nagare.Static.Release", so the schema is
-- unit-testable without a cluster.
module Nagare.Env.Store
  ( ReconcileMode (..)
  , reconcile
  , renderEnvConfigMap
  , renderEnvSecret
  , extractConfigMapData
  , extractSecretData
  , readEnvStore
  , readSecretStore
  , writeEnvStore
  , writeSecretStore
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Cradle
import Data.Aeson
  ( eitherDecodeStrict
  , encode
  , object
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Deploy (applyManifests)
import Nagare.Dsl.Types (EnvScope (..))           -- EP-23 IP2
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName)  -- EP-23 IP2
import System.Exit (ExitCode (..))

-- base64: see Decision Log. If the flake pins base64-bytestring instead, swap
-- these two helpers' bodies; nothing else changes.
import Data.Base64.Types (extractBase64)
import Data.ByteString.Base64 (encodeBase64', decodeBase64Untyped)

-- | How an incoming key/value set is combined with the existing one.
data ReconcileMode
  = -- | Union; incoming wins on collision; existing-only keys are kept.
    Merge
  | -- | The incoming set becomes the whole store; existing-only keys are dropped.
    ReconcileExact
  deriving stock (Eq, Show)

-- | Compute the desired store from the existing store and the incoming entries.
-- A single-key set is @reconcile Merge existing (Map.singleton k v)@. A delete is
-- expressed by passing the post-deletion map as the incoming set with
-- 'ReconcileExact'.
reconcile :: ReconcileMode -> Map Text Text -> Map Text Text -> Map Text Text
reconcile Merge existing incoming = Map.union incoming existing  -- left-biased: incoming wins
reconcile ReconcileExact _existing incoming = incoming

-- | Render the ConfigMap (JSON bytes that @kubectl apply -f@ accepts) holding
-- @kvs@ as plaintext for @app@ in @ns@ at @scope@, named per IP2.
renderEnvConfigMap :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
renderEnvConfigMap app ns scope kvs =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("ConfigMap" :: Text)
      , "metadata"
          .= object
            [ "name" .= managedConfigMapName app scope
            , "namespace" .= ns
            ]
      , "data" .= dataObject id kvs
      ]

-- | Render the Secret (JSON bytes) holding @kvs@ base64-encoded for @app@ in @ns@
-- at @scope@, type @Opaque@, named per IP2.
renderEnvSecret :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
renderEnvSecret app ns scope kvs =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Secret" :: Text)
      , "type" .= ("Opaque" :: Text)
      , "metadata"
          .= object
            [ "name" .= managedSecretName app scope
            , "namespace" .= ns
            ]
      , "data" .= dataObject b64encode kvs
      ]

-- | Build a stable, sorted @data@ JSON object, mapping each value through @f@.
dataObject :: (Text -> Text) -> Map Text Text -> Aeson.Value
dataObject f kvs =
  object [Key.fromText k .= f v | (k, v) <- Map.toAscList kvs]

-- | Parse @kubectl get configmap ... -o json@ into a plaintext map. Missing
-- @data@ yields an empty map; a JSON decode failure is 'Left'.
extractConfigMapData :: ByteString -> Either Text (Map Text Text)
extractConfigMapData = extractData pure

-- | Parse @kubectl get secret ... -o json@ into a map, base64-DECODING values.
-- Missing @data@ yields empty; a JSON or base64 decode failure is 'Left'.
extractSecretData :: ByteString -> Either Text (Map Text Text)
extractSecretData = extractData b64decode

-- | Shared extractor: decode the outer object, read the @data@ map of string
-- values, and run each value through @f@ (identity for ConfigMap, base64-decode
-- for Secret). Strict: non-string values or a failing @f@ are 'Left'.
extractData :: (Text -> Either Text Text) -> ByteString -> Either Text (Map Text Text)
extractData f bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode resource JSON: " <> T.pack e)
    Right v -> case dataMap v of
      Nothing -> Right Map.empty
      Just kvs -> traverse f kvs
  where
    dataMap :: Aeson.Value -> Maybe (Map Text Text)
    dataMap val = do
      Aeson.Object o <- Just val
      case KeyMap.lookup (Key.fromText "data") o of
        Just (Aeson.Object d) ->
          Just (Map.fromList [ (Key.toText k, s) | (k, Aeson.String s) <- KeyMap.toList d ])
        _ -> Nothing

-- base64 helpers (isolate the package choice; see Decision Log).
b64encode :: Text -> Text
b64encode = extractBase64 . encodeBase64' . TE.encodeUtf8

b64decode :: Text -> Either Text Text
b64decode t =
  case decodeBase64Untyped (TE.encodeUtf8 t) of
    Left e -> Left ("could not base64-decode secret value: " <> e)
    Right bs -> Right (TE.decodeUtf8 bs)
```

Note: `encodeBase64'` returns a `Base64 ... ByteString`; `extractBase64` unwraps it,
and we want a `Text` — adjust the helper to `TE.decodeUtf8 . extractBase64 .
encodeBase64'` if `encodeBase64'` yields bytes. The exact unwrapping depends on the
installed `base64` version; resolve at the GHC error and record it. If using
`base64-bytestring` instead: `b64encode = TE.decodeUtf8 . Data.ByteString.Base64.encode
. TE.encodeUtf8`, and `b64decode t = either (Left . T.pack) (Right . TE.decodeUtf8)
(Data.ByteString.Base64.decode (TE.encodeUtf8 t))`.

### Step 3 — Add tests (Milestone 1)

Edit `cli/nagarectl/test/Spec.hs`. Add `import Nagare.Env.Store`, add a
`testGroup "Nagare.Env.Store" envStoreTests` to the top-level `testGroup "nagarectl"`
list, and add the `envStoreTests` definition. The map type forces the `containers`
package (already a test dependency) and `Data.Map qualified as Map` (already imported).

```haskell
import Nagare.Env.Store
import Nagare.Dsl.Types (EnvScope (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap

envStoreTests :: [TestTree]
envStoreTests =
  [ testCase "reconcile Merge unions, incoming wins, keeps existing-only keys" $
      reconcile Merge (Map.fromList [("A", "1"), ("B", "2")]) (Map.fromList [("B", "9"), ("C", "3")])
        @?= Map.fromList [("A", "1"), ("B", "9"), ("C", "3")]
  , testCase "reconcile ReconcileExact replaces the whole set" $
      reconcile ReconcileExact (Map.fromList [("A", "1"), ("B", "2")]) (Map.fromList [("B", "9"), ("C", "3")])
        @?= Map.fromList [("B", "9"), ("C", "3")]
  , testCase "renderEnvSecret/extractSecretData round-trip base64 values" $ do
      let kvs = Map.fromList [("DATABASE_URL", "postgres://u:p@h/db"), ("API_KEY", "s3cr3t==")]
      case extractSecretData (renderEnvSecret "notes" "personal" Runtime kvs) of
        Right back -> back @?= kvs
        Left e -> assertFailure ("extract failed: " <> T.unpack e)
  , testCase "renderEnvConfigMap round-trips plaintext values" $ do
      let kvs = Map.fromList [("LOG_LEVEL", "info"), ("REGION", "us-west1")]
      case extractConfigMapData (renderEnvConfigMap "notes" "personal" Runtime kvs) of
        Right back -> back @?= kvs
        Left e -> assertFailure ("extract failed: " <> T.unpack e)
  , testCase "renderEnvConfigMap is apply-able JSON named per IP2" $ do
      let bs = renderEnvConfigMap "notes" "personal" Runtime (Map.singleton "K" "v")
      case Aeson.eitherDecodeStrict bs of
        Right (Aeson.Object o) -> do
          KeyMap.lookup (Key.fromText "kind") o @?= Just (Aeson.String "ConfigMap")
          metaName o @?= Just (Aeson.String "nagare-env-notes-runtime")
        other -> assertFailure ("not a JSON object: " <> show other)
  , testCase "extractSecretData rejects malformed base64 (no silent loss)" $ do
      let bad = "{\"kind\":\"Secret\",\"data\":{\"K\":\"!!!notb64!!!\"}}"
      case extractSecretData bad of
        Left _ -> pure ()
        Right _ -> assertFailure "expected Left for malformed base64"
  ]
  where
    metaName o = do
      Aeson.Object m <- KeyMap.lookup (Key.fromText "metadata") o
      KeyMap.lookup (Key.fromText "name") m
```

### Step 4 — Add the IO layer (Milestone 2)

Append to `cli/nagarectl/src/Nagare/Env/Store.hs` (and add the four names to the export
list):

```haskell
-- | Read the ConfigMap-backed env store for @app@/@scope@ in @ns@. A missing
-- ConfigMap (non-zero exit) is an empty map; a present-but-malformed one is 'Left'.
readEnvStore :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
readEnvStore app ns scope = readStore "configmap" (managedConfigMapName app scope) ns extractConfigMapData

-- | Read the Secret-backed store, base64-decoding values. Missing ⇒ empty map.
readSecretStore :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
readSecretStore app ns scope = readStore "secret" (managedSecretName app scope) ns extractSecretData

readStore :: String -> Text -> Text -> (ByteString -> Either Text (Map Text Text)) -> IO (Either Text (Map Text Text))
readStore kind name ns extract = do
  (exitCode, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", kind, T.unpack name, "-n", T.unpack ns, "-o", "json"]
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> Right Map.empty
    ExitSuccess -> extract out

-- | Persist the ConfigMap-backed store by applying the rendered manifest.
writeEnvStore :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
writeEnvStore app ns scope kvs = applyManifests [renderEnvConfigMap app ns scope kvs]

-- | Persist the Secret-backed store by applying the rendered manifest.
writeSecretStore :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
writeSecretStore app ns scope kvs = applyManifests [renderEnvSecret app ns scope kvs]
```

### Step 5 — Build and test

```bash
cd cli/nagarectl && cabal test
```

Expected transcript (abridged — the existing groups still run):

```text
nagarectl
  Nagare.Static.Image
    staticDockerfile uses the nginx base and 8080 layout: OK
  ...
  Nagare.Env.Store
    reconcile Merge unions, incoming wins, keeps existing-only keys: OK
    reconcile ReconcileExact replaces the whole set:                 OK
    renderEnvSecret/extractSecretData round-trip base64 values:      OK
    renderEnvConfigMap round-trips plaintext values:                 OK
    renderEnvConfigMap is apply-able JSON named per IP2:             OK
    extractSecretData rejects malformed base64 (no silent loss):     OK

All N tests passed (0.0Ns)
```

A non-zero exit or a `FAIL` line means a step is wrong; read the assertion message,
which prints the expected vs actual map or JSON.


## Validation and Acceptance

Acceptance is phrased as behavior with concrete inputs and outputs.

**Reconcile (both modes).** Given existing `{A:1, B:2}` and incoming `{B:9, C:3}`:

- `reconcile Merge` yields `{A:1, B:9, C:3}` — `A` survives, `B` is overwritten by the
  incoming `9`, `C` is added.
- `reconcile ReconcileExact` yields `{B:9, C:3}` — `A` is dropped because the incoming
  set is the whole store.

These are the first two unit tests; they fail before the module exists and pass after.

**base64 round-trip.** A rendered Secret's `data` values must base64-decode to the
originals. The test renders `renderEnvSecret "notes" "personal" Runtime
{DATABASE_URL: "postgres://u:p@h/db", API_KEY: "s3cr3t=="}`, then
`extractSecretData` the bytes and asserts the result equals the input map. You can also
prove the values are *encoded* by eye:

```bash
cd cli/nagarectl
cabal repl nagarectl <<'EOF'
:set -XOverloadedStrings
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as BC
import Nagare.Env.Store
import Nagare.Dsl.Types (EnvScope(..))
BC.putStrLn (renderEnvSecret "notes" "personal" Runtime (Map.singleton "API_KEY" "hello"))
EOF
```

Expected: the printed JSON contains `"data":{"API_KEY":"aGVsbG8="}` — `aGVsbG8=` is
base64 of `hello`. Decode it to confirm: `printf 'aGVsbG8=' | base64 -d` prints
`hello`.

**Apply-able ConfigMap named per IP2.** The rendered ConfigMap decodes to a JSON object
whose `kind` is `ConfigMap` and whose `metadata.name` is `nagare-env-notes-runtime`
(the IP2 helper output for app `notes`, scope `Runtime`). That is the fifth unit test.

**Malformed input is never silent loss.** `extractSecretData` of a Secret whose `data`
value is not valid base64 returns `Left` (last unit test), and `extractConfigMapData`/
`extractSecretData` of un-parseable JSON return `Left`. A *missing* resource at the IO
layer returns `Right empty` — these are different cases by design.

**Live check (Milestone 2, optional, GCP `tan-nb-exp` / `us-west1`).** With a kube
context pointed at the Nagare cluster (per `CLAUDE.md`, only `tan-nb-exp`), apply a
rendered ConfigMap and read it back:

```bash
cd cli/nagarectl
cabal repl nagarectl <<'EOF'
:set -XOverloadedStrings
import qualified Data.Map as Map
import Nagare.Env.Store
import Nagare.Dsl.Types (EnvScope(..))
writeEnvStore "notes" "personal" Runtime (Map.fromList [("LOG_LEVEL","info")])
r <- readEnvStore "notes" "personal" Runtime
print r
EOF
kubectl get configmap nagare-env-notes-runtime -n personal -o jsonpath='{.data}'
```

Expected: the repl prints `Right (fromList [("LOG_LEVEL","info")])`, and `kubectl`
prints `{"LOG_LEVEL":"info"}`. Clean up with
`kubectl delete configmap nagare-env-notes-runtime -n personal`.


## Idempotence and Recovery

Every step is safe to repeat. Editing the cabal file and the module is idempotent
(re-running `cabal test` just rebuilds). `kubectl apply -f` is declarative: applying the
same rendered manifest twice converges to the same resource, so `writeEnvStore`/
`writeSecretStore` are idempotent. A `reconcile`-then-`write` cycle is the intended
update path and is safe to run repeatedly.

The one data-safety concern is the read-modify-write cycle that EP-25 will build on top
of this module: if a read returns `Left` (malformed existing resource), the caller must
**not** write, exactly as `recordReleaseFor` in `Nagare.Static.Release` refuses to
overwrite an unreadable history. This module makes that easy by returning `Left` on
malformed input; EP-25 must honor it. If a live `writeSecretStore` is interrupted,
re-run it — `kubectl apply` is convergent. To roll back a bad store write, re-apply the
previous map (or `kubectl delete` the resource to return the app to the
"never configured" state, which deploys fine because EP-23's `envFrom` uses
`optional: true`).


## Interfaces and Dependencies

**New module.** `cli/nagarectl/src/Nagare/Env/Store.hs`, registered in
`cli/nagarectl/nagarectl.cabal` (`other-modules` of the `library` stanza). The full
public contract — the signatures that EP-25 (CLI) and EP-27 (build/preview env) consume
and that this plan must deliver unchanged — is:

```haskell
data ReconcileMode = Merge | ReconcileExact

-- Pure core (IP4). Merge: union, incoming wins, keep existing-only keys.
-- ReconcileExact: incoming becomes the whole set.
reconcile :: ReconcileMode -> Map Text Text -> Map Text Text -> Map Text Text

-- Pure rendering. Args: app, namespace, scope, values. JSON bytes for kubectl apply -f.
renderEnvConfigMap :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
renderEnvSecret    :: Text -> Text -> EnvScope -> Map Text Text -> ByteString

-- Pure extraction from `kubectl get ... -o json`. Missing data => empty map;
-- malformed JSON/base64 => Left. extractSecretData base64-decodes values.
extractConfigMapData :: ByteString -> Either Text (Map Text Text)
extractSecretData    :: ByteString -> Either Text (Map Text Text)

-- Thin kubectl IO. Missing resource => Right empty. Args: app, namespace, scope[, values].
readEnvStore    :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
readSecretStore :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
writeEnvStore   :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
writeSecretStore:: Text -> Text -> EnvScope -> Map Text Text -> IO ()
```

**Libraries used.** `aeson` (JSON build/parse, already a dependency), `cradle` (process
shell-out, already used by `Nagare.Static.Release`), `containers` (`Data.Map`),
`text`, `bytestring`, and a base64 codec. `Nagare.Deploy.applyManifests` is reused for
the write path. `System.Exit` for `ExitCode`.

**base64 dependency.** Neither `base64` nor `base64-bytestring` is currently in
`nagarectl.cabal` (verified by `grep -rn base64 cli/`, which returns nothing). Add
`base64` to the `library` and `test-suite` `build-depends`. If the nix flake's package
set does not provide it, use `base64-bytestring` and adjust the two private helpers
`b64encode`/`b64decode` (the module isolates the choice there). Record the resolution in
the Decision Log.

**EP-23 imports (hard dependency).** This plan imports, from the `nagare-dsl` library,
the scope type and naming helpers defined and exported by
`docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md` (Integration Point
IP2): `EnvScope (Runtime | Build | Preview)` and `scopeToken` from
`Nagare.Dsl.Types`, and `managedConfigMapName` / `managedSecretName` from
`Nagare.Dsl.Render`. These produce the resource names `nagare-env-<app>-<scope>` and
`nagare-secret-<app>-<scope>`. **Do not re-derive these strings**; import the helpers
so the store's names always match what EP-23's rendered Service references in its
`envFrom` list. If EP-23 is not yet merged, the implementer must coordinate: either
wait for it to land, or, to unblock pure unit-test work only, stub the three helpers
locally with a clearly-marked `-- TEMP: replace with EP-23 import` block and a failing
test that asserts the import path exists, then delete the stub the moment EP-23 merges.
The masterplan `docs/masterplans/5-environment-and-secret-management-for-nagare.md`
records EP-24 as hard-depending on EP-23.

**Consumers (downstream).** EP-25
(`docs/plans/25-nagarectl-env-and-secret-cli-commands.md`) calls `reconcile` for its
`env set`/`env sync`/`env delete` and `secret` commands and uses the read/write IO.
EP-27 (`docs/plans/27-build-time-and-preview-scoped-env-application.md`) reads the
build- and preview-scoped stores through `readEnvStore`/`readSecretStore`. Keep the
signatures above stable so those plans compile against them unchanged.
