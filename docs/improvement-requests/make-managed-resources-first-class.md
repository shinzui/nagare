---
type: Improvement Request
title: Make every managed resource a first-class object in one authoritative inventory
description: Nagare's Pulumi, NixOS, Kubernetes, secret, image, and release reconcilers have no shared model of resource identity, ownership, dependencies, or lifecycle, so collisions, unsafe adoption, stale objects, and non-resumable upgrades are discovered only during live release rehearsals.
timestamp: "2026-09-16T17:06:57Z"
generated:
  by: process:openai-codex
  at: "2026-09-16T17:06:57Z"
requestId: IR-24
status: proposed
origin: mori://shinzui/nagare
---

# Improvement Request: make Nagare's managed resources explicit and authoritative

**Authored by:** an `openai-codex` session implementing and rehearsing the unreleased Nagare
0.4.0 Attic cache provider on `tan-ng-labs` under
[ExecPlan 96](../plans/96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md).
**Addressed to:** `shinzui/nagare` agents.
**Status:** proposed.
**Created:** 2026-09-16.


## Why

Nagare already behaves like a control plane, but its resource model is implicit and split across
Pulumi programs, generated host flakes, shell bootstrap recipes, `kubectl apply`, database helpers,
image publication, encrypted operator material, and release metadata. Each subsystem can be
internally declarative while the assembled platform still has no single answer to basic questions:

- What resources should exist for this context and platform revision?
- Which Nagare component owns each resource, and may another component adopt or modify it?
- Which resources depend on which identities, credentials, artifacts, and readiness conditions?
- Which rename is a migration, which missing object should be recreated, and which stale object is
  safe to delete?
- Which exact desired state was reviewed, applied, verified, and stamped during a resumable upgrade?

This gap caused the 0.4.0 cache rehearsal to let the managed PostgreSQL helper and Attic runtime
both claim `Service/nagare-system/nix-cache`. Kubernetes accepted the second apply, silently changed
the Service's meaning, and left the first database plus its PVC, Secret, and backup CronJob orphaned.
The name collision was narrow; the architectural fault is not. The same ambiguity can occur across
cloud buckets and IAM bindings, GCE and tailnet identities, NixOS state, namespaces, certificates,
databases, brokers, application workloads, backup jobs, secrets, registry images, and immutable
release payloads.

Today Nagare detects many dangerous mutations with bespoke guards, but those guards do not compose
into an authoritative view. Release rehearsals therefore become the first time independently
correct reconcilers meet, failures restart too much work, and cleanup requires an operator to infer
ownership from names and implementation details.


## Requested change

Define a versioned, typed resource inventory as the platform-wide source of truth for every object
Nagare manages. The model should be independent of any one provider and capable of representing at
least cloud infrastructure, host configuration, Kubernetes resources, durable data, credentials,
published artifacts, and release/control metadata.

Each desired resource should have:

- a stable logical resource ID that survives provider-specific names and safe renames;
- context, component, provider, scope, and ownership identity;
- its concrete address, such as a Pulumi URN, GCP full resource name, NixOS host/state identity,
  Kubernetes GVK/namespace/name, secret reference, registry digest, or release payload ID;
- dependency and ordering edges, including readiness and migration prerequisites;
- lifecycle policy for create, adopt, update, replace, retain, migrate, and delete;
- data-safety and sensitivity classifications so destructive actions and secret evidence fail
  closed;
- desired revision/digest plus observed identity, health, and drift evidence;
- the reconciling component and a durable receipt for review, apply, verification, and rollback or
  forward-recovery decisions.

Use the inventory throughout the lifecycle:

1. **Compile and validate.** Render the complete desired inventory before mutation. Reject duplicate
   logical IDs, duplicate concrete addresses, invalid dependency graphs, provider-name collisions,
   and resources without explicit owners or lifecycle policy.
2. **Review and plan.** Produce one context-bound change set across Pulumi, NixOS, cluster, data, and
   artifact boundaries. Make replacements, adoption, destructive changes, and retained data visible
   before any subsystem applies.
3. **Reconcile and resume.** Execute dependency-ordered, component-scoped steps with durable receipts.
   A failed upgrade should resume from verified component boundaries instead of rematerializing and
   replaying the whole platform.
4. **Observe and explain.** Compare desired and observed state, report drift and health in one status
   surface, and explain which component owns an object and why it exists.
5. **Migrate and garbage-collect.** Model renames and ownership transfers explicitly. Delete stale
   resources only when inventory history proves they were formerly owned, their retention policy
   permits deletion, and dependents or durable data do not block it.

Stamp provider objects with the logical ID, component owner, context, and desired revision wherever
the provider supports metadata. Refuse implicit adoption when those identities disagree. For
providers that cannot carry metadata, retain equivalent signed or checksummed state in the
context-owned inventory.

The first implementation need not be a continuously running service. A deterministic compiler,
preflight validator, transaction journal, and read-only inventory/status command would immediately
remove an entire class of release-time failures. Design their schema and reconciliation protocol so
the same model can later drive a Nagare controller when continuous drift repair, event processing,
multi-node coordination, or remote operation justifies a control plane.


## Required verification

- A hermetic fixture containing two components that claim one Kubernetes address, and equivalent
  fixtures for a cloud/provider address and logical ID, are rejected before any mutation.
- An existing object with a different or absent owner is reported as an adoption decision and is not
  modified without an explicit reviewed policy.
- A rename fixture plans create/migrate/verify/retire in dependency order and preserves durable data.
- An interrupted multi-component upgrade resumes from its verified receipts without replaying
  completed cloud, host, or cluster phases.
- Drift fixtures distinguish repairable configuration drift, missing resources, foreign ownership,
  immutable replacement, retained orphans, and safe garbage-collection candidates.
- A production-shaped disposable-context test renders one inventory, applies it, reaches convergence,
  reruns as a no-op, and proves that an intentionally removed component is retained or deleted only
  according to its declared lifecycle policy.
- Release verification archives the inventory, reviewed change set, component receipts, and final
  observed-state summary under one immutable platform payload identity.


## Acceptance

For any supported Nagare context, the operator can ask what Nagare owns and receive one complete,
typed, revision-bound inventory across cloud, host, cluster, data, secrets, artifacts, and release
state. Planning fails before mutation when identities collide or ownership is ambiguous. Applying
the plan is dependency-aware and resumable. Status identifies drift and stale resources without
guessing from names, and cleanup cannot delete or adopt a resource without the inventory's explicit
lifecycle and data-safety policy.


## Non-goals

- Replacing Pulumi, NixOS, Kubernetes controllers, or provider APIs with a bespoke resource engine.
- Requiring a highly available, always-on service for Nagare's current single-node topology.
- Automatically adopting pre-existing or foreign resources based only on matching names.
- Making every reconciliation failure self-healing before the inventory, ownership, and transaction
  contracts are proven in the operator-driven workflow.
