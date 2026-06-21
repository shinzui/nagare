---
id: 75
slug: broker-substrate-spike-and-kafka-compatible-provider-contract
title: "Broker substrate spike and Kafka-compatible provider contract"
kind: exec-plan
created_at: 2026-06-21T15:31:05Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# Broker substrate spike and Kafka-compatible provider contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare has no proven message broker substrate. This plan is the live feasibility spike for MasterPlan
15 (`docs/masterplans/15-cluster-messaging-broker-for-nagare.md`): it proves that a Kafka-compatible
broker can run inside the single-node k3s cluster and records the provider-neutral contract that later
plans must encode. The initial provider is Redpanda. The future provider target is Tansu, which was
researched on 2026-06-21 and describes itself as a stateless Kafka-compatible broker with PostgreSQL,
SQLite/libSQL, S3, and memory storage engines plus a Prometheus metrics listener.

After this plan, a later implementer does not have to guess at listener settings, storage shape,
resource limits, topic commands, or metrics. The plan's output is evidence: Redpanda starts in a
disposable namespace, a topic can be created, a message can be produced and consumed by an in-cluster
client using the broker's advertised internal listener, data survives a broker pod restart, and metrics
are scrapeable. The plan also records the exact compatibility contract that Tansu must satisfy later:
Kafka bootstrap address, topic operations, internal-only networking, durable storage, and metrics.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Establish disposable namespace, storage, resource budget, and Redpanda manifests for a single broker.
- [ ] M2: Verify internal Kafka listener correctness with an in-cluster client, topic creation, produce, and consume.
- [ ] M3: Verify persistence across pod restart and document backup/restore implications.
- [ ] M4: Verify metrics endpoint and record provider-neutral observability facts.
- [ ] M5: Reconcile Redpanda findings with Tansu's known Kafka-compatible contract and update MasterPlan discoveries.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Run this as a spike before writing the final renderer.
  Rationale: Kafka-compatible brokers are sensitive to advertised listener metadata. A Kubernetes
  Service can be reachable while clients still fail if the broker advertises the wrong address. The
  cluster behavior must be proven before EP-76 encodes a renderer.
  Date: 2026-06-21

- Decision: Keep the spike internal-only.
  Rationale: The user asked for messaging inside the cluster. External Kafka access requires
  provider-specific advertised listener and security decisions that are out of scope for v1.
  Date: 2026-06-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository is a personal PaaS. Kubernetes bootstrap manifests live in `cluster/bootstrap/`.
Observability manifests live in `cluster/observability/`. Typed deployment config lives in
`cli/nagare-dsl/`, and operational commands live in `cli/nagarectl/`. Managed databases are the closest
existing stateful pattern: see `cli/nagare-dsl/src/Nagare/Dsl/Database.hs`,
`cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs`, and `cli/nagarectl/src/Nagare/Database/Create.hs`.
The database spike and renderer plans, `docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md`
and `docs/plans/44-typed-database-model-and-stateful-statefulset-service-pvc-and-secret-renderer.md`,
show the house style for proving stateful workloads before encoding them.

A **broker** is a server that accepts messages from producers and lets consumers read them later. A
**topic** is a named stream inside the broker. **Kafka-compatible** means ordinary Kafka clients can
connect using a bootstrap server address such as `events.personal.svc.cluster.local:9092`, ask the
broker for metadata, and then produce or consume messages. The **advertised listener** is the address
the broker returns to clients in metadata; it must be resolvable by pods inside the cluster.

Use Mori before relying on dependency APIs. `mori registry search kafka` shows local Kafka-related
libraries such as `confluentinc/librdkafka`, `haskell-works/hw-kafka-client`,
`shinzui/kafka-effectful`, and `shinzui/shibuya-kafka-adapter`. This spike can use packaged CLI
clients such as `rpk` or `kcat` inside temporary pods; it does not add a Haskell Kafka dependency.


## Plan of Work

M1 creates a disposable namespace such as `broker-spike`, then applies hand-written Redpanda manifests
or a temporary Helm release. Prefer raw manifests if they produce simpler provider-neutral shapes for
EP-76; use Helm only if the Redpanda chart is the only practical way to configure the broker safely.
Record every applied manifest excerpt in this plan.

