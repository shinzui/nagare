# C4 on the final candidate `3b59bcb7`

nagare-verify ran this on 2026-10-09: the clone-free installed rehearsal (`scripts/rehearse-clone-free-release.sh --version 0.4.0`)
against the candidate's exact revision, on both systems in `release.json`. Both pass, `cloneFree: true`, with all 11
checks, including `typed-config` and `local-init`. Since F85's fix, every operator step runs on an isolated PATH, so the
pass covers a host without npm.

- **aarch64-darwin:** run from a clean candidate worktree, 67 s, exit 0 (`clone-free-aarch64-darwin.json`, `.log`).
- **x86_64-linux:** run in an amd64 `nixos/nix:2.35.2` container under the Colima profile `nagare-c4-amd64` (vz with
  Rosetta, 4 CPU, 16 GiB), 63 s, exit 0, with nothing built in the container (`clone-free-x86_64-linux.json`, `.log`,
  `x86.sh`). The source is a git bundle of the candidate. Substitution uses a file cache holding the gate's x86_64
  outputs and the ten eval-time `cabal2nix-*` IFD outputs (`ifd.txt`), plus cache.nixos.org.
  `always-allow-substitutes = true` is needed because nixpkgs marks those IFD derivations `allowSubstitutes = false`;
  building them under emulation fails.

The `nix flake check --all-systems` part of C4 is the candidate's green gate record (36/36 x86_64-linux, 37/37
aarch64-darwin).
