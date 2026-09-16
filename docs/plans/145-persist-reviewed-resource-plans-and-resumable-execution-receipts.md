---
id: 145
slug: persist-reviewed-resource-plans-and-resumable-execution-receipts
title: "Persist reviewed resource plans and resumable execution receipts"
kind: exec-plan
created_at: 2026-09-16T17:23:45Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-16T17:23:45Z
---

# Persist reviewed resource plans and resumable execution receipts

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

An operator can retain a reviewed resource change, apply exactly that change, and resume after interruption without blindly repeating completed work. Two commands cannot concurrently overwrite context intent. Persisted evidence survives payload replacement and can be backed up and restored without manufacturing ownership from names.

This plan delivers the provider-independent planner, store, executor protocol, and CLI plumbing with deterministic fake adapters. Real cloud, host, cluster, and application adapters are delivered by other children.


## Progress

- [ ] M1: Persist independent scope revisions, immutable snapshots, and context identity.
- [ ] M2: Bind reviewed plans to observations, native bundles, and operation dependencies.
- [ ] M3: Journal execution, recover interruptions, and enforce writer exclusion.
- [ ] M4: Expose plan/apply/resume/export and prove crash/recovery behavior.


## Surprises & Discoveries

None yet; implementation has not started.


## Decision Log

2026-09-16: Preserve successful native Pulumi receipts and their offline resume property. Generic reconciliation must not turn provider access into a prerequisite for skipping already-proven work.

2026-09-16: Start with a private filesystem store and one context-wide writer. Storage is behind an interface; remote multi-writer operation is unsupported until it has a shared lock and compare-and-swap implementation.

2026-09-16: Persist accepted desired revisions before execution, and converged revisions only after verification. A failure exposes pending desired state and partial observations without pretending the old deployment is still fully active.


## Outcomes & Retrospective

Not implemented. Record crash-test evidence and storage limitations at completion.


## Context and Orientation

Hard dependency: [the typed inventory foundation](144-define-typed-resource-scopes-and-validate-composed-inventories.md). It supplies opaque ValidatedInventory, context/scope/resource identities, canonical serialization, typed references, and complete selected-scope replacement. A scope revision vector names the version of every owner declaration; changing an application does not change platform intent.

cli/nagarectl/src/Nagare/Platform/Upgrade.hs currently executes a fixed phase list through UpgradeOps. Platform/PulumiReceipt.hs privately stores started/succeeded/failed/operator-attested evidence bound to the transaction and retained native plan. Infra/Plan.hs protects saved Pulumi plans. Platform/Workspace.hs materializes immutable release assets; the new store must not live inside those workspaces. Platform/Replacement.hs and Cutover.hs already model intent/completion checkpoints and irreversible write admission; their specific recovery rules remain intact.

[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates payloads and mutable context state. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) makes context version the final upgrade commit and requires truthful partial progress. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds reviews and receipts and refuses ambiguous Pulumi starts. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) excludes private runtime state from Git. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) defines the new protocol.

Create modules under cli/nagarectl/src/Nagare/Inventory: Store.hs, Plan.hs, Journal.hs, Execute.hs, Adapter.hs, and extend Command.hs. This plan alone owns those interfaces, the context state format, and the generic inventory command parser in app/Main.hs. Provider plans add adapter implementations, not parallel journal formats.


## Plan of Work

### M1 — Durable scope state

Store private state below the existing context XDG state root in inventory/, outside platform workspaces. Allocate a stable ContextId in an explicit local initialization transaction; display-name changes preserve it, while an intentional context clone allocates a new identity. Bind it to provider target identities and the existing named context; never infer identity from a name or silently reuse copied state against another target.

Persist immutable scope declarations/revisions, composed inventory snapshots, observations, review bundles, operation events, and a small atomic head manifest. Distinguish accepted desired, last converged, retained resources, and an active transaction. The resource catalogue retains historical ownership and tombstones even when a scope is retired. Keep redacted public exports separate from private native provider bundles. Private files/directories use restrictive modes and verified paths; generated evidence rejects symlink substitution, while existing operator-owned context symlinks retain their established write-through behavior.

Implement same-directory temporary writes, explicit flush/fsync ordering appropriate to the supported platforms, and atomic rename. Journal events are immutable sequence-numbered files linked by previous digest; verify sequence and member digests during load. Recovery ignores unpublished staging files and refuses missing/reordered committed events. Atomic rename alone is not a power-loss durability guarantee: fault tests must cover publication boundaries.

Use an OS-held context lock whose release follows process death, plus head-revision compare-and-swap. Do not implement a stale PID-file guess. Resolve the installed unix locking API through Mori during implementation; do not prescribe a new dependency without registry verification. Hold the mutation lock through external effects. A read-only plan captures the base revision; apply checks it again under lock. An unresolved transaction reserves its scopes/claims and blocks a conflicting new apply.

### M2 — Reviewed operation plans

The planner compares validated desired state, prior accepted/converged state, and typed observations. Build an explicit operation graph with stable OperationId, covered ResourceIds, executor identity/version, input digests, preconditions, readiness conditions, native bundle references, and recovery contract. Resource dependencies and executor grouping are different: one Pulumi update may cover many resources, and one resource may require several migration operations.

Only a reviewed plan bound to context identity, provider target, scope revision vector, payload identity, policy version, canonical inventory digest, and native evidence can become executable. Review includes retained resources and adoption/replacement/deletion decisions. For now reject adoption, migration, and garbage collection unless the lifecycle child has supplied their reviewed proof types; never default them to ordinary update.

