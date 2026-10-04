---
id: 26
slug: make-platform-changes-and-releases-routine-after-the-inventory-release
title: "Make platform changes and releases routine after the inventory release"
kind: master-plan
created_at: 2026-10-04T04:49:45Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-04T04:49:45Z
---

# Make platform changes and releases routine after the inventory release

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

[MasterPlan 23](23-make-managed-resources-first-class-through-typed-scoped-inventories.md) proves Nagare's typed inventory release with three native gates per frozen candidate: C1 (the candidate CLI against an installed local platform), C2 (a fresh local context bootstrapped with the candidate's own payload, running the full scenario) and C3 (the same on a fresh GCP context). In MasterPlan 23 every gate was driven by hand, every code change that ships in the payload minted a new candidate, every candidate required tearing down and rebuilding the shared local cluster, and in-place upgrades of an inventory context were explicitly out of scope. The first native runs were expensive because they also found defects in paths that had never run (F39-F44); that part was a one-time cost. The structure that remains would make every future platform change cost a full manual C1/C2/C3 cycle.

After this initiative, a maintainer changing Nagare pays a cost proportional to the change. A documentation or harness-only change needs no native evidence. A change to the CLI or payload runs the local acceptance as one command, locally or in CI, and produces the finalized, assembled evidence the release gate consumes. A fix to release tooling no longer mints a new platform candidate. And a new candidate can be rehearsed as an in-place, reviewed upgrade of an already converged inventory context instead of a teardown and rebuild, so a routine candidate is verified the way a running installation would actually move to it.

In scope: one scripted local acceptance run (the C2 scenario, its interruptions, restores, source-unavailable drill, runner rehearsal, finalize and assembly); running it in CI; a change-class-based release gate; separating release tooling from the platform payload; and a candidate-to-candidate upgrade rehearsal of a disposable inventory context, local first.

Out of scope: the upgrade policy for installations that hold work data, which belongs to [MasterPlan 24](24-operate-nagare-as-a-team-run-workplace-intranet-paas.md) (its planned "upgrade path for contexts holding work data" stream) and to [MasterPlan 21](21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md) (replacement upgrades with bounded downtime). This initiative proves upgrade mechanics on disposable rehearsal contexts and hands the evidence to those plans; it does not decide work-data policy. Also out of scope: weakening any MasterPlan 23 guarantee, GKE, mutating a real operator context, and full-context teardown (MasterPlan 25).

This initiative starts after MasterPlan 23 closes. EP-168 may begin earlier as harness-only work, but it must target the final MasterPlan 23 candidate's commands and evidence formats.


## Decomposition Strategy

The work splits by the kind of cost it removes, so each child is independently verifiable:

[EP-168](../plans/168-script-the-local-acceptance-run-as-one-command.md) removes manual operation: one maintained command runs the whole local acceptance on a fresh local context and produces finalized local health and assembled inventory evidence. Its acceptance is a green run on the then-current candidate.

[EP-169](../plans/169-run-the-local-acceptance-in-ci.md) removes the dependency on one maintainer's workstation and Colima profile: the same command runs in CI inside Docker (k3d in a Docker-in-Docker job) for every candidate.

[EP-170](../plans/170-size-the-release-gate-to-the-change.md) removes over-verification: the release gate classifies the change between the last accepted candidate and the new one and requires only the evidence that class needs.

[EP-171](../plans/171-move-release-tooling-out-of-the-platform-payload.md) removes candidate churn from tooling fixes: release assembly, evidence and audit scripts move out of the shipped payload into a versioned harness, so fixing them does not change the platform payload.

[EP-172](../plans/172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md) removes the rebuild-per-candidate cost and proves what a running installation experiences: a converged context on the previous candidate is upgraded through the reviewed `platform upgrade` path to the new candidate, then re-verified.

Alternatives considered: one ExecPlan for all of it (rejected, because CI, gate policy, payload boundaries and upgrade rehearsal are independently verifiable and have different owners and risks); folding this into MasterPlan 23 (rejected, because MasterPlan 23 has an agreed release boundary and this work changes how releases are verified, not what the inventory release delivers); and folding the upgrade rehearsal into MasterPlan 24 (rejected, because MasterPlan 24 is waiting on a tooling evaluation and work-data policy, while candidate-to-candidate upgrade mechanics can be proven now on disposable contexts and feed MasterPlan 24 rather than wait for it).

