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
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T04:04:49Z
      mode: "update"
      note: "Interface amended after pre-implementation API validation under MasterPlan 23"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-22T03:40:43Z
      mode: "implement"
      note: "Implement typed scopes, composition, canonical wire and local compile command"
---

# Define typed resource scopes and validate composed inventories

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

Make ownership errors visible before any provider is contacted. An operator can compile several independently owned resource scopes into one inventory and receive precise errors for the original cache/database Service collision, duplicate cloud addresses, incompatible consumers, and invalid dependencies. The compiler and every future executor consume the same typed declarations.

This is the foundation of [IR-24](../improvement-requests/make-managed-resources-first-class.md). It does not yet mutate infrastructure. A scope is a complete desired-state declaration owned by one platform component, application, or standalone data service. A context inventory is the validated composition of their independently versioned declarations.


## Progress

- [x] (2026-09-22) M1: Define opaque identities, resource alternatives, lifecycle policies, and typed references; positive API control and constructor tests compile, Generic and capability-coercion attacks refuse.
- [x] (2026-09-22) M2: Implement deterministic composition, graph validation, and the versioned wire contract; 420 DSL tests pass, including 18 inventory cases.
- [x] (2026-09-22) M3 implementation: read-only CLI, canonical scope members, SHA-256 manifest binding, verified recomposition, and immutable private publication; 578 CLI tests pass.
- [ ] M3 acceptance: finish schema/fixture parity, the expanded negative API suite, adversarial boundary review, formatting, documentation, and final command evidence.
- [ ] M3: Expose read-only compilation and prove structural and graph guarantees.


## Surprises & Discoveries

2026-09-22: The local GHC is 9.12.4. Cabal downloaded missing existing dependencies without changing bounds. DSL tests passed 420/420 and CLI tests passed 578/578. The strengthened negative runner caught an unrelated ambiguous aeson import caused by explicitly exposing aeson in addition to Cabal's chosen package environment; the runner now uses the environment and its positive control imports aeson too. This validates why matching the intended compiler diagnostic is required.


## Decision Log

2026-09-16: Put the pure public domain modules in the existing nagare-dsl package under Nagare.Resource. This avoids a new package/toolchain boundary and lets typed application configurations and nagarectl share exactly one contract.

2026-09-16: Use types for structural correctness, pure checks for assembled-graph properties, and later provider observations for live facts. Neither type construction nor JSON decoding proves actual ownership or successful effects.

2026-09-16: Keep platform and application desired state independently revised. A selected-scope update is composed with all unselected declarations; omission outside the selection never means deletion.

2026-09-16: Return a CompositionCandidate rather than a bare ValidatedInventory, and provide no decoder from bytes to ValidatedInventory. The omission rule must survive the compile-to-plan file boundary, and an opaque type with two construction routes has two places to get validation wrong.

2026-09-16: Keep nagare-dsl free of hashing and never store a digest beside the content it digests. The original text required a desired-spec digest on every declaration while also preferring to keep hashing in nagarectl, which would have left the pure builders unable to construct a declaration.

2026-09-16: Claims include derived reservations for deterministic controller children, and ScopeSnapshot carries claims reserved by retained incarnations and unresolved transactions. Checked against the tree: a database's Service takes the database's name and applications are Knative Services, so direct claims alone miss a same-name collision on one core Service.

2026-09-16: Define ScopeDeclaration, ResourceBundle, DeclaredOperation, and RetirementIntent here. EP-147 and EP-148 already consumed the first two as "the EP-144 contract" although this plan did not define them, and the package dependency direction forces them into nagare-dsl.

2026-09-16: Split a scope revision into a purely derived generation and a nagarectl-computed digest, and mint ResourceId from a stable logical key rather than the provider name. A digest alone admits re-application of old content against a stale review; a name-derived identity turns a rename into a retained orphan plus an empty replacement.

