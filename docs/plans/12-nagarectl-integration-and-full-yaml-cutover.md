---
id: 12
slug: nagarectl-integration-and-full-yaml-cutover
title: "nagarectl integration and full YAML cutover"
kind: exec-plan
created_at: 2026-06-03T03:44:07Z
intention: "intention_01kt5s3j2zedh8ew1yp9qdp6c7"
master_plan: "docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md"
---

# nagarectl integration and full YAML cutover

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Before this plan, deploying an app with `nagarectl` requires a `nagare.yaml` file that a
YAML parser accepts silently even when it contains misconfigurations (a misspelled field, a
service name with uppercase letters, `max` scale below `min`, a CPU quantity like `"abc"`,
or an environment variable entry that has both `value:` and `secretRef:` set). After this
plan, there is no `nagare.yaml` anywhere in the repository. Each deployable app instead
carries a typed configuration file in the substrate chosen by EP-8 — for example, a
`nagare/Config.hs` that imports the `nagare-dsl` library (for the native eDSL outcome) or a
`nagare.dhall` that imports a typed Dhall package (for the Dhall outcome). The same
`nagarectl deploy` command as before still builds, pushes, renders, applies, waits, and
prints a URL — but now the path from config file to running service is fully type-checked,
and a broken config produces a clear one-line error on `stderr` and exit code 1 before
anything touches the cluster.

What you can do after this plan: run `nagarectl deploy --dry-run` in the
`cluster/examples/hello-knative-service/` directory and see the rendered Knative Service
YAML and the computed URL printed to the terminal, with no YAML parser involved. Run the same
command without `--dry-run` against a live cluster and get back an HTTPS URL that returns 200.
Run it with a deliberately broken typed config and see a human-readable error message.

This plan is EP-12 in the MasterPlan at
`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`. It implements
Integration Point 4 of that MasterPlan: the hard cutover that supersedes EP-6's `nagare.yaml`
contract, retires EP-6's `Nagare.Config` and `Nagare.Render` modules, and amends the bootstrap
MasterPlan's Integration Point 6.

This plan hard-depends on EP-9 (`docs/plans/9-typed-core-deployment-model-and-knative-renderer.md`)
for the typed `Deployment` model, the renderer, and the `nagare-dsl` library package, and on
EP-10 (`docs/plans/10-config-surface-and-loading-for-the-chosen-substrate.md`) for
`loadDeployment`. It soft-depends on EP-11
(`docs/plans/11-reusable-config-presets-and-composition-library.md`) for a richer reuse demo
(nice to have but not required for the cutover) and on EP-6
(`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`) as the existing package it modifies.


## Progress

