---
title: "A delegated deployer is trusted and repository content is not"
status: accepted
date: 2026-11-08
authors: [shinzui]
related:
  - docs/masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md
---

# ADR 35 — A delegated deployer is trusted and repository content is not

## Status

Accepted design for [MasterPlan 33](../masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md).
Implementation and acceptance remain pending in EP-247 through EP-252.

## Context

A hosted CI deployer must apply repository changes without executing repository programs beside its credentials.
Nagare has one client-side reviewed executor and one inventory head per context. A credential holder able to write
that store cannot be confined by checks in the same client. Protected sites also require routes and a shared backend
map in `nagare-system`, even when their origins occupy delegated namespaces.

## Decision

The operator trusts the deployer program, but not repository configuration or images. Delegations are read from the
accepted head; pure authorization checks run both at review preparation and admission. They constrain kinds,
namespace membership, hostnames, image repository, protection and existing scope ownership. Reviews bind the
asserted actor `{kind, name}` and source metadata into their digest. This is attribution, not proof of identity;
enforcement against another store holder would require signed authority or a server-side boundary.

Provider credentials add confinement wherever their permission models support it. For protected routes, the explicit
system-namespace exceptions are the composed `nagare-access-backends` ConfigMap and generated DomainMappings for
owned, in-bound hosts targeting the accepted enforcer. Unrelated backend entries remain intact. The DomainMapping
Role grants lifecycle verbs on that resource kind; hostname suffix and target restrictions remain Nagare checks.
Neither arbitrary system objects nor Shomei settings become writable through the delegation. ADR 29 retains its
central-enforcer routing architecture.

Config programs run only in the credential-free build. Versioned rendered envelopes carry exact UTF-8 stdout as a
JSON string, and their digest hashes the UTF-8 bytes of that decoded string. This preserves whitespace and avoids
trying to reconstruct original bytes from parsed JSON. App, site and standalone worker deployment accept rendered
inputs; task run/delete use accepted task state. A deployer context refuses program-based loading.

EP-251 owns the local S3 transport, migration and explicit credential-file loading. EP-248 owns scoped local identity
and policy provisioning, private bundle delivery, rotation and revocation. It hard-depends on EP-251 and proves an
in-cluster apply with only the issued bundle, prefix isolation and revoked-key refusal. Administrator object-store
credentials never enter a deployer bundle. A filesystem-context bundle remains workstation-only and cannot satisfy
the hosted-deployer gate. Inventory writes continue through ObjectOps.

## Consequences

No second deployment executor is introduced. The inventory store remains a context-wide trust boundary, not a
per-delegation one. Kubernetes does not enforce every hostname constraint; the credential-backed protected-route
test must exercise the real shared-namespace path. Separate builder and deployer identities keep their credentials
apart, while repository execution stays in the build environment. Multi-operator approval and cryptographic actor
authentication remain outside this initiative.
