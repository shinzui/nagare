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
[the 2026-10-04 retrospective](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-engineering-retrospective-2026-10-04.md)), to sessions
waiting on one another, and to hand-written evidence documents. The items below remove those costs
before MasterPlan 25 adds new native work.

Out of scope: hosted CI (operator, 2026-10-04: no GitHub Actions); work-data policy for team
installations ([MasterPlan 24](24-operate-nagare-as-a-team-run-workplace-intranet-paas.md));
replacement onto fresh infrastructure (MasterPlan 21); full-context teardown (MasterPlan 25); GKE;
mutating a real operator context; weakening any MasterPlan 23 guarantee.

### Finish line (fixed 2026-10-09; re-scoped by the operator 2026-10-12)

**2026-10-12:** releases are the priority. Items 10–12 are the open work, in that order. Items 1–5
stay held. See the Decision Log.

**2026-10-14:** items 6–12 are ticked and the plan is closed. Items 3, 4 (M1–M3) and 5 are
cancelled; items 1 and 2 (EP-173 M3–M4) are out of this plan's scope and are re-chartered when
item 2's trigger fires. Each carries a dated note on what covers it today, measured in Progress.

The rules of the [production readiness checklist](../releases/production-readiness-checklist.md)
apply here:
- **Fixed scope.** No item is added. A new finding that does not risk data loss goes to the deferral
  ledger with the operator's approval.
- **Evidence ticks a box.** That means a commit, a gate record or a drill log, never an estimate.
- **Only the native runs listed here.** A defect found in one stops the run. Its fix lands with a
  class-level interpreter regression that fails on the pre-fix source, and then the run is repeated
  once.

- [-] 1. The recovery model runs the production adapter registry, built in the library, rather than a
      test-local copy (EP-173 M3). Out of this plan's scope (operator, 2026-10-14), re-chartered with item 2's
      trigger and first when either world reopens. The model still assembles its own registry
      from an adapter list, while production wires twelve adapters with their fences and recoveries
      in `cli/nagarectl/app/Nagare/Cli/Inventory/Adapters.hs`. No finding since 2026-10-12 traces
      to the difference. {disposition=out-of-scope}
