---
id: 122
slug: prove-isolated-replacement-rehearsal-and-static-ip-handoff
title: "Prove isolated replacement rehearsal and static-IP handoff"
kind: exec-plan
created_at: 2026-09-13T22:09:03Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:36Z
      mode: "update"
      note: "Refresh feasibility gate against current bootstrap rehearsal and Pulumi evidence"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Prove isolated replacement rehearsal and static-IP handoff

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [122-prove-isolated-replacement-rehearsal-and-static-ip-handoff.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/122-prove-isolated-replacement-rehearsal-and-static-ip-handoff.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

**Current scope (2026-10-09).** This child implements optional machine/cluster replacement after
MP-23, not a prerequisite for ordinary node or PostgreSQL upgrades. The
[production checklist](../releases/production-readiness-checklist.md) credits those completed drills.
MP-23's typed scopes, reviewed native effects, conditional shared history, receipt verification and
proof-based recovery are the implementation foundation. Replacement phase records never grant
mutation authority independently of inventory admission. Proposed replacement commands below remain
unavailable until their owned implementation and acceptance are complete.

Before Nagare encodes a replacement-upgrade state machine, prove the cloud operations on which its
safety promise depends. This plan delivers a disposable same-project spike that creates two tiny
hosts and a test regional address, reaches the inactive host through IAP, transfers the address from
the old host to the candidate without changing DNS, and transfers it back after an injected
verification failure. It measures both directions and records structured evidence without touching
the context's real VM, disks, address, DNS zone, or buckets.

The user-visible result is a command that either prints a JSON proof that forward cutover plus
reserved rollback fits a requested budget, or refuses with the failed invariant. Its evidence fixes
the resource topology and operation order used by the remaining child plans. This plan is a
feasibility gate, not the production cutover implementation.

The current flake now includes a hermetic `gcp-bootstrap-rehearsal` that proves two reviewed Pulumi
plans, context-bound builder/kubeconfig identity, first-boot readiness, and certificate confinement.
That check supplies reusable setup/identity patterns but does not perform a live two-host reserved-
address handoff, so none of this plan's milestones are complete.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add a fail-closed dry-run model and fake-`gcloud` contract tests for every spike operation. Deferred until the operator resumes MasterPlan 21 (2026-10-09); Milestone 2 runs first as a measurement spike.
- [ ] Milestone 2: run the disposable live two-host/IAP/static-IP forward-and-reverse handoff and retain redacted timing evidence.
- [ ] Milestone 3: record the proven topology and budget semantics in ADR 19, or revise the MasterPlan if the proof fails.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: the repository gained a hermetic GCP bootstrap rehearsal after this plan was drafted,
  but it deliberately fakes provider operations and cannot establish address detach/attach timing or
  rollback behavior.
  Evidence: `checks.aarch64-darwin.gcp-bootstrap-rehearsal` passes two reviewed-plan applications and
  identity/certificate assertions in `nix flake check`; it creates no live GCE address users.

## Decision Log

Record every decision made while working on the plan.

- Decision: use a separately reserved disposable address and transaction-prefixed resources for the
  spike; never detach the active context's `publicIp` during feasibility work.
  Rationale: the proof must exercise the same GCE API shape without turning research into a
  production outage.
  Date: 2026-09-13.
- Decision: require a live reverse handoff after an injected failed health check.
  Rationale: a fast forward move does not establish that the downtime budget can include rollback.
  Date: 2026-09-13.
- Decision: reuse the bootstrap rehearsal's context, reviewed-plan, identity, and certificate
  fixtures where applicable, while retaining a separate operator-approved live handoff proof.
  Rationale: hermetic coverage should not be duplicated, but provider control-plane timing and
  address ownership can only be established by the scoped live experiment this plan owns.
  Date: 2026-09-15.

- Decision (operator, 2026-10-09): Run Milestone 2 first, as a measurement spike, and defer Milestone 1's fake-`gcloud` contract tests until the operator resumes [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md).
  - The spike is one script with a `--dry-run` that prints every command.
  - It runs under `_require_target_project` against two tiny disposable VMs and a test reserved address, never the context's own.
  - It moves the address forward and back at least five times, timing detach, attach, the first TCP and TLS connect through the address, and IAP reachability of the inactive host.
  - It deletes what it created by exact name.
  - The operator approves the reviewed dry run once, as a single bounded sequence.

  Rationale: The spike measures provider behaviour, not a Nagare code path, so ADR 25's interpreter-first rule does not apply to it. Its numbers decide whether the rest of MasterPlan 21 is worth building, which is the cheapest decision available.
  Date: 2026-10-09

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)

