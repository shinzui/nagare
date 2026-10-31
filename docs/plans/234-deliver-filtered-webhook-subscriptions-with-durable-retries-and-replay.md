---
id: 234
slug: deliver-filtered-webhook-subscriptions-with-durable-retries-and-replay
title: "Deliver filtered webhook subscriptions with durable retries and replay"
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

# Deliver filtered webhook subscriptions with durable retries and replay


## Purpose / Big Picture


An operator can register a receiver URL and selected lifecycle event types, inspect what Nagare tried to deliver, and replay an exhausted delivery. Events are sent as signed HTTP POST requests without making deployments or backups wait for the receiver. If a receiver processes a request but its response is lost, the retry carries the same event identity so the receiver can deduplicate it.


## Progress


- [ ] M1: Reviewed subscription configuration establishes exact filters, endpoint, secret reference and a durable starting feed position; unauthorized or invalid configurations are refused.
- [ ] M2: One real HTTP receiver observes signed delivery, persistence across sender restart and a stable identity after lost acknowledgment.
- [ ] M3: Bounded fan-out, finite retries, endpoint changes, pause/disable, key rotation and explicit replay work under adversarial state/transport tests.
- [ ] M4: CLI and protected read-only HTTP inspection explain delivery state, and a documented receiver verifies signatures and deduplicates events.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-31: Deliver at least once with bounded automatic attempts and durable exhausted state. A timeout is an unknown outcome, not proof the receiver did nothing; do not promise exactly once or strict arrival order.

2026-10-31: Keep all configuration changes reviewed through the CLI and all HTTP admin routes read-only. Each delivery records its subscription revision; endpoint/filter changes never silently redirect already queued data.


## Outcomes & Retrospective


(To be filled during implementation and at completion.)


## Context and Orientation


A subscription is reviewed configuration describing which events to send and where. Fan-out means matching each published event to every eligible subscription and creating a persistent delivery for each match. An attempt is one HTTP request for a delivery. A replay is an explicit operator request for a new delivery cycle of the same event, without repeating deployment or backup work. At-least-once delivery allows duplicates when a request succeeded remotely but its acknowledgment was not recorded locally.

The prerequisite `docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md` supplies the complete event contract, stable source/event IDs, context-bound immutable history and conditional lifecycle storage. This child can use fixture events without waiting for domain producers. Real payload fixtures from `docs/plans/232-record-successful-application-deployments-as-lifecycle-events.md` and `docs/plans/233-observe-verified-database-backups-and-publish-lifecycle-events.md` are soft integration inputs.

The existing HTTP admin API in `cli/nagare-api/src/Nagare/Api/Routes.hs` and `cli/nagare-api-server/src/Nagare/Api/Server/App.hs` is read-only. Reviewed CLI workflows live under `cli/nagarectl/app/Nagare/Cli/Inventory/` and `Commands/`. The single inventory executor is in `cli/nagarectl/src/Nagare/Inventory/Execute/`. Existing inbound Git provider handling in `cli/nagarectl/src/Nagare/Static/Webhook.hs` verifies signatures but is not an outbound queue or subscription implementation.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires one reviewed authority and explicit capabilities. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) keeps secret values outside public configuration. [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) requires typed library/runtime boundaries. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires faultable HTTP and store interpreters before live installation. Record durable delivery guarantees in the lifecycle ADR introduced by EP-231.


## Plan of Work


### M1 — Reviewed subscriptions


Add `cli/nagarectl/src/Nagare/Lifecycle/Webhook/Subscription.hs`, with pure constructors/validation, and executable-private CLI options/dispatch for `events webhook create`, `update`, `disable` and `delete`. They save inventory reviews; ordinary `inventory apply DIR --yes` applies them. Compile each subscription as a dedicated standalone scope containing a reviewed configuration ConfigMap, using the existing Kubernetes adapter rather than creating a second reconciliation engine. Persist only endpoint, subscription ID, exact supported event types, optional exact resource filters, a signing-secret namespace/name/key reference, endpoint network policy and `startAfter`. The sender reads verified converged subscription declarations and their exact immutable configuration, not an arbitrary same-name live ConfigMap. Accepted-but-unconverged changes are not active.

Capture the current event-feed high-water position when saving a creation review and include it explicitly in that review. Default matching starts strictly after this position once the subscription converges; events published during the review delay remain eligible. A brand-new subscription does not implicitly send older history. Updates preserve its original creation position. Duplicate creation with an existing ID refuses unless it is the same idempotent review. Commit typed subscription-control facts through EP-231's atomic source chain for every converged create, update, disable, reactivate and delete, preserving the exact immutable configuration revision. The sender must replay these control revisions in committed order even if several changes finish while it is offline; reading only the latest accepted ConfigMap would lose their boundaries. Use a durable independent control-consumer checkpoint. No HTTP subscription mutation endpoints are added.

