# Bundle Update Log

## 2026-11-11
* **Addition**: FRIC-8 records detour process friction with mori://shinzui/nagare: Fixed line caps on the test suite assembler and CLI dispatch push new groups into unrelated modules

## 2026-11-10

* **Update**: FRIC-7 resolved: Status set to resolved.


* **Addition**: FRIC-7 records detour tooling friction with https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake-check: nix flake check --all-systems cannot leave out one system

* **Addition**: FRIC-6 records blocked environment friction with mori://shinzui/nagare: A broken IPv6 path stops every intranet command from the workstation
* **Addition**: FRIC-5 records slowdown tooling friction with mori://shinzui/nagare: The fast gate checks the last commit and ignores uncommitted work

## 2026-10-31
* **Addition**: FRIC-4 records detour tooling friction with mori://shinzui/nagare: A rebuild check cannot run through the remote builder
* **Addition**: FRIC-3 records slowdown tooling friction with mori://shinzui/nagare: Cross-system IFD serialises the x86\_64-linux auth package set evaluation
* **Update**: FRIC-2 accepted: Status set to accepted.
* **Update**: FRIC-1 accepted: Status set to accepted.
* **Addition**: FRIC-2 records detour process friction with mori://shinzui/nagare/scripts/test-managed-command-audit.sh: New CLI command needs undocumented audit registration
* **Addition**: FRIC-1 records detour tooling friction with mori://shinzui/nagare/scripts/check-cli-architecture.py: Line caps forced restructuring mid-feature
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
