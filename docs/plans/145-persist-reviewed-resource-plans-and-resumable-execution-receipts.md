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
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T04:04:49Z
      mode: "update"
      note: "Interface amended after pre-implementation API validation under MasterPlan 23"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-22T04:32:10Z
      mode: "implement"
      note: "Implement conditional inventory store, review admission, and recovery protocol"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-22T14:34:28Z
      mode: "implement"
      note: "Pass retained native evidence into post-execution verification"
---

# Persist reviewed resource plans and resumable execution receipts

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

An operator can retain a reviewed resource change, apply exactly that change, and resume after interruption without blindly repeating completed work. Two commands cannot concurrently overwrite context intent. Persisted evidence survives payload replacement and can be backed up and restored without manufacturing ownership from names.

This plan delivers the provider-independent planner, store, executor protocol, and CLI plumbing with deterministic fake adapters. Real cloud, host, cluster, and application adapters are delivered by other children.


## Progress

- [x] (2026-09-22) M1: Persist independent scope revisions, immutable snapshots, and context identity.
- [x] (2026-09-22) M2: Bind reviewed plans to observations, native bundles, and operation dependencies.
- [x] (2026-09-22) M3: Journal execution, recover interruptions, and enforce writer exclusion.
- [x] (2026-09-22) M4: Expose plan/apply/resume/export and prove crash/recovery behavior.


## Surprises & Discoveries

2026-09-22: The in-memory backend needs separate MVars for object state, conditional-write serialization, and the process lock. Reusing one guard deadlocked the conformance suite before an adapter ran. The separation also makes the store contract explicit: conditional object mutation and executor exclusion are different capabilities.

2026-09-22: Operator-facing review directories cannot carry retained native plans. They now contain only the canonical review document, checksum, and public scope declarations; apply uses that document digest to retrieve the issued native evidence from the private store and verifies that the public scopes are byte-identical. The deterministic manifest-only adapter can therefore produce review fixtures without exposing or authorizing a production mutation.

2026-09-22: The filesystem lock file is not a store member. The first CLI export attempted to read its own locked handle and failed with `resource busy`; object enumeration now excludes the lock and unpublished atomic-write temporaries. A filesystem export/restore test guards this boundary and also exposed an `Either` value being mistaken for the returned key list in the empty-store check.

2026-09-22: A fresh child process is necessary to test the kernel lock. A fork inherits enough process state to make the result platform-dependent. The suite launches the test executable in probe modes, proves concurrent refusal, terminates a lock-holding process, and then proves immediate reacquisition.

2026-09-22: The original verification callback received only the common operation. That forced receipt-backed adapters to reconstruct mutable native inputs after execution, so a clean-process resume could verify different evidence from the retained review. Verification now receives the same immutable `PreparedNative` bytes as preflight, execution, and recovery. Provider access may still be needed to observe current state, but the reviewed native plan is never regenerated to prove completion.


## Decision Log

2026-09-16: Preserve successful native Pulumi receipts and their offline resume property. Generic reconciliation must not turn provider access into a prerequisite for skipping already-proven work.

2026-09-16: Start with a private filesystem store and one context-wide writer. Storage is behind an interface; remote multi-writer operation is unsupported until it has a shared lock and compare-and-swap implementation.

2026-09-16: Persist accepted desired revisions before execution, and converged revisions only after verification. A failure exposes pending desired state and partial observations without pretending the old deployment is still fully active.

2026-09-16: Specify the store as conditional writes and test the protocol against a store that has nothing else. The filesystem remains the only shipped implementation, but correctness must not depend on rename or flock, because ADR 13 already moved the comparable Pulumi state off the workstation and this store will hold deletion authority.

2026-09-16: Distinguish ReviewedPlan from a lock-scoped ExecutablePlan. The earlier text named both and defined neither, and a value verified against a snapshot read outside the lock cannot by itself authorize effects.

2026-09-16: Add prepareReview and an adapter prepare method. The earlier interface had a pure planner and a verifier of finished bundles, with no step that could run a native preview to produce the evidence a review must bind.

