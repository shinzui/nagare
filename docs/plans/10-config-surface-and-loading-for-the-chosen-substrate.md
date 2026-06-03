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

- [ ] Determine the chosen substrate: read EP-8's Decision Log (step described in Concrete Steps M0).
- [ ] M1.1 Add `Nagare.Dsl.Load` to the exposed-modules list in `cli/nagare-dsl/nagare-dsl.cabal`.
- [ ] M1.2 Add substrate-specific dependencies to `nagare-dsl.cabal` (see branch instructions).
- [ ] M1.3 Write stub `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` with the `LoadError` type, `renderLoadError`, and a stub `loadDeployment` returning a fixed `Left`.
- [ ] M1.4 `cabal build` from `cli/nagare-dsl/` succeeds.
- [ ] M1.5 Run the stub harness: `cabal run nagare-dsl-load-demo -- /nonexistent` prints `renderLoadError` output for each variant.
- [ ] M2.1 Implement the loader body following the branch matching EP-8's decision.
- [ ] M2.2 Write the hello config surface file (the worked example) in the chosen substrate.
- [ ] M2.3 `cabal test` passes: the golden load test confirms the hello config loads to the canonical hello `Deployment` and renders byte-identically to EP-9's golden service YAML.
- [ ] M3.1 Write the failure-mode test suite (`test/LoadSpec.hs` or extend `test/Spec.hs`).
- [ ] M3.2 `cabal test` passes all failure-mode tests: bad name, value+secretRef, max<min, missing field, syntax error each yield the expected `LoadError`.
- [ ] Record the branch taken and any surprises in the Decision Log and Surprises sections.
- [ ] Update Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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

