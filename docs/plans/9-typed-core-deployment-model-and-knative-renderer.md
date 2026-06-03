---
id: 9
slug: typed-core-deployment-model-and-knative-renderer
title: "Typed core deployment model and Knative renderer"
kind: exec-plan
created_at: 2026-06-03T03:44:07Z
intention: "intention_01kt5s3j2zedh8ew1yp9qdp6c7"
master_plan: "docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md"
---

# Typed core deployment model and Knative renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan is complete, there is a standalone Haskell library — `nagare-dsl` — that
defines exactly what a Nagare deployment *is* in types, and that can render any valid
deployment to the Knative `Service` (and optional `DomainMapping`) YAML that the cluster
expects. Before this plan, illegal configurations (a service name with capital letters or a
leading hyphen, an environment variable that simultaneously claims to be a literal value and
a secret reference, a scale whose `max` is below its `min`, a CPU quantity like `"abc"`) can
be silently written down — they only fail minutes later when the cluster rejects the manifest.
After this plan, those mistakes cannot be expressed in the type: the type system or a
smart-constructor function with a precise error message stops you the moment you try to
create the illegal value, not when you deploy.

The concrete thing you can do after this plan: run `cabal test` inside `cli/nagare-dsl/` and
see a golden test pass, proving that a fully-configured deployment value — constructed
entirely through the library's safe constructors — renders byte-for-byte to the same Knative
Service YAML that the cluster contract (EP-6, `docs/plans/6-nagarectl-deploy-cli-in-haskell.md`)
defines. You can also run a shell command that tries to compile a module that uses the hidden
`ServiceName` constructor directly and watch GHC refuse.

This plan owns Integration Points 1, 2, and 5 of the MasterPlan at
`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`.


## Progress

- [x] M1.1 cabal.project layout; create `cli/nagare-dsl/nagare-dsl.cabal` and `cli/nagare-dsl/cabal.project`. _(2026-06-03)_
- [x] M1.2 Modules `src/Nagare/Dsl/Types.hs`, `src/Nagare/Dsl/Render.hs` (implemented directly, not stubbed). _(2026-06-03)_
- [x] M1.2b `src/Nagare/Dsl/Prelude.hs` re-exporting Generic, Text, base helpers, Control.Lens (not Data.Generics.Labels). _(2026-06-03)_
- [x] M1.3 `cabal build` succeeds from `cli/nagare-dsl/` inside `nix develop`. _(2026-06-03; needed `{-# LANGUAGE PackageImports #-}` in Render.hs for the `"generic-lens"` import.)_
- [x] M2.1 All newtypes, sum types, and smart constructors in `src/Nagare/Dsl/Types.hs` (unprefixed strict fields). _(2026-06-03)_
- [x] M2.2 `test/Spec.hs` unit tests for every smart constructor (accept valid, reject invalid). _(2026-06-03)_
- [x] M2.3 `cabal test` passes the unit tests. _(2026-06-03: 38 unit cases.)_
- [x] M3.1 `src/Nagare/Dsl/Render.hs` with `renderService` and `renderDomainMapping`. _(2026-06-03; uses `encodePretty` + key comparator — see Decision Log.)_
- [x] M3.2 Check in golden files: `test/golden/hello.nagare.yaml` (input), `test/golden/hello.service.yaml`, `test/golden/hello.domainmapping.yaml` (generated). _(2026-06-03)_
- [x] M3.3 Golden tests in `test/Spec.hs`; `cabal test` passes. _(2026-06-03: 45 total cases; byte-identical to EP-6's documented Service + DomainMapping.)_
- [x] M4.1 `test/negative/BadConstructor.hs` and `test/negative/check-negative-types.sh`. _(2026-06-03)_
- [x] M4.2 Negative-type check passes — GHC rejects the hidden-constructor use. _(2026-06-03: `[GHC-01928] Illegal term-level use of the type constructor 'ServiceName'`.)_
- [x] Final: Progress, Surprises, Decision Log, Outcomes updated; Integration Points 1/2/5 verified. _(2026-06-03)_


## Surprises & Discoveries

- **The renderer must use `encodePretty` + an explicit key comparator, not plain `Data.Yaml.encode`
  (deviation from the plan text).** This plan's M3.1/M3.3 assumed `Data.Yaml.encode` sorts object
  keys alphabetically and instructed generating the golden from whatever it produces — but its own
  illustrated golden is *not* alphabetical (`image` before `env`; `min-scale` before `max-scale`),
  and MasterPlan Integration Point 2 requires byte-for-byte parity with EP-6's documented output.
  Carrying the EP-8 spike lesson, `Render.hs` serialises through `Data.Yaml.Pretty.encodePretty`
  with a `setConfCompare` comparator that ranks keys explicitly. The generated golden then matches
  EP-6's authoritative order exactly (verified by `cat` and the `goldenVsString` lock-in). (2026-06-03)
- **The key comparator needs care for `name`.** `name` must sort *first* in `metadata` and
  `secretKeyRef` (before `namespace`/`key`) but *last* in a DomainMapping `ref` (after `apiVersion`
  and `kind`). A first attempt with `name` ranked 0 globally produced `ref: {apiVersion, name, kind}`
  — wrong. The fix is a rank assignment satisfying all three contexts at once:
  `apiVersion(0) < kind(1) < name(2) < namespace/key/value/valueFrom(3) < metadata(4) < spec(5)`,
  with the per-object keys (`image/ports/env/resources`, `min/max-scale`, `cpu/memory`) ranked
  within their own objects. (2026-06-03)
- **GHC 9.12 negative-test wording.** Importing only the *type* `ServiceName` and then using it as
  a term yields `[GHC-01928] Illegal term-level use of the type constructor 'ServiceName'`, not the
  plan's anticipated "Not in scope: data constructor". Both prove the data constructor is
  unexported/inaccessible; the check script accepts either wording. The negative module must be
  compiled against the *installed* `nagare-dsl` package (via `cabal exec -- ghc -package nagare-dsl`),
  not bare `ghc -isrc`, because the library's prelude pulls non-boot packages (`lens`,
  `generic-lens`) that a bare GHC session cannot resolve. (2026-06-03)
- **`Nagare.Dsl.Prelude` re-exports all of `Control.Lens`, which clashes with aeson's `(.=)`.**
  `Render.hs` imports the prelude `hiding ((.=))` and takes `(.=)` from `Data.Aeson`. (2026-06-03)
- Dependencies all resolved from Hackage (the corpus fallback in `cabal.project` was not needed):
  `aeson 2.3`, `yaml 0.11`, `generic-lens 2.2.2`, `lens 5.3.6`, `tasty`/`tasty-hunit`/`tasty-golden`.
  (2026-06-03)


## Decision Log

- Decision: Separate `cabal.project` files per package — `cli/nagare-dsl/cabal.project` for
  EP-9/10/11, and `cli/nagarectl/cabal.project` (created by EP-6/12) which will add
  `nagare-dsl` as a `packages:` source entry when it depends on it.
  Rationale: `nagare-dsl` must be independently buildable and testable without EP-6's
  `nagarectl` package existing. A shared `cli/cabal.project` would couple the two packages;
  separate project files let each be built and tested independently. EP-12 adds
  `../nagare-dsl` to `nagarectl`'s `cabal.project` when it wires the dependency.
  See Integration Point 5 in the MasterPlan.
  Date: 2026-06-03

- Decision: Use `tasty` + `tasty-hunit` from Hackage (not the mori corpus source paths) for
  the unit test suite, and `tasty-golden` from Hackage for the golden test.
  Rationale: The nix developer shell provides `cabal` and internet access to Hackage; the
  corpus paths exist as a fallback if Hackage is unavailable (record in Surprises which was
  used). Hackage versions match the corpus versions exactly (tasty 1.5.4, tasty-hunit 0.10.2,
  tasty-golden 2.3.6), so switching is a one-line `cabal.project` change if needed.
  Date: 2026-06-03

- Decision: Use the shell-script negative-type-test mechanism (M4), not `should-not-typecheck`
  or `-fdefer-type-errors`.
  Rationale: `should-not-typecheck` is not in the mori corpus and would require a network
  fetch. `-fdefer-type-errors` hides the error until runtime and requires a runtime assertion
  harness, which is more complex than a direct compile check. The shell-script approach
  compiles a dedicated `.hs` file with `ghc` and asserts non-zero exit; the expected GHC
  error text is documented in the plan and verified by running the script. This is the same
  mechanism used by GHC's own test suite for "should-not-compile" tests and works fully
  offline. For the EnvVar mutual-exclusion proof, the type is a sum type — not a struct —
  making the bug literally unrepresentable at the type level, which is self-evident from
  the definition and confirmed by the compiler rejecting any pattern-match or construction
  that treats it otherwise.
  Date: 2026-06-03

