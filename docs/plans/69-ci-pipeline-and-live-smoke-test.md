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

Full plan before trimming: [69-ci-pipeline-and-live-smoke-test.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/69-ci-pipeline-and-live-smoke-test.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

