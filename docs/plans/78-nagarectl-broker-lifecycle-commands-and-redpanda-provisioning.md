---
id: 78
slug: nagarectl-broker-lifecycle-commands-and-redpanda-provisioning
title: "nagarectl broker lifecycle commands and Redpanda provisioning"
kind: exec-plan
created_at: 2026-06-21T15:31:20Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# nagarectl broker lifecycle commands and Redpanda provisioning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [78-nagarectl-broker-lifecycle-commands-and-redpanda-provisioning.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/78-nagarectl-broker-lifecycle-commands-and-redpanda-provisioning.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This plan turns the typed broker model from EP-76 into an operational CLI. After it lands, a user can
run `nagarectl broker create redpanda events`, wait for a single internal Redpanda broker to become
ready, create declared topics, list brokers, inspect one broker, restart it, and delete it without
hand-writing Kubernetes manifests.

The behavior is Redpanda-specific in implementation but provider-neutral in CLI shape. Commands use
the noun `broker`, labels use `nagare.dev/broker`, and connection details are expressed as Kafka
bootstrap servers. That keeps the future Tansu provider from needing a new user-facing model.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `broker` command parser and library module stubs to `nagarectl`. Started 2026-06-21 after EP-76 completed.
- [x] M2: Implement idempotent Redpanda create/apply/wait using EP-76 renderer output.
- [x] M3: Implement topic creation and reconciliation for declared topics.
- [x] M4: Implement list, get, restart, and delete commands with label-based discovery.
- [x] M5: Add dry-run output, tests, and live acceptance transcript.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-21: `nagare-dsl` defaults are already `Redpanda` `v26.1.8` and broker runtime memory `1G`,
  so `nagarectl` tests should assert through `defaultBrokerVersion` and `defaultBrokerSizing` rather
  than copy stale version or sizing literals.

- 2026-06-21: The local workstation's default kubectl context is still `sennari`, so live EP-78
  acceptance used the documented VM path. A direct IAP tunnel to port `6443` failed because k3s is
  bound to localhost on `nagare-01`; the successful acceptance used a temporary `kubectl` wrapper that
  forwarded commands through `scripts/iap-ssh.sh ssh nagare-01 -- sudo k3s kubectl ...` and streamed
  `kubectl apply -f <local-temp-file>` over stdin.

## Decision Log

Record every decision made while working on the plan.

- Decision: Put CLI implementation in `Nagare.Broker.*` library modules, not in `app/Main.hs`.
  Rationale: Recent work extracted deploy behavior into library modules so tests can call it without
  going through the executable. Broker lifecycle should follow that pattern.
  Date: 2026-06-21

- Decision: Expose topic creation from flags as `--topic TOPIC`, `--topic-partitions N`, and
  `--topic-retention-ms MS`, while still supporting richer topic declarations through `--config`.
  Rationale: The original plan required CLI control over topic partitions and retention. A repeated
  explicit topic-name flag avoids implicit topic naming and maps cleanly to EP-76's `BrokerTopic`
  model. The Redpanda implementation uses `rpk topic create --if-not-exists` followed by
  `rpk topic describe` compatibility checks so an existing incompatible topic fails loudly.
  Date: 2026-06-21

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-78 completed on 2026-06-21. `nagarectl broker create redpanda NAME` can build a typed `Broker`
from flags or load one from `--config`, render EP-76 manifests, dry-run them, apply them, annotate the
StatefulSet, wait for rollout, and reconcile declared topics. `broker list`, `broker get`, `broker
restart`, and `broker delete` use the shared `nagare.dev/broker` labels and preserve PVC data by
default. Live acceptance on the Nagare k3s cluster created broker `events` in namespace `broker-live`,
created topic `jobs`, produced and consumed `ep78-live-ok`, restarted the broker, consumed the same
record again, and removed the disposable namespace.