- Decision: Branch taken: (record here during M0 which branch was followed)
  Rationale: (record here after reading EP-8's Decision Log)
  Date: (fill in during implementation)

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

(To be filled during and after implementation.)


## Context and Orientation

Read this section fully before touching any code. It defines every term used in this plan.

**What Nagare is.** Nagare is a personal Platform-as-a-Service: one GCP virtual machine running
k3s (a lightweight Kubernetes distribution) with Knative Serving installed. Knative Serving
turns a container image into an auto-scaling web service called a *Knative Service*. Today an
app is described by `nagare.yaml`; the initiative this plan belongs to (`docs/masterplans/2-...`)
replaces that YAML with a typed configuration surface. This plan (EP-10) builds the piece that
turns the typed config file into the Haskell `Deployment` value EP-9 defined.

**Hard dependencies.** This plan hard-depends on:

- **EP-8** (`docs/plans/8-config-substrate-evaluation-spike-and-decision.md`) — the spike that
  ran three prototypes and recorded a substrate decision. EP-10 implements whichever substrate
  EP-8 chose. The implementer *must* read EP-8's Decision Log before writing code.
- **EP-9** (`docs/plans/9-typed-core-deployment-model-and-knative-renderer.md`) — the library
  that defines `Nagare.Dsl.Types.Deployment` and all smart constructors. EP-10 marshals into
  these types; the `cli/nagare-dsl/` package and its `cabal.project` already exist from EP-9.

**What this plan builds.** A single new module `Nagare.Dsl.Load` added to the existing
`cli/nagare-dsl/` library (the same package EP-9 created). The module exports:

```haskell
module Nagare.Dsl.Load
  ( LoadError(..)
  , renderLoadError
  , loadDeployment
  ) where

-- | All the ways loading a config file can fail.
data LoadError
  = FileNotFound FilePath
  | ...  -- substrate-specific variants; see each branch below

renderLoadError :: LoadError -> Text

loadDeployment :: FilePath -> IO (Either LoadError Deployment)
```

The `loadDeployment` function is Integration Point 3 of the parent MasterPlan: EP-12 will call
it from `nagarectl deploy`. The signature is fixed here so EP-12 can be authored against it
before this plan is implemented.

**The three possible substrates and which branch to follow.** EP-8 evaluated three candidates:

1. *Config-as-program* — the app ships a Haskell source file (`nagare/Config.hs` or similar)
   that binds `deployment :: Deployment`. The loader shells out to `runghc` or `cabal run` to
   compile and execute it, capturing the serialized result on stdout.

2. *Interpreter (hint or GHC API)* — same Haskell source file, evaluated at runtime through an
   embedded interpreter. EP-8 measured feasibility; if it found this impractical (no `hint` in
   the local mori corpus, and the raw GHC API cannot cleanly extract a runtime value without
   effectively re-implementing option 1), this branch was scored low or marked infeasible.

3. *Dhall* — the app ships a `nagare.dhall` file. The loader uses `Dhall.inputFile` with a
   manually written decoder to unmarshal the Dhall value into an intermediate Haskell record,
   then runs each field through EP-9's smart constructors.

**File layout after this plan.** The only files added or modified are inside `cli/nagare-dsl/`:

```text
cli/nagare-dsl/
  nagare-dsl.cabal          -- add Nagare.Dsl.Load + branch dependencies
  src/
    Nagare/
      Dsl/
        Types.hs            -- unchanged (EP-9)
        Render.hs           -- unchanged (EP-9)
        Load.hs             -- NEW: LoadError, renderLoadError, loadDeployment
  test/
    Spec.hs                 -- extend with load tests
    LoadSpec.hs             -- NEW: failure-mode test suite (or merged into Spec.hs)
    golden/
      hello.nagare.yaml     -- input: the existing hello example (EP-9)
      hello.service.yaml    -- golden renderer output (EP-9)
      hello.domainmapping.yaml
      hello.load.yaml       -- NEW: the surface config file the loader reads
                            --   (nagare.dhall, Config.hs, or similar per branch)
```

**The "hello" canonical example.** Throughout this plan, the canonical test deployment is the
hello app from `cluster/examples/hello-knative-service/nagare.yaml`:

- name: `hello`, namespace: `personal`
- image: `gcr.io/knative-samples/helloworld-go` (no tag)
- domain: `hello.example.com`, port: `8080`
- env: one entry, `TARGET = "Nagare"` (literal)
- resources: cpu `250m`, memory `128Mi`
- scale: min `0`, max `3`

EP-9 constructs this as the `helloDep` value in its golden tests. The goal of M2's load test
is to confirm that `loadDeployment` on the hello config surface file returns a `Deployment`
equal to EP-9's `helloDep` value — and that feeding that `Deployment` to `renderService`
produces the golden service YAML byte-for-byte.

**Toolchain.** All `cabal` commands run from inside `nix develop` at the repository root. The
nix shell provides GHC 9.12 (pinned via the repository flake) and cabal-install.

> **Haskell standards (binding; see MasterPlan Integration Point 6).** This package is built with **GHC 9.12** pinned through the repository Nix flake and follows the house standards in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`. Every Cabal stanza uses `default-language: GHC2024` and `import: common`, where the `common` stanza enables `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` (and `MultilineStrings` where useful). Modules import the shared `Nagare.Dsl.Prelude` (EP-9) instead of repeating common imports; record types use strict (`!`) unprefixed fields with explicit `deriving stock`/`deriving newtype`/`deriving anyclass` strategies; field access/update uses generic-lens `#label` with lens operators; qualified imports are postpositive. Formatting is `fourmolu` + `cabal-gild` via `treefmt`.

**Key library sources (read before guessing at APIs).**

- `Dhall` (corpus): `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall/src/Dhall.hs`
  — `inputFile :: Decoder a -> FilePath -> IO a`, throwing `SomeException` on failure.
  `Dhall.hs` handles `DetailedTypeError` and `Imported (TypeError ...)` via `Control.Exception`.
  The caller wraps `inputFile` in `try @SomeException` to catch parse/type/marshal failures.
- `Dhall.Marshal.Decode` (corpus): `.../dhall/src/Dhall/Marshal/Decode.hs`
  — manual combinators: `record :: RecordDecoder a -> Decoder a`,
  `field :: Text -> Decoder a -> RecordDecoder a`,
  `union :: UnionDecoder a -> Decoder a`,
  `constructor :: Text -> Decoder a -> UnionDecoder a`,
  `strictText :: Decoder Text`,
  `natural :: Decoder Natural`,
  `maybe :: Decoder a -> Decoder (Maybe a)`.
  Derived via `DeriveAnyClass` + `DeriveGeneric` from `Dhall.FromDhall`.
- `Cradle` (corpus): `/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle/src/Cradle.hs`
  — `run :: (Output output, MonadIO m) => ProcessConfiguration -> m output`,
  `run_ :: MonadIO m => ProcessConfiguration -> m ()`,
  `cmd :: String -> ProcessConfiguration`,
  `addArgs :: ConvertibleStrings s String => [s] -> ProcessConfiguration -> ProcessConfiguration`,
  `setWorkingDir :: FilePath -> ProcessConfiguration -> ProcessConfiguration`,
  `StdoutRaw(..)` (`fromStdoutRaw :: ByteString`),
  `StdoutTrimmed(..)` (`fromStdoutTrimmed :: Text`),
  `StderrRaw(..)` (`fromStderr :: ByteString`),
  `ExitCode(..)`.


## Plan of Work

The work proceeds in three milestones. M0 is a mandatory first step (not a coding milestone)
that reads EP-8's decision and locks in which branch to follow. M1 scaffolds the module and
proves the build. M2 implements the loader for the chosen branch. M3 proves every failure mode.

**M0 — Determine the chosen substrate (mandatory first step, not a coding task).** Open
`docs/plans/8-config-substrate-evaluation-spike-and-decision.md`, find the Decision Log entry
for M5 (the substrate decision entry), and note which substrate won. Record the branch name in
this plan's Decision Log (update the "Branch taken" entry seeded above). Then proceed to M1,
following only the sub-section that matches the recorded substrate in each milestone.

**Milestone M1 — Module scaffold, `LoadError` type, and stub `loadDeployment`.** At the end of
M1, the `Nagare.Dsl.Load` module exists in `cli/nagare-dsl/`, exports `LoadError`, `renderLoadError`,
and a stub `loadDeployment` that returns `Left (FileNotFound path)` unconditionally, and `cabal
build` succeeds. A tiny executable (`nagare-dsl-load-demo`) calls `renderLoadError` on one
instance of each `LoadError` variant and prints the results, proving the error rendering is
wired up before any real loading logic exists.

**Milestone M2 — Implement the loader; golden load test passes.** At the end of M2, `loadDeployment`
is fully implemented for the chosen substrate. A new golden test constructs the hello
deployment through `loadDeployment` (reading the hello surface config file from
`test/fixtures/`), passes the resulting `Deployment` to `renderService`, and diffs the output
byte-for-byte against EP-9's `test/golden/hello.service.yaml`. Passing this test proves the
loaded value is *identical* to EP-9's canonical hello value — not just similar but the exact
same fields, which is the correct integration-point proof.

**Milestone M3 — Failure-mode test suite.** At the end of M3, a tasty test suite (`LoadSpec`)
exercises every `LoadError` variant with a deliberately broken config file (or an invalid
field value in the valid-file path) and asserts both the variant identity and that
`renderLoadError` produces a message containing the expected diagnostic fragment. No
`Deployment` is returned for any failure input. `cabal test` passes all tests.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` inside
`nix develop` unless stated otherwise.


### M0 — Determine the chosen substrate

```bash
# Open EP-8's Decision Log:
# docs/plans/8-config-substrate-evaluation-spike-and-decision.md
# Find the M5 Decision Log entry. It will say one of:
#   "substrate: Dhall"
#   "substrate: config-as-program (native eDSL, runghc/cabal)"
#   "substrate: interpreter (hint / GHC API)"
# Record that choice in this plan's Decision Log ("Branch taken" entry) before proceeding.
```

After reading: update this plan's Decision Log "Branch taken" entry with the substrate name and
a one-sentence rationale citing the score from EP-8's table. Do this before any code changes.


### M1 — LoadError type and stub module

**M1.1 — Add `Nagare.Dsl.Load` to the cabal file.** Open
`cli/nagare-dsl/nagare-dsl.cabal`. In the `library` stanza, add `Nagare.Dsl.Load` to
`exposed-modules`:

```cabal
    exposed-modules:
        Nagare.Dsl.Types
        Nagare.Dsl.Render
        Nagare.Dsl.Load
```

**M1.2 — Add substrate-specific dependencies.** Still in `nagare-dsl.cabal`, add the
dependencies that the chosen branch requires.

*Branch A (Dhall):* Add to the `library` stanza's `build-depends`:

```cabal
      , dhall
      , exceptions
```

The `dhall` package lives in the local mori corpus at
`/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall`.
Add it to `cli/nagare-dsl/cabal.project` as a local package path:

```cabal
packages:
  .
  /Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall
```

The `exceptions` package (from Hackage) provides `MonadCatch`/`try` that works with
`SomeException`. If `Control.Exception.try` from `base` is sufficient (it is for pure IO),
the `exceptions` package is optional — use `Control.Exception.try @SomeException` directly.

*Branch B (config-as-program):* Add to the `library` stanza's `build-depends`:

```cabal
      , cradle
      , process
      , temporary
      , aeson
      , directory
      , filepath
```

The `cradle` package lives at
`/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle`.
Add it to `cli/nagare-dsl/cabal.project`:

```cabal
packages:
  .
  /Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle
```

`temporary` (Hackage) provides `withSystemTempDirectory`. `process` is a boot library;
`directory` and `filepath` are boot libraries.

*Branch C (interpreter):* This branch is not taken if EP-8 marked it infeasible. If EP-8
found a working interpreter path, follow the specific instructions EP-8's Decision Log
records. Otherwise, skip to Branch A or B as directed. The remainder of this plan does not
provide a separate Branch C walkthrough because the MasterPlan Surprises section notes that
`hint` is absent from the corpus and the raw GHC API cannot cleanly extract a runtime value
without effectively replicating Branch B's subprocess approach. If EP-8 found an interpreter
path feasible, adapt Branch B's structure (replace `runghc` with the interpreter call) and
record the delta in this plan's Decision Log.

**M1.3 — Write the stub `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`.** The `LoadError` type is
written in full now (not a stub), because the failure-mode tests in M3 depend on it and the
test suite must compile. Only `loadDeployment` is stubbed.

The `LoadError` enumeration differs by branch. Write the one that matches EP-8's decision;
delete the unused branches from this file.

*Branch A — Dhall `LoadError`:*

```haskell
module Nagare.Dsl.Load
  ( LoadError (..)
  , renderLoadError
  , loadDeployment
  ) where

import Control.Exception (SomeException, try)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types

-- | All the ways loading a Dhall config file can fail.
--
-- 'FileNotFound': the path does not exist or cannot be opened.
-- 'DhallError': Dhall parse, type-check, or import error — carries the
--   underlying diagnostic string from the Dhall library. Shows the file path
--   and the full Dhall error message so the author can fix their config.
-- 'MarshalError': the Dhall expression parsed and type-checked but a field
--   value failed EP-9's smart constructor (e.g. a service name with capitals).
--   Carries the field name and the 'Left' message from the smart constructor.
data LoadError
  = FileNotFound !FilePath
  | DhallError !FilePath !Text
  | MarshalError !Text !Text
  deriving stock (Generic, Eq, Show)

-- | Render a 'LoadError' as a single human-readable 'Text' suitable for
-- printing to a terminal.
--
-- Examples:
--   FileNotFound "/app/nagare.dhall"
--     → "nagare: config file not found: /app/nagare.dhall"
--   DhallError "/app/nagare.dhall" "Error: Missing field `name`\n..."
--     → "nagare: Dhall error in /app/nagare.dhall:\n  Error: Missing field `name`\n..."
--   MarshalError "serviceName" "service name contains invalid characters: Hello_World"
--     → "nagare: field 'serviceName' failed validation: service name contains invalid characters: Hello_World"
renderLoadError :: LoadError -> Text
renderLoadError (FileNotFound path) =
  "nagare: config file not found: " <> Text.pack path
renderLoadError (DhallError path msg) =
  "nagare: Dhall error in " <> Text.pack path <> ":\n  " <> msg
renderLoadError (MarshalError field msg) =
  "nagare: field '" <> field <> "' failed validation: " <> msg

-- | Load a 'Deployment' from a Dhall config file.
-- Stub: always returns 'Left (FileNotFound path)' until M2.
loadDeployment :: FilePath -> IO (Either LoadError Deployment)
loadDeployment path = pure (Left (FileNotFound path))
```

*Branch B — config-as-program `LoadError`:*

```haskell
module Nagare.Dsl.Load
  ( LoadError (..)
  , renderLoadError
  , loadDeployment
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types

-- | All the ways loading a config-as-program file can fail.
--
-- 'FileNotFound': the config source file does not exist.
-- 'CompileError': the config source file failed to compile with runghc/cabal.
--   Carries the GHC diagnostic output (stderr) so the author can read the
--   type/parse error.
-- 'MissingBinding': the config compiled successfully but stdout was empty or
--   did not contain a parseable serialized Deployment — the config file did not
--   produce a valid `deployment` binding.
-- 'MarshalError': the serialized output parsed but a field value failed
--   EP-9's smart constructor validation.
data LoadError
  = FileNotFound !FilePath
  | CompileError !FilePath !Text
  | MissingBinding !FilePath
  | MarshalError !Text !Text
  deriving stock (Generic, Eq, Show)

-- | Render a 'LoadError' as a human-readable 'Text' for terminal output.
--
-- Examples:
--   FileNotFound "/app/nagare/Config.hs"
--     → "nagare: config file not found: /app/nagare/Config.hs"
--   CompileError "/app/nagare/Config.hs" "Config.hs:5:1: error: ..."
--     → "nagare: compile error in /app/nagare/Config.hs:\n  Config.hs:5:1: error: ..."
--   MissingBinding "/app/nagare/Config.hs"
--     → "nagare: /app/nagare/Config.hs compiled but did not produce a 'deployment' value"
--   MarshalError "port" "port must be >= 1, got: 0"
--     → "nagare: field 'port' failed validation: port must be >= 1, got: 0"
renderLoadError :: LoadError -> Text
renderLoadError (FileNotFound path) =
  "nagare: config file not found: " <> Text.pack path
renderLoadError (CompileError path msg) =
  "nagare: compile error in " <> Text.pack path <> ":\n  " <> msg
renderLoadError (MissingBinding path) =
  "nagare: " <> Text.pack path <> " compiled but did not produce a 'deployment' value"
renderLoadError (MarshalError field msg) =
  "nagare: field '" <> field <> "' failed validation: " <> msg

-- | Load a 'Deployment' from a Haskell config-as-program source file.
-- Stub: always returns 'Left (FileNotFound path)' until M2.
loadDeployment :: FilePath -> IO (Either LoadError Deployment)
loadDeployment path = pure (Left (FileNotFound path))
```

**M1.4 — Add a tiny demo executable to `nagare-dsl.cabal`.** This executable prints
`renderLoadError` of each `LoadError` variant, proving the module builds and renders correctly
before the real loader exists. Add a stanza to `nagare-dsl.cabal`:

```cabal
executable nagare-dsl-load-demo
    import:           warnings
    main-is:          LoadDemo.hs
    hs-source-dirs:   demo
    build-depends:
        base
      , nagare-dsl
      , text
    default-language: GHC2024
```

Create `cli/nagare-dsl/demo/` and write `cli/nagare-dsl/demo/LoadDemo.hs`:

*Branch A version:*

```haskell
module Main (main) where

import qualified Data.Text.IO as TIO
import Nagare.Dsl.Load

main :: IO ()
main = do
  TIO.putStrLn (renderLoadError (FileNotFound "/app/nagare.dhall"))
  TIO.putStrLn (renderLoadError (DhallError "/app/nagare.dhall" "Error: Missing field `name`"))
  TIO.putStrLn (renderLoadError (MarshalError "serviceName" "service name contains invalid characters: Hello_World"))
```

*Branch B version:*

```haskell
module Main (main) where

import qualified Data.Text.IO as TIO
import Nagare.Dsl.Load

main :: IO ()
main = do
  TIO.putStrLn (renderLoadError (FileNotFound "/app/nagare/Config.hs"))
  TIO.putStrLn (renderLoadError (CompileError "/app/nagare/Config.hs" "Config.hs:5:1: error: parse error"))
  TIO.putStrLn (renderLoadError (MissingBinding "/app/nagare/Config.hs"))
  TIO.putStrLn (renderLoadError (MarshalError "port" "port must be >= 1, got: 0"))
```

**M1.5 — Build and run the demo.** From `cli/nagare-dsl/`:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build
cabal run nagare-dsl-load-demo
```

Expected (Branch A):

```text
nagare: config file not found: /app/nagare.dhall
nagare: Dhall error in /app/nagare.dhall:
  Error: Missing field `name`
nagare: field 'serviceName' failed validation: service name contains invalid characters: Hello_World
```

Expected (Branch B):

```text
nagare: config file not found: /app/nagare/Config.hs
nagare: compile error in /app/nagare/Config.hs:
  Config.hs:5:1: error: parse error
nagare: /app/nagare/Config.hs compiled but did not produce a 'deployment' value
nagare: field 'port' failed validation: port must be >= 1, got: 0
```

If `cabal build` fails, check that the module is listed in `exposed-modules`, the
substrate-specific dependencies are in `build-depends`, and (for Dhall) the corpus path is
added to `cabal.project`.

---

### M2 — Implement the loader and write the hello surface config file

This section is divided by branch. Follow only the sub-section whose heading matches the
substrate recorded in M0. After implementing your branch, proceed to M2's validation step.

---

#### Branch A — Dhall loader

**M2-A.1 — Write the hello surface config file.** Create
`cli/nagare-dsl/test/fixtures/hello.dhall`. This is the on-disk file an app author would
ship in their repository. It expresses the hello deployment (from
`cluster/examples/hello-knative-service/nagare.yaml`) in Dhall syntax:

```dhall
-- nagare.dhall
-- Deployment descriptor for the "hello" app.
-- Load with: nagarectl deploy --config nagare.dhall
{ name      = "hello"
, namespace = "personal"
, image     = "gcr.io/knative-samples/helloworld-go"
, domain    = Some "hello.example.com"
, port      = 8080
, env       =
    [ { varName = "TARGET"
      , value   = < Literal : Text | SecretRef : Text >.Literal "Nagare"
      }
    ]
, cpuRequest    = Some "250m"
, memoryRequest = Some "128Mi"
, scaleMin      = Some 0
, scaleMax      = Some 3
}
```

The Dhall record uses `Natural` for `port`, `scaleMin`, `scaleMax` (Dhall's `Natural` maps to
Haskell's `Natural` or `Integer` via `FromDhall`). The `domain`, `cpuRequest`, `memoryRequest`,
`scaleMin`, `scaleMax` fields use `Optional Text` / `Optional Natural` (the `Some`/`None`
syntax). The `env` field is a `List` of records with a union field for the env var kind.

The union type `< Literal : Text | SecretRef : Text >` corresponds to Haskell's `EnvKind`
defined in the decoder below.

**M2-A.2 — Implement `Nagare.Dsl.Load` (Dhall branch).** Replace the stub body of
`loadDeployment` with the full implementation. Replace the entire `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`
with:

```haskell
module Nagare.Dsl.Load
  ( LoadError (..)
  , renderLoadError
  , loadDeployment
  ) where

import Control.Exception (SomeException, try)
import Control.Exception qualified as E
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
import Numeric.Natural (Natural)
import System.IO.Error (isDoesNotExistError)

-- ---------------------------------------------------------------------------
-- LoadError

data LoadError
  = FileNotFound !FilePath
  | DhallError !FilePath !Text
  | MarshalError !Text !Text
  deriving stock (Generic, Eq, Show)

renderLoadError :: LoadError -> Text
renderLoadError (FileNotFound path) =
  "nagare: config file not found: " <> Text.pack path
renderLoadError (DhallError path msg) =
  "nagare: Dhall error in " <> Text.pack path <> ":\n  " <> msg
renderLoadError (MarshalError field msg) =
  "nagare: field '" <> field <> "' failed validation: " <> msg

-- ---------------------------------------------------------------------------
-- Dhall intermediate types
--
-- These mirror the structure of the Dhall expression in nagare.dhall.
-- They are local to this module and not exported; the caller always
-- sees the validated Deployment from Nagare.Dsl.Types.

-- | Dhall union for env var kind (maps to EnvVar in Nagare.Dsl.Types).
data EnvKind
  = Literal !Text
  | SecretRef !Text
  deriving stock (Generic, Eq, Show)

-- | Manual Dhall decoder for EnvKind.
-- Generic derivation would work if constructor names match exactly;
-- the manual form is more robust across Dhall versions.
envKindDecoder :: Dhall.Decoder EnvKind
envKindDecoder = Dhall.union
  (   (Literal   <$> Dhall.constructor "Literal"   Dhall.strictText)
  <>  (SecretRef <$> Dhall.constructor "SecretRef" Dhall.strictText)
  )

-- | One env entry as encoded in the Dhall expression.
data DhallEnvEntry = DhallEnvEntry
  { entryVarName :: !Text
  , entryValue :: !EnvKind
  }
  deriving stock (Generic, Eq, Show)

dhallEnvEntryDecoder :: Dhall.Decoder DhallEnvEntry
dhallEnvEntryDecoder = Dhall.record $
  DhallEnvEntry
    <$> Dhall.field "varName" Dhall.strictText
    <*> Dhall.field "value"   envKindDecoder

-- | Top-level Dhall record shape.
data DhallDeployment = DhallDeployment
  { ddName :: !Text
  , ddNamespace :: !Text
  , ddImage :: !Text
  , ddDomain :: !(Maybe Text)
  , ddPort :: !Natural
  , ddEnv :: ![DhallEnvEntry]
  , ddCpuRequest :: !(Maybe Text)
  , ddMemoryRequest :: !(Maybe Text)
  , ddScaleMin :: !(Maybe Natural)
  , ddScaleMax :: !(Maybe Natural)
  }
  deriving stock (Generic, Eq, Show)

dhallDeploymentDecoder :: Dhall.Decoder DhallDeployment
dhallDeploymentDecoder = Dhall.record $
  DhallDeployment
    <$> Dhall.field "name"          Dhall.strictText
    <*> Dhall.field "namespace"     Dhall.strictText
    <*> Dhall.field "image"         Dhall.strictText
    <*> Dhall.field "domain"        (Dhall.maybe Dhall.strictText)
    <*> Dhall.field "port"          Dhall.natural
    <*> Dhall.field "env"           (Dhall.list dhallEnvEntryDecoder)
    <*> Dhall.field "cpuRequest"    (Dhall.maybe Dhall.strictText)
    <*> Dhall.field "memoryRequest" (Dhall.maybe Dhall.strictText)
    <*> Dhall.field "scaleMin"      (Dhall.maybe Dhall.natural)
    <*> Dhall.field "scaleMax"      (Dhall.maybe Dhall.natural)

-- ---------------------------------------------------------------------------
-- Marshalling from DhallDeployment to Deployment

-- | Marshal a 'DhallDeployment' into a fully-validated 'Deployment'.
-- Every smart-constructor failure becomes a 'MarshalError'.
toDeployment :: DhallDeployment -> Either LoadError Deployment
toDeployment dd = do
  name' <- mapLeft (MarshalError "name")      $ mkServiceName (ddName dd)
  ns'   <- mapLeft (MarshalError "namespace") $ mkNamespace   (ddNamespace dd)
  img'  <- mapLeft (MarshalError "image")     $ mkImageRef    (ddImage dd)
  dom'  <- case ddDomain dd of
              Nothing -> Right Nothing
              Just t  -> fmap Just . mapLeft (MarshalError "domain") $ mkDomain t
  port' <- mapLeft (MarshalError "port")      $ mkPort (fromIntegral (ddPort dd))
  env'  <- mapLeft id $ mapM toEnvEntry (ddEnv dd)
  res'  <- toResources dd
  scale' <- case (ddScaleMin dd, ddScaleMax dd) of
    (Nothing, Nothing) -> Right Nothing
    (Just mn, Just mx) ->
      fmap Just . mapLeft (MarshalError "scale") $
        mkScale (fromIntegral mn) (fromIntegral mx)
    _ -> Left (MarshalError "scale"
                "scaleMin and scaleMax must both be present or both absent")
  Right Deployment
    { depName      = name'
    , depNamespace = ns'
    , depImage     = img'
    , depDomain    = dom'
    , depPort      = port'
    , depEnv       = Map.fromList env'
    , depResources = res'
    , depScale     = scale'
    }

toEnvEntry :: DhallEnvEntry -> Either LoadError (EnvName, EnvVar)
toEnvEntry e = do
  n <- mapLeft (MarshalError "env.varName") $ mkEnvName (entryVarName e)
  v <- case entryValue e of
    Literal lit   -> Right (EnvLiteral lit)
    SecretRef sec -> fmap EnvSecretRef .
                       mapLeft (MarshalError ("env." <> entryVarName e <> ".secretRef")) $
                       mkSecretName sec
  Right (n, v)

toResources :: DhallDeployment -> Either LoadError (Maybe Resources)
toResources dd =
  case (ddCpuRequest dd, ddMemoryRequest dd) of
    (Nothing, Nothing) -> Right Nothing
    (cpu, mem) -> do
      cpu' <- traverse (mapLeft (MarshalError "cpuRequest")    . mkQuantity) cpu
      mem' <- traverse (mapLeft (MarshalError "memoryRequest") . mkQuantity) mem
      Right (Just Resources { resCpu = cpu', resMemory = mem' })

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f (Left e)  = Left (f e)
mapLeft _ (Right x) = Right x

-- ---------------------------------------------------------------------------
-- The loader

-- | Load a 'Deployment' from a Dhall config file.
--
-- Returns 'Right dep' if the file parses, type-checks, and every field passes
-- EP-9's smart constructors.
--
-- Returns 'Left' with a precise 'LoadError' for each failure mode:
--   - 'FileNotFound' if the file does not exist or cannot be read.
--   - 'DhallError' if the Dhall parser, type-checker, or import resolution fails.
--   - 'MarshalError' if a field value fails a smart constructor (e.g. bad name).
loadDeployment :: FilePath -> IO (Either LoadError Deployment)
loadDeployment path = do
  result <- try @SomeException (Dhall.inputFile dhallDeploymentDecoder path)
  case result of
    Left ex ->
      -- Distinguish "file not found" from Dhall parse/type errors.
      let msg = Text.pack (show ex)
      in if isFileNotFoundMsg msg
         then pure (Left (FileNotFound path))
         else pure (Left (DhallError path msg))
    Right dd ->
      pure (toDeployment dd)

-- | Heuristic: check if the exception message indicates a missing file.
-- The Dhall library throws an IOException with the standard OS message when
-- the file cannot be opened.
isFileNotFoundMsg :: Text -> Bool
isFileNotFoundMsg msg =
  "does not exist" `Text.isInfixOf` msg
  || "No such file or directory" `Text.isInfixOf` msg
  || "openFile: does not exist" `Text.isInfixOf` msg
```

Note on `try @SomeException`: this requires `{-# LANGUAGE TypeApplications #-}` (enabled by
GHC2024). The `Dhall.inputFile` function throws exceptions for all failure modes — parse
errors, type errors, import errors, and IO errors — so catching `SomeException` is the correct
approach. The heuristic in `isFileNotFoundMsg` converts the two most common failure modes
(file missing vs. parse/type error) into the appropriate `LoadError` variant.

Note on `Dhall.natural`: this decoder returns `Natural` (from `Numeric.Natural`). Convert to
`Int` via `fromIntegral` for the smart constructors `mkPort` and `mkScale`. A `Natural` always
fits in an `Int` for the value ranges we use, but be aware that very large `Natural` values
would overflow; the smart constructors reject out-of-range values regardless.

---

#### Branch B — Config-as-program loader

**M2-B.1 — Design decision: value transport.** The config-as-program loader compiles and runs
the app's `Config.hs` file via `runghc` (shelling out with `cradle`) and captures the
`Deployment` value from stdout. The config program must serialize the `Deployment` to a format
the loader can parse back. The recommended transport is JSON, using `aeson`'s `ToJSON`/`FromJSON`
instances on an intermediate record (not on `Deployment` directly — the newtypes have no
`FromJSON` instances, and adding them would pollute the core types with a serialization concern).
The recommended approach:

1. The config program imports a helper module `Nagare.Dsl.Config` (defined by this plan) that
   provides a `deploymentToJSON :: Deployment -> LBS.ByteString` function. The config calls
   `deploymentToJSON deployment >>= LBS.putStr`. This means the config program produces JSON on
   stdout.
2. The loader runs the config program with `runghc`, captures stdout as a `ByteString` via
   `StdoutRaw`, and decodes the JSON back into an intermediate record, then re-runs the smart
   constructors to get a `Deployment`.

An alternative is for the config program to serialize to a simple line-delimited text format,
but JSON is self-describing and easier to validate. Record your choice in the Decision Log.

**M2-B.2 — Add a helper module `Nagare.Dsl.Config`.** This module defines the JSON
serialization that the config program uses to communicate its `Deployment` value to the loader.
Add `Nagare.Dsl.Config` to `exposed-modules` in `nagare-dsl.cabal`. Create
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs`:

```haskell
-- | Serialization helpers for config-as-program files.
-- A Config.hs file imports this module and calls 'emitDeployment' to send
-- its 'Deployment' value to the loader via stdout.
module Nagare.Dsl.Config
  ( emitDeployment
  ) where

import Data.Aeson ((.=), encode, object)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types

-- | Serialize a 'Deployment' to JSON and write it to stdout.
-- Call this as the last line of your Config.hs @main@ function.
emitDeployment :: Deployment -> IO ()
emitDeployment dep = LBS.putStr (encodeDeployment dep)

-- | JSON encoding of 'Deployment' as a flat record.
-- The loader reads this format in 'Nagare.Dsl.Load.loadDeployment'.
encodeDeployment :: Deployment -> LBS.ByteString
encodeDeployment dep = encode $ object
  [ "name"          .= serviceNameText (depName dep)
  , "namespace"     .= namespaceText   (depNamespace dep)
  , "image"         .= imageRefText    (depImage dep)
  , "domain"        .= fmap domainText (depDomain dep)
  , "port"          .= portInt         (depPort dep)
  , "env"           .= map encodeEnv (Map.toList (depEnv dep))
  , "cpuRequest"    .= fmap quantityText (resCpu    =<< depResources dep)
  , "memoryRequest" .= fmap quantityText (resMemory =<< depResources dep)
  , "scaleMin"      .= fmap scaleMin (depScale dep)
  , "scaleMax"      .= fmap scaleMax (depScale dep)
  ]
  where
    encodeEnv (name, EnvLiteral lit) = object
      [ "varName" .= envNameText name
      , "kind"    .= ("Literal" :: String)
      , "value"   .= lit
      ]
    encodeEnv (name, EnvSecretRef sn) = object
      [ "varName"   .= envNameText name
      , "kind"      .= ("SecretRef" :: String)
      , "secretName" .= secretNameText sn
      ]
```

**M2-B.3 — Write the hello surface config file.** Create
`cli/nagare-dsl/test/fixtures/nagare/Config.hs`. This is what an app author writes:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Hello app deployment descriptor.
-- Compile and run via: nagarectl deploy --config nagare/Config.hs
module Config (main) where

import Data.Map.Strict qualified as Map
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Types

-- | The deployment value for the hello app.
-- Every field is constructed through EP-9's smart constructors.
-- A type or constructor error here is caught at compile time by runghc.
deployment :: Either String Deployment
deployment = do
  name'  <- mapLeft show $ mkServiceName "hello"
  ns'    <- mapLeft show $ mkNamespace   "personal"
  img'   <- mapLeft show $ mkImageRef    "gcr.io/knative-samples/helloworld-go"
  dom'   <- fmap Just . mapLeft show $ mkDomain "hello.example.com"
  port'  <- mapLeft show $ mkPort 8080
  en     <- mapLeft show $ mkEnvName "TARGET"
  sc     <- mapLeft show $ mkScale 0 3
  cpuQ   <- mapLeft show $ mkQuantity "250m"
  memQ   <- mapLeft show $ mkQuantity "128Mi"
  let res = Resources { resCpu = Just cpuQ, resMemory = Just memQ }
  Right Deployment
    { depName      = name'
    , depNamespace = ns'
    , depImage     = img'
    , depDomain    = dom'
    , depPort      = port'
    , depEnv       = Map.singleton en (EnvLiteral "Nagare")
    , depResources = Just res
    , depScale     = Just sc
    }
  where
    mapLeft f (Left e)  = Left (f e)
    mapLeft _ (Right x) = Right x

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
```

**M2-B.4 — Implement `Nagare.Dsl.Load` (Branch B).** Replace the stub:

```haskell
module Nagare.Dsl.Load
  ( LoadError (..)
  , renderLoadError
  , loadDeployment
  ) where

import Control.Exception (IOException, try)
import Cradle (StderrRaw (..), StdoutRaw (..), addArgs, cmd, run, setWorkingDir)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))

-- ---------------------------------------------------------------------------
-- LoadError

data LoadError
  = FileNotFound !FilePath
  | CompileError !FilePath !Text
  | MissingBinding !FilePath
  | MarshalError !Text !Text
  deriving stock (Generic, Eq, Show)

renderLoadError :: LoadError -> Text
renderLoadError (FileNotFound path) =
  "nagare: config file not found: " <> Text.pack path
renderLoadError (CompileError path msg) =
  "nagare: compile error in " <> Text.pack path <> ":\n  " <> msg
renderLoadError (MissingBinding path) =
  "nagare: " <> Text.pack path <> " compiled but did not produce a 'deployment' value"
renderLoadError (MarshalError field msg) =
  "nagare: field '" <> field <> "' failed validation: " <> msg

-- ---------------------------------------------------------------------------
-- JSON intermediate record (mirrors the format emitted by Nagare.Dsl.Config)

data JsonEnvEntry = JsonEnvEntry
  { jeVarName :: !Text
  , jeKind :: !Text -- "Literal" or "SecretRef"
  , jeValue :: !(Maybe Text) -- present when kind = "Literal"
  , jeSecretName :: !(Maybe Text) -- present when kind = "SecretRef"
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonEnvEntry where
  parseJSON = withObject "EnvEntry" $ \o ->
    JsonEnvEntry
      <$> o .:  "varName"
      <*> o .:  "kind"
      <*> o .:? "value"
      <*> o .:? "secretName"

data JsonDeployment = JsonDeployment
  { jdName :: !Text
  , jdNamespace :: !Text
  , jdImage :: !Text
  , jdDomain :: !(Maybe Text)
  , jdPort :: !Int
  , jdEnv :: ![JsonEnvEntry]
  , jdCpuRequest :: !(Maybe Text)
  , jdMemoryRequest :: !(Maybe Text)
  , jdScaleMin :: !(Maybe Int)
  , jdScaleMax :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDeployment where
  parseJSON = withObject "Deployment" $ \o ->
    JsonDeployment
      <$> o .:  "name"
      <*> o .:  "namespace"
      <*> o .:  "image"
      <*> o .:? "domain"
      <*> o .:  "port"
      <*> o .:  "env"
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "scaleMin"
      <*> o .:? "scaleMax"

-- ---------------------------------------------------------------------------
-- Marshalling from JsonDeployment to Deployment

toDeployment :: JsonDeployment -> Either LoadError Deployment
toDeployment jd = do
  name' <- mapLeft (MarshalError "name")      $ mkServiceName (jdName jd)
  ns'   <- mapLeft (MarshalError "namespace") $ mkNamespace   (jdNamespace jd)
  img'  <- mapLeft (MarshalError "image")     $ mkImageRef    (jdImage jd)
  dom'  <- case jdDomain jd of
              Nothing -> Right Nothing
              Just t  -> fmap Just . mapLeft (MarshalError "domain") $ mkDomain t
  port' <- mapLeft (MarshalError "port")      $ mkPort (jdPort jd)
  env'  <- mapM toEnvEntry (jdEnv jd)
  res'  <- toResources jd
  scale' <- case (jdScaleMin jd, jdScaleMax jd) of
    (Nothing, Nothing) -> Right Nothing
    (Just mn, Just mx) ->
      fmap Just . mapLeft (MarshalError "scale") $ mkScale mn mx
    _ -> Left (MarshalError "scale"
                "scaleMin and scaleMax must both be present or both absent")
  Right Deployment
    { depName      = name'
    , depNamespace = ns'
    , depImage     = img'
    , depDomain    = dom'
    , depPort      = port'
    , depEnv       = Map.fromList env'
    , depResources = res'
    , depScale     = scale'
    }

toEnvEntry :: JsonEnvEntry -> Either LoadError (EnvName, EnvVar)
toEnvEntry e = do
  n <- mapLeft (MarshalError "env.varName") $ mkEnvName (jeVarName e)
  v <- case jeKind e of
    "Literal"   ->
      case jeValue e of
        Nothing  -> Left (MarshalError ("env." <> jeVarName e) "Literal entry missing 'value' field")
        Just lit -> Right (EnvLiteral lit)
    "SecretRef" ->
      case jeSecretName e of
        Nothing  -> Left (MarshalError ("env." <> jeVarName e) "SecretRef entry missing 'secretName' field")
        Just sec -> fmap EnvSecretRef . mapLeft (MarshalError ("env." <> jeVarName e <> ".secretRef"))
                      $ mkSecretName sec
    other -> Left (MarshalError ("env." <> jeVarName e <> ".kind")
                    ("unknown env kind: " <> other))
  Right (n, v)

toResources :: JsonDeployment -> Either LoadError (Maybe Resources)
toResources jd =
  case (jdCpuRequest jd, jdMemoryRequest jd) of
    (Nothing, Nothing) -> Right Nothing
    (cpu, mem) -> do
      cpu' <- traverse (mapLeft (MarshalError "cpuRequest")    . mkQuantity) cpu
      mem' <- traverse (mapLeft (MarshalError "memoryRequest") . mkQuantity) mem
      Right (Just Resources { resCpu = cpu', resMemory = mem' })

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f (Left e)  = Left (f e)
mapLeft _ (Right x) = Right x

-- ---------------------------------------------------------------------------
-- The loader

-- | Load a 'Deployment' from a Haskell config-as-program source file.
--
-- The file is compiled and run via @runghc@. The config program must call
-- 'Nagare.Dsl.Config.emitDeployment' to write JSON to stdout.
--
-- Returns 'Left' with one of:
--   - 'FileNotFound' if the file does not exist.
--   - 'CompileError' if @runghc@ exits non-zero (carries GHC stderr).
--   - 'MissingBinding' if the program produced no output.
--   - 'MarshalError' if JSON parsing or smart-constructor validation fails.
loadDeployment :: FilePath -> IO (Either LoadError Deployment)
loadDeployment path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (FileNotFound path))
    else do
      -- Determine the source root: the directory containing the config file
      -- becomes the GHC include path for local imports within the config.
      let configDir = takeDirectory path
      -- Shell out to runghc, capturing stdout (the JSON) and stderr (GHC diagnostics).
      -- Cradle's StdoutRaw gives us raw ByteString without trimming.
      result <- try @IOException $ do
        (StdoutRaw stdout, StderrRaw stderr) <-
          run $ cmd "runghc"
              & addArgs
                  [ "-i" <> configDir
                  , path
                  ]
        pure (stdout, stderr)
      case result of
        Left ioErr ->
          pure (Left (CompileError path (Text.pack (show ioErr))))
        Right (stdout, stderr) ->
          if BS.null stdout
            then pure (Left (MissingBinding path))
            else case eitherDecodeStrict stdout of
              Left parseErr ->
                pure (Left (CompileError path
                  ("JSON decode error: " <> Text.pack parseErr <> "\nGHC output:\n" <> Text.decodeUtf8 stderr)))
              Right jd ->
                pure (toDeployment jd)
```

Note: `Text.decodeUtf8` is from `Data.Text.Encoding`. Add `text` to `build-depends` if not already
present (it is, from EP-9). Add `import Data.Text.Encoding (decodeUtf8)` and use
`decodeUtf8 stderr` instead of `Text.decodeUtf8 stderr`. The `run` call returns a tuple because
`Output (a, b)` is supported when both `a` and `b` implement `Output` individually; check the
cradle `Output` instances if this does not compile — you may need to capture them separately
with two `run` calls or use a pair wrapper.

A simpler alternative if tuple output is not supported: run the process with `ExitCode` +
`StdoutRaw` in two steps, using `run_` first, then `run` — or use `process` (`System.Process`)
directly to capture both stdout and stderr in one call:

```haskell
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

shellOut :: FilePath -> FilePath -> IO (Either LoadError BS.ByteString)
shellOut configDir path = do
  (exitCode, stdout, stderr) <-
    readProcessWithExitCode "runghc" ["-i" <> configDir, path] ""
  case exitCode of
    ExitSuccess -> pure (Right (BS.pack (map (fromIntegral . fromEnum) stdout)))
    ExitFailure _ -> pure (Left (CompileError path (Text.pack stderr)))
```

Using `readProcessWithExitCode` from `System.Process` (a boot library, no extra dependency)
avoids the tuple-output complexity. It returns `String` rather than `ByteString`; convert with
`Data.ByteString.Char8.pack`. Record the approach chosen in the Decision Log.

**M2-B.5 — Write the hello fixture.** Create the directory and the fixture:

```bash
mkdir -p /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl/test/fixtures/nagare
```

Then write the `Config.hs` file shown in M2-B.3 into
`cli/nagare-dsl/test/fixtures/nagare/Config.hs`.

---

#### M2 — Validation (both branches)

**M2.V.1 — Write the load golden test.** Extend `cli/nagare-dsl/test/Spec.hs` (or add
`test/LoadSpec.hs` and import it). Add a test that calls `loadDeployment` on the hello fixture
and checks the resulting `Deployment` against EP-9's `helloDep` value, then renders it through
`renderService` and compares against the golden service YAML file:

```haskell
-- In test/Spec.hs (or LoadSpec.hs), add:

import Nagare.Dsl.Load  (loadDeployment)
import Nagare.Dsl.Render (renderService)

loadGoldenTests :: [TestTree]
loadGoldenTests =
  [ testCase "loadDeployment hello returns Right helloDep" $ do
      -- Path to the fixture file (relative paths work from the cabal test runner,
      -- which sets the working directory to the package root cli/nagare-dsl/).
      let fixturePath = case branch of
            Dhall -> "test/fixtures/hello.dhall"
            ConfigAsProgram -> "test/fixtures/nagare/Config.hs"
      result <- loadDeployment fixturePath
      case result of
        Left err -> assertFailure ("loadDeployment returned Left: " <> show err)
        Right dep -> dep @?= helloDep  -- helloDep defined in EP-9's golden test section

  , goldenVsString
      "loadDeployment hello renders to golden service YAML"
      "test/golden/hello.service.yaml"
      (do
         let fixturePath = case branch of
               Dhall -> "test/fixtures/hello.dhall"
               ConfigAsProgram -> "test/fixtures/nagare/Config.hs"
         result <- loadDeployment fixturePath
         case result of
           Left err -> fail ("loadDeployment returned Left: " <> show err)
           Right dep -> pure (fromStrict (renderService dep "20260602-120000")))
  ]
```

Replace the `case branch of` comment with the actual fixture path for the branch you
implemented. The equality test `dep @?= helloDep` is the definitive proof that the loaded
value is byte-for-byte identical to what EP-9's constructors produce — same validated types,
same field order, same values. The golden YAML comparison then proves that this correct
`Deployment` renders identically to EP-9's golden output.

**M2.V.2 — Run the tests.** From `cli/nagare-dsl/`:

```bash
cabal test nagare-dsl-test --test-show-details=streaming
```

Expected:

```text
nagare-dsl
  Nagare.Dsl.Types
    ...  (all prior unit tests, unchanged)
  Nagare.Dsl.Render
    renderService hello:                       OK
    renderDomainMapping hello:                 OK
  Nagare.Dsl.Load
    loadDeployment hello returns Right helloDep: OK
    loadDeployment hello renders to golden service YAML: OK

All N tests passed.
Test suite nagare-dsl-test: PASS
```

If `loadDeployment hello returns Right helloDep` fails with a `dep /= helloDep` assertion, the
output will show both values. Compare field by field to find the discrepancy. Common issues:
the fixture file uses a different field value than the golden (e.g. `scaleMax = Some 4` instead
of `Some 3`), or the marshalling function for env entries reversed the sort order.

---

### M3 — Failure-mode test suite

Create `cli/nagare-dsl/test/LoadSpec.hs` with the failure-mode tests. These tests do not need
fixture files for every case — they can call `loadDeployment` on a programmatically written
temporary file, or test the `toDeployment` / `toEnvEntry` marshalling functions directly (which
is faster and does not require file I/O for every case). The recommended approach: expose
`toDeployment` (or its equivalent) from `Nagare.Dsl.Load` for testing, or use `loadDeployment`
with temporary files. Below, tests against the internal marshaller are shown for brevity; the
implementer may also write temp-file tests for end-to-end coverage.

Add `LoadSpec.hs` to the `test-suite` stanza's `other-modules` in `nagare-dsl.cabal`, or
merge into `Spec.hs`.

**The failure-mode test module (Branch A — Dhall):**

```haskell
module LoadSpec (loadTests) where

import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Load
import Nagare.Dsl.Prelude
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty
import Test.Tasty.HUnit

loadTests :: TestTree
loadTests = testGroup "Nagare.Dsl.Load failure modes"
  [ testCase "file not found returns FileNotFound" $ do
      result <- loadDeployment "/nonexistent/nagare.dhall"
      result @?= Left (FileNotFound "/nonexistent/nagare.dhall")

  , testCase "renderLoadError FileNotFound contains path" $
      assertContains "/nonexistent/nagare.dhall"
        (renderLoadError (FileNotFound "/nonexistent/nagare.dhall"))

  , testCase "bad service name (uppercase) returns MarshalError on name field" $ do
      result <- withDhallFixture badNameDhall loadDeployment
      case result of
        Left (MarshalError "name" msg) ->
          assertContains "invalid" msg
        other -> assertFailure ("expected MarshalError name, got: " <> show other)

  , testCase "max < min returns MarshalError on scale field" $ do
      result <- withDhallFixture badScaleDhall loadDeployment
      case result of
        Left (MarshalError "scale" msg) ->
          assertContains ">=" msg
        other -> assertFailure ("expected MarshalError scale, got: " <> show other)

  , testCase "missing required field (port) returns DhallError" $ do
      result <- withDhallFixture missingPortDhall loadDeployment
      case result of
        Left (DhallError _ _) -> pure ()
        other -> assertFailure ("expected DhallError, got: " <> show other)

  , testCase "syntax error in Dhall file returns DhallError" $ do
      result <- withDhallFixture syntaxErrorDhall loadDeployment
      case result of
        Left (DhallError _ _) -> pure ()
        other -> assertFailure ("expected DhallError, got: " <> show other)

  , testCase "renderLoadError MarshalError name contains field name and message" $
      assertContains "name" (renderLoadError (MarshalError "name" "contains invalid characters: Hello"))

  , testCase "renderLoadError DhallError contains file path" $
      assertContains "/some/file.dhall" (renderLoadError (DhallError "/some/file.dhall" "type error"))
  ]

-- | Write a Dhall string to a temp file and run the action.
withDhallFixture :: String -> (FilePath -> IO a) -> IO a
withDhallFixture content action =
  withSystemTempFile "nagare-test.dhall" $ \path h -> do
    hPutStr h content
    hClose h
    action path

-- Broken fixtures:

-- Bad name: uppercase character in service name
badNameDhall :: String
badNameDhall = unlines
  [ "{ name      = \"Hello_World\""
  , ", namespace = \"personal\""
  , ", image     = \"gcr.io/foo/bar\""
  , ", domain    = None Text"
  , ", port      = 8080"
  , ", env       = [] : List { varName : Text, value : < Literal : Text | SecretRef : Text > }"
  , ", cpuRequest    = None Text"
  , ", memoryRequest = None Text"
  , ", scaleMin      = None Natural"
  , ", scaleMax      = None Natural"
  , "}"
  ]

-- Bad scale: max < min
badScaleDhall :: String
badScaleDhall = unlines
  [ "{ name      = \"hello\""
  , ", namespace = \"personal\""
  , ", image     = \"gcr.io/foo/bar\""
  , ", domain    = None Text"
  , ", port      = 8080"
  , ", env       = [] : List { varName : Text, value : < Literal : Text | SecretRef : Text > }"
  , ", cpuRequest    = None Text"
  , ", memoryRequest = None Text"
  , ", scaleMin      = Some 5"
  , ", scaleMax      = Some 1"
  , "}"
  ]

-- Missing port field — Dhall type-check rejects it
missingPortDhall :: String
missingPortDhall = unlines
  [ "{ name      = \"hello\""
  , ", namespace = \"personal\""
  , ", image     = \"gcr.io/foo/bar\""
  , "}"
  ]

-- Syntax error
syntaxErrorDhall :: String
syntaxErrorDhall = "{ name = \"hello\" INVALID_SYNTAX }"

assertContains :: Text -> Text -> Assertion
assertContains needle haystack
  | needle `Text.isInfixOf` haystack = pure ()
  | otherwise = assertFailure
      ("expected " <> show needle <> " to appear in: " <> Text.unpack haystack)
```

**The failure-mode test module (Branch B — config-as-program):**

```haskell
module LoadSpec (loadTests) where

import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Load
import Nagare.Dsl.Prelude
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty
import Test.Tasty.HUnit

loadTests :: TestTree
loadTests = testGroup "Nagare.Dsl.Load failure modes"
  [ testCase "file not found returns FileNotFound" $ do
      result <- loadDeployment "/nonexistent/Config.hs"
      result @?= Left (FileNotFound "/nonexistent/Config.hs")

  , testCase "renderLoadError FileNotFound contains path" $
      assertContains "/nonexistent/Config.hs"
        (renderLoadError (FileNotFound "/nonexistent/Config.hs"))

  , testCase "bad service name (uppercase) returns MarshalError on name field" $ do
      result <- withConfigFixture badNameConfig loadDeployment
      case result of
        Left (MarshalError "name" msg) -> assertContains "invalid" msg
        other -> assertFailure ("expected MarshalError name, got: " <> show other)

  , testCase "max < min returns MarshalError on scale field" $ do
      result <- withConfigFixture badScaleConfig loadDeployment
      case result of
        Left (MarshalError "scale" msg) -> assertContains ">=" msg
        other -> assertFailure ("expected MarshalError scale, got: " <> show other)

  , testCase "compile error in Config.hs returns CompileError" $ do
      result <- withConfigFixture syntaxErrorConfig loadDeployment
      case result of
        Left (CompileError _ _) -> pure ()
        other -> assertFailure ("expected CompileError, got: " <> show other)

  , testCase "Config.hs with no emitDeployment call returns MissingBinding" $ do
      result <- withConfigFixture noEmitConfig loadDeployment
      case result of
        Left (MissingBinding _) -> pure ()
        other -> assertFailure ("expected MissingBinding, got: " <> show other)

  , testCase "renderLoadError CompileError contains file path and diagnostic" $ do
      let err = CompileError "/app/Config.hs" "parse error"
      assertContains "/app/Config.hs" (renderLoadError err)
      assertContains "parse error"    (renderLoadError err)
  ]

withConfigFixture :: String -> (FilePath -> IO a) -> IO a
withConfigFixture content action =
  withSystemTempFile "Config.hs" $ \path h -> do
    hPutStr h content
    hClose h
    action path

badNameConfig :: String
badNameConfig = unlines
  [ "{-# LANGUAGE OverloadedStrings #-}"
  , "module Config (main) where"
  , "import Nagare.Dsl.Types"
  , "import Nagare.Dsl.Config (emitDeployment)"
  , "import qualified Data.Map.Strict as Map"
  , "main :: IO ()"
  , "main = do"
  , "  let Right name  = mkServiceName \"Hello_World\""  -- fails at runtime
  , "      Right ns    = mkNamespace \"personal\""
  , "      Right img   = mkImageRef \"gcr.io/foo/bar\""
  , "      Right port' = mkPort 8080"
  , "      dep = Deployment name ns img Nothing port' Map.empty Nothing Nothing"
  , "  emitDeployment dep"
  ]

badScaleConfig :: String
badScaleConfig = unlines
  [ "{-# LANGUAGE OverloadedStrings #-}"
  , "module Config (main) where"
  , "import Nagare.Dsl.Types"
  , "import Nagare.Dsl.Config (emitDeployment)"
  , "import qualified Data.Map.Strict as Map"
  , "main :: IO ()"
  , "main = do"
  , "  let Right name  = mkServiceName \"hello\""
  , "      Right ns    = mkNamespace \"personal\""
  , "      Right img   = mkImageRef \"gcr.io/foo/bar\""
  , "      Right port' = mkPort 8080"
  , "      Right sc    = mkScale 5 1"  -- fails: max < min
  , "      dep = Deployment name ns img Nothing port' Map.empty Nothing (Just sc)"
  , "  emitDeployment dep"
  ]

syntaxErrorConfig :: String
syntaxErrorConfig = "THIS IS NOT VALID HASKELL ###"

noEmitConfig :: String
noEmitConfig = unlines
  [ "module Config (main) where"
  , "main :: IO ()"
  , "main = pure ()"  -- no emitDeployment call
  ]
```

Note: for Branch B's `badNameConfig` and `badScaleConfig`, the failure comes from the
`Right ...` irrefutable pattern match at runtime, which causes the `runghc` process to exit
non-zero with a stderr message. The loader interprets a non-zero exit as `CompileError` (which
is technically a runtime error, but the same variant is appropriate since the config program
failed). Alternatively, expose `toDeployment` for direct testing of the marshal layer without
subprocess overhead; record this decision in the Decision Log if you do.

**M3 — Run the failure-mode tests.** From `cli/nagare-dsl/`:

```bash
cabal test nagare-dsl-test --test-show-details=streaming
```

Expected (failures section, new):

```text
  Nagare.Dsl.Load failure modes
    file not found returns FileNotFound:                      OK
    renderLoadError FileNotFound contains path:               OK
    bad service name (uppercase) returns MarshalError ...:    OK
    max < min returns MarshalError on scale field:            OK
    missing required field (port) returns DhallError:         OK  [Branch A]
    syntax error in Dhall file returns DhallError:            OK  [Branch A]
    compile error in Config.hs returns CompileError:          OK  [Branch B]
    Config.hs with no emitDeployment returns MissingBinding:  OK  [Branch B]
    renderLoadError MarshalError name contains ...:           OK
    renderLoadError DhallError/CompileError contains path:    OK

All N tests passed.
Test suite nagare-dsl-test: PASS
```

Every test must pass. If a failure-mode test receives `Right dep` instead of a `Left`, the
error-detection path in the loader is broken — add a debug print of the result and trace
whether the bad value reached `toDeployment` at all.


## Validation and Acceptance

Acceptance is behavioral. All three gates must pass before marking this plan complete.

**Gate 1 — M1: The module builds and the demo runs.** From `cli/nagare-dsl/`:

```bash
cabal build
cabal run nagare-dsl-load-demo
```

`cabal build` exits 0. The demo prints one line per `LoadError` variant, each matching the
expected format shown in M1.5.

**Gate 2 — M2: The hello config file loads correctly.** From `cli/nagare-dsl/`:

```bash
cabal test nagare-dsl-test --test-show-details=streaming 2>&1 | grep -E "loadDeployment|PASS|FAIL"
```

Expected:

```text
loadDeployment hello returns Right helloDep:          OK
loadDeployment hello renders to golden service YAML:  OK
Test suite nagare-dsl-test: PASS
```

The equality assertion `dep @?= helloDep` proves the loaded value is *identical* to EP-9's
canonical hello value — same `ServiceName`, same `Namespace`, same env map, same `Scale`. The
golden YAML comparison then proves that rendering this value produces the exact same bytes as
EP-9's golden file. Together, these two checks prove Integration Point 3 is correctly wired to
Integration Points 1 and 2.

**Gate 3 — M3: All failure-mode tests pass.** From `cli/nagare-dsl/`:

```bash
cabal test nagare-dsl-test --test-show-details=streaming 2>&1 | grep -E "failure|PASS|FAIL"
```

Expected:

```text
Nagare.Dsl.Load failure modes
  ... (all variants) ...
Test suite nagare-dsl-test: PASS
```

No `Left` variant is missing. No test returns `Right` when a `Left` is expected. Each
`renderLoadError` output contains the expected diagnostic fragment. No `Deployment` is returned
for any broken input.

To run all gates in a single command:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal build \
  && cabal run nagare-dsl-load-demo \
  && cabal test nagare-dsl-test --test-show-details=streaming \
  && echo "ALL GATES PASSED"
```


## Idempotence and Recovery

All steps are additive and safe to repeat. `cabal build` and `cabal test` are idempotent.

If `cabal build` fails with a missing package (e.g. `dhall` or `cradle` not found), add the
corpus path to `cli/nagare-dsl/cabal.project` as shown in M1.2 and record the fact in
Surprises & Discoveries.

If a golden test in M2 fails with a mismatch, `tasty-golden` will print both the actual output
and the expected golden file. The most common cause: the fixture file's field values do not
match the `helloDep` values from EP-9 (e.g. a different image string). Fix the fixture, not the
golden file.

If the `try @SomeException` pattern in the Dhall loader does not compile (error about the type
application syntax), add `{-# LANGUAGE TypeApplications #-}` to the language pragmas of
`Load.hs`, or use the `SomeException` catch without the type application:
`catch (fmap Right action) (\(ex :: SomeException) -> pure (Left ...))`.

For Branch B: if `runghc` is not on `PATH` inside `nix develop`, use `cabal exec -- runghc`
as the command in the `cmd` call, or pass the full path. Record the alternative in Surprises.

Temporary files written by the failure-mode tests in M3 (`withSystemTempFile`) are cleaned up
by the `temporary` library after each test. Re-running the tests is safe.


## Interfaces and Dependencies

**Types and function signatures that must exist at the end of this plan (full module paths).**

From `Nagare.Dsl.Load` (module owned by this plan, in `cli/nagare-dsl/`):

```haskell
-- Branch A (Dhall) LoadError:
data LoadError
  = FileNotFound FilePath
  | DhallError   FilePath Text
  | MarshalError Text     Text

-- Branch B (config-as-program) LoadError:
data LoadError
  = FileNotFound   FilePath
  | CompileError   FilePath Text
  | MissingBinding FilePath
  | MarshalError   Text     Text

-- Common to all branches:
renderLoadError :: LoadError -> Text
loadDeployment  :: FilePath -> IO (Either LoadError Deployment)
```

The `loadDeployment` signature is **Integration Point 3** of the parent MasterPlan
(`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`). EP-12 calls exactly
this function. If any change to the signature is required, update the MasterPlan's Integration
Point 3 entry and notify EP-12's author before writing code.

**Packages added by this plan (per branch).**

Branch A (Dhall):
- `dhall` (mori corpus: `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall`)
  — `Dhall.inputFile :: Decoder a -> FilePath -> IO a`,
    `Dhall.record`, `Dhall.field`, `Dhall.union`, `Dhall.constructor`, `Dhall.strictText`,
    `Dhall.natural`, `Dhall.maybe`, `Dhall.list`.
- `base` — `Control.Exception.try @SomeException` for catching all Dhall exceptions.
- `Numeric.Natural` — `Natural` type returned by `Dhall.natural`.

Branch B (config-as-program):
- `cradle` (mori corpus: `/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle`)
  — `cmd`, `run`, `addArgs`, `setWorkingDir`, `StdoutRaw(..)`, `StderrRaw(..)`.
- `aeson` — `FromJSON`, `eitherDecodeStrict` for JSON transport.
- `process` (boot) — `readProcessWithExitCode` (alternative to `cradle` if tuple output is complex).
- `temporary` (Hackage) — `withSystemTempFile` in the failure-mode tests.
- `directory` (boot) — `doesFileExist`.
- `filepath` (boot) — `takeDirectory`, `(</>)`.

**Packages unchanged from EP-9:** `text`, `bytestring`, `containers`, `yaml`, `aeson`,
`tasty`, `tasty-hunit`, `tasty-golden`.

**Files modified by this plan** (all inside `cli/nagare-dsl/`):
- `nagare-dsl.cabal` — add `Nagare.Dsl.Load` to `exposed-modules`; add branch dependencies.
- `cabal.project` — add corpus path for `dhall` (Branch A) or `cradle` (Branch B).
- `src/Nagare/Dsl/Load.hs` — new file (owned by this plan).
- `demo/LoadDemo.hs` — new file (owned by this plan).
- `test/Spec.hs` — extended with load golden tests.
- `test/LoadSpec.hs` — new file (failure-mode suite).
- `test/fixtures/hello.dhall` (Branch A) or `test/fixtures/nagare/Config.hs` (Branch B) — new.

**Files not touched by this plan:** `src/Nagare/Dsl/Types.hs`, `src/Nagare/Dsl/Render.hs`,
`test/golden/hello.service.yaml`, `test/golden/hello.domainmapping.yaml`,
`test/golden/hello.nagare.yaml`, `test/negative/BadConstructor.hs`,
`test/negative/check-negative-types.sh`, `cli/nagarectl/` (EP-12 touches that),
`cluster/examples/hello-knative-service/` (EP-12 migrates that).
