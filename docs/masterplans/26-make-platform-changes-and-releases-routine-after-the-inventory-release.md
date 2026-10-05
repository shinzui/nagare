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
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-04T14:16:36Z
      mode: "update"
      note: "ADR 24 tooling decision"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T03:25:17Z
      mode: "update"
      note: "Add EP-173 and EP-174 (interpreter-first discovery, local gate); start them before MP-23 closes; no GitHub Actions"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T03:50:52Z
      mode: "update"
      note: "Operator accepted ordering; EP-169 cancelled; ADR 25 accepted"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T17:56:25Z
      mode: "implement"
      note: "Registry and progress for EP-173/EP-174; stale CI prose; nagare-harness layout decision"
---

# Make platform changes and releases routine after the inventory release

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

[MasterPlan 23](23-make-managed-resources-first-class-through-typed-scoped-inventories.md) proves Nagare's typed inventory release with three native gates per frozen candidate: C1 (the candidate CLI against an installed local platform), C2 (a fresh local context bootstrapped with the candidate's own payload, running the full scenario) and C3 (the same on a fresh GCP context). In MasterPlan 23 every gate was driven by hand, every code change that ships in the payload minted a new candidate, every candidate required tearing down and rebuilding the shared local cluster, and in-place upgrades of an inventory context were explicitly out of scope. The first native runs were expensive because they also found defects in paths that had never run (F39-F44). This plan originally called that a one-time cost. 2026-10-04 disproved it: F49, F50, F51, F52, F53 and F54 were all found natively, and all were catchable in seconds by a fake adapter, a model test or a per-commit check. [The 2026-10-04 retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md) shows that 26 of the 35 natively found MasterPlan 23 findings were cheap-layer defects, and only one needed the cloud. Two costs remain. The first is that native runs are still the main way defects are found. The second is that every platform change costs a full manual C1/C2/C3 cycle.

After this initiative, defects are found by the effect interpreters and a local per-commit gate, and native runs only confirm ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)). A maintainer changing Nagare also pays a cost proportional to the change. A documentation or harness-only change needs no native evidence. A change to the CLI or payload runs the local acceptance as one local command and produces the finalized, assembled evidence the release gate consumes. A fix to release tooling no longer mints a new platform candidate. And a new candidate can be rehearsed as an in-place, reviewed upgrade of an already converged inventory context instead of a teardown and rebuild, so a routine candidate is verified the way a running installation would actually move to it.

In scope: adversarial provider interpreters and a stuck-state invariant model in the ordinary test suite; a local per-commit and per-candidate gate with exhaustiveness errors, a builder-health proof and fixture smoke; one scripted local acceptance run (the C2 scenario, its interruptions, restores, source-unavailable drill, runner rehearsal, finalize and assembly); running it in CI; a change-class-based release gate; separating release tooling from the platform payload; and a candidate-to-candidate upgrade rehearsal of a disposable inventory context, local first.

Out of scope: the upgrade policy for installations that hold work data, which belongs to [MasterPlan 24](24-operate-nagare-as-a-team-run-workplace-intranet-paas.md) (its planned "upgrade path for contexts holding work data" stream) and to [MasterPlan 21](21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md) (replacement upgrades with bounded downtime). This initiative proves upgrade mechanics on disposable rehearsal contexts and hands the evidence to those plans; it does not decide work-data policy. Also out of scope: hosted CI. By operator decision on 2026-10-04, gating does not use GitHub Actions; every gate runs locally. Also out of scope: weakening any MasterPlan 23 guarantee, GKE, mutating a real operator context, and full-context teardown (MasterPlan 25).

EP-173 and EP-174 start immediately, before MasterPlan 23 closes. They change no shipped behaviour, and MasterPlan 23's remaining native work waits for EP-173's first two milestones (operator decision, 2026-10-04). The other streams start after MasterPlan 23 closes. EP-168 may begin earlier as harness-only work, but it must target the final MasterPlan 23 candidate's commands and evidence formats.


## Decomposition Strategy

The work splits by the kind of cost it removes, so each child is independently verifiable:

[EP-173](../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md) removes discovery by native run. Provider worlds produce the states real providers produce: lost acknowledgement, landed but unready, replaced, renamed, foreign manager, transient and store failures. An invariant model over the real planner, driver and adapters checks that every stopped transaction has a reviewed exit and that nothing unreviewed is accepted. Its acceptance is that it fails on the pre-repair source of F54 and on reverted guards of seven earlier findings.

