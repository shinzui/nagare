---
id: 119
slug: adopt-haskell-jitsurei-across-nagare-s-haskell-packages
title: "Adopt haskell-jitsurei across Nagare's Haskell packages"
kind: exec-plan
created_at: 2026-09-13T13:33:40Z
intention: "intention_01m2df7a16e6t9hqmvx8qy9d61"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T13:33:40Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-13T13:49:34Z
      mode: "implement"
      note: "Implemented the haskell-jitsurei migration and validation milestones"
---

# Adopt haskell-jitsurei across Nagare's Haskell packages

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [119-adopt-haskell-jitsurei-across-nagare-s-haskell-packages.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/119-adopt-haskell-jitsurei-across-nagare-s-haskell-packages.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this change, Nagare's three maintained Haskell packages use one deliberate house style
instead of a partial mix of old record selectors, type-prefixed fields, record updates, repeated
imports, and package-wide `PackageImports`. Contributors can work in `nagare-dsl`, `nagarectl`,
and `nagare-access` using the current conventions published at
`mori://shinzui/haskell-jitsurei/docs/core-standards`,
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and
`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`. A custom Prelude is a small project
module that re-exports common names; it does not replace Haskell's implicit `base` Prelude.

The refactor must not change deployment JSON, rendered Kubernetes YAML, command names or help,
platform-upgrade transaction JSON, access-service HTTP behavior, cookies, headers, or error text.
The observable result is that package tests and goldens still pass, shipped configuration examples
still compile, `nix flake check` succeeds, and a new style check prevents the same drift.

## Progress

- [x] (2026-09-13T13:51:26Z) Milestone 1: recorded ADR 16, normalized Cabal defaults and
      dependency bounds, scoped `PackageImports` to Prelude modules, added
      `Nagare.Access.Prelude`, and compiled all three workspaces successfully.
- [x] (2026-09-13T14:12:45Z) Milestone 2: migrated `nagare-dsl`, its direct tests,
      fixtures, CLI consumers, and shipped examples to semantic fields and label-based access;
      all 387 DSL tests pass, the dependent `nagarectl` workspace builds, and the hermetic
      `examples-compile` check accepts every shipped configuration.
- [x] (2026-09-13T15:28:29Z) Milestone 3: migrated the `nagarectl` library and focused tests;
      the library and direct test suite compile with `NoFieldSelectors`, all 438 tests pass,
      and both executables compile against the renamed library surface.
- [x] (2026-09-13T15:46:28Z) Milestone 4: migrated the `nagarectl` and `nagared`
      entry points; both compile with `NoFieldSelectors`, both help texts are byte-identical to
      their pre-migration captures, and all 438 `nagarectl` tests pass.
- [x] (2026-09-13T16:04:38Z) Milestone 5: migrated `nagare-access`, its executable,
      and its test suite; every component compiles with `NoFieldSelectors`, and all 128 access
      tests pass with the HTTP, cookie, header, redirect, proxy, Shomei, and En behavior intact.
- [x] (2026-09-13T16:35:28Z) Milestone 6: formatted all maintained packages, added declarative
      ast-grep and Cabal policy enforcement, completed ADR and contributor guidance, and passed
      the root `nix flake check --print-build-logs --max-jobs 1` validation gate.

## Surprises & Discoveries

- GHC rejects a strictness annotation on a record field of a `newtype`. Those fields are the sole
  syntactic exception to the explicit-bang rule: a newtype constructor is representation-erased,
  while every field of a project-owned `data` record remains explicitly strict.
  Evidence: GHC 9.12.3 reports `A newtype constructor must not have a strictness annotation` for
  `ConfigTimeout`, `PreparedServerOutput`, and analogous wire wrappers when a bang is added.

- Cabal's ignored `.ghc.environment.*` files can retain package IDs from an older package database
  even after the library and tests rebuild. Regenerating both workspace files turned apparent
  fixture-loader failures into a useful source-level check, which then found one
  `Task.app`/fixture-value namespace collision; renaming the fixture value restored all 438 tests.
  The `nagarectl` suite must be run with its materialized environment explicitly selected because
  Cabal's isolated test environment is temporary while fixture `runghc` processes are children of
  the test executable.

- The final hermetic run found that `checks.vm-shape-defaults-agree` encoded the old `VmShape`
  selector prefixes in its source-text extraction patterns. Direct GHC tests could not expose this
  because it is a Nix-level cross-language consistency check. Updating its four patterns to the new
  semantic field names restored the check without changing the compared values.

## Decision Log

- Decision: Apply this plan to maintained Cabal components under `cli/nagare-dsl/`,
  `cli/nagarectl/`, and `cli/nagare-access/`. Update consumer fixtures and
  `cluster/examples/*/nagare/*.hs` when public DSL fields change, but exclude the historical
  `docs/spikes/ep8-substrate-spike/` and completed-plan prose.
  Rationale: The three packages are the production Haskell surface. The spike is historical;
  examples and fixtures are live compatibility tests.
  Date: 2026-09-13

- Decision: Follow current `haskell-jitsurei` documents rather than older examples in completed
  Nagare plans. Enable `PackageImports` only in Prelude modules and use plain
  `import Data.Generics.Labels ()` where `#label` is used.
  Rationale: The label module supplies an orphan `IsLabel` instance. Keeping it out of Preludes and
  definition-only modules limits transitive leakage. The upstream standard has no tags; Mori's
  source and upstream `HEAD` both resolve to
  `fb6574d971da2bc3ae52bce279828577895ca5f6` and the selected documents are current.
  Date: 2026-09-13

- Decision: Keep `Nagare.Dsl.Prelude` for `nagare-dsl` and `nagarectl`; add a separate
  `Nagare.Access.Prelude` for `nagare-access`.
  Rationale: The CLI already depends on the DSL. Coupling the independently packaged access
  service to deployment types merely for imports would be wrong. Neither Prelude re-exports
  `Data.Generics.Labels`.
  Date: 2026-09-13

- Decision: Apply record rules only to project-owned records. Construction and constructor-directed
  record patterns, including field puns, remain valid. Selector-function application and record
  updates on project-owned records become `#label` lens operations. Third-party record updates may
  remain, and this work does not enable `RecordWildCards`.
  Rationale: This is the exact boundary in the current record-pattern document and avoids wrapping
  external APIs merely for style.
  Date: 2026-09-13

- Decision: Rename type-derived and abbreviated field prefixes, including exposed pre-1.0 DSL
  fields, while preserving serialized keys and behavior. Migrate every tracked consumer and add an
  `Unreleased` changelog entry.
  Rationale: Names such as `taskName`, `jdName`, `prVolume`, `wdpConfigPath`, and
  `handoffAccessToken` repeat their enclosing type; `DuplicateRecordFields` and `#label` make those
  prefixes unnecessary. Semantic compound names such as `baseDomain`, `cookieDomain`, and
  `failureThreshold` remain. Nagare 0.1.0 is the appropriate time for this source cleanup.
  Date: 2026-09-13

- Decision: Standardize direct bounds on `generic-lens ^>=2.3` and `lens ^>=5.3`.
  Rationale: Mori locates them at `mori://ekmett/lens/packages/generic-lens` and
  `mori://ekmett/lens/packages/lens`. Hackage and upstream tags checked on 2026-09-13 show released
  versions 2.3.0.0 and 5.3.6, both supporting GHC 9.12. The local lens corpus has an unreleased 5.4
  description, so it is not used. `nagarectl` currently resolves generic-lens 2.2.2.0 because its
  `^>=2.2` bound excludes 2.3.
  Date: 2026-09-13

- Decision: Override `generic-lens` and `generic-lens-core` to 2.3.0.0 in the root Nix Haskell
  package set.
  Rationale: The pinned nixpkgs revision provides 2.2.2, which cannot satisfy the standardized
  direct bound. Hackage metadata and the source located through
  `mori://ekmett/lens/packages/generic-lens` and
  `mori://ekmett/lens/packages/generic-lens-core` confirm that the released 2.3.0.0 packages are a
  matched pair and support the repository's GHC 9.12 toolchain. The hermetic examples check builds
  both overrides before compiling every shipped configuration.
  Date: 2026-09-13

- Decision: Use local GHC builds, `NoFieldSelectors` compile audits, and focused/full Cabal tests
  while migrating the remaining Haskell components; run the expensive hermetic Nix build once
  after the Haskell migration and mechanical formatting are complete.
  Rationale: The Nix package derivations also rebuild profiling objects and Haddocks. Running them
  between milestones repeats work that subsequent source edits invalidate without finding more
  Haskell type errors than the local compiler gates.
  Date: 2026-09-13

- Decision: Express Haskell syntax enforcement as declarative ast-grep rules and retain
  `scripts/check-haskell-style.sh` only as a thin scope-and-Cabal-policy entry point.
  Rationale: The installed ast-grep Haskell parser represents strict record types as
  `strict_field` nodes beneath `data_type`, so it precisely exempts `newtype` while rejecting lazy
  `data` fields. It also distinguishes code from comments for imports and overloaded labels. Cabal
  files are outside that parser, so the wrapper still owns their component-level check.
  Date: 2026-09-13

## Outcomes & Retrospective

Nagare's three maintained Haskell packages now follow the repository's adopted
`haskell-jitsurei` contract. Project-owned `data` records use semantic field names and explicit
strictness bangs, while representation-erased `newtype` fields remain the sole compiler-required
exception. Record reads and updates use generic-lens labels with explicit
`Data.Generics.Labels ()` imports, derivations state their strategies, and package-qualified imports
are confined to the two package Prelude modules. Existing serialized keys, Kubernetes goldens,
help output, CLI behavior, and access-service protocol behavior were preserved.

Validation completed with 387 DSL tests, 438 `nagarectl` tests, and 128 access tests passing under
GHC 9.12.3. Direct `NoFieldSelectors` audits compiled every maintained component. The final root
`nix flake check --print-build-logs --max-jobs 1` passed all 16 checks compatible with the native
`aarch64-darwin` system, including the new hermetic `haskell-style` check, shipped-example
compilation, `nagarectl-build-test`, and the corrected VM-shape consistency assertion.

The most valuable enforcement choice was replacing ad hoc Haskell text inspection with ast-grep's
syntax-aware rules. A focused rule test proves that lazy `data` fields fail while unbanged
`newtype` fields pass, preventing the strictness rule from regressing or being over-applied. The
single final Nix validation also justified its placement: it found one stale cross-language source
assertion that the faster direct GHC loop could not observe, after the Haskell migration itself was
already stable.

