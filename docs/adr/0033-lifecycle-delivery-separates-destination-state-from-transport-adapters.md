---
title: "Lifecycle delivery separates destination state from transport adapters"
status: accepted
date: 2026-10-31
authors: [shinzui]
related:
  - docs/masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md
  - docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md
  - docs/plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md
  - docs/plans/235-run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
---

# ADR 33 — Lifecycle delivery separates destination state from transport adapters


## Status


Accepted design direction on 2026-10-31, when the operator requested that the lifecycle-event plans explicitly preserve future Kafka publication. Implementation and acceptance are Not Started; this record does not claim an installed event service or Kafka adapter.


## Context


[MasterPlan 31](../masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md) separates durable event facts from outbound webhooks. Its initial delivery child placed delivery state under a webhook namespace and expressed acknowledgment/retry behavior directly in HTTP terms. That would make future Kafka delivery reuse the feed but risk duplicating subscription/checkpoint/replay logic or imposing HTTP-shaped configuration and outcomes on it.

Deployment and backup producers already have independent semantic guarantees. Adding another publication transport must preserve those guarantees and stable event identities. [ADR 22](0022-compose-independent-resource-scopes-through-a-typed-inventory.md) retains the reviewed inventory executor as operation authority; neither a webhook receiver nor a Kafka broker becomes that authority.


## Decision


The canonical event envelope, event ID, source facts and feed remain transport-neutral. Domain producers record facts and do not know destination URLs, signing headers, brokers, topics or partition receipts. Feed position is publication metadata separate from event identity and any transport receipt.

Shared modules under `Nagare.Lifecycle.Subscription` and `Nagare.Lifecycle.Delivery` own typed reviewed subscriptions/destinations, filtering, durable matching, independent scan checkpoints, pending deliveries, attempt identities, scheduling, inspection and replay. Each destination has a stable identity, explicit transport discriminator, versioned typed configuration and delivery policy. V1 has one destination per subscription; another destination uses another subscription over the same immutable event history. Public event documents remain unchanged across destinations.

Adapters own transport configuration validation, credential capabilities, external publication, acknowledgment evidence, failure classification and default policy. The shared engine receives acknowledged, retryable, permanent-failure or unknown outcomes, never an HTTP status as its universal result type. HTTP signing, status classification, Retry-After parsing and response limits remain under `Nagare.Lifecycle.Webhook`. Typed optional receipt details may vary by transport without making every destination supply URL/signing fields. Only the webhook destination is supported in production initially; unsupported versions/types produce explicit destination-local diagnostics. There is no dynamic plugin framework or arbitrary unvalidated configuration map.

Destination queues, checkpoints, attempt history and retry state are independent and subject to fair bounded scheduling. An unavailable future Kafka destination must not stall a webhook, advance its cursor or delay deployment/backup operations. Register adapters only in worker setup; source materialization and domain code never select a transport. Delivery-control facts remain durably linked to committed inventory outcomes, separately from public lifecycle events.

A future Kafka adapter can supply broker/topic binding, credential references, key selection, acknowledgment policy, batching and backpressure through this boundary. Use the same immutable event value and event ID, with stable context/logical resource identity available for routing keys. Strict per-key ordering, if required later, needs an explicit scheduling/retry/replay policy and tests; the initial webhook policy permits retry overtaking. Broker acknowledgment is publication evidence, not evidence that a consumer processed an event. Recovery between Nagare state and an external destination retains an at-least-once baseline; no transport feature alone establishes end-to-end exactly once.

Acceptance now requires a real shared-engine test with the webhook adapter and a test-only non-HTTP recording adapter using different receipt/configuration shapes. Both consume identical event IDs/bytes through independent checkpoints, and restart, retry, exhaustion and replay of one leave the other unaffected. The recording adapter is not a shipped destination or a Kafka emulator. Shared code must compile without importing concrete transport implementations.


## Consequences


EP-231 explicitly preserves transport-neutral identity, canonical event bytes, routing identity and independent feed readers. EP-234 owns the shared delivery boundary and HTTP implementation, with the two-adapter proof before policy expansion. EP-235 wires adapters and scoped credentials at the process boundary and verifies isolated/fair runtime behavior. Deployment and backup producer plans do not change.

A later Kafka implementation adds a typed configuration variant, adapter/policy, credentials, conformance coverage and real broker fidelity tests. Kafka client selection, topic management, broker provisioning and a production Kafka endpoint are outside MasterPlan 31. A webhook-only implementation whose delivery core imports HTTP protocol policy fails this architecture even if the feed itself is reusable.

A versioned typed extension is preferred to duplicating delivery engines, sending directly from producers or replacing the authoritative event feed with Kafka. Existing event/HTTP behavior and webhook-first implementation order remain intact.
