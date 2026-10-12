---
id: 10
slug: config-surface-and-loading-for-the-chosen-substrate
title: "Config surface and loading for the chosen substrate"
kind: exec-plan
created_at: 2026-06-03T03:44:07Z
intention: "intention_01kt5s3j2zedh8ew1yp9qdp6c7"
master_plan: "docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md"
---

# Config surface and loading for the chosen substrate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [10-config-surface-and-loading-for-the-chosen-substrate.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/10-config-surface-and-loading-for-the-chosen-substrate.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan is complete, an app author can write a single typed configuration file that
describes their Nagare deployment — the filename and syntax depend on which substrate EP-8's
spike selected — and run one Haskell function, `loadDeployment :: FilePath -> IO (Either
LoadError Deployment)`, to obtain either a fully-validated `Deployment` value (from EP-9's
`Nagare.Dsl.Types`) or a precise, human-readable error that tells the author exactly which
field is wrong and why.

Before this plan, there is no bridge between an on-disk config file and the typed `Deployment`
value that EP-9's renderer consumes. After this plan, that bridge exists: the loader reads the
file, validates every field through EP-9's smart constructors, and returns either a correct
`Deployment` or a `LoadError` whose `renderLoadError` output can be printed directly to a
terminal. EP-12 will call this loader from `nagarectl deploy`; EP-11 will write presets in the
chosen surface language. This plan is the keystone that makes both downstream plans possible.

The concrete thing you can verify after this plan: run `cabal test` inside `cli/nagare-dsl/`
and see the M3 failure-mode test suite pass, proving that a valid hello config file loads to a
`Deployment` equal to EP-9's canonical hello value, and that each class of broken input
produces the specific `LoadError` variant described in this plan.

## Progress

- [x] M0 Determine the chosen substrate from EP-8's Decision Log. _(2026-06-03: Branch B — config-as-program, native eDSL.)_
- [x] M1.1 Add `Nagare.Dsl.Load` (and helper `Nagare.Dsl.Config`) to `exposed-modules`. _(2026-06-03)_
- [x] M1.2 Add deps to `nagare-dsl.cabal` (`directory`, `filepath`, `process`; `temporary` for tests); `write-ghc-environment-files: always` in `cabal.project`. _(2026-06-03; used `process.readProcessWithExitCode`, not `cradle`.)_
- [x] M1.3 Write `Nagare.Dsl.Load` — `LoadError` (FileNotFound/CompileError/MissingBinding/MarshalError), `renderLoadError`, `loadDeployment`, plus a pure exported `decodeDeployment`. _(2026-06-03; implemented in full, not stubbed.)_
- [x] M1.4 `cabal build` succeeds. _(2026-06-03)_
- [x] M1.5 `cabal run nagare-dsl-load-demo` prints `renderLoadError` for each variant. _(2026-06-03)_
- [x] M2.1 Implement the loader (Branch B): compile-and-run `Config.hs` via `runghc`, capture JSON, decode + re-validate. _(2026-06-03)_
- [x] M2.2 Write the hello config surface file `test/fixtures/nagare/Config.hs` (unprefixed fields, `module Main`). _(2026-06-03)_
- [x] M2.3 `cabal test`: `loadDeployment` on the hello fixture returns a `Deployment` equal to EP-9's `helloDep` and renders byte-identically to the golden service YAML. _(2026-06-03)_
- [x] M3.1 Failure-mode suite `test/LoadSpec.hs`. _(2026-06-03)_
- [x] M3.2 `cabal test`: bad name → MarshalError, max<min → MarshalError, syntax error → CompileError, no emit → MissingBinding, missing file → FileNotFound, value+secretRef sum-type. _(2026-06-03)_
- [x] Record branch + surprises in Decision Log / Surprises. _(2026-06-03)_
- [x] Update Outcomes & Retrospective. _(2026-06-03)_

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The plan's Branch B code used EP-9's *old* prefixed field names** (`depName`, `resCpu`,
  `scaleMin`, positional `Deployment ...`). EP-9 shipped **unprefixed** strict fields per the house
  standard, so all marshalling/construction was rewritten to `Deployment { name = ..., namespace =
  ..., image = ..., domain = ..., port = ..., env = ..., resources = ..., scale = ... }`,
  `Resources { cpu = ..., memory = ... }`, and `Scale.minScale/maxScale`. (2026-06-03)
- **The loader's `runghc` resolves `nagare-dsl` via the inherited cabal package environment, not a
  CWD file.** `ls` showed no `.ghc.environment.*` in the package dir, yet a child `runghc` found
  `Nagare.Dsl.Config`/`Types`. The mechanism is that `cabal test`/`cabal run` export the package
  environment (`GHC_PACKAGE_PATH` and/or a generated env file) to child processes, which `runghc`
  inherits. This is why the load tests pass deterministically (56/56). It also pins the EP-12
  caveat: a stand-alone `nagarectl` binary will not have this inherited environment and must
  provision one itself. (2026-06-03)
- **`MarshalError` is not naturally reachable through a well-formed config-as-program file**: the
  app's `Config.hs` already validates via the smart constructors, so by the time it emits JSON the
  values are valid, and a config that crashes on a bad value exits non-zero → `CompileError`. The
  loader's JSON re-validation (`decodeDeployment`) is defence-in-depth; the `MarshalError` path is
  therefore unit-tested directly against `decodeDeployment` with hand-written bad JSON rather than
  through a subprocess. (2026-06-03)
- All deps resolved from Hackage / boot libraries; `process`, `directory`, `filepath` are boot,
  `temporary` from Hackage. No mori-corpus fallback was needed. (2026-06-03)

## Decision Log

