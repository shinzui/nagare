---
id: 69
slug: ci-pipeline-and-live-smoke-test
title: "CI Pipeline and Live Smoke Test"
kind: exec-plan
created_at: 2026-06-11T02:37:50Z
intention: "intention_01ktt8he4vepkb0gbp2k9z5fc3"
master_plan: "docs/masterplans/13-live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration.md"
---

# CI Pipeline and Live Smoke Test

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

MasterPlan: docs/masterplans/13-live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration.md


## Purpose / Big Picture

Today this repository has **no continuous integration of any kind**. There is no
`.github/` directory, no workflow, and nothing that runs the Haskell test suites or
even type-checks the shipped example configurations on a push or a pull request. The
cost of that gap was made concrete during the 2026-06-10 live audit: three of the
example application descriptors under `cluster/examples/*/nagare/Config.hs` had
**silently stopped compiling** against the current typed DSL, and nobody noticed,
because the only thing that exercised the DSL was the unit test suite, and the unit
test suite compiles its *own* fixtures (under `cli/nagare-dsl/test/fixtures/` and
`cli/nagarectl/test/fixtures/`), **not** the example configs that ship to users. The
examples are the documentation; when they rot, the documentation lies. Separately,
every *live* behavior — actually deploying an app to the cluster, snapshotting a
volume, restoring it — had been deferred for weeks behind a powered-off virtual
machine, so real defects (a missing GCS-auth helper that returned `401 Anonymous`, a
cluster that could not pull its own private images) hid in the dark until the audit
flushed them out.

After this change, a contributor gains two things they do not have today. First, an
**offline CI** that runs on every push and pull request and **fails the build** if any
example `Config.hs` no longer compiles, if either Haskell test suite has a failing
test, or if the Haskell sources are not formatted to the house style. This is the
regression net that would have caught the three rotted examples the instant they
broke. You will be able to see it working by opening a pull request and watching a
GitHub check named *CI* go green on a clean tree and red the moment you introduce a
type error into any example. Second, a **live smoke test** — run on demand, not on
every pull request — that drives the real end-to-end path: it starts the virtual
machine if it is stopped, deploys a private-registry build-mode application, snapshots
one of its volumes and **restores** that snapshot, confirms the application answers an
HTTP request with status 200, and tears everything down. That smoke test exercises
exactly the paths that were dark for weeks, so a future regression in any of them
surfaces in minutes rather than after a multi-week audit.

The single most important design decision, already made and recorded in this plan's
Decision Log, is that **the CI logic lives in Nix flake checks, which are the source
of truth, and GitHub Actions is only a thin shell that installs Nix and runs them.**
That means the *exact* checks CI runs are runnable on a contributor's laptop with one
command, `nix flake check`, with no GitHub account, no hosted runner, and no
divergence between "what CI does" and "what I can reproduce locally." Local and hosted
behavior are identical by construction because they invoke the same derivations.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

Status: **Complete** — flake checks (build+test both packages, example-compile guard, shellcheck) pass; thin CI + manual live-smoke workflows authored; the live smoke passed end-to-end against `nagare-01`.