[EP-174](../plans/174-gate-every-commit-before-any-native-run.md) removes late discovery of build and fixture defects. It adds exhaustiveness as an error, a local pre-push gate, and a full local gate with a builder-health proof whose record native work requires. It also smoke-runs fixture applications locally before a cluster sees them.

[EP-168](../plans/168-script-the-local-acceptance-run-as-one-command.md) removes manual operation: one maintained command runs the whole local acceptance on a fresh local context and produces finalized local health and assembled inventory evidence. Its acceptance is a green run on the then-current candidate.

[EP-169](../plans/169-run-the-local-acceptance-in-ci.md) planned to run the same command in hosted CI. It is cancelled (operator decision, 2026-10-04: no GitHub Actions); EP-168's command and EP-174's local gate cover the need.

[EP-170](../plans/170-size-the-release-gate-to-the-change.md) removes over-verification: the release gate classifies the change between the last accepted candidate and the new one and requires only the evidence that class needs.

[EP-171](../plans/171-move-release-tooling-out-of-the-platform-payload.md) removes candidate churn from tooling fixes: release assembly, evidence and audit scripts move out of the shipped payload into a versioned harness, so fixing them does not change the platform payload.

[EP-172](../plans/172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md) removes the rebuild-per-candidate cost and proves what a running installation experiences: a converged context on the previous candidate is upgraded through the reviewed `platform upgrade` path to the new candidate, then re-verified.

Alternatives considered for the 2026-10-04 additions: folding the interpreter work into EP-170 as a gate rule only (rejected, because a rule without worlds and a model has nothing to check); and restoring GitHub Actions as the per-commit gate (rejected by the operator as too slow). Earlier alternatives: one ExecPlan for all of it (rejected, because CI, gate policy, payload boundaries and upgrade rehearsal are independently verifiable and have different owners and risks); folding this into MasterPlan 23 (rejected, because MasterPlan 23 has an agreed release boundary and this work changes how releases are verified, not what the inventory release delivers); and folding the upgrade rehearsal into MasterPlan 24 (rejected, because MasterPlan 24 is waiting on a tooling evaluation and work-data policy, while candidate-to-candidate upgrade mechanics can be proven now on disposable contexts and feed MasterPlan 24 rather than wait for it).

Relevant local ADRs:
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) (the immutable platform payload and per-context workspaces; EP-171 changes what the payload contains, EP-172 relies on workspaces selected by payload digest);
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) (platform versions across CLI, payload, context, host and cluster; the upgrade rehearsal must keep these consistent);
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) (release gate and Nix release publishing from validated tags; EP-170 and EP-171 change what the gate requires and where its tooling lives);
[ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) (the upgrade transaction carries every guard of the recipes it replaces; EP-172 must preserve this);
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (the typed inventory, reviews, journal and candidate-bound release evidence whose guarantees the scripted run must reproduce, not relax; EP-173 tests its adapter boundary);
[ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) (harness tooling in Haskell; EP-174's gate is a `nagare-harness` command);
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) (accepted 2026-10-04: interpreters find defects and native runs confirm; EP-173 and EP-174 implement it, and EP-170 enforces it). No cross-repository ADR applies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Script the local acceptance run as one command | docs/plans/168-script-the-local-acceptance-run-as-one-command.md | None | None | Not Started |
| 2 | Run the local acceptance in CI | docs/plans/169-run-the-local-acceptance-in-ci.md | EP-168 | EP-171 | Cancelled (operator, 2026-10-04: no GitHub Actions; EP-168 + EP-174 cover the need) |
| 3 | Size the release gate to the change | docs/plans/170-size-the-release-gate-to-the-change.md | None | EP-168, EP-171 | Not Started |
| 4 | Move release tooling out of the platform payload | docs/plans/171-move-release-tooling-out-of-the-platform-payload.md | None | None | Not Started |
| 5 | Rehearse candidate upgrades of an inventory context instead of rebuilding it | docs/plans/172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md | EP-168 M1 | EP-170 | Not Started |
| 6 | Find recovery defects with adversarial provider interpreters | docs/plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md | None | None | In Progress (M1 done; M2 in progress, 2026-10-05) |
| 7 | Gate every commit before any native run | docs/plans/174-gate-every-commit-before-any-native-run.md | None | EP-168 (shared `nagare-harness` package) | Completed (2026-10-05) |
| 8 | Make the flake check build each Haskell package once | docs/plans/178-make-the-flake-check-build-each-haskell-package-once.md | None | EP-174 | Completed (2026-10-05) |

