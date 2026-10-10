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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Fixed finish line with enumerated native runs; EP-172 owns release transitions; EP-168 ports archived drivers + preflight; lanes"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-10T14:04:49Z
      mode: "update"
      note: "Operator added item 9 and EP-184 (gate wall time, lost gate runs)"
---

# Make platform changes and releases routine after the inventory release

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

**Current scope (2026-10-09, after [MasterPlan 23](23-make-managed-resources-first-class-through-typed-scoped-inventories.md)
closed on candidate `83124396` and published v0.4.0).** This is the first of the three follow-up
MasterPlans (26, then [25](25-reviewed-full-context-teardown-with-vm-workload-collection.md), with
[21](21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md) held), because it lowers
the cost of everything after it.

After this initiative:
- A fix costs a gate proportional to the change, not a candidate loop. The release gate classifies
  the change and asks only for the evidence that class needs.
- Defects are found by the effect interpreters, and native runs only confirm
  ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)). A tool
  refuses a native step whose path no model covers.
- The local acceptance is one unattended command, and fixing release tooling does not mint a new
  platform candidate.
- An installed v0.4.0 context can move to the next Nagare release through a reviewed, recoverable
  transition, rehearsed on a disposable local context every release.

Why this order. MasterPlan 23's time went mostly to native runs used as defect finders (about 13
candidate loops before `83124396`; 26 of 35 native findings were catchable by a cheap layer, per
[the 2026-10-04 retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md)), to sessions
waiting on one another, and to hand-written evidence documents. The items below remove those costs
before MasterPlan 25 adds new native work.

Out of scope: hosted CI (operator, 2026-10-04: no GitHub Actions); work-data policy for team
installations ([MasterPlan 24](24-operate-nagare-as-a-team-run-workplace-intranet-paas.md));
replacement onto fresh infrastructure (MasterPlan 21); full-context teardown (MasterPlan 25); GKE;
mutating a real operator context; weakening any MasterPlan 23 guarantee.

### Finish line (fixed 2026-10-09)

The rules of the [production readiness checklist](../releases/production-readiness-checklist.md)
apply here:
- **Fixed scope.** No item is added. A new finding that does not risk data loss goes to the deferral
  ledger with the operator's approval.
- **Evidence ticks a box.** That means a commit, a gate record or a drill log, never an estimate.
- **Only the native runs listed here.** A defect found in one stops the run. Its fix lands with a
  class-level interpreter regression that fails on the pre-fix source, and then the run is repeated
  once.

- [ ] 1. The recovery model runs the production adapter registry, built in the library, rather than a
      test-local copy (EP-173 M3).
- [ ] 2. Every registered executor and action has a provider world and a covering model scenario,
      recorded in `interpreter-coverage.json`. Deleting a scenario fails a test. This includes the
      Pulumi cloud-foundation world that MasterPlan 25 extends (EP-173 M4–M5).
- [ ] 3. Changing release or harness tooling leaves the built payload digest unchanged (EP-171).
- [ ] 4. The release gate classifies the change between two revisions and requires only that class's
      evidence. Its output on real MasterPlan 23 candidate pairs matches a hand-checked expectation
      (EP-170).
- [ ] 5. **Native run L1 (cp3).** `nagare-harness local-acceptance` reproduces C2 on `83124396`
      unattended: 16/16 assertions, evidence assembled. A deliberately injected fault stops it at the
      named stage (EP-168).
- [ ] 6. An admitted inventory context moves to a new release through a reviewed transition that
      binds the source and target releases and refuses unsupported pairs. The recovery model proves
      it under faults first (EP-172 M1–M2).
- [ ] 7. **Native run L2 (cp3).** A disposable local context converged on v0.4.0 moves to the next
      candidate through that transition. The seeded data reads back unchanged, and an unchanged
      replan has zero operations (EP-172 M3).
- [ ] 8. The next release is cut this way: one candidate, classified, carrying only the evidence its
      class requires, and published locally through the release runbook (integration gate, all
      children).