2026-09-16: No hidden-constructor type in Nagare.Resource derives Generic, identities included. A GHC 9.10.3 check confirmed that Generic permits forging a value whose constructor is not exported, that coerce retags a phantom index without the constructor in scope, and that a nominal role or GADT witness stops it.


## Outcomes & Retrospective

The typed model and local compiler are implemented. M3's final acceptance audit remains in progress. No provider mutation or migration of existing deployment entry points is included in this foundation.


## Context and Orientation

The Haskell model and renderers live in cli/nagare-dsl/src/Nagare/Dsl, with smart constructors in Types.hs and engine types in Database.hs and Broker/Types.hs. Config.hs and Load.hs provide serialized typed configuration. Renderers currently return ByteString manifests. cli/nagarectl/src/Nagare/Deploy.hs applies those bytes without an ownership-aware inventory. cli/nagarectl/app/Main.hs owns CLI dispatch. Extend the two existing Cabal packages, their exposed-modules lists, and test runners rather than adding a second executable or dynamic plugin system.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) establishes separate ownership scopes, composed validation, declared controller delegation, and proof-bearing execution boundaries. [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) requires strict records, explicit deriving, the shared Prelude, and normal generic-lens conventions. For every type whose constructor is hidden, identity newtypes as well as validated/proof values, do not export Generic reconstruction or writable optics that bypass invariants; record that narrow exception in ADR 16. Ordinary domain records retain the house style. [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) already separates routing claims from TLS readiness; represent these as separate capabilities/conditions.

No child dependency is required. This plan owns Nagare.Resource.Types, Reference, Policy, Inventory, Compile, and Wire in cli/nagare-dsl/src/Nagare/Resource, the initial schemas/resource-inventory-v1.json contract, and cli/nagarectl/src/Nagare/Inventory/Command.hs for the compile command. Later child plans extend these shared contracts through this owner; they must not define competing identity or inventory types. That ownership includes ScopeDeclaration, ResourceBundle, DeclaredOperation, the contribution kinds and their closed composer dispatch, RetirementIntent, and the per-kind claim function with its derived reservations, all of which later plans consume by name.


## Plan of Work

### M1 — Typed declarations and references

Introduce smart-constructed ContextId, ScopeId, ResourceId, ScopeGeneration, ProviderAddress, PhysicalIdentity, and ContentDigest. Context identity is stored independently of its mutable display name; ResourceId is context-wide and is never parsed to recover an owner or provider name. ScopeId distinguishes platform components, applications, standalone services, and release publication. ResourceId survives an ownership transfer. PhysicalIdentity represents one observed incarnation and can change only through explicit replacement/migration.

A scope revision has two parts with different owners. ScopeGeneration is a per-scope counter that this package derives purely: a replaced scope's candidate generation is its base generation plus one and a new scope starts at one, so compilation stays deterministic. The digest of the scope's canonical bytes is attached by nagarectl, which owns hashing. EP-145 compares both parts and its own head sequence, so re-applying earlier content can never satisfy a stale review. A digest alone would allow that; a counter alone would not identify content.

Mint ResourceId deterministically from the minting scope, a stable logical key, and a role path inside the builder, such as the data volume of one database. The logical key defaults to the name first declared and is carried explicitly afterward; builders take it as an input, and EP-147/EP-148 add the optional key to the user-facing Database, Deployment, broker, and volume values. A changed key is a different resource, never an inferred rename. Without this rule, renaming a database in configuration would silently retain the old data as an orphan and create an empty database under a new identity. EP-149 owns the reviewed rename; this plan owns making identity independent of the name.

Use explicit alternatives for a directly managed declaration, a reference to an external resource, and an observed controller child. Only the directly managed alternative can carry a lifecycle owner and request mutations. Model controller delegation as bounded field/operation authority; a delegation cannot grant deletion of the parent. Shared-owner contributions are typed requests consumed by the designated owner, not multiple declarations claiming the same address.

