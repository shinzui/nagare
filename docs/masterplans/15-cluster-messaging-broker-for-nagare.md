---
id: 15
slug: cluster-messaging-broker-for-nagare
title: "Cluster Messaging Broker for Nagare"
kind: master-plan
created_at: 2026-06-21T15:30:56Z
intention: "intention_01kvncmnzweearjz953y6besqc"
---

# Cluster Messaging Broker for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Nagare can currently run HTTP services, static sites, workers, scheduled tasks, durable volumes, and
managed databases, but it has no first-class in-cluster message broker. A developer can write a
long-running worker that says it consumes a queue, but the platform does not provision the queueing
substrate, create topics, inject broker connection settings, or surface broker health in Grafana. This
initiative adds that missing messaging layer while preserving Nagare's single-node, low-resource
operating model.

The first implementation provider is **Redpanda**, because it is Kafka API compatible, runs as a
single broker, and avoids the ZooKeeper footprint of traditional Kafka. The long-term provider is
**Tansu** once it is mature enough for Nagare's use: as of the research for this plan on 2026-06-21,
the Tansu repository describes a stateless Kafka-compatible broker with PostgreSQL, SQLite/libSQL, S3,
and memory storage engines; its broker exposes Kafka listener settings and a Prometheus metrics
listener. The abstraction boundary is therefore the **Kafka protocol and Nagare's own broker contract**,
not Redpanda-specific command output. A Nagare app should declare "I use broker `events` and topic
`jobs`"; Redpanda is the provider behind that contract in v1, and Tansu can replace it later by
implementing the same contract.

After the initiative, a developer can:

- provision a single in-cluster messaging broker with `nagarectl broker create redpanda events`;
- declare topics with retention and partition settings in typed config;
- bind a service or worker to topics and receive generated runtime environment variables such as
  `KAFKA_BOOTSTRAP_SERVERS` and per-topic names without hard-coding service DNS;
- inspect, restart, list, and delete broker resources through `nagarectl broker ...`;
- see broker health, throughput, consumer lag, storage, and scrape status through the existing
  VictoriaMetrics and Grafana stack; and
- follow documentation that explicitly says which parts are provider-neutral and which are Redpanda
  implementation details.

What is in scope: a live substrate spike that proves Redpanda works on the single-node k3s cluster and
captures a provider-neutral contract that Tansu can later satisfy; a typed `Broker`/`BrokerTopic`
model in `nagare-dsl`; `nagarectl broker` lifecycle commands for the Redpanda provider; generated
connection env and topic binding for `Deployment`, `Worker`, and `Application` workloads; a broker
observability abstraction that feeds VictoriaMetrics and Grafana without baking Redpanda names into
user-facing docs; explicit broker sizing controls for users running larger GCP instances; and
end-to-end examples. The default profile is intentionally small for Nagare's current single
`e2-standard-2` target, but CPU, memory, Redpanda core count, Redpanda memory, storage size, topic
partitions, retention, and future provider options must be configurable through typed config and CLI
flags so a user who runs a larger VM can give the broker more headroom without forking manifests.

What is out of scope: multi-node broker high availability, cross-zone replication, public internet
exposure for brokers, a general event schema registry product, exactly-once application semantics, a
Tansu production migration in v1, and a UI beyond Grafana dashboards and CLI commands. Tansu support
is planned as a compatibility target and migration-ready interface, not as the initial provider.


## Decomposition Strategy

The initiative is split into six child ExecPlans by functional concern. The split mirrors previous
Nagare initiatives: first prove the substrate, then add typed DSL artifacts, then add lifecycle
operations, then connect workloads, then add observability, then document the end-to-end behavior.

The main design rule is that **provider is a typed dimension, not the public interface**. Redpanda and
Tansu both speak Kafka-compatible client protocols, but they differ in process model, storage, command
line, metrics names, and Kubernetes shape. Those differences belong behind a provider contract. The
Nagare-facing API should talk about brokers, topics, bootstrap servers, topic env names, and
observability capabilities. This is the same pattern the database initiative used for Postgres, Redis,
and ClickHouse: engine/provider-specific facts are data, while the resource, renderer, lifecycle, and
binding APIs are shared.

