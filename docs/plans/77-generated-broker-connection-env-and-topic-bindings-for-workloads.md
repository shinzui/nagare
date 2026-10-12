---
id: 77
slug: generated-broker-connection-env-and-topic-bindings-for-workloads
title: "Generated broker connection env and topic bindings for workloads"
kind: exec-plan
created_at: 2026-06-21T15:31:05Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# Generated broker connection env and topic bindings for workloads

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [77-generated-broker-connection-env-and-topic-bindings-for-workloads.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/77-generated-broker-connection-env-and-topic-bindings-for-workloads.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This plan lets Nagare workloads consume the broker without hard-coding service names or topic strings.
After it lands, a web service, worker, or multi-workload `Application` can declare that it uses broker
`events` and topic `jobs`; `nagarectl deploy`, `nagarectl worker deploy`, and `nagarectl app deploy`
resolve the broker and inject runtime environment variables such as `KAFKA_BOOTSTRAP_SERVERS` and
`NAGARE_TOPIC_JOBS`.

The goal is a provider-neutral workload contract. App code should depend on Kafka-compatible client
settings and topic names, not on Redpanda. When Tansu becomes the provider, these env names remain
stable.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add typed broker/topic binding fields to `Deployment`, `Worker`, and `Application`.
- [x] M2: Round-trip bindings through JSON emit/load with backward-compatible empty defaults.
- [x] M3: Implement broker discovery and generated env assembly in `nagarectl`.
- [x] M4: Wire generated env into deploy, worker deploy, and app deploy paths.
- [x] M5: Add tests and a dry-run example proving env injection.

Update 2026-06-21: M1/M2 landed as a DSL-only slice. `BrokerName`, `TopicName`, and
`BrokerBinding` now live in `Nagare.Dsl.Broker.Types` and are re-exported by `Nagare.Dsl.Broker`.
`Deployment`, `Worker`, and `Application` each have `brokers :: [BrokerBinding]`; JSON emit/load
round-trips the field, and omitted `brokers` decodes as `[]`.

Validation 2026-06-21:

- `fourmolu --mode inplace` passed for the edited `nagare-dsl` source and test modules.
- `cabal test nagare-dsl-test` from `cli/nagare-dsl` passed: 342 tests.
- `nix fmt cli/nagare-dsl` failed because the flake does not provide
  `formatter.aarch64-darwin`.

Update 2026-06-21: M3/M4 landed as a `nagarectl` runtime slice. `Nagare.Broker.Connection` resolves
broker bindings to ready broker rows, validates requested topics with `rpk topic describe`, assembles
Kafka-compatible env (`KAFKA_BOOTSTRAP_SERVERS`, `KAFKA_SECURITY_PROTOCOL`, `NAGARE_BROKER_NAME`,
`NAGARE_TOPIC_*`), and rejects incompatible multi-broker bootstrap collisions. Single-service deploy,
worker deploy, and app deploy merge the generated broker env before rendering.

Validation 2026-06-21:

- `fourmolu --mode inplace` passed for the edited `nagarectl` source and test modules.
- `cabal test nagarectl-test` from `cli/nagarectl` passed: 311 tests.
- `nix fmt cli/nagarectl` failed because the flake does not provide
  `formatter.aarch64-darwin`.

Update 2026-06-21: M5 completed. `cluster/examples/broker-worker/nagare/Config.hs` is a
config-as-program worker example with `BrokerBinding { name = events, topics = [jobs] }`.
`nagare-dsl-test` loads that example and compares the typed binding. Live dry-run acceptance used a
temporary Redpanda broker named `events` in namespace `personal`, reconciled topic `jobs`, rendered
the broker-worker dry-run manifest, and then deleted the broker StatefulSet, Service, and PVC.

The dry-run evidence contained the required generated env:

```yaml
env:
- name: KAFKA_BOOTSTRAP_SERVERS
  value: events.personal.svc.cluster.local:9092
- name: KAFKA_SECURITY_PROTOCOL
  value: PLAINTEXT
- name: NAGARE_BROKER_NAME
  value: events
- name: NAGARE_TOPIC_JOBS
  value: jobs
```

Final validation 2026-06-21:

- `fourmolu --mode inplace cluster/examples/broker-worker/nagare/Config.hs cli/nagare-dsl/test/WorkerSpec.hs` passed.
- `cabal test nagare-dsl-test` from `cli/nagare-dsl` passed: 343 tests.
- `cabal test nagarectl-test` from `cli/nagarectl` passed: 311 tests.
- Live dry-run command passed:

```bash
PATH=/tmp/nagare-kubectl-ep77:$PATH cabal run exe:nagarectl -- worker deploy -f ../../cluster/examples/broker-worker/nagare/Config.hs --dry-run
```

- Cleanup passed: `broker delete events --namespace personal --yes`, PVC
  `nagare-broker-events-data` deletion, and `broker list --namespace personal` returned
  `(no managed brokers)`.
- `nix fmt cli/nagare-dsl cli/nagarectl` failed because the flake does not provide
  `formatter.aarch64-darwin`.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Splitting `BrokerBinding` out of `Nagare.Dsl.Broker` was necessary to avoid an import cycle:
  `Deployment` lives in `Nagare.Dsl.Types`, while `Nagare.Dsl.Broker` already imports
  `Nagare.Dsl.Types` for broker resource fields.
- The project convention for new records is strict, unprefixed fields with `deriving stock
  (Generic, ...)`; the binding shape uses `BrokerBinding { name, topics }`, not prefixed field names.
- Dry-run deploy now resolves broker bindings before rendering, so a dry-run example with bindings
  requires a live managed broker and topics in the target namespace. A missing broker/topic fails
  before manifest output, matching the acceptance requirement.
- Live M5 validation used the same temporary `kubectl` wrapper approach as EP-78 because the local
  kubectl context is `sennari`; Nagare cluster operations must go through the VM's
  `sudo k3s kubectl`.

## Decision Log

Record every decision made while working on the plan.

- Decision: Use Kafka-compatible env names for generated connection settings.
  Rationale: The user wants Redpanda now and Tansu later. `KAFKA_BOOTSTRAP_SERVERS` is the stable
  application-facing contract across both providers.
  Date: 2026-06-21

- Decision: Put broker leaf reference types in `Nagare.Dsl.Broker.Types` and re-export them from
  `Nagare.Dsl.Broker`.
  Rationale: Workload records need `BrokerBinding`, but the full broker resource module depends on
  workload leaf types from `Nagare.Dsl.Types`; a leaf module keeps the typed API without a cycle.
  Date: 2026-06-21

- Decision: Validate requested topics during deploy resolution by executing `rpk topic describe`
  inside the broker pod.
  Rationale: A binding should fail before rendering/applying manifests when the referenced topic does
  not exist or is not reachable, and EP-78 already proved `rpk` inside the Redpanda pod as the topic
  management surface.
  Date: 2026-06-21

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-77 is complete. Workloads can now declare provider-neutral broker/topic bindings in typed config,
round-trip them through JSON, resolve the referenced live broker and topics at deploy time, and
receive Kafka-compatible runtime env without hard-coding service DNS. The implemented contract covers
single-service deploys, worker deploys, and application deploys. The broker-worker example and live
dry-run prove the user-visible behavior. The remaining formatter caveat is repository-level:
`nix fmt` cannot run on this host until the flake provides `formatter.aarch64-darwin`.

