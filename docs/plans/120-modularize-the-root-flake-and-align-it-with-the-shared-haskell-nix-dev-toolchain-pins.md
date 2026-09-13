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


## Purpose / Big Picture

Nagare's root `flake.nix` has grown to 667 lines. About 445 of them are one inline `checks`
attribute set containing roughly twenty shell-script derivations, and the rest mixes release
metadata, packages, apps, a networked CI job, and a developer shell with a hand-maintained Pulumi
override. Reading or changing any one of those concerns means scrolling past all the others.
Separately, the flake pins its own `nixos-unstable` nixpkgs (locked at `331800d`, 2026-05-31) and
its own GHC 9.12 package set, while the maintainer's other Haskell projects all share one toolchain
generation defined by the `haskell-nix-dev` base flake (`mori://shinzui/haskell-nix-dev`) through the
`nix-haskell-flake` Seihou module (`mori://shinzui/seihou-modules`, path
`modules/haskell/nix-haskell-flake`; the artifact-level Mori URI for Seihou modules is pending).
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
- [ ] Milestone 2: pass the derivation-equivalence gate on `aarch64-darwin` and `x86_64-linux`.
- [ ] Milestone 3: convert the wiring to flake-parts modules with a rev-pinned `flake-parts` input.
- [ ] Milestone 3: pass the derivation-equivalence gate on both systems.
- [ ] Milestone 4: record the current `nix-haskell-flake` pin in the Decision Log.
- [ ] Milestone 4: follow `haskell-nix-dev` for nixpkgs and flake-parts; add the Cachix `nixConfig`.
- [ ] Milestone 4: switch every `ghc912` reference to `ghc9124`.
- [ ] Milestone 4: disable Haddock for nagare's own Haskell packages (`cradle`, `nagare-dsl`,
      `nagarectl`) and confirm their derivations no longer have a `doc` output.
- [ ] Milestone 4: resolve the Pulumi override (drop it or refresh its hashes).
- [ ] Milestone 4: `nix flake check` passes on both systems; lock is immovable; `nixos/flake.lock`
      unchanged.
- [ ] Milestone 5 (optional): move large inline check scripts into `nix/checks/scripts/*.sh` and
      shellcheck them.
- [ ] Milestone 5 (optional): build the developer shells with `haskell-nix-dev`'s `mkDevShell` so HLS
      is substituted from Cachix.
- [ ] Milestone 5: update `README.md`, `.envrc`, and `agents/skills/nagare-release/SKILL.md`
      references; distill durable decisions into an ADR.


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

(To be filled during and after implementation.)


## Context and Orientation

A Nix flake is a directory with a `flake.nix` that declares `inputs` (other flakes, such as nixpkgs)
and `outputs` (packages, checks, developer shells). `flake.lock` records the exact revision of every
input. A derivation is Nix's build recipe; its `drvPath` is a store path such as
`/nix/store/abc…-nagarectl.drv` whose hash covers every input to the build, so two evaluations that
produce the same `drvPath` will build exactly the same thing. "IFD" (import from derivation) means
evaluation has to build something first; `callCabal2nix` does this, so evaluating the Haskell
packages for `x86_64-linux` needs a Linux builder. `follows` makes one input reuse another input's
dependency instead of locking its own copy. flake-parts is a small library that lets a flake be
written as a set of modules, each contributing `perSystem` outputs (per CPU/OS system) or top-level
`flake` outputs.

The root flake today (`flake.nix`) has these parts. Lines 12–32 read `release.json` (the platform
version and `supportedSystems`, currently `x86_64-linux` and `aarch64-darwin`), compute
`sourceRevision` from `self.rev` or `self.dirtyRev`, define `forAllSystems`, and define
`nagarePackagesFor pkgs`, which imports `nix/platform-package.nix` and `nix/haskell-packages.nix`.
`lib.release` (lines 34–38) exposes version, revision, and systems. `packages` (40–51) exposes
`nagarectl`, `nagare-platform`, `nagare`, `release-tools`, and `default`. `apps` (53–68) exposes
`nagarectl`, `nagare`, and `default`. `checks` (81–520) contains: `nagare-dsl-build-test`,
`nagarectl-build-test`, `nagare-platform-assets`, `infra-vm-shape`, `vm-shape-defaults-agree`,
`nagare-clone-free-platform` (a ~170-line script with fake `pulumi`, `nix`, `curl`, `gcloud`,
`gsutil`, and `kubectl` tools), `examples-compile`, `nagarectl-external-config`,
`shellcheck-scripts`, `bucket-ownership-guard`, `image-build-guard`, `render-context-template`,
`cluster-bootstrap-defaults`, `forge-credential-refresh`, `release-consistency-source`,
`github-actions`, and the Haskell formatting and house-style check `haskell-style`. `hydraJobs`
(526–545) holds `nagare-access-build-test`, a networked Cabal build
that needs `sandbox = relaxed` and a private-dependency token; CI builds it only on `x86_64-linux`.
`devShells` (547–665) holds `default` (Pulumi 3.239.0 and pulumi-nodejs overridden with fixed
`hash`/`vendorHash` values, nodejs 22, gcloud, kubectl, helm, k3d, sops, age, tailscale, jq, just,
`pkgs.haskell.compiler.ghc912`, cabal-install, ghc912 HLS, fourmolu, cabal-gild, zlib, postgresql,
pkg-config, and a `PULUMI_HOME` shellHook) and `haskell` (a smaller GHC shell).

