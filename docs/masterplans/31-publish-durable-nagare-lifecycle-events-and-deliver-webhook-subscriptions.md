---
id: 31
slug: publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions
title: "Publish durable Nagare lifecycle events and deliver webhook subscriptions"
kind: master-plan
created_at: 2026-10-31T14:21:24Z
intention: "intention_01m695aak2e4ebx7gw1pcvphvr"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-31T14:21:24Z
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
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:35:44Z
      mode: "update"
      note: "Applied the 2026-11-04 review: convergence journal event instead of a second chain, Nagare.Events modules, /v1/events inspection routes, nagare-events in the nagare-api-server package and image, in-process receipt discovery with a five-minute default, request budget."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:35:44Z
      verdict: "changes-requested"
      note: "Architecture, API and cost review against the code: reuse the journal as the source chain, transport-neutral inspection routes, second executable in the existing service image, in-process receipt discovery, page and polling defaults, Nagare.Events namespace."
---

# Publish durable Nagare lifecycle events and deliver webhook subscriptions


## Vision & Scope


An operator can ask what Nagare deployed and which database backups completed, read the same durable event history through the CLI or protected admin API, and later register receiver URLs to receive signed HTTP POST requests. A receiver can be unavailable while deployment and backup operations continue. Delivery resumes after a worker restart, and an operator can inspect failures and replay an event without repeating its original operation.

The first event types are `app.deployed`, `database.backup.completed`, and `database.backup.accepted`. A deployment event means a changed production application, standalone service, or site release passed the readiness required by its reviewed deployment and committed convergence. It is historical evidence, not a promise of continuing health. A completed backup means its archive and authenticated receipt were verified at exact provider versions. Acceptance is a separate event meaning a reviewed transaction admitted that backup as a recovery point. Notification never grants restore or prune authority.

The first stage delivers event history and producers. The second delivers transport-neutral subscription/delivery machinery, webhooks as the first production transport adapter, and a context-local background service. A transport adapter converts a delivery request into one external publication attempt and returns a typed outcome; it does not own lifecycle event production. Kafka publication must be addable later without changing deployment/backup producers, source facts, event identity or the feed format. Included are manual and scheduled managed-database backups and app-database backups, stable identities, versioned payloads, resumable collection, durable delivery attempts, signature rotation, and recovery documentation. New event types can be added through typed producers with explicit guarantees. Failure/start/delete/restore events, application-volume events, preview deployment events, incoming automation triggers, a UI, SSE/WebSocket streaming, exactly-once delivery, a production Kafka adapter, broker provisioning, and multi-node availability are outside this initiative. Preserving the Kafka extension boundary and testing it with a second test-only adapter are required now. Existing inbound Git provider webhooks stay separate.

Creation of this plan authorizes planning only; no runtime or production configuration has been changed. Engineering estimates from the discussion were preliminary, not acceptance commitments.


## Decomposition Strategy


Five work streams separate durable facts, domain meaning, delivery, and installation. EP-231 owns the shared event contract, atomic inventory source records, event storage, CLI listing and HTTP reads. EP-232 supplies deployment facts. EP-233 supplies backup facts and a read-only collector for unattended runs. EP-234 supplies the transport-neutral destination/subscription contract, reviewed configuration, shared reliable delivery, and the first webhook adapter. EP-235 packages and operates the combined service, integrates credentials and upgrades, and confirms the complete path.

This preserves independently useful outcomes: a queryable feed before push delivery; deployment notifications without waiting for backup coverage; backup observation without silently accepting recovery points; and a sender verified against a local receiver before cluster installation. Calling receiver URLs directly from deployment code would couple external availability to inventory mutation. Treating Kubernetes Events or human-readable journal detail as public facts would provide neither the required semantics nor durable replay. The durable feed remains independent of all delivery transports; adding a Kafka destination later must not make Kafka the inventory journal or require it for webhook operation. A new broker is unnecessary for the initial implementation.

