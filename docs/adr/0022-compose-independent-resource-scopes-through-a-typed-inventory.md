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

## Amendment — 2026-09-16: the shared interface was validated before implementation

The interface proposed by MasterPlan 23 was checked against the working tree and compiled as stubs
before any code was written. The architecture above is unchanged. Six rules came out of that check
that will outlive the plans.

1. **An address claim includes what a controller will create.** A declaration claims its own
   address and reserves the deterministically named children of its controller. Databases here
   name their Service after the database and applications are Knative Services, which create a core
   Service of the same name, so comparing declared addresses alone misses that collision. Claims
   held by retained incarnations and unresolved transactions are part of the validated snapshot.
2. **A validated inventory has one construction route.** Composition returns the desired inventory
   together with the base it was composed against and the explicit replace and retire changes.
   Stored scope documents are decoded and composed again; nothing decodes bytes directly into a
   validated inventory. This is what carries "omission never means deletion" across a file.
3. **Digests identify content and revisions identify history.** No digest is stored beside the
   inline content it digests, no revision enters a desired digest or provider metadata, and a shared
   resource's effective digest follows its composed content. Otherwise an unchanged rerun is not a
   no-op. The pure model stays free of a hashing dependency; one operator-side module derives every
   digest.
4. **Logical identity comes from a stable key, not the provider name.** A changed key is a new
   resource. Only a reviewed migration makes a rename anything else.
5. **Authority to cause effects exists only under the writer lock.** A plan verified against a
   snapshot is evidence, not permission. Admission under the lock re-checks the head, reservations,
   and live preconditions, and yields a value that cannot leave that lock's scope. Native evidence
   is produced by an explicit adapter preparation step during planning. Adapters never re-enter a
   command that takes the lock.
6. **The store's correctness rests on conditional writes only.** Publish-if-absent,
   append-at-sequence, and replace-head-if-generation-matches are sufficient, and the transaction
   tests run against a store that has nothing else. The filesystem remains the only implementation,
   and no distributed exclusion is claimed, but a shared store needs no protocol change.

No type with a hidden constructor derives `Generic`, identity newtypes included: `GHC.Generics.to`
rebuilds such a value without naming its constructor. This is the narrow exception to
[ADR 16](0016-adopt-haskell-jitsurei-for-production-haskell.md)'s label convention that the
Decision above anticipated.

A cloud context may keep its inventory store in its state bucket, beside its Pulumi state. This
was decided the same day and is delivered by MasterPlan 23's eighth child,
[ExecPlan 151](../plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md).
Replicating a local store, or moving it by export and restore, lets two machines restore one history
and both apply, and the state at risk is deletion authority;
[ADR 13](0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) moved
the less critical Pulumi state off the workstation for the same reason. The shared store stays
narrow: one writer, refusal of a second machine through the head's conditional replacement, an
explicit operator takeover instead of a lease, and the filesystem store retained for local mode and
for a new context's first transaction. It does not detect whether another executor is alive.
ExecPlan 151 amends ADR 13 when the store exists.

## Amendment — 2026-09-22: the read-only foundation

EP-144 implements the pure model and `nagarectl inventory compile`. This does not
claim that existing mutating commands use inventory authority. The compiled bundle
stores each scope once under its SHA-256 identity; a member request retains the
complete base vector, reservation holders, and explicit replacements/retirements.
The manifest binds both this request and the desired content. Reopening verifies
all members and recomposes; JSON decoding never creates a validated inventory.
Generations are absent from desired identity and present in candidate identity.

Version-one canonical bytes are a protocol contract, pinned by scope and candidate
goldens. The encoder sorts object keys itself and normalizes unordered declaration
collections. The decoder rejects duplicate JSON keys before aeson discards them,
non-integer number tokens, unknown fields, and unsupported variants. Future readers
must retain the old canonical encoder for old member versions. Hashes provide
integrity, not authority against an actor who rewrites a complete candidate: EP-145
must bind its base to persisted history under admission.

The first contribution composer is owner-authorized namespace registration.
Generated Namespaces participate in ordinary claim validation and expose their
contributing scopes through `contributionDependents` for later retention policy.
Controller reservations include Knative core Services, Certificate Secrets,
StatefulSet Pods/PVCs, and declared Helm members. StatefulSet expansion is bounded;
invalid generated names refuse rather than throwing during graph validation.
Native parity, observed ownership, and additional provider semantics remain the
responsibility of the adapter plans. The public declaration operation vocabulary
is closed and contains no shell-text alternative.

See [the compiler contract](../architecture/resource-inventory.md) for wire layout,
scope lifecycle behavior, verification commands, and the boundary with EP-145.