EP-75 is a live spike because Nagare has never run a broker. A broker is stateful, long-lived, and
protocol-sensitive: a Kafka client receives advertised listener metadata from the broker, so a
Service that merely forwards port 9092 can still fail if the broker advertises a DNS name clients
cannot use. The spike proves internal-only listener settings, persistence, topic creation,
produce/consume, restart behavior, and metrics on the actual cluster before the DSL encodes any
contract.

EP-76 owns the pure type and renderer contract. It does not call the cluster. It adds `Broker`,
`BrokerProvider`, and topic types, plus deterministic Kubernetes manifest renderers and golden tests.
EP-78 owns operational provisioning with Redpanda: CLI parsing, idempotent apply, waits, inspection,
restart, and deletion. EP-77 owns workload consumption: declaring broker/topic bindings on web
services, workers, and applications, resolving live broker state, and injecting environment variables
at deploy time. EP-79 owns the requested observability abstraction, intentionally separate from EP-78
so metrics and dashboards do not become an afterthought in the Redpanda lifecycle code. EP-80 owns the
developer-facing docs, examples, and migration notes for replacing Redpanda with Tansu later.

Alternatives considered and rejected. A single ExecPlan was rejected because the work touches the
cluster substrate, the typed DSL, CLI lifecycle, workload env injection, observability, and docs; one
plan would be too broad and hard to verify. A "just install the Redpanda Helm chart" plan was rejected
as the top-level design because it would expose Redpanda chart values as the Nagare API and make the
Tansu migration harder. A Tansu-first plan was rejected because the user explicitly wants Redpanda now
and Tansu later when it is mature. A provider-specific observability dashboard was rejected because it
would not create the abstraction the user asked for; provider-specific metrics can feed a common
dashboard contract, but the contract must be Nagare-owned.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 75 | Broker substrate spike and Kafka-compatible provider contract | docs/plans/75-broker-substrate-spike-and-kafka-compatible-provider-contract.md | None | None | Not Started |
| 76 | Typed Broker model and provider-neutral renderer contract | docs/plans/76-typed-broker-model-and-provider-neutral-renderer-contract.md | None | EP-75 | Not Started |
| 78 | nagarectl broker lifecycle commands and Redpanda provisioning | docs/plans/78-nagarectl-broker-lifecycle-commands-and-redpanda-provisioning.md | EP-76 | EP-75 | Not Started |
| 77 | Generated broker connection env and topic bindings for workloads | docs/plans/77-generated-broker-connection-env-and-topic-bindings-for-workloads.md | EP-76 | EP-78 | Not Started |
| 79 | Broker observability abstraction dashboards and health checks | docs/plans/79-broker-observability-abstraction-dashboards-and-health-checks.md | EP-76 | EP-75, EP-78 | Not Started |
| 80 | Messaging broker docs examples and Tansu migration readiness | docs/plans/80-messaging-broker-docs-examples-and-tansu-migration-readiness.md | EP-77, EP-78, EP-79 | EP-75 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-75 has no dependencies and is the root evidence plan. It proves which Kubernetes shapes,
listeners, storage settings, resource limits, topic operations, and metrics endpoints are valid on
the live single-node cluster. EP-76 can start without EP-75 as pure design work, but it has a soft
dependency because its rendered shapes must reconcile with the spike evidence before it is complete.

EP-78 has a hard dependency on EP-76 because the CLI provisions `Broker` values and calls the renderer
and naming helpers defined there. EP-77 has a hard dependency on EP-76 because workload records need a
typed field for broker/topic bindings and generated env must use the type names and secret/service
helpers from the model. EP-77 has only a soft dependency on EP-78 because its tests can stub broker
discovery, but live acceptance needs a broker created by `nagarectl broker create`.

EP-79 has a hard dependency on EP-76 because the observability abstraction must use the broker labels,
names, and provider capability fields defined by the model. It has soft dependencies on EP-75 and
EP-78: the spike discovers real metrics and the lifecycle command installs the provider, but the
dashboard and scrape contract can be developed against static fixtures. EP-80 comes last because docs
and examples need the CLI, binding, and observability behavior to be settled.

Parallelism: EP-75 and EP-76 can proceed together if EP-76 treats its renderer as provisional until
the spike settles the exact shapes. EP-77 and EP-79 can proceed in parallel once EP-76 is complete.
EP-80 should wait for EP-77, EP-78, and EP-79.


## Integration Points

