# Bundle Update Log

## 2026-11-12

* **Update**: FRIC-16 accepted: Status set to accepted.


* **Update**: FRIC-15 accepted: Status set to accepted.


* **Addition**: FRIC-16 records detour tooling friction with mori://shinzui/nagare: The artifact transport reports success after failing under macOS bash 3.2


* **Addition**: FRIC-15 records detour tooling friction with mori://shinzui/mori: mori registry refuses to start on a projection catalog mismatch


* **Addition**: FRIC-14 records detour tooling friction with mori://shinzui/nagare: The packaged nagarectl's artifact transport needs a bash newer than macOS /bin/bash, and reports its failure as ambiguous


* **Addition**: FRIC-13 records detour tooling friction with mori://shinzui/mori: mori refuses to start on a projection catalog fingerprint mismatch

* **Addition**: FRIC-12 records detour tooling friction with mori://shinzui/nagare: just gate-fast without a revision gates master's HEAD from a worktree

## 2026-11-11

* **Update**: FRIC-11 resolved: Status set to resolved.


* **Update**: FRIC-10 accepted: Status set to accepted.


* **Addition**: FRIC-11 records slowdown environment friction with mori://shinzui/nagare/scripts/inventory-artifact-transport.sh: Linux host-tool assumptions in the deploy path surfaced one per 10-minute image build


* **Addition**: FRIC-10 records slowdown process friction with mori://shinzui/nagare/scripts/test-managed-command-audit.sh: The fast gate's audit and mutation steps failed one at a time for a new subcommand and a new update kind


* **Update**: FRIC-8 resolved: Operator decision 2026-11-11: registration lists grow by design, so their caps were raised and the misplaced groups returned.


* **Update**: FRIC-9 accepted: Accepted at MasterPlan 33's completion triage; the recurrence with FRIC-1 is recorded in the MasterPlan for the operator.


* **Update**: FRIC-8 accepted: Accepted at MasterPlan 33's completion triage; the recurrence with FRIC-1 is recorded in the MasterPlan for the operator.


* **Addition**: FRIC-9 records detour process friction with mori://shinzui/nagare: The 1000-line cap on Nagare.Target turned a 17-line fix red at the fast gate

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
