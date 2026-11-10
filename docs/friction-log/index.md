---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Line caps forced restructuring mid-feature](1-line-caps-forced-restructuring-mid-feature.md) - Hard line caps on Inventory/Store.hs (1000), Cli/Dispatch.hs (200) and test Suite.hs (300) each failed the architecture check after a few added lines and forced a constructor merge, a re-export and a regrouping.
- [New CLI command needs undocumented audit registration](2-new-cli-command-needs-undocumented-audit-registration.md) - A new Command constructor must be registered in scripts/audit-managed-commands.py with a coverage family and a catalogue row; nothing at build or style time says so, and the fast gate went red only at architecture-and-command-audit with a log that hides the error.
- [Cross-system IFD serialises the x86_64-linux auth package set evaluation](3-cross-system-ifd-serialises-the-x86-64-linux-auth-package-set-evaluation.md) - Evaluating the x86_64-linux release-image outputs from the aarch64-darwin workstation runs every callCabal2nix import-from-derivation as a separate remote build, one at a time, before any package compiles.
- [A rebuild check cannot run through the remote builder](4-a-rebuild-check-cannot-run-through-the-remote-builder.md) - nix build --rebuild of x86_64-linux image derivations from the aarch64-darwin workstation fails with 'local builds are disabled (max-jobs = 0)' although the builder is running, so a determinism check needs a shell on the builder.
- [The fast gate checks the last commit and ignores uncommitted work](5-the-fast-gate-checks-the-last-commit-and-ignores-uncommitted-work.md) - just gate-fast defaults to HEAD, so running it before committing spends minutes gating the previous revision while appearing to check the change.