Relevant local decisions are [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md), requiring typed Haskell modules and explicit architecture boundaries; [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), retaining one reviewed inventory executor and bounded recorded-state reads; [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md), keeping credentials in operator-owned material and using conditional object storage; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), requiring adversarial offline execution before native confirmation; [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md), requiring recorded physical identities; and [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md), retaining the single-node operating model and reviewed backup retention. MasterPlan 28's API remains read-only: lifecycle reads are an explicit narrow extension, while subscription mutations remain CLI-reviewed operations.

[ADR 33](../adr/0033-lifecycle-delivery-separates-destination-state-from-transport-adapters.md) records the accepted transport boundary and Kafka extension constraint, with implementation pending. EP-231 records the source/feed commit protocol when implementing it; EP-234 extends durable context with exact wire/retry semantics, and EP-235 records credential and recovery consequences. None of these planning documents claims runtime acceptance.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 231 | Durable event feed and atomic source facts | [EP-231](../plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md) | None | None | Not Started |
| 232 | Successful application deployment events | [EP-232](../plans/232-record-successful-application-deployments-as-lifecycle-events.md) | EP-231 | None | Not Started |
| 233 | Verified database backup events and collection | [EP-233](../plans/233-observe-verified-database-backups-and-publish-lifecycle-events.md) | EP-231 | None | Not Started |
| 234 | Shared delivery core and first webhook adapter | [EP-234](../plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md) | EP-231 | EP-232 and EP-233 real producer fixtures | Not Started |
| 235 | Runtime installation and recovery proof | [EP-235](../plans/235-run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery.md) | EP-232, EP-233, EP-234 | None | Not Started |

Statuses are Not Started, In Progress, Complete, or Cancelled. Whole-child hard dependencies require completion of that child.


## Dependency Graph


Implement EP-231 first. Its first milestone proves the uncertain inventory-finalization-to-feed boundary with a real executor and a faultable conditional store, before adding public API variants. Once EP-231 is complete, EP-232, EP-233 and EP-234 have independent prerequisites; their interfaces come from EP-231 rather than assumptions about one another. The default execution order is EP-231, EP-232, EP-233, EP-234, EP-235. EP-234 can use typed fixture events until the real producer fixtures are available. EP-235 waits for all three so its deployed drill confirms actual deployment, scheduled backup and HTTP delivery behavior.

EP-233 proves one managed PostgreSQL scheduled run before extending engine and app-database variants. EP-234 proves the same event through its shared engine to a real HTTP receiver and an independently checkpointed test-only recording adapter, including failure isolation and lost acknowledgment, before expanding subscription policy. These checks belong to the children and are not duplicate integration plans.


## Integration Points


**Source commit and public contract — EP-231 owns.** New code under `cli/nagarectl/src/Nagare/Events/` defines opaque source keys, validated event candidates, the facts object and convergence journal event, and the feed reader/writer. The namespace is `Nagare.Events`, because `Nagare.Inventory.Lifecycle` and `Nagare.Inventory.Plan.Lifecycle` already name operator lifecycle proposals. Public DTOs and schemas belong in `cli/nagare-contract`, HTTP routes in `cli/nagare-api`, and read handlers in `cli/nagare-api-server`. The contract package retains independence from the inventory library. EP-232 and EP-233 build typed candidates; they do not add another executor or write ad hoc JSON.

Inventory-produced facts ride the existing journal, not a second chain. The journal is already an immutable, digest-linked sequence whose tip, `headSequence`, advances in the same conditional head replacement that commits each event: `Execute/Journal.hs`, `appendEventAt` and `commitHead`, publish `journal/<sequence>` and then replace the head, settling an uncertain write by rereading and retrying while the head is unchanged. What is missing is an event at final convergence. `Execute/Transaction.hs` appends the transaction-level `Completed` before `finalizeCollections`, and `releaseClaimWith` in `Execute/Claims.hs` later replaces the head with the claim cleared and convergence recorded without appending anything. EP-231 therefore appends one typed convergence event in that replacement, through the same publish-then-commit path. The event names the digest of an immutable facts object published under the inventory prefix before the head write; the facts object carries the transaction's public event candidates and its typed internal subscription/replay control facts, which authorize notification work without becoming public lifecycle events. A facts object no committed journal event names is an orphan, not an event source. The journal sequence is every consumer's checkpoint; consumers read `journal/` suffixes after it and never the whole journal. No new head field or second tip is carried through copy, transfer and rebuild paths, but the wire changes: the journal event schema gains a variant and the head wire version advances inside the EP-172 StoreHead transition, so an older CLI refuses the store at head read. Existing journal bytes are unchanged. Source capture is local/object-store work; no collector or receiver HTTP request occurs under the inventory writer claim.

