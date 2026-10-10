---
title: "Typed resource inventories"
type: Capability
description: "Compose independently revisioned ownership scopes into one context inventory and reject conflicting resource claims before mutation."
generated:
  by: process:openai-codex
  at: "2026-10-10T05:03:04Z"
capabilityId: CAP-21
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.4.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Resource.Types"
  - "Nagare.Resource.Inventory"
  - "Nagare.Resource.Compile"
  - "nagarectl inventory compile"
evidence:
  - kind: module
    resource: cli/nagare-dsl/src/Nagare/Resource/Inventory.hs
    proves: Opaque scopes, snapshots, and validated inventories compose declarations, claims, dependencies, and authorized contributions.
  - kind: test
    resource: cli/nagare-dsl/test/ResourceInventorySpec.hs
    proves: Logical IDs, provider collisions, controller reservations, dependency validation, contributions, and preservation of unselected scopes are checked.
  - kind: test
    resource: cli/nagarectl/test/InventorySpec.hs
    proves: Wire compilation rejects conflicting and malformed claims and produces deterministic inventory bytes and digests.
  - kind: test
    resource: cli/nagarectl/test/InventoryIntegrationSpec.hs
    proves: Multiple independent scopes compose and execute while sibling application members remain accepted during partial retirement.
  - kind: guide
    resource: docs/user/resource-inventory.md
    proves: Context inventory, independent scopes, ownership, identity, and declaration-to-execution boundaries are explained.
---

# Typed resource inventories

Each context composes its platform components and applications into one typed
inventory of cloud, host, Kubernetes, data, credential, artifact, and release
resources. Each owner supplies a complete scope with its own revision. Updating
selected scopes preserves the declarations and revisions of unselected scopes,
so applications can release independently of the platform.

The same typed declarations supply resource membership, native rendering,
review, and execution inputs. Composition checks logical IDs, provider
addresses, reserved controller children, dependencies, and permission to
contribute to shared objects. Two scopes cannot silently claim the same object.
An application may contribute routing or configuration to a platform-owned
object while the platform retains ownership.

Offline compilation validates the graph and produces a content-bound candidate.
Live ownership and permission to execute are established through the
[reviewed operation ledger](reviewed-operation-ledger.md) (CAP-22).

## Limits

- A compiled inventory establishes structural validity; it does not prove that
  a provider object exists, is healthy, or is owned by Nagare.
- The combined context inventory is derived from its scopes. It is not a
  separately editable desired-state document.
- The 0.4.0 release covers fresh inventory-backed contexts. General in-place
  platform payload or inventory-schema transitions are outside its contract.
- The resource vocabulary and Haskell interfaces remain experimental; this is
  not an open provider/plugin framework.