`nix/haskell-packages.nix` (98 lines) overrides `pkgs.haskell.packages.ghc912` with `cradle` (from the
rev-pinned non-flake input `github:garnix-io/cradle/711c441…`), `nagare-dsl`, and `nagarectl`
(via `callCabal2nix ../cli/…`), and builds `typedConfigRuntime` (a `ghcWithPackages` containing
`nagare-dsl`, used by the installed CLI to `runghc` user configs), `checkedNagareDsl`,
`checkedNagarectl`, the wrapped `nagarectl`, and the `nagare` launcher. `nix/platform-package.nix`
(52 lines) builds the immutable platform payload from a `cleanSourceWith` filter over the repository
that excludes `cluster/secrets`, `.git`, build directories, and generated `Pulumi.<stack>.yaml`
files.

These checks initially took `src = ./.` (the whole flake source): `haskell-style`,
`infra-vm-shape`, `vm-shape-defaults-agree`, `examples-compile`, `nagarectl-external-config`, `shellcheck-scripts`,
`bucket-ownership-guard`, `image-build-guard`, `render-context-template`,
`cluster-bootstrap-defaults`, `forge-credential-refresh`, `release-consistency-source`, and
`github-actions`; the Hydra job did too. `cluster-bootstrap-defaults` greps the source for two Let's Encrypt URLs and
excludes `./flake.nix` from its "duplicated elsewhere" search because the check itself names them.

CI (`.github/workflows/ci.yml`) runs `nix flake check --print-build-logs --max-jobs 1` on
`ubuntu-latest` and builds `.#hydraJobs.x86_64-linux.nagare-access-build-test`.
`.github/workflows/release.yml` runs `nix flake check` natively per supported system and records
`nix path-info` for `.#nagarectl` and `.#nagare-platform`. Output names must therefore stay stable.
The workstation is `aarch64-darwin` and has a remote `x86_64-linux` builder configured in
`/etc/nix/machines` (`ssh://builder@nix-gcp-builder`), which Nix uses automatically for Linux IFD and
builds when reachable.

The alignment target. `haskell-nix-dev` at revision `206ecd25bcb4a07581210bdae3e6f43c8fd179d8`
pins nixpkgs `d5dfd8e6716dde34398bc14bc87c10dece9c8c68` (2026-09-10) by revision, re-exports
`flake-parts` (locked `31729ca…`, with `nixpkgs-lib` following its nixpkgs), `pre-commit-hooks`, and
`treefmt-nix`, supports systems `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`, and exposes
`lib.<system>.mkDevShell { ghc ? "ghc9124"; extraNativeBuildInputs ? []; withHls ? …; shellHook ? ""; }`
which returns a `mkShell` with the GHC compiler, cabal-install, pkg-config, zlib, and (for `ghc9124`)
an HLS built with library profiling disabled and pushed to `https://shinzui.cachix.org`
(public key `shinzui.cachix.org-1:QEmAoJrA9WwLP0uxfDgktLi2BRrcvQQWdz8NzcMg4/E=`). The
`nix-haskell-flake` module's template writes exactly
`haskell-nix-dev.url = "github:shinzui/haskell-nix-dev/<rev>"`, `nixpkgs.follows = "haskell-nix-dev/nixpkgs"`,
and `flake-parts.follows = "haskell-nix-dev/flake-parts"`, plus that `nixConfig`. Its invariant is
that a rev-pinned URL cannot be moved by `nix flake update`, so the whole locked graph is a function
of that one revision. The module version may have moved by the time this plan is implemented; the
current pin is read from the module template in Milestone 4.

