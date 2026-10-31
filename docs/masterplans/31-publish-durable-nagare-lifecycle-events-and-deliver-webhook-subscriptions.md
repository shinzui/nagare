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
---

# Publish durable Nagare lifecycle events and deliver webhook subscriptions


## Vision & Scope


An operator can ask what Nagare deployed and which database backups completed, read the same durable event history through the CLI or protected admin API, and later register receiver URLs to receive signed HTTP POST requests. A receiver can be unavailable while deployment and backup operations continue. Delivery resumes after a worker restart, and an operator can inspect failures and replay an event without repeating its original operation.

The first event types are `app.deployed`, `database.backup.completed`, and `database.backup.accepted`. A deployment event means a changed production application, standalone service, or site release passed the readiness required by its reviewed deployment and committed convergence. It is historical evidence, not a promise of continuing health. A completed backup means its archive and authenticated receipt were verified at exact provider versions. Acceptance is a separate event meaning a reviewed transaction admitted that backup as a recovery point. Notification never grants restore or prune authority.

The first stage delivers event history and producers. The second delivers filtered webhook subscriptions and a context-local background service. Included are manual and scheduled managed-database backups and app-database backups, stable identities, versioned payloads, resumable collection, durable delivery attempts, signature rotation, and recovery documentation. New event types can be added through typed producers with explicit guarantees. Failure/start/delete/restore events, application-volume events, preview deployment events, incoming automation triggers, a UI, SSE/WebSocket streaming, exactly-once HTTP delivery, additional messaging engines, and multi-node availability are outside this initiative. Existing inbound Git provider webhooks stay separate.

Creation of this plan authorizes planning only; no runtime or production configuration has been changed. Engineering estimates from the discussion were preliminary, not acceptance commitments.


## Decomposition Strategy


Five work streams separate durable facts, domain meaning, delivery, and installation. EP-231 owns the shared event contract, atomic inventory source records, event storage, CLI listing and HTTP reads. EP-232 supplies deployment facts. EP-233 supplies backup facts and a read-only collector for unattended runs. EP-234 supplies reviewed subscription configuration and reliable delivery. EP-235 packages and operates the combined service, integrates credentials and upgrades, and confirms the complete path.

This preserves independently useful outcomes: a queryable feed before push delivery; deployment notifications without waiting for backup coverage; backup observation without silently accepting recovery points; and a sender verified against a local receiver before cluster installation. Calling receiver URLs directly from deployment code would couple external availability to inventory mutation. Treating Kubernetes Events or human-readable journal detail as public facts would provide neither the required semantics nor durable replay. A new broker would add an unnecessary stateful dependency.

Relevant local decisions are [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md), requiring typed Haskell modules and explicit architecture boundaries; [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), retaining one reviewed inventory executor and bounded recorded-state reads; [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md), keeping credentials in operator-owned material and using conditional object storage; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), requiring adversarial offline execution before native confirmation; [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md), requiring recorded physical identities; and [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md), retaining the single-node operating model and reviewed backup retention. MasterPlan 28's API remains read-only: lifecycle reads are an explicit narrow extension, while subscription mutations remain CLI-reviewed operations.

No local ADR yet defines outbound lifecycle events. EP-231 records the durable source/feed boundary in a new ADR when implementing it; EP-234 extends that context with delivery semantics, and EP-235 records credential and recovery consequences. Proposed choices below do not claim to be implemented decisions.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 231 | Durable event feed and atomic source facts | [EP-231](../plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md) | None | None | Not Started |
| 232 | Successful application deployment events | [EP-232](../plans/232-record-successful-application-deployments-as-lifecycle-events.md) | EP-231 | None | Not Started |
| 233 | Verified database backup events and collection | [EP-233](../plans/233-observe-verified-database-backups-and-publish-lifecycle-events.md) | EP-231 | None | Not Started |
| 234 | Filtered webhooks, retries and replay | [EP-234](../plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md) | EP-231 | EP-232 and EP-233 real producer fixtures | Not Started |
| 235 | Runtime installation and recovery proof | [EP-235](../plans/235-run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery.md) | EP-232, EP-233, EP-234 | None | Not Started |

Statuses are Not Started, In Progress, Complete, or Cancelled. Whole-child hard dependencies require completion of that child.


## Dependency Graph


Implement EP-231 first. Its first milestone proves the uncertain inventory-finalization-to-feed boundary with a real executor and a faultable conditional store, before adding public API variants. Once EP-231 is complete, EP-232, EP-233 and EP-234 have independent prerequisites; their interfaces come from EP-231 rather than assumptions about one another. The default execution order is EP-231, EP-232, EP-233, EP-234, EP-235. EP-234 can use typed fixture events until the real producer fixtures are available. EP-235 waits for all three so its deployed drill confirms actual deployment, scheduled backup and HTTP delivery behavior.

EP-233 proves one managed PostgreSQL scheduled run before extending engine and app-database variants. EP-234 proves one event through actual HTTP transport to a local receiver, including lost acknowledgment, before expanding subscription policy. These checks belong to the children and are not duplicate integration plans.


## Integration Points


**Source commit and public contract — EP-231 owns.** New code under `cli/nagarectl/src/Nagare/Lifecycle/` defines opaque source keys, validated event candidates, committed source records and the feed reader/writer. Public DTOs and schemas belong in `cli/nagare-contract`, HTTP routes in `cli/nagare-api`, and read handlers in `cli/nagare-api-server`. The contract package retains independence from the inventory library. EP-232 and EP-233 build typed candidates; they do not add another executor or write ad hoc JSON.

