---
id: 232
slug: record-successful-application-deployments-as-lifecycle-events
title: "Record successful application deployments as lifecycle events"
kind: exec-plan
created_at: 2026-10-31T14:21:30Z
intention: "intention_01m695aak2e4ebx7gw1pcvphvr"
master_plan: "docs/masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-31T14:21:30Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-31T14:34:39Z
      mode: "other"
      note: "Completed initial planning draft and checked source commit, control history, dependencies, recovery and validation interfaces."
---

# Record successful application deployments as lifecycle events


## Purpose / Big Picture


After a changed production release successfully deploys, an operator or event consumer can identify the exact application, service or site release from one `app.deployed` event. A failed rollout, an accepted review that has not converged, a dry run, or a verification-only rerun must never announce a deployment. Resuming after interruption produces the same logical event without redeploying the workload.


## Progress


- [ ] M1: A changed multi-workload application's verified final convergence yields one correctly identified deployment event; stopped and no-op transactions yield none.
- [ ] M2: Standalone service and production site deployment/rollback entry points use the same producer, with restart and compatibility coverage.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-31: Emit one event per changed production release subject, not per Kubernetes write or workload. Required rollout readiness and atomic final convergence establish success.

2026-10-31: Reuse the shared executor source-fact boundary. Commands, static publishers and deployment adapters do not send HTTP requests or append public events themselves.


## Outcomes & Retrospective


(To be filled during implementation and at completion.)


## Context and Orientation


A release subject is the logical application, standalone service or production site being deployed. A release identity describes exact deployment content rather than a mutable image tag. Convergence means the reviewed operations and their required verification completed and the inventory committed the resulting scopes. It does not promise future availability.

`cli/nagarectl/src/Nagare/Inventory/Application.hs` exposes application compilation. `cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` composes workloads; `Application/Release.hs` owns immutable release-history members and accepted application/standalone release log access. Site compilation is in `cli/nagarectl/src/Nagare/Inventory/Site.hs`. User commands live in `cli/nagarectl/app/Nagare/Cli/Commands/Application.hs`, `Deployment.hs`, `Site.hs` and `SitePublish.hs`. Those command handlers are entry points, not independent lifecycle authorities. Read `docs/user/deploying-apps.md` and [ADR 32](../adr/0032-static-publication-is-a-local-package-then-two-reviewed-stages.md) to distinguish image publication, configuration and actual site deployment before wiring site events. ADR 32 makes local packaging, reviewed image publication and reviewed serving deployment separate stages; only the final stage is eligible here.

The executor in `cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs` records journal completion before its final converged head write. `Execute/Claims.hs`, `releaseClaimWith`, establishes the final boundary. EP-231 supplies a typed source fact linked atomically from that final write and materializes it into a separate feed. Its complete accepted implementation is a hard prerequisite: `docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md`. Do not substitute parsing journal text or inspecting only the current head after the fact.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) retains reviewed scope ownership, recovery and the distinction between deployment meaning and diagnostic provenance. [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) requires recorded incarnation identity. [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) governs module boundaries. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires interrupted and uncertain outcomes in offline worlds. No existing ADR defines deployment notifications; record new durable semantics in EP-231's lifecycle ADR during implementation.


## Plan of Work


### M1 — One application release through the real executor


Add `cli/nagarectl/src/Nagare/Lifecycle/Deployment.hs` as the typed producer. Compute a candidate from the exact reviewed prior/desired application release member and required completion evidence. Carry the semantic subject and immutable release identity through the existing review/execution model with explicit codec/version handling where needed; do not add a command-name heuristic. Use the shared source-commit hook supplied by EP-231. The public payload contains subject kind, scope/logical identity, namespace, new and previous release identity, exact scope revision, transaction/review identifiers and the readiness proof reference. Omit private config, native bytes and generated environment values. A URL is optional descriptive metadata only.

Emit after all workloads and pre-deploy hooks required by that subject's reviewed deployment pass. A transaction changing two application subjects yields two distinct facts; one application with multiple workloads yields one. No event is emitted for a partial application rollout, operator close, admission alone, pre-deploy hook failure or unresolved provider outcome. Preserve existing supported recovery paths. A later successful resume of the original transaction produces the original source identity.