Require HTTPS for ordinary receivers and reject userinfo, URL fragments, redirects and credentials in query strings. Support cluster-private receivers through explicit reviewed allowed host/network configuration. Deny loopback, link-local and cloud metadata destinations; local integration tests use a narrowly injected transport policy. Validate resolved addresses at connection time and bind the connection to the validated resolution so DNS changes cannot bypass the configured destination policy. Do not globally ban private networks needed by intranet consumers. Bound URL, filter and response sizes and return useful review errors. Resolve signing material from an existing context-owned Secret; never put the value in flags, saved review text or public contract documents.

### M2 — One signed request through actual transport


Add `Webhook/Delivery.hs`, `Webhook/Signature.hs`, `Webhook/Transport.hs` and `Webhook/Store.hs` behind small public facades. Define typed transport/time/random/store operations and a thin real HTTP interpreter. A delivery ID derives from subscription identity, event identity and replay-cycle identity. The event envelope is byte-stable across attempts. Persist the delivery before issuing HTTP. Record an attempt intent and unique attempt token before sending, then conditionally record acknowledgment. Only a 2xx response acknowledges delivery. A crash or timeout after send leaves an unknown attempt and allows a later duplicate; never allocate a new event ID.

Use `Nagare-Event-Id`, `Nagare-Delivery-Id`, `Nagare-Webhook-Timestamp` and `Nagare-Webhook-Signature` headers. The timestamp is decimal Unix seconds. Sign with HMAC-SHA256 over UTF-8 `v1`, timestamp, event ID and delivery ID, each followed by a single LF byte, then the exact raw body with no added terminator. IDs contain no CR/LF. Encode each signature entry as `v1;kid=KEY_ID;sig=LOWERCASE_HEX`, with comma-separated entries during rotation; key IDs are restricted ASCII tokens. Publish exact canonical input bytes and expected digest as a fixture; do not rely on parsing and reserializing JSON. The receiver checks a five-minute timestamp window, compares signatures in constant time and records processed event IDs. A fresh retry timestamp yields a fresh signature over the same event bytes. Signatures prove possession of the subscription key, not workload health.

Prove one real socket roundtrip before implementing broad retry/fan-out policy. The receiver first processes a request then drops its response; restart the sender and observe the same event/delivery identity with another attempt. It must verify with the documented receiver algorithm and produce one downstream side effect after deduplication. Store faults before and after request issuance must be modeled already.

### M3 — Durable matching and bounded retry policy


Persist per-subscription scan cursors and matching deliveries in the same conditional subscription-state commit. An event is either deliberately filtered or has a durable delivery before that cursor advances. Never use one global cursor that can skip a subscription added or updated concurrently. Source the subscription's start position/revision from its converged declaration. The store uses EP-231's lifecycle binding and conditional primitives with independent delivery keys; no inventory writer claim is held while sending. Multiple workers may race, but attempt tokens and conditional transitions prevent stale acknowledgments from overwriting later state. Duplicate sends remain possible and documented. Maintain a due-work index; do not scan all historical deliveries each cycle.

Allow four concurrent sends overall and one in-flight attempt per subscription, with a ten-second total request timeout, a 64 KiB response capture limit and bounded queue/scan work per cycle. Persist enough work to resume without holding the backlog in memory. Preserve feed order for initial scheduling within a subscription but do not block later events behind a failed receiver request; strict arrival ordering is not promised. A bad subscription cannot starve another.

Automatically retry network/timeouts, HTTP 408, 429 and 5xx. Treat other 4xx and 3xx as terminal failures, retaining the reason. Make at most ten automatic attempts over at most 24 hours, whichever bound arrives first; use exponential backoff from ten seconds, capped at one hour, with jitter. Honor a valid Retry-After value for retryable responses within the same lifetime cap. Inject clock/randomness for deterministic tests. Exhausted/terminal records remain inspectable until explicit replay; retain all history in v1.

A disable pauses new sends and retains pending/exhausted records. Reactivation can resume unchanged pending work. Endpoint or filter changes cancel unsent deliveries of the old configuration revision and retain cancellation reasons; already acknowledged attempts remain acknowledged. Their reviewed activation policy is to capture the current feed head when applying that committed control fact to sender state. Persist that boundary, old/new revisions, cancellation range and control checkpoint in one conditional sender-state update. Unscanned events through the boundary are explicitly classified as cancelled under the old revision; events after it use the new revision. This gives a recoverable boundary without pretending a planning-time feed position atomically changes a running sender. Explicit replay under the current revision is how an operator chooses to resend old cancelled data. Deletion stops sends and preserves audit/delivery state. Before issuing a send, synchronize committed controls through a fresh bound source head; a request already in flight can still complete after disable/delete and must remain reported.

Rotate signing material through reviewed Secret references, not an in-place secret-value change that the sender silently treats as stable. Support a bounded overlap by attaching both current and retiring key signatures with explicit key IDs, followed by a reviewed removal of the retiring reference. Unknown/missing/changed Secret versions pause affected delivery with a diagnostic. Never leak secret bytes in attempt logs. Endpoint/filter changes and signing-key rotation have distinct behavior: rotating keys does not cancel pending events.

