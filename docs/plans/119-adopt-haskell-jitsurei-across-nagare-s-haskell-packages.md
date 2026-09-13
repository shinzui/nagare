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
- [ ] Milestone 3: migrate the `nagarectl` library and focused tests.
- [ ] Milestone 4: migrate the `nagarectl` and `nagared` entry points without changing their CLI.
- [ ] Milestone 5: migrate `nagare-access`, its executable, and its test suite.
- [ ] Milestone 6: format and enforce the conventions, run whole-repository validation, and
      complete ADR distillation.


## Surprises & Discoveries

- GHC rejects a strictness annotation on a record field of a `newtype`. Those fields are the sole
  syntactic exception to the explicit-bang rule: a newtype constructor is representation-erased,
  while every field of a project-owned `data` record remains explicitly strict.
  Evidence: GHC 9.12.3 reports `A newtype constructor must not have a strictness annotation` for
  `ConfigTimeout`, `PreparedServerOutput`, and analogous wire wrappers when a bang is added.


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


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare's production Haskell is split across three Cabal workspaces. `cli/nagare-dsl/` defines the
typed configuration language and Kubernetes renderers; `cli/nagarectl/` provides the operator CLI
and `nagared` webhook; `cli/nagare-access/` provides forward authentication. The root `flake.nix`
pins GHC 9.12.3. `.github/workflows/ci.yml` treats `nix flake check` as primary CI and separately
builds the access package because it has private source dependencies.

The manifests are `cli/nagare-dsl/nagare-dsl.cabal`, `cli/nagarectl/nagarectl.cabal`, and
`cli/nagare-access/nagare-access.cabal`. All use `GHC2024` and a `common` stanza, but all enable
`PackageImports` globally. Access also lacks baseline `DeriveAnyClass` and `OverloadedLabels`.
The existing `cli/nagare-dsl/src/Nagare/Dsl/Prelude.hs` is used by most DSL and CLI modules. At
plan creation, 20 maintained DSL/CLI modules omit it, no access-specific Prelude exists, five
modules use prepositive `import qualified`, and twelve modules package-qualify
`Data.Generics.Labels`.

