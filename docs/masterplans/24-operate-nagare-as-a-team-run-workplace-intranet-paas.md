---
id: 24
slug: operate-nagare-as-a-team-run-workplace-intranet-paas
title: "Operate Nagare as a team-run workplace intranet PaaS"
kind: master-plan
created_at: 2026-09-28T14:26:34Z
intention: "intention_01m3m6hh7temkvtd7cgzkb3r15"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-28T14:26:34Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Constrain tool evaluation to retained journal/state and current engines; add bounded Velero backup assessment without selecting a tool"
---

# Operate Nagare as a team-run workplace intranet PaaS

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

**Operator constraints, 2026-09-28.** Keep Nagare's typed scopes and cross-tool journal/state, including the filesystem/GCS protocol. Do not evaluate replacing them as the default recommendation. No Flux, no implicit substitute GitOps platform, and no additional messaging engines. Prioritize current database backup/recovery and Kubernetes/volume backup fit; future database engines inform extension cost but are not implementations required here. Velero is a backup evaluation candidate only, not a selected dependency. The separately authorized MP-23 scope reduction is recorded in that plan; this evaluation neither blocks its release nor silently reopens its deferred features.

Nagare began as a cheap, single-node personal PaaS: one GCP Compute Engine VM running NixOS and
k3s, with applications deployed as Knative Services through the `nagarectl` CLI. As of 2026-09-28
the operator also intends to run Nagare as a PaaS for an intranet at work. A workplace deployment
is run by more than one person, holds data that is not the operator's alone, and must be
maintainable and auditable by colleagues. Nagare was designed around one operator, and several of
its mechanisms assume that.

After this initiative, a small team can operate one Nagare installation for a workplace intranet.
Several operators can run changes without silently overriding one another; a change can require
approval from a named reviewer; operators can be granted and revoked access to the installation's
deployment material; an installation that holds work data has a reviewed way to move to a new
platform version; and the availability the platform promises (single node or otherwise) is an
explicit, documented decision with stated recovery objectives. Each of these capabilities is
delivered within the retained typed-inventory and cross-tool journal/state boundary, using
established tools where a subsequent evidence-backed adoption decision justifies them.

The initiative deliberately starts with evaluation rather than implementation. The first-pass
research record [RES-3](../research/managed-resource-inventory-scope-and-tooling-overlap.md)
found that much of MasterPlan 23's managed-resource work appears to overlap established tools
(including Kubernetes apply and database/volume backup tools), but that no candidate had
prototype evidence. Its broad overlap list is preliminary research, not a selection list. The
operator has confirmed that the pros and cons of these tools have not yet been investigated in
depth. Choosing how to build the team capabilities before
that evaluation would repeat the mistake RES-3 describes.

In scope: capturing the team's operating requirements; deciding the availability model; a bounded,
prototype-backed evaluation of tooling beneath Nagare's retained ownership/journal boundary; and,
after that evaluation, ExecPlans for multi-operator writer exclusion, named-reviewer approval, team
access to deployment material, and an upgrade path for contexts that hold work data.

