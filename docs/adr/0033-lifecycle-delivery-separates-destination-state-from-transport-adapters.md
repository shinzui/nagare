---
title: "Lifecycle delivery separates destination state from transport adapters"
status: accepted
date: 2026-10-31
authors: [shinzui]
related:
  - docs/masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md
  - [docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md](https://github.com/shinzui/nagare/blob/940c1481caa27e7b267f070b623201c5da31e64f/docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md)
  - [docs/plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md](https://github.com/shinzui/nagare/blob/940c1481caa27e7b267f070b623201c5da31e64f/docs/plans/234-deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay.md)
  - [docs/plans/235-run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery.md](https://github.com/shinzui/nagare/blob/940c1481caa27e7b267f070b623201c5da31e64f/docs/plans/235-run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery.md)
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
---

# ADR 33 — Lifecycle delivery separates destination state from transport adapters


## Status


Accepted design direction on 2026-10-31, when the operator requested that the lifecycle-event plans explicitly preserve future Kafka publication. Amended on 2026-11-04 during the MasterPlan 31 review: the module namespace is `Nagare.Events`, because `Nagare.Inventory.Lifecycle` already names operator lifecycle proposals, and the inspection surface is transport-neutral. Amended on 2026-11-17 by EP-234's implementation with the delivered wire and retry semantics below. This record does not claim an installed event service (EP-235) or a Kafka adapter.


## Context


[MasterPlan 31](../masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md) separates durable event facts from outbound webhooks. Its initial delivery child placed delivery state under a webhook namespace and expressed acknowledgment/retry behavior directly in HTTP terms. That would make future Kafka delivery reuse the feed but risk duplicating subscription/checkpoint/replay logic or imposing HTTP-shaped configuration and outcomes on it.

Deployment and backup producers already have independent semantic guarantees. Adding another publication transport must preserve those guarantees and stable event identities. [ADR 22](0022-compose-independent-resource-scopes-through-a-typed-inventory.md) retains the reviewed inventory executor as operation authority; neither a webhook receiver nor a Kafka broker becomes that authority.


## Decision


The canonical event envelope, event ID, source facts and feed remain transport-neutral. Domain producers record facts and do not know destination URLs, signing headers, brokers, topics or partition receipts. Feed position is publication metadata separate from event identity and any transport receipt.

Shared modules under `Nagare.Events.Subscription` and `Nagare.Events.Delivery` own typed reviewed subscriptions/destinations, filtering, durable matching, independent scan checkpoints, pending deliveries, attempt identities, scheduling, inspection and replay. Each destination has a stable identity, explicit transport discriminator, versioned typed configuration and delivery policy. V1 has one destination per subscription; another destination uses another subscription over the same immutable event history. Public event documents remain unchanged across destinations.

Adapters own transport configuration validation, credential capabilities, external publication, acknowledgment evidence, failure classification and default policy. The shared engine receives acknowledged, retryable, permanent-failure or unknown outcomes, never an HTTP status as its universal result type. HTTP signing, status classification, Retry-After parsing and response limits remain under `Nagare.Events.Webhook`. Typed optional receipt details may vary by transport without making every destination supply URL/signing fields. Only the webhook destination is supported in production initially; unsupported versions/types produce explicit destination-local diagnostics. There is no dynamic plugin framework or arbitrary unvalidated configuration map. Inspection routes and CLI nouns are transport-neutral, `/v1/events/subscriptions`, `/v1/events/deliveries` and `events subscription`/`events delivery`, with a `transport` discriminator; only a transport's creation and configuration commands name it, so a later destination adds no route or noun.

Destination queues, checkpoints, attempt history and retry state are independent and subject to fair bounded scheduling. An unavailable future Kafka destination must not stall a webhook, advance its cursor or delay deployment/backup operations. Register adapters only in worker setup; source materialization and domain code never select a transport. Delivery-control facts remain durably linked to committed inventory outcomes, separately from public lifecycle events.

A future Kafka adapter can supply broker/topic binding, credential references, key selection, acknowledgment policy, batching and backpressure through this boundary. Use the same immutable event value and event ID, with stable context/logical resource identity available for routing keys. Strict per-key ordering, if required later, needs an explicit scheduling/retry/replay policy and tests; the initial webhook policy permits retry overtaking. Broker acknowledgment is publication evidence, not evidence that a consumer processed an event. Recovery between Nagare state and an external destination retains an at-least-once baseline; no transport feature alone establishes end-to-end exactly once.

Acceptance now requires a real shared-engine test with the webhook adapter and a test-only non-HTTP recording adapter using different receipt/configuration shapes. Both consume identical event IDs/bytes through independent checkpoints, and restart, retry, exhaustion and replay of one leave the other unaffected. The recording adapter is not a shipped destination or a Kafka emulator. Shared code must compile without importing concrete transport implementations.


## Consequences


EP-231 explicitly preserves transport-neutral identity, canonical event bytes, routing identity and independent feed readers. EP-234 owns the shared delivery boundary and HTTP implementation, with the two-adapter proof before policy expansion. EP-235 wires adapters and scoped credentials at the process boundary and verifies isolated/fair runtime behavior. Deployment and backup producer plans do not change.

A later Kafka implementation adds a typed configuration variant, adapter/policy, credentials, conformance coverage and real broker fidelity tests. Kafka client selection, topic management, broker provisioning and a production Kafka endpoint are outside MasterPlan 31. A webhook-only implementation whose delivery core imports HTTP protocol policy fails this architecture even if the feed itself is reusable.

A versioned typed extension is preferred to duplicating delivery engines, sending directly from producers or replacing the authoritative event feed with Kafka. Existing event/HTTP behavior and webhook-first implementation order remain intact.


## Amendment, 2026-11-17: the delivered semantics (EP-234)


The shared engine is `Nagare.Events.Delivery`, with its state in `Nagare.Events.Delivery.Store` and the adapter contract in `Nagare.Events.Delivery.Transport`; `scripts/check-haskell-architecture.py` refuses an import of `Nagare.Events.Webhook`, `Network.HTTP`, `Network.Connection` or `Network.Socket` from them. A subscription is one standalone inventory scope with no provider member; its record and last reviewed replay are scope overrides, and every converged change of either is an `event-subscriptions` control fact. The sender applies controls in journal order, idempotently by revision and delivery ID, before its checkpoint advances. Whether a reviewed destination change cancels the old revision's unsent work is the adapter's decision (`AdapterFactory.redirects`): a webhook URL or allowed-host change does; a signing-key rotation does not. A cancellation records its boundary, the feed count when the control was applied.

A delivery's ID derives from subscription, destination, event and cycle (`initial` or a reviewed replay's). It is recorded before anything is sent; an attempt's intent, under a fresh token, is recorded before the external call, and its outcome after it only while the record still holds that token. An intent with no outcome older than two minutes is closed as unknown and retried. The webhook adapter signs HMAC-SHA256 over `v1`, timestamp, event ID and delivery ID, each LF-terminated, then the raw body, as `v1;kid=ID;sig=HEX` entries; acknowledges only 2xx; retries 408, 429 and 5xx honouring `Retry-After`, connection refusals and timeouts; treats other 3xx and 4xx as permanent; and allows ten attempts within 24 hours from ten seconds doubling to an hour with a quarter of jitter. It connects only to policy-checked resolved addresses and verifies TLS for the URL's host. The test-only recording adapter in `EventsDeliverySpec` proves the seam: the same engine delivers identical event bytes and IDs to it and to a real HTTP receiver, from independent cursors, with failure isolation.