Add `events webhook replay ID --event EVENT_ID --save-plan DIR`. Review the exact retained event ID, current subscription revision and new replay-cycle ID; a typed replay control fact committed through EP-231's source chain authorizes enqueueing that cycle, never an application operation. It remains reachable after later configuration changes or removal of its Kubernetes control object. Apply the control and its independent checkpoint atomically with delivery creation, checking the subscription's current enabled revision; changed authority pauses replay for a new review rather than silently redirecting it. Reapplying the same review does not create extra cycles. Each replay has the same event ID and a new delivery-cycle ID, with lineage to earlier attempts. Receiver deduplication by event ID still prevents an unwanted repeated effect; documentation explains that intentional repeated downstream work is the receiver's decision.

### M4 — Inspect and integrate


Add `events webhook list`, `deliveries` and `inspect` with the shared contract output, plus protected read-only `/v1/webhooks/subscriptions`, `/v1/webhooks/deliveries` and individual delivery reads. Use EP-231's context-bound paging and API error/deadline conventions. Include subscription revision, event ID, replay lineage, attempt times/statuses, next attempt, bounded sanitized failure detail and terminal/pause/cancel reason. Exclude secret values and response bodies containing credentials; do not log arbitrary receiver bodies verbatim. Extend the generated OpenAPI and Hurl/client tests.

Add a minimal runnable Haskell receiver example and protocol guide under `cluster/examples/lifecycle-webhook-receiver/` and `docs/user/lifecycle-events.md`. Its library test independently verifies the published signing vector, rejects stale/modified requests, and deduplicates duplicate event IDs in persistent test storage. Demonstrate both deployment and backup DTO fixtures through the same transport. Keep notifications distinct from inbound Git webhook automation.


## Concrete Steps


From the repository root, after EP-231 is Complete:

```bash
python3 scripts/check-haskell-architecture.py
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /Lifecycle.Webhook/' --test-show-details=direct
cabal test nagare-api-server-test --project-dir=cli/nagarectl --test-show-details=direct
just api-hurl
```

Use Mori to locate the existing HTTP and cryptographic dependency source/docs before using APIs. Check upstream releases and authoritative package registries before changing bounds; this plan does not select a new library. Establish nonempty `Lifecycle.Webhook` groups including real HTTP, virtual-clock and faultable-store tests.

The following future interface must be implemented and documented against a disposable fixture context with an existing signing Secret and approved receiver domain:

```bash
cabal run nagarectl --project-dir=cli/nagarectl -- events webhook create deploys --url https://receiver.example.test/events --type app.deployed --signing-secret webhook-signing --signing-secret-key current --save-plan ./webhook-review
cabal run nagarectl --project-dir=cli/nagarectl -- inventory apply ./webhook-review --yes
cabal run nagarectl --project-dir=cli/nagarectl -- events webhook deliveries deploys --contract 1
```

Expected behavior: the first command saves a review showing endpoint, filter, secret reference and starting event position; apply activates only that reviewed declaration; listing reports queued, attempted or acknowledged delivery by stable IDs. Do not run this example against a live context during plan creation.


## Validation and Acceptance


Drive the real sender and socket receiver with a seeded event. Verify body bytes/signatures independently, exact filters and resource scoping, timestamps, key rotation and stable identities. Kill the sender at each persistence/request/acknowledgment boundary. A visible matching event is never lost between cursor advancement and delivery persistence; a receiver may see duplicates after uncertain outcomes, with all attempts inspectable. Assert that a receiver outage does not acquire or delay the inventory writer claim.

Use virtual time to exhaust retry bounds, test Retry-After, terminal response classes, response limits, slow/hanging connections, destination changes and DNS-policy checks. Exercise overlapping workers, subscription revision races, disable/delete while a request is in flight, endpoint/filter change and replay-review reapplication. One failed receiver must not stop another. With 10,000 historical deliveries and one due request, due-work lookup and a 50-item inspection page have bounded index reads rather than full-history scans. Invalid cursors and unauthorized admin reads fail normally. No native cluster is needed for child acceptance.


## Idempotence and Recovery


Use immutable events, stable delivery identities, conditional state transitions and attempt tokens. Settle lost state-write acknowledgments by rereading before enqueueing or issuing another attempt. A pending/unknown HTTP attempt can be retried with the same event ID; the receiver must deduplicate. Retry exhaustion is recoverable by an explicit retained replay review. Keep original deliveries and lineage when replaying. Never repair delivery by resetting the event feed, applying an app review or rerunning backup production. Pause is reversible; deletion preserves delivery audit and does not retract data already received.


## Interfaces and Dependencies


Hard dependency: complete `docs/plans/231-publish-a-durable-lifecycle-event-feed-with-atomic-source-facts.md`. This child owns subscription compilation, exact revision/start boundaries, signing protocol, sender state machine, delivery indexes, retry/replay policy and inspection DTOs/routes. Domain producers are soft fixture inputs. The independently packaged worker in `docs/plans/235-run-the-lifecycle-event-service-and-prove-restart-and-upgrade-recovery.md` calls these libraries, installs secret/network permissions and owns deployed recovery proof. Library facades accept scoped capabilities rather than an unrestricted inventory execution environment. Record an ADR amendment before shipping the protocol and reviewed delivery-control semantics.
