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

- [x] M0 (2026-06-21): Repository and dependency orientation completed. `mori show --full` identified
  this repo as `shinzui/nagare`; `mori registry search kafka` identified local Kafka client libraries
  but the spike still uses `rpk` from Redpanda images rather than adding a Haskell dependency.
- [x] M0 (2026-06-21): Verified the local kubectl context is `sennari`, which is not the Nagare k3s
  cluster. The runbook-confirmed safe path remains the VM path through `scripts/iap-ssh.sh` and
  `sudo k3s kubectl`.
- [x] M0 (2026-06-21): Refreshed the Redpanda Helm repo and pinned the current chart metadata for the
  spike input: `redpanda/redpanda` chart `26.1.6`, app/image `v26.1.8`.
- [x] M1 (2026-06-21): After interactive gcloud reauthentication and VM start, confirmed `nagare-01`
  was `Ready` on k3s `v1.35.4+k3s1`, `local-path` was the default storage class, applied
  `cluster/examples/broker-spike/redpanda.yaml`, and observed one Redpanda pod ready with an internal
  ClusterIP Service and a 5Gi `local-path` PVC.
- [x] M2 (2026-06-21): Verified internal Kafka listener correctness from an in-cluster Redpanda client:
  cluster metadata advertised `redpanda.broker-spike.svc.cluster.local:9092`, topic `jobs` was created,
  `spike-ok` was produced at offset 2, and consuming offset 2 returned exactly `spike-ok`.
- [x] M3 (2026-06-21): Deleted `redpanda-0`; StatefulSet recreated it, the same PVC stayed bound, and
  consuming offset 2 after restart returned `spike-ok`.
- [x] M4 (2026-06-21): Scraped `http://redpanda.broker-spike.svc.cluster.local:9644/public_metrics`
  from the in-cluster client and recorded broker, Kafka, and storage metric families for EP-79.
- [x] M5 (2026-06-21): Reconciled Redpanda findings with the Tansu target contract, updated the
  MasterPlan discoveries, and cleaned up the disposable `broker-spike` namespace.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Live cluster access is blocked before any Redpanda resource was applied.** The documented safe
  command path correctly avoids the local `sennari` kubectl context, but the IAP tunnel cannot open
  until gcloud credentials are refreshed interactively. Evidence:

```text
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl get nodes'

ERROR: (gcloud.compute.start-iap-tunnel) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution.
Please run:

  $ gcloud auth login

to obtain new credentials.
```

  `gcloud auth list` shows active account `nadeem@topagentnetwork.com`, and `gcloud config list`
  shows project `tan-nb-exp`, region `us-west1`, and zone `us-west1-a`. No namespace, PVC, StatefulSet,
  Service, Helm release, or pod was created before this blocker.

- **Current Redpanda Helm defaults require explicit spike overrides.** On 2026-06-21, `helm repo
  update redpanda` and `helm show chart redpanda/redpanda` reported chart `26.1.6` with app version
  `v26.1.8`. The values show defaults that are not Nagare-v1 safe without overrides: `statefulset.replicas`
  defaults to `3`, `external.enabled` defaults to `true`, global `tls.enabled` defaults to `true`, and
  `storage.persistentVolume.size` defaults to `20Gi`. The values also show resource defaults of
  one CPU core and `2.5Gi` container memory. The live spike should start with a single replica,
  internal-only access, and a deliberately small persistent volume before accepting any renderer shape.

- **Official provider documentation confirms the contract boundaries to test live.** Redpanda's
  Kubernetes listener documentation says the Helm chart has an internal Kafka listener for in-cluster
  connections and an external listener for outside-cluster access; Redpanda's monitoring documentation
  says `/public_metrics` on the Admin API port is the primary low-cardinality metrics endpoint. The
  Tansu repository describes an Apache Kafka API-compatible broker with PostgreSQL, libSQL/SQLite, S3,
  and memory storage engines. These sources support keeping Nagare's public contract at the Kafka
  bootstrap/topic/metrics level while treating chart values and Redpanda metrics names as provider
  implementation details.

- **The Redpanda Helm chart is not a good v1 renderer source of truth.** Even after setting
  `external.enabled=false`, `external.service.enabled=false`, and disabling the Kafka/Admin external
  listeners, the rendered chart still retained a second advertised Kafka address in the generated
  configurator script and kept REST/schema external container ports. For the spike, a raw manifest was
  clearer and closer to Nagare's eventual renderer shape: one standalone PVC, one internal ClusterIP
  Service, one single-replica StatefulSet, no public Service, and an explicit advertised Kafka address.

- **The Redpanda image entrypoint is `rpk`, not a shell.** A `kubectl run ... -- rpk cluster info`
  invocation becomes `rpk rpk cluster info` and fails. For reusable client work, run the same image
  with `--command -- /bin/bash -lc "sleep 3600"` and then execute `rpk` commands inside it.

