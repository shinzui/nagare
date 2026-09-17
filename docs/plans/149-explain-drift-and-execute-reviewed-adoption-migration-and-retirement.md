---
id: 149
slug: explain-drift-and-execute-reviewed-adoption-migration-and-retirement
title: "Explain drift and execute reviewed adoption migration and retirement"
kind: exec-plan
created_at: 2026-09-16T17:23:45Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-16T17:23:45Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T04:04:49Z
      mode: "update"
      note: "Interface amended after pre-implementation API validation under MasterPlan 23"
---

# Explain drift and execute reviewed adoption migration and retirement

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

Operators can ask what owns a resource, why it exists, whether it drifted, and why Nagare will or will not change it. Existing installations enter inventory management through explicit adoption. Renames and owner transfers preserve identity and durable data, while cleanup can delete only historically owned resources whose exact current incarnation and policy permit it.

This plan delivers provider-independent lifecycle planning plus inventory status/explain commands. It verifies semantics using recording adapters. Final real-provider coverage comes from the adapter children and EP-150.


## Progress

- [ ] M1: Classify observations and expose complete read-only status/explain.
- [ ] M2: Plan explicit legacy adoption and ownership transfer.
- [ ] M3: Plan migration/retirement with retained data and recovery evidence.
- [ ] M4: Expose lifecycle commands and verify decision/recovery fixtures.


## Surprises & Discoveries

None yet; implementation has not started.


## Decision Log

2026-09-16: Historical ownership plus current physical identity is required for collection. A label, name prefix, missing declaration, or matching content is insufficient.

2026-09-16: A migration is a graph of operations with explicit recovery/commit points. Reversing ordinary create order is not a migration or a safe rollback strategy.

2026-09-16: Status is a timestamped observation, never a hidden repair operation. Inaccessible and missing must remain distinct, including after a partial upgrade.

2026-09-16: Validate proposals into opaque LifecycleDecisions for EP-145's single planner instead of exposing planAdoption, planMigration, and planRetirement. The earlier planners took no inventory, so a proposal restated owner, digest, and policy beside the declaration; retirement intent existed both here and in EP-144; and a change that adopts some resources while updating others had no expression.


## Outcomes & Retrospective

Not implemented. Record decision coverage, safety boundaries, and remaining provider limitations at completion.


## Context and Orientation

Hard dependencies are [typed resource inventory](144-define-typed-resource-scopes-and-validate-composed-inventories.md) and [durable planning/execution](145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md). The foundation supplies stable logical identity, explicit owners, typed dependencies, data/sensitivity policies, physical incarnations, and independent scopes. The executor supplies private immutable history, reviewed operation graphs, writer exclusion, and recovery decisions. This plan owns cli/nagarectl/src/Nagare/Inventory/Lifecycle.hs, Migration.hs, Status.hs, and Explain.hs and extends the generic Plan/Command interfaces through their existing ownership.

Platform/Status.hs already distinguishes release identities; Platform/Deployment.hs distinguishes confirmed absence from unknown deployment. Domain/Binding.hs and Domain/Tls.hs expose ownership/readiness facts. Database/Delete.hs and Broker/Delete.hs presently derive native names/retention from live labels and annotations. Ops/Cleanup.hs performs broader cleanup. Platform/Replacement.hs, Cutover.hs, and StateTransfer.hs contain a separate safety model for candidate-host replacement, deadlines, retained resources, and irreversible writes.

[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) requires explicit adoption and truthful partial upgrades. [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) forbids treating shrink as ordinary update. [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) prohibits rollback after candidate write admission. [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) separates route/TLS ownership. [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) retains disabled cache data. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) defines lifecycle authority.

Real adapters from EP-146/147 are soft dependencies for this plan's deterministic tests. Do not mark live-provider acceptance complete from those tests; EP-150 combines them. EP-148 hard-depends on this policy so application deletes/restores do not create a temporary unsafe path.


## Plan of Work

### M1 — Status without side effects

Implement typed observation outcomes and drift findings: converged, configuration drift, missing, unowned, foreign owner, immutable replacement required, retained orphan, collection candidate, and unknown/unavailable. Report health independently from configuration drift and from historical operation completion. A read error never becomes NotFound; an old receipt does not prove current health.

Expose `nagarectl inventory status --json` and `inventory explain RESOURCE_ID --json` with context/provider identity, selected desired and converged revision vectors, observation time/freshness, owner, executor, address aliases, physical identity, consumers, required conditions, delegation, retention policy, and unfinished transaction/recovery reason. Explain traces dependencies to the owning declaration without leaking secret values or private command output. Observations may be partial; output names the missing provider scopes rather than claiming complete coverage. Read-only status can report unmanaged discoveries but never stamps/adopts them.

