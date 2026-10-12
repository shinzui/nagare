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

Full plan before trimming: [144-define-typed-resource-scopes-and-validate-composed-inventories.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/144-define-typed-resource-scopes-and-validate-composed-inventories.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Make ownership errors visible before any provider is contacted. An operator can compile several independently owned resource scopes into one inventory and receive precise errors for the original cache/database Service collision, duplicate cloud addresses, incompatible consumers, and invalid dependencies. The compiler and every future executor consume the same typed declarations.

This is the foundation of [IR-24](../improvement-requests/make-managed-resources-first-class.md). It does not yet mutate infrastructure. A scope is a complete desired-state declaration owned by one platform component, application, or standalone data service. A context inventory is the validated composition of their independently versioned declarations.

## Progress

- [x] (2026-09-22) M1: Define opaque identities, resource alternatives, lifecycle policies, and typed references; positive API control and constructor tests compile, Generic and capability-coercion attacks refuse.
- [x] (2026-09-22) M2: Implement deterministic composition, graph validation, and the versioned wire contract; 420 DSL tests pass, including 18 inventory cases.
- [x] (2026-09-22) M3 implementation: read-only CLI, canonical scope members, SHA-256 manifest binding, verified recomposition, and immutable private publication; 578 CLI tests pass.
- [x] (2026-09-22) M3 acceptance: schema/fixture and compiled-output parity, 23 expected-diagnostic negative fixtures plus positive control, boundary review, formatting, documentation, and provider-free command evidence complete.
- [x] (2026-09-22) M3: Expose read-only compilation and prove structural and graph guarantees.

## Surprises & Discoveries

2026-09-22: The local GHC is 9.12.4. Cabal downloaded missing existing dependencies without changing bounds. DSL tests passed 420/420 and CLI tests passed 578/578. The strengthened negative runner caught an unrelated ambiguous aeson import caused by explicitly exposing aeson in addition to Cabal's chosen package environment; the runner now uses the environment and its positive control imports aeson too. This validates why matching the intended compiler diagnostic is required.

2026-09-22: The final boundary pass found two normalization hazards. Aeson intentionally collapses duplicate object keys, so token validation now rejects duplicates and non-integer tokens before conversion to its map representation. Native Kubernetes API versions must be normalized before computing claims; kubernetesAddress maps apps/v1 and apps/v1beta1 to the same address, and provider-address validation rejects noncanonical groups. Controller-generated name overflow is reported as a diagnostic, not a partial constructor exception. Diagnostic matching also flattens wrapped compiler messages so qualified aeson instance errors are recognized without accepting unrelated failures.

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

2026-09-22: Keep the compiled fixture request in input.json using immutable scope-member references, with candidate.json binding its digest and resulting desired identity/generations. Rationale: the complete base and explicit retirements remain inspectable without duplicating scope documents or creating a bytes-to-proof decoder. EP-145 must compare this base to its authoritative store; a self-consistent fixture is not authenticated ownership history.

2026-09-22: Ship namespace registration as the first closed contribution composer and expose contributionDependents for retention policy. Controller-specific specs reserve their deterministic children; native content is referenced by digest. Operation kinds are a closed vocabulary. Rationale: later adapters extend explicit alternatives while preserving the composition signature, and no executor may invent new members or interpret arbitrary operation text. ADR 22 and docs/architecture/resource-inventory.md record the durable contract; ADR 16 records the opaque-type exception.

## Outcomes & Retrospective

Complete on 2026-09-22. The typed model, canonical scope wire contract, graph validator, immutable private compiler output, and verified recomposition loader are implemented. All 424 DSL tests and 580 CLI tests pass, including 22 pure inventory cases and eight compiler cases. The API positive control and all 23 negative compilation fixtures pass. Haskell style, Fourmolu, Cabal Gild, JSON Schema metaschema validation, ten fixture shape checks, compiled-output schema checks, and git diff whitespace checks pass.

The actual built executable compiled the valid fixture twice with PATH=/nonexistent and returned the same candidate digest. The collision fixture returned a nonzero exit with both owners and the canonical Service claim and created no output directory. Output directory/file permissions were verified as 0700/0600. This proves the command needs no provider executable. It does not prove live ownership, health, concurrency, native declaration parity, or persisted-history admission; those remain the named later plans' responsibilities. Existing deployment paths are unchanged.

```text
GHC 9.12.4
nagare-dsl-test: All 424 tests passed
nagarectl-test: All 580 tests passed
public API: positive control + 23 intended negative rejections
candidate: d29d70896d10117d2cd550b5a17804d1da9a45a0a0706192dd3b03fd54e13632
PATH=/nonexistent: two identical valid compilations; collision refuses
JSON Schema: fixture inputs and compiled manifest/request/scope members validate
```