- **`rpk topic produce` requires careful format quoting through nested shells.** A brittle
  `--format` invocation split `hello-redpanda` into two records (`hello-redpa` and `da`). The reliable
  form used in the final evidence was:

```bash
printf "spike-ok\n" | rpk topic produce jobs -f "%v\n" -X brokers=redpanda.broker-spike.svc.cluster.local:9092
```

- **A raw single-broker Redpanda manifest works on Nagare's single-node cluster.** The verified
  manifest is committed at `cluster/examples/broker-spike/redpanda.yaml`. It uses Redpanda `v26.1.8`,
  `--smp 1`, `--memory 1G`, `--reserve-memory 0M`, `--overprovisioned`, a 5Gi standalone
  `local-path` PVC named `redpanda-data`, internal bootstrap
  `redpanda.broker-spike.svc.cluster.local:9092`, and Admin API port `9644`.


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

- Decision: Treat the Redpanda Helm chart as the live spike vehicle, but do not let chart defaults
  define Nagare's contract.
  Rationale: The current chart is easy to pin and inspect (`26.1.6` / app `v26.1.8`), but its defaults
  include three replicas, external access, TLS, and a 20Gi persistent volume. Nagare v1 needs a
  single-node, internal-only, low-resource broker contract, so the spike must override these values and
  record the resulting Kubernetes shape before EP-76 writes a renderer.
  Date: 2026-06-21

- Decision: Stop before live mutation when IAP SSH requires gcloud reauthentication.
  Rationale: The runbook warns that the workstation's default kubectl context targets an unrelated
  cluster. Because `scripts/iap-ssh.sh` could not open the IAP tunnel without `gcloud auth login`, any
  attempt to use local kubectl would risk applying broker resources to the wrong cluster.
  Date: 2026-06-21

- Decision: Use a raw Kubernetes manifest for the spike and keep Helm as research input only.
  Rationale: The Helm chart is useful for version and default discovery, but its generated shape kept
  provider-specific sidecars and external-listener assumptions that are not part of Nagare's v1
  internal-only broker contract. The raw manifest is smaller, auditable, and closer to the renderer
  EP-76 should implement.
  Date: 2026-06-21

- Decision: Use the stable ClusterIP Service DNS name as the v1 advertised Kafka bootstrap address.
  Rationale: In a single-broker internal-only deployment, clients should not need a pod ordinal. The
  live client saw broker metadata for `redpanda.broker-spike.svc.cluster.local:9092` and successfully
  produced and consumed through that address.
  Date: 2026-06-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-75 completed on 2026-06-21. The spike proved that Redpanda `v26.1.8` can run as a single
StatefulSet-backed broker on Nagare's single-node k3s cluster with a standalone `local-path` PVC and
an internal ClusterIP Service. A client pod created topic `jobs`, produced `spike-ok`, consumed it
through the advertised internal bootstrap address, and consumed the same record after deleting and
recreating the broker pod. The Admin API `/public_metrics` endpoint is scrapeable from inside the
cluster and exposes enough broker, Kafka, and storage metrics for EP-79.

The main lesson is that the Redpanda Helm chart is too provider-shaped to serve as Nagare's first
renderer contract. EP-76 should encode the raw, provider-neutral Kubernetes shape proven here and keep
Redpanda-specific flags behind provider options. Future Tansu support must satisfy the same user-facing
contract: an internal Kafka bootstrap address, deterministic topic operations, durable storage through
its selected storage engine, and Prometheus-compatible broker health metrics.


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

Current resume point as of 2026-06-21: run `gcloud auth login` interactively for
`nadeem@topagentnetwork.com`, then continue through the VM path rather than local kubectl:

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 \
  scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl get nodes'
```

Do not proceed if the local context is still `sennari` and the VM path is unavailable.

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

As of 2026-06-21, the Helm chart input to verify is:

```text
redpanda/redpanda chart: 26.1.6
Redpanda app/image: v26.1.8
Defaults requiring spike overrides: statefulset.replicas=3, external.enabled=true, tls.enabled=true, storage.persistentVolume.size=20Gi
```

The live spike should render or apply values equivalent to single replica, internal-only access, and a
small persistent volume, then record the actual generated Service, StatefulSet, PVC, and advertised
Kafka listener before EP-76 relies on them.

The working spike used the committed raw manifest instead of Helm:

```bash
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl apply -f -' < cluster/examples/broker-spike/redpanda.yaml
```

The cluster accepted the namespace, standalone PVC, internal Service, and StatefulSet:

```text
namespace/broker-spike created
persistentvolumeclaim/redpanda-data created
service/redpanda created
statefulset.apps/redpanda created
```

Readiness and storage evidence:

```text
NAME             READY   STATUS              RESTARTS   AGE
pod/redpanda-0   0/1     ContainerCreating   0          8s

NAME               TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)             AGE
service/redpanda   ClusterIP   10.43.45.243   <none>        9092/TCP,9644/TCP   8s

NAME                                  STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/redpanda-data   Bound    pvc-8d9218aa-12d0-497e-a6fa-b06814d0b17c   5Gi        RWO            local-path     8s