An unresolved output is allowed only in its declared position and type. If native planning cannot be completed before a prerequisite is created, represent a review barrier. Review and execute the bounded preparation transaction, then require a newly reviewed resolved native plan before dependent mutation. Do not silently replace evidence in a previously approved bundle. Secret values are fetched privately by adapters at execution; secret version references are bound without exposing plaintext.

Wire decoding creates an untrusted plan. Verification checks all members, versions, bindings, base revisions, and authorizations before returning opaque ReviewedPlan or ExecutablePlan. Do not export constructors, FromJSON instances, Generic reconstruction, or setters that bypass verification.

### M3 — Execution and recovery

Define explicit pending, intent-recorded, completed, failed, ambiguous, and operator-resolved states. Persist operation intent before its first effect and observed completion afterward. Distinguish a known no-effect failure from partial/unknown effects; a nonzero exit does not prove no mutation. Recovery asks the adapter for proof of completion, safe retry against the identical review, or an unresolved outcome requiring a reviewed operator decision.

Separate completion evidence from fresh health. A verified Pulumi receipt can skip the cloud operation without credentials/tool/provider access, while later dependent actions check the live conditions they actually require. Later health failure does not authorize rerunning a completed data migration. A complete transaction is a no-op. If the base inputs change, create a new review; do not edit the old transaction into a different request.

Commit accepted scope revisions atomically with transaction activation. After successful verification, advance the converged head. Preserve the special platform sequence of cluster completion marker followed by context version commit for the final integration child. For operational actions such as restart or backup, journal the operation against the existing scope revision without inventing a new desired configuration.

Back up the complete store under lock, including journal, declarations, retained identities, and private evidence, with encryption appropriate to existing operator practice. Restore verifies all members and target bindings into staging before installation, refuses an active writer, and re-observes before future mutation. Lost history is a recovery state; labels cannot recreate deletion authority. A checksummed store is not a signature or defense against someone able to rewrite all of it.

### M4 — Commands and deterministic verification

Extend inventory compile to load the stored base scope snapshot. Add `inventory plan --inventory DIRECTORY --out DIRECTORY`, `inventory apply DIRECTORY --yes`, `inventory resume TRANSACTION --yes`, and `inventory export --out DIRECTORY`. Global context selection remains authoritative. Commands display exact selected scopes and reviewed digest. Apply refuses an unreviewed/changed bundle even with --yes; that flag acknowledges the displayed bound decision and does not bypass policy.

Create InventoryTransactionSpec.hs with injected clocks, file operations/failure points, and recording adapters. A three-component fixture simulates cloud, host, and cluster. Interrupt at each persistence/effect boundary; prove proven operations are skipped, ambiguous operations stop, and the final context commit cannot occur early. Run two actual local processes against one temporary store to test lock exclusion, not just an in-memory flag.


## Concrete Steps

Run from the repository root using its development environment as necessary. The fixture and commands below are delivered here; no provider credentials are needed.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
(cd cli/nagarectl && cabal run nagarectl -- inventory plan --inventory test/fixtures/inventory/compiled --out /tmp/nagare-review-145)
bash scripts/check-haskell-style.sh
```

Use a temporary XDG configuration/state directory in tests. The plan command records zero mutations, lists selected scopes and operation IDs, and produces a digest-bound review. Apply/resume behavior is exercised by recording adapters inside the Haskell suite; do not expose fake execution as a production CLI backend.


## Validation and Acceptance

Exercise changed base revision, changed provider target, edited inventory/native bundle, unknown schema, unredacted secret, interrupted journal/head publication, process death, concurrent writer, and incomplete restored backup. Each refuses before a new external effect. A successful receipt with a lost final journal event repairs progress only when bindings verify. A started receipt without authoritative completion remains ambiguous. A failed phase cannot advance the converged head. An unchanged completed transaction records no provider calls.

Retained histories and receipts survive removal of a payload workspace. Exported public review contains no secret fields, sensitive native payloads, command stderr dumps, or private paths; the encrypted recovery backup is a separate artifact.


## Idempotence and Recovery

Never rewrite reviewed bundles or successful receipts in place. Resume reads the exact original review and current journal. A stale review requires a new plan. Recovery never deletes provider objects or abandons ownership history. Support read-only inspection of old upgrade schemas; generic conversion of old success text into new proof is forbidden. EP-150 owns the legacy transaction integration.


## Interfaces and Dependencies

Nagare.Inventory.Adapter owns a closed, versioned adapter registry with pure declaration/plan validation and injected IO methods for observe, preflight, execute, verify, and recover. Adapters declare all ResourceIds their operations can affect. Execute never accepts an arbitrary shell string.

```haskell
planChanges
  :: ValidatedInventory -> InventoryHistory -> ObservationSet
  -> Either (NonEmpty PlanError) ChangeProposal

verifyReview
  :: StoreSnapshot -> ReviewBundle
  -> Either (NonEmpty ReviewError) ReviewedPlan

applyReviewed
  :: InventoryStore -> AdapterRegistry -> ReviewedPlan
  -> IO (Either ExecutionError TransactionResult)

resumeTransaction
  :: InventoryStore -> AdapterRegistry -> TransactionId
  -> IO (Either ExecutionError TransactionResult)
```

Define InventoryStore operations for consistent read, lock-scoped compare-and-swap, immutable publication, append event, and verified export/restore. Plan and Journal wire versions are independent of platform semantic version. Use existing aeson, crypton, bytestring, containers, directory, unix, time, and test infrastructure; locate library APIs through Mori before implementation.
