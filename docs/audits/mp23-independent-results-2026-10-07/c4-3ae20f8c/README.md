# C4 (EP-154) on candidate 3ae20f8c (2026-10-07)

Session `mp23-c3i`, on brief from `nagare-verify`. No cloud mutation. Every value below was observed.

## nix flake check --all-systems (cited, not rerun)

Gate record `~/.local/state/nagare/gates/3ae20f8c9ed5bcfaa1681a7c3a3a927d6ede773b.json` (sha256
`daedebb1a0bec5359c727fe380809ee959a7796cbad9a50c6cb3b227daa34b0b`): commit `3ae20f8c9ed5…`, clean,
green, tree `f93114988654…`. Step `nix-flake-check` ran `nix flake check --all-systems --print-build-logs`,
exit 0 in 1722 s. Systems: aarch64-darwin 37/37 checks realised, x86_64-linux 36/36. `just gate-verify`
printed `green`.

## aarch64-darwin: passed, but depends on the host's npm

`scripts/rehearse-clone-free-release.sh --version 0.4.0 --flake-ref
'git+file:///private/tmp/nagare-cand-3ae20f8c-src?rev=3ae20f8c9ed5bcfaa1681a7c3a3a927d6ede773b'`, run
from the clean candidate worktree, exited 0 in 514 s. The report is `clone-free-aarch64-darwin.json`:
`cloneFree: true`, revision `3ae20f8c9ed5…`, system `aarch64-darwin`, pulumi `v3.255.0`,
`platformUpgrade` planned with 1 preview call. Its checks include `typed-config`.

The `local-init` check (`nix run <ref>#nagare -- --dry-run local-up`) inherits the workstation PATH,
which has nodejs 22.23.2. `darwin-no-npm.log` reruns that one step with PATH reduced to bash, git,
mkdir and nix: exit 1, `could not run npm ci for the Pulumi program (Node.js and npm are required)`.
With the host PATH, the same step exits 0.

## x86_64-linux: fails at local-init (npm missing)

The documented path is an amd64 container under Colima. A separate profile, `nagare-c4-amd64` (vz with
Rosetta, 4 CPU, 8 GiB), ran `nixos/nix:2.35.2` with `--platform linux/amd64`. That is the same Nix
version as the workstation's Determinate Nix. Substitution used a file cache exported from the
workstation's own x86_64-linux candidate outputs (realised by the gate) plus cache.nixos.org. The
source came from a git bundle of the candidate worktree. Script: `x86_64-linux-in-container.sh`.

1. `nixos/nix:2.28.3` failed while re-locking: `cannot find flake 'flake:treefmt-nix'` (log
   `x86_64-linux-run-nix-2.28.3-failed.log`). Nix 2.28 treats the lock as stale. With Nix 2.35.2 the
   flake evaluates unchanged.
2. With Nix 2.35.2, `packages.x86_64-linux.nagarectl` evaluated to the gate's
   `/nix/store/1wzyh25mvpnw7f389p6zkcdn1pwlbiqr-nagarectl-0.4.0`, and `nagare` to
   `/nix/store/pvfai11da50fw24r8md581ih0q5ic46i-nagare-0.4.0`. The rehearsal then exited 1
   (`x86_64-linux-run-nix-2.35.2-attempt1.log`).
3. A `bash -x` rerun (`x86_64-linux-diag-bash-x.log`) passed these checks: version, operator version
   and tools (pulumi v3.255.0), context, inventory compile, **typed-config** (`app check` on the
   multi-workload `Config.hs`; jq assertion passed), platform root and payload source tag
   `3ae20f8c9ed5`. It failed at `run_operator --dry-run local-up`.
4. `local-up-diag.log` reruns that step alone: `nagarectl: npm ci failed in …/infra/pulumi (exit 127)`.
   The container has no npm.

Rosetta side note: `app check` printed `.nagarectl-wrapped: Ticker: poll failed: Interrupted system
call` twice. This is the GHC RTS timer under Rosetta emulation; the check still passed.

## Finding (for the tracker; the operator decides on any deferral)

The installed `nagare` operator recipe needs `npm` from the host. `nagarectl`'s Pulumi runtime runs
`npm ci` (`cli/nagarectl/app/Nagare/Cli/Runtime/Pulumi.hs:149-152`), but `operatorTools` in
`nix/haskell-packages.nix:139-146` supplies pulumi and pulumi-nodejs and not nodejs/npm. So
`nagare local-up` fails on a clean host on both systems. The clone-free rehearsal hides this: it
isolates PATH only for `run_target_operator_cli`, not for `run_operator`. EP-154's acceptance asks
that "every … transport script and typed-config capability the supported commands need is present in
the installed outputs". This is not a data-loss risk.

## Result

- aarch64-darwin: report written, with `typed-config`; passing depends on host npm.
- x86_64-linux: no passing report. Everything up to and including `typed-config` passes;
  `local-init` fails on the missing npm.
- C4 is not complete at `3ae20f8c`.
