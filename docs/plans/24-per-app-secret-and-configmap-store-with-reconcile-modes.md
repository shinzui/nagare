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

Full plan before trimming: [24-per-app-secret-and-configmap-store-with-reconcile-modes.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/24-per-app-secret-and-configmap-store-with-reconcile-modes.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

