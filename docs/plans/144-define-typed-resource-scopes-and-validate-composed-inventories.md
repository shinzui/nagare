---
id: 144
slug: define-typed-resource-scopes-and-validate-composed-inventories
title: "Define typed resource scopes and validate composed inventories"
kind: exec-plan
created_at: 2026-09-16T17:23:44Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-16T17:23:44Z
---

# Define typed resource scopes and validate composed inventories

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

Make ownership errors visible before any provider is contacted. An operator can compile several independently owned resource scopes into one inventory and receive precise errors for the original cache/database Service collision, duplicate cloud addresses, incompatible consumers, and invalid dependencies. The compiler and every future executor consume the same typed declarations.

This is the foundation of [IR-24](../improvement-requests/make-managed-resources-first-class.md). It does not yet mutate infrastructure. A scope is a complete desired-state declaration owned by one platform component, application, or standalone data service. A context inventory is the validated composition of their independently versioned declarations.


## Progress

- [ ] M1: Define opaque identities, resource alternatives, lifecycle policies, and typed references.
- [ ] M2: Implement deterministic composition, graph validation, and the versioned wire contract.
- [ ] M3: Expose read-only compilation and prove structural and graph guarantees.


## Surprises & Discoveries

None yet; implementation has not started.


## Decision Log

2026-09-16: Put the pure public domain modules in the existing nagare-dsl package under Nagare.Resource. This avoids a new package/toolchain boundary and lets typed application configurations and nagarectl share exactly one contract.

2026-09-16: Use types for structural correctness, pure checks for assembled-graph properties, and later provider observations for live facts. Neither type construction nor JSON decoding proves actual ownership or successful effects.

2026-09-16: Keep platform and application desired state independently revised. A selected-scope update is composed with all unselected declarations; omission outside the selection never means deletion.


## Outcomes & Retrospective

Not implemented. Record demonstrated guarantees and remaining limitations when complete.


## Context and Orientation

The Haskell model and renderers live in cli/nagare-dsl/src/Nagare/Dsl, with smart constructors in Types.hs and engine types in Database.hs and Broker/Types.hs. Config.hs and Load.hs provide serialized typed configuration. Renderers currently return ByteString manifests. cli/nagarectl/src/Nagare/Deploy.hs applies those bytes without an ownership-aware inventory. cli/nagarectl/app/Main.hs owns CLI dispatch. Extend the two existing Cabal packages, their exposed-modules lists, and test runners rather than adding a second executable or dynamic plugin system.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) establishes separate ownership scopes, composed validation, declared controller delegation, and proof-bearing execution boundaries. [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) requires strict records, explicit deriving, the shared Prelude, and normal generic-lens conventions. For opaque validated/proof values specifically, do not export Generic reconstruction or writable optics that bypass invariants; record that narrow exception in ADR 16. Ordinary domain records retain the house style. [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) already separates routing claims from TLS readiness; represent these as separate capabilities/conditions.

No child dependency is required. This plan owns Nagare.Resource.Types, Reference, Policy, Inventory, Compile, and Wire in cli/nagare-dsl/src/Nagare/Resource, the initial schemas/resource-inventory-v1.json contract, and cli/nagarectl/src/Nagare/Inventory/Command.hs for the compile command. Later child plans extend these shared contracts through this owner; they must not define competing identity or inventory types.


## Plan of Work

### M1 — Typed declarations and references

Introduce smart-constructed ContextId, ScopeId, ResourceId, ScopeRevision, ProviderAddress, PhysicalIdentity, and ContentDigest. Context identity is stored independently of its mutable display name; ResourceId is context-wide and does not encode the current owner or provider name. ScopeId distinguishes platform components, applications, standalone services, and release publication. ResourceId survives an ownership transfer. PhysicalIdentity represents one observed incarnation and can change only through explicit replacement/migration.

Use explicit alternatives for a directly managed declaration, a reference to an external resource, and an observed controller child. Only the directly managed alternative can carry a lifecycle owner and request mutations. Model controller delegation as bounded field/operation authority; a delegation cannot grant deletion of the parent. Shared-owner contributions are typed requests consumed by the designated owner, not multiple declarations claiming the same address.

Each managed declaration requires provider/kind, owner, executor, address claim, desired-spec digest, lifecycle policy, data classification, sensitivity, and dependencies. Use distinct durable-data policies that require retention/recovery intent; do not encode all combinations as Maybe fields. Opaque public review data contains SecretRef identifiers and version tokens, never secret bytes or hashes of low-entropy plaintext. Do not derive Show/ToJSON for raw credential carriers.

A capability reference uses a type parameter plus an explicit runtime witness for its wire representation: a database connection, OCI image, storage location, or readiness condition cannot be interchanged. Give phantom parameters nominal roles or an equivalent representation so coerce cannot turn one capability into another. Existential declarations retain their witnesses for validation. Unknown output values carry a producer ResourceId, output key, witness, constraints, and sensitivity. They cannot create undeclared members during apply.

Prove this milestone with public-API compile-failure fixtures and pure constructor tests. Misusing identities or output references must fail for the intended reason, not a missing package/import.

### M2 — Composition and validation

Implement composeInventory over a complete ScopeSnapshot and a nonempty selected-scope replacement set. Preserve unselected scopes byte-for-byte and their revisions. Require explicit scope retirement; an unreadable/missing scope file is an error rather than an empty declaration.