Status values: Not Started, In Progress, Complete, Cancelled.
EP-172's hard dependency is only EP-168's first milestone: a scripted fresh-context bootstrap and scenario that leaves a converged context to upgrade. EP-169 is cancelled: its premise (GitHub Actions) conflicts with the operator's 2026-10-04 decision.


## Dependency Graph

EP-173 and EP-174 come first and start now, in parallel with each other and with MasterPlan 23's remaining work. EP-173 M1–M2 (the Kubernetes application world and the incarnation, store and transient faults) is the slice MasterPlan 23's remaining native runs wait for. EP-174 M1–M3 should land before the next MasterPlan 23 candidate is frozen. EP-170's native-evidence precondition consumes EP-173 M5's coverage record and EP-174's gate record. Among the original streams, EP-168 comes first because the others consume the scripted run. EP-169 needs the whole of EP-168 (a command that runs end to end without a human) before CI can execute it; it benefits from EP-171 because a CI job should check out harness tooling independently of the payload under test. EP-170 can design the change classes and the gate rules in parallel, but its acceptance (a gate decision proven on real candidates) uses EP-168's evidence and EP-171's tooling boundary, so both are soft dependencies. EP-171 is independent and can proceed immediately after MasterPlan 23 closes. EP-172 needs EP-168 M1, a scripted bootstrap and scenario that yields a converged context on the previous candidate, and benefits from EP-170 because the gate decides when an upgrade rehearsal can replace a fresh-context C2.

Parallel lanes: now, EP-173 and EP-174; after MasterPlan 23, EP-168 and EP-171 together; then EP-170 and EP-172.


## Integration Points

The acceptance runner command and its output layout. Defined by EP-168: the Haskell command `nagare-harness local-acceptance` (per ADR 24) that takes a candidate package and an operator root and writes the assertion evidence directory, the runner rehearsal directory and the assembled `inventory-evidence.json`. EP-170 consumes its output as gate input, and EP-172 reuses its scenario and check stages against an upgraded context. Changes to its arguments or layout are coordinated through this MasterPlan.

The change classification. Defined by EP-170: a deterministic mapping from the files changed between two revisions to a change class (proposed: harness-only, CLI/app, payload/substrate) and the evidence each class requires. EP-171's payload boundary determines which paths count as payload; EP-172 adds "upgrade rehearsal" as acceptable evidence for some classes.

The payload boundary. Defined by EP-171: which repository paths ship in `nix build .#nagare` (the platform payload under `share/nagare`) and which are harness tooling. EP-170 uses it to classify changes; EP-169 checks out harness tooling at the harness revision.

Upgrade rehearsal evidence. Defined by EP-172, consumed by EP-170 and handed to MasterPlan 24's upgrade-path stream and MasterPlan 21.