- [x] M1.1: `checks.nagare-dsl-build-test` builds + tests `nagare-dsl` (`nagare-dsl-test`).
- [x] M1.2: `checks.nagarectl-build-test` builds + tests `nagarectl` (`nagarectl-test`).
- [x] M1.3: `checks.examples-compile` compiles-and-runs every `cluster/examples/*/nagare/Config.hs` via `cabal exec -- runghc -XGHC2024 -i<dir>` (all 19 currently compile).
- [~] M1.4: `fourmolu-format` **intentionally omitted** — the pinned fourmolu 0.19.x reformats 82/93 committed files (a version drift, not contributor misformatting), so the check would be red on a clean tree. Recorded in Surprises with the follow-up.
- [x] M1.5: `checks.shellcheck-scripts` runs `shellcheck --severity=error` over `scripts/*.sh` (clean on the tree; SC1091/SC2034 are info/warning, not errors).
- [x] M1.6: `nix flake check` passes on a clean tree (network via `__noChroot`; macOS sandbox off locally, `sandbox = relaxed` on CI). The fix that the from-scratch derivation exposed (`cabal build` before `cabal test`, so the loader tests' `.ghc.environment.*` is materialised) is in place.
- [x] M2.1: `.github/workflows/ci.yml` — a thin workflow that installs Nix (`sandbox = relaxed`) and runs `nix flake check`.
- [~] M2.2: Authored. The GitHub-side "observe the *CI* check go green" needs a push to GitHub (not done here); the `nix flake check` it wraps is verified locally, so the hosted run is green-by-construction.
- [x] M3.1: `just smoke` recipe + `scripts/live-smoke.sh` orchestrate the real scenario.
- [x] M3.2: `.github/workflows/live-smoke.yml` gated on `workflow_dispatch` only.
- [x] M3.3: Implemented the **real** scenario (not a stub) — all soft deps EP-1/EP-2/EP-3/EP-6 are landed.
- [x] M3.4: Ran end-to-end against the live VM; transcript recorded in Outcomes (deploy → snapshot → restore → HTTP 200 → teardown; `live smoke: OK`).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The repository has **two** flake files: the root `flake.nix` (the developer shell —
  Pulumi, the GHC 9.12 toolchain, cloud tooling) and `nixos/flake.nix` (the NixOS host
  image for `nagare-01`). The Haskell project itself is **not** flake-managed as a
  package: each Haskell package carries its own per-directory `cabal.project`
  (`cli/nagare-dsl/cabal.project`, `cli/nagarectl/cabal.project`), and the root
  `flake.nix` exposes only `devShells`, no `packages` and no `checks`. This plan adds
  the first `checks` output, and it adds it to the **root** flake (justification in the
  Decision Log).

- The fourmolu configuration the MasterPlan brief referred to as
  `cli/nagarectl/fourmolu.yaml` **does not exist**. There is a single shared
  `cli/fourmolu.yaml` that covers the whole `cli/` tree (both `nagare-dsl` and
  `nagarectl`); see the header comment in that file. The format check therefore runs
  one fourmolu invocation rooted at `cli/`, not two. (Recorded here so a future
  contributor does not go looking for a second config file.)

- Every shipped example under `cluster/examples/*/nagare/Config.hs` is a `Main` module
  that emits its JSON via one of `Nagare.Dsl.Config.emit{Deployment,StaticSite,ServerSite}`.
  There are **no** standalone database or task example configs under
  `cluster/examples/` (a search for `emitDatabase`/`emitTask` returns nothing), so the
  example-compile guard's universe is exactly the 19 `cluster/examples/*/nagare/Config.hs`
  files. The guard must still glob, not hard-code the list, so newly added examples are
  covered automatically.

- **(M1, 2026-06-11) The `fourmolu-format` check is omitted (version drift).** The dev shell pins
  fourmolu 0.19.0.1, which interprets `cli/fourmolu.yaml` differently than the older fourmolu that
  last formatted the tree — `fourmolu --mode check` reports **82 of 93** committed `.hs` files as
  unformatted (e.g. `) where` → `)\n where`, import reordering), none caused by this initiative.
  Wiring the check would make CI red on a clean tree (the very "false FAIL trains people to ignore
  red" antipattern EP-4 removed). Follow-up: either re-pin fourmolu to the version that formatted the
  tree, or do a one-time tree-wide `fourmolu --mode inplace` reformat in a dedicated commit, then add
  the check. The other three checks (build+test ×2, example-compile) are the regression net the audit
  actually needed; `shellcheck --severity=error` is included and clean.

- **(M1, 2026-06-11) `nix flake check` exposed a fragility the dev shell hid.** Running the checks in
  a from-scratch Nix derivation (git tree only — `.ghc.environment.*` is gitignored, so absent)
  surfaced that 7 `nagare-dsl-test` loader tests (`loadServerSite`/`loadSite`) fail: they shell out
  to `runghc` on a fixture and need a `.ghc.environment.*` file present, which `cabal test`'s implicit
  build does NOT write — only an explicit `cabal build`. Fix: the build/test checks run `cabal build
  all` before `cabal test`, materialising the env file. (This is the same GHC-env class of issue EP-6
  fixed for `nagarectl`; the `nagare-dsl` loader has no auto-resolution.) `nix flake check` is green
  after the fix.

- **(M3, 2026-06-11) The live smoke test caught a REAL latent defect — exactly its purpose.** The
  first run deployed (built amd64, pushed to private AR) but the pod stuck `ImagePullBackOff` /
  `401 Unauthorized`: EP-2's token-refresh timer rewrote `registries.yaml` but containerd never
  reloaded it (k3s loads it only at start). Root-caused and fixed in EP-2's `registries.nix` (a
  timer-driven `systemctl restart k3s`); see
  `docs/plans/66-...` Surprises. After the fix the smoke passed end-to-end. This is precisely the
  dark-path regression the smoke test exists to surface — it paid for itself on its first real run.

- **(M3, 2026-06-11) Smoke flag note for future maintainers:** `nagarectl deploy` takes the config
  via `--file`/`-f`; the `storage snapshot`/`storage restore` verbs take it via `--config`/`-f`
  (the `StoreCommonOpts` parser). The smoke script uses each correctly.


## Decision Log

Record every decision made while working on the plan.

- Decision (2026-06-11): CI is implemented as **Nix flake checks (the source of truth)**
  invoked by a **thin GitHub Actions workflow**. The flake checks contain all logic; the
  workflow only installs Nix and runs `nix flake check`.
  Rationale: local/hosted parity. A contributor reproduces CI exactly with one command
  (`nix flake check`) and no GitHub account; CI cannot drift from what runs locally
  because both invoke the same derivations. This is the MasterPlan-level decision
  (docs/masterplans/13, Decision Log 2026-06-11) made concrete here.
  Date: 2026-06-11.

- Decision (2026-06-11): The `checks` output is added to the **root** `flake.nix`, not to
  `nixos/flake.nix` and not to a brand-new third flake.
  Rationale: the root flake already pins the exact GHC 9.12 toolchain (`pkgs.haskell.compiler.ghc912`),
  `cabal-install`, `fourmolu`, and `cabal-gild` that the project builds and formats with,
  and it is the flake a contributor already `nix develop`s into. Putting checks there keeps
  one toolchain definition and means `nix flake check` and `nix develop` agree. `nixos/flake.nix`
  is host-image-only (system `x86_64-linux`) and conceptually separate; mixing application
  CI into it would couple two unrelated lifecycles.
  Date: 2026-06-11.

- Decision (2026-06-11): The example-compile guard runs **the same `runghc` contract the
  loader uses at runtime** — `runghc -XGHC2024 -i<configDir> <Config.hs>` — under
  `cabal exec` from `cli/nagarectl` so that `nagare-dsl` resolves, rather than re-implementing
  a bespoke compile path. Concretely: `( cd cli/nagarectl && cabal exec -- runghc -XGHC2024 -i<exampledir> <Config.hs> )`.
  Rationale: it tests the *real* code path users hit (`Nagare.Dsl.Load.runConfig`), and a config
  that compiles under the guard is exactly a config that `nagarectl deploy` can load. It also
  *runs* each config (emitting JSON to stdout), so it catches run-time `emit*`/marshalling
  failures, not only type errors.
  Date: 2026-06-11.

- Decision (2026-06-11): The **live smoke test is NOT part of per-PR CI.** It is a separate
  `just smoke` target and a `workflow_dispatch`-only GitHub workflow.
  Rationale: it requires the running VM, GCP credentials, and the cluster configured by EP-2;
  none of those is available to an offline PR runner, and a billable cluster must not be touched
  on every push. The offline checks are the gate; the live smoke is on-demand verification.
  Date: 2026-06-11.

- Decision (2026-06-11): The smoke scenario ships first as a **skip stub** that exits 0 with a
  clear "soft dependencies not yet landed" message, and its real steps are filled in as EP-1
  (the `nagarectl storage restore` verb), EP-2 (declarative private-image pull), and EP-3
  (cross-arch build) land.
  Rationale: EP-5 has only *soft* dependencies on EP-1/EP-2/EP-3 (docs/masterplans/13, Dependency
  Graph). The offline CI is valuable immediately; the live scenario is only meaningful once those
  behaviors exist. A stub that is wired but no-ops keeps the harness reviewable and lets the
  scenario be filled in incrementally without blocking M1/M2.
  Date: 2026-06-11.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The repository now has the CI it never had, plus a live smoke test — both verified:

**Offline CI (M1/M2).** The root `flake.nix` gains a `checks` output with four derivations:
`nagare-dsl-build-test`, `nagarectl-build-test`, `examples-compile` (compiles-and-runs all 19 shipped
`Config.hs` through the loader's real `runghc` contract — the guard for the rotted-example class the
audit found), and `shellcheck-scripts`. `nix flake check` passes on a clean tree. `.github/workflows/ci.yml`
is a thin shell that installs Nix and runs the same `nix flake check`, so local and hosted behaviour are
identical by construction. (`fourmolu-format` is deliberately omitted — a fourmolu version drift would
make it red on a clean tree; see Surprises.)

**Live smoke (M3).** `just smoke` / `scripts/live-smoke.sh` ran end-to-end against `nagare-01`,
exercising every path that was dark for weeks. Transcript (2026-06-11):

```text
== step 3: nagarectl deploy uploads-volume (build amd64 -> push private AR -> deploy) ==
  ... 20260611-050844: digest: sha256:8935a85b... (pushed to private AR)
  service.serving.knative.dev/uploads-volume condition met
  Deployed: https://uploads-volume.personal.apps.example.com
== step 4a: write a sentinel into the volume ==
  uploaded + read back: smoke ok 71544
== step 4b: snapshot the volume to GCS ==
  Snapshot written: gs://tan-nb-exp-nagare-backups/volumes/uploads-volume/uploads/20260611T050857Z.tar.gz
== step 4c: restore the snapshot into a scratch PVC and confirm the sentinel round-trips ==
  /restore/smoke-sentinel-71544.txt
  RESTORE OK: sentinel smoke-sentinel-71544.txt present in the restored tree
== step 5: verify HTTP 200 ==
  HTTP 200 OK
live smoke: OK
```

This single run proved EP-1 (the snapshot+restore GCS round-trip that returned `401 Anonymous` before
the unified `Nagare.Cluster.GcsJob` hostAliases), EP-2 (the cluster pulled the private image — after the
reload-defect fix the smoke itself surfaced), EP-3 (the amd64 image runs on the amd64 node), and EP-6
(GHC-env auto-resolution + the `just live-test` harness). `.github/workflows/live-smoke.yml` runs the
same scenario on a manual `workflow_dispatch`.

**Gaps / follow-ups.** (1) `fourmolu-format` deferred (version drift). (2) The flake checks are
network-dependent (not hermetic) — the documented first-iteration trade-off; a `haskell.nix` migration
would make them network-free. (3) The GitHub *CI* check's green-on-clean is green-by-construction (it
runs the verified `nix flake check`) but was not observed on a real push here.