Compare only authoritative desired fields; adapter-owned projection rules exclude controller-generated/defaulted fields and explicitly delegated rotations. A policy change that affects comparison is versioned and makes relevant reviews stale.

### M2 — Adoption and transfer

An adoption proposal maps each chosen logical resource to an observed native address and physical incarnation, the expected owner absence or explicit previous owner, and evidence. It does not restate the proposed owner, desired spec, lifecycle or data classification, or dependencies: those are already fixed by the resource's declaration in the composed candidate, and a proposal that could disagree with the declaration would be a second source of truth. Require exact candidate/target binding and per-resource decisions. Missing metadata is a decision to review, not permission to update.

Observe all declared candidates before mutation; provider scope/account/cluster identity is part of the review. At apply, re-observe and require conditional updates/imports that reject incarnation or owner changes. Already-stamped metadata may be reused only when the private authoritative history verifies it. Conflicting legacy helpers are surfaced as alternatives, not silently merged.

Transfer between known scopes selects both scopes in one reviewed transaction, preserves ResourceId, records the prior owner, and verifies dependent capability contracts. Ownership change must not be inferred from a resource moving between files. Partially applied stamping/import remains recoverable through journaled operations; do not advance the accepted ownership head as if every object had been adopted successfully. EP-145's desired/converged distinction must report partial adoption honestly.

Support an explicit migration path for existing platform version adoption: version stamping alone does not adopt every resource. Keep old adoption inspection compatible while directing inventory management through the stronger per-resource review.

### M3 — Migration, retained resources, and collection

Define MigrationSpec as explicit operations: prepare destination, back up or seed, fence writers where needed, transfer state, verify, switch consumers, admit writes/commit, and retire old resources. Conditions and physical bindings determine ordering. A rename can create a second physical incarnation under one stable ResourceId, so history must represent active, candidate, and retained incarnations without declaring duplicate logical resources. Address claims cover all live incarnations until retirement.

Require a declared data compatibility/recovery contract. Before irreversible admission the adapter may compensate where proven safe; afterward it reports forward-recovery requirements. Retain old data and its recovery credentials/keys until verification and policy permit deletion. A database migration is not satisfied merely because its Kubernetes Job exited zero; its adapter supplies the required schema/data evidence.

Compute retirement from the RetireScope change and RetirementIntent carried by EP-144's CompositionCandidate, together with historical ownership. `inventory retire` builds that change and runs composeInventory like any other command, so a consumer in another scope that still references the retiring scope's exports is rejected by the composer, and this plan adds the history-based checks the composer cannot see. Do not define a second retirement intent here. Retained resources remain in the context catalogue with their last owner and physical identity after active declarations disappear. Garbage collection requires exact current identity/owner, completed dependency/cutover gates, policy permission, retention age, and backup/restore evidence when required. Active consumers, controller children with retained data, unknown observations, incomplete history, or unproven global artifact consumer coverage block collection. Do not recursively delete a namespace or broad storage prefix because its top-level object was owned.

Integrate replacement-upgrade resources through the existing Replacement/Cutover contract, not generic delete/recreate. Candidate write admission remains the irreversible boundary, and reserved addresses/DNS/backups retain their special protection. This plan defines the bridge and deterministic tests; it does not enable currently unfinished replacement infrastructure.

### M4 — Commands and evidence

Add `inventory adopt --input FILE --out DIRECTORY`, `inventory migrate --input FILE --out DIRECTORY`, and `inventory retire --scope SCOPE --out DIRECTORY` as proposal/review commands only. Each validates its proposal into LifecycleDecisions against the composed candidate and passes them to EP-145's single planChanges, so one reviewed change can adopt most of an existing installation's resources while updating a few, which is what the first adoption of a real context will need. Their outputs are normal EP-145 reviewed bundles; `inventory apply DIRECTORY --yes` executes them after live preconditions. Add `inventory gc --plan --out DIRECTORY` to list collection candidates and reasons for retained entries. There is no implicit prune-on-apply.

The input file formats are versioned proposal DTOs, not editable proof objects. Ship small examples in test/fixtures/inventory/lifecycle and docs/architecture/managed-resource-lifecycle.md, including legacy cache resources, a database Service rename, and app retirement. Extend the same public schema contract rather than inventing a parallel lifecycle config language. Define generic reviewed operator recovery through `inventory recover TRANSACTION --operation OPERATION --decision FILE`; the file names an exact permitted adapter recovery action and evidence, and --yes cannot override an unsupported recovery.