Relevant ADRs. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) makes Nix by
immutable tag the distribution channel, makes `release.json` the source of truth for supported
systems, and requires each supported system to pass the flake checks natively; this plan must keep
output names, `lib.release`, and systems unchanged. [ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md)
packages the typed-config runtime (`typedConfigRuntime`) with `nagarectl`; the GHC attribute change in
Milestone 4 rebuilds it and the `examples-compile` and `nagarectl-external-config` checks prove it
still works. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
defines the immutable platform payload; Milestone 1 changes its source filter, and the
`nagare-platform-assets` and `nagare-clone-free-platform` checks prove its content contract.
[ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) sets GHC 9.12 as the house
toolchain, which `ghc9124` keeps. [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)
is the reason the host flake is excluded. No ADR yet records how the root flake's pins are chosen;
Milestone 5 adds one.


## Plan of Work

### Milestone 1 — exclude Nix wiring from check and payload sources

Scope: create `nix/source.nix` and route every whole-repository `src` through it. At the end, editing
`flake.nix`, `flake.lock`, or anything under `nix/` no longer changes the `drvPath` of any check or of
`nagare-platform`. This milestone intentionally changes those `drvPath` values once, so its gate is
`nix flake check` plus a demonstration that a wiring edit is now invisible.

Create `nix/source.nix`:

```nix
# The repository source that checks and the platform payload build from. The Nix wiring
# itself (root flake.nix, flake.lock, and nix/) is excluded, so refactoring the flake does
# not change any check's derivation and editing it does not re-run every check.
{ lib, root }:

let
  rootString = toString root;
  isNixWiring = path:
    let p = toString path;
    in p == "${rootString}/flake.nix"
      || p == "${rootString}/flake.lock"
      || p == "${rootString}/nix"
      || lib.hasPrefix "${rootString}/nix/" p;
in
{
  inherit isNixWiring;
  src = lib.cleanSourceWith {
    name = "nagare-source";
    src = root;
    filter = path: _type: !(isNixWiring path);
  };
}
```

In `flake.nix`, bind `nagareSource = import ./nix/source.nix { inherit (nixpkgs) lib; root = ./.; };`
in the top-level `let`, and replace every `src = ./.;` in `checks` with `src = nagareSource.src;`.
In `nix/platform-package.nix`, add a `isNixWiring` argument (pass `nagareSource.isNixWiring` from
`nagarePackagesFor`) and add `&& !(isNixWiring path)` to the existing filter. Leave the
`-e '^\./flake\.nix$'` exclusion in `cluster-bootstrap-defaults` as it is: it becomes a no-op, and
editing the script text now would only add noise to Milestone 2's gate (Milestone 5 removes it).

Acceptance: `nix flake check` passes; the payload still has no `flake.nix` at its root (it never
did); and the "wiring edit is invisible" demonstration in Concrete Steps shows identical `checks`
`drvPath` values before and after appending a comment to `flake.nix`.

### Milestone 2 — split the flake into plain Nix files

Scope: move code out of `flake.nix` without changing behaviour, still using `forAllSystems`. At the
end, `flake.nix` is under about 80 lines and each concern lives in its own file. The gate is exact:
every output's `drvPath` (and each app's `program` string, `lib.release`, and the list of output and
attribute names) is identical before and after, on both systems.

Create these files; each is a function taking only what it uses:

- `nix/nagare-packages.nix` — `{ pkgs, nagareSource, releaseVersion, sourceRevision, cradle }`, the
  body of today's `nagarePackagesFor`.
- `nix/packages.nix` — `{ pkgs, nagarePackages }`, returns the `packages` attribute set.
- `nix/apps.nix` — `{ nagarePackages }`, returns the `apps` attribute set.
- `nix/pulumi.nix` — `{ pkgs }`, returns `{ pulumi, pulumi-nodejs }` with the override and its
  comments moved verbatim.
- `nix/dev-shells.nix` — `{ pkgs, pulumi }`, returns `{ default, haskell }`.
- `nix/hydra-jobs.nix` — `{ pkgs }`, returns `{ nagare-access-build-test }`.
- `nix/checks/default.nix` — `{ pkgs, nagarePackages, src }`, returns the union (`//`) of the
  domain files below, each with the same signature.
- `nix/checks/haskell.nix` — `nagare-dsl-build-test`, `nagarectl-build-test`, `examples-compile`,
  `nagarectl-external-config`.
- `nix/checks/platform.nix` — `nagare-platform-assets`, `nagare-clone-free-platform`,
  `release-consistency-source`.
- `nix/checks/infra.nix` — `infra-vm-shape`, `vm-shape-defaults-agree`.
- `nix/checks/scripts.nix` — `shellcheck-scripts`, `bucket-ownership-guard`, `image-build-guard`,
  `render-context-template`, `forge-credential-refresh`, `cluster-bootstrap-defaults`.
- `nix/checks/ci.nix` — `github-actions`.