Each managed declaration requires provider/kind, owner, executor, address claim, typed desired spec, lifecycle policy, data classification, sensitivity, and dependencies. Use distinct durable-data policies that require retention/recovery intent; do not encode all combinations as Maybe fields. Opaque public review data contains SecretRef identifiers and version tokens, never secret bytes or hashes of low-entropy plaintext. Do not derive Show/ToJSON for raw credential carriers.

A declaration never stores a digest of content it carries inline. ContentDigest appears only for external content: chart or manifest bytes, image digests, system closures, and native plan files. Per-resource and per-scope digests are derived in exactly one nagarectl function from canonical bytes. A declaration then cannot disagree with its own digest, and the pure builders in this package can construct complete declarations without a hash function. nagare-dsl has no hashing dependency today (its build-depends are aeson, base, bytestring, containers, directory, filepath, generic-lens, lens, process, text, yaml) and this plan adds none, which also keeps the package small for application authors whose nagare/Config.hs is loaded against it.

Define ResourceBundle and ScopeDeclaration here; EP-147 and EP-148 consume them and no other plan defines them. A ResourceBundle is what one builder returns: declarations, typed exports, required conditions, contributions, and declared operations. A ScopeDeclaration is one owner's complete set of bundles under a ScopeId, smart-constructed so duplicates inside the scope fail early. A DeclaredOperation is a durable one-shot action that belongs to desired state, such as a schema migration bound to image and database identities or the creation of a logical cache. It carries a stable identity, the resources it affects, typed inputs, and a recovery class, never shell text. These types live in nagare-dsl because nagarectl depends on nagare-dsl and not the reverse: the database, application, and bootstrap builders return them from pure code. EP-145 owns the execution-time operation graph that is planned from them.

A capability reference uses a type parameter plus an explicit runtime witness for its wire representation: a database connection, OCI image, storage location, or readiness condition cannot be interchanged. Prefer a GADT witness indexed by a closed Capability kind. The parameter's role is then nominal by inference, and the wire decoder recovers the index through an existential and testEquality. The nominal role is necessary, not defensive: coerce retags a phantom parameter even when the constructor is not in scope. Existential declarations retain their witnesses for validation. Unknown output values carry a producer ResourceId, output key, witness, constraints, and sensitivity. They cannot create undeclared members during apply.

No type with a hidden constructor in Nagare.Resource derives Generic. That includes the identity newtypes, not only proof values. The existing Nagare.Dsl.Types newtypes derive Generic behind a hidden constructor, and a caller can forge an invalid value through GHC.Generics.to, or a generic-lens position lens, without ever naming the constructor. Do not copy that pattern into this package. Records whose invariants live entirely in their field types keep the house style and its labels. The style rules in rules/ast-grep/haskell-style.yml do not require a Generic instance, so this passes `just haskell-style-check`.

Prove this milestone with public-API compile-failure fixtures and pure constructor tests. Misusing identities or output references must fail for the intended reason, not a missing package/import.

### M2 — Composition and validation

Implement composeInventory over a complete ScopeSnapshot and a nonempty set of scope changes. Preserve unselected scopes byte-for-byte and their revisions. Require explicit scope retirement; an unreadable/missing scope file is an error rather than an empty declaration.

ScopeSnapshot holds the context binding, every accepted scope's generation together with its complete declaration, and the claims that stay reserved outside active declarations: retained and candidate incarnations, and the reservations of an unresolved transaction. A revision vector alone cannot validate collisions, and active declarations alone would let a new scope claim the address of a retained database so that the conflict surfaces only at the live adapter. EP-145 supplies reserved claims from its resource catalogue; fixtures in this plan supply them explicitly.