**Event history — EP-231 owns.** The event feed is a separate context-bound storage prefix with its own conditional head, immutable envelopes and source checkpoints. Materialization means converting a committed source fact or verified receipt into a public event. Stable IDs derive from context identity and the versioned source key, never a retry timestamp. Store envelopes in bounded immutable segment objects indexed by position; publish segments and index nodes, then atomically advance the constant-size feed head with its journal-sequence and receipt checkpoints. A page of 50 reads the head, one index node and at most two segments, through exact GETs and never a listing. Reprocessing a source creates no second logical event. The feed orders discovery/publication, not real-world causality across different producers; payloads retain occurrence and observation times. EP-233 adds receipt discovery through this interface. EP-234 reads this feed and owns separate delivery checkpoints.

**Producer guarantees — EP-232 and EP-233 own.** Deployment facts name a scope, exact release and final convergence proof, once per changed release in a transaction. Backup completion facts name source lineage, backup ID, archive/receipt versions and verification proof. Acceptance facts refer to that same backup identity and a converged reviewed ingestion. Event observation must not become inventory acceptance. Failures to collect scheduled receipts are visible as collection lag/errors and never reclassified as completed backups.

**Subscriptions and delivery — EP-234 owns.** A subscription is reviewed configuration naming a typed destination, event types, optional exact resource filters, a starting position and a versioned delivery policy. Its destination has a stable identity and a transport discriminator; only the webhook variant is available in production initially. Endpoint/network configuration and signing-secret references belong to that variant, not the shared subscription fields. Public delivery inspection identifies destination and transport separately from optional transport-specific receipt details. Converged configuration is readable by the sender; secret values are resolved separately. Committed control facts preserve every configuration revision and replay authorization even if newer inventory transactions finish before the worker catches up. Each subscription/destination owns its durable scan cursor and pending work, recording that every event up to its position was either matched to a persistent delivery, deliberately filtered or explicitly cancelled by a recorded configuration change. Shared code lives in `Nagare.Events.Subscription`, `Nagare.Events.Delivery`, `Nagare.Events.Delivery.Store` and `Nagare.Events.Delivery.Transport`; HTTP implementation remains under `Nagare.Events.Webhook`. Destination state heads stay constant-size and point to immutable nodes, so neither a conditional write nor a cycle's reads grow with delivery history. Shared state uses acknowledged, retryable, permanent-failure and unknown-outcome results rather than HTTP statuses. Retry scheduling is shared; error classification, acknowledgment evidence and default policy belong to each transport. Bounded budgets isolate destinations and transports. One unavailable destination must never block another cursor or inventory operations. Delivery attempts have stable event/delivery IDs, finite automatic retries and explicit replay. At-least-once means a receiver may see the same event again after an uncertain acknowledgment. The existing admin API gains only transport-neutral read routes, `/v1/events/subscriptions`, `/v1/events/deliveries` and `/v1/events/deliveries/{deliveryId}`, with a `transport` discriminator and typed optional receipt details; there is no `/v1/webhooks` group, so a later transport adds no route. CLI inspection and replay nouns are `events subscription` and `events delivery`; only `events webhook create|update|disable|delete` names the transport. No mutation credentials are added.