**Lessons.** The smoke test paid for itself on its first real run by exposing the EP-2 reload defect — a
dark-path bug that the offline CI could never have caught and that had survived the M2 "verification"
(which only passed because `host-switch` restarts k3s). And running the flake checks in a clean Nix
derivation exposed a GHC-env fragility the dev shell's stray `.ghc.environment.*` file had been hiding —
the same class of issue EP-6 fixed for `nagarectl`. Both findings validate the core thesis: behaviours
that are never exercised in a clean environment rot in the dark.


## Context and Orientation

This section describes the current state as if you know nothing about the repository.
Read it before touching anything.

**What "CI" means here.** Continuous integration (CI) is automation that, on every code
change, builds the project and runs its checks so a regression is caught immediately
rather than discovered later. This repository has none today: there is no `.github/`
directory and no workflow file. You can confirm this yourself — `ls .github` fails.

**What "Nix flake checks" means here.** A *flake* is a Nix project described by a
`flake.nix` file that declares reproducible *outputs*. One kind of output is a `checks`
attribute set: each entry is a derivation (a build) that *must succeed* for the check to
pass. The command `nix flake check` evaluates and builds every entry under `checks` for
the current system and fails if any of them fails to build. Because each check is a
plain Nix derivation, it runs identically on a laptop and on a hosted runner — that
identity is the whole point of the source-of-truth decision.

**The two existing flakes.** The repository root holds `flake.nix`, which currently
declares only `devShells` — the developer shell you enter with `nix develop`. It pins
the toolchain this project builds with: `pkgs.haskell.compiler.ghc912` (GHC 9.12),
`pkgs.cabal-install`, `pkgs.haskell.packages.ghc912.fourmolu`, and
`pkgs.haskell.packages.ghc912.cabal-gild`, alongside cloud tooling (`google-cloud-sdk`,
`kubectl`, `pulumi`, `just`, `jq`). Its `systems` list is
`[ "x86_64-linux" "aarch64-darwin" ]`. The second flake, `nixos/flake.nix`, builds the
NixOS host image for the `nagare-01` VM; it is unrelated to application CI and this plan
does not touch it.

**The two Haskell packages.** Under `cli/` there are two Cabal packages:

- `cli/nagare-dsl` — the typed deployment model and Knative renderer
  (`cli/nagare-dsl/nagare-dsl.cabal`). Its test suite is named `nagare-dsl-test`
  (an `exitcode-stdio-1.0` suite whose entry point is `cli/nagare-dsl/test/Spec.hs`,
  built on the `tasty` test framework). Its `cli/nagare-dsl/cabal.project` declares
  `packages: .` and `write-ghc-environment-files: always`.

- `cli/nagarectl` — the deploy CLI (`cli/nagarectl/nagarectl.cabal`). Its test suite is
  named `nagarectl-test` (entry point `cli/nagarectl/test/Spec.hs`). Its
  `cli/nagarectl/cabal.project` declares `packages: . ../nagare-dsl` (so `nagarectl`
  builds against the local `nagare-dsl`), `write-ghc-environment-files: always`, and a
  `source-repository-package` stanza pulling `cradle` from
  `https://github.com/garnix-io/cradle` at tag `711c441fa8f190a8964c56a3bae864cd5321c5c5`
  (cradle is not on Hackage). **This network fetch matters for CI** — see "Network access
  in checks" below.

  Together the two suites comprise roughly 258 unit/golden/property tests today (the figure
  recorded in docs/plans/63 and MasterPlan 12 after the `Nagare.Init` group landed). The
  exact number is not load-bearing; "both suites pass" is the acceptance, and the count is
  cited only so a reader can sanity-check that CI is actually running them.