composeInventory returns a CompositionCandidate: the ValidatedInventory, the base generation vector it was composed against, and the explicit changes, each a scope replacement or a retirement carrying its RetirementIntent. ValidatedInventory is the complete desired state and nothing else, so composing the same content from different bases yields the same desired-state identity, while the candidate identifies one change request. Keeping the changes beside the inventory carries the omission rule across the file boundary: a planner holding an inventory that lacks a scope its history knows must find a matching retirement in the candidate or refuse. Without that, a truncated or hand-edited compiled file that still validates as a graph reads as a request to retire. RetirementIntent is defined here and consumed by EP-149; do not define a second one.

Composition runs in three ordered phases. First, validate each scope in isolation and collect its contributions. Second, for each designated owner, check contributor authorization and key conflicts, then derive the owner's contribution-derived declarations through a pure composer selected by contribution kind. A namespace registration, for instance, becomes a foundation-owned Namespace declaration whose identity is minted from the contributing scope and key and which records that scope as a retention dependent. Third, validate the whole graph, including derived declarations and their claims. The dispatch over contribution kinds is closed and lives in this package, so EP-147 adds kinds through this owner without changing composeInventory's signature. A contribution can therefore add membership only through its owner's composer, inside validation, never during apply. An owner's effective spec is a function of composed content; its digest follows the content, not the revisions of the contributing scopes, so redeploying an application with an unchanged contribution leaves the shared resource untouched.

Canonicalize provider address claims by real collision domain. Kubernetes uses the logical cluster target, API group and resource kind, namespace when namespaced, and name; API version is presentation, not a second object identity. The cluster component is the cluster's own logical identity, because its physical identity does not exist until the cluster does; adapters resolve it at observation. Cloud bucket names are globally scoped, while instance addresses include project and zone. Pulumi URNs and cloud addresses are aliases of one declaration, not separate owned resources. Include logical claims such as hostname, database/schema, and backend route that can conflict even across different native kinds.

A declaration claims more than its own address. Each kind's claim function returns its direct claim plus derived reservations for the deterministically named objects its controller will create: a Knative Service reserves the core Service of the same name in its namespace, a Certificate reserves its target Secret, a StatefulSet reserves its ordinal Pods and template claims, and a Helm release reserves its rendered objects. This is not hypothetical. Nagare.Dsl.Database.Render names a database's Service exactly after the database (`dbServiceName n = n`), and applications render as Knative Services, so an application and a database sharing a name in one namespace fight over one core Service while their declared kinds differ. Comparing only direct group/kind/namespace/name claims would pass the same class of collision that motivated IR-24. An observed controller child must match a reservation made by its parent. EP-147 fills in the per-kind table; this plan owns the mechanism and its fixture.

Reject duplicate logical IDs before constructing maps, duplicate canonical claims, missing owners/policies, dangling or mismatched references, cycles, conflicting delegated fields, incompatible consumer requirements, and unsupported schema versions. A generated address needs an exclusive predeclared reservation or a later guarded resolution barrier; uncertainty cannot be treated as proof that no collision exists. Runtime adapters must still check live collisions.

Separate dependency relationships: consumption/retention, readiness conditions, and operation ordering. Do not infer a safe teardown order simply by reversing creation edges. Return all independent diagnostics with scope, ResourceId, canonical claim, and declaration source location.

Stable serialization has explicit schema versions, ordered maps/sets, normalized values, and an exact canonical byte encoding for digesting. Input order must not affect inventory identity; observation timestamps never enter desired digests. Decode untrusted wire data into unvalidated declarations, then re-run semantic validation. Unknown fields that could affect semantics and unsupported kinds/versions refuse. The Haskell decoder is the authoritative validator; JSON Schema describes the interoperable shape, not a replacement for graph checks.

There is no function from bytes to ValidatedInventory. The wire contract is one canonical document per scope plus a small candidate manifest naming the context binding, the base generation vector, the explicit changes, and each member's digest. nagarectl verifies member digests, decodes each scope with decodeScope, rebuilds the snapshot and changes, and calls composeInventory again. The opaque type then has exactly one construction route. It also means an unselected scope's stored bytes are never re-encoded by a different CLI version, which is the only way "byte-for-byte" can hold across releases: a single monolithic inventory file would pass every unselected scope through whichever encoder happened to run the latest application deploy.

