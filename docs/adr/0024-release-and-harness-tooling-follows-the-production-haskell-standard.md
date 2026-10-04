---
title: "Release and harness tooling follows the production Haskell standard"
status: accepted
date: 2026-10-04
authors: [shinzui]
related:
  - docs/adr/0016-adopt-haskell-jitsurei-for-production-haskell.md
  - docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
  - docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md
  - docs/plans/168-script-the-local-acceptance-run-as-one-command.md
  - docs/plans/171-move-release-tooling-out-of-the-platform-payload.md
---

# ADR 24 — Release and harness tooling follows the production Haskell standard

## Status

Accepted, 2026-10-04, by operator decision during MasterPlan 23's native verification.

## Context

Production code follows [ADR 16](0016-adopt-haskell-jitsurei-for-production-haskell.md): Haskell
under the haskell-jitsurei standards, a style gate, a per-module size ratchet, and tests. The code
that proves a release has no standard.
- Release, verification-harness and audit tooling grew as shell scripts plus Python.
- By 2026-10-04, `scripts/` held 42 Python files, about 7,700 lines, touched in 76 commits in one month.
- The session drivers that ran MasterPlan 23's acceptance runs used untested inline Python blocks to shape evidence.

MasterPlan 23 showed what this costs:
- **F42.** The managed-resource evidence assembler compared a review's planner digest with the compile-manifest digest. Those can never be equal, so the assembler could not accept real CLI output. Its tests passed only because they used hand-made fixtures, and its error message hid the mismatch.
- **Implicit contracts.**
  - The rehearsal runner and the assembler had an evidence-layout contract that nobody wrote down: the runner's plan, apply and verify must run back to back.
  - The acceptance drivers broke that contract, and a full local run for candidate `7d486457` could not be assembled.
  - Each tool re-parses the CLI's JSON by hand, so nothing ties its idea of a review, an export or a receipt to the types the CLI actually writes.
- **No ownership.** Each session added its own helper in whatever form was fastest mid-run. The result works, but nobody can safely maintain it, and it ships inside the platform payload ([EP-171](../plans/171-move-release-tooling-out-of-the-platform-payload.md)).

## Decision

1. New release, verification-harness and audit tooling is written in Haskell in the repository's cabal workspace. It follows ADR 16 and the haskell-jitsurei standards, and it passes the same gates as production code: `just haskell-style-check`, `scripts/check-haskell-architecture.py` and the test suites.
2. The tooling reuses `nagarectl`'s library types for reviews, inventory exports, run records and evidence, instead of re-parsing their JSON. When an evidence format changes, the tooling stops compiling instead of passing silently.
3. Its tests use real CLI output as fixtures, alongside focused unit cases. An evidence check that has only ever passed against hand-made input is not done.
4. Shell is allowed only as thin glue: invoking processes, wrappers and the cluster. No Python embedded in shell, and no evidence shaping in shell.
5. Existing Python and shell tools are frozen. Bug fixes are allowed. Adding a feature means porting that tool first. Each MasterPlan 26 stream ports the tools it touches. [EP-168](../plans/168-script-the-local-acceptance-run-as-one-command.md) starts with the local acceptance runner and the evidence helpers it composes.
6. The tooling lives outside the platform payload ([EP-171](../plans/171-move-release-tooling-out-of-the-platform-payload.md)), so fixing a tool does not mint a release candidate.

## Consequences

- Writing a tool takes longer than writing a script. Changing one is safer: format drift becomes a compile error, and the gates apply.
- The F42 class of defect, where a check is right only against invented input, becomes unlikely.
- There is one language and one standard to maintain. Reviewers apply the same rules to tooling as to the CLI.
- Until the ports land, the frozen scripts remain in use. The runbook's procedure, not the scripts, is the reference for how a run must be done.