**Future Kafka destination — EP-234 preserves the seam; implementation is later work.** A future typed Kafka variant supplies broker/topic binding, credential references, record-key selection, producer acknowledgment policy and batching limits through the same delivery engine. Reuse the immutable event envelope/ID as record value/identity and derive any resource routing key from stable context/logical resource identity; do not add Kafka-specific fields to domain source facts. Preserve feed position as separate publication metadata. Explicitly specify ordering and retry behavior: webhook retries may overtake failed events, so strict per-key Kafka ordering would require an additional delivery policy and proof. Broker acknowledgment is publication evidence, never proof of consumer processing. Retain at-least-once cross-store recovery; producer features alone do not justify an end-to-end exactly-once claim. Topic mapping, Kafka client/version selection, native broker tests and broker provisioning are deliberately not implemented by this initiative. A test-only recording adapter with non-HTTP receipts proves the seam now.

**Runtime and credentials — EP-235 owns integration.** One new Haskell executable, `nagare-events`, runs source materialization, receipt collection and transport-neutral delivery with bounded independent destination queues. It is a second executable of the `nagare-api-server` package, shipped in that package's existing release image and run by a second Deployment with its own command, ServiceAccount and credentials, as `nagared` is a second executable of `nagarectl`; no new package, image or pin. Receipt discovery and verification use in-process object operations, gogol for GCS and an in-cluster MinIO reader for local mode, because the existing `ScheduledGcs.hs` and `ScheduledStore.hs` paths run `gcloud` and `curl` from the operator's workstation. Readiness reports the last loop iteration's checks and never touches the store. Register transport adapters at the runtime boundary; do not dispatch on transport inside source materialization or domain producers. Its libraries remain testable without a running service. The API gains read-only access to the event prefix; the worker reads required inventory history, exact backup objects and scoped signing keys, and writes only event/delivery state. It receives no inventory apply/resume/close authority. The worker's scheduled-receipt observer is an explicit service read capability, not a widening of the admin API's provider-read boundary. Local filesystem and GCS modes both have an installation and persistence story.

**Request and latency budget — shared; each child asserts its part, EP-235 measures the whole.** An inventory transaction without facts adds no store write; one with facts adds one facts object and one journal event and no extra head write. Source materialization reads the inventory head once per 30-second cycle and then only journal objects after its checkpoint and the facts they name. Backup discovery lists the shared backup prefix once per five-minute cycle, independent of the schedule count, against the 15-minute upload cadence of ADR 28, and downloads an archive once per exact version within a byte budget, because a receipt pins a SHA-256 that provider metadata cannot confirm. A delivery attempt costs at most three conditional writes. A feed page of 50 reads the head, one index node and at most two segments; the admin API serves it from `Serve.hs`'s representation cache keyed by the feed revision, under the existing ten-second deadline, with exact GETs and no listing. Probes never read or write the store. The worker runs with the admin API's request and limit shape. Each child asserts its counts with `Store/Counters.hs`; EP-235 records idle and loaded per-cycle counts natively.

**Recovery and retention — shared, EP-235 accepts.** Source facts, event envelopes and delivery records are retained without automatic pruning in v1; their bounded per-cycle/page cost is tested independently of total history. Pending and exhausted deliveries are never discarded by a TTL. Capacity use is reported so later reviewed retention can be designed. Back up the new authoritative notification state under the existing recovery objectives. Rebuilding from an older checkpoint may redeliver an event with the same ID; it must never redeploy an app or rerun a backup. New subscriptions start after a durably captured feed high-water mark; replay of history is explicit. Candidate/rehearsal installations disable outbound delivery unless aimed at the drill receiver.


## Progress


2026-11-04: All five children are Not Started. EP-231 is ready; the others wait on it as the registry states. Completion requires EP-235's restart, duplicate-delivery, unattended-backup, credential-isolation and upgrade drills and the budget above measured natively. No implementation or native acceptance is claimed.


## Surprises & Discoveries


The current journal's transaction completion precedes the final converged-head write. Source: `cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs`, `executeWithJournal`, and `cli/nagarectl/src/Nagare/Inventory/Execute/Claims.hs`, `releaseClaimWith`. This changes the shared design: consumers must not publish success merely by matching a journal completion or its detail text.

