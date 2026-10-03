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
---

# Observe retained cloud members and order cloud collection by real consumption

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md).


## Purpose / Big Picture

After a cloud scope is retired, the read-only collection assessment (`nagarectl inventory gc --plan --out DIR`) reports every retained cloud member as `exact-incarnation-not-present` with observation `unknown`, because the assessment has no Pulumi observer for retained cloud members. Teardown also treats Pulumi declaration ordering as consumption. On the MP-23 C3 checkpoint, the apex DNS record listed the VM, the subnet and all four firewalls as its consumers, so no member could ever be the first leaf. After this plan:
- the assessment observes retained cloud members exactly;
- consumption edges reflect real use: the VM uses the subnet, firewalls apply to the network, and DNS records point at the address;
- teardown offers leaves in a safe order: DNS records and firewalls, then subnet, address and network.


## Progress

- [ ] Milestone 1: retained cloud observation in the collection assessment.
- [ ] Milestone 2: consumption edges distinct from Pulumi ordering, with regressions.
- [ ] Milestone 3: native ordering proof with EP-167.


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


## Outcomes & Retrospective

(Not started.)


## Context and Orientation

The cloud scope is compiled by `Nagare.Inventory.Cloud.compileCloudScope` from the Pulumi program's canonical registration bundle (`infra/pulumi/src/resourceDeclarations.ts`). Each registration's `dependencies` currently mixes Pulumi parent and ordering edges with real consumption. `Nagare.Inventory.Status.consumersOf` treats every dependency as consumption.

The collection assessment lives in `cli/nagarectl/app/Nagare/Cli/Inventory/` (the `inventory gc` path), and execution builds retained cloud adapters through `Nagare.Cli.Inventory.CloudHistory.loadCloudHistory`. MP-23 commit `07d203ad` showed that admission of a cloud retirement needs the Pulumi observer installed for retained members even when a review has no operations (`cloudRetained` in `Execution.hs`). The assessment needs the same treatment.

The motivating evidence is in MP-23 finding F40 (`docs/audits/mp23-findings.md#f40`): the assessment output listing reasons per member. ADR [0022](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) governs collection; ADR [0009](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires every cloud read to stay inside the active context's project.


## Plan of Work

Milestone 1:
- Give the collection assessment the same retained cloud observer as execution: `loadCloudHistory` plus `inventoryPulumiAdapterWithCollections`, with the context's Pulumi environment prepared through `prepareInfraTargetWithPulumi`.
- Regression: a retained cloud member present in a fake stack export assesses as present with its exact physical ID.

Milestone 2:
- Separate ordering from consumption. Either the registration bundle marks each edge's kind, or the compiler derives consumption from typed resource kinds.
- Teach `consumersOf` and teardown eligibility to use consumption only.
- Keep reverse-order deletion safe: a producer is never collected before its real consumers.
- Regressions: firewalls are not consumers of DNS records, and a subnet still blocks its network.

Milestone 3:
- On a disposable context with all scopes retired (EP-167), teardown offers leaves in the expected order and each collection deletes exactly one resource.


## Concrete Steps

Work in `cli/nagarectl` and `infra/pulumi`. Run `cabal test nagarectl-test`, `just haskell-style-check`, `python3 scripts/check-haskell-architecture.py`, and the Pulumi program's own type check after changing the registration bundle.


## Validation and Acceptance

Accepted when:
- the assessment reports retained cloud members with exact observations;
- teardown offers a leaf as soon as the scope is retired;
- the native order deletes leaves before their producers with no refusal.


## Idempotence and Recovery

Assessment and planning are read-only. Changing edge kinds changes the canonical scope digest, so existing contexts replan once: a policy-only, verify-only review.


## Interfaces and Dependencies

This plan owns the consumption-edge contract in the cloud registration bundle. EP-164 relies on consumption, not ordering, to decide whether a VM is a leaf. Hard dependency: none. Soft dependency: EP-164's eligibility change touches the same function.