Move each derivation's text verbatim. Nix indented strings (`'' … ''`) strip the common leading
indentation, so re-indenting a whole block is safe, but changing relative indentation, a character in
a script, a `nativeBuildInputs` order, or a derivation name changes the `drvPath` and fails the gate.
Keep the explanatory comments with the code they describe. Keep `lib.release` and the `release.json`
reading in `flake.nix`. Add `watch_file flake.nix nix/*.nix nix/checks/*.nix` to `.envrc` directly
before `use flake`, because nix-direnv watches only `flake.nix` and `flake.lock` and would otherwise
keep a stale shell after a module edit.

Acceptance: the derivation-equivalence gate in Concrete Steps reports no difference for
`aarch64-darwin` and `x86_64-linux`, and `nix flake check` passes.

### Milestone 3 — adopt flake-parts

Scope: express the flake as flake-parts modules, again with no derivation change. At the end,
`flake.nix` calls `flake-parts.lib.mkFlake` and imports modules; the Milestone 2 files become
flake-parts modules or are called from them.

Add the input:

```nix
inputs.flake-parts = {
  url = "github:hercules-ci/flake-parts/31729ca8cbdb4fa927b34e5f4353e6a83f39e993";
  inputs.nixpkgs-lib.follows = "nixpkgs";
};
```

Write `outputs = inputs@{ self, nixpkgs, flake-parts, cradle, ... }: flake-parts.lib.mkFlake { inherit inputs; } ({ withSystem, ... }: { … })`
with `systems = releaseMetadata.supportedSystems;` (read `release.json` in a `let` before `mkFlake`),
`flake.lib.release = { … };`, and `imports = [ ./nix/nagare-packages.nix ./nix/packages.nix … ]`.
Convert the files as follows. `nix/nagare-packages.nix` becomes a module that sets
`perSystem._module.args.pkgs = import nixpkgs { inherit system; }` (flake-parts' default is
`inputs'.nixpkgs.legacyPackages`; setting it explicitly guarantees the same package set as
`forAllSystems` did) and provides the shared value as `perSystem._module.args.nagarePackages`, so other
modules receive `{ pkgs, nagarePackages, ... }`. `packages.nix`, `apps.nix`, `dev-shells.nix`, and
`checks/default.nix` each become `{ ... }: { perSystem = { pkgs, nagarePackages, ... }: { packages = …; }; }`,
and the domain check files stay plain functions imported by `checks/default.nix`. `flake-parts` has no
per-system `hydraJobs` option, so `nix/hydra-jobs.nix` sets
`flake.hydraJobs = lib.genAttrs systems (system: withSystem system ({ pkgs, ... }: { nagare-access-build-test = …; }))`,
using the `withSystem` and `config.systems` module arguments. `pulumi.nix` stays a plain function
called from `dev-shells.nix`.

flake-parts may add empty top-level outputs (for example `nixosModules = { }` or `overlays = { }`).
If the gate's output-name list differs only by such empty attribute sets, record it in Surprises &
Discoveries and the Decision Log and accept it; any non-empty difference fails the gate.

Acceptance: the derivation-equivalence gate reports no difference on both systems (subject to the
empty-output rule), `nix flake check` passes, and `nix flake metadata --json | jq '.locks.nodes | keys'`
shows exactly one `nixpkgs` node.

### Milestone 4 — follow haskell-nix-dev and move to ghc9124

Scope: the first milestone that changes what gets built. At the end, nixpkgs and flake-parts come
from the rev-pinned `haskell-nix-dev` input, the Haskell package set is `ghc9124`, Cabal/GHC come from
cache.nixos.org, the Cachix substituter is declared, and all checks pass on both systems.

Read the current pin from the module template (see Concrete Steps) and record the `haskell-nix-dev`
revision and its nixpkgs revision in the Decision Log. Replace the `nixpkgs` and `flake-parts` inputs
with:

```nix
inputs = {
  haskell-nix-dev.url = "github:shinzui/haskell-nix-dev/<rev from the module template>";
  nixpkgs.follows = "haskell-nix-dev/nixpkgs";
  flake-parts.follows = "haskell-nix-dev/flake-parts";
  cradle = { url = "github:garnix-io/cradle/711c441fa8f190a8964c56a3bae864cd5321c5c5"; flake = false; };
};

nixConfig = {
  extra-substituters = [ "https://shinzui.cachix.org" ];
  extra-trusted-public-keys = [ "shinzui.cachix.org-1:QEmAoJrA9WwLP0uxfDgktLi2BRrcvQQWdz8NzcMg4/E=" ];
};
```