- [ ] 9. (Added by the operator, 2026-10-10.) The gates wait only for their slowest job and do not
      lose runs to the builder. The suite runs in parallel with its slow model tests sharded, the
      full gate runs each check once with local and remote work overlapping, a gcloud preflight,
      keep-awake session and transport retry protect it, and the deep tier and mutation sweep run
      inside it when needed. Before and after times are recorded (EP-184).

No cloud run is required by this plan. If item 8's change class requires C3, the operator approves
that one bounded sequence when it is reached. The sequence includes the human dependencies: builder
up, gcloud authenticated, and a test Tailscale key carrying `tag:nagare-test`.

### Working rules for this initiative

- **One worktree session per lane** (see Dependency Graph). A reviewer reads landed commits on its own
  schedule rather than gating work through messages. No coordinator relays operator decisions.
- **A native run starts only after its preflight passes:**
  [before a native run](../runbooks/before-a-native-run.md), `just gate-verify` for the exact
  revision, and EP-168's environment preflight.
- **Status lives in three places only:** this checklist, each child's Progress section, and the
  findings register. Evidence directories are produced by the harness; no new standalone audit
  documents.


## Decomposition Strategy

The children split by the cost each one removes:
- [EP-173](../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md): discovery by
  native run. It adds provider worlds and the stuck-state invariant model.
- [EP-174](../plans/174-gate-every-commit-before-any-native-run.md): late build and fixture defects. It
  adds the local per-commit gate (complete).
- [EP-168](../plans/168-script-the-local-acceptance-run-as-one-command.md): manual operation. The local
  acceptance becomes one command.
- [EP-171](../plans/171-move-release-tooling-out-of-the-platform-payload.md): candidate churn from
  tooling fixes.
- [EP-170](../plans/170-size-the-release-gate-to-the-change.md): over-verification.
- [EP-172](../plans/172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md):
  the missing move from one release to the next, and the rebuild per candidate. Re-scoped 2026-10-09
  to own the release transition itself, not only its rehearsal.

EP-169 (hosted CI) is cancelled, and EP-178 (one flake build per package) is complete.

Alternatives rejected:
- Folding the interpreter work into EP-170 as a gate rule only: a rule without worlds has nothing to
  check.
- Restoring GitHub Actions: the operator rejected it.
- Leaving release transitions to MasterPlan 21: its replacement path needs fresh infrastructure,
  while the ordinary next release needs an in-place transition, and today no plan owned one.

Relevant ADRs:
- [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md): payload and
  workspaces (EP-171, EP-172).
- [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md): versions
  across CLI, payload, context, host and cluster. Its 2026-09-26 amendment refuses a version change
  after admission until a reviewed transition exists; EP-172 implements that transition.
- [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md): the release gate (EP-170).
- [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md): the
  transition carries every guard of the recipes it replaces.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): reviews,
  journal and evidence.
- [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md): harness
  tooling in Haskell.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): interpreters
  find defects.

No cross-repository ADR applies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Script the local acceptance run as one command | docs/plans/168-script-the-local-acceptance-run-as-one-command.md | None | EP-171; MP-25 EP-167 M3 (reviewed local teardown stage) | Not Started |
| 2 | Run the local acceptance in CI | docs/plans/169-run-the-local-acceptance-in-ci.md | EP-168 | EP-171 | Cancelled (operator, 2026-10-04: no GitHub Actions; EP-168 + EP-174 cover the need) |
| 3 | Size the release gate to the change | docs/plans/170-size-the-release-gate-to-the-change.md | None; M3 needs EP-173 M5 | EP-168, EP-171 | Not Started |
| 4 | Move release tooling out of the platform payload | docs/plans/171-move-release-tooling-out-of-the-platform-payload.md | None | None | Not Started |
| 5 | Move an inventory context to the next release through a reviewed transition | docs/plans/172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md | M3 needs EP-168 M1 | EP-170, EP-173 | Not Started |
| 6 | Find recovery defects with adversarial provider interpreters | docs/plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md | None | None | In Progress (M1–M2 accepted 2026-10-05; M3–M5 open) |
| 7 | Gate every commit before any native run | docs/plans/174-gate-every-commit-before-any-native-run.md | None | EP-168 (shared `nagare-harness` package) | Complete (2026-10-05) |
| 8 | Make the flake check build each Haskell package once | docs/plans/178-make-the-flake-check-build-each-haskell-package-once.md | None | EP-174 | Complete (2026-10-05) |
| 9 | Make the gates wait only for their slowest job and stop losing gate runs to the builder | docs/plans/184-make-the-gates-wait-only-for-their-slowest-job-and-stop-losing-gate-runs-to-the-builder.md | None | EP-173 (shared recovery-model test files) | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. EP-172 keeps its file path; its title
changed with the 2026-10-09 re-scope.


