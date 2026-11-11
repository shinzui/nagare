---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Line caps forced restructuring mid-feature](1-line-caps-forced-restructuring-mid-feature.md) - Hard line caps on Inventory/Store.hs (1000), Cli/Dispatch.hs (200) and test Suite.hs (300) each failed the architecture check after a few added lines and forced a constructor merge, a re-export and a regrouping.
- [The fast gate's audit and mutation steps failed one at a time for a new subcommand and a new update kind](10-the-fast-gate-s-audit-and-mutation-steps-failed-one-at-a-time-for-a-new-subcommand-and-a-new-update-kind.md) - Adding delegation credentials and Role to the adapter's update list cost three fast-gate runs: the command audit hid its unregistered-constructor error (FRIC-2 again), then wanted a refreshed catalogue snapshot, then a mutation record no longer applied.
- [New CLI command needs undocumented audit registration](2-new-cli-command-needs-undocumented-audit-registration.md) - A new Command constructor must be registered in scripts/audit-managed-commands.py with a coverage family and a catalogue row; nothing at build or style time says so, and the fast gate went red only at architecture-and-command-audit with a log that hides the error.
- [Cross-system IFD serialises the x86_64-linux auth package set evaluation](3-cross-system-ifd-serialises-the-x86-64-linux-auth-package-set-evaluation.md) - Evaluating the x86_64-linux release-image outputs from the aarch64-darwin workstation runs every callCabal2nix import-from-derivation as a separate remote build, one at a time, before any package compiles.
- [A rebuild check cannot run through the remote builder](4-a-rebuild-check-cannot-run-through-the-remote-builder.md) - nix build --rebuild of x86_64-linux image derivations from the aarch64-darwin workstation fails with 'local builds are disabled (max-jobs = 0)' although the builder is running, so a determinism check needs a shell on the builder.
- [The fast gate checks the last commit and ignores uncommitted work](5-the-fast-gate-checks-the-last-commit-and-ignores-uncommitted-work.md) - just gate-fast defaults to HEAD, so running it before committing spends minutes gating the previous revision while appearing to check the change.
- [A broken IPv6 path stops every intranet command from the workstation](6-a-broken-ipv6-path-stops-every-intranet-command-from-the-workstation.md) - gcloud and nagarectl try IPv6 first and spend their whole timeout on it, so a home router losing IPv6 looked like store and ownership failures and left one transaction ambiguous.
- [nix flake check --all-systems cannot leave out one system](7-nix-flake-check-all-systems-cannot-leave-out-one-system.md) - Nix's flake check has no way to skip a system, so publishing tooling for a system the landing gate cannot build forces a flake input the gate overrides.
- [Fixed line caps on the test suite assembler and CLI dispatch push new groups into unrelated modules](8-fixed-line-caps-on-the-test-suite-assembler-and-cli-dispatch-push-new-groups-into-unrelated-modules.md) - Nagare.Test.Suite is capped at 300 lines and Nagare.Cli.Dispatch at 200, both already at the cap, so each new test group or command had to be hooked into an unrelated spec module or squeezed by reformatting imports.
- [The 1000-line cap on Nagare.Target turned a 17-line fix red at the fast gate](9-the-1000-line-cap-on-nagare-target-turned-a-17-line-fix-red-at-the-fast-gate.md) - Nagare.Target sat 11 lines under the architecture check's 1000-line cap, so adding one documented function failed the fast gate and forced a second commit and two more packaged builds during a live run.