Replace `ghc912` with `ghc9124` in `nix/nagare-packages.nix`/`nix/haskell-packages.nix`
(`pkgs.haskell.packages.ghc9124`), `nix/hydra-jobs.nix` (`pkgs.haskell.compiler.ghc9124`), and
`nix/dev-shells.nix` (compiler, HLS, fourmolu, cabal-gild).

Disable Haddock for the three packages the flake defines. Haddock is GHC's API-documentation
generator; nixpkgs runs it by default for every Haskell library and puts the result in a separate
`doc` output, which nagare never uses. In the `overrides` of the Haskell package set (in
`nix/haskell-packages.nix`, or wherever Milestones 2–3 left it), wrap `cradle`, `nagare-dsl`, and
`nagarectl` in `pkgs.haskell.lib.dontHaddock`, composed with the existing `dontCheck`, for example
`cradle = hl.dontHaddock (hl.dontCheck (hfinal.callCabal2nix "cradle" cradleSrc { }));` with
`hl = pkgs.haskell.lib;`. `checkedNagareDsl` and `checkedNagarectl` are built from those overridden
packages with `doCheck`, so they inherit the setting. Do not apply `dontHaddock` to the whole package
set; see the Decision Log. Then resolve Pulumi. Evaluate the new
nixpkgs' `pulumi.version`. If it is 3.239.0 or newer, delete `nix/pulumi.nix` and use
`pkgs.pulumi` and `pkgs.pulumiPackages.pulumi-nodejs` directly (a newer Pulumi CLI is acceptable for
existing state; an older one is not), and record the version in the Decision Log. If it is older, keep
the override and refresh `vendorHash` for both derivations by setting each to `lib.fakeHash`,
building the default developer shell, and copying the `got: sha256-…` value Nix prints; keep
`doCheck = false` and the `postInstall` for pulumi-nodejs. Fix any other evaluation failures the new
nixpkgs causes (for example a package marked insecure or renamed), recording each one in Surprises &
Discoveries.

Do not touch `nixos/`. The new nixpkgs rebuilds the whole Haskell closure once, locally and in CI;
the first `ubuntu-latest` CI run will be slow.

Acceptance: `nix flake check` passes on `aarch64-darwin`; every `checks.x86_64-linux.*` builds on the
Linux builder; `.#nagarectl`, `.#nagare`, and `.#nagare-platform` build on both systems and
`nagarectl --version` runs; the lock has a single `nixpkgs` node whose revision equals
`haskell-nix-dev`'s; `nix flake update` leaves `flake.lock` unchanged; `git diff --exit-code nixos/`
is clean; and `nix develop -c ghc --version` prints 9.12.4; and the `cradle`, `nagare-dsl`, and `nagarectl`
derivations (including `checkedNagareDsl` and `checkedNagarectl`) list no `doc` output and their
build logs contain no Haddock phase. The `hydraJobs` networked check is left
to CI because it needs a private token and a relaxed sandbox.

### Milestone 5 (optional) — script files, cached HLS, docs, ADR

Scope: readability and cache improvements that change derivations, gated by `nix flake check`, plus
documentation. Each part can be skipped independently; record any skip in the Decision Log.

Scripts. Move the inline scripts of `nagare-clone-free-platform`, `cluster-bootstrap-defaults`,
`nagarectl-external-config`, `examples-compile`, `vm-shape-defaults-agree`, and
`nagare-platform-assets` into `nix/checks/scripts/<check-name>.sh`, invoked from the derivation as
`bash ${./scripts/<check-name>.sh}`. Values the scripts currently interpolate from Nix (for example
`$payload`, `$src`, or a store path) are passed as derivation attributes, which become environment
variables. Add `nix/checks/scripts/*.sh` to `shellcheck-scripts` by giving that derivation a second
attribute pointing at `./scripts` (the directory is excluded from `nagareSource`, so it must be passed
separately). Remove the obsolete `-e '^\./flake\.nix$'` exclusion from `cluster-bootstrap-defaults`.

Cached HLS. In `nix/dev-shells.nix`, build `default` with
`inputs.haskell-nix-dev.lib.${system}.mkDevShell { ghc = "ghc9124"; withHls = true; extraNativeBuildInputs = [ …the other tools… ]; shellHook = …; }`
and `haskell` with `withHls = false`. Drop the now-duplicated compiler, cabal-install, HLS, zlib, and
pkg-config entries (mkDevShell supplies them); keep fourmolu and cabal-gild from
`pkgs.haskell.packages.ghc9124`. The shell loses its `name = "nagare"`; that is cosmetic.