Add InventoryLifecycleSpec.hs and InventoryMigrationSpec.hs. Use table-driven pure decisions and injected adapter outcomes for every condition; retain integration tests where native preconditions need proof.


## Concrete Steps

Run from repository root with the development toolchain. The following tests and fixtures are delivered here.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
(cd cli/nagarectl && cabal run nagarectl -- inventory status --json)
bash scripts/check-haskell-style.sh
```

Tests use isolated temporary context/state roots with an installed fixture adapter registry. Production status requires a configured context; it exits nonzero for invalid context and emits a typed partial report for unavailable provider observations. No test discovers/deletes objects in a real project. EP-150 runs the live disposal case with explicit target identity.


## Validation and Acceptance

Fixtures distinguish all drift categories and separate unreadable from absent. Adoption of a same-name foreign object is refused unless an explicit allowed transfer is reviewed with both owners; a missing owner requires explicit adoption. Changing UID/provider incarnation after review refuses before mutation. A bad/missing history digest prevents collection.

A rename fixture visibly orders create/seed/verify/switch/retire, preserves logical identity and data, and retains the old incarnation until policy permits cleanup. Interrupt each boundary and show safe resume or explicit forward recovery. A dependent consumer blocks retirement; deleting its scope does not erase the dependency history of retained data.

Garbage collection deletes only exact reviewed candidates, with a recording adapter proving no unrelated object was touched. Unknown/global consumer coverage retains artifacts. A proposed namespace delete with undeclared or retained descendants refuses. Replacement tests preserve existing write-admission and rollback rules. Status and explain record zero mutation calls and no private values.


## Idempotence and Recovery

Read-only proposals/status are repeatable. Reviewed adoption/migration/retirement uses the same immutable receipts and context lock as ordinary apply. An interrupted operation cannot be reclassified as harmless solely from exit status. History loss requires verified backup restoration or explicit conservative re-enrollment; it never enables garbage collection. Finalize deletion only after observing exact removal and retain a tombstone.


## Interfaces and Dependencies

```haskell
classifyDrift
  :: ValidatedInventory -> InventoryHistory -> ObservationSet
  -> [DriftFinding]

decideAdoption
  :: CompositionCandidate -> AdoptionProposal -> InventoryHistory -> ObservationSet
  -> Either (NonEmpty LifecycleError) LifecycleDecisions

decideMigration
  :: CompositionCandidate -> MigrationSpec -> InventoryHistory -> ObservationSet
  -> Either (NonEmpty LifecycleError) LifecycleDecisions

decideRetirement
  :: CompositionCandidate -> InventoryHistory -> ObservationSet
  -> Either (NonEmpty LifecycleError) LifecycleDecisions

decideCollection
  :: CompositionCandidate -> CollectionRequest -> InventoryHistory -> ObservationSet
  -> Either (NonEmpty LifecycleError) LifecycleDecisions

combineDecisions
  :: LifecycleDecisions -> LifecycleDecisions
  -> Either (NonEmpty LifecycleError) LifecycleDecisions
```

LifecycleDecisions is the opaque type that EP-145's planChanges consumes. EP-145 exports only noLifecycleDecisions; this plan is the only place a non-empty value can be built, through an internal module that is not in nagarectl's exposed-modules list. Every function here takes the CompositionCandidate, so a decision is always checked against the declaration it concerns, and none of them returns a ChangeProposal: planning stays in one place. combineDecisions refuses two decisions about one resource. These signatures were type-checked as stubs with EP-144's and EP-145's under GHC 9.10.3 on 2026-09-16.

Support types are explicit alternatives in Lifecycle/Migration; identity and policy primitives remain owned by EP-144, operation/journal types by EP-145. Adapters provide conditional mutation and data-specific verification; pure functions do not assert live success. Use existing libraries. Find dependency APIs through Mori and verify releases before changing bounds; never search/read /nix/store.


## Revision Notes

2026-09-16: Revised before implementation after an API validation pass requested by the operator. The separate lifecycle planners became decision validators over EP-144's CompositionCandidate that feed EP-145's single planChanges; AdoptionProposal no longer restates what the declaration fixes; RetirementIntent is consumed from EP-144 rather than redefined. The reason is one source of truth per fact and a planner that can express a mixed adopt-and-update change.
