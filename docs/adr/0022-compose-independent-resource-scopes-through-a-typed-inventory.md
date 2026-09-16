---
title: "Compose independent resource scopes through a typed inventory"
status: accepted
date: 2026-09-16
authors: [shinzui]
related:
  - docs/improvement-requests/make-managed-resources-first-class.md
  - docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md
  - docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md
  - docs/adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md
  - docs/adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md
---

# ADR 22 — Compose independent resource scopes through a typed inventory

## Status

Accepted as the architecture for MasterPlan 23 on 2026-09-16 following the operator's design discussion. Implementation is not yet complete; the existing command behavior remains as described in the earlier ADRs until its migration is verified.

## Context

The Attic rehearsal exposed two components claiming the same Kubernetes Service. Independent reconcilers have no common ownership or lifecycle authority. A global inventory alone would not solve the problem if it were a handwritten mirror of scripts, and one global desired-state document could incorrectly couple application deployments to platform upgrades. The operator requires an explicit platform/application boundary and wants types and pure validation to replace duplicated shell policy.

## Decision

Each context has a stable identity and independently revised ownership scopes. Platform components, applications, and standalone data services declare complete desired state only for their own scopes. One composed context inventory checks address claims, resource identities, dependencies, and policy across those declarations. Omission outside the selected scopes never requests deletion. Platform and application releases remain independent. A coordinated migration may explicitly select several scopes.

A managed resource has one lifecycle owner. Consumers hold typed references to exported capabilities, not authority to replace or delete the provider. Shared resources have designated owners. Where consumers contribute routing or policy entries, the owner validates and composes those contributions into its resource. Delegated controllers have explicit field or operation authority; generated children are observed through their controlling resource, not adopted as independently managed declarations.

Desired declarations, live observations, and execution history are separate versioned records. Logical identity survives renames; provider addresses and observed physical incarnations are distinct. Provider address equality follows the provider's collision domain, not the owning context's display name. The local implementation checks its composed inventory and live target, but does not claim distributed exclusion across independent workstations.

Haskell owns the common domain contract. Smart constructors and explicit alternatives rule out structural errors. Pure validation proves graph properties and yields opaque validated values. Review and guarded execution similarly require evidence-bearing values; decoding JSON does not grant authority. Constructors, generic reconstruction, and writable optics must not bypass those boundaries. Raw credentials have no representation in the public review format. Native provider programs consume versioned declaration data and report their actual resource registrations so that tests can establish parity with inventory membership.

Every resource is declared before external mutation. Generated values are typed output references with declared producers, destinations, and constraints. They cannot add resource membership or silently broaden a reviewed operation. If a provider cannot plan until an output exists, a bounded preparation transaction is reviewed first and the dependent operation requires a subsequent review of its resolved native plan. Review is not permission for arbitrary later expansion.

Operations run at native executor boundaries: a Pulumi stack update, a guarded host activation, or a Kubernetes component reconciliation may cover several declared resources. Native saved plans, project and cluster guards, protected data policies, and host self-reversion remain authoritative safety layers. Readiness conditions and migration operations form an explicit execution graph. Intent precedes each external mutation and durable observed completion follows it. Ambiguous interruption stops automatic replay unless adapter evidence proves a safe resolution. Proven Pulumi completion remains skippable without a provider call; current health is reported separately.

Initially, one operator state directory owns immutable snapshots, reviewed bundles, and an append-only operation journal with a context-wide writer lock and revision checks. State is private, backed up, and independent of release workspaces. A checksummed history provides integrity checks, not authentication against an actor who can rewrite the store. Loss of authoritative history enters recovery; names and labels alone cannot reconstruct deletion authority. Remote writers and continuous reconciliation require a later storage/coordination implementation of the same contract.

Release publication uses a distinct workflow-owned scope. Its ephemeral runner persists the reviewed publication binding atomically with creation of a provider draft release, retains exact asset/verification evidence there before publication, and recovers completion from the unchanged published object. Authorized same-tag workflows are serialized. This narrow provider recovery protocol is not a general remote context store; expiring CI artifacts are not authoritative history, and published legacy releases are not retroactively rewritten.

Adoption, ownership transfer, replacement, and retirement are reviewed transitions bound to observed physical identity. Durable data defaults to retention. Garbage collection requires ownership history, exact identity, resolved dependents, and an explicit deletion policy. Artifact retention considers all known consumers; release publication has its own scope rather than belonging to whichever deployment context first consumed it.

All supported Nagare mutation entry points eventually use this protocol. Pure decisions move from shell into typed modules; transport, host activation, and native provider tools may remain narrow adapters. Migration acceptance includes removal of superseded orchestration and policy implementations. No release claims complete inventory coverage while supported mutation paths remain unaccounted for.

## Consequences

Application deployments and platform upgrades can advance independently while detecting shared-resource conflicts. Existing installations need explicit adoption and old transactions need a versioned compatibility path; neither is inferred from matching names. The model enables deterministic tests for collision, lifecycle, and recovery policy, while real provider observations and integration tests remain necessary.

This does not introduce a daemon, distributed scheduler, generic replacement for Pulumi/NixOS/Kubernetes, automatic data rollback, or a security boundary against administrators using raw provider tools. Types reduce invalid internal states; they do not establish live ownership, permission, freshness, or successful external effects.