**Where `cabal test` is run.** Each suite is run from inside its package directory:
`cd cli/nagare-dsl && cabal test` and `cd cli/nagarectl && cabal test`. There is no root
`cabal.project` spanning both; each package is built and tested in its own directory.

**The example configs and why they rot silently.** Under `cluster/examples/` there are 19
application example directories, each shipping a `nagare/Config.hs` — a Haskell `Main`
module that constructs a typed value (`Deployment`, `StaticSite`, or `ServerSite`) and
prints its JSON via a `Nagare.Dsl.Config.emit*` helper. These are the worked examples a
user copies. The full list (paths relative to repo root) is:

```text
cluster/examples/app-cleanup-task/nagare/Config.hs
cluster/examples/app-lifecycle-demo/nagare/Config.hs
cluster/examples/clickhouse-analytics/nagare/Config.hs
cluster/examples/dockerfile-app/nagare/Config.hs
cluster/examples/env-and-secrets/nagare/Config.hs
cluster/examples/heartbeat-task/nagare/Config.hs
cluster/examples/hello-knative-service/nagare/Config.hs
cluster/examples/nixpacks-app/nagare/Config.hs
cluster/examples/postgres-app/nagare/Config.hs
cluster/examples/prebuilt-image-app/nagare/Config.hs
cluster/examples/preset-app-a/nagare/Config.hs
cluster/examples/preset-app-b/nagare/Config.hs
cluster/examples/redis-cache/nagare/Config.hs
cluster/examples/sqlite-pvc-litestream/nagare/Config.hs
cluster/examples/static-cdn-site/nagare/Config.hs
cluster/examples/static-site/nagare/Config.hs
cluster/examples/tanstack-start/nagare/Config.hs
cluster/examples/tanstack-start-cdn/nagare/Config.hs
cluster/examples/uploads-volume/nagare/Config.hs
```

