---
type: Term
title: messaging broker
description: A Nagare-operated stateful process that hosts named Kafka-compatible topics for application messages.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-34
status: current
tags: [data-recovery]
anchors:
  - kind: doc
    resource: docs/user/messaging-brokers.md
---

# messaging broker

A Nagare-operated stateful process that hosts named Kafka-compatible topics for application messages. Redpanda is the current provider. The broker is internal, has a durable PVC, and exposes a bootstrap server to bound workloads.

See [Messaging brokers](../../docs/user/messaging-brokers.md) for the full contract and operating procedure.