Out of scope: editing [MasterPlan 23](23-make-managed-resources-first-class-through-typed-scoped-inventories.md)
or its children. This initiative produces evidence and a recommendation; any change to MasterPlan
23's scope is the operator's decision and is recorded in MasterPlan 23's own Decision Log. Also out
of scope: GKE (MasterPlan 23's operator boundary applies here too), mutating any cloud context
during evaluation, and multi-node or managed-database high availability unless EP-162's
availability decision explicitly requires it.


## Decomposition Strategy

The initiative is split by what must be known before anything can be built. Two child plans exist
now; the implementation streams are named below but deliberately not yet written, because their
design depends on the evaluation's outcome.

[EP-162](../plans/162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md)
captures what the workplace actually needs (how many operators, which roles, approval, audit,
access revocation, data classification, recovery objectives, and network placement) and records
the availability decision. It produces the criteria that the evaluation scores against.

[EP-163](../plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md)
performs the evaluation RES-3 did not: desk research against current releases, bounded prototypes
on an isolated local k3d cluster, measured footprints, and a scored comparison per layer. It ends
with a research record superseding RES-3 and a recommendation the operator can accept or reject.

After EP-163's recommendation is decided, this MasterPlan is updated (Mode: update) to add
ExecPlans for these planned streams, each shaped by the chosen tooling:

1. Multi-operator writer exclusion. Today EP-151's GCS inventory store allows one writer, has no
   lease or liveness detection, and needs an explicit operator takeover; Pulumi's own GCS backend
   has separate locking. The stream evaluates improvements to that retained coordination contract and its interaction
   with native tool locks; it does not replace Nagare's journal or conflate native backend state
   with cross-tool execution history.
2. Named-reviewer approval. Today a saved review is published by the operator who runs it. The
   stream binds approval of a change to named reviewers through the reviewed-intent boundary;
   using pull requests for approval would not itself require a GitOps reconciler.
3. Team access to deployment material. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
   places each installation's contexts, host flakes, sops secrets, and recipients in one
   operator's private repository. The stream defines how a team shares, rotates, and revokes that
   access.
4. Upgrade path for contexts holding work data. MasterPlan 23's first release covers only fresh
   contexts and treats existing data as disposable, and
   [MasterPlan 21](21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md)
   (replacement upgrades) is independent. The stream defines the supported path once work data
   exists, coordinating with both rather than duplicating them.
5. Availability implementation, only if EP-162's decision requires more than today's single node.

Alternatives considered: writing all implementation ExecPlans up front (rejected, because their
content would be speculative until the tooling is chosen); a single ExecPlan for requirements and
evaluation (rejected, because the availability decision and the tooling evaluation are
independently verifiable and the evaluation needs its own prototypes); and folding this work into
MasterPlan 23 (rejected, because its eight remaining active children have a separately agreed
release boundary, and tool research should not create a new release prerequisite).

Relevant local ADRs, read for this plan:
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
(one operator's private repository and remote Pulumi state, the main single-operator assumption);
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
(the retained typed inventory, single-writer store, and review/journal semantics beneath which
candidate tools must fit);
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
(every cloud-mutating path asserts the active context's project; any selected tool must preserve
this); [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
[ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md), and
[ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md)
(version and upgrade semantics the upgrade-path stream must honour). No cross-repository ADR was
found to apply.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 162 | Define team operating requirements and decide availability for the intranet PaaS | docs/plans/162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md | None | None | Not Started |
| 163 | Evaluate established tooling against Nagare's managed-resource layers | docs/plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md | EP-162 M1 (before EP-163 M3) | EP-162 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-162).
A whole-child hard dependency requires that child to be Complete. If only a milestone's
accepted output is needed, it is named explicitly and explained below.


## Dependency Graph

EP-162 and EP-163 start in parallel. EP-163's first two milestones (candidate research and local
prototypes) need only RES-3's criteria and do not depend on EP-162. EP-163 M3, the scored
comparison and recommendation, has a hard dependency on EP-162 M1: the accepted team requirements
record. Scoring tools against requirements that have not been stated would produce a
recommendation nobody can check. EP-162 M2, the availability decision, is a soft input to EP-163
M3; if it is not yet accepted, EP-163 scores candidates under the current single-node assumption
and says so.

The planned implementation streams have a hard dependency on the operator's decision on EP-163's
recommendation, recorded in this MasterPlan's Decision Log. They are added as ExecPlans at that
point.


## Integration Points

Evaluation criteria. EP-162 owns the requirements record (use-case concepts in `docs/use-cases/`)
and the availability ADR. EP-163 consumes both as its scoring criteria and must cite each
requirement it scores by its use-case handle. If EP-163 finds a requirement that EP-162 did not
state, it proposes it to EP-162 rather than scoring against an unrecorded requirement.

Research records. EP-163 owns the research record that supersedes RES-3 in `docs/research/`. It
sets RES-3's `status` to `superseded` with `supersededBy` pointing at the new handle; it must not
rewrite RES-3's findings.

MasterPlan 23. Neither child edits MasterPlan 23, ADR 22, or MasterPlan 23's child plans. EP-163's
recommendation is written so the operator can apply it to MasterPlan 23 in a separate change.
Concurrent MasterPlan 23 sessions are active in this repository; stage only this initiative's
files by explicit path.

Prototype isolation. EP-163's prototypes run on a dedicated local k3d cluster that is not the
Nagare local context's cluster, so they cannot disturb MasterPlan 23's retained local fixtures.
No cloud context is touched.

Cross-plan decisions that should become ADRs: the availability model (EP-162), and, once the
operator decides, the tooling boundary between Nagare and established tools (after EP-163).


## Progress

2026-09-28 scope alignment: MP-23 now has an operator-approved reduction and retains its journal/state. EP-163 is narrowed to explicit tool boundaries and a Velero backup evaluation. This planning update starts no prototype and selects no tool; child statuses remain Not Started.

2026-09-28: MasterPlan created with EP-162 and EP-163. No child plan started. The implementation
streams listed in Decomposition Strategy are intentionally not yet planned.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Retain the typed inventory and cross-tool journal/state; evaluate bounded native/database/volume tooling beneath them. No Flux or new messaging engines. Velero is evaluated for backups only, without selection or a dependency on MP-23 release.
  Rationale: These are the operator's clarified constraints. MP-23's separate scope change must not be turned into a new tooling migration project.
  Date: 2026-09-28

- Decision: The 2026-09-28 MP-23 update is separately authorized by the operator. The earlier research-only instruction below remains the boundary for EP-163 itself, not a prohibition on that already-authorized update.
  Rationale: Evaluation findings and adoption decisions must remain distinct.
  Date: 2026-09-28

- Decision: Evaluate before planning implementation. Create only the requirements and tooling
  evaluation children now, and add implementation ExecPlans after the operator decides on
  EP-163's recommendation.
  Rationale: RES-3 found apparent overlap with established tools but evaluated none of them, and
  the operator confirmed that the pros and cons have not been investigated in depth. The
  implementation design of every team capability depends on that choice.
  Date: 2026-09-28

- Decision: This initiative does not modify MasterPlan 23.
  Rationale: The operator wants to research further before changing MasterPlan 23, and MasterPlan
  23 has active concurrent implementation sessions.
  Date: 2026-09-28


## Outcomes & Retrospective

(To be filled during and after implementation.)

## Revision Notes

2026-09-28: Align evaluation with the operator-approved MP-23 scope and retained journal/state; exclude Flux/new messaging engines and keep Velero as a backup candidate only.