2026-09-16: One planner takes opaque LifecycleDecisions, and observationRequirements states what must be observed. Separate lifecycle planners could not express a mixed adopt-and-update change, and unspecified coverage would force either full-context observation on every application deploy or guessing.

2026-09-16: Return refusals as Left and every admitted outcome as a TransactionResult that names its transaction. Failed and ambiguous transactions are durable state to resume, not errors to discard.

2026-09-22: Pass retained native bytes to adapter verification. Post-effect verification must decode and bind the exact reviewed preparation, not call preparation again against mutable configuration or provider state.

2026-09-16: Lock with base's GHC.IO.Handle.Lock and forbid adapter children from re-entering inventory commands. unix's setLock is an fcntl record lock that is lost on any close of the file and not inherited; re-entry under a held lock deadlocks the transaction against itself.

2026-09-22: Keep native evidence exclusively in the private store. The directory handed to an operator is a redacted review projection, and apply hydrates it only from the immutable review previously published by the selected context store. Rationale: a review must bind exact native bytes without turning saved provider plans or private paths into public evidence.

2026-09-22: Ship a manifest-only CLI planner until the real adapters arrive in EP-146 and EP-147. It creates deterministic, inspectable review evidence and its preflight always refuses, so the new generic commands are testable without pretending that provider execution exists.


## Outcomes & Retrospective

Completed on 2026-09-22. The implementation adds the conditional filesystem and in-memory stores, canonical digest-linked journals, pure planner and observation coverage, private native preparation, opaque ReviewedPlan and lock-scoped ExecutablePlan boundaries, admission/recovery, and the plan/apply/resume/export command surface. The negative fixture proves an ExecutablePlan cannot escape its lock scope. Eleven focused transaction tests cover backend conformance, convergence, safe retry, proof-based ambiguous recovery without duplicate effects, stale-review refusal before preflight, redacted public reviews, adapter re-entry, verified backup/restore refusal, journal gaps, cross-process exclusion, and lock release on process death.

The full acceptance pass reports 591 nagarectl tests and 424 nagare-dsl tests, the Haskell style scan, Fourmolu check, and the negative type fixture passing. CLI acceptance compiled the inventory fixture, emitted review digest `5ffb4e7f61f889d9822db57f85258506b048cf84783f736ee96ab06cd13958c9`, refused manifest-only apply at preflight, and exported the complete private store without including its lock file. No provider mutation was enabled.

The filesystem backup is a private checksummed recovery artifact with restrictive modes, not a defense against an actor able to rewrite the store. Its destination is responsible for transport/at-rest encryption; EP-151 supplies the context state bucket and its provider-side encryption. Real observation, native preparation, and execution remain the responsibility of EP-146 and EP-147, and lifecycle decisions remain EP-149's responsibility.


## Context and Orientation

Hard dependency: [the typed inventory foundation](144-define-typed-resource-scopes-and-validate-composed-inventories.md). It supplies opaque ValidatedInventory and CompositionCandidate, context/scope/resource identities, per-scope canonical serialization, typed references, declared operations, and complete selected-scope replacement. A candidate carries the desired inventory together with its base generation vector and explicit changes, and composeInventory is the only way to obtain one: this plan loads a compiled directory by verifying member digests, decoding each scope, and composing again. A scope revision vector names the version of every owner declaration; changing an application does not change platform intent.

cli/nagarectl/src/Nagare/Platform/Upgrade.hs currently executes a fixed phase list through UpgradeOps. Platform/PulumiReceipt.hs privately stores started/succeeded/failed/operator-attested evidence bound to the transaction and retained native plan. Infra/Plan.hs protects saved Pulumi plans. Platform/Workspace.hs materializes immutable release assets; the new store must not live inside those workspaces. Platform/Replacement.hs and Cutover.hs already model intent/completion checkpoints and irreversible write admission; their specific recovery rules remain intact.

[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates payloads and mutable context state. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) makes context version the final upgrade commit and requires truthful partial progress. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds reviews and receipts and refuses ambiguous Pulumi starts. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) excludes private runtime state from Git. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) defines the new protocol.

