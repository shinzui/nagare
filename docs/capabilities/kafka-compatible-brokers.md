---
title: "Kafka-compatible brokers"
type: Capability
description: "Provision and operate a single-node Redpanda broker, declare topics and bindings, and inject Kafka-compatible connection settings into workloads."
generated:
  by: codex/gpt-5
  at: "2026-08-25T20:51:44Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-25T20:51:44Z"
    document_timestamp: "2026-08-25T20:51:44Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the capability, compatibility promise, and repository evidence for inclusion in
      the version 0.1.0 Nix release.
verified:
  by: process:openai-codex
  at: "2026-08-25T20:51:44Z"
capabilityId: CAP-15
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Broker"
  - "nagarectl broker list|create|get|restart|delete"
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/Spec.hs
    proves: Broker validation, loading, StatefulSet, Service, PVC, and topic rendering are tested.
  - kind: test
    resource: cli/nagarectl/test/Spec.hs
    proves: Broker creation plans, topic plans, discovery, connection environment, and health parsing are tested.
  - kind: example
    resource: cluster/examples/broker-worker/nagare/Config.hs
    proves: A shipped worker binds to a declared broker and topic.
  - kind: guide
    resource: docs/user/messaging-brokers.md
    proves: Broker lifecycle, topics, workload binding, credentials, and health inspection are documented.
---

# Kafka-compatible brokers

The broker model renders a Redpanda StatefulSet, persistent storage, Service, configuration, and
declared topics. Workloads bind by logical broker and topic names and receive Kafka-compatible
connection settings. The CLI creates, inspects, restarts, lists, and deletes broker instances, and
the observability stack includes broker scrape and dashboard assets.

## Limits

- Only the Redpanda provider is implemented. The Tansu shape described in planning material is not a
  capability and is not claimed here.
- The broker is single-node and non-HA, matching Nagare's personal-platform scope.
- Broker behavior is proven through rendering and fixture-based health parsing; a live failure and
  recovery drill is not part of the default CI suite.