partitioned roll out complete: 1 new pods have been updated...
```

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

Actual Kafka protocol evidence used `spike-ok` as the sentinel value. Cluster metadata advertised the
internal Service DNS, not a public address:

```text
CLUSTER
redpanda.83631107-f13d-484b-85cf-d69150317e92

BROKERS
ID    HOST                                     PORT
0*    redpanda.broker-spike.svc.cluster.local  9092

TOPIC  STATUS
jobs   OK
```

The final produce and consume proof was:

```text
Produced to partition 0 at offset 2 with timestamp 1782058430369.
{
  "topic": "jobs",
  "value": "spike-ok",
  "timestamp": 1782058430369,
  "partition": 0,
  "offset": 2
}
```

For restart durability:

```bash
kubectl -n broker-spike delete pod redpanda-0
kubectl -n broker-spike rollout status statefulset/redpanda --watch
```

Then consume or list offsets again and record the result.

The restart proof was:

```text
pod "redpanda-0" deleted from broker-spike namespace
Waiting for 1 pods to be ready...
partitioned roll out complete: 1 new pods have been updated...

NAME                READY   STATUS    RESTARTS   AGE
pod/broker-client   1/1     Running   0          2m20s
pod/redpanda-0      1/1     Running   0          6s

NAME                                  STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/redpanda-data   Bound    pvc-8d9218aa-12d0-497e-a6fa-b06814d0b17c   5Gi        RWO            local-path     5m15s

{
  "topic": "jobs",
  "value": "spike-ok",
  "timestamp": 1782058430369,
  "partition": 0,
  "offset": 2
}
```

The metrics proof was:

```text
# HELP redpanda_application_build Redpanda build information
redpanda_application_build{redpanda_revision="c7962c091d86f51435f38ef443173344c4e94287",redpanda_version="v26.1.8"} 1.000000
# HELP redpanda_cluster_brokers Number of configured brokers in the cluster
redpanda_cluster_brokers{} 1.000000
# HELP redpanda_cluster_topics Number of topics in the cluster
redpanda_cluster_topics{} 2.000000
# HELP redpanda_cluster_unavailable_partitions Number of partitions that lack quorum among replicants
redpanda_cluster_unavailable_partitions{} 0.000000
# HELP redpanda_kafka_records_fetched_total Total number of records fetched
# HELP redpanda_kafka_records_produced_total Total number of records produced
# HELP redpanda_kafka_request_latency_seconds Internal latency of kafka produce requests
# HELP redpanda_kafka_under_replicated_replicas Number of under replicated replicas (i.e. replicas that are live, but not at the latest offest)
# HELP redpanda_storage_disk_free_bytes Disk storage bytes free.
# HELP redpanda_storage_disk_total_bytes Total size of attached storage, in bytes.
```

Cleanup evidence:

```text
namespace "broker-spike" deleted
Error from server (NotFound): namespaces "broker-spike" not found
```


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

Verified contract for downstream plans:

| Contract point | EP-75 evidence | Downstream implication |
|---|---|---|
| Provider | Redpanda `v26.1.8` works as the first provider. Tansu is not registered in Mori; upstream Tansu docs describe an Apache Kafka API-compatible broker with PostgreSQL, libSQL/SQLite, S3, and memory storage engines. | EP-76 should define `Redpanda` now and reserve `Tansu`; provider-specific process/storage flags stay behind provider options. |
| Kubernetes shape | Single-replica StatefulSet, standalone 5Gi `local-path` PVC, internal ClusterIP Service, no public Service. | EP-76 should render this small raw shape rather than shelling out to the Helm chart. |
| Bootstrap address | `redpanda.broker-spike.svc.cluster.local:9092` was advertised in Kafka metadata and used for produce/consume. | EP-77 should inject `KAFKA_BOOTSTRAP_SERVERS` using the broker Service DNS, not a pod ordinal and not a Redpanda-specific variable. |
| Topic operations | `rpk topic create jobs`, `rpk topic produce`, and `rpk topic consume` worked from an in-cluster client. | EP-78 can implement topic create/list/delete with provider-specific commands behind Nagare's topic model. |
| Durability | `spike-ok` survived deleting `redpanda-0` and consuming the same offset after StatefulSet recovery. | EP-76/EP-78 should keep PVC ownership explicit and must not default to `emptyDir`. |
| Observability | `/public_metrics` on Admin port `9644` exposed broker, Kafka, and storage metric families. | EP-79 should scrape the provider Admin metrics endpoint and normalize dashboard panels around broker count, topic/partition health, produce/fetch records, request latency, under-replicated replicas, and disk free/total. |


## Revision Notes

2026-06-21: Implemented EP-75 on the live Nagare cluster, added the verified raw Redpanda spike
manifest, recorded command evidence for startup, topic operations, restart persistence, metrics, and
cleanup, and converted the plan's downstream contract from provisional assumptions into verified
facts.