Create modules under cli/nagarectl/src/Nagare/Inventory: Store.hs, Plan.hs, Journal.hs, Execute.hs, Adapter.hs, and extend Command.hs. This plan alone owns those interfaces, the context state format, and the generic inventory command parser in app/Main.hs. Provider plans add adapter implementations, not parallel journal formats.


## Plan of Work

### M1 — Durable scope state

Store private state below the existing context XDG state root in inventory/, outside platform workspaces. Allocate a stable ContextId in an explicit local initialization transaction; display-name changes preserve it, while an intentional context clone allocates a new identity. Bind it to provider target identities and the existing named context; never infer identity from a name or silently reuse copied state against another target.

Persist immutable scope declarations/revisions, composed inventory snapshots, observations, review bundles, operation events, and a small atomic head manifest. Distinguish accepted desired, last converged, retained resources, and an active transaction. The resource catalogue retains historical ownership and tombstones even when a scope is retired. Keep redacted public exports separate from private native provider bundles. Private files/directories use restrictive modes and verified paths; generated evidence rejects symlink substitution, while existing operator-owned context symlinks retain their established write-through behavior.

Implement same-directory temporary writes, explicit flush/fsync ordering appropriate to the supported platforms, and atomic rename. Journal events are immutable sequence-numbered files linked by previous digest; verify sequence and member digests during load. Recovery ignores unpublished staging files and refuses missing/reordered committed events. Atomic rename alone is not a power-loss durability guarantee: fault tests must cover publication boundaries.

Express every store operation as a conditional write: publish immutable content only if absent, append a journal event only at an unused sequence number, and replace the head manifest only if its generation still matches. Correctness, including mutual exclusion between transactions, must follow from those primitives and the head's active-transaction reservation alone. The OS lock then only stops two local processes from executing the same transaction, and a later object-store implementation needs no protocol change, because GCS offers the same preconditions through generation matching, in the same kind of bucket where tan-nb-exp already keeps its Pulumi state. Prove it by running the transaction suite against a second, in-memory store that implements only those conditional semantics, with no rename and no lock. This matters beyond tidiness. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) promises that a new machine needs two clones and credentials. A store whose protocol quietly depended on POSIX rename and flock would make deletion authority, and after EP-148 every application deploy, permanently local to one workstation.

A scope revision is the pair of EP-144's ScopeGeneration and the digest this package computes over the scope's canonical bytes. Compare-and-swap checks that pair for every selected scope and the head sequence, so applying content A, then B, then A again cannot revive a review written against the first A. Digests identify content and revisions identify history. Never fold a revision into a desired digest or into provider metadata, or an unchanged rerun stops being a no-op.

Use an OS-held context lock whose release follows process death, plus the head compare-and-swap. Do not implement a stale PID-file guess. Take the lock with `GHC.IO.Handle.Lock.hTryLock` from base, which GHC 9.10.3 exposes and which uses flock or open-file-description locks that the kernel releases when the process dies. Do not use `System.Posix.IO.setLock` from unix: those are fcntl record locks, which a process loses as soon as it closes any descriptor for the file and which a child does not inherit. No new dependency is needed. Hold the mutation lock through external effects. A read-only plan captures the base revision; apply checks it again under lock. An unresolved transaction reserves its scopes/claims and blocks a conflicting new apply; supply those reservations, with retained and candidate incarnations, as the reserved claims of EP-144's ScopeSnapshot.

Record an executor claim in the head when a transaction is admitted: the transaction, a store client identity generated once per state root, an epoch, and the time. Install it with the same head replacement that activates the transaction and release it when the executor stops for any reason. With the filesystem store a leftover claim from this client is provably dead once the process lock has been acquired, and is cleared. [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) implements this same store contract over the context's state bucket and relies on the claim to refuse a second machine, so the field belongs to the head format from the start rather than being added later.

Adapters run scripts and native tools while the lock is held. None of them may re-enter a command that takes the context lock, or the child blocks on its own parent. Export the transaction identity to adapter children and make every inventory-entering command refuse when it is set. The retained wrappers that EP-146 and EP-147 route through the checked command path are entry points for operators, never callees of an adapter.

### M2 — Reviewed operation plans