Inventory-produced facts must be reachable through an immutable, digest-linked source-record chain whose tip advances in the same conditional head replacement that establishes final convergence. Prepare the immutable record before that replacement. A record uploaded but unreachable from the committed head is an orphan, not an event source. The chain also carries typed internal subscription/replay control facts; these authorize notification work without becoming public lifecycle events. The existing transaction-level journal `Completed` is insufficient: `Execute/Transaction.hs` appends it before `finalizeCollections` and `releaseClaimWith`, and `Execute/Claims.hs` commits the final converged head later. Source capture is local/object-store work; no collector or receiver HTTP request occurs under the inventory writer claim. Preserve all existing journal bytes and define an explicit store-schema transition for the new head reference.

**Event history — EP-231 owns.** The event feed is a separate context-bound storage prefix with its own conditional head, immutable envelopes and source checkpoints. Materialization means converting a committed source fact or verified receipt into a public event. Stable IDs derive from context identity and the versioned source key, never a retry timestamp. Publish event objects before atomically advancing their visible feed prefix and corresponding source checkpoint. Reprocessing a source creates no second logical event. The feed orders discovery/publication, not real-world causality across different producers; payloads retain occurrence and observation times. EP-233 adds receipt discovery through this interface. EP-234 reads this feed and owns separate delivery checkpoints.

**Producer guarantees — EP-232 and EP-233 own.** Deployment facts name a scope, exact release and final convergence proof, once per changed release in a transaction. Backup completion facts name source lineage, backup ID, archive/receipt versions and verification proof. Acceptance facts refer to that same backup identity and a converged reviewed ingestion. Event observation must not become inventory acceptance. Failures to collect scheduled receipts are visible as collection lag/errors and never reclassified as completed backups.

**Subscriptions and delivery — EP-234 owns.** A subscription is reviewed configuration naming an endpoint, signing-secret reference, event types and optional exact resource filters. Converged configuration is readable by the sender; secret values are resolved separately. Committed control facts preserve every configuration revision and replay authorization even if newer inventory transactions finish before the worker catches up. A durable scan cursor records that every event up to its position was either matched to a persistent delivery, deliberately filtered or explicitly cancelled by a recorded configuration change. Delivery attempts have stable event/delivery IDs, finite automatic retries and explicit replay. At-least-once means a receiver may see the same event again after an uncertain acknowledgment. The existing admin API gains only read routes for deliveries/subscriptions, not mutation credentials.

**Runtime and credentials — EP-235 owns integration.** One new Haskell executable, `nagare-events`, runs source materialization, receipt collection and delivery with bounded independent queues. Its libraries remain testable without a running service. The API gains read-only access to the event prefix; the worker reads required inventory history, exact backup objects and scoped signing keys, and writes only event/delivery state. It receives no inventory apply/resume/close authority. The worker's scheduled-receipt observer is an explicit service read capability, not a widening of the admin API's provider-read boundary. Local filesystem and GCS modes both have an installation and persistence story.

**Recovery and retention — shared, EP-235 accepts.** Source facts, event envelopes and delivery records are retained without automatic pruning in v1; their bounded per-cycle/page cost is tested independently of total history. Pending and exhausted deliveries are never discarded by a TTL. Capacity use is reported so later reviewed retention can be designed. Back up the new authoritative notification state under the existing recovery objectives. Rebuilding from an older checkpoint may redeliver an event with the same ID; it must never redeploy an app or rerun a backup. New subscriptions start after a durably captured feed high-water mark; replay of history is explicit. Candidate/rehearsal installations disable outbound delivery unless aimed at the drill receiver.


## Progress


2026-10-31: MasterPlan and five child ExecPlans drafted and linked to intention `intention_01m695aak2e4ebx7gw1pcvphvr`. All implementation is Not Started. EP-231 is ready; later children await the dependencies above. Completion requires EP-235's restart, duplicate-delivery, unattended backup, credential-isolation and upgrade drills. No implementation or native acceptance is claimed.


## Surprises & Discoveries


The current journal's transaction completion precedes the final converged-head write. Source: `cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs`, `executeWithJournal`, and `cli/nagarectl/src/Nagare/Inventory/Execute/Claims.hs`, `releaseClaimWith`. This changes the shared design: consumers must not publish success merely by matching a journal completion or its detail text.

Scheduled backup receipts can be verified before reviewed ingestion and remain useful after the producing Job disappears. Source: `cli/nagarectl/src/Nagare/Inventory/ScheduledIngest.hs` and `docs/user/backups-and-disaster-recovery.md`. Completion and acceptance therefore need separate event guarantees and a background receipt observer.


## Decision Log


2026-10-31: Separate the event feed from delivery, and domain producers from both. This provides useful history before webhooks and gives each child an observable outcome.

2026-10-31: Preserve the single inventory executor and read-only admin API. Commit source reachability with final convergence; run collection and HTTP delivery outside that authority. This avoids false success, loss between operation completion and notification, and receiver-induced deployment delays.

2026-10-31: Distinguish verified backup completion from reviewed acceptance. A notification is never new recovery or pruning authority.

2026-10-31: Use existing conditional filesystem/GCS storage and a bounded context-local Haskell worker; add no broker. Delivery is at least once with stable IDs and explicit replay, and v1 introduces no automatic notification-history deletion.


## Outcomes & Retrospective


(To be filled during implementation and at completion.)