Docs and ADR. Update the layout block in `README.md` to show `nix/` and `nix/checks/`, the comment
above `use flake` in `.envrc`, and the file list in `agents/skills/nagare-release/SKILL.md` (which
names `nix/platform-package.nix` and `nix/haskell-packages.nix`). Then write
`docs/adr/0017-the-root-flake-follows-the-shared-haskell-nix-dev-toolchain-pin.md` in the existing
filesystem convention (YAML frontmatter with `title`, `status`, `date`, `authors`, `related`; sections
Status, Context, Decision, Consequences), recording: the root flake's nixpkgs and flake-parts follow a
rev-pinned `haskell-nix-dev`; the toolchain moves only by bumping that revision to the one the
current `nix-haskell-flake` module ships; Seihou does not manage the root flake and why; the host
flake is independent; and Nix wiring is excluded from check sources.

Acceptance: `nix flake check` passes on both systems; `nix develop -c haskell-language-server --version`
reports GHC 9.12.4; the HLS store path is present in `https://shinzui.cachix.org` (Concrete Steps); and
the three docs no longer describe the old layout.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`, in a shell where
`nix` has flakes enabled. Stage files by explicit path (never `git add -A`; other work may be in
progress in the tree), and commit each milestone with a Conventional Commits message and the plan
trailers, for example:

```text
refactor(nix): exclude Nix wiring from check sources

ExecPlan: docs/plans/120-modularize-the-root-flake-and-align-it-with-the-shared-haskell-nix-dev-toolchain-pins.md
Intention: intention_01m2dhezayepwrcx6afxfbbaz9
```

New files must be tracked by git (at least staged) before any `nix` command, because a flake inside a
git work tree cannot see untracked files.

### The derivation-equivalence gate (Milestones 2 and 3)

The gate compares a "before" and an "after" tree that differ only in Nix wiring. Both are exported
from git so untracked build output is not copied, and both are evaluated as `path:` flakes so neither
has a git revision (which would otherwise flow into `nagarectl` and `nagare-platform` through
`sourceRevision`). `BASE` is the commit that finished the previous milestone and `CAND` is the
candidate commit.

```bash
BASE=<commit that finished the previous milestone>
CAND=HEAD
work="$(mktemp -d)"
mkdir -p "$work/after" "$work/before"
git archive "$CAND" | tar -x -C "$work/after"
( cd "$work/after" && tar -c . ) | tar -x -C "$work/before"
rm -rf "$work/before/flake.nix" "$work/before/flake.lock" "$work/before/nix"
git archive "$BASE" flake.nix flake.lock nix | tar -x -C "$work/before"