Records are similarly inconsistent. `cli/nagare-dsl/src/Nagare/Dsl/Task.hs` has `taskName`;
JSON mirrors in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` use `jd*`, `jt*`, `jj*`, and `jwp*`;
`cli/nagarectl/src/Nagare/Storage/Discover.hs` defines `PVCRow` with `pr*` fields and mixes lenses,
selectors, and record updates; `cli/nagarectl/app/Main.hs` has abbreviated option fields; and
`cli/nagare-access/src/` lacks the `Generic` derivations required for generic-lens and contains lazy
fields such as `AuthenticatedUser.userSubject`. The standard requires strict fields, no
type-derived prefixes, explicit deriving strategies, and label access for project-owned records.

The baseline is green under GHC 9.12.3. Workspace test commands pass 387 DSL tests, the `nagarectl`
suite, and 128 access tests. DSL coverage includes emit/decode round trips, renderer goldens, and
real `Config.hs` loading.

[ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) is relevant because it makes
GHC 9.12 and typed configuration part of packaged `nagarectl`; this plan preserves that boundary.
[MasterPlan 2](../masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md) intended partial
adoption, but no local ADR defines a repository-wide source convention. Implementation creates
`docs/adr/0016-adopt-haskell-jitsurei-for-production-haskell.md`. If `0016` is occupied
concurrently, use the next free four-digit number and update this plan's local link.


## Plan of Work

### Milestone 1: Establish the contract and foundations

Create `docs/adr/0016-adopt-haskell-jitsurei-for-production-haskell.md` in the existing unprofiled
ADR format. Record the canonical standards, project-owned-record boundary, separate Preludes,
pre-1.0 source break, and behavior-preservation rule. Add a concise Haskell section to `CLAUDE.md`
linking the ADR and canonical Mori documents.

Normalize all three Cabal `common` stanzas: retain `GHC2024`; require `DeriveAnyClass`,
`DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings`; retain `MultilineStrings` only
where used; remove global `PackageImports`; and use `generic-lens ^>=2.3` plus `lens ^>=5.3` where
needed. Convert package-qualified label imports to plain imports before removing the extension.
Keep `cli/nagare-dsl/src/Nagare/Dsl/Prelude.hs` for DSL/CLI and add and expose
`cli/nagare-access/src/Nagare/Access/Prelude.hs` for access. Each alone carries
`{-# LANGUAGE PackageImports #-}`, re-exports a small common `as X` surface and `Control.Lens`, and
does not import `Data.Generics.Labels`. Focused compile tests must prove these interfaces.

### Milestone 2: Migrate nagare-dsl and consumers

Migrate every module under `cli/nagare-dsl/src/` and direct test module under
`cli/nagare-dsl/test/`. Import `Nagare.Dsl.Prelude` except from itself, remove redundant imports,
use postpositive `qualified`, add plain `Data.Generics.Labels ()` only where labels are used,
derive `Generic`, make fields strict, and keep explicit deriving strategies.

Remove prefixes that repeat their type. Required examples are `Task.taskName` to `Task.name`,
`JsonDeployment.jdName` to `JsonDeployment.name`, `JsonTask.jtSchedule` to `JsonTask.schedule`,
and `JsonWorkerProbe.jwpFailureThreshold` to `JsonWorkerProbe.failureThreshold`; apply the rule to
all JSON mirrors in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`. Replace selectors and project-owned
updates with `^.`, `.~`, `?~`, or `%~` while preserving construction and constructor patterns.
Keep Aeson keys byte-identical, then migrate consumers under `cli/nagare-dsl/test/fixtures/`,
`cli/nagarectl/test/fixtures/`, and `cluster/examples/*/nagare/`. Acceptance is 387 or more passing
DSL tests, unchanged goldens, and compiling examples.

### Milestone 3: Migrate the nagarectl library

Apply the same rules to `cli/nagarectl/src/**/*.hs` and focused `cli/nagarectl/test/*.hs`. Rename
families such as `pr*` on `PVCRow`, `wdp*` on `WorkerDeployParams`, `dr*` on `DomainRow`, and
`agp*` on access-grant parameters. In `cli/nagarectl/src/Nagare/Platform/Upgrade.hs` and other
serialization modules, preserve explicit JSON keys while moving project-owned access/update to
labels. Leave external records such as `System.Process.CreateProcess` alone. Test after the
access/environment, application/deployment, database/broker, storage/tasks, and
platform/operations slices. Acceptance is the full green CLI suite with unchanged goldens.

### Milestone 4: Migrate the executables

Refactor `cli/nagarectl/app/Main.hs` and `cli/nagarectl/nagared/Main.hs` separately. Rename option
prefixes including `uo*`, `hio*`, `cco*`, `tro*`, `dbr*`, and `cpo*` to actual option names,
relying on `DuplicateRecordFields` and labels. Preserve command names, flags, defaults, environment
names, help, exit codes, and output. Acceptance is an empty before/after diff for
`nagarectl --help` and `nagared --help` plus green builds and tests.

### Milestone 5: Migrate nagare-access

Import `Nagare.Access.Prelude` throughout `cli/nagare-access/src/`,
`cli/nagare-access/app/Main.hs`, and `cli/nagare-access/test/Spec.hs`. Derive `Generic`, make lazy
fields strict, remove type-derived prefixes, and use explicit label imports only in manipulating
modules. Required examples include `RuntimeConfig.runtimeListen` to `listen`,
`SessionHandoff.handoffAccessToken` to `accessToken`, `ReturnTarget.targetHost` to `host`, and
`MfaCompletion.mfaCompletionCeremonyId` to `ceremonyId`. Preserve Aeson keys, cookies, trusted and
stripped headers, redirects, statuses, and bodies. Acceptance is 128 or more passing access tests,
including Shomei/En, portal, proxy, WebSocket, and failure cases.

### Milestone 6: Enforce and validate

Update `cli/fourmolu.yaml` to cover all packages. Run Fourmolu 0.19.0.1 over tracked
`cli/**/*.hs` and Cabal Gild 1.6.0.4 over the manifests in a separate mechanical commit. Add
`scripts/check-haskell-style.sh` and a thin `justfile` recipe `haskell-style-check`. The script
rejects prepositive qualified imports, package imports outside `*/Prelude.hs`, global
`PackageImports`, strategy-less deriving, lazy project-owned fields, and maintained modules without
their package Prelude. Scope import enforcement to `src/`, `app/`, `nagared/`, and direct tests;
exclude generated files and consumer fixtures.

Add a hermetic `haskell-style` check to `flake.nix` running that script, Fourmolu check mode, and
Cabal Gild check mode. Existing CI will pick it up. Add an `Unreleased` entry to `CHANGELOG.md` for
the source migration and unchanged wire/CLI behavior. Run all validation, update living sections,
and distill durable findings into the ADR.


## Concrete Steps

Use the repository root, currently `/Users/shinzui/Keikaku/bokuno/nagare`, unless entering a Cabal
workspace. Confirm the clean baseline and tool versions:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
git status --short
nix develop -c ghc --numeric-version
nix develop -c fourmolu --version
nix develop -c cabal-gild --version
```

Expected version evidence is:

```text
9.12.3
fourmolu 0.19.0.1
cabal-gild version 1.6.0.4
```

Build and test each independent workspace after its milestone:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
nix develop -c cabal build all
nix develop -c cabal test all --test-show-details=direct

cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
nix develop -c cabal build all
nix develop -c cabal test all --test-show-details=direct

cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-access
nix develop -c cabal build all
nix develop -c cabal test nagare-access-test --test-show-details=direct
```

Final output must report each suite as `PASS`. Counts may grow but must not decrease without an
explanation in this plan. Run these audits from the root; final invocations produce no matches:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
rg -n '^import qualified ' cli -g '*.hs'
rg -n 'PackageImports' cli -g '*.cabal'
rg -n '^import "' cli -g '*.hs' | rg -v '/Prelude.hs:'
rg -n '^[[:space:]]*deriving \(' cli -g '*.hs'
```

At the final formatting milestone, format all tracked Haskell and Cab files and prove a second pass
is clean:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
git ls-files -z 'cli/**/*.hs' | xargs -0 nix develop -c fourmolu --mode inplace --config cli/fourmolu.yaml
nix develop -c cabal-gild --io cli/nagare-dsl/nagare-dsl.cabal
nix develop -c cabal-gild --io cli/nagarectl/nagarectl.cabal
nix develop -c cabal-gild --io cli/nagare-access/nagare-access.cabal
git ls-files -z 'cli/**/*.hs' | xargs -0 nix develop -c fourmolu --mode check --config cli/fourmolu.yaml
nix develop -c cabal-gild --mode check --input cli/nagare-dsl/nagare-dsl.cabal
nix develop -c cabal-gild --mode check --input cli/nagarectl/nagarectl.cabal
nix develop -c cabal-gild --mode check --input cli/nagare-access/nagare-access.cabal
```

Before milestone 4, use a temporary directory to capture help. After refactoring, write matching
`*.after` files and compare:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
NAGARE_HELP_TMP="$(mktemp -d)"
nix develop -c cabal run nagarectl -- --help > "$NAGARE_HELP_TMP/nagarectl.before"
nix develop -c cabal run nagared -- --help > "$NAGARE_HELP_TMP/nagared.before"
diff -u "$NAGARE_HELP_TMP/nagarectl.before" "$NAGARE_HELP_TMP/nagarectl.after"
diff -u "$NAGARE_HELP_TMP/nagared.before" "$NAGARE_HELP_TMP/nagared.after"
```

Both diffs exit zero with no output. Finish from the root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
scripts/check-haskell-style.sh
just haskell-style-check
nix flake check --print-build-logs --max-jobs 1
git status --short
```

The two style commands print:

```text
Haskell style checks passed (nagare-dsl, nagarectl, nagare-access).
```

Commit each independently passing milestone with a Conventional Commit subject. Every
implementation commit, including formatting-only commits, ends with:

```text
ExecPlan: docs/plans/119-adopt-haskell-jitsurei-across-nagare-s-haskell-packages.md
Intention: intention_01m2df7a16e6t9hqmvx8qy9d61
```


## Validation and Acceptance

Acceptance requires source conformance and unchanged behavior. The style script, its `just` wrapper,
Fourmolu check mode, and Cabal Gild check mode all return zero. The four `rg` audits above return no
matches. Review remaining project-owned record braces to confirm they are construction or patterns,
not selector/update use; external-library updates are allowed.

All packages build and test under GHC 9.12.3. DSL round-trip tests emit identical JSON keys and all
Kubernetes goldens remain byte-identical. Root `nix flake check --print-build-logs --max-jobs 1`
compiles every shipped `cluster/examples/*/nagare/Config.hs` and runs the hermetic style check. The
separate access command passes authentication, authorization, proxy, portal, cookie, and WebSocket
tests. Help snapshots have empty diffs. Tests for upgrade transactions, release logs, session
handoff, and DSL round trips prove persisted keys did not follow Haskell field renames.

`CHANGELOG.md` describes only the source-level migration as breaking. All added cross-repository
references use canonical `mori://` URIs, the ADR uses a repository-relative link, and this plan's
living sections contain actual validation evidence before completion.


## Idempotence and Recovery

Build, test, audit, and check commands are repeatable apart from ignored caches. Fourmolu and Cabal
Gild must reach a fixed point. Keep each package migration in its own commit and the formatter pass
separate. If a rename fails compilation, update all construction, pattern, selector, and label sites
for that type before moving on; do not recover by re-enabling global `PackageImports`, re-exporting
`Data.Generics.Labels`, or accepting changed goldens.

For an ambiguous label, confirm the record derives `Generic`, import `Data.Generics.Labels ()` in
the manipulating module, and add the smallest useful type annotation. For a changed Aeson result,
restore the explicit key mapping and rerun the focused round trip. If ADR `0016` is occupied,
allocate the next unused filename, update local links, and record the collision under Surprises &
Discoveries.


## Interfaces and Dependencies

`cli/nagare-dsl/src/Nagare/Dsl/Prelude.hs` remains exposed with this shape:

```haskell
{-# LANGUAGE PackageImports #-}

module Nagare.Dsl.Prelude
  ( module X
  , module Control.Lens
  ) where
```

It re-exports the existing small common set via package-qualified `as X` imports and
`"lens" Control.Lens`. It never imports `Data.Generics.Labels`. Create
`cli/nagare-access/src/Nagare/Access/Prelude.hs` with the same shape, exporting at least
`GHC.Generics.Generic`, `Data.Text.Text`, repeatedly used small base helpers, and `Control.Lens`.
The implicit Haskell Prelude remains enabled.

A module manipulating a project record uses:

```haskell
import Data.Generics.Labels ()

readField :: GenericRecord -> Text
readField record = record ^. #field

updateField :: Text -> GenericRecord -> GenericRecord
updateField value record = record & #field .~ value
```

Project records use strict fields and explicit strategies:

```haskell
data GenericRecord = GenericRecord
  { field :: !Text
  , optional :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
```

Construction and constructor-directed patterns are permitted; `field record` and
`record {field = value}` are not. Use `?~` for `Maybe`, `%~` for functional updates, and `at` or
`ix` for keyed containers when clearer.

Direct bounds are `generic-lens ^>=2.3` and `lens ^>=5.3`. Verified released versions are 2.3.0.0
and 5.3.6, both supporting GHC 9.12. No new service or network API is introduced. The only new
repository command is `scripts/check-haskell-style.sh`, exposed as `just haskell-style-check` and a
root flake check.