M2 proves Kafka protocol behavior inside the cluster. Create a topic, produce one message, consume it
from the beginning, and confirm the client connects through the internal bootstrap address. Capture the
exact bootstrap DNS name and listener settings.

M3 proves durability. Delete the broker pod, wait for the StatefulSet to recreate it, and consume the
same message or inspect the topic to confirm data survived. Record the PVC name, storage class, and
cleanup behavior.

M4 proves metrics. Find the Redpanda metrics endpoint, scrape it with `curl` or an in-cluster temporary
pod, and record the metric families that EP-79 should normalize into the Nagare broker dashboard.

M5 maps the findings to the future Tansu contract. Record which contract points are generic Kafka
behavior and which are Redpanda-specific implementation details.


## Concrete Steps

Run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
mori show --full
mori registry search kafka
```

Operate against the intended Nagare cluster. Follow `docs/runbooks/cluster-access.md` if the local
machine cannot reach the k3s API. Use a disposable namespace:

```bash
kubectl create namespace broker-spike
kubectl get storageclass
kubectl get nodes
```

Apply the chosen Redpanda manifests or Helm release. If using Helm during the spike, pin the exact
chart version in the transcript and use values that create one internal broker, one PVC, and no public
external listener:

```bash
helm repo add redpanda https://charts.redpanda.com
helm repo update
helm upgrade --install redpanda redpanda/redpanda \
  --namespace broker-spike \
  --set statefulset.replicas=1
```

The exact values are a spike output, not an input. After install:

```bash
kubectl -n broker-spike get pods,svc,pvc
kubectl -n broker-spike rollout status statefulset/redpanda --watch
```

Use an in-cluster client pod to create and test a topic. Replace the image and command with the
working client chosen during implementation:

```bash
kubectl -n broker-spike run broker-client --rm -it --restart=Never \
  --image=docker.redpanda.com/redpandadata/redpanda:latest -- bash
rpk topic create jobs -X brokers=redpanda.broker-spike.svc.cluster.local:9092
printf 'hello\n' | rpk topic produce jobs -X brokers=redpanda.broker-spike.svc.cluster.local:9092
rpk topic consume jobs --offset start -n 1 -X brokers=redpanda.broker-spike.svc.cluster.local:9092
```

Expected evidence is a consumed message body:

```text
hello
```

For restart durability:

```bash
kubectl -n broker-spike delete pod redpanda-0
kubectl -n broker-spike rollout status statefulset/redpanda --watch
```

Then consume or list offsets again and record the result.


## Validation and Acceptance

Acceptance is evidence in this plan, not shipped code. The plan is complete when it records:

- the exact Redpanda Kubernetes shape that worked on Nagare's cluster;
- the exact internal bootstrap address used by a client pod;
- a successful topic create, produce, and consume transcript;
- a pod restart transcript showing data persists;
- the metrics endpoint and at least three useful broker metrics for EP-79;
- cleanup commands and confirmation that the disposable namespace was removed; and
- a short compatibility table saying which findings apply to future Tansu support.


## Idempotence and Recovery

The spike must use only the disposable `broker-spike` namespace. Recovery is:

```bash
kubectl delete namespace broker-spike --wait=true
```

If a PVC remains because the storage class retains it, inspect it before deletion and record the
manual cleanup. Do not apply spike manifests in `personal`, `monitoring`, `logging`, or `tracing`.


## Interfaces and Dependencies

External provider facts must be verified before implementation. Redpanda's Kubernetes documentation
describes Helm and Operator deployment paths, and its Helm docs describe listener and monitoring
settings. Tansu's repository describes a Kafka-compatible broker with storage-engine options and a
Prometheus listener. Record the exact source versions or page dates used during implementation.

The interface output of this plan is prose and evidence for:

- EP-76's `BrokerProvider` constructors: `Redpanda` now and `Tansu` reserved;
- EP-76's service and PVC naming helpers;
- EP-78's `nagarectl broker create redpanda NAME` behavior;
- EP-77's `KAFKA_BOOTSTRAP_SERVERS` env contract; and
- EP-79's metrics scrape and dashboard contract.