The planner compares a CompositionCandidate, prior accepted/converged state, and typed observations. Build an explicit operation graph with stable OperationId, covered ResourceIds, executor identity/version, input digests, preconditions, readiness conditions, native bundle references, and recovery contract. Resource dependencies and executor grouping are different: one Pulumi update may cover many resources, and one resource may require several migration operations. EP-144's declared operations enter this graph with the identities they were declared with. A scope that history knows and the candidate's inventory lacks must be matched by a retirement in the candidate's changes; otherwise refuse.

Observations are partial by nature, so make coverage explicit. An ObservationSet maps a ResourceId to present, confirmed absent with its evidence, or unavailable with a reason; a resource missing from the map was not observed, which never means absent. observationRequirements derives, from the candidate and history, exactly which resources a plan needs observed: the selected scopes' resources, the readiness conditions they depend on, and the holders of any claim they touch. planChanges refuses when that coverage is incomplete. Without this function the command layer must either observe the whole context, which would make every application deploy require cloud and Pulumi credentials, or guess.

There is one planner. Adoption, migration, retirement, and collection arrive as LifecycleDecisions, an opaque value that EP-149 constructs by checking a proposal against the same candidate, history, and observations. This plan exports only noLifecycleDecisions, so convergent changes plan without EP-149, while anything that would need a decision refuses rather than defaulting to ordinary update. Separate planners per lifecycle action cannot express the first adoption of an existing installation, where one scope replacement adopts most resources and updates a few, and they would let a proposal restate an owner, digest, or policy that the declaration already fixes.

planChanges is pure and cannot run a native tool, yet review must bind native evidence. prepareReview closes that gap: for each operation it calls the adapter's prepare method, which produces and retains the native bundle (a saved Pulumi plan, the expanded Helm and manifest objects, an evaluated system closure) and checks that the bundle touches only the operation's declared resources. Its result is the ReviewBundle, or a review barrier where a bundle cannot exist until a prerequisite does. The plan command is compile, observe, planChanges, prepareReview, then publish the bundle into the store by digest so that apply can tell an issued review from an edited directory.

Only a reviewed plan bound to context identity, provider target, scope revision vector, payload identity, policy version, candidate digest, and native evidence can become executable. Review includes retained resources and adoption/replacement/deletion decisions.

An unresolved output is allowed only in its declared position and type. If native planning cannot be completed before a prerequisite is created, represent a review barrier. Review and execute the bounded preparation transaction, then require a newly reviewed resolved native plan before dependent mutation. Do not silently replace evidence in a previously approved bundle. Secret values are fetched privately by adapters at execution; secret version references are bound without exposing plaintext.

Wire decoding creates an untrusted plan. Verification checks all members, versions, bindings, base revisions, and authorizations before returning an opaque ReviewedPlan. Do not export constructors, FromJSON instances, Generic reconstruction, or setters that bypass verification.

ReviewedPlan and ExecutablePlan are different evidence. verifyReview is pure over a StoreSnapshot read outside the lock, so a ReviewedPlan only says the bundle was issued by this store and matched that snapshot; the head may have moved since. ExecutablePlan is the authority to cause effects. Only admit creates one, under the process lock, after re-checking the head sequence, every selected scope's revision, reservations, and the adapters' live preconditions. Index it by the lock's scope type, as in `withProcessLock :: InventoryStore -> (forall s. LockedStore s -> IO a) -> IO (Either StoreError a)`, so the value cannot leave the lock that justified it. Keep withProcessLock a top-level function: a higher-rank record field cannot be used as a selector or through a generic-lens label.

### M3 — Execution and recovery

Separate refusal from outcome in the result type. A refusal means nothing was admitted: no intent was journaled and no effect occurred, so it is the Left of apply and resume. Everything after admission is a TransactionResult that always names its TransactionId: converged, paused at a review barrier, stopped on a failure with its class, or stopped ambiguous. A stopped transaction is durable state the operator must resume or resolve, not an exception; returning it as a bare error would lose the identifier the next command needs.