Write the canonical encoder by hand over explicitly sorted keys, with integers and no floating-point numbers, and pin golden bytes in tests. Do not rely on aeson's object ordering. It comes from aeson's manual `ordered-keymap` Cabal flag (default on in aeson 2.3.1.0), which is a property of how a dependency was built rather than of this code. Consumers, including the TypeScript program of EP-146, hash the exact bytes they were given and never re-canonicalize.

### M3 — Compiler command and fixtures

Add `nagarectl inventory compile --input FILE --out DIRECTORY`, with optional `--json` diagnostics, to Main.hs through Inventory.Command. FILE is a version-1 candidate bundle containing context binding, the base scope revision vector, selected scopes, and their complete declarations; EP-145 will compose against persisted scope state. In this milestone an explicit complete fixture snapshot is required, including its reserved claims. The output directory contains the candidate manifest, one canonical document per scope under scopes/, and the manifest digest; writes are local/private only, and the command never runs gcloud, kubectl, Pulumi, or an artifact publisher. nagarectl computes every digest here, in one module that EP-145 reuses.

Create cli/nagarectl/test/fixtures/inventory and cli/nagare-dsl/test/ResourceInventorySpec.hs. Fixtures include the exact two-owner core Service/nagare-system/nix-cache collision, a global bucket conflict, duplicate logical IDs, a version-aliased Kubernetes duplicate, a valid independent-scope composition, and a typed unresolved output. Add four that the direct-claim model alone would miss: an application and a database sharing a name in one namespace, rejected through the Knative Service's derived reservation; a new declaration claiming the address of a retained incarnation; a candidate whose inventory lacks a known scope without a retirement; and two namespace registrations whose derived declarations collide. Add a positive and deliberately negative public API fixture per opaque guarantee, including a forgery attempt through GHC.Generics.to and a coerce between two capability indices. Strengthen the existing negative-test runner to assert the specific compiler failure, with a positive control proving the package was available. Today test/negative/check-negative-types.sh only prints WARN when the expected message is missing, so a fixture that fails for an unrelated reason still passes.

Register tests in the existing Spec.hs/Cabal lists. Every later declaration compiler must emit this representation; preserve compatibility with existing DSL functions until their migration plans remove the alternate path.


## Concrete Steps

Use the repository root as working directory. No dependency upgrades are required. Find dependency source through Mori before relying on APIs; if changing a bound later, verify the authoritative registry and upstream tags first. Never search or read /nix/store.

```bash
(cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=direct)
(cd cli/nagare-dsl && bash test/negative/check-negative-types.sh)
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
(cd cli/nagarectl && cabal run nagarectl -- inventory compile --input test/fixtures/inventory/valid.json --out /tmp/nagare-inventory-144)
```

The last command and fixture are new surfaces delivered here. It exits zero with a stable candidate digest. Running it against collision-service.json exits nonzero with both owners and the normalized address; no provider invocation is recorded. Reuse an identical output directory only if its contents verify; refuse differing contents instead of overwriting evidence. Use the project development environment if tools are not already available.


## Validation and Acceptance

A valid fixture compiles twice to identical bytes and digest despite shuffled declaration input order. Updating an application scope preserves platform revisions. A missing unselected scope refuses. All collision/reference/delegation/cycle fixtures fail before any external tool is launched. A missing owner is rejected at construction or the wire boundary. Output binding cannot add a resource or alter ownership. Public-API negative fixtures prove opaque constructors, the absence of Generic reconstruction, capability roles, and secret serialization restrictions; ordinary typechecking alone is insufficient.