Compare deployment meaning and the previous successful release, not timestamps, appended diagnostic history, a release-stamp refresh or source provenance alone. A reviewed verification-only operation creates no deployment event. If a stopped transaction already accepted the desired revision, a later transaction that actually establishes its first successful deployment must still produce a deployment event; accepted equals desired is insufficient to suppress it. Test this against the real application recovery worlds before adding other producers. Event identity includes the converging transaction and subject so a later distinct rollback/redeployment is distinguishable from retrying the same transaction.

### M2 — Supported production entry points and rollback


Reuse the producer for reviewed standalone service deployments and both supported production site runtimes. Image build/upload or a static site's artifact publication alone is not `app.deployed`. A production site becomes deployed only at its reviewed activation and required serving verification. A rollback to a different prior release emits `app.deployed` with action `rollback` when that action is known from reviewed intent; ordinary forward deploys use `deploy`. A mere re-verification of the same successful release emits nothing. Do not infer rollback intent by comparing tag spelling.

Keep preview scopes outside v1 event coverage and explicitly test their exclusion. Platform transitions, adoption/import of historical release logs, image publication, restart, scale, stop/start and environmental provenance refresh must not masquerade as a production deployment. If an entry point lacks durable intent sufficient to classify it, extend its reviewed typed metadata and compatibility tests; do not weaken the guarantee or silently omit a supported production path.

Register new test modules and source modules through their owning Cabal manifests and suite assembler. Extend a focused event sample and user-facing event documentation without rewriting historical plans or claiming native proof. Require source/feed event bytes to survive collection of old release Kubernetes resources because the event contains the committed immutable evidence it needs.


## Concrete Steps


Work from the repository root, after EP-231 is Complete. Use Mori to locate any dependency API/documentation before changing its use; verify released versions before selecting bounds. No new package is selected here.

```bash
python3 scripts/check-haskell-architecture.py
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /Lifecycle.Deployment/' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /application inventory compilation/' --test-show-details=direct
```

Add the nonempty test group `Lifecycle.Deployment`, using the real application compiler, planner, executor, source store and materializer. The second command selects the existing group in `cli/nagarectl/test/InventoryApplicationSpec.hs`; both commands must select actual tests rather than succeed with zero cases.

In the disposable fixture context established by those tests, the new public read command is:

```bash
cabal run nagarectl --project-dir=cli/nagarectl -- events list --type app.deployed --first 50 --contract 1
```

Expected behavior: one matching event for the changed release, naming its exact subject and review; repeating source collection returns the same ID and does not increment the count. The fixture harness must print its isolated context configuration rather than using the active operator installation.


## Validation and Acceptance


Use actual planner/executor recovery tests, not only handcrafted candidate values. Exercise application create/update, multi-workload readiness, hook failure, partial provider write, lost acknowledgment of the final inventory update, process death before/after source commitment, newer transactions before materialization, same-release verification, provenance-only change, prior accepted-but-unconverged state and successful resume. The observed feed contains precisely the successful changed production releases and stable IDs after every replay.

Then demonstrate a standalone service and a static/server site through their public reviewed workflow code, plus a rollback, with no producer-specific storage or sender logic. A same-tag image with changed immutable content must be distinguished according to the reviewed release identity; a tag change that preserves identical deployment meaning is covered by the explicit no-op policy. CLI/API decode the event with EP-231's DTOs. Assert that events contain no secrets or full native payloads. EP-235 owns live cluster confirmation; this child is accepted from offline executable workflows.


## Idempotence and Recovery


The shared source/feed protocol supplies persistence and deduplication. Repeated materialization never creates another event, and repeated apply/resume never repeats a proved deployment effect to recover notification state. Do not delete old source facts after Kubernetes release-history collection. Preserve old persisted review decoding or require the explicit versioned transition established by EP-231; do not invent events for pre-activation history. A disabled worker leaves committed facts available for catch-up.


## Interfaces and Dependencies


Hard dependency: all of `docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md`, including its validated source candidate and final-head integration. This child owns the deployment producer, typed reviewed deployment intent needed by it, and subject/action semantics. It consumes shared IDs, event DTOs and materialization unchanged. It supplies real deployment fixtures to `docs/plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md` as a soft integration input and is a hard prerequisite of `docs/plans/235-run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery.md`. It does not own backup validation, receiver transport or the inventory commit protocol.