Canonicalize provider address claims by real collision domain. Kubernetes uses cluster identity, API group and resource kind, namespace when namespaced, and name; API version is presentation, not a second object identity. Cloud bucket names are globally scoped, while instance addresses include project and zone. Pulumi URNs and cloud addresses are aliases of one declaration, not separate owned resources. Include logical claims such as hostname, database/schema, and backend route that can conflict even across different native kinds.

Reject duplicate logical IDs before constructing maps, duplicate canonical claims, missing owners/policies, dangling or mismatched references, cycles, conflicting delegated fields, incompatible consumer requirements, and unsupported schema versions. A generated address needs an exclusive predeclared reservation or a later guarded resolution barrier; uncertainty cannot be treated as proof that no collision exists. Runtime adapters must still check live collisions.

Separate dependency relationships: consumption/retention, readiness conditions, and operation ordering. Do not infer a safe teardown order simply by reversing creation edges. Return all independent diagnostics with scope, ResourceId, canonical claim, and declaration source location.

Stable serialization has explicit schema versions, ordered maps/sets, normalized values, and an exact canonical byte encoding for digesting. Input order must not affect inventory identity; observation timestamps never enter desired digests. Decode untrusted wire data into unvalidated declarations, then re-run semantic validation. Unknown fields that could affect semantics and unsupported kinds/versions refuse. The Haskell decoder is the authoritative validator; JSON Schema describes the interoperable shape, not a replacement for graph checks.

### M3 — Compiler command and fixtures

Add `nagarectl inventory compile --input FILE --out DIRECTORY`, with optional `--json` diagnostics, to Main.hs through Inventory.Command. FILE is a version-1 candidate bundle containing context binding, the base scope revision vector, selected scopes, and their complete declarations; EP-145 will compose against persisted scope state. In this milestone an explicit complete fixture snapshot is required. The output directory contains canonical inventory.json and its digest; writes are local/private only, and the command never runs gcloud, kubectl, Pulumi, or an artifact publisher.

Create cli/nagarectl/test/fixtures/inventory and cli/nagare-dsl/test/ResourceInventorySpec.hs. Fixtures include the exact two-owner core Service/nagare-system/nix-cache collision, a global bucket conflict, duplicate logical IDs, a version-aliased Kubernetes duplicate, a valid independent-scope composition, and a typed unresolved output. Add a positive and deliberately negative public API fixture per opaque guarantee. Strengthen the existing negative-test runner to assert the specific compiler failure, with a positive control proving the package was available.

Register tests in the existing Spec.hs/Cabal lists. Every later declaration compiler must emit this representation; preserve compatibility with existing DSL functions until their migration plans remove the alternate path.


## Concrete Steps

Use the repository root as working directory. No dependency upgrades are required. Find dependency source through Mori before relying on APIs; if changing a bound later, verify the authoritative registry and upstream tags first. Never search or read /nix/store.

```bash
(cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=direct)
(cd cli/nagare-dsl && bash test/negative/check-negative-types.sh)
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
(cd cli/nagarectl && cabal run nagarectl -- inventory compile --input test/fixtures/inventory/valid.json --out /tmp/nagare-inventory-144)
```

The last command and fixture are new surfaces delivered here. It exits zero with a stable inventory digest. Running it against collision-service.json exits nonzero with both owners and the normalized address; no provider invocation is recorded. Reuse an identical output directory only if its contents verify; refuse differing contents instead of overwriting evidence. Use the project development environment if tools are not already available.


## Validation and Acceptance

A valid fixture compiles twice to identical bytes and digest despite shuffled declaration input order. Updating an application scope preserves platform revisions. A missing unselected scope refuses. All collision/reference/delegation/cycle fixtures fail before any external tool is launched. A missing owner is rejected at construction or the wire boundary. Output binding cannot add a resource or alter ownership. Public-API negative fixtures prove opaque constructors, capability roles, and secret serialization restrictions; ordinary typechecking alone is insufficient.

Tests document which guarantees are static and which are pure runtime checks. Do not claim the compiler proves live ownership, race freedom, successful migration, or provider health.


## Idempotence and Recovery

Compilation is read-only with respect to infrastructure and context intent. Canonical output files are immutable and privately staged before publication. Invalid bundles do not advance any context revision. Existing DSL/render paths remain available until individually migrated; they must not be marked inventory-covered yet.


## Interfaces and Dependencies

The following signatures describe the required boundary; define the named support types in the modules above, with hidden constructors for proof values.

```haskell
composeInventory
  :: ScopeSnapshot
  -> ScopeReplacement
  -> Either (NonEmpty InventoryError) ValidatedInventory

encodeCanonicalInventory :: ValidatedInventory -> ByteString

decodeInventory
  :: ByteString
  -> Either (NonEmpty InventoryError) ValidatedInventory

data CapabilityRef a -- constructor hidden; nominal role
data ValidatedInventory -- no public reconstruction or mutation route
```

ScopeReplacement contains selected complete declarations plus explicit retirement intents. ScopeSnapshot records context binding and the full scope revision vector. Resource specifications are versioned provider-specific typed alternatives behind the common envelope, not arbitrary shell commands. Existing aeson, bytestring, containers, text, and the established test libraries suffice for this foundation; keep hashing/IO in nagarectl if that avoids adding dependencies to the DSL.