Scheduled backup receipts can be verified before reviewed ingestion and remain useful after the producing Job disappears. Source: `cli/nagarectl/src/Nagare/Inventory/ScheduledIngest.hs` and `docs/user/backups-and-disaster-recovery.md`. Completion and acceptance therefore need separate event guarantees and a background receipt observer.

2026-11-04: The journal is already the chain EP-231 planned to add. Source: `cli/nagarectl/src/Nagare/Inventory/Execute/Journal.hs`, `appendEventAt` and `commitHead`, publish a digest-linked `journal/<sequence>` object and advance `headSequence` in one conditional head replacement, settling an uncertain write by reread and bounded retry. Only `releaseClaimWith` replaces the head without an event. EP-231 now appends a typed convergence event there instead of a second chain and head field.

2026-11-04: The scheduled-receipt paths are operator tools. Source: `cli/nagarectl/src/Nagare/Inventory/ScheduledGcs.hs` runs `gcloud storage objects list` as a subprocess, `ScheduledStore.hs` port-forwards and runs `curl` with SigV4 credentials, and `nix/release-images.nix` puts only the binaries, busybox and CA certificates in a service image. EP-233's collector needs in-process object operations, and local mode needs an in-cluster MinIO reader, the initiative's one dependency decision.

2026-11-04: `Nagare.Inventory.Lifecycle` and `Nagare.Inventory.Plan.Lifecycle` already name operator lifecycle proposals, and `cli/nagare-api/src/Nagare/Api/Page.hs` caps pages at 100 where EP-231 said 200. The namespace is `Nagare.Events` and pages follow `Nagare.Api.Page`.


## Decision Log


2026-10-31: Separate the event feed from delivery, and domain producers from both. This provides useful history before webhooks and gives each child an observable outcome.

2026-10-31: Preserve the single inventory executor and read-only admin API. Commit source reachability with final convergence; run collection and HTTP delivery outside that authority. This avoids false success, loss between operation completion and notification, and receiver-induced deployment delays.

2026-10-31: Distinguish verified backup completion from reviewed acceptance. A notification is never new recovery or pruning authority.

2026-10-31: Use existing conditional filesystem/GCS storage and a bounded context-local Haskell worker; add no broker. Delivery is at least once with stable IDs and explicit replay, and v1 introduces no automatic notification-history deletion.


2026-10-31: Require a transport-neutral delivery core with typed destination configuration and adapter outcomes; ship only the webhook transport and prove extension with a test-only non-HTTP adapter. Kafka can later consume the same feed through independent checkpoints without a producer rewrite or inheriting HTTP retry/ordering assumptions. [ADR 33](../adr/0033-lifecycle-delivery-separates-destination-state-from-transport-adapters.md) records this durable boundary.

2026-11-04: Reuse the inventory journal as the source chain. One typed convergence event appended in `releaseClaimWith`'s head replacement names an immutable facts object. This removes a second chain, a second head tip and its copy, transfer and rebuild paths, and reuses `commitHead`'s settle-and-retry; the journal sequence is every consumer's checkpoint. The wire change is a journal event variant and the head wire version, carried by the EP-172 StoreHead transition.

2026-11-04: Inspection is transport-neutral: `/v1/events/subscriptions` and `/v1/events/deliveries` with a `transport` discriminator, and the CLI nouns `events subscription` and `events delivery`; only webhook creation and configuration commands name the transport. A later Kafka destination adds no route or noun.

2026-11-04: Ship `nagare-events` as a second executable of the `nagare-api-server` package in its existing release image, run by a second Deployment with its own credentials, as `nagared` is a second executable of `nagarectl`. Credential separation is a deployment property, not an image property; a fifth image, package and pin would add release and gate cost for nothing.

2026-11-04: Fix the cost defaults in Integration Points: five-minute backup discovery with one listing per cycle against ADR 28's 15-minute uploads, archive bytes verified once per version within a budget, constant-size feed and destination heads over immutable segments and nodes, cache-served API pages and probes that never touch the store. The module namespace is `Nagare.Events`.


## Outcomes & Retrospective


(To be filled during implementation and at completion.)
