---
type: Guide
title: "Lifecycle events and webhooks"
description: "Read Nagare's lifecycle events, subscribe a receiver to signed webhooks, verify and deduplicate them, and inspect or replay deliveries."
docId: DOC-45
tags: [events, webhooks, backups, deployments, operations]
generated:
  by: process:claude
  at: 2026-11-17T23:00:00Z
---

# Lifecycle events and webhooks

A context records what Nagare did as immutable lifecycle events:

| Type | Meaning |
| --- | --- |
| `app.deployed` | A changed production release of an application, standalone service or site passed its reviewed readiness and its transaction converged. |
| `database.backup.completed` | A database backup's archive and signed receipt were verified at exact stored versions. |
| `database.backup.accepted` | A reviewed transaction admitted that backup as a recovery point. |

An event's `id` never changes across retries, restarts or replays. Read them
with `nagarectl events list` or `GET /v1/events`. Backup events are described
in [Backups and disaster recovery](backups-and-disaster-recovery.md#backup-lifecycle-events).

## Subscribe a receiver

A subscription is a reviewed change of the context, like any other:

```bash
nagarectl events webhook create deploys \
  --url https://hooks.example.test/nagare \
  --type app.deployed --type database.backup.accepted \
  --signing-secret events/deploys-webhook --signing-key key \
  --save-plan ./deploys-review
nagarectl inventory apply ./deploys-review --yes
```

The review shows the URL, the event types, the signing Secret reference and
the feed position the subscription starts after: events published after the
review are sent, older history is not. `--scope KIND:NAME [--member RESOURCE]`
narrows it to one scope. The signing key is read from the named Secret field
when the sender delivers; its value never appears in a review. A receiver is
`https://`; a cluster-private host must be named with `--allow-host`, which
also permits plain `http://` for it. Loopback, link-local and metadata
addresses are always refused, and the sender connects only to the address it
checked.

`events webhook update NAME` changes the URL, types or allowed hosts, or
rotates the key with `--rotate-key NAMESPACE/NAME:FIELD:ID` (the old key keeps
signing until `--retire-key ID`). A new URL or filter cancels the deliveries the
old revision had not sent; a key rotation does not. `events webhook disable`
pauses sending and keeps pending work, `update --enable` resumes it, and
`events webhook delete` stops it and keeps the delivery history. Each is a
saved review that `inventory apply` applies.

## What a receiver gets

Each attempt is a `POST` of the event's canonical JSON with:

| Header | Value |
| --- | --- |
| `Nagare-Event-Id` | The event's stable ID. |
| `Nagare-Delivery-Id` | This subscription's delivery of the event in one cycle. |
| `Nagare-Webhook-Timestamp` | Decimal Unix seconds of this attempt. |
| `Nagare-Webhook-Signature` | `v1;kid=KEY_ID;sig=HEX`, comma-separated while a key rotates. |

The signature is lowercase hex HMAC-SHA256, keyed by the Secret's bytes, over
the UTF-8 bytes of `v1`, the timestamp, the event ID and the delivery ID, each
followed by one LF, then the exact body with nothing added. For key
`0123456789abcdef0123456789abcdef`, timestamp `1700000000`, event
`ev-00000000000000000000000000000001`, delivery
`dl-00000000000000000000000000000002` and body `{"a":1}`, the signed bytes are

```text
v1\n1700000000\nev-00000000000000000000000000000001\ndl-00000000000000000000000000000002\n{"a":1}
```

and the header is
`v1;kid=k1;sig=e864a4d1937ac9e4c08f2978561fad6a7a1257cd29725f8be27260b69b89a48e`.

A receiver checks that the timestamp is within five minutes of its clock,
recomputes the MAC from the raw body (never a re-serialized one), compares it
in constant time with each entry, and records the event IDs it processed.
Delivery is at least once: a response that was lost is retried with the same
event and delivery IDs and a fresh timestamp and signature, so the receiver
must deduplicate by event ID. A signature proves the sender holds the
subscription's key, not that the workload is healthy.
[`cluster/examples/lifecycle-webhook-receiver/Receiver.hs`](../../cluster/examples/lifecycle-webhook-receiver/Receiver.hs)
is a complete receiver that does all of this.

Only a 2xx response acknowledges. 408, 429 and 5xx are retried, honouring
`Retry-After`; other 3xx and 4xx fail for good. A timeout or a broken response
may have been received and is retried. At most ten attempts are made within 24
hours, ten seconds apart at first and doubling up to an hour. Redirects are
not followed and at most 64 KiB of a response is read. Events may arrive out of
order; a retry can overtake a later event.

## Inspect and replay

```bash
nagarectl events subscription list
nagarectl events delivery list deploys
nagarectl events delivery inspect dl-...
```

Each takes `--contract 1` for its document (`subscription-list`,
`delivery-list`, `delivery`). The admin API serves the same state, read only,
at `/v1/events/subscriptions`, `/v1/events/deliveries?subscription=NAME` and
`/v1/events/deliveries/{deliveryId}`, whatever the transport. A delivery is
`pending`, `in-flight`, `acknowledged`, `failed`, `exhausted` or `cancelled`,
with each attempt's outcome.

To send a failed or exhausted event again:

```bash
nagarectl events delivery replay deploys --event ev-... --save-plan ./replay
nagarectl inventory apply ./replay --yes
```

The replay is a new delivery cycle of the same event under the subscription's
current revision; applying the same review again creates no other. It repeats
no deployment or backup. Whether a repeated delivery causes repeated work is
the receiver's decision.
