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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T23:37:33Z
      mode: "implement"
      note: "M1/M2 done; measured 25:53 -> 19:46 (Haskell), ~26 -> 3:37 (docs-only)"
---

# Make the flake check build each Haskell package once

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [178-make-the-flake-check-build-each-haskell-package-once.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/178-make-the-flake-check-build-each-haskell-package-once.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] (2026-10-05) M1, observed: `packages.nagarectl` and `checks.nagarectl-build-test` reference one
  nagarectl derivation configured with `--disable-library-profiling`. `nix flake check` passed with 52
  checks; timings are in Outcomes. Original acceptance: one nagarectl derivation per system, tested in place; no library profiling for Nagare's
  packages; `sourceForTests` holds only `cluster/`; compile-time stamping off behind `stampRevision`,
  with the wrapper reporting the revision.
  Acceptance: `nix flake check` passes on aarch64-darwin with the same check count. The shipped
  `packages.nagarectl` and `checks.nagarectl-build-test` reference the same nagarectl derivation,
  configured with `--disable-library-profiling`. The timing is recorded against the baseline below.
- [x] (2026-10-05) M2: the session memory (agent preflight rules) and `docs/runbooks/before-a-native-run.md` section 3
  already state the ADR 25 split. Agents now run `just gate-fast` per commit, and `nix flake check` or
  `just gate` per push batch and candidate, one at a time. Original acceptance: per-commit guidance follows ADR 25 decision 5: `just gate-fast` on every commit, and the full
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

**Timings: aarch64-darwin `nix flake check -L`, wall clock, observed 2026-10-05.** The cp3 Colima VM
was using about 1.7 cores for most of these runs.

| Run | Before | After |
|---|---|---|
| One-line Haskell change, warm cache | 25:53 (1,394 `Compiling` lines, 544 of them profiling) | **19:46** (485 lines, none profiling) |
| Docs-only change | about the same as a Haskell change: the stamped revision and the whole-repository test source invalidated nagarectl | **3:37** (nothing compiled) |
| First run on the new settings, a one-time cost | — | 39:10 (rebuilt `nagare-dsl`, `ghc-with-packages` and `nagare-harness` once) |

Every run passed with 52 checks.

**Where the remaining time goes.** A Haskell commit still costs about 20 minutes: one optimized
nagarectl compile, its 1,200-test run in the sandbox, and about 3.5 minutes of script checks whose
input is the whole source tree. Further options, not taken here:
- build the test suite at `-O0`;
- narrow the script checks' source input;
- incremental per-module builds (haskell.nix or Buck2).

The policy change in M2 matters more: per-commit feedback is `just gate-fast`, which takes about 4
minutes incrementally.

