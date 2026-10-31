---
id: 235
slug: run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery
title: "Run the lifecycle event service and prove restart and upgrade recovery"
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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-31T15:01:10Z
      mode: "update"
      note: "Require transport-neutral delivery, isolated destination progress and a second-adapter proof for future Kafka publication; record ADR 33."
---

# Run the lifecycle event service and prove restart and upgrade recovery


## Purpose / Big Picture


A context can run lifecycle event collection and webhook delivery continuously with explicit credentials, persistent state and useful health reporting. Operators can upgrade or restart the service without losing notifications or repeating deployments/backups. This child confirms the complete deployment-to-event-to-receiver path and a scheduled backup notification that requires no CLI ingestion.


## Progress


- [ ] M1: A packaged Haskell worker runs bounded source materialization, receipt collection and delivery loops against filesystem and object-store configurations with correct capability separation.
- [ ] M2: Reviewed context enable/disable, deployment, read-only API access, secret delivery and persistent state survive upgrade and documented recovery.
- [ ] M3: Gated offline coverage and disposable native deployment/backup/receiver drills prove catch-up, duplicate handling, credential isolation and latency reporting.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-31: Install one context-local worker without another messaging engine or inventory reconciler. The service receives no apply/resume/close authority and uses bounded independent queues so receipt verification cannot starve delivery.

2026-10-31: Preserve the existing read-only admin credential. New lifecycle history is a separately authorized read prefix; backup/provider observation belongs only to the worker.


## Outcomes & Retrospective


(To be filled during implementation and at completion.)


## Context and Orientation


A worker is a long-running process that repeatedly reads committed source facts, checks backup receipts and sends due notifications. It does not reconcile desired infrastructure. A capability is a narrowly scoped set of operations/credentials; it must be impossible for receipt collection to call inventory mutation just because both libraries exist in the same repository.

This child requires completion of `docs/plans/232-record-successful-application-deployments-as-lifecycle-events.md`, `docs/plans/233-observe-verified-database-backups-and-publish-lifecycle-events.md` and `docs/plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md`, which in turn depend on the core feed. Deployment, backup verification and HTTP delivery must already be proven offline. The worker calls their facades and does not reimplement policy. [ADR 33](../adr/0033-lifecycle-delivery-separates-destination-state-from-transport-adapters.md) requires transport registration at this runtime boundary, a shared delivery engine and destination-local progress; production Kafka publication remains future work.

`cli/nagare-api-server/src/Nagare/Api/Server/App.hs` and `Serve.hs` define admin service wiring. `cluster/bootstrap/admin-api/admin-api-local.yaml.tmpl` and `admin-api-cloud.yaml.tmpl` show existing local/GCS service deployment conventions. `cli/nagarectl/src/Nagare/Inventory/Store/Service.hs` supplies read-only service-store access. `nix/nagare-packages.nix`, `nix/packages.nix`, `flake.nix` and the CLI Cabal project control packaging; inspect their current structure before adding the new executable. The managed-command audit is `scripts/audit-managed-commands.py` and the architecture gate is `scripts/check-haskell-architecture.py`. `docs/runbooks/before-a-native-run.md` defines native-run preconditions.

[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) governs operator secret delivery and state. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) retains explicit inventory authority and bounded service reads. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires offline fault coverage and gated native confirmation. [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) requires exact identities. [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md) retains a single node with hourly recovery points and a four-hour rebuild objective; adding this process does not introduce high availability.


## Plan of Work


### M1 — Package a bounded worker


Add `cli/nagare-events/nagare-events.cabal` and `cli/nagare-events/app/Main.hs` with only process setup, typed options and loop supervision. Keep shared execution in the already-owned `Nagare.Lifecycle` facades, and add focused worker-private modules as needed. Register the package in the Cabal project and Nix package outputs. Use existing Mori-discovered Haskell/HTTP/storage dependencies rather than assuming APIs; verify authoritative registry versions and tags before selecting bounds.

Run independent bounded loops for inventory source materialization, backup collection and transport-neutral due delivery. Construct the adapter registry at process setup and register only the production webhook adapter initially. Source/materialization loops and domain producers must not dispatch on transport type. Unknown/unsupported persisted transport versions pause only affected destinations with a diagnostic; never reinterpret them as webhook configuration or acknowledge their work. Defaults come from the child interfaces: 30-second receipt polling, four receipt verifications, four sends and one in-flight request per subscription, all within explicit memory/byte/work budgets. Preserve fair destination queues, isolated checkpoints and scoped transport credentials; one stalled destination cannot exhaust all shared execution slots. Future Kafka registration adds its own typed configuration, capability and policy without changing the event feed or wrapping a Kafka producer as an HTTP receiver. Supply cancellation and graceful shutdown; finish or persist unresolved attempt state before exit within a bounded shutdown period. Honor store binding and supported schema before processing anything. Never acquire an inventory executor claim. Default to one replica, but conditional-write tests must tolerate accidental overlap and a restarted old process; sending duplicates is allowed, losing acknowledged state is not.

