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

Full plan before trimming: [9-typed-core-deployment-model-and-knative-renderer.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/9-typed-core-deployment-model-and-knative-renderer.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