## Dependency Graph

Two lanes, each one worktree session:
- **Lane A (pure code, start now).**
  - EP-184 first: it shortens every other plan's gates.
  - EP-173 M3, then M4, then M5.
  - EP-171.
  - EP-170 M1–M2; its M3 waits for EP-173 M5's coverage record.
  - EP-172 M1–M2: the transition model and code, against the recovery model.
- **Lane B (cp3).**
  - EP-168 M1–M3, which delivers native run L1.
  - Then EP-172 M3 (native run L2). It needs EP-168 M1 and EP-172 M2.

Item 8 (the next release) needs every other item. EP-172 M3 hard-depends only on EP-168's first
milestone: a scripted fresh-context bootstrap and scenario that leaves a converged context.


## Integration Points

**The acceptance runner and its output layout.** EP-168 owns `nagare-harness local-acceptance`:
- **Inputs:** candidate package, images, operator root.
- **Outputs:** one evidence directory created by the runner's plan, a staging directory, a private
  directory, and the assembled `inventory-evidence.json`.
- **Starting point:** EP-168 ports the driver set that passed on `83124396`, stage for stage. The set
  is archived, frozen, in
  [`drivers-83124396/`](../audits/mp23-independent-results-2026-10-07/drivers-83124396/README.md).
- **Consumers:** EP-170 reads the output as gate input. EP-172 reuses its stages against a moved
  context instead of a fresh one.

**The environment preflight.** EP-168 owns it. Before any stage, the harness refuses unless every
human dependency is settled:
- the remote builder answers;
- gcloud is authenticated (cloud contexts);
- the context's Tailscale key carries `tag:nagare-test`;
- `gate verify` is green for the candidate revision;
- only the expected Colima profile runs.

MasterPlan 25's teardown runner calls the same preflight.

**The release transition.** EP-172 owns:
- the reviewed transition of an admitted context from release S to release T;
- a compatibility table in the payload (supported S→T pairs, store wire versions);
- the transition's recovery exits.

The legacy `platform upgrade` runner stays blocked for inventory contexts (`guardLegacyMutationInventory`).
MasterPlan 21 consumes the compatibility table for replacement source/target pairs.
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) records
the ownership.

**The change classification.** EP-170 owns the mapping from changed paths to class and required
evidence. EP-171's payload boundary decides which paths count as payload. EP-172 adds "transition
rehearsal" as evidence a class may accept.

**The payload boundary.** EP-171 owns which repository paths ship under `share/nagare`.

