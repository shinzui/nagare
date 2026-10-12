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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-23T17:24:05Z
      mode: "implement"
      note: "Begin accepted-inventory status and drift classification"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T17:51:23Z
      mode: "implement"
      note: "Record current model contribution to accepted inventory status and shared store progress"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T20:05:12Z
      mode: "implement"
      note: "Implement reviewed adoption and scoped transfer checks"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T21:56:54Z
      mode: "implement"
      note: "Expose sanitized journal recovery state in read-only inventory status"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T23:54:30Z
      mode: "implement"
      note: "Align collection screening with proved Kubernetes delete transport"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T01:53:10Z
      mode: "implement"
      note: "Classify immutable Kubernetes Deployment selector changes"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T02:30:20Z
      mode: "implement"
      note: "Report UID-bound retained Kubernetes health separately from drift"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T04:46:40Z
      mode: "implement"
      note: "Classify immutable StatefulSet identity changes"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T13:22:43Z
      mode: "implement"
      note: "Keep executor-change observations single-valued before migration review"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T18:03:32Z
      mode: "implement"
      note: "Extend exact reviewed collection to stateless Services and CronJobs with disposable proof"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T20:36:19Z
      mode: "implement"
      note: "F37: execute-time no-effect abandonment (d9aed800), reviewed field takeover (1df735a6); C2 adoption/drift/storage notes"
---

# Explain drift and execute reviewed adoption migration and retirement

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.