- [-] 2. Every registered executor and action has a provider world and a covering model scenario,
      recorded in `interpreter-coverage.json`. Deleting a scenario fails a test. This includes the
      Pulumi cloud-foundation world that MasterPlan 25 extends (EP-173 M4–M5). M4 out of this plan's
      scope (operator, 2026-10-14), re-chartered when an intranet upgrade finds a host-stage
      defect or MasterPlan 25 reopens. M5 declined. On 2026-10-14:
      F121–F124, the four upgrade defects since v0.5.0, all sat in providers without a world (host
      transport, Helm, the cloud stage's guard) and were all found on the intranet. Item 12's
      rehearsal now catches the Helm and guard classes locally; the host stage and Pulumi are still
      first run on the intranet each release. The three intranet upgrades since F121's fix ran the
      host stage clean. The coverage record (M5) has no remaining consumer: item 4's M3 and item
      5's refusal are both cancelled. {disposition=out-of-scope}
- [-] 3. Changing release or harness tooling leaves the built payload digest unchanged (EP-171).
      Cancelled (operator, 2026-10-14): the cost it removes is gone. `just release-candidate VERSION --revision REV`
      runs the tooling from the working tree, so the Apple-container fix `78a79865` landed after
      candidate `ba6dd7d7` and v0.6.3 kept its candidate. The Haskell derivations build from their
      `cli/` subtrees and the sweep skip ignores `scripts/`, so a tooling change rebuilds and
      re-sweeps nothing. What remains is hygiene: 37 of the 57 scripts under `share/nagare` are
      release, drill, check or test tooling. {disposition=declined}
- [-] 4. The release gate classifies the change between two revisions and requires only that class's
      evidence. Its output on real MasterPlan 23 candidate pairs matches a hand-checked expectation
      (EP-170). M1–M3 cancelled (operator, 2026-10-14). Landed in slices without the classifier:
      the docs carry-forward
      (ADR 25, 2026-10-09), the mutation-sweep skip when nothing under `cli/`, `nix/` or the flake
      changed (`391db1b6`), the version mask (`e9d78be3`), and covered post-land gates skipped
      (`eaec31c8`). The rest would spare a full gate on about 19 of the 125 commits since
      2026-10-10 (11 runbook and user-doc commits, 8 script-only commits), each a background
      post-land gate of about 14 minutes. M3 has nothing left to gate: no release carries fresh
      native evidence. {disposition=declined}
- [-] 5. **Native run L1 (cp3).** `nagare-harness local-acceptance` reproduces C2 on `83124396`
      unattended: 16/16 assertions, evidence assembled. A deliberately injected fault stops it at the
      named stage (EP-168). Cancelled (operator, 2026-10-14): the command does not exist, and no
      release reads
      `inventory-evidence.json`; `release-candidate` and `release-publish` need only the rehearsal
      record. `scripts/release-rehearse.sh` and `scripts/site-access-drill.sh` bootstrap a fresh
      local context from the packaged CLI today (about 7 to 9 minutes). The only dependent,
      MasterPlan 25 EP-167 M3 (held), now bootstraps its own context from those scripts. {disposition=declined}
- [x] 6. An admitted inventory context moves to a new release through a reviewed transition that
      binds the source and target releases and refuses unsupported pairs. The recovery model proves
      it under faults first (EP-172 M1–M2). Evidence: `1ae43c34`, `61368b61`.
- [x] 7. **Native run L2 (cp3).** A disposable local context converged on v0.4.0 moves to the next
      candidate through that transition. The seeded data reads back unchanged, and an unchanged
      replan has zero operations (EP-172 M3). The seeded row read back unchanged for 0.5.0 → 0.6.0
      (`f59c42a4`) and 0.5.0 → 0.6.1 (`3504325b`). F124's fix (`eb0f017e`) closed the replan: item
      12's rehearsal on `cf2fa37e` (landed as `10f28696`) replanned with zero operations.
- [x] 8. The next release is cut this way: one candidate, classified, carrying only the evidence its
      class requires, and published locally through the release runbook (integration gate, all
      children). Evidence: v0.6.1 under the 2026-10-10 release proof. Full gate on `080ae60a`,
      rehearsal record `3504325b`, and the intranet upgraded in place with login working. The
      change classification (EP-170) is not part of it.
- [x] 9. (Added by the operator, 2026-10-10.) The gates wait only for their slowest job and do not
      lose runs to the builder. The suite runs in parallel with its slow model tests sharded, the
      full gate runs each check once with local and remote work overlapping, a gcloud preflight,
      keep-awake session and transport retry protect it, and the deep tier and mutation sweep run
      inside it when needed. Before and after times are recorded (EP-184). Evidence: `7e78de52`,
      `9200626d`, `b588b03d`. M3 was dropped and M4 reduced to `just gate-release` (EP-184 Decision
      Log).
- [x] 10. (Added by the operator, 2026-10-12.) The deep tier is worth running once per release.
      - It reads the known-defect ledger, so only an unlisted class fails it.
      - It reports each class once, with a count.
      - `just gate-release` runs it only when recovery-related code changed since the revision
        of the last deep run.
      Superseded (operator, 2026-10-12): the deep tier is out of the release path, because a run
      took 6.2 hours. `just gate-release` is the gate record and the mutation sweep (ADR 25,
      2026-10-12 amendment). The ledger-aware judge landed in `acd53e28` for manual runs.
- [x] 11. (Added by the operator, 2026-10-12.) A release is two commands.
      - `just release-candidate VERSION` runs everything up to the tag, unattended: the release
        gate, the transition rehearsal, both native builds and the assembly.
      - `just release-publish VERSION` signs the tag, pushes it and publishes, retrying a draft
        that is not yet visible.
      - What stays manual: signing the tag, and choosing when the intranet upgrades.
      Evidence: `just release-candidate 0.6.1 --rehearsal` on `391db1b6` ran unattended and green
      in 28 minutes (2026-10-12, 23:47–00:15Z). The release gate (full gate record and a
      187-of-187 mutation sweep) ran in the background and was the longest step. The 0.5.0 →
      candidate rehearsal took 8.5 minutes, both native builds 5 minutes, and two identical
      assemblies 1 second. Recipes `e9bd86d1`, `cd3e92d9` and `391db1b6`; a release with no change
      under `cli/`, `nix/` or the flake skips the sweep.
- [x] 12. (Added by the operator, 2026-10-12.) The transition rehearsal catches what the intranet
      upgrade caught.
      - It runs the packaged nagarectl with every guard.
      - It sets up its own Colima environment (DNS, registry forward, clean environment).
      - F122 (the skew guard) and F123 (the Helm version) would each have stopped it.
      Evidence: `just release-rehearse REV 0.5.0` on `cf2fa37e` read the seeded row back unchanged
      and replanned with zero operations. With F122's guard reverted (`fe8212f9`) it stopped at the
      first transition apply ("minor platform-version skew requires `nagarectl platform upgrade`"),
      and with the v0.6.0 wrapper's missing Helm (`a255c1d0`) at the second transition plan
      ("helm: … does not exist"). It also found why the old rehearsal missed F122: `inventory apply`
      ran the release guard only for stages that select Pulumi, host or artifact operations, so a
      Kubernetes- and Helm-only stage skipped it. Every bootstrap and transition stage now runs it.

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

EP-169 (hosted CI) is cancelled, and EP-178 (one flake build per package) is complete. On
2026-10-14 the operator cancelled EP-168, EP-171, EP-170 M1–M3 and EP-173 M5, and held EP-173
M3–M4 behind a trigger (Decision Log).

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
| 1 | Script the local acceptance run as one command | docs/plans/168-script-the-local-acceptance-run-as-one-command.md | None | EP-171; MP-25 EP-167 M3 (reviewed local teardown stage) | Cancelled (operator, 2026-10-14: no release reads its evidence, and `scripts/release-rehearse.sh` bootstraps a fresh local context from the packaged CLI) |
| 2 | Run the local acceptance in CI | docs/plans/169-run-the-local-acceptance-in-ci.md | EP-168 | EP-171 | Cancelled (operator, 2026-10-04: no GitHub Actions; EP-168 + EP-174 cover the need) |
| 3 | Size the release gate to the change | docs/plans/170-size-the-release-gate-to-the-change.md | None; M3 needs EP-173 M5 | EP-168, EP-171 | Cancelled (operator, 2026-10-14: M1–M3 not started; the classifier would spare about 19 background gates in 125 commits). Landed slices: docs carry-forward (2026-10-09), the ledger-aware deep-tier judge `acd53e28` (item 10, then superseded on 2026-10-12), the sweep skip `391db1b6` and version mask `e9d78be3`, covered post-land gates `eaec31c8` |
| 4 | Move release tooling out of the platform payload | docs/plans/171-move-release-tooling-out-of-the-platform-payload.md | None | None | Cancelled (operator, 2026-10-14: `release-candidate --revision` already runs tooling from the working tree, so a tooling fix mints no candidate) |
| 5 | Move an inventory context to the next release through a reviewed transition | docs/plans/172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md | None (M3 rehearses on a disposable local context without EP-168) | None | Complete (2026-10-12: v0.6.0 and v0.6.1 moved the intranet; F124's zero-operation replan closed in `eb0f017e`, item 7). Since then v0.6.2 and v0.6.3 moved it through the same transition |
| 6 | Find recovery defects with adversarial provider interpreters | docs/plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md | None | None | Complete (2026-10-14: M1–M2 accepted 2026-10-05; M3–M4 out of this plan's scope, re-chartered when an intranet upgrade finds a host-stage defect or MasterPlan 25 reopens; M5 declined) |
| 7 | Gate every commit before any native run | docs/plans/174-gate-every-commit-before-any-native-run.md | None | EP-168 (shared `nagare-harness` package) | Complete (2026-10-05) |
| 8 | Make the flake check build each Haskell package once | docs/plans/178-make-the-flake-check-build-each-haskell-package-once.md | None | EP-174 | Complete (2026-10-05) |
| 9 | Make the gates wait only for their slowest job and stop losing gate runs to the builder | docs/plans/184-make-the-gates-wait-only-for-their-slowest-job-and-stop-losing-gate-runs-to-the-builder.md | None | EP-173 (shared recovery-model test files) | Complete (2026-10-12: M3 dropped, M4 reduced to `just gate-release`) |
| 10 | Make inventory status answer in seconds | docs/plans/185-make-inventory-status-answer-in-seconds.md | None | None | Complete (2026-10-12: `inventory status` from 139 s to 23–28 s, `894b58b7`, `90370d07`) |

Status values: Not Started, In Progress, Complete, Cancelled, Held. A held plan is not worked on
until the operator reopens it. EP-172 keeps its file path; its title
changed with the 2026-10-09 re-scope.


## Dependency Graph

**2026-10-14:** the plan is closed. Nothing is owed. EP-173 M3–M4 are re-chartered on a trigger:
the host-transport world when an intranet upgrade finds a host-stage defect, the Pulumi
cloud-foundation world when MasterPlan 25 reopens (its EP-165 M1 and EP-167 M1 need it). M3 goes
first when either reopens, so the worlds run the production registry. Nothing else depends on this
plan. The lane layout used before 2026-10-14 is in git history.


## Integration Points

**The acceptance runner and its output layout.** Cancelled with EP-168.
`scripts/release-rehearse.sh` bootstraps the fresh local context on the previous release, moves it
to the candidate and reads the seeded data back; its record is the only evidence the release scripts
read. The cancelled design, for reference:
- **Inputs:** candidate package, images, operator root.
- **Outputs:** one evidence directory created by the runner's plan, a staging directory, a private
  directory, and the assembled `inventory-evidence.json`.
- **Starting point:** EP-168 ports the driver set that passed on `83124396`, stage for stage. The set
  is archived, frozen, in
  [`drivers-83124396/`](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/drivers-83124396/README.md).
- **Consumers:** EP-170 reads the output as gate input. EP-172 reuses its stages against a moved
  context instead of a fresh one.

**The environment preflight.** Cancelled with EP-168. The full gate's builder probe and gcloud
preflight, `release-candidate`'s preflight and `release-rehearse.sh`'s environment scrub cover the
builder, gcloud, gate-record and Colima checks; the Tailscale tag check exists nowhere, and no open
native run needs it. The cancelled design refused unless every human dependency was settled:
- the remote builder answers;
- gcloud is authenticated (cloud contexts);
- the context's Tailscale key carries `tag:nagare-test`;
- `gate verify` is green for the candidate revision;
- only the expected Colima profile runs.

MasterPlan 25's teardown runner, if reopened, carries its own.

**The release transition.** EP-172 owns:
- the reviewed transition of an admitted context from release S to release T;
- a compatibility table in the payload (supported S→T pairs, store wire versions);
- the transition's recovery exits.

The legacy `platform upgrade` runner stays blocked for inventory contexts (`guardLegacyMutationInventory`).
MasterPlan 21 consumes the compatibility table for replacement source/target pairs.
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) records
the ownership.

**The change classification.** Cancelled with EP-170. The rules that exist live in two places:
`Nagare.Harness.CarryForward` (inert documentation carries the ancestor's gate record forward) and
`just gate-release` (the mutation sweep runs only when `cli/`, `nix/` or the flake changed beyond
the platform version). A new rule goes next to those.

**The payload boundary.** Cancelled with EP-171. `nix/platform-package.nix` is the boundary, and
the payload keeps shipping the whole `scripts/` directory.

**The gate record.** EP-174 owns it (complete). It is a JSON record per commit under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/gates/`, checked by
`nagare-harness gate verify --revision`. `just land`, the pre-push hook, `release-candidate` and
`release-rehearse` call it.

**The provider worlds.** EP-173 owns them:
- **Built:** Kubernetes, store, rename, restore and collection.
- **Re-chartered on the trigger (M4):** the Pulumi cloud foundation, Helm and the host transport.

The interpreter-coverage record (M5) is cancelled with its consumers, EP-170 M3 and EP-168.
MasterPlan 25 EP-165 and EP-167 extend the Pulumi cloud-foundation world with retained members and
teardown faults rather than building a second one.

**The local teardown stage.** MasterPlan 25 EP-167 M3 delivers reviewed removal of a local context.
EP-168 is cancelled, so the stage runs from EP-167's own runner on a context that
`scripts/release-rehearse.sh` bootstraps.

**The production adapter registry.** EP-173 M3 (re-chartered on the trigger) moves its construction from
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

2026-10-12: items 6, 8 and 9 are ticked; item 7 waits on F124. The operator re-scoped the plan to
items 10–12.

2026-10-14: items 6–12 are ticked. No item is open; items 1–5 are held. Measured state on
v0.6.3, the release the intranet runs:
- **Three releases through the two commands.** v0.6.1, v0.6.2 and v0.6.3 each ran
  `just release-candidate` (13.7 minutes for v0.6.2 with the sweep skipped, 28 minutes with it)
  and `just release-publish` (2 minutes), and each upgraded the intranet in place the same day
  with the operator's login working (`mori://tan/tan-ng-labs` `ca34a6e`, `7dca2bc`, `d92ba9c`).
- **Full gate.** 34 records since 2026-10-12: median about 14 minutes of wall time, 9 minutes when
  the Linux flake check is cached, 51 at worst. The local `nagarectl` build is the 9-minute floor.
- **Commits since 2026-10-10:** 125. 89 changed only inert documentation and carried their
  ancestor's record forward; 16 changed Haskell or Nix; 11 changed other documentation and 8
  only scripts, and those 19 each paid a full gate.
- **Upgrade defects since v0.5.0:** F121–F124, all found by the intranet's first transitions on
  2026-10-12, all in providers without a model world. The rehearsal of item 12 catches three of
  the four classes. The 0.6.2 and 0.6.3 intranet upgrades found none.
- **Decision (operator, 2026-10-14):** items 3, 4 (M1–M3) and 5 are cancelled; items 1 and 2 are out
  of this plan's scope and re-chartered when item 2's trigger fires (Decision Log). Nothing in MasterPlan 27, MasterPlan 28 or
  EP-195 depends on them; held MasterPlan 25 needs EP-173 M4's Pulumi world and bootstraps its own
  local context.

The plan closed on 2026-10-14.


## Surprises & Discoveries

- The "one-time cost" assumption in the original Vision was wrong. On 2026-10-04, six more findings
  were found natively, all cheap-layer (F49–F54). Across MasterPlan 23, 26 of 35 natively found
  findings could have been found by a type check, a fake adapter or a model test
  ([retrospective](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-engineering-retrospective-2026-10-04.md)).
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

- Decision (operator, 2026-10-14): Close the plan. Cancel EP-168, EP-171, EP-170 M1–M3 and
  EP-173 M5. Hold EP-173 M3–M4 behind a trigger: the host-transport world is reopened when an
  intranet upgrade finds a host-stage defect, and the Pulumi cloud-foundation world when
  MasterPlan 25 reopens; M3 goes first when either does. A closed plan carries no open box, so
  M3–M4 are marked out of scope and re-chartered when the trigger fires.
  Rationale: the 2026-10-14 refresh in Progress. Three releases ran through the two commands and
  upgraded the intranet; no release reads the evidence EP-168 assembles; `release-candidate
  --revision` already removes the candidate churn EP-171 targeted; EP-170's wins landed as slices
  and the rest would spare about 19 background gates in 125 commits; the coverage record has no
  consumer left. The four upgrade defects since v0.5.0 were all in providers without a world, which
  keeps M4 held rather than cancelled.
  Date: 2026-10-14

- Decision (operator, 2026-10-12): Take the deep tier out of the release path. "I can't wait 6
  hours." A release is the full gate record and the mutation sweep; `just gate-deep` stays manual.
  Item 10 is superseded and its triage dropped.
  Rationale: the 2026-10-10 run took 6.2 hours, 70% of it in five database scenarios.
  Date: 2026-10-12

- Decision (operator, 2026-10-12): Releases come first, "so I don't have to dread them". Add items
  10–12, in that order:
  - the deep tier reads the ledger and runs only after a recovery change;
  - a release is two commands;
  - the rehearsal runs the packaged nagarectl with every guard, on an environment it sets up.

  EP-168, EP-171 and EP-173 M3–M5 stay held. Of EP-170, only the deep-tier slice is reopened.
  Rationale: v0.6.0 and v0.6.1 cost these:
  - about ten manual release steps;
  - a hand-built rehearsal environment;
  - a deep tier that took 6.2 hours on 2026-10-10 and failed every shard on known ledger classes;
  - two upgrade defects (F122, F123) the rehearsal could not catch, which surfaced only on the
    intranet.
  Date: 2026-10-12

- Decision (operator, 2026-10-10): Cut this plan to the critical path of the requirement
  "developers deploy and log in; the operator changes and upgrades without losing data". EP-184
  (gate time) and EP-172 (move an installed context to the next release) stay, in that order.
  EP-168, EP-170, EP-171 and EP-173 M3–M5 are held. Item 8's release proof changes: the full gate,
  EP-172's rehearsal on a disposable local context, and the deploy-and-login check on the upgraded
  real intranet; the per-release local and cloud evidence chain is not re-run. The release scripts
  still require that evidence tree until EP-172 replaces it with the rehearsal record.
  Rationale: the review of the session logs on 2026-10-10. A 55-minute gate ran the suite three
  times, hand-adapted release drivers failed late four times in one run, and since 2026-10-07
  docs outpaced code four to one. The operator: "the current workflow is horribly broken".
  Date: 2026-10-10

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

Closed 2026-10-14. The finish line holds the deliverables and their evidence; the Decision Log holds
the decisions.


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
