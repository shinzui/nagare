---
title: "Resource identity and reviewed lifecycle"
type: Capability
description: "Explain live ownership, identity, dependencies, drift, and health, and retire or collect resources through separate evidence-bound reviews."
generated:
  by: process:claude-code
  at: "2026-10-20T13:46:54Z"
capabilityId: CAP-23
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.4.0
packages:
  - nagarectl
  - nagare-dsl
interface:
  - "nagarectl inventory status|explain"
  - "nagarectl inventory adopt|retire|collect"
  - "nagarectl inventory gc --plan"
  - "nagarectl inventory rebuild-decisions|rebuild"
requires:
  - CAP-22
evidence:
  - kind: test
    resource: cli/nagarectl/test/InventoryRebuildSpec.hs
    proves: A rebuild recreates a confirmed-absent member as a new incarnation from a recorded predecessor's recovery point, records its lineage, and is refused if the member reappeared after review.
  - kind: test
    resource: cli/nagarectl/test/InventoryStatusSpec.hs
    proves: Status distinguishes absence, foreign ownership, drift, unreadability, and dependency and collection assessments.
  - kind: test
    resource: cli/nagarectl/test/InventoryIncarnationSpec.hs
    proves: Kubernetes identity is recorded from write results, replacement is detected, and rebind and data authority use the accepted incarnation.
  - kind: test
    resource: cli/nagarectl/test/InventoryLifecycleSpec.hs
    proves: Adoption binds context and fresh physical identity, rejects unsupported authority fields, and distinguishes migration incarnations.
  - kind: test
    resource: cli/nagarectl/test/InventoryNativeCollectionSpec.hs
    proves: Controller collection checks exact descendant ownership, complete discovery, deletion authority, and recovery after partial collection.
  - kind: test
    resource: cli/nagarectl/test/InventoryIntegrationSpec.hs
    proves: Scoped removal retains members while unrelated application resources remain accepted.
  - kind: guide
    resource: docs/user/resource-inventory.md
    proves: Accepted and converged revisions, logical and physical identity, live findings, retirement, and collection are explained.
  - kind: guide
    resource: docs/runbooks/inventory-operations.md
    proves: Rebind, drift repair, controller collection, and the documented recovery limits have operator procedures.
---

# Resource identity and reviewed lifecycle

The [reviewed operation ledger](reviewed-operation-ledger.md) (CAP-22) connects
accepted declarations to live provider observations. Status distinguishes
accepted and converged revisions from current health. Explain identifies a
resource's owner, dependencies, consumers, and lifecycle blockers. Provider
absence, unreadability, foreign ownership, configuration drift, and immutable
replacement are separate findings.

Logical IDs identify resources across supported renames; physical identities
identify individual provider incarnations. For Kubernetes members, Nagare
records identity from reviewed write results. Recreating a PVC under the same
name does not establish authority over its contents: status reports a replaced
or unrecorded incarnation, and data operations require a supported reviewed
exit. Adoption and rebind require explicit identity-bound decisions.

Retirement removes a scope from active desired state while retaining its
members and reserved claims. Collection is a separate review, permitted only
when policy, dependencies, physical identity, and adapter support establish
deletion authority. A confirmed collection leaves a tombstone in history.
Supported controller collection includes the exact reviewed descendants;
omitting a scope or screening collection candidates does not delete anything.

Since 0.5.0, a durable member confirmed absent can be rebuilt. `inventory rebuild-decisions` names
each missing database or volume's recorded incarnation, and `inventory rebuild` recreates it as a
new incarnation from a verified recovery point of that recorded predecessor, recording the lineage
in the review. Admission refuses a rebuild whose member reappeared after review.

## Limits

- Recorded-incarnation protection covers Kubernetes members. Other adapters
  use their own provider evidence; the release does not give every provider the
  same identity guarantee.
- Data is retained by default. Retirement does not authorize collection of
  database PVCs, credential Secrets, or broker topics; retained consumers may
  continue to block collection of their dependencies.
- Full-context physical teardown, including VM/workload collection, is not
  offered. Cloud perimeter cleanup has a separate staged procedure.
- A PVC deleted outside review while mounted (F77), or members blocked behind
  a broken StatefulSet (F78), have documented recovery limits. See the
  [inventory runbook](../runbooks/inventory-operations.md).
- An expiry timestamp or collection assessment is not proof of provider
  deletion. Scheduled backup retention is applied only through reviewed prunes.