Full plan before trimming: [149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Operators can ask what owns a resource, why it exists, whether it drifted, and why Nagare will or will not change it. Existing installations enter inventory management through explicit adoption. Renames and owner transfers preserve identity and durable data, while cleanup can delete only historically owned resources whose exact current incarnation and policy permit it.

This plan delivers provider-independent lifecycle planning plus inventory status/explain commands. It verifies semantics using recording adapters. Final real-provider coverage comes from the adapter children and EP-150.

## Progress

- [x] (2026-09-23) M1 partial: Read-only snapshot composition reconstructs accepted effective contributions through the same closed validator as changed plans. A typed drift classifier distinguishes converged, configuration drift, confirmed absence, foreign ownership, and unknown/unavailable observation without examining private native bytes. A focused six-case fixture and the full 701-test CLI suite pass. Real provider observation, history/retirement categories, status/explain commands, and lifecycle decisions remain open.
- [x] (2026-09-23) M1 partial: `inventory status --json` and `inventory explain RESOURCE_ID --json` now reconstruct the accepted scope vector and native evidence from immutable private reviews, call the registered provider observe functions without applying changes, and report provider identity, partial coverage, drift, consumers, policy, and active transaction. A missing store or workspace is not initialized by status. On the disposable full bootstrap, all 205 resources across 17 accepted/converged scopes report converged, with no missing provider; the 702-test CLI suite passes. Historical retained incarnations, separate health, and lifecycle/recovery details remain open.
- [x] (2026-09-23) M2/M3 guard: A lifecycle decision now binds its observation, incarnation, resource, and context through a canonical digest; adoption requires a new desired declaration and present nonforeign observation. Migration decisions refuse until they have an operation/recovery contract. Retention and collection decisions currently refuse because the head has no durable retained-incarnation catalogue or deletion tombstones. `ApproveRetirement` no longer plans a delete. The 724-test CLI suite passes. Adoption transport, retained history, and lifecycle commands remain open.
- [x] (2026-09-23) M1/M2 partial: Kubernetes observation now distinguishes an unstamped object from one stamped for another logical resource. Status reports `unowned` separately from `foreign-owner`; planning refuses an accepted object whose ownership stamp disappears and requires a reviewed adoption decision for a newly declared unowned object. A focused adapter fixture and the 724-test CLI suite pass. The adapter's conditional adoption write and CLI proposal flow remain open.
- [x] (2026-09-23) M2 partial: The Kubernetes adapter prepares stamp-only adoption for an unstamped object whose desired fields already match. Its runtime applies the three reserved annotations with one JSON Patch that tests UID and resourceVersion, preserving unrelated fields. A disposable k3d ConfigMap was adopted and verified through the registered adapter, and 726 CLI tests pass. Versioned proposal input, mixed-resource command flow, and other-provider adoption remain open.
- [x] (2026-09-23) M2/M4 partial: `inventory adopt --input FILE --out DIRECTORY` accepts a strict version 1 proposal naming a compiled candidate, exact context binding, provider addresses, and observed physical identities. It observes the complete candidate, validates selected unowned incarnations into opaque decisions, and publishes a normal review that can mix adoption with ordinary changes. Pure decision/DTO fixtures and the 728-test CLI suite pass; the command help and a separate disposable adapter adoption pass. A full command-path disposable adoption, provider transfers, retention, and migration remain open.
- [x] (2026-09-23) M2/M4 disposable command proof: An isolated local inventory state root against the disposable k3d context compiled a one-resource candidate, reviewed an unowned ConfigMap by its observed UID through `inventory adopt`, and applied the single `AdoptResource` operation. Status reported one accepted, converged resource and no active transaction. The exact UID and data survived annotation stamping; the fixture was then removed by exact name after checking its UID. Provider transfer and retained-resource lifecycle remain open.
- [x] (2026-09-23) M2 guard: Moving an accepted ResourceId from one scope to another now refuses with `owner-transfer-required` instead of becoming an ordinary update. A two-scope candidate fixture and the 729-test CLI suite pass. Explicit transfer proof and execution remain open.
- [x] (2026-09-23) M2 partial: A proposal resource can name `previousOwner` to request transfer of an already stamped ResourceId. Validation requires the prior owner in accepted history, both old and new scopes selected, a changed declared owner, the exact current physical observation, and unchanged desired native content. The planner emits an incarnation-bound `VerifyResource` operation. The 729-test CLI suite passes; a full command-path transfer and provider-specific capability checks remain open.
- [x] (2026-09-23) M2/M4 disposable transfer proof: An isolated local inventory state root compiled the old scope, created a stamped ConfigMap, then reviewed a two-scope handoff through `inventory adopt` using its exact UID. The review contained one `VerifyResource` and no update. Admission exposed a head decoder invariant that rejected an old converged scope during an active handoff; the decoder now allows that intermediate state only while a transaction is active. `inventory resume` converged the destination scope with the same UID, data, and ResourceId; the exact disposable ConfigMap was removed after verification. Other-provider transfers and retained-resource lifecycle remain open.
- [x] (2026-09-23) M2 transfer contract: Validation now limits the proved transfer route to Kubernetes resources with unchanged address, native specification, aliases, lifecycle, data/sensitivity policy, delegation, and dependency set. A changed native digest refuses rather than being smuggled into a `VerifyResource` handoff. Other provider transfers remain unavailable until their own incarnation and ownership preconditions are proved.
- [x] (2026-09-23) M1 partial: Status findings now expose health separately from configuration drift. An observed matching specification reports health `unknown`, while confirmed absence reports `unavailable`; the CLI does not equate `converged` configuration with workload readiness. The 137 focused inventory tests pass. Provider-specific condition probes remain open.
- [x] (2026-09-23) M1 read consistency: Status and explain reread the accepted head after provider observations and refuse if another transaction changed it during the report. The CLI executable builds.
- [x] (2026-09-23) M1 recovery visibility: Status and explain now validate the committed journal for an active transaction and report each operation's latest sanitized state, with a separate recovery-required flag. Journal detail and provider errors stay private; a final head reread rejects a concurrent change. Eleven focused status tests, the 734-test CLI suite, the CLI executable build, and Haskell style checks pass. Retained history and provider-specific health probes remain open.
- [x] (2026-09-23) M2 ownership proof: The generic lifecycle validator and planner now refuse an already stamped object when accepted history has no ownership record. Only a fresh unowned incarnation enters the current adoption route. Five focused adoption tests, the 734-test CLI suite, and Haskell style checks pass; other-provider adoption remains open.
- [x] (2026-09-23) M1 dependency explanation: `inventory explain` now walks transitive dependencies in the composed declaration graph and reports each prerequisite's resource ID, owner scope, source declaration, and depth. A two-hop fixture, the 735-test CLI suite, executable build, and Haskell style checks pass. Retained history, provider-specific health, and lifecycle/recovery interpretation remain open.
- [x] (2026-09-23) M3/M4 partial: `inventory retire --scope KIND:NAME --out DIRECTORY` now builds a reviewed `RetainResources` scope removal. The review binds each disappearing direct Kubernetes resource to its accepted scope revision and observed UID. Admission reobserves the UID under the writer lock, records the retained incarnation in the head, and preserves its address claims for later composition. Status and explain expose the retained catalogue with unknown live observation. A recording adapter proves retirement, address reservation, refusal of silent reactivation, refusal of a forged reservation-free candidate, and refusal after UID replacement. The 736-test CLI suite, 443-test DSL suite, and Haskell style check pass. Collection, migration, provider-specific retained health, and generic recovery remain open.
- [x] (2026-09-23) M1/M3 partial: Read-only status now reconstructs retained Kubernetes native observation inputs from the original immutable accepted review and classifies the historical UID as present, drifted, replaced, absent, unowned, foreign-owned, or unavailable. Retained providers contribute to coverage reporting; an unknown observation does not authorize collection. The focused retirement fixture passes; collection decision and tombstone remain open.
- [x] (2026-09-23) M3 guard: A scope with disappearing observed controller children now refuses at both planning and admission. Retaining the parent alone cannot erase a child's derived address claim or physical identity; the focused controller-child fixture and Haskell style check pass. Retained child history remains a separate required contract before those scopes can retire.
- [x] (2026-09-23) M1/M3 native evidence: A Kubernetes recording-adapter transaction now creates, reviews, retires, and reloads one resource, proving that the original immutable review still supplies its native observation input after the active scope disappears. The retirement performs no additional provider mutation. The new focused test passes after the 737-test CLI regression suite.
- [x] (2026-09-23) M1 partial: Explain now includes consumers from both active and retained declarations, and traces a retained resource's own prerequisites to their historical owner and source. A two-resource retirement fixture proves the dependency remains visible after both active declarations leave the accepted scope vector. Focused retirement and dependency tests pass; collection still needs its complete dependency and recovery gates.
- [x] (2026-09-23) M3/M4 partial: `inventory gc --plan --out DIRECTORY` now writes a read-only collection assessment for retained resources, screening policy, durable data, active and retained consumers, exact present UID, and active transactions. Every report explicitly says deletion is unauthorized; a candidate is only eligible to enter a future reviewed collection protocol. The retained-dependent fixture proves a consumer blocker. Deletion execution and tombstones remain open.
- [x] (2026-09-23) M3/M4 narrow collection route: `CollectRetained` is a versioned candidate change requiring an authoritative retained claim. `inventory collect --resource RESOURCE_ID --out DIRECTORY` reviews an exact historical UID and immutable owner revision for a stateless namespaced ConfigMap with `DeleteWhenUnreferenced` and no known consumers. Admission rechecks the current UID/resourceVersion; the native DELETE carries both server-side preconditions and orphan propagation. Confirmed absence moves the retained entry to a review-bound tombstone; resume is idempotent and logical-ID reuse refuses. Recording-adapter create/retire/collect and disposable native ConfigMap collection pass. A separate disposable raw API probe returned Conflict for stale UID and stale resourceVersion, then deleted the exact incarnation. Broader kinds, durable recovery, and migration remain open.
- [x] (2026-09-24) M3 collection extension: Retained stateless namespaced Services and CronJobs now share the exact UID/resourceVersion-bound DELETE and tombstone route. A focused disposable cluster test creates, verifies, rejects a stale preflight after a concurrent annotation, conditionally collects, and confirms absence for both kinds. StatefulSet and durable data collection remain closed.
- [x] (2026-09-24) M3 collection review accepts multiple distinct retained resource IDs in one candidate and one immutable review. Existing per-resource lifecycle decisions, provider preconditions, and tombstones apply independently; a focused composition fixture proves duplicate IDs refuse before planning.
- [x] (2026-09-23) M4 partial: `inventory recover TRANSACTION --operation OPERATION --decision FILE` accepts a strict version 1 decision bound to the transaction, operation, and immutable review. Under the writer lock it asks the issued adapter to prove completion or safe retry before appending an audited journal state; unresolved and contrary proofs refuse. A focused recording-adapter fixture proves completion without replay, rejects a contrary retry decision and duplicate recovery, and checks strict DTO decoding. Migration and provider-specific forward recovery remain open.
- [x] (2026-09-23) M1 partial: Read-only status probes Kubernetes Job, CRD, cert-manager, Knative Service, and Deployment conditions independently of configuration drift. It accepts a condition only when the second read has the same UID as the inventory observation, and otherwise leaves health unknown. A pure kind-selection fixture and the CLI executable build pass. Other provider health remains open.
- [x] (2026-09-23) M2 compatibility: Legacy `platform adopt` now says explicitly in text and JSON that it pins the platform release without adopting any provider object into inventory. The upgrade runbook links the per-resource exact-incarnation adoption review. The legacy status and marker flow remains intact.
- [x] (2026-09-23) M3 collection screening: Read-only `gc --plan`, lifecycle validation, and conditional Kubernetes deletion now share one supported-kind predicate. Unsupported resources carry `unsupported-collection-transport` rather than appearing collectible, and cannot enter a reviewed collection plan. The 150 focused inventory tests and Haskell style check pass; durable-data and other-provider collection remain open.
- [x] (2026-09-24) M1 partial: Status includes the read-only collection assessments for retained objects, while retained explain exposes historical aliases, required conditions, delegation, policies, and declaration source alongside dependency traces. The CLI executable builds. Immutable replacement classification, unmanaged discovery, and broader provider health remain open.
- [x] (2026-09-24) M1 replacement boundary: Typed observations now distinguish an immutable replacement requirement from ordinary drift. Status reports its physical identity and digest; the generic planner refuses `UpdateResource` with `replacement-review-required`. Retained observation also reports the condition without permitting collection. The 150 focused inventory tests pass. Production adapters still need provider-specific immutable-change classification, and reviewed replacement/migration execution remains open.
- [x] (2026-09-24) M1 Kubernetes immutable classification: The production observer recognizes a changed explicit `apps/v1` Deployment selector and reports replacement required for its stamped ResourceId. Unowned and foreign objects retain their ownership categories, and the existing generic planner refuses an ordinary update. Eleven focused Deployment tests and Haskell style checks pass. Other immutable fields, unhealthy Deployment observation, and reviewed migration remain open.
- [x] (2026-09-24) M1 retained health: Status and explain now probe supported retained Kubernetes conditions only for the historically retained UID and report health separately from configuration observation. Confirmed absence reports unavailable health; matching configuration alone remains unknown until a condition probe succeeds. A focused fixture proves that a replacement UID and confirmed absence cannot enter the retained condition probe. The CLI executable builds and the focused retirement tests pass. Other provider health remains open.
- [x] (2026-09-24) M2 Helm scope transfer: An unchanged stamped Helm release can move between two explicitly selected scopes through the existing reviewed `VerifyResource` handoff. The lifecycle validator requires equal executor, address, native spec, aliases, policies, delegations, and dependencies. A fixture proves an unreviewed transfer refuses, a reviewed transfer plans verification without mutation, a changed native contract refuses, and a changed release revision fails adapter preflight. The focused Helm tests pass. Other provider transfers remain unavailable.
- [x] (2026-09-24) M3 migration guard: Ordinary planning now refuses an accepted ResourceId whose provider address or executor changes with `migration-review-required` before classifying the new observation as create or update. A fixture covers both confirmed absence and a present stamp at the destination. The focused inventory test passes. The dual-incarnation migration graph and execution protocol remain open.
- [x] (2026-09-24) M1 StatefulSet immutable classification: The production Kubernetes observer reports replacement required when explicit selector, service name, volume claim templates, or pod management policy differ. Volume claim templates compare desired fields to avoid defaulted observed metadata causing a false finding. The focused test and Haskell style check pass; reviewed replacement and broader immutable coverage remain open.
- [x] (2026-09-24) M1 condition separation: An existing Kubernetes object with an unready controller condition now retains its configuration and ownership observation. A distinct internal state prevents execution verification from treating it as complete, while read-only status can report not-ready health. A focused Job fixture, the 154-test inventory suite, and Haskell style check pass.
- [x] (2026-09-24) M1 StatefulSet health: Status now probes the observed StatefulSet UID and requires a current controller generation plus the requested ready and updated replica counts. Mutation waits for rollout before verification; an unready observation retains configuration facts but cannot complete the operation. The 155-test inventory suite and Haskell style check pass; other provider health remains open.
- [x] (2026-09-24) M2 decision replay boundary: Validated lifecycle decisions now carry their exact composed candidate and accepted history. The planner revalidates them against current history and observations; mixing decisions from different contexts or deciding twice for one resource refuses. Two disjoint adoption decisions combine into one review. Focused fixtures and the 752-test CLI suite pass. Provider adoption breadth and migration remain open.
- [x] (2026-09-24) M1 Helm ownership and health: A pending stamped Helm release now preserves its physical and owner observation rather than becoming foreign-owned. Malformed status is unavailable; a missing or mismatched stamp is foreign. The adapter refuses verification until deployment completes. Active and retained status use a second read of the exact revision Secret UID to report ready or not-ready independently from drift. Parser/adapter fixtures, the 753-test CLI suite, executable build, and Haskell style check pass.
- [x] (2026-09-24) M3 migration observation discovery: `observationRequirements` now exposes each accepted logical resource whose executor or address changes as an old/new `ManagedResource` pair. A rename fixture proves the source and destination declarations stay distinct while ordinary planning still refuses migration. Separate dual-incarnation observation, review, execution, and recovery remain open.
- [x] (2026-09-24) M3 Helm retention: `inventory retire` now keeps a stamped Helm release under its original scope revision and physical release Secret UID without a Helm mutation. Planning and apply reconstruct retained native evidence; admission refuses a changed UID. The recording fixture, full 751-test CLI suite, executable build, and style check pass. Controller-child history, durable data migration, and broader collection remain open.
- [x] (2026-09-24) M1: Read-only status and explain classify active and retained resources, separate controller health from configuration, expose partial provider coverage and recovery state, and bound findings by observation start/end times. The full 750-test CLI suite and executable build pass. Kinds without a proved condition probe report health `unknown`; unmanaged discovery remains an optional read-only extension.
- [x] (2026-09-24) M3 migration guard: Ordinary observation requests now select the desired executor once for each logical ID, while `migrationIncarnations` retains the historical source and desired destination declarations separately. An executor-change fixture proves that the old executor is not queried through the single-valued observation map and planning returns `migration-review-required`. All 753 CLI tests and Haskell style checks pass. Dual-incarnation observation and reviewed migration execution remain open.
- [x] (2026-09-24) M3 dual-observation foundation: `observationRequirements` now exposes source-executor requests separately from ordinary desired-executor requests. `observeMigrationIncarnations` accepts separate source and destination adapter registries and requires complete, exact coverage for both before producing a paired observation per ResourceId. A Kubernetes-to-Helm recording fixture proves the same ID carries distinct source-present and destination-absent facts; the 754-test CLI suite passes. Production source registry construction, proposal validation, reviewed operation graphs, and retained migration history remain open.
- [x] (2026-09-24) M3 proposal validation: A strict version 1 migration input now names the compiled candidate, context binding, source and destination addresses, source physical identity, destination absence proof, and a stateless or durable recovery contract. `validateMigrationInput` requires the old accepted declaration, changed composed destination, matching owner/data policy, and exact paired facts; duplicate targets and mismatches refuse. A new migration fixture covers valid binding, altered UID/absence, wrong contract and owner, and malformed durable input. All 756 CLI tests pass. It is validation only; operation review and execution are still open.
- [x] (2026-09-24) M3/M4 provider-independent migration: Opaque decisions now revalidate both observations and emit a reviewed eight-stage graph with explicit recovery classes. The immutable review binds the old owner/revision/UID/address, destination address/absence, and data contract. Admission rechecks immutable scope coverage, and the head retains the old incarnation with a canonical review marker while accepting the destination; the history decoder permits only a disjoint, review-proved overlap. A recording adapter converges and resumes after an ambiguous result at each of the eight stages without replay. `inventory migrate --input FILE --out DIRECTORY` is wired to separate source and destination observations, and status loads their native evidence independently. All 758 CLI tests, executable build, and Haskell style checks pass. Production adapters still refuse migration preparation or execution; live data and cutover verification remain open.
- [x] (2026-09-24) M3 migration safety follow-up: A retained source sharing an active logical ID now carries an `active-incarnation` collection blocker. The recording fixture checks that screening and rejects a tampered head that removes the canonical migration review marker. The proposal command also refuses a migration stage backed only by the manifest-only adapter. All 758 CLI tests pass; production stage contracts remain open.
- [x] (2026-09-24) M3 mixed-change ordering: Ordinary updates to declared consumers of a migrating ResourceId now depend on destination verification, and the migration's `SwitchConsumers` stage waits for those updates. A two-resource fixture checks both graph edges; the full CLI suite passes. Provider-specific cutover remains the adapter's responsibility.
- [x] (2026-09-24) M3 recording data proof: A stage-aware recording adapter now tracks source data, a backup copy, writer fence, destination transfer, consumer switch, and write admission. The run converges only when each stage sees its required predecessor state; the final assertions show source, backup, and destination data all remain equal. The full 761-test CLI suite passes. This is a generic protocol fixture, not a provider backup or schema validation claim.
- [x] (2026-09-24) M4 command-path proof: An isolated local inventory store and compiled candidate exercise `planInventoryMigrationWith` through versioned input, separate source/destination recording observers, normal review publication, and immutable reload. The documented migration DTO decodes. Cache adoption, database Service rename, and application retirement examples are present. All 762 CLI tests pass.
- [x] (2026-09-24) Final validation: All 762 nagarectl tests, the CLI executable build, and Haskell style checks pass. `inventory status --json` against the currently selected default context exits with `StoreConditionFailed "inventory store is not initialized"`, the expected read-only refusal for an uninitialized store; the isolated status and lifecycle fixtures cover populated history.
- [x] (2026-09-24) M2: Explicit versioned adoption, Kubernetes/Helm unchanged owner transfer, and the legacy platform-version adoption boundary are implemented and documented. Unsupported provider imports continue to refuse during native preparation.
- [x] (2026-09-24) M3: Provider-independent migration, retained history, conservative collection, and recovery contracts are implemented with recording proofs. Exact stateless namespaced ConfigMap collection is the only production delete route; durable, controller-child, and migrated-source collection remain refused until their provider and incarnation-specific contracts are available.
- [x] (2026-09-24) M4: Lifecycle proposal/status/recovery commands and decision, execution, interruption, tamper, and command-path fixtures are delivered. Production migration stages remain assigned to adapter-specific work and EP-150, as stated in this plan's purpose.

## Surprises & Discoveries

The platform workspace resolver materialized an immutable payload copy, so status needed a separate existing-workspace lookup to keep its read-only contract. Provider observation errors may include command output; status collapses these to a generic unavailable reason and names the missing provider scope.

The first live scope transfer had a valid intermediate head with the new accepted owner and the old converged owner. The head decoder's blanket subset check refused this state after admission, before journal append. The decoder now permits the mismatch only with an active transaction; the existing durable transaction resumed and converged without recreating the ConfigMap.

The command-level adoption DTO already required an unowned observation, but the generic validator still accepted a stamped present or drifted object without accepted history. Direct validator callers could have produced an adoption decision without the stronger DTO check. The validator and planner now share the same conservative boundary.

Removing a scope also removes its active declaration from the accepted vector. A retained entry therefore stores the immutable old scope revision, not just a UID, so later status and claim validation can reconstruct the declaration even after the scope disappears. A review alone is insufficient: admission reobserves each retained UID under the writer lock before advancing the head.

The head wire format could encode an accepted resource and one retained incarnation under the same logical ID, but `loadInventoryHistory` rejected that overlap. The observation set and adapter registry also select one provider object per ResourceId. The migration implementation therefore uses separate source and destination observation registries, a review marker on the retained entry, and a disjoint-claim check before the history decoder accepts the pair. A direct `UpdateResource` would not prove destination creation or preserve the source claim.

The read-only collection assessment and lifecycle validator previously checked lifecycle, data, consumers, identity, and transaction state but omitted the executor's supported kind. They could label or review a Service even though conditional deletion permits only a namespaced ConfigMap. A shared support predicate now gates screening, validation, and adapter preparation.

The ordinary planner classified an accepted ResourceId solely from the observation at its new desired address. If that address was absent, a stateless resource could become a `CreateResource`; if a stamped object was present, it could become an `UpdateResource`. Neither operation retained or verified the old address. Address and executor changes now refuse before that classification.

An opaque lifecycle decision could be passed to `planChanges` with a later candidate, accepted history, or observation. Revalidating its proposal detects observation changes; carrying the original composition candidate and history also detects declaration and authority changes that preserve the observation. Disjoint decisions can now be combined only when both were validated for the same context.

The Helm runtime parsed deployment status before reading the Nagare owner stamp. A pending release therefore became `foreign-owner` even when the stamp was valid. Parsing the stamp first retains its ownership and physical identity, while adapter preparation still requires a deployed release. Malformed status responses also need an unavailable category separate from a readable foreign stamp.

When a known logical resource changed executor, `observationRequirements` requested the same ResourceId from both old and new adapters. `observeWithRegistry` then rejected the duplicate before the planner could emit its migration-review refusal. The ordinary observation map can represent only one incarnation per ResourceId; source observation needs a separate, explicitly bound channel.

After a migration, read-only status had the same single-valued problem: merging source and destination facts under one ResourceId could misclassify both or reject duplicate observations. Native evidence and observations now stay separate for active and retained incarnations. A retained migration source is screened from collection while that logical ID remains active.

The initial migration operation map associated a migrating ResourceId with its final `RetainSource` stage. Ordinary dependent updates would then run after source retention, while the graph's `SwitchConsumers` stage had no edge to wait for them. The graph now exposes destination verification as the dependency target and makes the switch wait for those updates.

A conditional Service DELETE can return success while the object is still visible with a deletion timestamp. Immediate final verification treated this as an unresolved collection. The native transport now waits up to 30 seconds for the address to disappear; final adapter verification still rejects a replacement incarnation. The disposable Service and CronJob test also forces resourceVersion churn between preparation and preflight and proves refusal before collection.

## Decision Log

2026-09-16: Historical ownership plus current physical identity is required for collection. A label, name prefix, missing declaration, or matching content is insufficient.

2026-09-16: A migration is a graph of operations with explicit recovery/commit points. Reversing ordinary create order is not a migration or a safe rollback strategy.

2026-09-16: Status is a timestamped observation, never a hidden repair operation. Inaccessible and missing must remain distinct, including after a partial upgrade.

2026-09-16: Validate proposals into opaque LifecycleDecisions for EP-145's single planner instead of exposing planAdoption, planMigration, and planRetirement. The earlier planners took no inventory, so a proposal restated owner, digest, and policy beside the declaration; retirement intent existed both here and in EP-144; and a change that adopts some resources while updating others had no expression.

2026-09-23: Do not allow a reviewed RetainResources scope removal to erase the last accepted resource declaration before retained-incarnation history exists. A retirement approval is not deletion authority. Collection also needs exact historical identity and a deletion tombstone; the validator refuses these paths until the catalogue is implemented.

2026-09-23: Expose the versioned adoption DTO/validator module for package tests while keeping `LifecycleDecisions` opaque. Only the validator constructs a non-empty decision through `validateLifecycleDecisions`; the public command accepts proposal data, not proof objects.

2026-09-23: A provider ownership stamp without accepted history is insufficient for adoption. Require an unowned observation for the currently supported route and refuse stamped objects until a separate history recovery protocol proves them. This keeps direct calls to the generic validator within the same authority rule as the operator proposal command.

2026-09-23: RetainResources retirement records each disappeared managed Kubernetes incarnation in the head with old scope revision, owner, UID, and retention time. Its claims remain reserved. The first route is limited to directly declared Kubernetes resources with a proved observation path; disappearing generated members or other executors fail closed. No provider delete occurs during retirement. Collection remains a separate reviewed and tombstoned transaction.

2026-09-23: An operator recovery file selects only an action for one uncertain issued operation; the registered adapter supplies the current completion or safe-retry proof. An unresolved adapter result cannot be overridden by the file, and the normal journaled resume remains the convergence step.

2026-09-23: Kubernetes health remains a separate read-only observation using the runtime's existing readiness predicates. A second read must match the first observation's UID before its condition can be attached to a status finding.

2026-09-24: An adapter-proved immutable replacement requirement is a separate observation, and the generic planner refuses to turn it into an ordinary update. Rationale: drift alone does not say whether mutation in place is possible, and replacement requires its own review and recovery contract. No production adapter emits this outcome yet.

2026-09-24: Extend the scope transfer verification route to Helm releases whose existing adapter proves the stamped context/ResourceId, release revision, and unchanged reviewed native contract. Keep the same two-scope and contract equality requirements as Kubernetes. This is a verification handoff, not a Helm upgrade.

2026-09-24: Treat a known ResourceId's provider address or executor change as requiring a reviewed migration even when the destination is absent or appears already owned. An ordinary create or update observes only one incarnation and cannot prove retention or cutover of the source.

2026-09-24: For ordinary planning, observe the desired incarnation of a known ID exactly once and keep the old/new declaration pair in `migrationIncarnations`. This preserves the fail-closed migration refusal for executor changes without treating a duplicate observation as a provider error. A later migration protocol must observe both incarnations independently and bind both facts into its review.

2026-09-24: Keep migration source and destination observations in separate adapter registries and combine them only after exact coverage checks. The existing ordinary ObservationSet and adapter registry remain single-valued by ResourceId; changing their meaning would make ordinary create/update and ownership classification ambiguous.

2026-09-24: Migration proposal files name addresses and observed identities but do not restate the desired specification or owner. The composed candidate and accepted immutable scope supply those facts. Durable proposals must name backup, compatibility, fence, and recovery evidence identifiers; the adapter must verify the evidence before review and execution.

2026-09-24: Permit an active destination and retained source with one logical ID only when a canonical immutable migration review proves the old revision, physical identity, both addresses, and disjoint address claims. Keep their native observation inputs separate. The generic migration graph is executable by an adapter that proves its stages; existing production adapters refuse until their stage-specific backup, fence, cutover, and recovery behavior is implemented. Recording evidence alone is not production authority.

2026-09-24: In a mixed migration review, a dependent resource update belongs between destination verification and the consumer switch stage. Bind it with operation dependencies so cutover cannot pass before declared consumer updates complete; provider-specific switch verification remains mandatory inside the adapter.

2026-09-24: Treat the existing `DeleteWhenUnreferenced` stateless policy as having no minimum hold time; the domain policy has no retention-age field. `Retain` and `Protect` do not authorize collection, and every durable or age-sensitive case stays retained until a typed policy and provider evidence can express its release condition. This avoids inventing a hidden duration in the command layer.

## Outcomes & Retrospective

M1-M4 are complete for this plan's provider-independent scope. Status and explain report accepted and retained identity, drift, provider coverage, health, dependency traces, collection screening, and active recovery state without mutation. Versioned lifecycle proposals feed one planner; a reviewed migration binds two incarnations and an ordered graph, preserves source data in a recording model, and recovers at every interruption boundary. The production lifecycle routes proved here are Kubernetes adoption, Kubernetes/Helm unchanged scope transfer and direct retention, exact stateless ConfigMap collection, and adapter-proved operator recovery. Production migration stages, other-provider imports, durable/age-sensitive collection, controller-child retention, and migrated-source collection refuse until adapter-specific or later typed-policy work supplies their evidence. The final real-provider inventory coverage belongs to the adapter children and EP-150.

