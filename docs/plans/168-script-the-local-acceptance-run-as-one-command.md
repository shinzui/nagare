---
id: 168
slug: script-the-local-acceptance-run-as-one-command
title: "Script the local acceptance run as one command"
kind: exec-plan
created_at: 2026-10-04T04:49:45Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-04T04:49:45Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-04T14:16:36Z
      mode: "update"
      note: "Haskell per ADR 24; one evidence directory, runner last, staged records"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-10T02:46:57Z
      mode: "update"
      note: "Reference EP-183 (v0.4.0 intranet gaps)"
---

# Script the local acceptance run as one command

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [168-script-the-local-acceptance-run-as-one-command.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/168-script-the-local-acceptance-run-as-one-command.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today the local release acceptance for a Nagare candidate (called C2 in [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md)) is run by a person typing hundreds of commands: bootstrapping a fresh local cluster, deploying a scenario, killing applies at chosen moments, backing up and restoring every database, stopping the cluster for a recovery drill, and finally assembling evidence. The first run took most of a day; a later run with session-local scripts took about fifty minutes of mostly unattended work. After this plan, a maintainer runs one command against a candidate package and gets, without further input, a finalized local health record with every required assertion and an assembled `inventory-evidence.json`, or a clear stop naming the step and the refusal.

You can see it working by running the command on the final MasterPlan 23 candidate `83124396` (v0.4.0) on the `nagare-mp23-cp3` Colima profile (or any profile sized like it) and finding `local-health.json` reporting 16 recorded assertions and `inventory-evidence.json` accepted by the assembler. This run is native run L1 of [MasterPlan 26](../masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md)'s finish line.

## Progress

**Cancelled (operator, 2026-10-14; MasterPlan 26 Decision Log).** No release reads the evidence this run assembles, and `scripts/release-rehearse.sh` bootstraps a fresh local context from the packaged CLI. Nothing below was started.

- [-] M1: The tool first runs the environment preflight and refuses unless every human dependency is settled: builder reachable, `gate verify` green for the candidate revision, only the expected Colima profile running, and for cloud contexts gcloud authenticated and the Tailscale key tagged `tag:nagare-test`. It then bootstraps a fresh local context from a candidate package, runs C1 on that payload, deploys the scenario with its interruption points, seeds every store, and leaves a converged, idle context. Acceptance: a run on `83124396` ends with the store idle and accepted equal to converged, and each preflight refusal is covered by a unit test. {disposition=declined}
- [-] M2: The tool runs every check in `fixtures/inventory-release/local/scenario.json`, including the source-unavailable drill, and records each assertion. Acceptance: `scripts/scenario-assertions.py finalize` reports all required assertions. {disposition=declined}
- [-] M3: After every scenario mutation, the tool runs the runner rehearsal: plan, apply and verify back to back in the evidence directory (one packaged CreateResource, apply, a verified no-op, every provider observable). It then replays the staged records and assembles `inventory-evidence.json`. Acceptance: the assembler accepts that same directory. {disposition=declined}

## Surprises & Discoveries

(None yet.)

## Decision Log

- Decision (superseded the same day): Write the runner in bash with small Python helpers, matching the existing `scripts/rehearse-*.sh` and `scripts/scenario-assertions.py`.
  Rationale at the time: The pieces it composes are already bash and Python.
  Date: 2026-10-04
- Decision: Write the acceptance tool in Haskell, per [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) (operator decision). It reuses `nagarectl`'s library types for reviews, exports, run records and evidence. It ports the evidence helpers it needs (scenario assertion records, the unchanged runner candidate, managed-resource assembly) instead of calling the frozen Python.
  Rationale: The shell-plus-Python drivers that ran MasterPlan 23's acceptance needed 17 untested inline Python blocks. The assembler's F42 defect, a check correct only against invented fixtures, came from the same style. One standard and shared types make evidence-format drift a compile error.
  Date: 2026-10-04
- Decision: There is one evidence directory, created by the runner's plan. The runner runs last. Checks write to a staging directory, and their records are deferred until the runner's plan exists.
  Rationale: The assembler requires the runner's plan, apply and verify back to back (`final-observation.accepted == review.desiredRevisions`), and the runner's plan refuses an existing directory. The first `7d486457` run broke this and could not be assembled.
  Date: 2026-10-04

- Decision: Port the driver set that passed C2 16/16 on `83124396`, stage for stage, rather than re-deriving the run. The set is archived as a frozen record in `docs/audits/mp23-independent-results-2026-10-07/drivers-83124396/` (`c2/`). Its stages are `setup`, `phase1`, C1, `phase2`, `phase2b`, `rebind-check`, `restores`, `misc`, `su`, `final-a`, `retire-kept`, `final-b` and `assemble`.
  Rationale: It is the only acceptance run known to pass unattended. Porting a passing sequence turns a design problem into a translation with fixture replay.
  Date: 2026-10-09
- Decision: This tool owns the environment preflight, and MasterPlan 25's teardown runner reuses it.
  Rationale: MasterPlan 23's overnight stalls were human dependencies: a Tailscale SSH check waiting for a browser approval for 3 h 40 m, gcloud re-authentication, and a builder that was off. A refusal at start costs seconds.
  Date: 2026-10-09
- Decision: Once [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md) EP-167 M3 lands reviewed local teardown, the tool runs it as its final stage, and `--replace-cluster` stops being the normal path.
  Rationale: Teardown then runs every release instead of rotting.
  Date: 2026-10-09

## Outcomes & Retrospective

Cancelled 2026-10-14 (MasterPlan 26 Decision Log). Nothing was built; `scripts/release-rehearse.sh` bootstraps a fresh local context today, and no release reads the evidence this run would have assembled.