snapshot() {  # snapshot <tree> <system> <out.json>
  nix eval --impure --json --expr "
    let
      f = (builtins.getFlake \"path:$1\").outputs;
      s = \"$2\";
      drvs = builtins.mapAttrs (_: d: d.drvPath);
    in {
      outputNames = builtins.attrNames f;
      systems = builtins.attrNames f.checks;
      release = f.lib.release;
      packages = drvs f.packages.\${s};
      checks = drvs f.checks.\${s};
      devShells = drvs f.devShells.\${s};
      hydraJobs = drvs f.hydraJobs.\${s};
      apps = builtins.mapAttrs (_: a: a.program) f.apps.\${s};
    }" | jq -S . > "$3"
}

for system in aarch64-darwin x86_64-linux; do
  snapshot "$work/before" "$system" "$work/before-$system.json"
  snapshot "$work/after"  "$system" "$work/after-$system.json"
  diff -u "$work/before-$system.json" "$work/after-$system.json" && echo "gate: $system identical"
done
```

Expected output:

```text
gate: aarch64-darwin identical
gate: x86_64-linux identical
```

Evaluating `x86_64-linux` runs `cabal2nix` on the remote Linux builder (IFD). If the builder is
unreachable, Nix fails with a message saying a `x86_64-linux` system is required. In that case, record
it in Surprises & Discoveries, fix builder access if possible, and otherwise treat the `aarch64-darwin`
gate plus CI's `x86_64-linux` `nix flake check` as the evidence, noting that this is weaker. Any
`diff` output means the refactor changed something: find the named attribute and restore the moved
text exactly.

### Milestone 1 demonstration

Commit the Milestone 1 changes first, then run the check and the probe. The probe exports the
commit twice, appends a comment to `flake.nix` and adds a file under `nix/` in one copy, and compares
the `checks` derivations of both copies. It never edits the working tree.

```bash
nix flake check --print-build-logs
probe="$(mktemp -d)"
mkdir -p "$probe/plain" "$probe/edited"
git archive HEAD | tar -x -C "$probe/plain"
git archive HEAD | tar -x -C "$probe/edited"
printf '\n# wiring-edit probe\n' >> "$probe/edited/flake.nix"
printf '# probe\n{ }\n' > "$probe/edited/nix/probe.nix"
for tree in plain edited; do
  nix eval --impure --json --expr "
    builtins.mapAttrs (_: d: d.drvPath)
      (builtins.getFlake \"path:$probe/$tree\").outputs.checks.aarch64-darwin" \
    | jq -S . > "$probe/$tree.json"
done
diff -u "$probe/plain.json" "$probe/edited.json" && echo "wiring edits are invisible to checks"
```

Expected final line: `wiring edits are invisible to checks`. Running the same probe against the
commit before this milestone shows a diff for every check that used `src = ./.`, which is a useful
sanity comparison.

### Milestone 4 commands

Find the module's pin (the Seihou modules repository path comes from Mori):

```bash
modules="$(mori registry show shinzui/seihou-modules --full | sed -n 's/.*Path: *//p' | head -n 1)"
grep -n 'haskell-nix-dev.url' "$modules/modules/haskell/nix-haskell-flake/files/flake.nix.tpl"
jq -r '.nodes.nixpkgs.locked.rev' "$modules/modules/haskell/nix-haskell-flake/files/flake.lock"
```

At the time of writing this prints revision `206ecd25bcb4a07581210bdae3e6f43c8fd179d8` and nixpkgs
`d5dfd8e6716dde34398bc14bc87c10dece9c8c68`. After editing inputs:

```bash
nix flake lock
jq '[.nodes | to_entries[] | select(.value.locked.repo == "nixpkgs") | .key]' flake.lock
jq -r '.nodes.nixpkgs.locked.rev' flake.lock
nix eval --raw --impure --expr '(builtins.getFlake "git+file://'"$PWD"'").inputs.nixpkgs.legacyPackages.aarch64-darwin.pulumi.version'
nix eval --raw --impure --expr '(builtins.getFlake "git+file://'"$PWD"'").inputs.nixpkgs.legacyPackages.aarch64-darwin.haskell.compiler.ghc9124.version'
```

Expect one nixpkgs node named `nixpkgs` with the module's nixpkgs revision, and GHC `9.12.4`. For a
Pulumi hash refresh, after setting `vendorHash = pkgs.lib.fakeHash;`:

```bash
nix build --no-link .#devShells.aarch64-darwin.default 2>&1 | grep -E 'specified:|got:'
```

Confirm Haddock is off for the flake's own packages. Each command lists the derivation's outputs,
which must not include `doc`:

```bash
for check in nagare-dsl-build-test nagarectl-build-test; do
  nix eval --json ".#checks.aarch64-darwin.$check.outputs"
done
nix eval --json .#packages.aarch64-darwin.nagarectl --apply 'p: builtins.map (d: d.outputs or [ ]) p.paths'
nix log .#checks.aarch64-darwin.nagarectl-build-test | grep -c 'haddockPhase' || true
```

Expected: both check `outputs` lists contain no `"doc"` (with Haddock enabled nixpkgs adds `"doc"`
next to `"out"`), the `nagarectl` wrapper's underlying package likewise has no `"doc"`, and the log
search prints `0`. `nix log` only works after the check has been built on this machine; run it after
`nix flake check`.

Then validate:

```bash
nix flake check --print-build-logs
nix eval --json .#checks.x86_64-linux --apply builtins.attrNames \
  | jq -r '.[] | ".#checks.x86_64-linux." + .' \
  | xargs nix build --no-link --print-build-logs
nix build --no-link .#packages.x86_64-linux.nagarectl .#packages.x86_64-linux.nagare-platform .#packages.x86_64-linux.nagare
nix run .#nagarectl -- --version
nix develop -c ghc --version
nix flake update && git diff --exit-code flake.lock && echo "pins are immovable"
git diff --exit-code -- nixos/ && echo "host flake untouched"
```

Expected tail:

```text
The Glorious Glasgow Haskell Compilation System, version 9.12.4
pins are immovable
host flake untouched
```

### Milestone 5 cache probe

```bash
hls="$(nix eval --raw --impure --expr '(builtins.getFlake "git+file://'"$PWD"'").inputs.haskell-nix-dev.lib.aarch64-darwin.ghcVersions.ghc9124.hls.outPath')"
nix path-info --store https://shinzui.cachix.org "$hls" && echo "HLS is substitutable"
nix develop -c haskell-language-server --version
```

If `path-info` reports the path is missing, `haskell-nix-dev`'s CI has not pushed that revision; record
it in Surprises & Discoveries rather than building HLS in CI.


## Validation and Acceptance

The plan is complete when all of the following hold, each observed and recorded in Progress or
Outcomes & Retrospective with the command output.

Milestones 2 and 3 are proven behaviour-preserving by the derivation-equivalence gate printing
"identical" for both systems: every package, check, developer shell, and hydra job builds from the
same recipe as before, and apps point at the same programs. Milestone 1 is proven by
`nix flake check` passing and by the wiring-edit probe producing an empty diff.

After Milestone 4, `nix flake check` passes on `aarch64-darwin` and every `x86_64-linux` check builds
on the Linux builder; CI's `flake-check` and `nagare-access-check` jobs pass on the pushed commit.
The Haskell suites (`nagare-dsl-build-test`, `nagarectl-build-test`), the typed-config runtime checks
(`examples-compile`, `nagarectl-external-config`), and the clone-free install rehearsal
(`nagare-clone-free-platform`) are the behavioural evidence that the CLI, payload, and `runghc`
runtime still work on GHC 9.12.4. `nix run .#nagarectl -- --version` prints the version from
`release.json`. `nix flake update` leaves `flake.lock` unchanged, `flake.lock` contains one nixpkgs
node equal to `haskell-nix-dev`'s, and `nixos/` is unchanged.

After Milestone 5 (if done), `haskell-language-server --version` works in `nix develop` and the HLS
path is in the Cachix store, and ADR 17 exists.


## Idempotence and Recovery

Milestones 1–3 change only evaluation structure and can be retried freely: if a gate fails, compare
the named attribute's old and new text, fix it, amend the candidate commit, and re-run the gate. The
gate works in a temporary directory and never modifies the working tree. To abandon a milestone,
`git revert` its commit; nothing outside the repository is affected.

Milestone 4 changes the lock. `nix flake lock` is idempotent. To back out, revert the commit; the
previous `flake.lock` restores the old nixpkgs exactly. A failed build leaves nothing behind except
store paths that `nix store gc` can collect. `nix flake update` is safe here only because every input
is rev-pinned or follows one; if a future edit adds a branch-ref input, update it by name
(`nix flake update <input>`) instead.

No step touches cloud resources, the host, or any operator context. The only network use is fetching
inputs, substituting from caches, and dispatching builds to the configured Linux builder.


## Interfaces and Dependencies

Inputs at the end of the plan: `haskell-nix-dev` (rev-pinned, `mori://shinzui/haskell-nix-dev`),
`nixpkgs` following `haskell-nix-dev/nixpkgs`, `flake-parts` following `haskell-nix-dev/flake-parts`,
and `cradle` (rev-pinned, non-flake). The module template that decides the pin lives in
`mori://shinzui/seihou-modules` at `modules/haskell/nix-haskell-flake/files/flake.nix.tpl`.

Flake outputs must keep their names and shapes, because `.github/workflows/ci.yml`,
`.github/workflows/release.yml`, the release scripts, and operators depend on them:
`lib.release.{version,sourceRevision,supportedSystems}`;
`packages.<system>.{nagarectl,nagare-platform,nagare,release-tools,default}`;
`apps.<system>.{nagarectl,nagare,default}`; every `checks.<system>.*` name listed in Context and
Orientation; `hydraJobs.<system>.nagare-access-build-test`; and `devShells.<system>.{default,haskell}`.

Files and their contracts at the end of Milestone 3: `nix/source.nix` returns `{ src, isNixWiring }`;
`nix/haskell-packages.nix` keeps its argument set `{ pkgs, cradleSrc, platformPackage, sourceRevision }`
and its result attributes `checkedNagareDsl`, `checkedNagarectl`, `haskellPackages`, `nagare`,
`nagarectl`, `typedConfigRuntime`, `nagarePlatform`; `nix/platform-package.nix` takes
`{ pkgs, sourceRoot, isNixWiring, releaseVersion, sourceRevision }`; `nix/nagare-packages.nix`
provides `nagarePackages` (the `haskell-packages.nix` result) and `pkgs` to every `perSystem` module;
each file in `nix/checks/` other than `default.nix` is a function
`{ pkgs, nagarePackages, src }: { <check-name> = <derivation>; … }`. From Milestone 5, `nix/dev-shells.nix`
depends on `inputs.haskell-nix-dev.lib.<system>.mkDevShell` with the parameters `ghc`,
`extraNativeBuildInputs`, `withHls`, and `shellHook`.


## Revision Notes

- 2026-09-13: Milestone 4 now disables Haddock for the flake's own Haskell packages (`cradle`,
  `nagare-dsl`, `nagarectl`) with `pkgs.haskell.lib.dontHaddock`, with a Progress item, a Decision
  Log entry explaining why it is scoped to those packages and placed in Milestone 4, verification
  commands, and acceptance criteria. Requested by the operator to keep Nix builds fast, since Nix
  builds do not need API documentation.