Define explicit pending, intent-recorded, completed, failed, ambiguous, and operator-resolved states. Persist operation intent before its first effect and observed completion afterward. Distinguish a known no-effect failure from partial/unknown effects; a nonzero exit does not prove no mutation. Recovery asks the adapter for proof of completion, safe retry against the identical review, or an unresolved outcome requiring a reviewed operator decision.

Separate completion evidence from fresh health. A verified Pulumi receipt can skip the cloud operation without credentials/tool/provider access, while later dependent actions check the live conditions they actually require. Later health failure does not authorize rerunning a completed data migration. A complete transaction is a no-op. If the base inputs change, create a new review; do not edit the old transaction into a different request.

Commit accepted scope revisions atomically with transaction activation. After successful verification, advance the converged head. Preserve the special platform sequence of cluster completion marker followed by context version commit for the final integration child. For operational actions such as restart or backup, journal the operation against the existing scope revision without inventing a new desired configuration.

Back up the complete store under lock, including journal, declarations, retained identities, and private evidence, with encryption appropriate to existing operator practice. Restore verifies all members and target bindings into staging before installation, refuses an active writer, and re-observes before future mutation. Lost history is a recovery state; labels cannot recreate deletion authority. A checksummed store is not a signature or defense against someone able to rewrite all of it.

### M4 — Commands and deterministic verification

Extend inventory compile to load the stored base scope snapshot, including the reserved claims. Add `inventory plan --inventory DIRECTORY --out DIRECTORY`, where the input is a compiled candidate directory that is verified and composed again rather than trusted, `inventory apply DIRECTORY --yes`, `inventory resume TRANSACTION --yes`, and `inventory export --out DIRECTORY`. Global context selection remains authoritative. Commands display exact selected scopes and reviewed digest. Apply refuses an unreviewed/changed bundle even with --yes; that flag acknowledges the displayed bound decision and does not bypass policy.

Create InventoryTransactionSpec.hs with injected clocks, file operations/failure points, and recording adapters. A three-component fixture simulates cloud, host, and cluster. Interrupt at each persistence/effect boundary; prove proven operations are skipped, ambiguous operations stop, and the final context commit cannot occur early. Run two actual local processes against one temporary store to test lock exclusion, not just an in-memory flag.


## Concrete Steps

Run from the repository root using its development environment as necessary. The fixture and commands below are delivered here; no provider credentials are needed.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
(cd cli/nagarectl && cabal run nagarectl -- inventory plan --inventory test/fixtures/inventory/compiled --out /tmp/nagare-review-145)
bash scripts/check-haskell-style.sh
```

Use a temporary XDG configuration/state directory in tests. The plan command records zero provider mutations, lists selected scopes and operation IDs, and produces a digest-bound review; its only write is publishing that review into the private store by digest. Apply/resume behavior is exercised by recording adapters inside the Haskell suite; do not expose fake execution as a production CLI backend.


## Validation and Acceptance

Exercise changed base revision, changed provider target, edited inventory/native bundle, a candidate directory with a scope file removed and no retirement, a review bundle that was never published into the store, content re-applied after an intervening revision (A, B, A) against a review of the first A, incomplete observation coverage, an adapter child that re-enters an inventory command, unknown schema, unredacted secret, interrupted journal/head publication, process death, concurrent writer, and incomplete restored backup. Each refuses before a new external effect. A successful receipt with a lost final journal event repairs progress only when bindings verify. A started receipt without authoritative completion remains ambiguous. A failed phase cannot advance the converged head. An unchanged completed transaction records no provider calls.

The whole transaction suite passes against both the filesystem store and the in-memory conditional-write store. A failed or ambiguous apply returns a result naming its transaction, and `inventory resume` accepts that identifier. An ExecutablePlan cannot be returned out of the lock scope; keep that as a negative compile fixture beside EP-144's.

Retained histories and receipts survive removal of a payload workspace. Exported public review contains no secret fields, sensitive native payloads, command stderr dumps, or private paths; the encrypted recovery backup is a separate artifact.


## Idempotence and Recovery

Never rewrite reviewed bundles or successful receipts in place. Resume reads the exact original review and current journal. A stale review requires a new plan. Recovery never deletes provider objects or abandons ownership history. Support read-only inspection of old upgrade schemas; generic conversion of old success text into new proof is forbidden. EP-150 owns the legacy transaction integration.


## Interfaces and Dependencies

Nagare.Inventory.Adapter owns a closed, versioned adapter registry with pure declaration/plan validation and injected IO methods for observe, prepare, preflight, execute, verify, and recover. prepare produces the retained native bundle during planning; preflight re-checks live preconditions under the lock. Adapters declare all ResourceIds their operations can affect. Execute never accepts an arbitrary shell string.

```haskell
observationRequirements
  :: CompositionCandidate -> InventoryHistory -> ObservationRequirements