- **Provider-neutral broker model.** Defined by EP-76 in new modules under
  `cli/nagare-dsl/src/Nagare/Dsl/Broker.hs` and `cli/nagare-dsl/src/Nagare/Dsl/Broker/Render.hs`.
  Consumed by EP-78, EP-77, EP-79, and EP-80. It must include provider (`Redpanda` now,
  `Tansu` reserved), broker name, namespace, version, storage size, resource settings, listener
  contract, provider sizing options, and topics.

- **Resource labels and names.** Defined by EP-76 and consumed everywhere:
  `nagare.dev/managed-by: nagarectl`, `nagare.dev/broker: <name>`,
  `nagare.dev/broker-provider: <provider>`, and topic labels where Kubernetes resources represent
  topics. Later plans must discover resources by labels first and only use helper functions for
  deterministic names.

- **Connection environment contract.** Defined by EP-77 and consumed by docs/examples. The stable v1
  variables are `KAFKA_BOOTSTRAP_SERVERS`, `KAFKA_SECURITY_PROTOCOL`, `NAGARE_BROKER_NAME`, and
  generated per-topic env names such as `NAGARE_TOPIC_JOBS`. These are intentionally Kafka-protocol
  names, not Redpanda names.

- **Topic ownership contract.** EP-76 defines typed topic declarations; EP-78 creates topics for the
  provider; EP-77 injects topic names into workloads. Topic names must be deterministic and safe for
  Kafka-compatible providers. A later Tansu provider must be able to create the same logical topics.

- **Broker observability abstraction.** EP-79 owns the provider-neutral scrape and dashboard contract
  in `cluster/observability/` and docs. EP-78 may install provider-specific metrics endpoints, but it
  must label them so EP-79 can scrape them through the shared contract.

- **Tansu migration contract.** EP-80 records what must remain provider-neutral for a future Tansu
  implementation: Kafka bootstrap env, topic declarations, internal-only listener, metrics health, and
  storage durability expectations. No v1 user config should need a Redpanda-specific field unless it
  is explicitly namespaced as provider options.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-75: Prove Redpanda starts, persists data, creates topics, produces/consumes, and exports metrics on the live cluster.
- [ ] EP-75: Record the provider-neutral Kafka-compatible contract and Tansu migration implications.
- [ ] EP-76: Add typed broker/topic model, JSON emit/load, renderer helpers, and golden tests.
- [ ] EP-78: Add `nagarectl broker` lifecycle commands backed by Redpanda provisioning.
- [ ] EP-77: Add workload broker/topic bindings and generated runtime env injection.
- [ ] EP-79: Add scrape configuration, Grafana dashboard assets, and health checks through a provider-neutral abstraction.
- [ ] EP-80: Add docs, examples, and a Tansu migration readiness note.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

(None yet.)


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Use Redpanda as the first provider and design the Nagare API around a provider-neutral
  Kafka-compatible broker contract.
  Rationale: The user requested Redpanda first because it is resource-conscious, then Tansu once the
  project matures. Redpanda and Tansu both target Kafka-compatible clients, so the stable Nagare
  contract should be broker/topic/bootstrap abstractions rather than Redpanda chart details.
  Date: 2026-06-21

- Decision: Make broker observability a dedicated child plan rather than a checklist item inside
  Redpanda provisioning.
  Rationale: The user explicitly asked to add "the abstraction on observability." Keeping it separate
  forces a provider-neutral metrics and dashboard contract that a future Tansu provider can satisfy.
  Date: 2026-06-21

- Decision: Keep broker public exposure out of v1.
  Rationale: Nagare's initial messaging need is inside the cluster. Kafka-compatible external access
  requires careful advertised listener design and is a different security and networking problem.
  Date: 2026-06-21

- Decision: Make broker sizing configurable while keeping a small default profile.
  Rationale: The default Nagare VM is resource-constrained, so v1 should default to a single-core,
  low-memory Redpanda profile. Some users will run larger GCP instances and should be able to raise
  CPU, memory, Redpanda `--smp`, Redpanda `--memory`, storage, partitions, and retention through typed
  config or CLI flags instead of editing generated manifests.
  Date: 2026-06-21

- Decision: Proceed without an Intention ID.
  Rationale: The MasterPlan skill asks for an intention prompt through an AskUserQuestion tool, but
  that tool was not available in the active mode. No intention was provided by the user in the request.
  Date: 2026-06-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
