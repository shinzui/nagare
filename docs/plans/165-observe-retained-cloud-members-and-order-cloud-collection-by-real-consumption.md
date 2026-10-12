---
id: 165
slug: observe-retained-cloud-members-and-order-cloud-collection-by-real-consumption
title: "Observe retained cloud members and order cloud collection by real consumption"
kind: exec-plan
created_at: 2026-10-03T22:27:20Z
master_plan: "docs/masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-03T22:27:20Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Observe retained cloud members and order cloud collection by real consumption

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md).

Full plan before trimming: [165-observe-retained-cloud-members-and-order-cloud-collection-by-real-consumption.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/165-observe-retained-cloud-members-and-order-cloud-collection-by-real-consumption.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After a cloud scope is retired, the read-only collection assessment (`nagarectl inventory gc --plan --out DIR`) reports every retained cloud member as `exact-incarnation-not-present` with observation `unknown`, because the assessment has no Pulumi observer for retained cloud members. Teardown also treats Pulumi declaration ordering as consumption. On the MP-23 C3 checkpoint, the apex DNS record listed the VM, the subnet and all four firewalls as its consumers, so no member could ever be the first leaf. After this plan:
- the assessment observes retained cloud members exactly;
- consumption edges reflect real use: the VM uses the subnet, firewalls apply to the network, and DNS records point at the address;
- teardown offers leaves in a safe order: DNS records and firewalls, then subnet, address and network.

## Progress

- [ ] Milestone 1: cloud physical identity recorded at creation and read through ADR 27's checked accessor (VM, disks, address, buckets, images; ADR 27 §4 amendment), and retained cloud observation in the collection assessment. Both are tested over the Pulumi cloud-foundation world from MasterPlan 26's EP-173 M4.
- [ ] Milestone 2: consumption edges distinct from Pulumi ordering, with regressions.
- [ ] Milestone 3: the ordering is proven in EP-167's teardown-to-zero model, then confirmed natively as part of run G1 (EP-167 M2).

## Surprises & Discoveries

(None yet.)

## Decision Log

- Decision (2026-10-09): This plan owns cloud physical identity at creation.
  - It covers the identity the provider returns for a reviewed create of the VM, disks, address, buckets and images.
  - The identity is journalled in the operation's completion event and read through ADR 27's one checked accessor.
  - [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md)'s EP-124 reuses it.
  - Milestone 2 is pure and may start at once. Milestone 1 waits for EP-173 M4's world and extends it with retained members, rather than building a second Pulumi fake.

  Rationale: Both this MasterPlan's delete preconditions (F33) and MasterPlan 21's candidate slots need the same primitive, and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) §4 currently leaves these kinds without it.
  Date: 2026-10-09

## Outcomes & Retrospective

(Not started.)