Expose internal liveness and readiness endpoints. Readiness requires valid context/schema/credential binding and writable notification state; an individual unavailable receiver is reported as delivery health, not a liveness failure causing restart loops. Log structured redacted IDs/outcomes and expose source lag, last successful receipt scan, oldest pending candidate, pending/due/exhausted deliveries, last delivery success, publication durations and notification storage consumption, labeled by destination ID and transport rather than requiring a URL or HTTP response for every delivery. Expose webhook-specific response metrics through its adapter only. No generic observability platform is introduced.

### M2 — Install and recover in each supported storage mode


Add reviewed enable/disable configuration and a platform-owned worker scope/template under `cluster/bootstrap/lifecycle-events/`. Use a bounded Kubernetes Deployment with resource requests/limits, a non-root read-only runtime, appropriate NetworkPolicy and no public control endpoint. Preserve candidate/rehearsal side-effect suppression: outbound delivery defaults off there and can only target the explicit drill receiver when enabled for proof. Disabling the worker retains source/feed/delivery state and ordinary backup production.

Cloud installation explicitly binds the authoritative inventory prefix, backup bucket and lifecycle state prefix. Supply separate service capabilities: inventory/source/history reads, exact backup object reads plus receipt authentication, event/delivery writes, and named signing-Secret reads. The worker cannot mutate inventory heads, reviews, backup archives or backup receipts, and cannot create Kubernetes Jobs or change application resources. API credentials gain read permission only to public lifecycle and sanitized delivery/config projections; they gain no worker writer credential or backup signing key. Use prefix/condition restrictions in the existing provider IAM mechanisms and explicit denied-operation tests; do not rely on a comment that a broad bucket role will be used carefully.

Local contexts use distinct persistent mounts/directories for read-only inventory input and writable lifecycle state. Make the inventory source store actually available to the in-cluster reader: for a workstation-only store, require an explicit supported mount or existing migration before enablement. Do not silently create a second inventory, copy mutable state or substitute a new empty store. Document the local signing/backup access path with the same least-authority behavior. The installed filesystem/object-store topology must match the topology used in native tests.

Include lifecycle state in context export/transfer/rebuild and the declared recovery objectives. V1 retains source facts, events, delivery audit and due-work indexes without automatic pruning; report disk/object growth, with a documented reviewed future retention path rather than silent TTL deletion. A restore of older notification state can resend an already-received event, always under the same stable event ID; the receiver deduplicates. Preserve event context identity/epoch across a normal restart or upgrade. Cross-context copy refuses. Document event schema compatibility, old-writer refusal, restart recovery, pause, replay, key rotation, store corruption and a failed format transition. Any new authoritative store must have an actual backup/restore procedure, not only deployment manifests.

Extend managed-command inventory/architecture registration and user/capability documentation to describe exactly the implemented scope. Update or create lifecycle architecture records when installation changes durable authority. Finish the ADR distillation pass across all children before marking the initiative complete.

### M3 — Confirm the complete path


First run worker supervision, credential-denial, capability and packaging tests locally through faultable interpreters. Exercise the runtime dispatcher with the HTTP adapter and EP-234's test-only non-HTTP recording adapter, proving separate progress and fair budgets across restart, blocking adapter calls and failed acknowledgment persistence. This is offline capability proof only; do not install the recording transport or a Kafka broker in native contexts. Add a harness scenario owned by the existing Haskell harness, rather than a new parallel shell orchestrator. It provisions only disposable fixture workloads and records candidate revision, context/store bindings, source event IDs, receiver acknowledgments and restore outcomes.

After the candidate's normal gates are green and the selected disposable environment is authorized under the native-run runbook, install the packaged worker and receiver. Run one reviewed production-style application release and observe its exact `app.deployed` event/POST; repeat a no-op review and confirm no new deployment event. Let one reviewed PostgreSQL schedule complete without running receipt-ingestion commands, then observe `database.backup.completed`; separately ingest its receipt and observe `database.backup.accepted`. Existing child tests cover the other engines and app-database variants; use available fidelity fixtures and add native variants only where they resolve an unmodeled provider interaction.