The crucial gap: the existing test suite under `cli/nagare-dsl/test/` and
`cli/nagarectl/test/` compiles its *own* fixtures (under each package's `test/fixtures/`),
**not** these shipped examples. So when a DSL change makes one of these 19 files stop
compiling, the test suite stays green and the breakage ships. The example-compile guard
this plan adds closes exactly that gap.

**How an example is compiled and run.** The loader `Nagare.Dsl.Load.runConfig`
(`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`) runs a config with
`readProcessWithExitCode "runghc" ["-XGHC2024", "-i" <> configDir, path] ""`. In words:
it invokes `runghc` (the GHC "compile and immediately run" tool) with the house language
edition `GHC2024`, adds the config's own directory to the include path with `-i`, and
passes the file path. For `runghc` to resolve the `nagare-dsl` package (and its
dependencies), GHC needs a *package environment* — the `.ghc.environment.*` file that
`write-ghc-environment-files: always` materialises in each `cabal.project` directory. The
proven, self-sufficient way to give `runghc` that environment in CI is to run it under
`cabal exec` from the `cli/nagarectl` package, because that package's build plan already
includes `nagare-dsl`:

```bash
( cd cli/nagarectl && cabal exec -- runghc -XGHC2024 -i<exampledir> <Config.hs> )
```

`cabal exec` sets up the GHC package environment for the current build plan and then runs
the given command inside it, so `runghc` sees `nagare-dsl`. This is the exact recipe the
example-compile guard uses.

**The dependency on EP-6 (docs/plans/70), and the self-sufficient fallback.** EP-6 ("CLI
and operator-harness ergonomics") makes `nagarectl` *resolve the loader's GHC environment
itself*, so an operator no longer hand-captures a `--ghc-env` file. Today the mechanism is
manual: `cli/nagarectl/app/Main.hs` reads `--ghc-env`/`NAGARE_GHC_ENVIRONMENT` and exports
`GHC_ENVIRONMENT` for the loader's `runghc`. **This plan does not depend on EP-6 for the
offline CI.** The `cabal exec` recipe above is fully self-sufficient and works today with
no EP-6 changes, because `cabal exec` supplies the environment. If and when EP-6 lands, the
guard could be simplified to invoke `nagarectl`'s own loader directly, but that is an
optional later refinement, not a requirement. State this in any review: **M1 has no hard
dependency on EP-6.**

**Network access in checks.** `nix flake check` builds derivations in Nix's sandbox, which
by default has **no network access**. Two of our checks need the network at build time: the
Cabal builds fetch Hackage dependencies, and `cli/nagarectl` fetches `cradle` from GitHub.
There are two acceptable ways to handle this, and the plan picks the simpler one for the
first iteration and records the trade-off (see "A note on sandboxing and `haskell.nix`"
under Plan of Work). The short version: the first iteration runs the Cabal build/test
*inside the dev shell in a non-sandboxed check invocation* (`nix flake check --no-sandbox`
on Linux, or equivalently a check that shells out to `cabal` with network access), which is
pragmatic and keeps the flake small; a later hardening can switch to a fully hermetic
`haskell.nix`/`callCabal2nix` build if reproducibility-without-network becomes a
requirement. Both are documented so a future contributor can choose.

**The live paths the smoke test exercises.** The smoke test drives `nagarectl` against the
real cluster. The relevant verbs already exist or are added by sibling plans:
`nagarectl deploy` (build, push, apply, wait, print URL), `nagarectl app storage snapshot`
(snapshot a volume to the GCS backup bucket — the `command "storage"` group with
`progDesc "Snapshot a volume's contents to the GCS backup bucket"` in
`cli/nagarectl/app/Main.hs`), and the **new** `nagarectl storage restore APP VOLUME BACKUP_ID [--into-live]`
verb that **EP-1 (docs/plans/65)** adds (`progDesc "Restore a backup into a scratch target
(or --into-live); --dry-run prints the Job"`). EP-1 also deletes the hand-rolled bash
restore scripts. EP-5 *consumes* these verbs; it does not edit them.

**The harness the smoke test relies on (EP-6, docs/plans/70).** Reaching the cluster from a
workstation requires an Identity-Aware-Proxy (IAP) tunnel on port 22 plus a rewritten
kubeconfig that points `kubectl` at the tunneled API server. EP-6 provides `just live-test`,
a one-command recipe that stands up that harness. The smoke target reuses it rather than
re-implementing the tunnel. Until EP-6 lands, the smoke target documents the manual harness
steps (an SSH local-forward to `127.0.0.1:6443`, as the MasterPlan access note describes)
and skips if the harness is unavailable.


## Plan of Work

The work is three milestones. M1 builds the flake checks (the source of truth) and is
independently valuable the moment it lands — it catches the rotted-example class of bug. M2
wraps those checks in a thin GitHub Actions workflow so they run on every push and pull
request. M3 adds the on-demand live smoke test. M1 and M2 have **no** dependency on the
sibling plans EP-1/EP-2/EP-3; M3 has soft dependencies on all three and ships first as a
skip stub.

A note on sandboxing and `haskell.nix`. The cleanest hermetic way to build Haskell in Nix is
`haskell.nix` or `pkgs.haskellPackages.callCabal2nix`, which derive a fully reproducible,
network-free build. Adopting either is a larger change (it re-expresses the Cabal build as a
Nix expression and must be taught about the `cradle` `source-repository-package`). For the
first iteration this plan deliberately keeps the flake small: the checks invoke `cabal`
directly inside a build that is allowed network access, mirroring exactly what a developer
runs in `nix develop`. The cost is that these checks are not network-hermetic; the benefit is
a tiny, obviously-correct flake that a novice can read. The hardening to `haskell.nix` is
recorded as a follow-up in the Outcomes section when M1 completes, not done here.


### Milestone M1 — Flake checks: build, test, example-compile, format

**Scope.** Add a `checks` attribute to the root `flake.nix` with these entries, each a
derivation that fails the build on any problem:

1. `nagare-dsl-build-test` — builds `cli/nagare-dsl` and runs its `nagare-dsl-test` suite.
2. `nagarectl-build-test` — builds `cli/nagarectl` and runs its `nagarectl-test` suite.
3. `examples-compile` — compiles-and-runs every `cluster/examples/*/nagare/Config.hs`.
4. `fourmolu-format` — verifies the `cli/` tree is formatted per `cli/fourmolu.yaml`.
5. (Optional) `shellcheck-scripts` — runs `shellcheck` over the remaining `scripts/*.sh`.

**What will exist at the end.** Running `nix flake check` at the repo root evaluates and
builds all five entries. On a clean tree it passes. If you break an example (introduce a type
error into any `cluster/examples/*/nagare/Config.hs`), `examples-compile` fails. If you break a
test, the matching `*-build-test` fails. If you misformat a Haskell source, `fourmolu-format`
fails.

**How to structure the flake edit.** The root `flake.nix` already has a `forAllSystems`
helper and a `pkgs` binding per system. Add a `checks = forAllSystems (pkgs: { ... });`
output alongside `devShells`. Each check is built with `pkgs.runCommand` (a derivation whose
build script either succeeds, producing an output, or fails). Reuse the toolchain the dev
shell already pins (GHC 9.12, `cabal-install`, `fourmolu`) by referencing the same `pkgs`
attributes. A representative shape (illustrative — finalize the exact derivation when
implementing, and resolve the network-access approach per the note above):

```nix
checks = forAllSystems (pkgs:
  let
    ghc = pkgs.haskell.compiler.ghc912;
    haskellTooling = [ ghc pkgs.cabal-install pkgs.zlib pkgs.pkg-config ];
  in {
    # Build + test nagare-dsl. Runs `cabal test` in the package dir.
    nagare-dsl-build-test = pkgs.runCommand "nagare-dsl-build-test"
      { nativeBuildInputs = haskellTooling; src = ./.; }
      ''
        cp -r "$src" build && chmod -R +w build
        cd build/cli/nagare-dsl
        export HOME="$PWD/.home"
        cabal update
        cabal test nagare-dsl-test --test-show-details=streaming
        touch "$out"
      '';

    # Build + test nagarectl (depends on the local nagare-dsl via its cabal.project).
    nagarectl-build-test = pkgs.runCommand "nagarectl-build-test"
      { nativeBuildInputs = haskellTooling; src = ./.; }
      ''
        cp -r "$src" build && chmod -R +w build
        cd build/cli/nagarectl
        export HOME="$PWD/.home"
        cabal update
        cabal test nagarectl-test --test-show-details=streaming
        touch "$out"
      '';

    # Compile-and-run every shipped example Config.hs through the loader's runghc
    # contract, resolving nagare-dsl via `cabal exec` from the nagarectl package.
    examples-compile = pkgs.runCommand "examples-compile"
      { nativeBuildInputs = haskellTooling; src = ./.; }
      ''
        cp -r "$src" build && chmod -R +w build
        cd build
        export HOME="$PWD/.home"
        ( cd cli/nagarectl && cabal update && cabal build all )
        fail=0
        for cfg in cluster/examples/*/nagare/Config.hs; do
          dir="$(dirname "$cfg")"
          echo "== compiling $cfg =="
          if ! ( cd cli/nagarectl && cabal exec -- \
                   runghc -XGHC2024 -i"../../$dir" "../../$cfg" >/dev/null ); then
            echo "FAILED: $cfg" >&2
            fail=1
          fi
        done
        [ "$fail" -eq 0 ] || exit 1
        touch "$out"
      '';

    # Verify the cli/ Haskell tree is formatted to the house style.
    fourmolu-format = pkgs.runCommand "fourmolu-format"
      { nativeBuildInputs = [ pkgs.haskell.packages.ghc912.fourmolu ]; src = ./.; }
      ''
        cd "$src"
        fourmolu --mode check --config cli/fourmolu.yaml $(find cli -name '*.hs')
        touch "$out"
      '';

    # OPTIONAL: lint the remaining shell scripts.
    shellcheck-scripts = pkgs.runCommand "shellcheck-scripts"
      { nativeBuildInputs = [ pkgs.shellcheck ]; src = ./.; }
      ''
        cd "$src"
        shellcheck scripts/*.sh scripts/lib/*.sh
        touch "$out"
      '';
  });
```

Two implementation realities to resolve while writing this (record the resolution in
Surprises & Discoveries):

- **Network access.** `cabal update`/`cabal build` and the `cradle` `source-repository-package`
  fetch need the network. In Nix's default sandbox they will fail. The first-iteration
  approach is to run `nix flake check` such that these derivations can reach the network
  — on Linux that is `nix flake check --no-sandbox`, or marking the relevant derivations as
  impure/fixed-output. Document the exact chosen mechanism. If hermeticity is later required,
  migrate to `haskell.nix`/`callCabal2nix` (the recorded follow-up).

- **`paths` in `examples-compile`.** The `-i` path is relative to the `cli/nagarectl` working
  directory (hence the `../../` prefixes above). Verify the prefix arithmetic on the first run;
  an absolute path computed from `$PWD` is an equally good alternative and may be clearer.

**Commands to run (locally, from the repo root).**

```bash
nix flake check
```

**Acceptance for M1.** On a clean tree, `nix flake check` exits 0 and reports each check built.
To prove the guard works, introduce a deliberate type error into one example and re-run:

```bash
# Break an example on purpose.
printf '\nbad = (1 :: Int) + "oops"\n' >> cluster/examples/hello-knative-service/nagare/Config.hs
nix flake check        # expect: examples-compile FAILS, naming the file.
git checkout -- cluster/examples/hello-knative-service/nagare/Config.hs
nix flake check        # expect: PASS again.
```

Similarly, a failing unit test must fail `nagare-dsl-build-test` or `nagarectl-build-test`, and
a misformatted source must fail `fourmolu-format`.


### Milestone M2 — Thin GitHub Actions workflow

**Scope.** Add `.github/workflows/ci.yml` that installs Nix and runs `nix flake check`. The
workflow contains **no build logic** — all logic is in the flake. It runs on `push` and
`pull_request`.

**What will exist at the end.** A GitHub check named *CI* appears on pushes and pull requests.
It is green on a clean tree and red when any flake check fails. Because it runs the very same
`nix flake check`, there is zero divergence from local behavior.

**The workflow file.** Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:

# Cancel superseded runs on the same ref to save runner minutes.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  flake-check:
    name: nix flake check
    runs-on: ubuntu-latest
    steps:
      - name: Check out the repository
        uses: actions/checkout@v4

      - name: Install Nix
        uses: cachix/install-nix-action@v27
        with:
          # Flakes are still gated behind experimental features.
          extra_nix_config: |
            experimental-features = nix-command flakes

      - name: Run the flake checks (the source of truth)
        # The checks ARE the CI. If any example Config.hs stops compiling, a
        # test fails, or a source is misformatted, this step fails the build.
        run: nix flake check --print-build-logs
```

Two notes for the implementer:

- The runner is `ubuntu-latest`, i.e. `x86_64-linux`, which is in the root flake's `systems`
  list, so `nix flake check` resolves the Linux check set. (Apple-silicon contributors get
  `aarch64-darwin` locally; both share the same check definitions.)
- If M1 settled on `--no-sandbox` (or impure/fixed-output derivations) for network access, the
  `run:` line here must use the matching invocation. Keep this the *only* place that differs
  from a bare `nix flake check`, and add a one-line comment explaining why.

**Acceptance for M2.** Push a branch and open a pull request; the *CI* check runs and is green
on a clean tree. Re-run the deliberate-breakage experiment from M1 on a branch and confirm the
check turns red and the log names the offending example.


### Milestone M3 — Live smoke test (manual / periodic)

**Scope.** Add a `just smoke` recipe backed by `scripts/live-smoke.sh`, plus a
`workflow_dispatch`-only workflow `.github/workflows/live-smoke.yml`. The smoke scenario:

1. **Start the VM if needed.** Ensure the `nagare-01` instance is `RUNNING` (start it and wait
   if it is `TERMINATED`).
2. **Stand up the harness.** Run `just live-test` (EP-6) to open the IAP port-22 tunnel and
   write the rewritten kubeconfig so `kubectl`/`nagarectl` reach the cluster. Until EP-6 lands,
   fall back to the documented manual SSH local-forward to `127.0.0.1:6443`.
3. **Deploy a private-registry build-mode app.** From a dedicated smoke example directory,
   `nagarectl deploy` an app whose image is built from source (build mode) and pushed to the
   project's **private** Artifact Registry, then pulled by the cluster. This exercises EP-2
   (declarative private-image pull) and EP-3 (cross-arch build: the node is amd64, the build
   host may be arm64).
4. **Snapshot and restore a volume.** The smoke app declares a volume; write a sentinel file
   into it, `nagarectl app storage snapshot` it to the GCS backup bucket, then **restore** that
   snapshot with the new `nagarectl storage restore APP VOLUME BACKUP_ID --into-live` verb
   (EP-1) and confirm the sentinel is present. This is the exact path that returned
   `401 Anonymous` live before EP-1's unified GCS-auth helper.
5. **Verify HTTP 200.** `curl` the app's URL (printed by `nagarectl deploy`) and assert status
   `200`.
6. **Tear down.** Delete the app, its DomainMappings, its volume/PVC, and the snapshot; close
   the tunnel. Teardown must run even if an earlier step failed (a `trap` in the script).

**What will exist at the end.** A contributor with the VM running and credentials present runs
`just smoke` and watches the full deploy → snapshot → restore → HTTP-200 → teardown cycle, or
triggers the same from the GitHub UI via *Run workflow* on the *Live Smoke* workflow.

**The skip stub (ships first).** Because EP-1/EP-2/EP-3 are soft dependencies, `scripts/live-smoke.sh`
ships first as a guarded stub: it checks for the prerequisites (VM reachable, the
`nagarectl storage restore` verb present, the harness available) and, if any is missing,
prints a precise "soft dependency not yet landed; skipping" message and exits 0. As each sibling
plan lands, replace the corresponding guard with the real step. This keeps the harness reviewable
and the workflow green-by-skip until the live behaviors exist.

**The `just smoke` recipe.** Append to `justfile` (a thin wrapper, like the others):

```text
# EP-5 (docs/plans/69): live smoke test. Starts the VM if needed, deploys a
# private-registry build-mode app, snapshots and RESTORES a volume, verifies
# HTTP 200, and tears down. Requires the running VM + GCP credentials; this is
# NOT part of the per-PR offline CI. Soft-deps: EP-1 (restore verb), EP-2
# (private-image pull), EP-3 (cross-arch build), EP-6 (just live-test harness).
smoke:
    scripts/live-smoke.sh
```

**The orchestration script.** Create `scripts/live-smoke.sh`. It sources the target guardrail
(`scripts/lib/target.sh`) so it only ever acts on the configured project, sets a teardown
`trap`, and runs the six steps. Skeleton (fill steps in as soft deps land):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Single-project guardrail: refuse to run against any project but the configured target.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"
_require_target_project

SMOKE_APP="smoke-app"
SMOKE_VOL="data"

cleanup() {
  echo "== teardown =="
  nagarectl app delete "${SMOKE_APP}" --yes || true
  # ... delete snapshot, close tunnel ...
}
trap cleanup EXIT

# Step 1: ensure the VM is RUNNING (start + wait if TERMINATED).
# Step 2: just live-test  # EP-6 harness (IAP tunnel + kubeconfig).
# Step 3: ( cd cluster/examples/<smoke-app> && nagarectl deploy ... )   # EP-2/EP-3
# Step 4: snapshot + restore the volume                                  # EP-1
#   BACKUP_ID="$(nagarectl app storage snapshot "${SMOKE_APP}" "${SMOKE_VOL}" ... )"
#   nagarectl storage restore "${SMOKE_APP}" "${SMOKE_VOL}" "${BACKUP_ID}" --into-live
# Step 5: curl -sS -o /dev/null -w '%{http_code}' "${APP_URL}"  -> assert 200
# Step 6: handled by the trap.

echo "live smoke: OK"
```

**The manual workflow.** Create `.github/workflows/live-smoke.yml`, triggered only by
`workflow_dispatch`:

```yaml
name: Live Smoke

# Manual trigger ONLY. This deploys to the real cluster and requires the running
# VM + GCP credentials, so it must never run on push/PR.
on:
  workflow_dispatch:

jobs:
  live-smoke:
    name: live smoke test
    runs-on: ubuntu-latest
    steps:
      - name: Check out the repository
        uses: actions/checkout@v4

      - name: Install Nix
        uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes

      - name: Authenticate to GCP
        # Configure credentials so gcloud/nagarectl can reach the target project.
        # Wire this to the project's preferred secret mechanism (e.g. a service
        # account key in repo secrets, or Workload Identity Federation).
        run: echo "TODO: configure GCP auth before the live steps are un-stubbed"

      - name: Run the live smoke test inside the dev shell
        run: nix develop --command just smoke
```

The workflow runs inside `nix develop` so `nagarectl`, `gcloud`, `kubectl`, and `just` are all
present (the dev shell already ships them). Wiring the actual GCP credential is left to whoever
un-stubs the live steps, alongside EP-2's durable credential mechanism; until then the job runs
the skip-stub and succeeds by no-op.

**Acceptance for M3.** With the VM running and credentials present, `just smoke` (or the
manually dispatched workflow) completes the full deploy → snapshot → restore → HTTP-200 →
teardown cycle and prints `live smoke: OK`, then leaves no smoke resources behind
(`nagarectl app list` does not show `smoke-app`; the snapshot is deleted). Before the soft deps
land, the stub exits 0 with a clear "skipping" message and the workflow is green-by-skip.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a step
says otherwise. Enter the dev shell first (`nix develop`) or rely on direnv.

**M1 — author and verify the flake checks.**

```bash
# 1. Edit flake.nix: add the `checks = forAllSystems (pkgs: { ... });` output
#    described in Milestone M1 (the five derivations).
$EDITOR flake.nix

# 2. Run the checks. On a clean tree this builds and passes all entries.
nix flake check --print-build-logs
```

Expected tail (illustrative):

```text
checking flake output 'checks'...
building '/nix/store/...-nagare-dsl-build-test.drv'...
building '/nix/store/...-nagarectl-build-test.drv'...
building '/nix/store/...-examples-compile.drv'...
== compiling cluster/examples/hello-knative-service/nagare/Config.hs ==
... (one line per example) ...
building '/nix/store/...-fourmolu-format.drv'...
```

Prove the example guard with the deliberate-breakage experiment from M1's acceptance.

**M2 — author the thin workflow.**

```bash
mkdir -p .github/workflows
$EDITOR .github/workflows/ci.yml     # paste the M2 yaml.
git add .github/workflows/ci.yml flake.nix
git commit -m "ci(EP-5): nix flake checks + thin GitHub Actions workflow"
git push                              # open a PR; watch the CI check.
```

**M3 — author the smoke target, script, and manual workflow.**

```bash
$EDITOR justfile                      # add the `smoke:` recipe.
$EDITOR scripts/live-smoke.sh         # add the orchestration script (skip-stub first).
chmod +x scripts/live-smoke.sh
$EDITOR .github/workflows/live-smoke.yml   # add the workflow_dispatch workflow.

# Dry-run the stub locally (no VM needed; it should skip cleanly).
just smoke
```


## Validation and Acceptance

The change is effective beyond compilation when all of the following hold:

- **Offline CI catches a rotted example.** Appending a type error to any
  `cluster/examples/*/nagare/Config.hs` makes `nix flake check` fail in `examples-compile`,
  naming the file; reverting makes it pass. This is the regression that shipped undetected
  before this plan.

- **Offline CI catches a failing test.** Introducing a failing assertion in either suite makes
  the matching `*-build-test` check fail. Both `nagare-dsl-test` and `nagarectl-test` run (the
  ~258-test corpus), confirmed by `--test-show-details=streaming` output.

- **Offline CI catches misformatting.** Reformatting a Haskell file away from `cli/fourmolu.yaml`
  style makes `fourmolu-format` fail; running `fourmolu --mode inplace` fixes it.

- **GitHub parity.** The *CI* check on a pull request runs the identical `nix flake check` and
  is green on a clean tree, red on any of the above breakages — with no logic in the workflow
  beyond installing Nix.

- **Live smoke (manual).** With the VM running and credentials present, `just smoke` performs
  deploy → snapshot → **restore** → HTTP-200 → teardown and prints `live smoke: OK`, leaving no
  `smoke-app` resources behind. Until EP-1/EP-2/EP-3 land, the stub exits 0 with an explicit
  "skipping (soft dependency not yet landed)" message.

Exact test commands, for reference, runnable inside `nix develop`:

```bash
( cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=streaming )
( cd cli/nagarectl  && cabal test nagarectl-test  --test-show-details=streaming )
fourmolu --mode check --config cli/fourmolu.yaml $(find cli -name '*.hs')
```


## Idempotence and Recovery

`nix flake check`, `cabal build`/`cabal test`, and `fourmolu --mode check` are all idempotent
and safe to repeat; they read the tree and produce no lasting side effects beyond Nix store and
`dist-newstyle` build artifacts. The deliberate-breakage experiments instruct you to
`git checkout --` the modified file afterward, so the tree returns to clean.

The GitHub workflows are additive: adding `.github/workflows/*.yml` cannot affect the working
tree and can be deleted with no residue. Re-running a workflow is safe.

The live smoke test is the only step with external side effects (it touches the cluster and the
GCS backup bucket). It is made safe by (a) the `_require_target_project` guardrail, which refuses
to run against any project but the configured target; (b) a unique, dedicated `smoke-app`
name/namespace so it never collides with real workloads; and (c) a teardown `trap` that runs on
every exit, including failure, deleting the app, its volume/PVC, and the snapshot. If teardown is
interrupted, re-running `just smoke` and letting it reach teardown — or manually
`nagarectl app delete smoke-app --yes` plus deleting the snapshot object — restores a clean
state. Because the scenario is idempotent (deploy of the same `smoke-app` overwrites the prior
one), re-running after a partial failure is safe.


## Interfaces and Dependencies

**Libraries, tools, and services used (and why).**

- **Nix flakes** (`flake.nix` `checks` output, built by `nix flake check`): the source of truth
  for CI. Chosen for local/hosted parity (Decision Log).
- **GHC 9.12 + `cabal-install`** (`pkgs.haskell.compiler.ghc912`, `pkgs.cabal-install`): build
  and test both Haskell packages, reusing the toolchain the dev shell already pins.
- **`fourmolu`** with `cli/fourmolu.yaml`: the house Haskell formatter; the single shared config
  covers the whole `cli/` tree.
- **`runghc` under `cabal exec`**: the example-compile guard, mirroring `Nagare.Dsl.Load.runConfig`'s
  runtime contract `runghc -XGHC2024 -i<dir> <Config.hs>` and resolving `nagare-dsl` via
  `cabal exec` from `cli/nagarectl`.
- **`shellcheck`** (optional check): lints the remaining `scripts/*.sh`.
- **GitHub Actions** with `actions/checkout@v4` and `cachix/install-nix-action@v27`: the thin
  hosted shell that installs Nix and runs the flake checks.
- **`nagarectl`, `gcloud`, `kubectl`, `just`** (all in the dev shell): the live smoke test's
  drivers.

**Artifacts created or edited by this plan.**

- `flake.nix` — add a `checks` output (the only edit; `devShells` untouched).
- `.github/workflows/ci.yml` — new (offline CI).
- `.github/workflows/live-smoke.yml` — new (manual live smoke).
- `justfile` — add a `smoke:` recipe.
- `scripts/live-smoke.sh` — new (orchestration; skip-stub first).

**Integration contract — what this plan CONSUMES and does NOT edit.** Per
docs/masterplans/13 (Integration Points and Dependency Graph), EP-5 has only *soft* and
*consume-only* relationships with its siblings:

- **EP-1 (docs/plans/65):** the smoke test *calls* the new
  `nagarectl storage restore APP VOLUME BACKUP_ID [--into-live]` verb and the existing
  `nagarectl app storage snapshot`. It does **not** edit EP-1's shared
  `Nagare.Cluster.GcsJob` module or the storage/database renderers; it exercises the *rendered*
  Jobs through the CLI. Until EP-1 lands, the restore step is stubbed/skipped.
- **EP-2 (docs/plans/66):** the smoke test *depends on* the cluster having
  `registries.yaml` and `registriesSkippingTagResolving` applied (so a private image pulls). It
  does **not** edit `nixos/hosts/nagare-01/k3s.nix` or `cluster/bootstrap/knative-serving/`.
- **EP-3 (docs/plans/67):** the smoke test *relies on* `nagarectl` building a node-architecture
  (amd64) image via the target-profile platform field. It does **not** edit `Nagare.Target`,
  `Nagare.Build`, or the profile schema.
- **EP-6 (docs/plans/70):** the smoke test *uses* `just live-test` for the IAP tunnel +
  kubeconfig harness. It does **not** edit the harness or `Nagare.Target`. The offline CI's
  example-compile guard does **not** depend on EP-6: the `cabal exec` recipe is self-sufficient
  today (see Context).

**Signatures / outputs that must exist at the end of each milestone.**

- End of **M1**: the root `flake.nix` exposes `checks.<system>.{nagare-dsl-build-test,
  nagarectl-build-test, examples-compile, fourmolu-format}` (and optionally `shellcheck-scripts`),
  and `nix flake check` builds them all and fails on a broken example, a failing test, or
  misformatting.
- End of **M2**: `.github/workflows/ci.yml` exists, runs on push/PR, and its only logical step is
  `nix flake check`.
- End of **M3**: `just smoke` and `scripts/live-smoke.sh` exist and, with the VM up, perform the
  full deploy → snapshot → restore → HTTP-200 → teardown cycle (skip-stub until EP-1/EP-2/EP-3
  land); `.github/workflows/live-smoke.yml` exists, `workflow_dispatch`-only.


## Revision Note

2026-06-11 — Initial authoring (fleshed out from the skeleton). Researched the repository's flake
layout (root `flake.nix` is devShell-only; `nixos/flake.nix` is host-image-only; no `checks`
exists today), the two Haskell packages and their per-directory `cabal.project` files and test
suite names (`nagare-dsl-test`, `nagarectl-test`), the loader's `runghc -XGHC2024 -i<dir>` contract
in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, the single shared formatter config `cli/fourmolu.yaml`
(the brief's `cli/nagarectl/fourmolu.yaml` does not exist), and the 19 shipped
`cluster/examples/*/nagare/Config.hs` examples that the existing test suite does **not** compile.
Recorded the source-of-truth decision (flake checks invoked by a thin Actions workflow), the
root-flake placement decision, the `cabal exec` example-compile recipe and its self-sufficiency
(no hard EP-6 dependency), and the live smoke test's manual/`workflow_dispatch` gating with a
skip-stub for the EP-1/EP-2/EP-3 soft dependencies. Why: to give a novice a fully self-contained
path to the CI that does not exist today plus the live smoke test, closing the rotted-example and
dark-live-path gaps the 2026-06-10 audit exposed.
