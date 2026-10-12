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

Full plan before trimming: [75-broker-substrate-spike-and-kafka-compatible-provider-contract.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/75-broker-substrate-spike-and-kafka-compatible-provider-contract.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

  `gcloud auth list` shows an active operator account, and `gcloud config list`
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