planChanges
  :: CompositionCandidate -> LifecycleDecisions -> InventoryHistory -> ObservationSet
  -> Either (NonEmpty PlanError) ChangeProposal

noLifecycleDecisions :: LifecycleDecisions

prepareReview
  :: AdapterRegistry -> StoreSnapshot -> ChangeProposal
  -> IO (Either (NonEmpty PrepareError) ReviewBundle)

verifyReview
  :: StoreSnapshot -> ReviewBundle
  -> Either (NonEmpty ReviewError) ReviewedPlan

withProcessLock
  :: InventoryStore -> (forall s. LockedStore s -> IO a) -> IO (Either StoreError a)

admit
  :: LockedStore s -> AdapterRegistry -> ReviewedPlan
  -> IO (Either (NonEmpty AdmissionError) (ExecutablePlan s))

execute
  :: LockedStore s -> AdapterRegistry -> ExecutablePlan s -> IO TransactionResult

applyReviewed
  :: InventoryStore -> AdapterRegistry -> ReviewedPlan
  -> IO (Either (NonEmpty AdmissionError) TransactionResult)

resumeTransaction
  :: InventoryStore -> AdapterRegistry -> TransactionId
  -> IO (Either (NonEmpty AdmissionError) TransactionResult)

data TransactionResult
  = Converged TransactionId
  | PausedAtBarrier TransactionId (NonEmpty ReviewBarrier)
  | StoppedFailed TransactionId OperationId FailureClass
  | StoppedAmbiguous TransactionId OperationId
```

applyReviewed is withProcessLock around admit and execute. These signatures were type-checked as stubs together with EP-144's and EP-149's under GHC 9.10.3 on 2026-09-16.

Define InventoryStore as monomorphic conditional-write operations: consistent read, publish-if-absent, append-at-sequence, replace-head-if-generation-matches, and acquire/release of the process lock, plus verified export/restore built from them. Plan and Journal wire versions are independent of platform semantic version. Use existing aeson, crypton, bytestring, containers, directory, unix, time, base's GHC.IO.Handle.Lock, and test infrastructure; locate library APIs through Mori before implementation. crypton is already a nagarectl dependency (Nagare.Infra.Plan hashes with Crypto.Hash SHA256), and the one digest module this plan shares with EP-144's compile command should follow that precedent.


## Revision Notes

2026-09-16: Added the executor claim to the head manifest and named EP-151 as the object-store implementation of this plan's store contract, after the operator decided to add a shared store as the eighth child. The claim costs nothing locally and is what lets a second machine be refused without a protocol change.

2026-09-16: Revised before implementation after an API validation pass requested by the operator; the interface was type-checked as stubs under GHC 9.10.3 alongside EP-144 and EP-149. Changes: the planner consumes EP-144's CompositionCandidate and refuses an omitted scope without a retirement; observation coverage and observationRequirements are explicit; one planner takes LifecycleDecisions; prepareReview and an adapter prepare method produce native evidence; ExecutablePlan is lock-scoped and distinct from ReviewedPlan; results separate refusal from durable transaction outcomes; a scope revision is generation plus digest with a head-sequence check; the store is specified as conditional writes and tested against an in-memory implementation; locking uses base's GHC.IO.Handle.Lock with a no-re-entry rule. The reasons are recorded in the Decision Log; in short, the earlier interface could not produce a review bundle, could not tell a stale proof from a current one, and tied correctness to one workstation's filesystem.