- Decision: EP-10 branches on EP-8's recorded substrate decision; the implementer reads EP-8's
  Decision Log in M0, picks the matching branch below, and records which branch was taken in
  this plan's Decision Log before writing any code.
  Rationale: The loader mechanism is entirely determined by the substrate (Dhall vs.
  config-as-program via `runghc`/`cabal run` vs. interpreter). Writing the plan as three
  concrete, separately labelled branches that converge on the same `loadDeployment` signature
  means the plan is self-contained regardless of which substrate EP-8 chose, while ensuring the
  implementer does not need to re-evaluate the substrate decision.
  Date: 2026-06-03

- Decision: The fixed Integration Point 3 signature is
  `loadDeployment :: FilePath -> IO (Either LoadError Deployment)` with no additional
  arguments (no explicit search path, no extra context). If EP-8's decision forces a different
  signature (e.g. a required `[FilePath]` package-database search path for the config-as-program
  branch), update this entry and notify EP-12's author before writing code.
  Rationale: EP-12 must call `loadDeployment` before EP-10 is implemented (to allow parallel
  authoring). The simplest possible signature — one file path, returns Either — covers all three
  substrate branches. The config-as-program branch locates the package database through `cabal`
  invocations rather than accepting it as an argument, keeping the caller interface simple.
  Date: 2026-06-03

- Decision: Branch taken: **Branch B — config-as-program (native Haskell eDSL).**
  Rationale: EP-8's M5 Decision Log records the native Haskell eDSL in the config-as-program model
  as the chosen substrate (the user's pick; it scored 20/25 and is the only substrate delivering
  the binding maximal-type-safety priority — illegal configs fail to compile). The loader therefore
  compiles-and-runs the app's `Config.hs` to obtain the `deployment` value.
  Date: 2026-06-03

- Decision (implementation details for Branch B):
  - **Process spawning** uses `System.Process.readProcessWithExitCode` (a boot library) rather than
    `cradle`'s tuple output — it returns exit code + stdout + stderr in one call, needs no
    `-threaded`, and avoids the tuple-`Output` complexity the plan flagged. No `cradle` dependency
    is added.
  - **GHC invocation** is plain `runghc -XGHC2024 -i<configDir> <path>` (via
    `readProcessWithExitCode`). The config imports the `nagare-dsl` package (`Nagare.Dsl.Config`,
    `Nagare.Dsl.Types`), which a bare `runghc` started cold cannot see (it gets only boot packages —
    an EP-8 spike finding). It works in the test because the spawned `runghc` **inherits the GHC
    package environment** (`GHC_PACKAGE_PATH` / a `.ghc.environment.*` file) that cabal sets up for
    the test process — `write-ghc-environment-files: always` in `cabal.project` materialises that
    environment. `-XGHC2024` gives app configs the house language edition. NOTE for EP-12: this
    inheritance only holds because the loader runs inside the `cli/nagare-dsl/` cabal context;
    provisioning the package environment for `nagarectl` at a user's app site (no cabal project,
    `nagarectl` is a built binary) is EP-12's integration responsibility — it must arrange a GHC
    package environment exposing `nagare-dsl` (e.g. ship a package-env file or invoke through a
    project). The `loadDeployment` signature (Integration Point 3) is unchanged regardless.
  - **Transport** is JSON (aeson). `Nagare.Dsl.Config.emitDeployment :: Deployment -> IO ()`
    serialises a validated `Deployment` to JSON on stdout; the loader decodes it and re-runs EP-9's
    smart constructors (defence in depth) via the pure, exported `decodeDeployment :: ByteString ->
    Either LoadError Deployment`, which also lets the `MarshalError` path be unit-tested without a
    subprocess.
  Date: 2026-06-03

- Decision: EP-10 follows the house Haskell standards (haskell-jitsurei) and the
  GHC 9.12 / GHC2024 toolchain established by EP-8 (flake pin) and EP-9 (`common`
  stanza + `Nagare.Dsl.Prelude`). New surface/loader modules import
  `Nagare.Dsl.Prelude`, use strict unprefixed fields, explicit deriving strategies,
  and generic-lens `#label` access.
  Rationale: consistency with the rest of the `nagare-dsl` package and the
  MasterPlan's Integration Point 6.
  Date: 2026-06-03

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome.** `Nagare.Dsl.Load` now bridges an on-disk config-as-program file to EP-9's typed
`Deployment`. `loadDeployment :: FilePath -> IO (Either LoadError Deployment)` (Integration Point 3)
compiles-and-runs the app's `Config.hs` with `runghc`, captures the JSON it emits via the new
`Nagare.Dsl.Config.emitDeployment` helper, decodes it, and re-runs EP-9's smart constructors,
returning either a fully-validated `Deployment` or a precise `LoadError`
(`FileNotFound`/`CompileError`/`MissingBinding`/`MarshalError`) with a terminal-ready
`renderLoadError`. EP-11 will write presets in this Haskell surface; EP-12 will call this exact
function from `nagarectl deploy`.

**Verification.** `cabal test` runs 56 cases, all green. The keystone proof — `loadDeployment` on
`test/fixtures/nagare/Config.hs` returns a `Deployment` **equal to EP-9's `helloDep`** and renders
byte-identically to the golden Service YAML — wires Integration Point 3 to Integration Points 1 and
2. Every failure mode is exercised: missing file, compile/runtime error, no emit, and bad
name/scale (MarshalError) via the pure `decodeDeployment`.

**Gaps / handoff.** The loader's `runghc` package-environment provisioning works in-test by
inheriting cabal's environment; making it work for a stand-alone `nagarectl` binary at a user's app
site is EP-12's responsibility (documented in the Decision Log and Surprises). The `loadDeployment`
signature is fixed and unchanged, so EP-12 can be authored against it.