Relevant local ADRs:
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) (the immutable platform payload and per-context workspaces; EP-171 changes what the payload contains, EP-172 relies on workspaces selected by payload digest);
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) (platform versions across CLI, payload, context, host and cluster; the upgrade rehearsal must keep these consistent);
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) (release gate and Nix release publishing from validated tags; EP-170 and EP-171 change what the gate requires and where its tooling lives);
[ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) (the upgrade transaction carries every guard of the recipes it replaces; EP-172 must preserve this);
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (the typed inventory, reviews, journal and candidate-bound release evidence whose guarantees the scripted run must reproduce, not relax). No cross-repository ADR applies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Script the local acceptance run as one command | docs/plans/168-script-the-local-acceptance-run-as-one-command.md | None | None | Not Started |
| 2 | Run the local acceptance in CI | docs/plans/169-run-the-local-acceptance-in-ci.md | EP-168 | EP-171 | Not Started |
| 3 | Size the release gate to the change | docs/plans/170-size-the-release-gate-to-the-change.md | None | EP-168, EP-171 | Not Started |
| 4 | Move release tooling out of the platform payload | docs/plans/171-move-release-tooling-out-of-the-platform-payload.md | None | None | Not Started |
| 5 | Rehearse candidate upgrades of an inventory context instead of rebuilding it | docs/plans/172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md | EP-168 M1 | EP-170 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
EP-172's hard dependency is only EP-168's first milestone: a scripted fresh-context bootstrap and scenario that leaves a converged context to upgrade.


## Dependency Graph

EP-168 comes first because every other stream consumes the scripted run. EP-169 needs the whole of EP-168 (a command that runs end to end without a human) before CI can execute it; it benefits from EP-171 because a CI job should check out harness tooling independently of the payload under test. EP-170 can design the change classes and the gate rules in parallel, but its acceptance (a gate decision proven on real candidates) uses EP-168's evidence and EP-171's tooling boundary, so both are soft dependencies. EP-171 is independent and can proceed immediately after MasterPlan 23 closes. EP-172 needs EP-168 M1, a scripted bootstrap and scenario that yields a converged context on the previous candidate, and benefits from EP-170 because the gate decides when an upgrade rehearsal can replace a fresh-context C2.

Parallel lanes after MasterPlan 23: EP-168 and EP-171 together; then EP-169, EP-170 and EP-172.


## Integration Points

The acceptance runner command and its output layout. Defined by EP-168: a maintained script (proposed `scripts/run-local-acceptance.sh`) that takes a candidate package and an operator root and writes the assertion evidence directory, the runner rehearsal directory and the assembled `inventory-evidence.json`. EP-169 runs it unchanged in CI, EP-170 consumes its output as gate input, and EP-172 reuses its scenario and check stages against an upgraded context. Changes to its arguments or layout are coordinated through this MasterPlan.

The change classification. Defined by EP-170: a deterministic mapping from the files changed between two revisions to a change class (proposed: harness-only, CLI/app, payload/substrate) and the evidence each class requires. EP-171's payload boundary determines which paths count as payload; EP-172 adds "upgrade rehearsal" as acceptable evidence for some classes.

The payload boundary. Defined by EP-171: which repository paths ship in `nix build .#nagare` (the platform payload under `share/nagare`) and which are harness tooling. EP-170 uses it to classify changes; EP-169 checks out harness tooling at the harness revision.

Upgrade rehearsal evidence. Defined by EP-172, consumed by EP-170 and handed to MasterPlan 24's upgrade-path stream and MasterPlan 21.

Representative early check: EP-168 M1's scripted bootstrap and scenario run must succeed on the final MasterPlan 23 candidate before EP-169 and EP-172 expand on it.

Cross-plan decisions that should become ADRs: the change classes and the evidence each requires (EP-170, likely an amendment to ADR 7); the payload/harness boundary (EP-171, an amendment to ADR 4 or ADR 7); and upgrade rehearsal as candidate evidence (EP-172, related to ADR 6 and ADR 18).


## Progress

Not started. Begins after MasterPlan 23 closes; EP-168 may start earlier as harness-only work against the final MasterPlan 23 candidate.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Decompose by the cost each stream removes (manual operation, workstation dependency, over-verification, tooling-driven candidate churn, rebuild-per-candidate), not by component.
  Rationale: Each removal is independently demonstrable, and the MasterPlan 23 native runs showed these five costs as separate sources of delay.
  Date: 2026-10-04

- Decision: Prove candidate-to-candidate upgrade mechanics here on disposable contexts, and leave work-data upgrade policy to MasterPlan 24 and MasterPlan 21.
  Rationale: The mechanics can be proven now and remove the rebuild-per-candidate cost; work-data policy depends on MasterPlan 24's evaluation and must not be pre-empted.
  Date: 2026-10-04


## Outcomes & Retrospective

(To be filled during and after implementation.)
