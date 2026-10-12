---
id: 120
slug: modularize-the-root-flake-and-align-it-with-the-shared-haskell-nix-dev-toolchain-pins
title: "Modularize the root flake and align it with the shared haskell-nix-dev toolchain pins"
kind: exec-plan
created_at: 2026-09-13T14:06:46Z
intention: "intention_01m2dhezayepwrcx6afxfbbaz9"
provenance:
  created_by:
    model: "claude-opus-5"
    harness: "claude-code"
    at: 2026-09-13T14:06:46Z
  revisions:
    - model: "claude-opus-5"
      harness: "claude-code"
      at: 2026-09-13T16:30:59Z
      mode: "update"
      note: "Disable Haddock for the flake's own Haskell packages in Milestone 4"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-13T16:40:41Z
      mode: "implement"
      note: "Implemented the root flake modularization and shared toolchain alignment"
---

# Modularize the root flake and align it with the shared haskell-nix-dev toolchain pins

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [120-modularize-the-root-flake-and-align-it-with-the-shared-haskell-nix-dev-toolchain-pins.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/120-modularize-the-root-flake-and-align-it-with-the-shared-haskell-nix-dev-toolchain-pins.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare's root `flake.nix` has grown to 667 lines. About 445 of them are one inline `checks`
attribute set containing roughly twenty shell-script derivations, and the rest mixes release
metadata, packages, apps, a networked CI job, and a developer shell with a hand-maintained Pulumi
override. Reading or changing any one of those concerns means scrolling past all the others.
Separately, the flake pins its own `nixos-unstable` nixpkgs (locked at `331800d`, 2026-05-31) and
its own GHC 9.12 package set, while the maintainer's other Haskell projects all share one toolchain
generation defined by the `haskell-nix-dev` base flake
(`mori://shinzui/haskell-nix-dev/repos/haskell-nix-dev`) through the `nix-haskell-flake` Seihou
template (`mori://shinzui/seihou-modules/templates/nix-haskell-flake`).
Because nagare is on a different nixpkgs revision, nothing it builds is shared with those projects:
its Haskell library closure is compiled separately, and its Haskell Language Server (HLS, the editor
backend) is compiled from source instead of downloaded from the `shinzui.cachix.org` binary cache.

After this plan, a contributor can open `flake.nix` and see a short entry point that lists inputs and
imports small, single-purpose files under `nix/`, and can find any check by domain under
`nix/checks/`. The flake takes its nixpkgs and flake-parts from one rev-pinned `haskell-nix-dev`
input, so `nix flake update` cannot drift those pins, the GHC 9.12.4 toolchain and HLS come from
binary caches, and every Hackage library nagare shares with the other projects on the same
toolchain generation is built once per machine rather than once per project. Editing Nix wiring
(anything in `flake.nix`, `flake.lock`, or `nix/`) no longer invalidates every check's source hash.

To see it working: `nix flake check` passes on `aarch64-darwin` and `x86_64-linux`;
`nix flake update && git diff --exit-code flake.lock` prints nothing; `nix develop -c ghc --version`
reports 9.12.4; and the milestone gates below prove that the two pure refactoring milestones changed
no derivation at all.

The NixOS host flake under `nixos/` (its own `flake.nix` and `flake.lock`) is explicitly out of
scope and must not change.

## Progress

- [x] (2026-09-13T16:40:41Z) Milestone 1: add `nix/source.nix` (a source tree that excludes Nix wiring) and use it for every
      check that currently uses `src = ./.` and for the platform payload filter.
- [x] (2026-09-13T16:40:41Z) Milestone 1: route the post-plan `haskell-style` check and the
      networked Hydra job through the same source so later wiring-only refactors preserve their
      derivations too.
- [x] (2026-09-13T16:51:07Z) Milestone 1: `nix flake check --print-build-logs` passed all 21 native
      checks, including all 438 CLI tests; the committed-tree probe printed `wiring edits are
      invisible to checks` after adding both a `flake.nix` comment and `nix/probe.nix`.
- [x] (2026-09-13T16:53:04Z) Milestone 2: split `flake.nix` into plain Nix functions under `nix/`
      and `nix/checks/`; the root entry point is now 66 lines and `.envrc` watches the modules.
- [x] (2026-09-13T17:07:03Z) Milestone 2: the derivation-equivalence gate printed
      `gate: aarch64-darwin identical` and `gate: x86_64-linux identical`; the committed split also
      passed `nix flake check --print-build-logs`, including all 438 CLI tests.
- [x] (2026-09-13T17:13:29Z) Milestone 3: convert the wiring to flake-parts modules with a
      rev-pinned `flake-parts` input; `nix flake check --no-build --print-build-logs` passes and
      `flake.lock` still contains exactly one nixpkgs node.
- [x] (2026-09-13T17:21:19Z) Milestone 3: the normalized derivation-equivalence gate printed
      `gate: aarch64-darwin pre-existing outputs identical` and
      `gate: x86_64-linux pre-existing outputs identical`; the raw diff contained only the five
      documented empty standard output names.
- [x] (2026-09-13T17:26:19Z) Milestone 4: record the current `nix-haskell-flake` v0.14.0 pin and
      its nixpkgs and flake-parts revisions in the Decision Log, verified against the registered
      sources and upstream `master` refs.
- [x] (2026-09-13T17:26:19Z) Milestone 4: follow `haskell-nix-dev` for nixpkgs and flake-parts, add
      the Cachix `nixConfig`, and keep the resulting lock to one nixpkgs node.
- [x] (2026-09-13T17:26:19Z) Milestone 4: switch every root-flake `ghc912` reference to `ghc9124`;
      direct evaluation reports GHC 9.12.4.
- [x] (2026-09-13T17:26:19Z) Milestone 4: disable Haddock for Nagare's own Haskell packages
      (`cradle`, `nagare-dsl`, `nagarectl`); both checked derivations expose only `out`, and the
      wrapper's underlying `nagarectl` package exposes no `doc` output.
- [x] (2026-09-13T17:26:19Z) Milestone 4: drop the Pulumi override and its release-specific hashes;
      the shared nixpkgs supplies Pulumi 3.255.0.
- [x] (2026-09-13T18:49:03Z) Milestone 4: all 21 flake checks pass on both supported systems,
      including all 438 CLI tests; the three release packages build explicitly on both systems;
      `nix flake update` is immovable; and `nixos/flake.lock` remains unchanged.
- [x] (2026-09-13T18:05:32Z) Milestone 5: move the six large inline check scripts into
      `nix/checks/scripts/*.sh`, pass their source and payload values as derivation attributes, and
      include them in `shellcheck-scripts`; the committed tree passes all 21 native flake checks,
      including all 438 CLI tests and the clone-free platform rehearsal.
- [x] (2026-09-13T17:52:22Z) Milestone 5: build both developer shells with
      `haskell-nix-dev`'s `mkDevShell`; the default includes HLS and the Haskell-focused shell omits
      it. The Cachix path probe succeeded, HLS 2.13.0.0 reports GHC 9.12.4, and `ghc --version`
      reports 9.12.4.
- [x] (2026-09-13T17:52:22Z) Milestone 5: update `README.md`, `.envrc`, and
      `agents/skills/nagare-release/SKILL.md`; ADR 17 now records the durable pin and ownership
      decisions, and `just docs-validate` passes.

## Surprises & Discoveries

- Observation: ExecPlan 119 added the `haskell-style` check after this plan's source inventory was
  written, and `hydraJobs.nagare-access-build-test` also used the whole repository as `src`.
  Evidence: before Milestone 1, `rg -n 'src = \./\.;' flake.nix` found the new check at line 98 and
  the Hydra job at line 556 in addition to the checks named below. Leaving the Hydra job unfiltered
  would make Milestone 2's all-output derivation-equivalence gate fail when the Nix wiring moves.

- Observation: The first Milestone 2 gate exposed an infinite recursion in `devShells.default` that
  the dirty-worktree `nix flake check --no-build` had not surfaced.
  Evidence: the exported `path:` flake failed while reading `devShells.default.drvPath`; the cause
  was `inherit (pulumi) pulumi` inside a recursive `let`. Referencing the bundle as
  `pulumi.pulumi` and `pulumi.pulumi-nodejs` removes the self-reference.

- Observation: A clean-Git `nix flake check` rebuilds the Nagare Haskell packages after every
  milestone commit even when the path-flake equivalence gate proves their unstamped recipes equal.
  Evidence: the Milestone 2 check built `nagarectl` with revision
  `8c05077ccb764b6010f1eb2dcd8630baf756f937`; `sourceRevision` is deliberately embedded in the
  package and therefore changes with the commit. The gate avoids this by evaluating exported
  `path:` flakes, where `sourceRevision` is null.

- Observation: flake-parts publishes five additional standard output names even when Nagare does
  not populate them: `formatter`, `legacyPackages`, `nixosConfigurations`, `nixosModules`, and
  `overlays`.
  Evidence: direct `nix eval --json ... --apply builtins.attrNames` probes returned empty attribute
  sets for all five; `legacyPackages` has one empty set under each supported system. The existing
  packages, apps, checks, development shells, Hydra jobs, and release metadata remain populated.

- Observation: `haskell-nix-dev` revision `206ecd25` carries `treefmt-nix`, but does not point that
  input's nixpkgs edge at its own nixpkgs despite the source comment saying all carried inputs do so.
  Evidence: the first generated lock had `nixpkgs` at `d5dfd8e` and `nixpkgs_2` at `4533d92`, matching
  the current `nix-haskell-flake` template lock. Overriding
  `haskell-nix-dev/treefmt-nix/nixpkgs` to follow `haskell-nix-dev/nixpkgs` removes `nixpkgs_2`.

- Observation: On this nixpkgs revision, `dontHaddock` removes actual documentation work and the
  `doc` output, but the generic Haskell builder still logs entry into an empty `haddockPhase` hook.
  Evidence: both checked packages expose only `["out"]`; the `nagarectl` wrapper's underlying
  package exposes `[[]]`; and their logs report `phase-hook=1 actual-haddock=0` when separately
  counting `Running phase: haddockPhase` and `Running Haddock on`. The plan's original expectation
  that the phase-hook count itself would be zero was too strict.

- Observation: Nagarectl's supported version interface is the `version` subcommand, not a global
  `--version` option.
  Evidence: `nix run .#nagarectl -- --version` reports `Invalid option`, while
  `nix run .#nagarectl -- version --json` returns platform version `0.1.0`, revision
  `fd69be61417fbba57faada46f594129c8a64ad27`, and CLI version `0.1.0`.

- Observation: The first final Linux validation attempt reached the running GCP builder but the
  managed ProxyCommand's ephemeral local port refused the SSH connection.
  Evidence: Nix reported `socat ... localhost:21477: Connection refused`. The established fallback
  — a direct local-port IAP tunnel with the scanned ED25519 host key passed through
  `base64-ssh-public-host-key` — successfully dispatched the same derivations to
  `ssh://builder@localhost:22477`; all 21 checks and the explicit `nagarectl`, `nagare-platform`,
  and `nagare` package gate then passed, and the temporary tunnel was closed.

- Observation: `haskell-style` was the only check that was accidentally Darwin-specific: its
  derivation executed `scripts/check-haskell-style.sh` directly, whose `/usr/bin/env bash` shebang
  is unavailable in the Linux Nix sandbox.
  Evidence: the first Linux run stopped with `/usr/bin/env: bad interpreter`; changing the check to
  `bash scripts/check-haskell-style.sh` passed independently on both systems and in the complete
  Linux rerun (`641e690`).

- Observation: the shared Cachix cache covers the `haskell-nix-dev` toolchain, but Nagare does not
  currently publish its application dependency closure.
  Evidence: the Linux run substituted GHC/HLS and 6.2 GiB of existing paths, then built uncached
  dependencies such as `foundation`, `crypton`, `tls`, and `warp`. The registered
  `mori://shinzui/haskell-nix-dev/repos/haskell-nix-dev` source uses
  `cachix/cachix-action@v15` to push its toolchains, while Nagare's `.github/workflows/ci.yml` only
  installs Nix. A follow-up should add the same authenticated Cachix push to Nagare's flake-check
  job; migrating to the separate `haskell.nix` framework is not required for that cache win.

## Decision Log

- Decision: Leave the NixOS host flake (`nixos/flake.nix`, `nixos/flake.lock`) untouched.
  Rationale: Host activation goes only through `just host-switch` under its own safety model
  (ADR 11), and host closures have different cache and upgrade concerns from the developer and
  release flake. The operator agreed to exclude it.
  Date: 2026-09-13

- Decision: Align with the `nix-haskell-flake` pins but do not generate the root flake with Seihou.
  Rationale: The module owns `flake.nix`, `.envrc`, and `nix/*.nix` and regenerates them. Nagare's
  root flake is a release flake (`lib.release`, `packages`, `apps`, `hydraJobs`, many `checks`), has
  an extra input (`cradle`) that would conflict on every module upgrade, builds three Cabal packages
  under `cli/` rather than one at the root, derives its systems from `release.json` rather than
  `flakeExposed`, and has a context-resolving `.envrc` that the module's generated `.envrc` would
  replace. Following the one `haskell-nix-dev` rev gives the cache and lock benefits without that
  coupling.
  Date: 2026-09-13

- Decision: Do the refactor before the pin change, and gate the refactor on byte-identical
  derivation paths rather than only on `nix flake check`.
  Rationale: A pure refactor can be proven to change nothing by comparing `drvPath` values. The pin
  change alters every hash by design, so doing both at once would reduce the evidence to "it still
  builds".
  Date: 2026-09-13

- Decision: Add a source-filtering milestone (Milestone 1) ahead of the split.
  Rationale: Many checks use `src = ./.`, which is the whole flake source including `flake.nix`,
  `flake.lock`, and `nix/`. Moving code between those files would change that source hash and every
  dependent `drvPath`, making the equivalence gate impossible. Excluding the Nix wiring from the
  source once (a deliberate, `nix flake check`-gated hash change) makes the later gates exact. It is
  also an improvement in itself: editing the flake no longer re-runs every check.
  Date: 2026-09-13

- Decision: Apply `nagareSource.src` to every whole-repository source consumer in the root flake,
  including `haskell-style` and `hydraJobs.nagare-access-build-test`, not only the check inventory
  that existed when this plan was drafted.
  Rationale: `haskell-style` is now part of `nix flake check`, and the derivation-equivalence gate
  explicitly compares Hydra jobs. Both consumers only need project sources, not Nix wiring.
  Date: 2026-09-13

- Decision: Pin `flake-parts` in Milestone 3 to the exact revision that `haskell-nix-dev` locks
  (`31729ca8cbdb4fa927b34e5f4353e6a83f39e993` at `haskell-nix-dev` `206ecd2`), with
  `inputs.nixpkgs-lib.follows = "nixpkgs"`.
  Rationale: This introduces no second nixpkgs and makes Milestone 4's switch to
  `flake-parts.follows = "haskell-nix-dev/flake-parts"` a no-op for flake-parts itself.
  Date: 2026-09-13

- Decision: Accept flake-parts' five empty standard outputs as the only output-name difference in
  the Milestone 3 refactor gate.
  Rationale: They are empty module-schema defaults rather than new build or release artifacts. The
  plan explicitly permits empty flake-parts outputs, while still requiring every pre-existing
  derivation and value to compare exactly.
  Date: 2026-09-13

- Decision: Follow the current `nix-haskell-flake` v0.14.0 template's `haskell-nix-dev` revision
  `206ecd25bcb4a07581210bdae3e6f43c8fd179d8`, which pins nixpkgs
  `d5dfd8e6716dde34398bc14bc87c10dece9c8c68` and flake-parts
  `31729ca8cbdb4fa927b34e5f4353e6a83f39e993`.
  Rationale: those are the current module-owned toolchain pins. The local registered sources and
  the authoritative upstream `master` refs both resolve to the same `haskell-nix-dev` and Seihou
  commits; neither upstream repository currently publishes Git tags.
  Date: 2026-09-13

- Decision: Override the carried `treefmt-nix` input's nixpkgs edge to follow
  `haskell-nix-dev/nixpkgs`.
  Rationale: the input is locked even though Nagare does not consume treefmt-nix. Without this
  override the shared flake introduces an unrelated second nixpkgs revision and violates the
  single-nixpkgs acceptance invariant. The override changes no Nagare output.
  Date: 2026-09-13

- Decision: Use nixpkgs' Pulumi 3.255.0 and matching `pulumi-nodejs` package directly, deleting the
  local 3.239.0 source and vendor-hash override.
  Rationale: 3.255.0 is newer than the minimum accepted by existing state, so carrying a bespoke
  source build and three release-specific hashes adds risk without benefit.
  Date: 2026-09-13

- Decision: In Milestone 5, use `haskell-nix-dev`'s `lib.<system>.mkDevShell` rather than reaching
  into `lib.<system>.ghcVersions`.
  Rationale: `mkDevShell` is the base flake's documented consumer contract (its source says "Keep
  these parameter names exactly"); the shape of `ghcVersions` is not promised.
  Date: 2026-09-13

- Decision: Disable Haddock (Haskell API documentation generation) in Nix builds of the packages
  this flake defines — `cradle`, `nagare-dsl`, and `nagarectl` — using
  `pkgs.haskell.lib.dontHaddock`, and do it in Milestone 4. Do not disable it across the whole
  Hackage package set.
  Rationale: The operator does not need API documentation from Nix builds, and Haddock adds build
  time to every CI and release run. Nothing in the flake, CI, or release workflow uses the `doc`
  output (a `git grep` for `.doc` and `haddock` in `*.nix`, `justfile`, and `.github` found
  nothing). Overriding every package in the set would give every dependency a new `drvPath`, so none
  of them could be substituted from caches or shared with the other projects on the same
  `haskell-nix-dev` toolchain, which is the point of Milestone 4; dependencies' docs are
  substituted rather than built whenever they are cached, so their cost is small by comparison. It
  lands in Milestone 4 rather than 2 or 3 because it changes derivations, which the equivalence gate
  forbids, while Milestone 4 rebuilds the closure anyway.
  Date: 2026-09-13

## Outcomes & Retrospective

The root flake is now a 66-line flake-parts entry point backed by single-purpose modules under
`nix/` and domain check modules under `nix/checks/`. All checks, the platform payload, and the
networked Hydra package use the filtered source from `nix/source.nix`, so edits to `flake.nix`,
`flake.lock`, or `nix/` no longer invalidate content-only source inputs. Exact `drvPath` comparison
proved the plain-module split and then the flake-parts conversion preserved every pre-existing
output on both supported systems; flake-parts added only its documented empty standard outputs.

The root lock now follows rev-pinned `haskell-nix-dev` revision `206ecd25bcb4a07581210bdae3e6f43c8fd179d8`
for nixpkgs and flake-parts, contains one nixpkgs node at
`d5dfd8e6716dde34398bc14bc87c10dece9c8c68`, and is immovable under `nix flake update`. Nagare uses
GHC 9.12.4, nixpkgs Pulumi 3.255.0, and shared development-shell construction. Its own `cradle`,
`nagare-dsl`, and `nagarectl` derivations have no `doc` output and perform no actual Haddock
invocation. The HLS 2.13.0.0 path is substitutable from `shinzui.cachix.org` and reports GHC 9.12.4.

All 21 checks passed on both `aarch64-darwin` and `x86_64-linux`, including the 438 Nagarectl tests,
typed example compilation, external-config validation, shellcheck, and the clone-free platform
rehearsal. `nagarectl`, `nagare-platform`, and `nagare` also passed explicit package builds on both
systems; `nagarectl version` reports 0.1.0. The six largest check bodies are maintainable shell
files covered by shellcheck, the documentation and `.envrc` describe the new layout, ADR 17 records
the durable pin ownership, and `just docs-validate` passes. The private, relaxed-sandbox Hydra job
remains delegated to CI as planned, and the independent `nixos/` host flake was not changed.

The cold Linux run exposed the next worthwhile improvement: publish Nagare's realized flake-check
closure to the existing Cachix cache. The current shared cache successfully avoids rebuilding the
toolchain, but it cannot substitute application dependencies until a Nagare CI job pushes them.