- [ ] M1.1 Extend `cli/nagarectl/cabal.project` to include `../nagare-dsl` as a `packages:` entry, so the sibling library is visible to the build.
- [ ] M1.2 Update `cli/nagarectl/nagarectl.cabal`: add `nagare-dsl` to the library's `build-depends`; remove `yaml` and `aeson` from library build-depends if they are no longer needed (those deps drove Config.hs parsing; Image.hs/Deploy.hs do not use them directly).
- [ ] M1.3 Delete `cli/nagarectl/src/Nagare/Config.hs` (the YAML parser and `NagareConfig` record).
- [ ] M1.4 Delete `cli/nagarectl/src/Nagare/Render.hs` (the YAML renderer — superseded by EP-9's `Nagare.Dsl.Render`).
- [ ] M1.5 Remove `Nagare.Config` and `Nagare.Render` from the `exposed-modules` list in `nagarectl.cabal`.
- [ ] M1.6 Rewrite `cli/nagarectl/src/Nagare/Image.hs` to accept `ImageRef` and `Deployment` from `Nagare.Dsl.Types` instead of `NagareConfig`; adjust `buildImage`/`pushImage` call sites.
- [ ] M1.7 Rewrite `cli/nagarectl/src/Nagare/Deploy.hs` to accept `Deployment` from `Nagare.Dsl.Types` instead of `NagareConfig`; adjust `serviceUrl` to read `depName`/`depNamespace`/`depDomain`.
- [ ] M1.8 Rewrite `cli/nagarectl/app/Main.hs` deploy flow: call `loadDeployment` (EP-10), handle `Left` with `renderLoadError` + exit 1, on `Right` call `computeTag` / `buildImage` / `configureDockerAuth` / `pushImage` / `renderService` / `renderDomainMapping` / `applyManifests` / `waitForReady` / `serviceUrl`; `--dry-run` prints rendered YAML and URL without side effects.
- [ ] M1.9 Remove the EP-6 golden test from `cli/nagarectl/test/` if it tested `Nagare.Config`/`Nagare.Render` (those modules are now gone); EP-9's `nagare-dsl` test suite is the authoritative golden test.
- [ ] M1.10 `cabal build` succeeds from `cli/nagarectl/`; `cabal run nagarectl -- --help` shows the deploy subcommand.
- [ ] M1.11 `nagarectl deploy --dry-run` in the migrated hello example prints the rendered Knative Service YAML and the computed URL. Prove with `git grep -l Nagare.Config` returning nothing except plan documents.
- [ ] M2.1 Run `nagarectl deploy` in the hello example against a live cluster (EP-4 cluster + KUBECONFIG + gcloud authed to `tan-nb-exp`); verify build/push/apply/wait/URL with a real deploy.
- [ ] M2.2 `curl` the printed URL; confirm HTTP 200.
- [ ] M3.1 Migrate `cluster/examples/hello-knative-service/`: replace `nagare.yaml` with the chosen substrate's typed config expressing the same deployment; update the directory's README.
- [ ] M3.2 Verify no `nagare.yaml` remains anywhere: `git grep -l nagare.yaml` shows only historical plan references (plan `.md` files), not any application config or test fixture.
- [ ] M3.3 Verify failure path: run `nagarectl deploy` with a deliberately broken typed config; observe `renderLoadError` message on stderr and exit code 1.
- [ ] M3.4 Amend `docs/masterplans/1-bootstrap-nagare-personal-paas.md` Integration Point 6: replace the `nagare.yaml` YAML schema block with a note that the YAML contract is superseded by this initiative; link to this plan and the MasterPlan 2.
- [ ] M3.5 Amend `docs/plans/6-nagarectl-deploy-cli-in-haskell.md`: add a note at the bottom that its `Nagare.Config` and `Nagare.Render` modules were retired by EP-12 as part of the typed DSL cutover.
- [ ] Final: update Progress, Surprises & Discoveries, Decision Log, and Outcomes; verify the MasterPlan's EP-12 progress row.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: EP-10's `loadDeployment` is treated as a black box. EP-12 calls exactly the
  signature `loadDeployment :: FilePath -> IO (Either LoadError Deployment)` from
  `Nagare.Dsl.Load` and maps `Left` to `renderLoadError :: LoadError -> Text`. It does not
  know or care which substrate EP-8 chose — that is entirely encapsulated in EP-10.
  Rationale: This is the whole point of Integration Point 3 in the MasterPlan: a stable
  boundary so EP-12 can be authored independently of the substrate decision. If EP-10's
  signature changes, EP-10 updates this plan's Interfaces section.
  Date: 2026-06-03

- Decision: keep `yaml` and `aeson` in `nagarectl`'s `build-depends` only if `Nagare.Deploy`
  or `Nagare.Image` still need them; otherwise remove them from the library stanza. The
  executable stanza keeps `optparse-applicative`, `text`, `bytestring`, `base`, and the
  `nagarectl` library. Rendering is now entirely via `nagare-dsl`.
  Rationale: Removing unused deps keeps the build lean and makes it obvious that YAML
  parsing/rendering no longer happens in `nagarectl` proper. `aeson`/`yaml` are still valid
  deps in `nagare-dsl` (which is where the rendering lives), so removing them from
  `nagarectl` is correct if no code there imports them.
  Date: 2026-06-03

- Decision: the `cli/nagarectl/test/` golden test for `Nagare.Config`/`Nagare.Render` is
  deleted. EP-9's `nagare-dsl-test` golden test is the authoritative renderer contract.
  Rationale: The golden test in EP-6 was designed to test the modules being deleted. Keeping
  a dead test fixture would be confusing and would require maintaining two identical golden
  files. EP-9's test suite is the single source of truth.
  Date: 2026-06-03

- Decision: As part of the cutover, EP-12 migrates `cli/nagarectl/` from EP-6's `Haskell2010`
  to the house standard `GHC2024` + `common` stanza and the GHC 9.12 toolchain, matching
  `nagare-dsl`. `Main.hs` imports `Nagare.Dsl.Prelude` and uses postpositive qualified imports
  and generic-lens `#label` access.
  Rationale: a single coherent toolchain/standard across both packages; consistency with
  MasterPlan Integration Point 6.
  Date: 2026-06-03

- Decision: the bootstrap MasterPlan's Integration Point 6 is amended in-place (not appended
  with a new integration point). The YAML schema block is replaced with a forward reference
  note to this plan and MasterPlan 2.
  Rationale: Integration Point 6 as written describes a contract that no longer exists after
  EP-12 completes. Leaving it unchanged would mislead future readers. Amending it in-place
  (with a revision note at the plan's bottom) is the ExecPlan revision protocol.
  Date: 2026-06-03


## Outcomes & Retrospective

(To be filled during and after implementation. Compare the result against the Purpose / Big
Picture: `nagarectl deploy --dry-run` working with no YAML parser, a live deploy succeeding,
and `git grep -l nagare.yaml` returning only plan documents.)


## Context and Orientation

Read this section fully before touching code. It assumes you have no prior context.

**What this repository is.** Nagare is a single-node personal Platform-as-a-Service: one GCP
virtual machine running k3s (a lightweight Kubernetes distribution) with Knative Serving
installed. A developer app is described by a configuration file; `nagarectl deploy` turns that
config into a running Knative Service accessible over HTTPS. This plan is the final integration
step in a larger initiative (MasterPlan 2) that replaces the original `nagare.yaml` approach
with a typed, compile-checked alternative.

**The five plans this plan depends on.** You need to read at least the Interfaces section of
each:

- `docs/plans/6-nagarectl-deploy-cli-in-haskell.md` (EP-6) — defines the existing
  `cli/nagarectl/` package layout, the modules you will delete or modify, and the fixed
  operational facts (Artifact Registry URL, namespace, cluster access).
- `docs/plans/9-typed-core-deployment-model-and-knative-renderer.md` (EP-9) — defines the
  `nagare-dsl` library at `cli/nagare-dsl/` with `Nagare.Dsl.Types.Deployment` and
  `Nagare.Dsl.Render.renderService`/`renderDomainMapping`. EP-9 must be complete before this
  plan can be implemented.
- `docs/plans/10-config-surface-and-loading-for-the-chosen-substrate.md` (EP-10) — defines
  `Nagare.Dsl.Load.loadDeployment :: FilePath -> IO (Either LoadError Deployment)` and
  `renderLoadError :: LoadError -> Text`. EP-10 must be complete before this plan.
- `docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md` (MasterPlan 2) —
  the parent initiative; Integration Points 3, 4, and 5 are directly relevant.
- `docs/masterplans/1-bootstrap-nagare-personal-paas.md` (bootstrap MasterPlan) — Integration
  Point 6 is the `nagare.yaml` contract this plan supersedes.

**The current state of the codebase.** As of this plan's authoring: the `cli/nagarectl/`
directory exists with only a `.gitkeep` (EP-6 is Not Started — its modules do not yet exist).
The `cli/nagare-dsl/` library is being built by EP-9. The hello example application lives at
`cluster/examples/hello-knative-service/` and currently contains `nagare.yaml`, `service.yaml`,
`domainmapping.yaml`, and a `README.md`.

Because EP-6 has not been implemented yet, this plan is effectively doing EP-6 and the EP-12
cutover together in one pass — building the `cli/nagarectl/` package from scratch in a way
that never uses `nagare.yaml` at all. The EP-6 plan describes what the modules *would have*
contained; this plan builds them to use EP-9's types and EP-10's loader instead.

**Key directory layout.** After this plan completes, the relevant part of the repository looks
like this:

```text
cli/
  nagare-dsl/            -- EP-9's library (Nagare.Dsl.Types, Nagare.Dsl.Render)
    cabal.project        -- references this package; EP-12 does NOT modify this
    nagare-dsl.cabal
    src/Nagare/Dsl/
      Types.hs
      Render.hs
    test/...
  nagarectl/             -- EP-12 builds and wires this package
    cabal.project        -- add ../nagare-dsl as packages: entry
    nagarectl.cabal      -- depends on nagare-dsl, not on yaml/aeson for config
    app/
      Main.hs            -- optparse-applicative CLI; calls loadDeployment + renderService
    src/Nagare/
      Image.hs           -- computeTag/buildImage/configureDockerAuth/pushImage (Deployment)
      Deploy.hs          -- applyManifests/waitForReady/serviceUrl (Deployment)
    test/
      Spec.hs            -- placeholder or integration tests (no Config/Render golden test)

cluster/examples/hello-knative-service/
  <typed-config>         -- e.g. nagare/Config.hs or nagare.dhall (EP-8 substrate choice)
  README.md              -- updated to document the typed config
  service.yaml           -- retained as reference; applied by nagarectl
  domainmapping.yaml     -- retained as reference
  (nagare.yaml DELETED)
```

**Fixed facts from EP-6 that remain unchanged.** These are established operational constants
this plan does not change:

- Artifact Registry URL: `us-west1-docker.pkg.dev/tan-nb-exp/nagare`. Docker auth command:
  `gcloud auth configure-docker us-west1-docker.pkg.dev --quiet`. All `gcloud` targets GCP
  project `tan-nb-exp`.
- Default application namespace: `personal` (also the default in `defaultNamespace` from
  EP-9's `Nagare.Dsl.Types`).
- Service URL shape: `https://<name>.<namespace>.<baseDomain>`, where `baseDomain` defaults
  to `apps.example.com` and is overridable via `--base-domain` or `NAGARE_BASE_DOMAIN`.
  Custom `domain` in the typed config yields `https://<domain>` via the DomainMapping path.
- Cluster access via `KUBECONFIG` (copied from the VM and pointing at the k3s API server).
- Tag computation: UTC timestamp `YYYYMMDD-HHMMSS` unless `--tag` is passed.
- Process orchestration: the `cradle` library (source at
  `/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle`) for all `docker`/`gcloud`/
  `kubectl` shell-outs.

**The `cabal.project` arrangement.** EP-9 established that each package has its own
`cabal.project` (see EP-9's Decision Log). `cli/nagare-dsl/cabal.project` lists only the
`nagare-dsl` package. `cli/nagarectl/cabal.project` must list both the current package (`.`)
and the sibling library (`../nagare-dsl`) under the `packages:` stanza so that `cabal` can
resolve the dependency locally. This is the standard cabal way to depend on a sibling package
in a monorepo.

**What EP-10 provides.** EP-10 implements `Nagare.Dsl.Load` in the `nagare-dsl` library
(same `cli/nagare-dsl/` package). The two functions this plan uses are:

```haskell
loadDeployment  :: FilePath -> IO (Either LoadError Deployment)
renderLoadError :: LoadError -> Text
```

`loadDeployment` takes a path to the typed config file (the chosen substrate), loads and
evaluates it, and returns either a fully-validated `Deployment` (the `Right` branch) or a
`LoadError` describing what went wrong (the `Left` branch). `renderLoadError` converts a
`LoadError` to a human-readable one-line `Text` message suitable for printing to `stderr`.
The `FilePath` defaults to whatever EP-8 selected as the canonical config filename — e.g.
`"nagare/Config.hs"` for the native eDSL substrate or `"nagare.dhall"` for the Dhall
substrate. EP-10 decides and documents this default; EP-12 passes it through from a CLI
option.

**What EP-9 provides.** The renderer is `renderService :: Deployment -> Text -> ByteString`
(the `Text` is the resolved image tag) and `renderDomainMapping :: Deployment -> Maybe
ByteString`. `renderService` produces the Knative `Service` YAML bytes; `renderDomainMapping`
produces a `Just` with the DomainMapping YAML bytes when `depDomain dep` is set, or `Nothing`
when it is absent. These replace the deleted `Nagare.Render` module entirely.

**Toolchain prerequisites.** Run all `cabal` commands from inside the developer shell:
`nix develop` from the repository root. M1 and M3 (build and cutover verification) are fully
offline. M2 (real deploy) requires EP-4's cluster up and reachable, `KUBECONFIG` exported, and
`gcloud` authenticated to `tan-nb-exp`.

> **Haskell standards (binding; see MasterPlan Integration Point 6).** This package is built with **GHC 9.12** pinned through the repository Nix flake and follows the house standards in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`. Every Cabal stanza uses `default-language: GHC2024` and `import: common`, where the `common` stanza enables `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` (and `MultilineStrings` where useful). Modules import the shared `Nagare.Dsl.Prelude` (EP-9) instead of repeating common imports; record types use strict (`!`) unprefixed fields with explicit `deriving stock`/`deriving newtype`/`deriving anyclass` strategies; field access/update uses generic-lens `#label` with lens operators; qualified imports are postpositive. Formatting is `fourmolu` + `cabal-gild` via `treefmt`.


## Plan of Work

The work proceeds in three milestones. M1 builds the rewired `nagarectl` package and proves it
works offline. M2 validates against the live cluster. M3 completes the cutover by migrating
the example app, verifying no `nagare.yaml` remains, testing the failure path, and making the
required amendments to the two MasterPlans.

**Milestone M1 — build nagarectl against nagare-dsl; dry-run works offline.** At the end of
M1, `cli/nagarectl/` is a Cabal package that depends on the sibling `nagare-dsl` library
rather than on its own YAML parser. The modules `Nagare.Config` and `Nagare.Render` do not
exist. `Nagare.Image` and `Nagare.Deploy` are adapted to accept `Deployment` from
`Nagare.Dsl.Types`. `app/Main.hs` calls `loadDeployment` from EP-10 and `renderService` from
EP-9. `cabal build` succeeds, and `nagarectl deploy --dry-run --file <config>` prints the
rendered Knative YAML plus the computed URL to stdout. A `git grep` confirms `Nagare.Config`
no longer appears in any Haskell source file.

Because EP-6 has not been implemented (the `cli/nagarectl/` directory currently has only a
`.gitkeep`), M1 creates the entire `cli/nagarectl/` package from scratch in a form that never
includes `Nagare.Config` or `Nagare.Render`.

**Milestone M2 — end-to-end real deploy (cluster required).** At the end of M2, `nagarectl
deploy` run in the hello example directory (with the migrated typed config) builds and pushes
the hello image to Artifact Registry under a fresh tag, applies the Knative Service and
DomainMapping, waits for readiness, and prints a `https://…` URL. A `curl` to that URL returns
200. This milestone has the same prerequisites as EP-6's M2: an EP-4 cluster, `KUBECONFIG`
exported, and `gcloud` authenticated. Offline reviewers should validate M1 and M3; only M2
requires cluster access.

**Milestone M3 — cutover completeness and MasterPlan amendments.** At the end of M3, the
example app's `nagare.yaml` has been replaced by the typed config, its README updated, and a
`git grep -l nagare.yaml` returns only plan `.md` files (historical references), not any
application config or test fixture. The failure path is verified. The bootstrap MasterPlan's
Integration Point 6 is amended and EP-6's plan file is annotated. The hard cutover is complete.


## Concrete Steps

Run all `cabal` commands from inside `nix develop` (from the repository root). All file paths
are given as absolute paths.


### M1 — Build nagarectl against nagare-dsl

**M1.1 — Create the cabal.project.** Create
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl/cabal.project`:

```cabal
-- cli/nagarectl/cabal.project
--
-- This file tells cabal where to find the nagarectl executable package and
-- its local sibling library nagare-dsl. The ../nagare-dsl entry makes the
-- nagare-dsl Cabal package available without publishing it to Hackage.
--
-- All other dependencies (cradle, optparse-applicative, text, bytestring,
-- time, temp) are resolved from Hackage by default.
--
-- If Hackage is unavailable, add corpus source paths:
--   /Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle
--   /Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project/optparse-applicative
-- Record in Surprises & Discoveries which path was used.
packages:
  .
  ../nagare-dsl
```

**M1.2 — Create nagarectl.cabal.** Create
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl/nagarectl.cabal`. The library stanza
exposes `Nagare.Image` and `Nagare.Deploy` only (the YAML-era `Nagare.Config` and
`Nagare.Render` are absent). Both modules now import from `nagare-dsl`. Notice that `yaml`
and `aeson` are absent — YAML parsing and rendering are entirely in `nagare-dsl`:

```cabal
cabal-version:      3.0
name:               nagarectl
version:            0.1.0.0
synopsis:           Deploy a typed-config Nagare app to Knative with one command.
description:
    nagarectl is the Nagare deploy CLI. It reads a typed configuration file
    (produced by EP-10's loader), renders a Knative Service manifest via the
    nagare-dsl library, builds and pushes a container image, applies the
    manifest, waits for readiness, and prints the live URL.
    The YAML-era nagare.yaml path is fully removed.
build-type:         Simple

common common
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        OverloadedLabels
        OverloadedStrings
    ghc-options: -Wall

library
    import:           common
    hs-source-dirs:   src
    exposed-modules:
        Nagare.Image
        Nagare.Deploy
    build-depends:
        base          >= 4.17 && < 5
      , nagare-dsl
      , text
      , bytestring
      , cradle
      , time
      , temporary

executable nagarectl
    import:           common
    main-is:          Main.hs
    hs-source-dirs:   app
    build-depends:
        base
      , nagarectl
      , nagare-dsl
      , text
      , bytestring
      , optparse-applicative

test-suite nagarectl-test
    import:           common
    type:             exitcode-stdio-1.0
    main-is:          Spec.hs
    hs-source-dirs:   test
    build-depends:
        base
      , nagarectl
      , nagare-dsl
      , text
      , bytestring
```

Notes on the dependency changes from EP-6's original `.cabal`:

- `yaml` and `aeson` are removed from the library stanza — they belonged to the deleted
  `Nagare.Config` (YAML parser) and `Nagare.Render` (YAML builder) modules.
- `nagare-dsl` is added to both the library and executable stanzas.
- `containers` and `unordered-containers` are no longer needed in the library (they were used
  by `Nagare.Config`'s `Map Text EnvValue`; `Deployment` comes fully constructed from EP-10).
- `temporary` replaces `temp` — the standard package name for `System.IO.Temp` on Hackage.
- `GHC2024` is used (matching EP-9 and the house Haskell standards) in place of EP-6's
  `Haskell2010`; the package uses a `common` stanza enabling DeriveAnyClass,
  DuplicateRecordFields, OverloadedLabels, OverloadedStrings. Rewriting `nagarectl`'s cabal
  stanzas from `Haskell2010` to `GHC2024` + `common` is part of the cutover: it brings
  `nagarectl` in line with the house standards and the GHC 9.12 toolchain, matching
  `nagare-dsl`.

**M1.3 — Create src/Nagare/Image.hs.** This is a light adaptation of EP-6's M2.1 spec,
replacing the `NagareConfig`-accepting signatures with `Deployment`-accepting ones. The image
ref is read from `depImage dep` (an `ImageRef` from `Nagare.Dsl.Types`). Create
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl/src/Nagare/Image.hs`:

```haskell
module Nagare.Image
  ( computeTag
  , buildImage
  , configureDockerAuth
  , pushImage
  , imageRef
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Types (Deployment, imageRefText)

registryHost :: String
registryHost = "us-west1-docker.pkg.dev"

-- | Compute a deploy tag: UTC timestamp in YYYYMMDD-HHMMSS format.
computeTag :: IO Text
computeTag = do
  now <- getCurrentTime
  pure (T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now))

-- | The full image reference for a deployment, e.g.
-- @"us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello:20260602-120000"@.
imageRef :: Deployment -> Text -> Text
imageRef dep tag = imageRefText (dep ^. #image) <> ":" <> tag

-- | Run @docker build -t \<image:tag\> \<context\>@.
-- The @context@ argument is the build-context directory (typically @"."@).
buildImage :: Text -> FilePath -> IO ()
buildImage ref context =
  run_ $ cmd "docker" & addArgs ["build", "-t", T.unpack ref, context]

-- | Run @gcloud auth configure-docker us-west1-docker.pkg.dev --quiet@.
-- This writes a Docker credential-helper entry so subsequent pushes authenticate
-- automatically against Artifact Registry.
configureDockerAuth :: IO ()
configureDockerAuth =
  run_ $ cmd "gcloud"
       & addArgs ["auth", "configure-docker", registryHost, "--quiet"]

-- | Run @docker push \<image:tag\>@.
pushImage :: Text -> IO ()
pushImage ref =
  run_ $ cmd "docker" & addArgs ["push", T.unpack ref]
```

**M1.4 — Create src/Nagare/Deploy.hs.** `serviceUrl` now reads `depName`, `depNamespace`,
and `depDomain` from the `Deployment` type rather than from `NagareConfig`. Create
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl/src/Nagare/Deploy.hs`:

```haskell
module Nagare.Deploy
  ( applyManifests
  , waitForReady
  , serviceUrl
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.ByteString qualified as BS
import Data.Text qualified as T
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import Nagare.Dsl.Types
  ( Deployment
  , serviceNameText
  , namespaceText
  , domainText
  )

-- | Apply each manifest by writing it to a temp file and running
-- @kubectl apply -f \<file\>@. Using a temp file (rather than stdin piping)
-- keeps the cradle invocation simple and avoids handle-management complexity.
applyManifests :: [BS.ByteString] -> IO ()
applyManifests = mapM_ applyOne
  where
    applyOne m = withSystemTempFile "nagare-manifest.yaml" $ \fp h -> do
      BS.hPut h m
      hClose h
      run_ $ cmd "kubectl" & addArgs ["apply", "-f", fp]

-- | Run @kubectl wait --for=condition=Ready --timeout=300s ksvc/\<name\> -n \<namespace\>@.
-- Blocks until the Knative Service is Ready or the 5-minute timeout expires.
waitForReady :: Text -> Text -> IO ()
waitForReady name namespace =
  run_ $ cmd "kubectl"
       & addArgs
           [ "wait", "--for=condition=Ready", "--timeout=300s"
           , "ksvc/" <> T.unpack name
           , "-n", T.unpack namespace
           ]

-- | Compute the service URL.
-- If the deployment has a custom domain, returns @https://\<domain\>@.
-- Otherwise returns the Knative wildcard URL:
-- @https://\<name\>.\<namespace\>.\<baseDomain\>@.
-- The @baseDomain@ argument is the resolved base (e.g. @"apps.example.com"@),
-- supplied via @--base-domain@ or the @NAGARE_BASE_DOMAIN@ env var, defaulting
-- to @"apps.example.com"@.
serviceUrl :: Deployment -> Text -> Text
serviceUrl dep baseDomain =
  case dep ^. #domain of
    Just d  -> "https://" <> domainText d
    Nothing ->
      "https://"
        <> serviceNameText (dep ^. #name)
        <> "."
        <> namespaceText (dep ^. #namespace)
        <> "."
        <> baseDomain
```

**M1.5 — Create app/Main.hs.** This is the orchestration entry point. It calls EP-10's
`loadDeployment`, maps errors to a one-line stderr message + exit 1, and on success drives the
build/push/render/apply/wait/URL pipeline. Create
`/Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl/app/Main.hs`:

```haskell
module Main (main) where

import Nagare.Dsl.Prelude

import Control.Monad (forM_, when)
import Data.Maybe (maybeToList)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Render (renderDomainMapping, renderService)
import Nagare.Dsl.Types (serviceNameText, namespaceText)
import Nagare.Deploy (applyManifests, serviceUrl, waitForReady)
import Nagare.Image
  ( buildImage
  , computeTag
  , configureDockerAuth
  , imageRef
  , pushImage
  )

-- ---------------------------------------------------------------------------
-- CLI options

-- | Options for the @deploy@ subcommand. Fields are strict and unprefixed;
-- access is via generic-lens @#label@.
data DeployOpts = DeployOpts
  { file       :: !FilePath
    -- ^ Path to the typed config file. Default supplied by EP-10; e.g.
    -- @"nagare/Config.hs"@ or @"nagare.dhall"@ depending on the substrate.
  , tag        :: !(Maybe String)
    -- ^ Override the auto-computed UTC timestamp tag.
  , baseDomain :: !(Maybe String)
    -- ^ Override the apps base domain; defaults to @NAGARE_BASE_DOMAIN@ env
    -- var, then @"apps.example.com"@.
  , context    :: !FilePath
    -- ^ Docker build-context directory. Default: @"."@.
  , dryRun     :: !Bool
    -- ^ When True, print rendered manifests and URL without running any
    -- external process (build/push/apply/wait).
  }
  deriving stock (Generic, Show)

deployOptsParser :: FilePath -> Parser DeployOpts
deployOptsParser defaultFile =
  DeployOpts
    <$> strOption
          ( long "file" <> short 'f'
          <> metavar "FILE"
          <> value defaultFile
          <> showDefault
          <> help "Path to the typed deployment config file" )
    <*> optional (strOption
          ( long "tag" <> short 't'
          <> metavar "TAG"
          <> help "Image tag override (default: UTC timestamp YYYYMMDD-HHMMSS)" ))
    <*> optional (strOption
          ( long "base-domain"
          <> metavar "DOMAIN"
          <> help "Apps base domain (overrides NAGARE_BASE_DOMAIN env var, default apps.example.com)" ))
    <*> strOption
          ( long "context" <> short 'c'
          <> metavar "DIR"
          <> value "."
          <> showDefault
          <> help "Docker build-context directory" )
    <*> switch
          ( long "dry-run"
          <> help "Print rendered manifests and URL without building, pushing, or applying" )

-- The --file default is the substrate-specific filename chosen by EP-10.
-- Because EP-10's choice is not yet finalized (EP-10 is a dependency), we use
-- a placeholder; when EP-10 is implemented it must document this default and
-- this value should be updated to match. The CLI flag always overrides.
defaultConfigFile :: FilePath
defaultConfigFile = "nagare/Config.hs"   -- update when EP-10 finalises the substrate

cliParser :: Parser DeployOpts
cliParser = deployOptsParser defaultConfigFile

opts :: ParserInfo DeployOpts
opts = info (subparser (command "deploy" deployCmd) <**> helper)
  ( fullDesc
  <> progDesc "nagarectl — deploy a typed Nagare app to Knative" )
  where
    deployCmd = info (cliParser <**> helper)
      ( fullDesc <> progDesc "Build, push, and deploy the app in the current directory" )

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main = do
  dopts <- execParser opts
  runDeploy dopts

runDeploy :: DeployOpts -> IO ()
runDeploy dopts = do
  -- 1. Resolve the base domain from: --base-domain > NAGARE_BASE_DOMAIN > default.
  bd <- resolveBaseDomain (dopts ^. #baseDomain)

  -- 2. Load the typed config. A Left is a fatal error.
  edep <- Load.loadDeployment (dopts ^. #file)
  dep <- case edep of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> Load.renderLoadError err)
      exitFailure
    Right d -> pure d

  -- 3. Compute the image tag.
  imageTag <- case dopts ^. #tag of
    Just t  -> pure (T.pack t)
    Nothing -> computeTag

  let ref      = imageRef dep imageTag
      svcBytes = renderService dep imageTag
      dmBytes  = maybeToList (renderDomainMapping dep)
      url      = serviceUrl dep bd
      name     = serviceNameText (dep ^. #name)
      ns       = namespaceText (dep ^. #namespace)

  -- 4. Dry-run: print and exit.
  when (dopts ^. #dryRun) $ do
    TIO.putStrLn "--- Knative Service manifest ---"
    putStrLn (show svcBytes)   -- replaced with proper UTF-8 print below
    forM_ dmBytes $ \dm -> do
      TIO.putStrLn "--- DomainMapping manifest ---"
      putStrLn (show dm)
    TIO.putStrLn ("URL: " <> url)
    pure ()   -- fall-through; caller should exit after when-block in real impl

  -- 5. Live deploy.
  when (not (dopts ^. #dryRun)) $ do
    configureDockerAuth
    buildImage ref (dopts ^. #context)
    pushImage ref
    applyManifests (svcBytes : dmBytes)
    waitForReady name ns
    TIO.putStrLn ("Deployed: " <> url)

resolveBaseDomain :: Maybe String -> IO Text
resolveBaseDomain (Just bd) = pure (T.pack bd)
resolveBaseDomain Nothing   = do
  menv <- lookupEnv "NAGARE_BASE_DOMAIN"
  pure $ case menv of
    Just bd -> T.pack bd
    Nothing -> "apps.example.com"
```

Important: the dry-run path still needs proper `Data.ByteString.Char8.putStrLn` rather than
`show` (the `show svcBytes` lines above are placeholders). The Concrete Steps section provides
the full corrected source. Note the house style above: `Main.hs` imports the shared
`Nagare.Dsl.Prelude`, uses postpositive qualified imports (`import Nagare.Dsl.Load qualified as
Load`), and reads option/record fields via generic-lens `#label` access rather than record
selectors.

**M1.6 — Create test/Spec.hs stub.** The nagarectl test suite no longer has a golden test for
`Nagare.Config`/`Nagare.Render` (those modules are gone; EP-9's `nagare-dsl-test` is the
authoritative test). Create a minimal stub:

```haskell
module Main (main) where

main :: IO ()
main = putStrLn "nagarectl-test: no unit tests yet (golden tests live in nagare-dsl-test)"
```

**M1.7 — Verify the build.** From `cli/nagarectl/`:

```bash
cabal build
cabal run nagarectl -- --help
```

Expected:

```text
nagarectl — deploy a typed Nagare app to Knative

Usage: nagarectl COMMAND

Available commands:
  deploy                   Build, push, and deploy the app in the current directory
```

**M1.8 — Dry-run proof.** From `cluster/examples/hello-knative-service/` (assuming EP-10's
typed config is in place; for M1 validation against the hello example, provide the config
path explicitly):

```bash
nagarectl deploy --dry-run --file <path-to-typed-config>
```

Expected output (structure; exact YAML depends on the renderer):

```text
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello
  namespace: personal
spec:
  template:
    ...
--- DomainMapping manifest ---
apiVersion: serving.knative.dev/v1beta1
kind: DomainMapping
...
URL: https://hello.personal.apps.example.com
```

**M1.9 — Confirm Nagare.Config is gone.** From the repository root:

```bash
git grep -l "Nagare.Config" -- '*.hs'
```

Expected output: empty (no Haskell source file references `Nagare.Config`). Plan `.md` files
will still reference it historically — that is acceptable; the `-- '*.hs'` scope filter
excludes them.


### M2 — End-to-end real deploy

This milestone requires the EP-4 cluster to be up, `KUBECONFIG` exported per MasterPlan
Integration Point 7, and `gcloud` authenticated to project `tan-nb-exp`. All commands are run
from `cluster/examples/hello-knative-service/` with the migrated typed config in place.

**M2.1 — Run the deploy.** With `KUBECONFIG` set and `gcloud` authenticated:

```bash
nagarectl deploy
```

Expected transcript (abridged):

```text
Configuring Docker auth for us-west1-docker.pkg.dev ...
Building image us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello:20260602-120000 ...
Pushing image ...
Applying manifests ...
Waiting for Ready (up to 300s) ...
service.serving.knative.dev/hello condition met
Deployed: https://hello.personal.apps.example.com
```

**M2.2 — Curl the URL.**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://hello.personal.apps.example.com
```

Expected: `200`. Capture this output as evidence in Outcomes & Retrospective.


### M3 — Cutover completeness and MasterPlan amendments

**M3.1 — Migrate the hello example.** Replace
`cluster/examples/hello-knative-service/nagare.yaml` with the typed config in the substrate
EP-8 chose. The typed config must express the identical deployment: service name `hello`,
namespace `personal`, image `gcr.io/knative-samples/helloworld-go`, domain
`hello.example.com`, port `8080`, env `TARGET=Nagare`, resources `cpu: 250m, memory: 128Mi`,
scale `min: 0, max: 3`.

For the **native eDSL (Config.hs) substrate** (example — adjust to EP-8's actual outcome):

Create `cluster/examples/hello-knative-service/nagare/Config.hs`:

```haskell
-- | Deployment config for the hello-knative-service example.
-- Import this file's top-level 'deployment' value with EP-10's loader.
module Config where

import Data.Map qualified as Map
import Nagare.Dsl.Types

deployment :: Deployment
deployment =
  let Right name  = mkServiceName "hello"
      Right ns    = mkNamespace "personal"
      Right img   = mkImageRef "gcr.io/knative-samples/helloworld-go"
      Right dom   = mkDomain "hello.example.com"
      Right port' = mkPort 8080
      Right en    = mkEnvName "TARGET"
      Right sc    = mkScale 0 3
      Right cpuQ  = mkQuantity "250m"
      Right memQ  = mkQuantity "128Mi"
      res         = Resources { resCpu = Just cpuQ, resMemory = Just memQ }
  in Deployment
       { depName      = name
       , depNamespace = ns
       , depImage     = img
       , depDomain    = Just dom
       , depPort      = port'
       , depEnv       = Map.singleton en (EnvLiteral "Nagare")
       , depResources = Just res
       , depScale     = Just sc
       }
```

For the **Dhall substrate** (example — adjust to EP-8's actual outcome), create
`cluster/examples/hello-knative-service/nagare.dhall`:

```dhall
-- Deployment config for the hello-knative-service example.
let Nagare = <path-to-nagare-dhall-package>

in Nagare.deployment
     { name      = "hello"
     , namespace = "personal"
     , image     = "gcr.io/knative-samples/helloworld-go"
     , domain    = Some "hello.example.com"
     , port      = 8080
     , env       = toMap { TARGET = Nagare.EnvLiteral "Nagare" }
     , resources = Some { cpu = "250m", memory = "128Mi" }
     , scale     = Some { min = 0, max = 3 }
     }
```

After creating the typed config, delete `nagare.yaml`:

```bash
rm /Users/shinzui/Keikaku/bokuno/nagare/cluster/examples/hello-knative-service/nagare.yaml
```

Update the `README.md` in that directory to document the typed config instead of `nagare.yaml`.
The updated README should:

- Explain that the deployment is described in `nagare/Config.hs` (or `nagare.dhall`) instead
  of `nagare.yaml`, and why (type safety: invalid names, conflated env entries, `max < min`
  are now compile-time errors rather than cluster rejections).
- Show how to run `nagarectl deploy --dry-run` to preview the manifest.
- Retain the existing kubectl-based deploy/test/cleanup instructions (they still work, as the
  `service.yaml` and `domainmapping.yaml` reference files are unchanged).

**M3.2 — Verify no nagare.yaml remains.** From the repository root:

```bash
git grep -l nagare.yaml
```

Expected output: only plan `.md` files (e.g.
`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`,
`docs/masterplans/1-bootstrap-nagare-personal-paas.md`,
`docs/plans/12-nagarectl-integration-and-full-yaml-cutover.md`) — no app directories, no test
fixtures, no Haskell source files. If any other path appears, that file must be updated or
deleted.

**M3.3 — Verify the failure path.** Create a broken config file for this test (do not delete
it afterward — keep it as a test fixture at e.g.
`cli/nagarectl/test/fixtures/broken-config.hs`):

For the native eDSL substrate, create a file that exports `deployment` but uses an invalid
service name:

```haskell
-- Broken config: invalid service name (uppercase) — loadDeployment should return Left.
module Config where
import Nagare.Dsl.Types
deployment :: Either Text Deployment
deployment = fmap (\_ -> error "unreachable") (mkServiceName "INVALID NAME")
```

Then run:

```bash
nagarectl deploy --file cli/nagarectl/test/fixtures/broken-config.hs --dry-run
echo "Exit code: $?"
```

Expected: stderr shows a one-line message like
`nagarectl: invalid service name: INVALID NAME` and exit code 1.

The exact message depends on EP-10's `renderLoadError` implementation. Adjust the expectation
accordingly and record the actual message in Surprises & Discoveries.

**M3.4 — Amend the bootstrap MasterPlan.** Edit
`docs/masterplans/1-bootstrap-nagare-personal-paas.md`. Locate Integration Point 6. Replace
the body of that section (which currently contains the `nagare.yaml` YAML schema block and
description) with the following text, preserving the `**6. ...`  heading:

```text
**6. The application deployment contract (originally the `nagare.yaml` schema owned by EP-6;
superseded by the Haskell DSL initiative).** This integration point originally defined the
`nagare.yaml` YAML schema that EP-6 parsed and rendered. That YAML contract has been fully
replaced by the typed deployment DSL initiative tracked in
`docs/masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md`. The new contract is
a typed configuration file in the substrate chosen by EP-8 of that initiative; the canonical
deployment type is `Nagare.Dsl.Types.Deployment` defined in `cli/nagare-dsl/`. The cutover
was performed by EP-12 (`docs/plans/12-nagarectl-integration-and-full-yaml-cutover.md`), which
deleted `Nagare.Config` and `Nagare.Render` from `cli/nagarectl/` and replaced the example
app's `nagare.yaml` with the typed config. No `nagare.yaml` file exists anywhere in the
repository after that cutover.
```

Also append a revision note at the bottom of the bootstrap MasterPlan file:

```text
## Revision note (EP-12, 2026-06-03)

Integration Point 6 was amended to record the supersession of the `nagare.yaml` contract
by the typed Haskell DSL initiative (MasterPlan 2, EP-12). The YAML schema block was
replaced with a forward reference. No other integration points were affected. The EP-6
registry row is unchanged (EP-6 is the package that was modified; EP-12 performed the
cutover).
```

**M3.5 — Amend EP-6.** Append a revision note at the bottom of
`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`:

```text
## Revision note (EP-12, 2026-06-03)

EP-12 (`docs/plans/12-nagarectl-integration-and-full-yaml-cutover.md`) performed the hard
cutover described in MasterPlan 2 Integration Point 4. The modules `Nagare.Config`
(YAML parser, `NagareConfig` record) and `Nagare.Render` (YAML renderer from `NagareConfig`)
were never implemented and are now explicitly retired — they must not be created. The
`cli/nagarectl/` package instead depends on `nagare-dsl` and calls
`Nagare.Dsl.Load.loadDeployment` (EP-10) and `Nagare.Dsl.Render.renderService` (EP-9).
`Nagare.Image` and `Nagare.Deploy` were implemented to accept `Nagare.Dsl.Types.Deployment`
rather than `NagareConfig`. The golden test in EP-6's M1.5 (which tested `Nagare.Config` and
`Nagare.Render`) was not created; the authoritative golden test lives in `nagare-dsl-test`
(EP-9 M3.3–M3.5). All other EP-6 milestones (M2, M3) are unchanged in intent — the live
deploy, secrets, and custom domain paths work identically, only the config-loading path is
different.
```


## Validation and Acceptance

Acceptance is behavioral. Three gates must all pass.

**Gate 1 — offline build and dry-run (M1).** From `cli/nagarectl/`:

```bash
cabal build
cabal run nagarectl -- --help
```

Both succeed with no errors. Then, with a valid typed config file:

```bash
nagarectl deploy --dry-run --file <config-path>
```

Prints the Knative Service YAML and the computed URL to stdout, exits 0. Then:

```bash
git grep -l "Nagare.Config" -- '*.hs'
```

Returns empty. These three checks together prove: the package builds against `nagare-dsl`; the
deploy command works end-to-end in dry-run mode; and the YAML parser module is gone.

**Gate 2 — live deploy (M2, requires cluster).** From the example app directory with a live
cluster and valid `KUBECONFIG`:

```bash
nagarectl deploy
```

Prints a `https://` URL. Then:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' <url>
```

Returns `200`. Capture the full transcript as evidence.

**Gate 3 — cutover completeness (M3, offline).** Run from the repository root:

```bash
git grep -l nagare.yaml
```

Output contains only plan `.md` files, no app dirs or Haskell source files. Then run the
failure-path test:

```bash
nagarectl deploy --file cli/nagarectl/test/fixtures/broken-config.hs --dry-run
echo "Exit: $?"
```

`stderr` shows a one-line `nagarectl: <message>` and exit code is non-zero. Finally, open
`docs/masterplans/1-bootstrap-nagare-personal-paas.md` and confirm Integration Point 6 no
longer contains the YAML schema block; open `docs/plans/6-nagarectl-deploy-cli-in-haskell.md`
and confirm the revision note at the bottom.

To run all three offline checks in sequence:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl && cabal build \
  && cabal run nagarectl -- --help \
  && git -C ../.. grep -l "Nagare.Config" -- '*.hs' | diff - /dev/null \
  && echo "GATE 1 PASSED"
```

```bash
git grep -l nagare.yaml -- ':!docs/plans' ':!docs/masterplans' \
  | diff - /dev/null && echo "GATE 3 (no-yaml) PASSED"
```


## Idempotence and Recovery

`cabal build` and `cabal test` are idempotent — they can be re-run any number of times. If a
build fails because `nagare-dsl` is not yet in the `cabal.project`, add the `../nagare-dsl`
entry and re-run.

Deleting `src/Nagare/Config.hs` and `src/Nagare/Render.hs` is irreversible if they were
already implemented by EP-6. Because EP-6 is currently Not Started (the directory is a
`.gitkeep`), deletion means "never create these files." If for any reason EP-6 was partially
implemented before EP-12, recover the deleted source from `git log` with `git show
<commit>:cli/nagarectl/src/Nagare/Config.hs` before proceeding.

Replacing `nagare.yaml` in the example app is reversible via `git restore`. If the typed
config is incomplete and `nagarectl deploy` fails, the fallback is to apply `service.yaml`
directly with `kubectl apply -f cluster/examples/hello-knative-service/service.yaml` — that
file is unchanged and still correct.

Amending the bootstrap MasterPlan and EP-6 is a text edit and safe to re-do. Use `git diff`
to review the amendment before committing.

If `loadDeployment` does not yet exist (EP-10 not implemented), stub it temporarily:

```haskell
-- Temporary stub in Main.hs until EP-10 is complete:
loadDeployment :: FilePath -> IO (Either Text Deployment)
loadDeployment _ = pure (Left "EP-10 not yet implemented")
```

This lets M1 compile checks proceed; replace with the real import when EP-10 lands.


## Interfaces and Dependencies

**Libraries this plan adds to nagarectl.**

- `nagare-dsl` (the sibling package at `cli/nagare-dsl/`, available via `cabal.project`
  `packages:` entry) — provides `Nagare.Dsl.Types` (the `Deployment` type and all field
  types), `Nagare.Dsl.Render` (`renderService`, `renderDomainMapping`), and `Nagare.Dsl.Load`
  (`loadDeployment`, `renderLoadError`). This is the reason `yaml`/`aeson` are removed from
  the `nagarectl` library stanza.
- `cradle` (corpus at `/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle`) — unchanged
  from EP-6's decision; used by `Nagare.Image` and `Nagare.Deploy` for process orchestration.
- `optparse-applicative` (corpus at
  `/Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project/optparse-applicative`) —
  unchanged from EP-6's decision; used by `app/Main.hs`.
- `text`, `bytestring`, `time`, `temporary` — unchanged supporting libraries.

**Libraries removed from nagarectl.**

- `yaml` (was `Data.Yaml.decodeFileEither` in `Nagare.Config`) — deleted module; rendering
  now happens in `nagare-dsl`.
- `aeson` (was `Data.Aeson.Value` building in `Nagare.Render`) — deleted module.
- `containers`, `unordered-containers` (were `Map Text EnvValue` in `Nagare.Config`) —
  `Deployment`'s `depEnv :: Map EnvName EnvVar` lives in `nagare-dsl`.

**Types and function signatures that must exist at the end of each milestone** (full module
paths):

From EP-9 (`Nagare.Dsl.Types`, `Nagare.Dsl.Render`) — must already exist when this plan runs:

```haskell
-- Nagare.Dsl.Types
data Deployment = Deployment
  { depName      :: ServiceName
  , depNamespace :: Namespace
  , depImage     :: ImageRef
  , depDomain    :: Maybe Domain
  , depPort      :: Port
  , depEnv       :: Map EnvName EnvVar
  , depResources :: Maybe Resources
  , depScale     :: Maybe Scale
  }
serviceNameText  :: ServiceName -> Text
namespaceText    :: Namespace   -> Text
imageRefText     :: ImageRef    -> Text
domainText       :: Domain      -> Text
defaultNamespace :: Namespace   -- = Namespace "personal"

-- Nagare.Dsl.Render
renderService       :: Deployment -> Text -> ByteString
renderDomainMapping :: Deployment -> Maybe ByteString
```

From EP-10 (`Nagare.Dsl.Load`) — must already exist when this plan runs:

```haskell
loadDeployment  :: FilePath -> IO (Either LoadError Deployment)
renderLoadError :: LoadError -> Text
```

Defined by this plan in `cli/nagarectl/`:

```haskell
-- Nagare.Image
computeTag         :: IO Text
imageRef           :: Deployment -> Text -> Text
buildImage         :: Text -> FilePath -> IO ()
configureDockerAuth :: IO ()
pushImage          :: Text -> IO ()

-- Nagare.Deploy
applyManifests :: [ByteString] -> IO ()
waitForReady   :: Text -> Text -> IO ()
serviceUrl     :: Deployment -> Text -> Text
```

**The `cabal.project` arrangement.** `cli/nagarectl/cabal.project` must contain exactly:

```cabal
packages:
  .
  ../nagare-dsl
```

This makes `nagarectl`'s build see the `nagare-dsl` package from the sibling directory. No
changes are required to `cli/nagare-dsl/cabal.project`.

**Services and endpoints consumed.** Unchanged from EP-6: Artifact Registry
`us-west1-docker.pkg.dev/tan-nb-exp/nagare`; Docker auth via `gcloud auth configure-docker
us-west1-docker.pkg.dev`; the k3s cluster via `kubectl` with `KUBECONFIG`; Knative
`serving.knative.dev/v1` and `serving.knative.dev/v1beta1` APIs; default namespace `personal`;
URL shape `https://<name>.<namespace>.<baseDomain>` with `baseDomain` defaulting to
`apps.example.com`.

**The example app migration.** The in-repo test artifact is
`cluster/examples/hello-knative-service/`. After M3.1, this directory contains the typed
config (whatever EP-8 chose) and no `nagare.yaml`. The pre-rendered `service.yaml` and
`domainmapping.yaml` files in that directory are kept as reference manifests (they can still
be applied directly with `kubectl apply` for manual testing without the CLI).