The same desired content composed from two different bases yields one desired-state digest and two candidate digests. A name shared by an application and a database in one namespace is rejected through the derived reservation. A claim held by a retained incarnation blocks a new declaration. An inventory missing a known scope without a retirement refuses. Golden bytes pin the canonical encoding, so a change in a dependency's build flags cannot move a digest silently.

Tests document which guarantees are static and which are pure runtime checks. Do not claim the compiler proves live ownership, race freedom, successful migration, or provider health.


## Idempotence and Recovery

Compilation is read-only with respect to infrastructure and context intent. Canonical output files are immutable and privately staged before publication. Invalid bundles do not advance any context revision. Existing DSL/render paths remain available until individually migrated; they must not be marked inventory-covered yet.


## Interfaces and Dependencies

The following signatures describe the required boundary; define the named support types in the modules above, with hidden constructors for proof values.

```haskell
mkScopeDeclaration
  :: ScopeId -> [ResourceBundle]
  -> Either (NonEmpty InventoryError) ScopeDeclaration

mkScopeSnapshot
  :: ContextBinding
  -> Map ScopeId (ScopeGeneration, ScopeDeclaration)
  -> Map CanonicalClaim ClaimHolder -- retained, candidate, or transaction-reserved
  -> Either (NonEmpty InventoryError) ScopeSnapshot

data ScopeChange
  = ReplaceScope ScopeDeclaration
  | RetireScope ScopeId RetirementIntent

composeInventory
  :: ScopeSnapshot
  -> NonEmpty ScopeChange
  -> Either (NonEmpty InventoryError) CompositionCandidate

candidateInventory :: CompositionCandidate -> ValidatedInventory
candidateBase :: CompositionCandidate -> Map ScopeId ScopeGeneration
candidateChanges :: CompositionCandidate -> NonEmpty ScopeChange

claimsOf :: Declaration -> NonEmpty (ClaimKind, CanonicalClaim) -- direct + derived

encodeCanonicalScope :: ScopeDeclaration -> ByteString
decodeScope :: ByteString -> Either (NonEmpty InventoryError) ScopeDeclaration

data CapabilityRef (c :: Capability) -- constructor hidden; nominal role
data ValidatedInventory -- one construction route: composeInventory
data CompositionCandidate -- inventory + base vector + explicit changes
```

These signatures, together with the EP-145 and EP-149 boundaries that consume them, were type-checked as one stub module set under GHC 9.10.3 on 2026-09-16 before implementation. The check found one constraint worth keeping: a record field with a higher-rank type cannot be used as a selector or through a generic-lens label, so scoped operations stay top-level functions.

ScopeSnapshot records the context binding, every accepted scope's generation and declaration, and the reserved claims. Resource specifications are versioned provider-specific typed alternatives behind the common envelope, not arbitrary shell commands. Existing aeson, bytestring, containers, text, and the established test libraries suffice for this foundation. Hashing and IO stay in nagarectl; this package neither computes nor accepts a digest of inline content.


## Revision Notes

2026-09-16: Revised before implementation after an API validation pass requested by the operator. The interface was checked against the working tree and type-checked as stubs under GHC 9.10.3. Changes: composeInventory now returns a CompositionCandidate and there is no bytes-to-ValidatedInventory decoder; the wire format is one document per scope plus a manifest; ScopeSnapshot carries full declarations and reserved claims; claims include derived reservations for controller children; this plan now owns ScopeDeclaration, ResourceBundle, DeclaredOperation, RetirementIntent, and the contribution composition phase; declarations no longer store their own digest and nagare-dsl stays hash-free; a scope revision is a derived generation plus a nagarectl digest; ResourceId is minted from a stable logical key; no hidden-constructor type derives Generic; the canonical encoder is hand-written and pinned by golden bytes. The reason in every case is that the earlier text either contradicted itself, left a consumed type unowned, or would have passed a collision or a silent deletion that this initiative exists to stop.