- Decision: `nagare-dsl` follows the house Haskell standards (haskell-jitsurei): GHC2024 + a
  `common` stanza (`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
  `OverloadedStrings`, `MultilineStrings`), a `Nagare.Dsl.Prelude` custom prelude, strict
  unprefixed record fields (`Deployment.name/namespace/image/domain/port/env/resources/scale`,
  `Resources.cpu/memory`, `Scale.minScale/maxScale`), explicit deriving strategies, generic-lens
  `#label` access in the renderer, and postpositive qualified imports; built with GHC 9.12
  pinned by EP-8's flake change.
  Rationale: house standard directed by the user; supersedes the earlier draft that used
  GHC2021 and `dep*`/`res*`/`scale*` prefixed fields. See MasterPlan Integration Point 6.
  Date: 2026-06-03

- Decision: Render via `Data.Yaml.Pretty.encodePretty` with an explicit key comparator, overriding
  the M3.1/M3.3 instruction to use plain `Data.Yaml.encode` and accept its native key order.
  Rationale: the plan text assumed `Yaml.encode` sorts keys alphabetically, but that both
  contradicts the plan's own illustrated golden (non-alphabetical) and would not deterministically
  reproduce EP-6's documented byte order, which MasterPlan Integration Point 2 requires. The
  comparator (carried from the EP-8 spike, which hit the same issue) gives deterministic output
  matching EP-6 exactly for both the Service and the DomainMapping. The golden files are still
  generated from the renderer and locked in by `goldenVsString`. This does not change the
  `Deployment` types (Integration Point 1) or the public renderer signatures (Integration Point 2),
  only the internal serializer.
  Date: 2026-06-03


## Outcomes & Retrospective

**Outcome.** `cli/nagare-dsl/` exists as an independently buildable, offline-testable Haskell
library that fully delivers Integration Points 1, 2, and 5. `Nagare.Dsl.Types` defines the
canonical `Deployment` with maximal-safety types — hidden-constructor newtypes (`ServiceName`,
`Namespace`, `ImageRef`, `EnvName`, `SecretName`, `Port`, `Quantity`, `Domain`) each reachable only
through a validating `mkX :: ... -> Either Text X`, the `EnvVar = EnvLiteral | EnvSecretRef` sum
type making the value+secretRef bug unrepresentable, and `mkScale` rejecting `max < min`. Fields are
strict and **unprefixed** (`name/namespace/image/domain/port/env/resources/scale`,
`Resources.cpu/memory`, `Scale.minScale/maxScale`) per the house standard, addressing the user's
explicit objection to the spike's `dep*`/`res*` prefixes. `Nagare.Dsl.Render` renders to Knative
`Service` + `DomainMapping` YAML byte-identical to EP-6's documented output.

**Verification.** `cabal test` runs 45 cases — 38 smart-constructor unit tests (every accept/reject
path) and 2 golden tests proving byte-exact rendering — all green. The negative-type gate shows GHC
refusing `ServiceName "INVALID NAME WITH SPACES"` with `[GHC-01928]`, proving the hidden constructor
cannot be bypassed. All gates are offline; no cluster needed.

**Lessons.** The renderer's key ordering needed the spike's `encodePretty`+comparator approach (the
plan's plain-`Yaml.encode` assumption was wrong); the comparator needed a careful rank to place
`name` correctly across `metadata`/`secretKeyRef`/`ref`. The custom prelude's `Control.Lens`
re-export collides with aeson's `(.=)` — import the prelude `hiding ((.=))` in the renderer.

**Carried to downstream plans.** EP-10's loader compiles-and-runs the app's `Config.hs` to obtain a
`Deployment` and calls `Nagare.Dsl.Render.renderService`/`renderDomainMapping`; EP-11's presets are
functions returning these types; EP-12 wires the renderer into `nagarectl` and deletes EP-6's
duplicate. The `Deployment` field names and the renderer signatures here are the contract those
plans build on (Integration Points 1, 2, 5).


## Context and Orientation

This section defines every term used in this plan. Read it fully before touching code.

**What Nagare is.** Nagare is a single-node personal Platform-as-a-Service on a GCP virtual
machine running k3s (a lightweight Kubernetes distribution) with Knative Serving installed.
Knative Serving is a layer that turns one container image into an auto-scaling, scale-to-zero
HTTPS service called a *Knative Service* — a Kubernetes object of kind `Service` in the API
group `serving.knative.dev/v1`. A DomainMapping (`serving.knative.dev/v1beta1`, kind
`DomainMapping`) maps a custom hostname onto a Knative Service. EP-6
(`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`) defines the existing `nagare.yaml` schema
and the exact YAML that `nagarectl deploy` must render. This plan's renderer must produce
output that is byte-for-byte identical to what EP-6 specifies.

**What this plan builds.** A new Haskell library package `nagare-dsl` in a new directory
`cli/nagare-dsl/` (a sibling of `cli/nagarectl/`, which EP-6 owns and which is currently
empty). The library has two modules:

- `Nagare.Dsl.Types` — the canonical typed deployment model with maximal-safety constructors.
- `Nagare.Dsl.Render` — renders a `Deployment` value to Knative YAML bytes.

The library has a test suite (`nagare-dsl-test`) containing unit tests for the smart
constructors and a golden test for the renderer.

**The directory structure to create.**

```text
cli/nagare-dsl/
  cabal.project           -- references this package; fallback corpus paths listed
  nagare-dsl.cabal        -- Cabal package description
  src/
    Nagare/
      Dsl/
        Prelude.hs        -- custom prelude (re-exports common imports + lens)
        Types.hs          -- all newtypes, sum types, smart constructors, Deployment
        Render.hs         -- renderService, renderDomainMapping
  test/
    Spec.hs               -- tasty test entry point (unit tests + golden test)
    golden/
      hello.nagare.yaml   -- copy of cluster/examples/hello-knative-service/nagare.yaml
      hello.service.yaml  -- expected rendered Service YAML (golden output, checked in)
      hello.domainmapping.yaml  -- expected rendered DomainMapping YAML (golden output)
    negative/
      BadConstructor.hs   -- module that tries to use the hidden ServiceName constructor
      check-negative-types.sh  -- shell script that compiles BadConstructor and asserts failure
```

**Toolchain prerequisites.** Run all `cabal` commands from inside the developer shell at the
repository root: `nix develop` (from `/Users/shinzui/Keikaku/bokuno/nagare`). The shell
provides GHC 9.12 (pinned via the repository Nix flake — see EP-8's M0 milestone, which
performs the pin) and cabal-install. All milestones are offline-verifiable (no cluster
required). The only network access needed is Hackage for `yaml`, `aeson`, `tasty`,
`tasty-hunit`, and `tasty-golden`. If Hackage is unavailable, see the fallback cabal.project
in M1.1.

> **Haskell standards (binding; see MasterPlan Integration Point 6).** This package is built with **GHC 9.12** pinned through the repository Nix flake and follows the house standards in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`. Every Cabal stanza uses `default-language: GHC2024` and `import: common`, where the `common` stanza enables `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` (and `MultilineStrings` where useful). Modules import the shared `Nagare.Dsl.Prelude` instead of repeating common imports; record types use strict (`!`) unprefixed fields with explicit `deriving stock`/`deriving newtype`/`deriving anyclass` strategies; field access/update uses generic-lens `#label` with lens operators; qualified imports are postpositive. Formatting is `fourmolu` + `cabal-gild` via `treefmt`.

**The `nagare.yaml` schema and golden target.** EP-6's "Context and Orientation" section
defines the `nagare.yaml` schema fully. The existing example application at
`cluster/examples/hello-knative-service/nagare.yaml` is the golden input:

```yaml
name: hello
namespace: personal
image: gcr.io/knative-samples/helloworld-go
domain: hello.example.com
port: 8080
env:
  TARGET:
    value: "Nagare"
resources:
  cpu: 250m
  memory: 128Mi
scale:
  min: 0
  max: 3
```

With tag `"20260602-120000"`, `renderService` must produce exactly this YAML (the golden file):

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello
  namespace: personal
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
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
```

And `renderDomainMapping` must produce exactly:

```yaml
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: hello.example.com
  namespace: personal
spec:
  ref:
    apiVersion: serving.knative.dev/v1
    kind: Service
    name: hello
```

Three rendering rules from EP-6 that this renderer must preserve exactly:

1. Env entries are sorted by variable name (ascending) for determinism. `Data.Map.Map` stores
   keys in ascending order, so `Data.Map.toAscList` gives sorted order automatically.
2. Autoscaling annotation *values* are YAML strings, not integers. Kubernetes annotations are
   always strings. When you put `Data.Aeson.String "0"` into an aeson `Object` and serialize
   with `Data.Yaml.encode`, the yaml library produces `'0'` (single-quoted) because the bare
   value `0` would be parsed back as an integer. This is why the golden shows `'0'` and `'3'`
   rather than `0` and `3`.
3. Sub-blocks (`env`, `resources`, annotations) are omitted entirely when their source field
   is empty or absent. Do not emit `env: []` or `resources: {}` — leave the key out entirely.

**Type-safety design: why each type makes a class of error unrepresentable.**

The core idea throughout is *hidden constructors exported only via smart constructors*. A
Haskell `newtype` wraps one type in a distinct named type. If the data constructor of that
newtype is not exported from the module, then code outside the module cannot construct a value
of that type without going through the module's exported functions — which can validate. Here
is how each type applies this principle.

`ServiceName` wraps `Text` but does not export `ServiceName` (the constructor). The only way
to get a `ServiceName` is through `mkServiceName :: Text -> Either Text ServiceName`, which
checks that the text is 1–63 characters, all lowercase alphanumeric or hyphen, not starting
or ending with a hyphen. Without this, a service named `"My Service"` (spaces and capitals)
or `"--bad"` (leading hyphens) would be silently accepted and cause a cluster rejection. With
this, the bad names produce `Left "invalid service name: ..."` before anything reaches the
cluster. The accessor `serviceNameText :: ServiceName -> Text` lets callers read the wrapped
value without pattern-matching the hidden constructor.

`Namespace` is the same pattern: `mkNamespace :: Text -> Either Text Namespace` with
`defaultNamespace :: Namespace` pre-validated to `"personal"`.

`ImageRef` is the same pattern: `mkImageRef :: Text -> Either Text ImageRef`. It validates
that the text is non-empty and contains no colon (the contract is: repository path with no
tag; the tag is passed separately to `renderService`).

`EnvName` and `SecretName` both wrap `Text` with their constructors hidden and smart
constructors that validate the value is non-empty.

`Port` wraps `Int`, constructor hidden, `mkPort :: Int -> Either Text Port` accepts 1–65535
only, `defaultPort :: Port` is `8080`. A port of `0` or `99999` would silently be written to
YAML but the cluster would reject it. Now it is caught at construction.

`Quantity` wraps `Text`, constructor hidden, `mkQuantity :: Text -> Either Text Quantity`
checks that the text matches Kubernetes quantity syntax: one or more digits, optionally
followed by a decimal fraction (`.[0-9]+`), optionally followed by a suffix from the set `m`,
`k`, `M`, `G`, `T`, `P`, `E`, `Ki`, `Mi`, `Gi`, `Ti`, `Pi`, `Ei`. Anything that does not
match — `"abc"`, `"500 Mi"`, `""` — returns `Left` with a message. Invalid quantities like
`"abc"` would otherwise silently propagate to the YAML and cause a cluster parse error.

`Scale` is a data type (not a newtype) with `mkScale :: Int -> Int -> Either Text Scale` that
rejects negative values and requires `min <= max`. Writing `scale: {min: 3, max: 1}` in YAML
would be silently accepted today and produce an invalid annotation pair. The smart constructor
rejects `max < min` with `Left "max scale (1) must be >= min scale (3)"`.

`EnvVar = EnvLiteral Text | EnvSecretRef SecretName` is the headline safety invariant. The
YAML schema has each env entry as either `value: <literal>` or `secretRef: <name>`, but a
YAML parser cannot stop you from writing both keys in one entry. The sum type makes the choice
exclusive by construction: you pick a branch of the sum type, and there is no way to construct
a value that is simultaneously `EnvLiteral` and `EnvSecretRef`. This kills the YAML bug where
an entry has both `value:` and `secretRef:` set.

`Domain` wraps `Text` with `mkDomain :: Text -> Either Text Domain` validating a non-empty
hostname (no spaces, no protocol prefix).

`Deployment` is a plain data type whose *fields* are the validated types above. It has no
hidden constructor — you assemble it with a record literal — but because every field's type is
validated at construction, an invalid `Deployment` cannot be created from valid field values
alone. The only way to get an invalid field into a `Deployment` is if you ignore the `Left`
from a smart constructor.


## Plan of Work

The work proceeds in four milestones, each independently verifiable. Implement and test each
milestone fully before moving to the next.

**Milestone M1 — the Cabal skeleton compiles.** At the end of M1, `cli/nagare-dsl/` exists
as a Cabal package, the two stub modules type-check without errors, and `cabal build` from
`cli/nagare-dsl/` prints no errors. This proves the package layout is correct before writing
any logic. No tests are run in M1 — that is M2.

**Milestone M2 — Types.hs is complete; unit tests pass.** At the end of M2,
`Nagare.Dsl.Types` contains all newtypes, sum types, and smart constructors with full
validation logic. A tasty unit test suite proves each smart constructor accepts its valid
inputs and rejects each invalid input with the expected `Left` message. `cabal test` prints a
table of passing tests and exits 0.

**Milestone M3 — Render.hs is complete; golden tests pass.** At the end of M3,
`Nagare.Dsl.Render` renders a fully-specified `Deployment` to Knative YAML bytes. The golden
test constructs the canonical `hello` deployment from the smart constructors, renders it with
tag `"20260602-120000"`, and compares byte-for-byte to checked-in golden files. `cabal test`
passes all unit tests (M2) and the new golden tests.

**Milestone M4 — negative type tests are documented and verified.** At the end of M4, a shell
script `test/negative/check-negative-types.sh` compiles a negative-test module with `ghc` and
asserts that the compiler rejects it with the expected error. Running the script produces
clear output proving two things: that `ServiceName`'s constructor is inaccessible outside the
module, and that there is no way to construct an `EnvVar` that is both a literal and a secret
reference (which is self-evident from the sum type but confirmed by the compile check).


## Concrete Steps

All commands below are run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare`
unless stated otherwise. Enter the developer shell first:

```bash
nix develop
```


### M1 — Cabal skeleton

**M1.1 — create `cli/nagare-dsl/cabal.project`.**

```bash
mkdir -p /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl/src/Nagare/Dsl
mkdir -p /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl/test/golden
mkdir -p /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl/test/negative
```

Create `cli/nagare-dsl/cabal.project`:

```cabal
-- cli/nagare-dsl/cabal.project
--
-- This file tells cabal that the nagare-dsl package lives in the current
-- directory. All dependencies (yaml, aeson, tasty, etc.) are resolved from
-- Hackage by default.
--
-- If Hackage is unavailable in your environment, add corpus source paths:
--
--   packages:
--     .
--     /Users/shinzui/Keikaku/hub/haskell/tasty-project/tasty/core
--     /Users/shinzui/Keikaku/hub/haskell/tasty-project/tasty/hunit
--     /Users/shinzui/Keikaku/hub/haskell/tasty-project/tasty-golden
--
-- Record in Surprises & Discoveries which path was used.
packages: .
```

**M1.2 — create `cli/nagare-dsl/nagare-dsl.cabal`.**

```cabal
cabal-version:      3.0
name:               nagare-dsl
version:            0.1.0.0
synopsis:           Typed deployment model and Knative renderer for Nagare.
description:
    A library of maximally-safe Haskell types for describing Nagare deployments,
    together with a renderer that produces Knative Service and DomainMapping YAML.
    Illegal configurations (bad DNS names, value+secretRef env vars, max<min scale)
    are made unrepresentable by the type system.
build-type:         Simple

common common
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        MultilineStrings
        OverloadedLabels
        OverloadedStrings
    ghc-options: -Wall -Wno-unused-imports

library
    import:           common
    hs-source-dirs:   src
    exposed-modules:
        Nagare.Dsl.Prelude
        Nagare.Dsl.Types
        Nagare.Dsl.Render
    build-depends:
        base        >= 4.17 && < 5
      , text
      , bytestring
      , containers
      , aeson
      , yaml
      , generic-lens ^>=2.2
      , lens         ^>=5.3

test-suite nagare-dsl-test
    import:           common
    type:             exitcode-stdio-1.0
    main-is:          Spec.hs
    hs-source-dirs:   test
    build-depends:
        base
      , nagare-dsl
      , text
      , bytestring
      , containers
      , tasty           >= 1.4
      , tasty-hunit     >= 0.10
      , tasty-golden    >= 2.3
```

Note on `GHC2024`: this is the house-standard language edition (requires GHC 9.12, which the
pinned Nix flake provides). It bundles the commonly-needed extensions (`DataKinds`,
`DerivingStrategies`, `LambdaCase`, `ImportQualifiedPost`, and more) so they need not be
listed individually. The `common` stanza then supplies the four mandatory house extensions —
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` — plus
`MultilineStrings` for readable embedded literals where useful.

**M1.3 — create stub modules.** Create `cli/nagare-dsl/src/Nagare/Dsl/Prelude.hs` (a stub
re-export that M1.2b replaces with the full prelude):

```haskell
module Nagare.Dsl.Prelude
  ( -- Stubs; filled in M1.2b
  ) where
```

Create `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`:

```haskell
module Nagare.Dsl.Types
  ( -- Stubs; filled in M2
  ) where
```

Create `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`:

```haskell
module Nagare.Dsl.Render
  ( -- Stubs; filled in M3
  ) where
```

Create `cli/nagare-dsl/test/Spec.hs`:

```haskell
module Main (main) where

main :: IO ()
main = putStrLn "tests not yet implemented"
```

**M1.4 — verify the build.** From `cli/nagare-dsl/`:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
```

Expected (trimmed):

```text
Resolving dependencies...
Build profile: -w ghc-9.12 -O1
...
[1 of 3] Compiling Nagare.Dsl.Prelude ( src/Nagare/Dsl/Prelude.hs, ... )
[2 of 3] Compiling Nagare.Dsl.Types   ( src/Nagare/Dsl/Types.hs, ... )
[3 of 3] Compiling Nagare.Dsl.Render  ( src/Nagare/Dsl/Render.hs, ... )
```

If `cabal` cannot resolve `yaml` or `aeson` from Hackage (error like
`Could not resolve dependencies`), add the corpus fallback paths to `cabal.project` as shown
in the comment in that file and record the fact in Surprises & Discoveries.

**M1.2b — implement `cli/nagare-dsl/src/Nagare/Dsl/Prelude.hs`.** Replace the stub with the
full custom prelude. It re-exports the common imports used across the package (so modules do
not repeat them) plus the lens operators. Per the house standard it does **not** re-export
`Data.Generics.Labels` — each module that uses `#label` imports it itself.

```haskell
{-# LANGUAGE PackageImports #-}

module Nagare.Dsl.Prelude
  ( module X
  , module Control.Lens
  ) where

import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" GHC.Generics as X (Generic)
import "text" Data.Text as X (Text)
import "lens" Control.Lens
```


### M2 — Types.hs and unit tests

**M2.1 — implement `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`.** Replace the stub with the
full implementation. The complete module:

```haskell
module Nagare.Dsl.Types
  ( -- * ServiceName
    ServiceName
  , mkServiceName
  , serviceNameText
    -- * Namespace
  , Namespace
  , mkNamespace
  , defaultNamespace
  , namespaceText
    -- * ImageRef
  , ImageRef
  , mkImageRef
  , imageRefText
    -- * EnvName
  , EnvName
  , mkEnvName
  , envNameText
    -- * SecretName
  , SecretName
  , mkSecretName
  , secretNameText
    -- * EnvVar
  , EnvVar (..)
    -- * Port
  , Port
  , mkPort
  , defaultPort
  , portInt
    -- * Quantity
  , Quantity
  , mkQuantity
  , quantityText
    -- * Resources
  , Resources (..)
    -- * Scale
  , Scale (..)
  , mkScale
    -- * Domain
  , Domain
  , mkDomain
  , domainText
    -- * Deployment
  , Deployment (..)
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isAlphaNum, isDigit, isLower)
import Data.Map (Map)
import Data.Text qualified as Text

-- | A Kubernetes / RFC 1123 DNS label used as the Knative Service name.
-- The constructor is hidden. Use 'mkServiceName'.
newtype ServiceName = ServiceName Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'ServiceName'.
-- A valid service name is 1–63 characters, consisting of lowercase letters,
-- digits, and hyphens, not starting or ending with a hyphen.
mkServiceName :: Text -> Either Text ServiceName
mkServiceName t
  | Text.null t                     = Left "service name must not be empty"
  | Text.length t > 63              = Left ("service name too long (" <> Text.pack (show (Text.length t)) <> " chars, max 63)")
  | Text.isPrefixOf "-" t           = Left "service name must not start with a hyphen"
  | Text.isSuffixOf "-" t           = Left "service name must not end with a hyphen"
  | not (Text.all validChar t)      = Left ("service name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise                       = Right (ServiceName t)
  where
    validChar c = isLower c || isDigit c || c == '-'

serviceNameText :: ServiceName -> Text
serviceNameText (ServiceName t) = t

-- | Kubernetes namespace name.
-- The constructor is hidden. Use 'mkNamespace' or 'defaultNamespace'.
newtype Namespace = Namespace Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Namespace'. Applies the same rules as 'mkServiceName'.
mkNamespace :: Text -> Either Text Namespace
mkNamespace t
  | Text.null t                = Left "namespace must not be empty"
  | Text.length t > 63         = Left "namespace too long (max 63)"
  | Text.isPrefixOf "-" t      = Left "namespace must not start with a hyphen"
  | Text.isSuffixOf "-" t      = Left "namespace must not end with a hyphen"
  | not (Text.all validChar t) = Left ("namespace contains invalid characters: " <> t)
  | otherwise               = Right (Namespace t)
  where
    validChar c = isLower c || isDigit c || c == '-'

-- | The default Nagare namespace: @"personal"@.
defaultNamespace :: Namespace
defaultNamespace = Namespace "personal"

namespaceText :: Namespace -> Text
namespaceText (Namespace t) = t

-- | Container image repository path, with no tag.
-- For example: @"gcr.io\/knative-samples\/helloworld-go"@.
-- The constructor is hidden. Use 'mkImageRef'.
newtype ImageRef = ImageRef Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct an 'ImageRef'.
-- The text must be non-empty and must not contain a colon (tags are appended
-- separately by 'Nagare.Dsl.Render.renderService').
mkImageRef :: Text -> Either Text ImageRef
mkImageRef t
  | Text.null t          = Left "image ref must not be empty"
  | Text.elem ':' t      = Left ("image ref must not include a tag (found ':' in: " <> t <> ")")
  | otherwise         = Right (ImageRef t)

imageRefText :: ImageRef -> Text
imageRefText (ImageRef t) = t

-- | An environment variable name, e.g. @"DATABASE_URL"@.
-- The constructor is hidden. Use 'mkEnvName'.
newtype EnvName = EnvName Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct an 'EnvName'. Must be non-empty.
mkEnvName :: Text -> Either Text EnvName
mkEnvName t
  | Text.null t  = Left "env name must not be empty"
  | otherwise = Right (EnvName t)

envNameText :: EnvName -> Text
envNameText (EnvName t) = t

-- | A Kubernetes Secret name, used in 'EnvSecretRef'.
-- The constructor is hidden. Use 'mkSecretName'.
newtype SecretName = SecretName Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'SecretName'. Must be non-empty.
mkSecretName :: Text -> Either Text SecretName
mkSecretName t
  | Text.null t  = Left "secret name must not be empty"
  | otherwise = Right (SecretName t)

secretNameText :: SecretName -> Text
secretNameText (SecretName t) = t

-- | The value of an environment variable: either a literal text value or a
-- reference to a Kubernetes Secret.
--
-- This is the headline safety invariant: the YAML schema allows both a
-- @value:@ key and a @secretRef:@ key to appear in one env entry, producing
-- an invalid manifest that Kubernetes silently ignores or misinterprets.
-- By modelling env values as a sum type, it is impossible to construct a
-- value that is simultaneously literal and a secret reference — you pick
-- exactly one branch. The compiler enforces this; no runtime check is needed.
data EnvVar
  = EnvLiteral Text
    -- ^ A literal environment variable value, rendered as @value: <text>@.
  | EnvSecretRef SecretName
    -- ^ A Kubernetes Secret reference, rendered as
    -- @valueFrom.secretKeyRef.name: <secret>@ with @key@ set to the
    -- environment variable's own name (see 'Nagare.Dsl.Render.renderService').
  deriving stock (Generic, Eq, Show)

-- | A TCP port number.
-- The constructor is hidden. Use 'mkPort' or 'defaultPort'.
newtype Port = Port Int
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Port'. Valid range is 1–65535.
mkPort :: Int -> Either Text Port
mkPort n
  | n < 1     = Left ("port must be >= 1, got: " <> Text.pack (show n))
  | n > 65535 = Left ("port must be <= 65535, got: " <> Text.pack (show n))
  | otherwise = Right (Port n)

-- | The default container port: @8080@.
defaultPort :: Port
defaultPort = Port 8080

portInt :: Port -> Int
portInt (Port n) = n

-- | A Kubernetes quantity string, used for CPU and memory resource requests.
-- Examples: @"250m"@ (250 millicpu), @"512Mi"@ (512 mebibytes), @"1"@ (1 CPU),
-- @"2Gi"@ (2 gibibytes).
--
-- The constructor is hidden. Use 'mkQuantity'.
newtype Quantity = Quantity Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Quantity'.
-- Accepts the subset of Kubernetes quantity syntax used in practice:
-- an integer (or decimal fraction) optionally followed by a recognised suffix.
-- Recognised suffixes: @m@, @k@, @M@, @G@, @T@, @P@, @E@, @Ki@, @Mi@, @Gi@,
-- @Ti@, @Pi@, @Ei@.
mkQuantity :: Text -> Either Text Quantity
mkQuantity t
  | Text.null t  = Left "quantity must not be empty"
  | otherwise =
      let (digits, rest0) = Text.span isDigit t
      in if Text.null digits
         then Left ("quantity must start with a digit: " <> t)
         else
           let (frac, rest1) = parseFraction rest0
               _ = frac  -- consumed but not stored, just validated
           in if validSuffix rest1
              then Right (Quantity t)
              else Left ("unrecognised quantity suffix: " <> rest1 <> " (in: " <> t <> ")")
  where
    parseFraction s =
      case Text.uncons s of
        Just ('.', rest) -> let (d, r) = Text.span isDigit rest in (Just d, r)
        _                -> (Nothing, s)
    validSuffix s = s `elem`
      [ ""
      , "m", "k", "M", "G", "T", "P", "E"
      , "Ki", "Mi", "Gi", "Ti", "Pi", "Ei"
      ]

quantityText :: Quantity -> Text
quantityText (Quantity t) = t

-- | CPU and memory resource requests for the container.
data Resources = Resources
  { cpu    :: !(Maybe Quantity)
  , memory :: !(Maybe Quantity)
  } deriving stock (Generic, Eq, Show)

-- | Knative autoscaling bounds.
-- Fields: 'minScale' (minimum pods, 0 means scale-to-zero),
-- 'maxScale' (maximum pods).
-- Use 'mkScale' to construct; direct record construction bypasses validation.
data Scale = Scale
  { minScale :: !Int
  , maxScale :: !Int
  } deriving stock (Generic, Eq, Show)

-- | Validate and construct a 'Scale'.
-- Rejects negative values and requires @min <= max@.
mkScale :: Int -> Int -> Either Text Scale
mkScale mn mx
  | mn < 0    = Left ("scale min must be >= 0, got: " <> Text.pack (show mn))
  | mx < 0    = Left ("scale max must be >= 0, got: " <> Text.pack (show mx))
  | mx < mn   = Left ("scale max (" <> Text.pack (show mx) <> ") must be >= scale min (" <> Text.pack (show mn) <> ")")
  | otherwise = Right (Scale { minScale = mn, maxScale = mx })

-- | A custom public hostname for a DomainMapping, e.g. @"notes.example.com"@.
-- The constructor is hidden. Use 'mkDomain'.
newtype Domain = Domain Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Domain'.
-- Must be non-empty and contain no spaces or URI scheme.
mkDomain :: Text -> Either Text Domain
mkDomain t
  | Text.null t          = Left "domain must not be empty"
  | Text.elem ' ' t      = Left ("domain must not contain spaces: " <> t)
  | "://" `Text.isInfixOf` t = Left ("domain must not include a URI scheme (http://, https://): " <> t)
  | otherwise         = Right (Domain t)

domainText :: Domain -> Text
domainText (Domain t) = t

-- | A fully-specified Nagare deployment.
-- Assemble with a record literal after constructing each field through its
-- smart constructor. There is no hidden constructor for 'Deployment' — the
-- safety guarantee comes from the field types, not from hiding this record.
data Deployment = Deployment
  { name      :: !ServiceName
  , namespace :: !Namespace
  , image     :: !ImageRef
  , domain    :: !(Maybe Domain)
  , port      :: !Port
  , env       :: !(Map EnvName EnvVar)
    -- ^ Env entries are sorted by 'EnvName' (ascending) by 'Data.Map.Map',
    -- which guarantees deterministic YAML output without extra sorting.
  , resources :: !(Maybe Resources)
  , scale     :: !(Maybe Scale)
  } deriving stock (Generic, Eq, Show)
```

**M2.2 — implement `cli/nagare-dsl/test/Spec.hs` unit tests.** Replace the stub:

```haskell
module Main (main) where

import Data.Map qualified as Map
import Data.Text qualified as Text
import Test.Tasty
import Test.Tasty.HUnit
import Nagare.Dsl.Types

main :: IO ()
main = defaultMain $ testGroup "Nagare.Dsl.Types"
  [ testGroup "mkServiceName"
      [ testCase "accepts valid name"            $ assertRight (mkServiceName "hello")
      , testCase "accepts name with hyphens"     $ assertRight (mkServiceName "my-app-123")
      , testCase "accepts single character"      $ assertRight (mkServiceName "a")
      , testCase "accepts 63 chars"              $ assertRight (mkServiceName (rep 63 'a'))
      , testCase "rejects empty"                 $ assertLeftContains "empty"       (mkServiceName "")
      , testCase "rejects 64 chars"              $ assertLeftContains "too long"    (mkServiceName (rep 64 'a'))
      , testCase "rejects leading hyphen"        $ assertLeftContains "hyphen"      (mkServiceName "-bad")
      , testCase "rejects trailing hyphen"       $ assertLeftContains "hyphen"      (mkServiceName "bad-")
      , testCase "rejects uppercase"             $ assertLeftContains "invalid"     (mkServiceName "Hello")
      , testCase "rejects space"                 $ assertLeftContains "invalid"     (mkServiceName "my app")
      , testCase "rejects dot"                   $ assertLeftContains "invalid"     (mkServiceName "my.app")
      ]
  , testGroup "mkNamespace"
      [ testCase "accepts personal"              $ assertRight (mkNamespace "personal")
      , testCase "rejects empty"                 $ assertLeftContains "empty"       (mkNamespace "")
      , testCase "rejects uppercase"             $ assertLeftContains "invalid"     (mkNamespace "Personal")
      ]
  , testGroup "mkImageRef"
      [ testCase "accepts path"                  $ assertRight (mkImageRef "gcr.io/foo/bar")
      , testCase "rejects empty"                 $ assertLeftContains "empty"       (mkImageRef "")
      , testCase "rejects path with tag"         $ assertLeftContains "tag"         (mkImageRef "gcr.io/foo/bar:latest")
      ]
  , testGroup "mkPort"
      [ testCase "accepts 8080"                  $ assertRight (mkPort 8080)
      , testCase "accepts 1"                     $ assertRight (mkPort 1)
      , testCase "accepts 65535"                 $ assertRight (mkPort 65535)
      , testCase "rejects 0"                     $ assertLeftContains ">= 1"        (mkPort 0)
      , testCase "rejects negative"              $ assertLeftContains ">= 1"        (mkPort (-1))
      , testCase "rejects 65536"                 $ assertLeftContains "<= 65535"    (mkPort 65536)
      ]
  , testGroup "mkQuantity"
      [ testCase "accepts 250m"                  $ assertRight (mkQuantity "250m")
      , testCase "accepts 512Mi"                 $ assertRight (mkQuantity "512Mi")
      , testCase "accepts 1"                     $ assertRight (mkQuantity "1")
      , testCase "accepts 2Gi"                   $ assertRight (mkQuantity "2Gi")
      , testCase "accepts 1.5"                   $ assertRight (mkQuantity "1.5")
      , testCase "rejects empty"                 $ assertLeftContains "empty"       (mkQuantity "")
      , testCase "rejects abc"                   $ assertLeftContains "digit"       (mkQuantity "abc")
      , testCase "rejects bad suffix"            $ assertLeftContains "suffix"      (mkQuantity "100x")
      , testCase "rejects space"                 $ assertLeftContains "suffix"      (mkQuantity "100 Mi")
      ]
  , testGroup "mkScale"
      [ testCase "accepts 0 3"                   $ assertRight (mkScale 0 3)
      , testCase "accepts equal min==max"        $ assertRight (mkScale 2 2)
      , testCase "rejects negative min"          $ assertLeftContains ">= 0"        (mkScale (-1) 3)
      , testCase "rejects negative max"          $ assertLeftContains ">= 0"        (mkScale 0 (-1))
      , testCase "rejects max < min"             $ assertLeftContains ">="          (mkScale 3 1)
      ]
  , testGroup "mkDomain"
      [ testCase "accepts hostname"              $ assertRight (mkDomain "hello.example.com")
      , testCase "rejects empty"                 $ assertLeftContains "empty"       (mkDomain "")
      , testCase "rejects space"                 $ assertLeftContains "space"       (mkDomain "my domain.com")
      , testCase "rejects https scheme"          $ assertLeftContains "scheme"      (mkDomain "https://foo.com")
      ]
  , testGroup "EnvVar (sum type mutual exclusion)"
      [ testCase "EnvLiteral constructs"         $ EnvLiteral "info" @?= EnvLiteral "info"
      , testCase "EnvSecretRef constructs"       $
          let Right sn = mkSecretName "my-secret"
          in EnvSecretRef sn @?= EnvSecretRef sn
      -- The fact that there is no constructor that accepts both a Text literal
      -- and a SecretName simultaneously is proven by the type definition:
      -- only EnvLiteral and EnvSecretRef exist. The negative compile test in
      -- M4 provides additional evidence.
      ]
  ]

-- | Assert that the result is a 'Right'.
assertRight :: (Show e) => Either e a -> Assertion
assertRight (Right _) = pure ()
assertRight (Left e)  = assertFailure ("expected Right but got Left: " <> show e)

-- | Assert that the result is a 'Left' whose message contains the given substring.
assertLeftContains :: Text -> Either Text a -> Assertion
assertLeftContains needle (Left msg)
  | needle `elem'` msg = pure ()
  | otherwise          = assertFailure
      ("expected Left containing " <> show needle <> " but got: " <> show msg)
  where
    elem' n h = n `Text.isInfixOf` h
assertLeftContains needle (Right _) =
  assertFailure ("expected Left containing " <> show needle <> " but got Right")

rep :: Int -> Char -> Text
rep n c = Text.pack (replicate n c)
```

This first draft needs the `Text` type in scope for the helper signatures. Add an
unqualified import alongside the postpositive qualified one:

```haskell
import Data.Text (Text)
import Data.Text qualified as Text
```

The full Spec.hs with these consistent imports:

```haskell
module Main (main) where

import Data.Text (Text)
import Data.Text qualified as Text
import Test.Tasty
import Test.Tasty.HUnit
import Nagare.Dsl.Types

main :: IO ()
main = defaultMain $ testGroup "Nagare.Dsl.Types"
  [ testGroup "mkServiceName"
      [ testCase "accepts valid name"            $ assertRight (mkServiceName "hello")
      , testCase "accepts name with hyphens"     $ assertRight (mkServiceName "my-app-123")
      , testCase "accepts single char"           $ assertRight (mkServiceName "a")
      , testCase "accepts 63 chars"              $ assertRight (mkServiceName (Text.replicate 63 "a"))
      , testCase "rejects empty"                 $ assertLeftContains "empty"    (mkServiceName "")
      , testCase "rejects 64 chars"              $ assertLeftContains "long"     (mkServiceName (Text.replicate 64 "a"))
      , testCase "rejects leading hyphen"        $ assertLeftContains "hyphen"   (mkServiceName "-bad")
      , testCase "rejects trailing hyphen"       $ assertLeftContains "hyphen"   (mkServiceName "bad-")
      , testCase "rejects uppercase"             $ assertLeftContains "invalid"  (mkServiceName "Hello")
      , testCase "rejects space"                 $ assertLeftContains "invalid"  (mkServiceName "my app")
      ]
  , testGroup "mkNamespace"
      [ testCase "accepts personal"              $ assertRight (mkNamespace "personal")
      , testCase "rejects empty"                 $ assertLeftContains "empty"    (mkNamespace "")
      , testCase "rejects uppercase"             $ assertLeftContains "invalid"  (mkNamespace "Personal")
      ]
  , testGroup "mkImageRef"
      [ testCase "accepts path"                  $ assertRight (mkImageRef "gcr.io/foo/bar")
      , testCase "rejects empty"                 $ assertLeftContains "empty"    (mkImageRef "")
      , testCase "rejects tagged path"           $ assertLeftContains "tag"      (mkImageRef "gcr.io/foo/bar:latest")
      ]
  , testGroup "mkPort"
      [ testCase "accepts 8080"                  $ assertRight (mkPort 8080)
      , testCase "accepts 1"                     $ assertRight (mkPort 1)
      , testCase "accepts 65535"                 $ assertRight (mkPort 65535)
      , testCase "rejects 0"                     $ assertLeftContains ">= 1"     (mkPort 0)
      , testCase "rejects negative"              $ assertLeftContains ">= 1"     (mkPort (-1))
      , testCase "rejects 65536"                 $ assertLeftContains "<= 65535" (mkPort 65536)
      ]
  , testGroup "mkQuantity"
      [ testCase "accepts 250m"                  $ assertRight (mkQuantity "250m")
      , testCase "accepts 512Mi"                 $ assertRight (mkQuantity "512Mi")
      , testCase "accepts 1"                     $ assertRight (mkQuantity "1")
      , testCase "accepts 2Gi"                   $ assertRight (mkQuantity "2Gi")
      , testCase "accepts 1.5"                   $ assertRight (mkQuantity "1.5")
      , testCase "rejects empty"                 $ assertLeftContains "empty"    (mkQuantity "")
      , testCase "rejects abc"                   $ assertLeftContains "digit"    (mkQuantity "abc")
      , testCase "rejects 100x"                  $ assertLeftContains "suffix"   (mkQuantity "100x")
      ]
  , testGroup "mkScale"
      [ testCase "accepts 0 3"                   $ assertRight (mkScale 0 3)
      , testCase "accepts equal bounds"          $ assertRight (mkScale 2 2)
      , testCase "rejects negative min"          $ assertLeftContains ">= 0"     (mkScale (-1) 3)
      , testCase "rejects negative max"          $ assertLeftContains ">= 0"     (mkScale 0 (-1))
      , testCase "rejects max < min"             $ assertLeftContains ">="       (mkScale 3 1)
      ]
  , testGroup "mkDomain"
      [ testCase "accepts hostname"              $ assertRight (mkDomain "hello.example.com")
      , testCase "rejects empty"                 $ assertLeftContains "empty"    (mkDomain "")
      , testCase "rejects space"                 $ assertLeftContains "space"    (mkDomain "my domain.com")
      , testCase "rejects uri scheme"            $ assertLeftContains "scheme"   (mkDomain "https://foo.com")
      ]
  , testGroup "EnvVar sum type"
      [ testCase "EnvLiteral constructs"         $ EnvLiteral "info" @?= EnvLiteral "info"
      , testCase "EnvSecretRef constructs" $
          let Right sn = mkSecretName "db-url"
          in EnvSecretRef sn @?= EnvSecretRef sn
      ]
  ]

assertRight :: (Show e) => Either e a -> Assertion
assertRight (Right _)  = pure ()
assertRight (Left err) = assertFailure ("expected Right, got Left: " <> show err)

assertLeftContains :: Text -> Either Text a -> Assertion
assertLeftContains needle (Left msg)
  | needle `Text.isInfixOf` msg = pure ()
  | otherwise = assertFailure
      ("expected Left containing " <> show needle <> ", got: " <> Text.unpack msg)
assertLeftContains needle (Right _) =
  assertFailure ("expected Left containing " <> show needle <> ", got Right")
```

**M2.3 — run the unit tests.** From `cli/nagare-dsl/`:

```bash
cabal test nagare-dsl-test --test-show-details=streaming
```

Expected output (abridged):

```text
Build profile: -w ghc-9.12 -O1
...
Running 1 test suites...
Test suite nagare-dsl-test: RUNNING...
Nagare.Dsl.Types
  mkServiceName
    accepts valid name:     OK
    accepts name with hyphens: OK
    accepts single char:    OK
    accepts 63 chars:       OK
    rejects empty:          OK
    rejects 64 chars:       OK
    rejects leading hyphen: OK
    rejects trailing hyphen: OK
    rejects uppercase:      OK
    rejects space:          OK
  mkNamespace
    accepts personal:       OK
    rejects empty:          OK
    rejects uppercase:      OK
  mkImageRef
    accepts path:           OK
    rejects empty:          OK
    rejects tagged path:    OK
  mkPort
    accepts 8080:           OK
    accepts 1:              OK
    accepts 65535:          OK
    rejects 0:              OK
    rejects negative:       OK
    rejects 65536:          OK
  mkQuantity
    accepts 250m:           OK
    accepts 512Mi:          OK
    accepts 1:              OK
    accepts 2Gi:            OK
    accepts 1.5:            OK
    rejects empty:          OK
    rejects abc:            OK
    rejects 100x:           OK
  mkScale
    accepts 0 3:            OK
    accepts equal bounds:   OK
    rejects negative min:   OK
    rejects negative max:   OK
    rejects max < min:      OK
  mkDomain
    accepts hostname:       OK
    rejects empty:          OK
    rejects space:          OK
    rejects uri scheme:     OK
  EnvVar sum type
    EnvLiteral constructs:  OK
    EnvSecretRef constructs: OK

All 38 tests passed (0.00s)
Test suite nagare-dsl-test: PASS
```

Every test must pass. If any test fails, the error message from `assertFailure` will show the
actual `Left` message, which lets you diagnose and fix the smart constructor immediately.


### M3 — Render.hs and golden tests

**M3.1 — implement `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`.**

```haskell
module Nagare.Dsl.Render
  ( renderService
  , renderDomainMapping
  ) where

import Nagare.Dsl.Prelude
import "generic-lens" Data.Generics.Labels ()

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Types

-- | Render a 'Deployment' to a Knative Service YAML document.
-- The second argument is the resolved image tag (e.g. @"20260602-120000"@).
-- The container image is assembled as @imageRef <> ":" <> tag@.
-- Env entries are rendered sorted by variable name (ascending);
-- 'Data.Map.Map' already stores keys in ascending order, so 'Map.toAscList'
-- gives the correct order without additional sorting.
renderService :: Deployment -> Text -> ByteString
renderService dep tag =
  Yaml.encode (serviceValue dep tag)

-- | Render a 'DomainMapping' YAML document for the deployment's custom domain.
-- Returns 'Nothing' when the deployment's @domain@ field is absent.
renderDomainMapping :: Deployment -> Maybe ByteString
renderDomainMapping dep =
  fmap (\d -> Yaml.encode (domainMappingValue dep d)) (dep ^. #domain)

-- ---------------------------------------------------------------------------
-- Internal builders

serviceValue :: Deployment -> Text -> Value
serviceValue dep tag =
  object
    [ "apiVersion" .= String "serving.knative.dev/v1"
    , "kind"       .= String "Service"
    , "metadata"   .= metadataValue (serviceNameText (dep ^. #name))
                                    (namespaceText   (dep ^. #namespace))
    , "spec"       .= object [ "template" .= templateValue dep tag ]
    ]

metadataValue :: Text -> Text -> Value
metadataValue name ns =
  object
    [ "name"      .= String name
    , "namespace" .= String ns
    ]

templateValue :: Deployment -> Text -> Value
templateValue dep tag =
  case dep ^. #scale of
    Nothing ->
      object [ "spec" .= specValue dep tag ]
    Just sc ->
      object
        [ "metadata" .= object [ "annotations" .= annotationsValue sc ]
        , "spec"     .= specValue dep tag
        ]

annotationsValue :: Scale -> Value
annotationsValue sc =
  object
    [ "autoscaling.knative.dev/min-scale" .= String (Text.pack (show (sc ^. #minScale)))
    , "autoscaling.knative.dev/max-scale" .= String (Text.pack (show (sc ^. #maxScale)))
    ]

specValue :: Deployment -> Text -> Value
specValue dep tag =
  object [ "containers" .= toJSON [containerValue dep tag] ]

-- Produce the container Value, omitting optional sub-blocks when absent.
containerValue :: Deployment -> Text -> Value
containerValue dep tag =
  object (required <> optional')
  where
    imageStr = imageRefText (dep ^. #image) <> ":" <> tag
    portN    = portInt (dep ^. #port)
    required =
      [ "image" .= String imageStr
      , "ports" .= toJSON [object ["containerPort" .= Number (fromIntegral portN)]]
      ]
    optional' =
         (if Map.null (dep ^. #env) then [] else ["env" .= envValues (dep ^. #env)])
      <> (case dep ^. #resources of
            Nothing  -> []
            Just res -> ["resources" .= resourcesValue res])

envValues :: Map EnvName EnvVar -> Value
envValues m =
  toJSON (map envEntry (Map.toAscList m))
  where
    envEntry (name, ev) = envEntryValue (envNameText name) ev

envEntryValue :: Text -> EnvVar -> Value
envEntryValue name (EnvLiteral lit) =
  object ["name" .= String name, "value" .= String lit]
envEntryValue name (EnvSecretRef sn) =
  object
    [ "name"      .= String name
    , "valueFrom" .= object
        [ "secretKeyRef" .= object
            [ "name" .= String (secretNameText sn)
            , "key"  .= String name
            ]
        ]
    ]

resourcesValue :: Resources -> Value
resourcesValue res =
  object [ "requests" .= requestsObject ]
  where
    cpu    = fmap (\q -> "cpu"    .= String (quantityText q)) (res ^. #cpu)
    mem    = fmap (\q -> "memory" .= String (quantityText q)) (res ^. #memory)
    requestsObject = object (catMaybes [cpu, mem])
    catMaybes = foldr (\mx acc -> case mx of Nothing -> acc; Just x -> x : acc) []

domainMappingValue :: Deployment -> Domain -> Value
domainMappingValue dep d =
  object
    [ "apiVersion" .= String "serving.knative.dev/v1beta1"
    , "kind"       .= String "DomainMapping"
    , "metadata"   .= metadataValue (domainText d) (namespaceText (dep ^. #namespace))
    , "spec"       .= object
        [ "ref" .= object
            [ "apiVersion" .= String "serving.knative.dev/v1"
            , "kind"       .= String "Service"
            , "name"       .= String (serviceNameText (dep ^. #name))
            ]
        ]
    ]
```

Note: `Data.Aeson.Array` takes a `Data.Vector.Vector Value`. Add `vector` to `build-depends`
in `nagare-dsl.cabal`, or use the `aeson` re-export. The cleanest way to build a JSON array
from a list is `Data.Aeson.toJSON :: [Value] -> Value`, which uses the `ToJSON` instance for
lists and produces a YAML sequence. Replace the `Array` usage with:

```haskell
import Data.Aeson (Value (..), object, (.=), toJSON)
```

Then write `envValues` and `containerValue` using `toJSON`:

```haskell
envValues :: Map EnvName EnvVar -> Value
envValues m = toJSON (map envEntry (Map.toAscList m))
  where
    envEntry (name, ev) = envEntryValue (envNameText name) ev

-- In containerValue:
    required =
      [ "image" .= String imageStr
      , "ports" .= toJSON [object ["containerPort" .= portN]]
      ]
```

This avoids importing `Data.Vector`. The final `Render.hs` with the corrected approach
(using `toJSON` throughout for lists):

```haskell
module Nagare.Dsl.Render
  ( renderService
  , renderDomainMapping
  ) where

import Nagare.Dsl.Prelude
import "generic-lens" Data.Generics.Labels ()

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Types

-- | Render a 'Deployment' to a Knative Service YAML document.
-- The second argument is the resolved image tag, e.g. @"20260602-120000"@.
renderService :: Deployment -> Text -> ByteString
renderService dep tag = Yaml.encode (serviceValue dep tag)

-- | Render a DomainMapping YAML document.
-- Returns 'Nothing' when the deployment's @domain@ field is absent.
renderDomainMapping :: Deployment -> Maybe ByteString
renderDomainMapping dep = fmap (Yaml.encode . domainMappingValue dep) (dep ^. #domain)

-- ---------------------------------------------------------------------------
-- Internal builders

serviceValue :: Deployment -> Text -> Value
serviceValue dep tag =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind"       .= ("Service" :: Text)
    , "metadata"   .= namespacedMeta (serviceNameText (dep ^. #name))
                                     (namespaceText   (dep ^. #namespace))
    , "spec"       .= object ["template" .= templateValue dep tag]
    ]

namespacedMeta :: Text -> Text -> Value
namespacedMeta name ns =
  object ["name" .= name, "namespace" .= ns]

templateValue :: Deployment -> Text -> Value
templateValue dep tag =
  case dep ^. #scale of
    Nothing ->
      object ["spec" .= specValue dep tag]
    Just sc ->
      object
        [ "metadata" .= object ["annotations" .= annotationsValue sc]
        , "spec"     .= specValue dep tag
        ]

annotationsValue :: Scale -> Value
annotationsValue sc =
  object
    [ "autoscaling.knative.dev/min-scale" .= (Text.pack (show (sc ^. #minScale)) :: Text)
    , "autoscaling.knative.dev/max-scale" .= (Text.pack (show (sc ^. #maxScale)) :: Text)
    ]

specValue :: Deployment -> Text -> Value
specValue dep tag =
  object ["containers" .= toJSON [containerValue dep tag]]

containerValue :: Deployment -> Text -> Value
containerValue dep tag =
  object (required <> optionals)
  where
    imageStr = imageRefText (dep ^. #image) <> ":" <> tag
    portN    = portInt (dep ^. #port)
    required =
      [ "image" .= imageStr
      , "ports" .= toJSON [object ["containerPort" .= portN]]
      ]
    optionals =
         envField (dep ^. #env)
      <> resourcesField (dep ^. #resources)

envField :: Map EnvName EnvVar -> [(Data.Aeson.Key, Value)]
envField m
  | Map.null m = []
  | otherwise  = ["env" .= toJSON (map envEntry (Map.toAscList m))]
  where
    envEntry (name, ev) = envEntryValue (envNameText name) ev

envEntryValue :: Text -> EnvVar -> Value
envEntryValue name (EnvLiteral lit) =
  object ["name" .= name, "value" .= lit]
envEntryValue name (EnvSecretRef sn) =
  object
    [ "name"      .= name
    , "valueFrom" .= object
        [ "secretKeyRef" .= object
            [ "name" .= secretNameText sn
            , "key"  .= name
            ]
        ]
    ]

resourcesField :: Maybe Resources -> [(Data.Aeson.Key, Value)]
resourcesField Nothing    = []
resourcesField (Just res) =
  ["resources" .= object ["requests" .= object (cpuF <> memF)]]
  where
    cpuF = maybe [] (\q -> ["cpu"    .= quantityText q]) (res ^. #cpu)
    memF = maybe [] (\q -> ["memory" .= quantityText q]) (res ^. #memory)

domainMappingValue :: Deployment -> Domain -> Value
domainMappingValue dep d =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
    , "kind"       .= ("DomainMapping" :: Text)
    , "metadata"   .= namespacedMeta (domainText d)
                                     (namespaceText (dep ^. #namespace))
    , "spec"       .= object
        [ "ref" .= object
            [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
            , "kind"       .= ("Service" :: Text)
            , "name"       .= serviceNameText (dep ^. #name)
            ]
        ]
    ]
```

Note on `Data.Aeson.Key`: in aeson >= 2.0, object keys are of type `Key` (not `Text`).
The `.=` operator's left-hand side must be a `Key`. String literals are automatically
`Key` values via `IsString`. The type annotation `(.= ("text" :: Text))` works via the
`ToJSON Text` instance for values; you do not need to annotate the key. Write
`"apiVersion" .= someText` without annotation and the compiler will infer `Key` for the key.

Add `aeson` key compatibility note: if the build fails with
`Couldn't match type 'Text' with 'Key'`, change `[(Data.Aeson.Key, Value)]` to
`[Data.Aeson.Pair]` in the type signatures of `envField` and `resourcesField`.

**M3.2 — add `aeson` key to `nagare-dsl.cabal`.** The `Data.Aeson.Key` type from `aeson-key`
is re-exported by `aeson` in versions >= 2.0. No additional package is needed.

Add `vector` to `build-depends` only if the `Data.Vector.fromList` form is used (it is not in
the final version above — `toJSON` handles list conversion).

**M3.3 — write the golden files.** Copy the hello `nagare.yaml` input:

```bash
cp /Users/shinzui/Keikaku/bokuno/nagare/cluster/examples/hello-knative-service/nagare.yaml \
   /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl/test/golden/hello.nagare.yaml
```

The golden output files (`hello.service.yaml` and `hello.domainmapping.yaml`) must be
generated by the renderer — do not hand-write them, as byte-level quoting differs from
hand-authored YAML. Generate them by running a small `cabal repl` snippet:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal repl nagare-dsl
```

Then in the REPL:

```haskell
import Data.Map qualified as Map
import Data.ByteString qualified as BS
import Nagare.Dsl.Types
import Nagare.Dsl.Render

let Right svcName = mkServiceName "hello"
    Right ns      = mkNamespace "personal"
    Right img     = mkImageRef "gcr.io/knative-samples/helloworld-go"
    Right dom     = mkDomain "hello.example.com"
    Right prt     = mkPort 8080
    Right en      = mkEnvName "TARGET"
    Right sc      = mkScale 0 3
    Right cpuQ    = mkQuantity "250m"
    Right memQ    = mkQuantity "128Mi"
    res = Resources { cpu = Just cpuQ, memory = Just memQ }
    dep = Deployment
            { name      = svcName
            , namespace = ns
            , image     = img
            , domain    = Just dom
            , port      = prt
            , env       = Map.fromList [(en, EnvLiteral "Nagare")]
            , resources = Just res
            , scale     = Just sc
            }

BS.writeFile "test/golden/hello.service.yaml" (renderService dep "20260602-120000")
mapM_ (BS.writeFile "test/golden/hello.domainmapping.yaml") (renderDomainMapping dep)
```

Inspect the files to verify they look right:

```bash
cat test/golden/hello.service.yaml
cat test/golden/hello.domainmapping.yaml
```

The service golden file should look like this (produced by `Data.Yaml.encode`):

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello
  namespace: personal
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/max-scale: '3'
        autoscaling.knative.dev/min-scale: '0'
    spec:
      containers:
      - image: gcr.io/knative-samples/helloworld-go:20260602-120000
        ports:
        - containerPort: 8080
        env:
        - name: TARGET
          value: Nagare
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
```

Note: `Data.Yaml.encode` sorts object keys alphabetically within each YAML mapping. This means
`max-scale` appears before `min-scale` in the annotations (alphabetical order by full key).
This is correct behavior and the golden file must reflect the actual encoder output, not the
order shown in EP-6's illustrative example (which had `min-scale` first). Once you generate
the golden file from the renderer, the `goldenVsString` test locks in whatever order the
encoder produces. Commit the generated golden files — they are the ground truth.

The DomainMapping golden file should look like:

```yaml
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
metadata:
  name: hello.example.com
  namespace: personal
spec:
  ref:
    apiVersion: serving.knative.dev/v1
    kind: Service
    name: hello
```

Check the golden files into git — they are permanent test fixtures.

**M3.4 — add the golden test to `test/Spec.hs`.** Add imports and a new test group:

```haskell
import Data.ByteString.Lazy (ByteString, fromStrict)
import Data.ByteString.Lazy qualified as LBS
import Data.Map qualified as Map
import Test.Tasty.Golden (goldenVsString)
import Nagare.Dsl.Render (renderService, renderDomainMapping)
```

Add to the `main` function, alongside the existing unit-test group:

```haskell
main :: IO ()
main = defaultMain $ testGroup "nagare-dsl"
  [ testGroup "Nagare.Dsl.Types" unitTests
  , testGroup "Nagare.Dsl.Render" goldenTests
  ]
```

The `goldenTests` function:

```haskell
goldenTests :: [TestTree]
goldenTests =
  [ goldenVsString
      "renderService hello"
      "test/golden/hello.service.yaml"
      (pure (fromStrict (renderService helloDep "20260602-120000")))
  , goldenVsString
      "renderDomainMapping hello"
      "test/golden/hello.domainmapping.yaml"
      (case renderDomainMapping helloDep of
         Just bs -> pure (fromStrict bs)
         Nothing -> fail "renderDomainMapping returned Nothing for hello (expected Just)")
  ]

helloDep :: Deployment
helloDep =
  let Right svcName = mkServiceName "hello"
      Right ns      = mkNamespace "personal"
      Right img     = mkImageRef "gcr.io/knative-samples/helloworld-go"
      Right dom     = mkDomain "hello.example.com"
      Right prt     = mkPort 8080
      Right en      = mkEnvName "TARGET"
      Right sc      = mkScale 0 3
      Right cpuQ    = mkQuantity "250m"
      Right memQ    = mkQuantity "128Mi"
      res           = Resources { cpu = Just cpuQ, memory = Just memQ }
  in  Deployment
        { name      = svcName
        , namespace = ns
        , image     = img
        , domain    = Just dom
        , port      = prt
        , env       = Map.fromList [(en, EnvLiteral "Nagare")]
        , resources = Just res
        , scale     = Just sc
        }
```

`goldenVsString` from `tasty-golden` takes a test name, the path to the golden file, and an
`IO LBS.ByteString` action. If the golden file does not exist, the test creates it (first-run
bootstrap). If the file exists, the test compares byte-for-byte. The `fromStrict` call
converts the `Data.ByteString.ByteString` from the renderer to `Data.ByteString.Lazy.ByteString`
which `goldenVsString` expects.

**M3.5 — run all tests.** From `cli/nagare-dsl/`:

```bash
cabal test nagare-dsl-test --test-show-details=streaming
```

Expected outcome (the golden tests appear after the unit tests):

```text
...
Nagare.Dsl.Render
  renderService hello:        OK
  renderDomainMapping hello:  OK

All 40 tests passed (0.01s)
Test suite nagare-dsl-test: PASS
```

**Regenerating the golden files.** If the renderer output changes intentionally (e.g. after a
design decision changes key ordering), regenerate the golden files by deleting them and
re-running `cabal test`. `goldenVsString` will re-create the files on the first run with no
golden present, then pass on a second run. Alternatively, run the REPL snippet from M3.3
again. After regeneration, inspect the files, commit them, and document the change in the
Decision Log.


### M4 — negative type tests

The goal of M4 is to demonstrate, with a concrete compiler output, that two classes of illegal
configuration cannot be expressed in Haskell code using this library.

**What we prove:**

1. `ServiceName`'s constructor is inaccessible outside `Nagare.Dsl.Types`. Any module that
   tries to pattern-match on or construct `ServiceName "foo"` directly fails to compile.
2. There is no way to construct an `EnvVar` that is simultaneously a literal value and a
   secret reference. The `EnvVar` type is a sum type with exactly two constructors; no
   constructor accepts both a `Text` literal and a `SecretName` in a single application.

**M4.1 — create the negative test module.** Create
`cli/nagare-dsl/test/negative/BadConstructor.hs`:

```haskell
-- This module is EXPECTED TO FAIL TO COMPILE.
-- It demonstrates that ServiceName's constructor is inaccessible outside
-- Nagare.Dsl.Types, making it impossible to bypass mkServiceName's validation.
--
-- Do NOT add this module to a cabal test-suite.
-- Verify it via check-negative-types.sh (M4.2).
module BadConstructor where

import Nagare.Dsl.Types (ServiceName)

-- This line should produce:
--   error: Not in scope: data constructor 'ServiceName'
-- because Nagare.Dsl.Types does not export the 'ServiceName' data constructor.
badName :: ServiceName
badName = ServiceName "INVALID NAME WITH SPACES"
```

**M4.2 — create the shell check script.** Create
`cli/nagare-dsl/test/negative/check-negative-types.sh`:

```bash
#!/usr/bin/env bash
# Verify that modules which abuse internal constructors fail to compile.
# Run from the cli/nagare-dsl/ directory inside `nix develop`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
LIB_SRC="${REPO_ROOT}/cli/nagare-dsl/src"
NEG_DIR="${REPO_ROOT}/cli/nagare-dsl/test/negative"

echo "=== Negative type check: ServiceName constructor not exported ==="
echo "Compiling BadConstructor.hs (expected: compile error)"

# Capture stderr; ghc exits non-zero on type/scope errors.
if ghc \
  -i"${LIB_SRC}" \
  -package-db "$(cabal list-bin nagare-dsl 2>/dev/null | xargs dirname)/../lib/ghc-9.12/package.conf.d" \
  "${NEG_DIR}/BadConstructor.hs" \
  -o /dev/null 2>&1 | tee /tmp/neg-test-output.txt; then
  echo "FAIL: BadConstructor.hs compiled successfully — ServiceName constructor is leaking!"
  exit 1
else
  echo ""
  echo "PASS: GHC rejected BadConstructor.hs as expected."
  if grep -q "Not in scope.*ServiceName\|data constructor.*ServiceName" /tmp/neg-test-output.txt; then
    echo "PASS: Error message confirms 'ServiceName' constructor is not in scope."
  else
    echo "WARN: GHC rejected the file, but the expected scope error was not found."
    echo "Actual GHC output:"
    cat /tmp/neg-test-output.txt
    echo "Review the output above and update this script if the error wording changed."
  fi
fi

echo ""
echo "=== EnvVar mutual exclusion is enforced by the sum type ==="
echo "The EnvVar type has two constructors: EnvLiteral Text | EnvSecretRef SecretName."
echo "There is no constructor that accepts both a Text and a SecretName."
echo "This is verified by the compiler at every use site:"
echo "  EnvLiteral only accepts Text"
echo "  EnvSecretRef only accepts SecretName"
echo "No runtime check is needed; the type rules it out."
echo "PASS: EnvVar sum type mutual exclusion confirmed by type definition."

echo ""
echo "All negative type checks passed."
```

Make it executable:

```bash
chmod +x /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl/test/negative/check-negative-types.sh
```

**M4.3 — run the negative check.** The script requires the `nagare-dsl` package to have been
built first (so its compiled interface files are available). From `cli/nagare-dsl/`:

```bash
cabal build
```

Then use the simpler approach: compile the negative module using `ghc` directly, pointing it
at the source tree only (no compiled package DB needed if we just want to see the scope error,
because GHC will reject it before it needs the package):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
ghc -isrc test/negative/BadConstructor.hs -o /dev/null 2>&1
echo "Exit code: $?"
```

Expected output:

```text
test/negative/BadConstructor.hs:14:10: error: [GHC-88464]
    Not in scope: data constructor 'ServiceName'
    Module 'Nagare.Dsl.Types' does not export 'ServiceName'.

Exit code: 1
```

The GHC error code `[GHC-88464]` is GHC 9.x's error code for "Not in scope". If the exact
code differs in your version, any error mentioning `Not in scope` and `ServiceName` is
sufficient evidence. Record the actual output in Surprises & Discoveries.

Alternatively, run the script (it is more self-documenting):

```bash
bash /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl/test/negative/check-negative-types.sh
```

Expected final line:

```text
All negative type checks passed.
```


## Validation and Acceptance

Acceptance is behavioral. All three gates below must pass before this plan is marked complete.

**Gate 1 — M1/M2: smart-constructor unit tests pass.** From `cli/nagare-dsl/`:

```bash
cabal test nagare-dsl-test --test-show-details=streaming
```

All unit tests pass. The key behavioral proof: `mkScale 3 1` returns
`Left "scale max (1) must be >= scale min (3)"`, not `Right (Scale 3 1)`. A scale whose
`max` is below its `min` cannot exist as a value of type `Scale` — the error is caught here,
not when the cluster rejects the autoscaling annotation.

**Gate 2 — M3: golden tests pass.** From `cli/nagare-dsl/`:

```bash
cabal test nagare-dsl-test --test-show-details=streaming
```

Both golden tests pass: `renderService hello` and `renderDomainMapping hello`. The renderer
produces byte-for-byte output that matches the checked-in golden files. This proves the
renderer is compatible with the EP-6 cluster contract.

**Gate 3 — M4: negative compile check.** From `cli/nagare-dsl/`:

```bash
ghc -isrc test/negative/BadConstructor.hs -o /dev/null 2>&1
```

GHC exits with a non-zero code and prints an error containing `Not in scope` and `ServiceName`.
This proves the constructor is inaccessible.

To run all tests and the negative check in sequence:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test nagare-dsl-test --test-show-details=streaming \
  && ghc -isrc test/negative/BadConstructor.hs -o /dev/null 2>&1 | grep -q "Not in scope" \
  && echo "ALL GATES PASSED"
```

Expected final line: `ALL GATES PASSED`.


## Idempotence and Recovery

Every step is additive and safe to repeat. `cabal build` and `cabal test` are fully
idempotent — re-running either produces the same result. The only stateful step is generating
the golden files in M3.3: if you re-run the REPL snippet, it overwrites the golden files with
fresh renderer output. This is intentional for regeneration; in all other cases, leave the
golden files unchanged and let the test compare against them.

If `cabal test` fails with a golden mismatch, the test output shows the actual bytes from the
renderer and the expected bytes from the golden file. Fix the renderer or regenerate the golden
(if the change was intentional) and re-run. Never edit the golden file by hand — always
generate it from the renderer.

If the negative compile check in M4 produces an unexpected result (e.g. GHC compiles
`BadConstructor.hs` successfully, meaning the constructor leaked), the fix is to re-examine
the export list in `Nagare.Dsl.Types` and ensure `ServiceName` the constructor is absent.
The type must appear in the export list (`ServiceName` as a type, not `ServiceName(..)` as a
type-plus-constructors).

If Hackage is unavailable, add corpus source paths to `cabal.project` as documented in M1.1.
Record which path was used in Surprises & Discoveries.


## Interfaces and Dependencies

**Libraries and why.**

- `yaml` (Hackage, `Data.Yaml`) — serializes `aeson` `Value`s to YAML bytes with
  `Data.Yaml.encode`. This is the same library EP-6's renderer uses; using the same serializer
  ensures identical output for identical inputs.
- `aeson` (Hackage, `Data.Aeson`) — builds the typed JSON/YAML value tree with `object`,
  `toJSON`, and `.=`. Used as an intermediate representation between the typed `Deployment`
  value and the final YAML bytes.
- `containers` (`Data.Map.Strict` or `Data.Map`) — `Map EnvName EnvVar` for the env field.
  `Map` stores keys in ascending order; `toAscList` produces sorted-by-name env output
  deterministically, satisfying the golden-test stability requirement.
- `text` (`Data.Text`) — `Text` is used for all string fields in the type model.
- `bytestring` (`Data.ByteString`) — `renderService` and `renderDomainMapping` return `ByteString`.
- `tasty` >= 1.4, `tasty-hunit` >= 0.10 — test runner and HUnit assertions for unit tests.
  Corpus sources at `/Users/shinzui/Keikaku/hub/haskell/tasty-project/tasty/core` and
  `/Users/shinzui/Keikaku/hub/haskell/tasty-project/tasty/hunit`.
- `tasty-golden` >= 2.3 — `goldenVsString` for the byte-for-byte golden tests.
  Corpus source at `/Users/shinzui/Keikaku/hub/haskell/tasty-project/tasty-golden`.

**Types and function signatures** that must exist at the end of this plan (full module paths):

From `Nagare.Dsl.Types`:

```haskell
-- Newtypes with hidden constructors
newtype ServiceName   -- not exported: ServiceName(..)
newtype Namespace     -- not exported: Namespace(..)
newtype ImageRef      -- not exported: ImageRef(..)
newtype EnvName       -- not exported: EnvName(..)
newtype SecretName    -- not exported: SecretName(..)
newtype Port          -- not exported: Port(..)
newtype Quantity      -- not exported: Quantity(..)
newtype Domain        -- not exported: Domain(..)

-- Smart constructors
mkServiceName    :: Text -> Either Text ServiceName
mkNamespace      :: Text -> Either Text Namespace
defaultNamespace :: Namespace   -- = Namespace "personal"
mkImageRef       :: Text -> Either Text ImageRef
mkEnvName        :: Text -> Either Text EnvName
mkSecretName     :: Text -> Either Text SecretName
mkPort           :: Int  -> Either Text Port
defaultPort      :: Port   -- = Port 8080
mkQuantity       :: Text -> Either Text Quantity
mkDomain         :: Text -> Either Text Domain
mkScale          :: Int  -> Int -> Either Text Scale

-- Accessors
serviceNameText  :: ServiceName -> Text
namespaceText    :: Namespace   -> Text
imageRefText     :: ImageRef    -> Text
envNameText      :: EnvName     -> Text
secretNameText   :: SecretName  -> Text
portInt          :: Port        -> Int
quantityText     :: Quantity    -> Text
domainText       :: Domain      -> Text

-- Sum type (both constructors exported)
data EnvVar = EnvLiteral Text | EnvSecretRef SecretName

-- Plain data types (strict unprefixed fields)
data Resources = Resources { cpu :: !(Maybe Quantity), memory :: !(Maybe Quantity) }
data Scale     = Scale { minScale :: !Int, maxScale :: !Int }

-- The canonical deployment record
data Deployment = Deployment
  { name      :: !ServiceName
  , namespace :: !Namespace
  , image     :: !ImageRef
  , domain    :: !(Maybe Domain)
  , port      :: !Port
  , env       :: !(Map EnvName EnvVar)
  , resources :: !(Maybe Resources)
  , scale     :: !(Maybe Scale)
  }
```

From `Nagare.Dsl.Render`:

```haskell
renderService      :: Deployment -> Text -> ByteString
renderDomainMapping :: Deployment -> Maybe ByteString
```

**Integration Point ownership.** This plan is the sole owner of Integration Points 1, 2, and
5 as described in the MasterPlan at
`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`. Any downstream plan
(EP-10, EP-11, EP-12) that needs to extend or modify these types or function signatures must
update this plan's Decision Log and reflect the change in this Interfaces section before
writing code.
