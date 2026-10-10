---
title: "Reviewed operation ledger"
type: Capability
description: "Apply immutable context-bound reviews through a durable cross-tool journal, resume from completion evidence, and close stopped transactions by operation proof."
generated:
  by: process:openai-codex
  at: "2026-10-10T05:03:04Z"
capabilityId: CAP-22
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.4.0
packages:
  - nagarectl
  - nagare-dsl
interface:
  - "nagarectl inventory plan|apply|resume|recover|close"
  - "nagarectl inventory store"
  - "nagarectl app image-plan"
  - "--save-plan DIR"
requires:
  - CAP-1
  - CAP-21
evidence:
  - kind: module
    resource: cli/nagarectl/src/Nagare/Inventory/Execute/Driver.hs
    proves: Apply and resume share one operation driver with intent-before-effect journalling and evidence-bound recovery.
  - kind: test
    resource: cli/nagarectl/test/InventoryTransactionSpec.hs
    proves: Reviewed admission, conditional storage, executor claims, retained ownership, and operation ordering are exercised.
  - kind: test
    resource: cli/nagarectl/test/InventoryObjectOpsSpec.hs
    proves: Conditional head writes, lost acknowledgements, conflicting clients, and resume without repeating proved effects are tested.
  - kind: test
    resource: cli/nagarectl/test/InventoryCloseSpec.hs
    proves: Closure preserves landed effects, reverts scopes with no effects, refuses unresolved proof, and supports attested closure and re-entry after failed release writes.
  - kind: test
    resource: cli/nagarectl/test/InventoryGogolSpec.hs
    proves: The GCS transport exercises conditional writes, exact object reads, and structured provider failures.
  - kind: conformance
    resource: docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/cloud/inventory-evidence.json
    proves: The cloud acceptance record binds inventory, reviewed changes, component receipts, and final observation to the 0.4.0 candidate payload.
  - kind: guide
    resource: docs/runbooks/inventory-operations.md
    proves: Saved apply, interrupted resume, explicit takeover, proof-based closure, and attested recovery procedures are documented.
---

# Reviewed operation ledger

An operator plans changes to a [typed resource inventory](typed-resource-inventories.md)
(CAP-21) in a selected [target context](target-contexts-and-onboarding.md) (CAP-1).
The saved review binds the context, payload, base and desired revisions, native
inputs, dependencies, and execution preconditions. Apply reloads that immutable
review, rechecks authority, and runs dependency-ordered operations through the
native Pulumi, NixOS, Kubernetes, Helm, artifact, data, and access adapters.

The journal records intent before an effect and evidence afterwards. Resume
skips proved completion and asks the adapter to resolve uncertain operations.
An unreadable provider or a lost response remains unresolved until evidence or
an explicit supported recovery decision establishes the next action.

When resume cannot progress, closure classifies operations by proof. A changed
scope with no effects returns to its base revision; a scope with landed effects
keeps its desired revision so those resources remain owned. Close makes no
provider changes and asserts no convergence. An attested last-resort close
records the operator, reason, and evidence, accepts no unproved completion, and
leaves later plans to observe the resources again.

Local contexts store private history on the filesystem. Cloud contexts can share
history in the context's GCS state bucket. Conditional writes and an executor
claim enforce one writer; takeover explicitly transfers recovery to another
client after the original executor and its child processes have stopped.

## Limits

- Execution spans native systems and is not an atomic transaction that rolls
  every completed effect back. Safe retry depends on each adapter's evidence.
- The executor claim has no lease or automatic expiry. There is no always-on
  coordinator or general multi-operator approval protocol.
- Active data fences and migrations require their dedicated recovery exits;
  ordinary close cannot bypass them.
- Keep private review members, history, and recovery credentials. The public
  review summary alone is insufficient for execution or recovery.
- A transient GCS read during journal writing can leave an apply ambiguous
  until resume (F89); an ambiguous resume may omit its decision reason from
  terminal output (F94). See the [0.4.0 limits](../releases/v0.4.0.md).
