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

Full plan before trimming: [12-nagarectl-integration-and-full-yaml-cutover.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/12-nagarectl-integration-and-full-yaml-cutover.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M1.1 `cli/nagarectl/cabal.project` lists `.`, `../nagare-dsl`, and the `cradle` corpus path (cradle is not on Hackage); `write-ghc-environment-files: always` materialises the env the loader's `runghc` needs. _(2026-06-03)_
- [x] M1.2 `cli/nagarectl/nagarectl.cabal` depends on `nagare-dsl`; `yaml`/`aeson`/`containers` are absent (rendering/parsing live in `nagare-dsl`); `lens`/`generic-lens`/`directory` added for `#label` access and path handling; `GHC2024` + `common` stanza. _(2026-06-03)_
- [x] M1.3 `Nagare.Config` never created (EP-6 Not Started) — N/A by construction; the package never contains a YAML parser. _(2026-06-03)_
- [x] M1.4 `Nagare.Render` never created — N/A by construction; rendering is EP-9's `Nagare.Dsl.Render`. _(2026-06-03)_
- [x] M1.5 `exposed-modules` is `Nagare.Image`, `Nagare.Deploy` only. _(2026-06-03)_
- [x] M1.6 `cli/nagarectl/src/Nagare/Image.hs` accepts `Deployment`; `imageRef` reads `dep ^. #image` via `imageRefText`. _(2026-06-03)_
- [x] M1.7 `cli/nagarectl/src/Nagare/Deploy.hs` accepts `Deployment`; `serviceUrl` reads `#name`/`#namespace`/`#domain` (house unprefixed fields, not `depName`). _(2026-06-03)_
- [x] M1.8 `cli/nagarectl/app/Main.hs` deploy flow: `loadDeployment` → `Left` handled with `renderLoadError` + exit 1; `Right` → tag/build/auth/push/render/apply/wait/URL; `--dry-run` prints manifests (via `Data.ByteString.Char8.putStr`) + URL with no side effects. _(2026-06-03)_
- [x] M1.9 No EP-6 golden test existed to remove; `nagare-dsl-test` is authoritative. The `nagarectl-test` suite is a stub. _(2026-06-03)_
- [x] M1.10 `cabal build` succeeds from `cli/nagarectl/`; `nagarectl --help` shows the `deploy` subcommand; `nagarectl-test` passes. _(2026-06-03)_
- [x] M1.11 `nagarectl deploy --dry-run --file .../nagare/Config.hs` prints the Knative Service + DomainMapping YAML (byte-identical to EP-9's golden bar the timestamp tag) and `URL: https://hello.example.com`; `git grep -l "Nagare\.Config" -- '*.hs'` is empty. _(2026-06-03)_
- [x] M2.1 **DEFERRED** — live deploy needs the EP-4 cluster + `KUBECONFIG` + `gcloud` auth to `tan-nb-exp`; `nagare-01` is currently TERMINATED (powered down to halt charges, per the bootstrap MasterPlan). Run once the cluster is brought back up. (2026-10-17: a typed `nagare/Config.hs` application was deployed live with `app deploy`, the reviewed successor of `nagarectl deploy`, on cloud context `mp23-c3l`; [section 4 drill](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/README.md), setup phase; [checklist §4](../releases/production-readiness-checklist.md).)
- [x] M2.2 **DEFERRED** — `curl` the printed URL → 200, after M2.1. (2026-10-17: the same drill's setup requires `curl` HTTP 200 on `/` and on five `/add` writes before `PHASE-OK setup`; [driver](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/s4-drill.sh), [setup log](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/logs/phase-setup.log).)
- [x] M3.1 `cluster/examples/hello-knative-service/nagare.yaml` replaced by typed `nagare/Config.hs` (same deployment: name/ns/image/domain/port/env/resources/scale); README rewritten to document the typed config and `--dry-run` preview. _(2026-06-03)_
- [x] M3.2 No application config / source / test fixture references `nagare.yaml`: `git grep -l nagare.yaml -- ':!docs' ':!*.md'` is empty; remaining matches are markdown docs (historical + supersession notes). The vestigial `cli/nagare-dsl/test/golden/hello.nagare.yaml` (unreferenced by any test) was removed. _(2026-06-03)_
- [x] M3.3 Failure path: `nagarectl deploy --file test/fixtures/broken-config.hs` prints `nagarectl: nagare: compile error in ...: ... service name contains invalid characters ... INVALID NAME` on stderr and exits 1. _(2026-06-03)_
- [x] M3.4 Bootstrap MasterPlan Integration Point 6 amended in-place (YAML schema block replaced by a supersession note pointing at MasterPlan 2 / EP-12) + a revision note appended. _(2026-06-03)_
- [x] M3.5 EP-6 (`docs/plans/6-...`) annotated with a revision note: `Nagare.Config`/`Nagare.Render` retired, package depends on `nagare-dsl`, example migrated. _(2026-06-03)_
- [x] Final: Progress, Surprises & Discoveries, Decision Log, and Outcomes updated; MasterPlan EP-12 registry row + Progress updated. _(2026-06-03; M2 live validation deferred.)_

## Surprises & Discoveries

- **The plan's code samples were pre-house-standard.** This plan was authored before MasterPlan 2's
  revision adopting the house Haskell standards, so its `Image.hs`/`Deploy.hs`/`Main.hs` and the
  migrated `Config.hs` samples used prefixed fields (`depName`, `Resources { resCpu }`) and
  `mkServiceName "..."` record literals. The *actual* EP-9 `Nagare.Dsl.Types.Deployment` uses
  **unprefixed strict fields** (`name`, `namespace`, `image`, `domain`, `port`, `env`, `resources`,
  `scale`) read via generic-lens `#label`, `Resources {cpu, memory}`, and `Scale {minScale,
  maxScale}`. The implementation followed the real types, not the stale samples. (2026-06-03)

- **Loader package-environment provisioning is EP-12's to own (flagged by EP-10's Decision Log).**
  EP-10's `loadDeployment` runs the app's `Config.hs` with `runghc -XGHC2024 -i<dir>`, which resolves
  `nagare-dsl` only if GHC finds a package environment. `runghc` discovers a `.ghc.environment.*` by
  walking up from its working directory. Resolution: `cli/nagarectl/cabal.project` sets
  `write-ghc-environment-files: always` (so an env file exists in `cli/nagarectl/`), and `nagarectl`
  gained a `--ghc-env FILE` flag / `NAGARE_GHC_ENVIRONMENT` env var that, when set, exports
  `GHC_ENVIRONMENT` (absolute) for the loader's child process. Running `nagarectl` from
  `cli/nagarectl/` needs no flag; running from an app directory needs `--ghc-env <built env file>`.
  The standalone-binary production story (a self-contained package DB on the deploy VM) is still to
  be built when M2's live deploy is exercised. (2026-06-03)

- **`cradle` is not on Hackage.** Unlike the other deps (optparse-applicative, temporary, time,
  directory, lens, generic-lens — all in the cached Hackage index), `cradle` (garnix-io/cradle,
  v0.0.0.0) is only in the local corpus, so its source path
  (`/Users/shinzui/Keikaku/hub/haskell/cradle-project/cradle`) is listed directly in
  `cabal.project`'s `packages:`. Its API is `cmd :: String -> ProcessConfiguration`,
  `addArgs :: ConvertibleStrings s String => [s] -> ...`, `run_ :: MonadIO m => ... -> m ()`; `&`
  comes from `Control.Lens` via `Nagare.Dsl.Prelude`. (2026-06-03)

- **fourmolu 0.19 is not clean against the existing `cli/` tree.** The MasterPlan deferred "wiring a
  treefmt config for the cli/ tree" to EP-12. The house template's `fourmolu.yaml` uses
  `comma-style: trailing`, but the completed EP-9/EP-10/EP-11 modules use **leading** commas and keep
  `) where` on one line — neither of which the pinned fourmolu 0.19.0.1 reproduces. Forcing a
  tree-wide reformat would churn completed plans' code. Resolution: added `cli/fourmolu.yaml`
  calibrated to the prevailing style (leading commas, single-line `-- |` haddocks) so it is a no-op
  for existing files except the unconfigurable `)`/`where` line break; new `nagarectl` modules were
  hand-written to match the package's visual style. `cabal-gild` (which uses `--io`, not positional
  args, so it does not fit treefmt's formatter model) was run directly on `nagarectl.cabal`. A full
  treefmt wiring remains a follow-up. (2026-06-03)

- **EP-6 was Not Started, so M1 built `cli/nagarectl/` from scratch.** There were no `Nagare.Config`
  or `Nagare.Render` modules to delete (M1.3–M1.5, M1.9 are N/A by construction); the package was
  created directly in its post-cutover shape. (2026-06-03)

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

- Decision: `nagarectl` provisions the loader's GHC package environment via a `--ghc-env FILE`
  option (and `NAGARE_GHC_ENVIRONMENT` env var) that exports `GHC_ENVIRONMENT` for the child
  `runghc`, rather than changing EP-10's fixed `loadDeployment :: FilePath -> IO (Either LoadError
  Deployment)` signature (Integration Point 3).
  Rationale: EP-10's loader resolves `nagare-dsl` only when `runghc` finds a package environment;
  EP-10's own Decision Log hands "production package-env provisioning" to EP-12. Setting an
  environment variable in `nagarectl`'s process (inherited by the `runghc` child) keeps Integration
  Point 3 stable and untouched while giving the operator explicit control. With no flag, `runghc`
  falls back to discovering a `.ghc.environment.*` upward from its working directory — which is why
  running `nagarectl` from `cli/nagarectl/` (where `write-ghc-environment-files: always` left one)
  works with zero configuration.
  Date: 2026-06-03

- Decision: keep `nagare.yaml`-mentioning *historical* documents (the plan/masterplan `.md` files,
  `docs/initial-spec.md`) as-is, and update only the *current-behavior* surfaces (root `README.md`,
  the example `README.md`, `mori.dhall`, `justfile`, `docs/runbooks/disaster-recovery.md`) plus the
  two stale comments in `nagare-dsl`'s test tree. The vestigial unreferenced golden
  `cli/nagare-dsl/test/golden/hello.nagare.yaml` was removed.
  Rationale: M3.2's intent is that no live app config, source, or active test fixture references the
  YAML contract — verified by `git grep -l nagare.yaml -- ':!docs' ':!*.md'` being empty. The
  initial-spec is a frozen design snapshot and the plan docs are historical record; rewriting them
  would falsify the project's history. Adoption of this initiative (signalled by starting EP-12 per
  MasterPlan 2's Decision Log) authorises updating the bootstrap-level current-behavior docs.
  Date: 2026-06-03

- Decision: mark EP-12 Complete on the strength of the offline cutover (M1 + M3, all verified), with
  M2's live deploy explicitly deferred and tracked, rather than holding EP-12 open.
  Rationale: every implementation deliverable is done and verified offline — the package builds, the
  dry-run renders byte-identically to EP-9's golden, the failure path exits 1, and no live
  `nagare.yaml` remains. M2 is a *validation* milestone blocked solely by powered-down infrastructure
  (`nagare-01` is TERMINATED to halt charges); it is not partial implementation. The deferral is
  recorded in Progress (M2.1/M2.2), Outcomes, and the MasterPlan so the live check is not forgotten.
  Date: 2026-06-03

## Outcomes & Retrospective

The hard cutover is complete and verified offline. Against the Purpose / Big Picture:

- **`nagarectl deploy --dry-run` works with no YAML parser.** `cli/nagarectl/` is a Cabal package
  depending on `nagare-dsl`; it has no `Nagare.Config`/`Nagare.Render` and no `yaml`/`aeson` deps.
  `nagarectl deploy --dry-run --file cluster/examples/hello-knative-service/nagare/Config.hs`
  compiles-and-runs the typed config through EP-10's `loadDeployment`, renders via EP-9's
  `renderService`/`renderDomainMapping`, and prints the Service + DomainMapping YAML plus
  `URL: https://hello.example.com`. The rendered Service is byte-identical to EP-9's golden
  (`hello.service.yaml`) except the timestamp image tag. Exit 0.
- **Illegal configs fail before the cluster.** `nagarectl deploy --file test/fixtures/broken-config.hs`
  (service name `"INVALID NAME"`) prints `nagarectl: nagare: compile error in ...: ... service name
  contains invalid characters (allowed: a-z, 0-9, -): INVALID NAME` to stderr and exits 1.
- **No `nagare.yaml` remains as live config.** The example app carries `nagare/Config.hs`;
  `git grep -l nagare.yaml -- ':!docs' ':!*.md'` is empty. Remaining matches are markdown
  (historical plan/spec docs + supersession notes in the two READMEs / mori.dhall / justfile /
  runbook).
- **Both test suites green.** `nagare-dsl-test` (63 tests, incl. 5 QuickCheck properties) and the
  `nagarectl-test` stub pass under GHC 9.12.3.
- **MasterPlans reconciled.** Bootstrap MasterPlan Integration Point 6 amended in-place + revision
  note; EP-6 annotated with a retirement revision note.

**Deferred:** M2 (live deploy + `curl` 200). It requires the EP-4 cluster, which is powered down
(`nagare-01` TERMINATED to halt charges). When the cluster is brought back up, run `nagarectl deploy`
in the example dir (with `KUBECONFIG` and `gcloud` authed to `tan-nb-exp`) and `curl` the URL; the
standalone-binary package-environment provisioning (so the loader's `runghc` resolves `nagare-dsl`
without the dev tree) is the one remaining piece to harden at that point — `--ghc-env` /
`NAGARE_GHC_ENVIRONMENT` is the seam it plugs into.

**Substrate ergonomics vs. the spike's prediction:** the config-as-program model held up — the
example `Config.hs` reads cleanly, smart-constructor failures surface as precise load-time errors,
and the only operational wrinkle (the spike's predicted cost of "the deploy machine must carry GHC")
showed up exactly as the package-environment provisioning concern above.

