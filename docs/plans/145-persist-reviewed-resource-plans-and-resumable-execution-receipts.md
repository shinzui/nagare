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

Full plan before trimming: [145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