The gate record. Defined by EP-174: a JSON record per commit, under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/gates/`, binding commit, tree, steps, realised checks per system and a builder probe. It is checked by `nagare-harness gate verify --revision`. EP-168's runner calls `gate verify` before any cluster step, and EP-170 requires a green record for the candidate.

The interpreter-coverage record. Defined by EP-173 M5: `interpreter-coverage.json`, mapping every executor and action to the model scenarios and fault kinds covering it. EP-170 requires it before accepting native evidence, and EP-168 refuses a native step whose path has no entry.

The fixture smoke manifest. Defined by EP-174: `fixtures/inventory-release/local/fixture-smoke.json`. EP-168's runner calls `nagare-harness fixture-smoke` before deploying fixtures.

The `nagare-harness` package. Introduced by EP-168, which owns its layout. If EP-174 lands first, it creates the skeleton exactly as EP-168 describes, and EP-168 builds on it.

The production adapter registry. EP-173 M3 moves its construction from `cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs` into the library (`Nagare.Inventory.Registry`). Any stream that adds an adapter adds it there, with a world.

Representative early check: EP-168 M1's scripted bootstrap and scenario run must succeed on the final MasterPlan 23 candidate before EP-169 and EP-172 expand on it.

Cross-plan decisions that should become ADRs: interpreters find defects and native runs confirm ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), accepted 2026-10-04); the change classes and the evidence each requires (EP-170, likely an amendment to ADR 7); the payload/harness boundary (EP-171, an amendment to ADR 4 or ADR 7); and upgrade rehearsal as candidate evidence (EP-172, related to ADR 6 and ADR 18).


## Progress

In progress. EP-173 started on 2026-10-05 (M1 done, M2 in progress). EP-174 started the same day: `nagare-harness` with the fast and full gates, `gate verify`, the pre-push hook and the fixture smoke; its M1 waits for MasterPlan 23's in-flight EP-173 work to land. As of 2026-10-04, EP-173 and EP-174 were ready to start now, ahead of MasterPlan 23's remaining native work. The other streams begin after MasterPlan 23 closes, and EP-168 may start earlier as harness-only work against the final MasterPlan 23 candidate. EP-169 is cancelled.


## Surprises & Discoveries

- The "one-time cost" assumption in the original Vision was wrong. On 2026-10-04, six more findings were found natively, all cheap-layer (F49–F54). Across MasterPlan 23, 26 of 35 natively found findings could have been found by a type check, a fake adapter or a model test ([retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md)).
- GitHub Actions has been disabled since 2026-09-22 (`gh api repos/shinzui/nagare/actions/permissions` returns `{"enabled":false}`), and no local per-commit gate existed. 785 commits landed unchecked, which produced F53.
- The EP-153 in-memory driver model only ever recovers with `RecoveryProvedComplete` and observes stable identities. It could not find the stuck-state class that produced thirteen findings.


## Decision Log

- Decision: Decompose by the cost each stream removes (manual operation, workstation dependency, over-verification, tooling-driven candidate churn, rebuild-per-candidate), not by component.
  Rationale: Each removal is independently demonstrable, and the MasterPlan 23 native runs showed these five costs as separate sources of delay.
  Date: 2026-10-04

- Decision: Prove candidate-to-candidate upgrade mechanics here on disposable contexts, and leave work-data upgrade policy to MasterPlan 24 and MasterPlan 21.
  Rationale: The mechanics can be proven now and remove the rebuild-per-candidate cost; work-data policy depends on MasterPlan 24's evaluation and must not be pre-empted.
  Date: 2026-10-04

- Decision: Add EP-173 (adversarial provider interpreters and the stuck-state invariant model) and EP-174 (local per-commit gate, builder-health proof, fixture smoke), and start both before MasterPlan 23 closes.
  Rationale: Scripting and automating native runs (EP-168, EP-169) makes discovery by native run cheaper, but it is still discovery at the slowest layer. The 2026-10-04 retrospective shows most defects were cheap-layer, so the interpreters and a per-commit gate remove more cost than any native-run improvement.
  Date: 2026-10-04

- Decision: No GitHub Actions. Every gate runs locally, and x86_64-linux runs on the existing remote Nix builder with a builder-health proof.
  Rationale: Operator decision, 2026-10-04 ("GitHub Actions is so slow"; "do not use github action"). EP-169, which planned to run the acceptance on GitHub Actions, must be re-scoped or cancelled before it starts.
  Date: 2026-10-04

- Decision (operator, 2026-10-04): MasterPlan 23's remaining native work waits for EP-173 M1–M2. That work is phase 3b, the F54 native verification and any new candidate. F51 and F52 are un-deferred and fixed in MasterPlan 23. ADR 25 is accepted. EP-169 is cancelled.
  Rationale: Otherwise the next native run is again the first execution of unmodelled failure states. The F54 repair should be proven by the model before it goes native.
  Date: 2026-10-04

- Decision: New tooling in every stream is Haskell, under [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) (operator decision): the production standard, shared `nagarectl` types, real-output fixtures, no Python embedded in shell. The existing Python and shell tools are frozen; each stream ports the tools it touches. EP-168 starts this with the `nagare-harness` package.
  Rationale: MasterPlan 23's acceptance ran on untested shell-plus-Python glue, which led to the F42 assembler defect and to one unassemblable acceptance run.
  Date: 2026-10-04

- Decision: EP-174 landed first and created `cli/nagare-harness` as its own Cabal project (`cli/nagare-harness/cabal.project`), with no `nagarectl` library dependency yet. EP-168 adds that dependency, and `../nagarectl` to the project's packages, when `local-acceptance` needs the shared types.
  Rationale: There is no shared cabal workspace; each package has its own `cabal.project`. The pre-push hook builds the harness before running the gate, and a gate that first rebuilt the whole `nagarectl` library in a second build directory would add minutes to every push for no use. Otherwise the layout is what EP-168 describes: `src/Nagare/Harness/*`, `app/Main.hs`, a tasty suite, the Nix check `nagare-harness-build-test`, outside the platform payload.
  Date: 2026-10-05


## Outcomes & Retrospective

(To be filled during and after implementation.)
