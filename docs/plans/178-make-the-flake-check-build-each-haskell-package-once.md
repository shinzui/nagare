---
id: 178
slug: make-the-flake-check-build-each-haskell-package-once
title: "Make the flake check build each Haskell package once"
kind: exec-plan
created_at: 2026-10-05T22:00:02Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-05T22:00:02Z
---

# Make the flake check build each Haskell package once

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`nix flake check` was the slowest step of every gate: 15–25 minutes on aarch64-darwin, and again on
x86_64-linux for `--all-systems`. Most of that was avoidable rework.

After this plan, the flake builds each Haskell package once per system, without a profiling pass. The
nagarectl tests read only `cluster/`. While revision stamping is off, a commit that changes no Haskell
source reuses the cached nagarectl build and test run. A maintainer sees this as a much shorter `just
gate` and `nix flake check`, with the same checks and the same tests.

The operator decided on 2026-10-05 that compile-time revision stamping stays off until MasterPlans
24, 25 and 26 are finished. Meanwhile the shipped wrapper reports the revision, so `nagarectl version
--json` still names the exact commit and release tooling keeps working.


## Progress

- [ ] M1: one nagarectl derivation per system, tested in place; no library profiling for Nagare's
  packages; `sourceForTests` holds only `cluster/`; compile-time stamping off behind `stampRevision`,
  with the wrapper reporting the revision.
  Acceptance: `nix flake check` passes on aarch64-darwin with the same check count. The shipped
  `packages.nagarectl` and `checks.nagarectl-build-test` reference the same nagarectl derivation,
  configured with `--disable-library-profiling`. The timing is recorded against the baseline below.
- [ ] M2: per-commit guidance follows ADR 25 decision 5: `just gate-fast` on every commit, and the full
  `nix flake check --all-systems` or `just gate` per push batch and candidate.


## Surprises & Discoveries

- Observation: before this plan, one aarch64-darwin `nix flake check` built three
  `nagarectl-0.4.0` derivations:
  - the tested build (revision stamped, tests on);
  - the shipped build (revision stamped, tests off);
  - the `buildEnv` wrapper, which compiles nothing.

  So nagarectl compiled twice. 605 of the log's 1,526 `Compiling` lines were profiling objects
  (`.p_o`), because the tested build passed `--enable-library-profiling`. Evidence: the darwin flake
  log of M1 of EP-174, and `nix derivation show` of the derivations (observed).
  Date: 2026-10-05

- Observation: the tested build's `sourceForTests` copied the whole repository (`${../.}`), so any
  change anywhere invalidated it. The tests read only `cluster/` through it, plus the DSL fixtures,
  which already have their own narrow path.
  Date: 2026-10-05


## Decision Log

- Decision: `nagare-dsl` keeps a separate tested derivation.
  Rationale: its loader tests compile fixture configs with a GHC that already contains `nagare-dsl`
  (`typedConfigRuntime`). Testing in place would make the package depend on itself. It is 61 modules;
  nagarectl (272 modules) is the expensive one and has no such cycle.
  Date: 2026-10-05

- Decision: compile-time stamping is off behind `stampRevision = false` in
  `nix/haskell-packages.nix` until MasterPlans 24, 25 and 26 are finished. The shipped `nagarectl`
  wrapper sets `NAGARE_SOURCE_REVISION` from the flake's revision, and `Nagare.Version` falls back to
  it, reading it once per process, when nothing is compiled in.
  Rationale: operator decisions, 2026-10-05: keep knowing what is running ("helps knowing what we're
  running"), remove the compiled revision for the next MasterPlans, and keep it off until MP-24 to
  MP-26 are done. The operator chose the wrapper over flipping the switch for MP-23's freeze or
  changing the release scripts. The release scripts read `version --json` from the wrapped package,
  so they work unchanged. No flake check asserts the revision.
  Date: 2026-10-05


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

- **`nix/haskell-packages.nix`** builds the Haskell package set:
  - `nagare-dsl`, `nagarectl` and `nagare-harness`;
  - `checkedNagareDsl` and `checkedNagarectl`, used by `nix/checks/haskell.nix` as
    `nagare-dsl-build-test` and `nagarectl-build-test`;
  - `sourceForTests`;
  - the wrappers `nagarectl`, `operatorNagarectl` and `nagare`.
- **`sourceRevision`** comes from `flake.nix` (`self.rev` or `self.dirtyRev`). `postPatch` wrote it
  into `cli/nagarectl/src/Nagare/Version.hs`.


## Plan of Work

1. Add `stampRevision` and a `nagarePackage` helper that disables Haddock and library profiling.
2. Make `haskellPackages.nagarectl` the tested derivation, with the test-path substitutions and
   `preCheck`, and alias `checkedNagarectl` to it.
3. Narrow `sourceForTests` to `cluster/`.
4. Keep `checkedNagareDsl` as a separate tested build of the profiling-free `nagare-dsl`.
5. Make `Nagare.Version` fall back to `NAGARE_SOURCE_REVISION`, have the `nagarectl` wrapper set it,
   and point the runbook at the wrapped binary.


## Concrete Steps

```bash
nix flake check -L     # aarch64-darwin, from a clean worktree; compare with the baseline log
```

Baseline: the same commit before this change, plus a one-line Haskell comment change, timed with
`time nix flake check -L`. After: the same probe on top of this change.


## Validation and Acceptance

- `nix flake check` passes with the same number of checks.
- `nix-store -q --references` of the shipped `packages.aarch64-darwin.nagarectl` derivation names the
  same nagarectl `.drv` as `checks.aarch64-darwin.nagarectl-build-test`.
- `nix derivation show` of that `.drv` contains `--disable-library-profiling`.
- Timings for the baseline and the change are recorded in Outcomes.


## Idempotence and Recovery

The change is in Nix expressions only. Reverting the commit restores the old derivations. Setting
`stampRevision = true` restores the stamped revision.


## Interfaces and Dependencies

No interface changes. `nagarectl version --json` from the shipped wrapper still reports the revision.
The unwrapped binary reports none while compile-time stamping is off.