Stop the worker before a second deployment/backup completes, restart it and verify catch-up with stable IDs. Make the receiver return 500 and later recover; verify retry state and that an unrelated deployment still converges. Drop an acknowledgment after receiver processing and demonstrate duplicate delivery with one deduplicated downstream effect. Restart/upgrade the worker and API while queued work exists; no feed cursor, subscription boundary or pending event disappears. Restore notification state into a disposable recovery environment and prove replay uses the original event ID and never invokes deployment/backup production. Confirm read-only API and worker credentials fail forbidden writes.

Measure deployment-convergence-to-publication, receipt-availability-to-verification, verification-to-publication and publication-to-first-attempt separately. Under an idle fixture, source materialization and send scheduling each occur within two 30-second cycles; backup verification time is measured separately rather than hidden in a false fixed latency promise. Record backlog, object/byte counts and memory bounds. Keep concise evidence under `docs/audits/mp31-lifecycle-events/`, redact keys and credentials, and document cleanup of only the disposable reviewed resources.


## Concrete Steps


Run from the repository root. Existing gates include:

```bash
python3 scripts/check-haskell-architecture.py
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /Lifecycle/' --test-show-details=direct
cabal test nagare-api-server-test --project-dir=cli/nagarectl --test-show-details=direct
just api-hurl
```

After adding the package, establish these executable checks and wire them into the normal gate:

```bash
cabal build exe:nagare-events --project-dir=cli/nagarectl
cabal test nagare-events-test --project-dir=cli/nagarectl --test-show-details=direct
cabal run nagare-events --project-dir=cli/nagarectl -- --help
```

Expected result: nonempty passing worker tests, a reproducibly packaged executable, and help naming explicit context, inventory/event store bindings, budgets and delivery enablement. The implementation adds exact harness scenario/run commands here once registered with the existing harness; no native command is prescribed against an assumed live context. Use `just gate-fast` and the runbook-required full revision gate before native confirmation. Gate success is not claimed by this planning document.


## Validation and Acceptance


A disposable native context shows a real deployment and an unattended scheduled backup arriving at the same documented receiver, with separate completion/acceptance semantics. Catch-up, uncertain acknowledgment, receiver outage, queued upgrade and notification-state restore all preserve stable IDs and recoverable state. No observed retry starts an application rollout, backup or receipt ingestion. Local and cloud credential tests deny inventory and backup mutations; the API cannot obtain signing values or send requests. Local filesystem persistence and cloud conditional persistence both pass their offline recovery suite, and each installed topology has matching native evidence before being advertised as supported.

The service runs within declared resources, cancels work on shutdown, reports collector failures independently from receiver failures and remains useful after one subscription exhausts retries. Existing application/backup operations continue with the worker disabled or unavailable. Runtime extension acceptance requires that the same dispatcher handles the test-only non-HTTP adapter without changes to source/feed or producer modules, and that its failure/restart does not move or stall webhook progress. Production manifests register only webhooks and advertise no Kafka implementation. Documentation distinguishes accepted proof from remaining limitations and records that the single-node outage/recovery objective is unchanged. This child and the MasterPlan remain In Progress until every required mode and recovery gate above is accepted.


## Idempotence and Recovery


Enable/disable and service upgrades use ordinary reviewed scopes. Restarts resume from durable source, collection, subscription and delivery checkpoints, not empty defaults. Unknown request outcomes may redeliver an event with the same ID. Never erase the feed, change context identity or reset all delivery cursors to repair an install. Refuse incompatible downgrade/schema and retain failed transition evidence. A stale or corrupt store stops affected processing with diagnostics while leaving deployment and backups operational. Use only the documented reviewed recovery path for authoritative inventory; notification recovery must not acquire that authority.


Revision 2026-10-31: register transports only at runtime wiring, require isolated destination progress and fair budgets, and integrate the offline second-adapter proof without expanding deployed Kafka scope.


## Interfaces and Dependencies


Hard dependencies are the complete children at `docs/plans/232-record-successful-application-deployments-as-lifecycle-events.md`, `docs/plans/233-observe-verified-database-backups-and-publish-lifecycle-events.md` and `docs/plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md`. EP-231's source/feed contract is inherited transitively. This child owns executable supervision, credentials/IAM/mount integration, deployment packaging, persistence/backup recovery, status wiring and native harness proof. It consumes producer, collector and sender behavior through their public facades. If integration reveals a missing invariant, update the owning child's plan/code and the MasterPlan instead of duplicating its policy in the executable.