**The gate record.** EP-174 owns it (complete). It is a JSON record per commit under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/gates/`, checked by
`nagare-harness gate verify --revision`. EP-168 calls it before any cluster step, and EP-170 requires
it.

**The interpreter-coverage record and the provider worlds.** EP-173 owns `interpreter-coverage.json`
and the worlds:
- **Already built:** Kubernetes, store, rename, restore and collection.
- **Added in M4:** the Pulumi cloud foundation, Helm and the host transport.

EP-170 requires the coverage record, and EP-168 refuses a native step with no entry. MasterPlan 25
EP-165 and EP-167 extend the Pulumi cloud-foundation world with retained members and teardown
faults rather than building a second one.

**The local teardown stage.** MasterPlan 25 EP-167 M3 delivers reviewed removal of a local context.
Once it lands, EP-168 runs it as its final stage, so teardown is exercised every release. Until then,
EP-168 replaces the cluster only with `--replace-cluster` and the operator's approval.

**The production adapter registry.** EP-173 M3 moves its construction from
`cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs` into the library (`Nagare.Inventory.Registry`).
Any stream that adds an adapter adds it there, with a world.


## Progress

2026-10-09: re-scoped around the fixed finish line above.
- **Complete:** EP-174 and EP-178.
- **EP-173:** M1–M2 accepted on 2026-10-05; M3–M5 open.
- **Lane A** can start immediately. Lane B starts with EP-168 M1 on cp3.
- **Already done for EP-168:** the driver set it ports is archived in the repository (`77cdefe8`),
  because its only copy was in a scratch directory that macOS purges.
- **Landed ahead of item 4 (operator decision, 2026-10-09):** EP-170's first slice. A commit that
  changes only inert documentation carries its gated ancestor's record forward, so plan edits need
  no 20-minute gate (ADR 25 amendment).
- **No item is ticked.**

2026-10-10: the operator added item 9 (EP-184) after a 55-minute full gate and two gate runs lost
to the builder in one night.


## Surprises & Discoveries

- The "one-time cost" assumption in the original Vision was wrong. On 2026-10-04, six more findings
  were found natively, all cheap-layer (F49–F54). Across MasterPlan 23, 26 of 35 natively found
  findings could have been found by a type check, a fake adapter or a model test
  ([retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md)).
- GitHub Actions has been disabled since 2026-09-22, and no local per-commit gate existed. 785
  commits landed unchecked, which produced F53. EP-174 closed this.
- The EP-153 in-memory driver model only ever recovered with `RecoveryProvedComplete`, so it could
  not find the stuck-state class that produced thirteen findings. EP-173 M1–M2 replaced it with
  adversarial worlds, which then found F55–F65 before any native run.
- 2026-10-09: **No plan owned the move of an admitted inventory context to the next release.**
  - [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
    refuses a version change after admission.
  - The legacy `platform upgrade` refuses inventory contexts (`Upgrade.hs:366`).
  - MasterPlan 21 excludes general in-place release and schema migration.

  So the first v0.4.0 installation had no path to v0.4.1. EP-172 now owns it.
- 2026-10-09: **MasterPlan 23's time analysis, from session traces and the operator's rei notes:**
  - Sessions waiting on each other took about 27% of attributed session-hours (808 inter-session
    messages).
  - About 31 hours followed questions to the operator.
  - Native runs were mostly reruns after defects.
  - Since 2026-09-12, about 270K lines were added under `docs/` against about 260K lines of code.

  The working rules above answer these.
- 2026-10-09: The native drivers that produced MasterPlan 23's final evidence existed only in
  session scratch space under `/private/tmp`, which macOS purges after about three days. They are
  now archived.


## Decision Log

- Decision: Decompose by the cost each stream removes (manual operation, workstation dependency, over-verification, tooling-driven candidate churn, rebuild-per-candidate), not by component.
  Rationale: Each removal is independently demonstrable, and the MasterPlan 23 native runs showed these five costs as separate sources of delay.
  Date: 2026-10-04

- Decision: Prove candidate-to-candidate upgrade mechanics here on disposable contexts, and leave work-data upgrade policy to MasterPlan 24 and MasterPlan 21.
  Rationale: The mechanics can be proven now and remove the rebuild-per-candidate cost; work-data policy depends on MasterPlan 24's evaluation and must not be pre-empted.
  Date: 2026-10-04 (amended 2026-10-09: EP-172 also implements the transition; see below)

- Decision: Add EP-173 (adversarial provider interpreters and the stuck-state invariant model) and EP-174 (local per-commit gate, builder-health proof, fixture smoke), and start both before MasterPlan 23 closes.
  Rationale: Scripting and automating native runs (EP-168, EP-169) makes discovery by native run cheaper, but it is still discovery at the slowest layer. The 2026-10-04 retrospective shows most defects were cheap-layer, so the interpreters and a per-commit gate remove more cost than any native-run improvement.
  Date: 2026-10-04

- Decision: No GitHub Actions. Every gate runs locally, and x86_64-linux runs on the existing remote Nix builder with a builder-health proof.
  Rationale: Operator decision, 2026-10-04 ("GitHub Actions is so slow"; "do not use github action").
  Date: 2026-10-04

- Decision (operator, 2026-10-04): MasterPlan 23's remaining native work waits for EP-173 M1–M2. F51 and F52 are un-deferred and fixed in MasterPlan 23. ADR 25 is accepted. EP-169 is cancelled.
  Rationale: Otherwise the next native run is again the first execution of unmodelled failure states.
  Date: 2026-10-04

- Decision: New tooling in every stream is Haskell, under [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) (operator decision). The existing Python and shell tools are frozen; each stream ports the tools it touches.
  Rationale: MasterPlan 23's acceptance ran on untested shell-plus-Python glue, which led to the F42 assembler defect and to one unassemblable acceptance run.
  Date: 2026-10-04

- Decision: EP-174 landed first and created `cli/nagare-harness` as its own Cabal project, with no `nagarectl` library dependency yet. EP-168 adds that dependency when `local-acceptance` needs the shared types.
  Rationale: A gate that first rebuilt the whole `nagarectl` library in a second build directory would add minutes to every push.
  Date: 2026-10-05

- Decision (operator, 2026-10-09): Run the follow-up plans in the order 26, then 25, with 21 held except its measurement spike.
  - Each plan gets a fixed finish line whose native runs are listed up front.
  - Lanes run as one worktree session each, with no relay between sessions.

  Rationale: MasterPlan 23's cost came from native runs used as discovery, coordination waits, open scope and documentation churn. This plan lowers the cost of the other two, so it goes first.
  Date: 2026-10-09

- Decision (operator, 2026-10-09): EP-172 is re-scoped to own the reviewed transition of an admitted inventory context from one release to the next, through inventory operations, not the legacy `platform upgrade` runner.
  - The transition binds the source and target releases, and its compatibility table refuses unsupported pairs.
  - It is rehearsed on a disposable local context every release.
  - MasterPlan 21 keeps only replacement onto fresh infrastructure.

  Rationale: Production use of v0.4.0 needs a path to the next release, and no plan owned one.
  Date: 2026-10-09

- Decision (operator, 2026-10-10): Add finish-line item 9 and EP-184. The gates must wait only for
  their slowest job and stop losing runs to the builder.
  Rationale: a full gate took about 55 minutes because the same suite ran three times in sequence
  (local cabal, then the darwin and Linux flake builds), on one thread, with seven model tests
  taking about 1,090 of the suite's 1,168 seconds. Two more runs that night were lost to the
  builder's idle watchdog, gcloud reauthentication and an IAP drop. The operator: "this is very
  painful". The fixed-scope rule yields to the operator's own addition.
  Date: 2026-10-10

- Decision: EP-168 ports the driver set that passed on `83124396` stage for stage, rather than redesigning the run. It also owns the environment preflight.
  Rationale: That set is the only acceptance run known to pass unattended (C2 16/16, first try after scheduling). The overnight Tailscale and gcloud stalls were human dependencies that a preflight can refuse up front.
  Date: 2026-10-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Notes

2026-10-09: Re-scoped after MasterPlan 23 closed:
- added the fixed finish line, its native runs and the working rules;
- re-scoped EP-172 to own release transitions, recorded in an ADR 6 amendment;
- made EP-168 the port of the archived passing drivers, plus the preflight;
- named the shared Pulumi cloud world (EP-173 M4) and the local teardown stage as integration points
  with MasterPlan 25;
- corrected EP-173's registry status and removed history-only prose.

The pre-2026-10-09 text is in git history.

2026-10-10: added finish-line item 9 and EP-184 (gate wall time and lost gate runs) at the
operator's request, first in lane A.
