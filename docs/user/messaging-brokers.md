# Messaging brokers

> **Status:** Working for Redpanda-backed, single-node, in-cluster brokers.

Nagare brokers are internal Kafka-compatible message brokers for workers and
services that need asynchronous work: queues, event streams, fan-out, or
background processors.

A **broker** is the long-running stateful process. A **topic** is a named stream
inside that broker. A **producer** writes messages to a topic. A **consumer**
reads messages from a topic. A **bootstrap server** is the broker address Kafka
clients use first; clients then learn the broker's advertised listener from the
broker itself.

Nagare's user-facing contract is provider-neutral:

- provision a broker by name;
- create topics by name;
- bind workloads to broker/topic names;
- receive generated Kafka-compatible environment variables at deploy time; and
- inspect health and metrics through `nagarectl broker get` and Grafana.

Redpanda is the v1 provider. Tansu is reserved as a future provider; see
[Tansu migration readiness](#tansu-migration-readiness).

## Provision a broker

The smallest useful broker:

```bash
nagarectl broker create redpanda events \
  --namespace personal \
  --topic jobs \
  --topic-partitions 1 \
  --topic-retention-ms 86400000
```

This creates a single-replica StatefulSet, a ClusterIP Service, a durable
`local-path` PVC, and topic `jobs`. The broker is internal only:

```text
events.personal.svc.cluster.local:9092
```

Useful commands:

```text
nagarectl broker list [--namespace personal]
nagarectl broker get NAME [--namespace personal]
nagarectl broker restart NAME [--namespace personal]
nagarectl broker delete NAME [--namespace personal] [--yes]
```

`broker delete` removes the StatefulSet and Service but keeps the PVC by default
so data is not destroyed accidentally. Delete the PVC only when you intend to
lose broker data:

```bash
kubectl delete pvc nagare-broker-events-data -n personal
```

## Typed broker config

Use a checked-in config when you want broker shape and topics reviewed with the
app:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as Text
import Nagare.Dsl.Broker
import Nagare.Dsl.Config (emitBroker)
import Nagare.Dsl.Types (mkNamespace, mkQuantity)

broker :: Broker
broker =
  Broker
    { name = unsafe (mkBrokerName "events")
    , provider = Redpanda
    , version = unsafe (mkBrokerVersion Redpanda "v26.1.8")
    , namespace = unsafe (mkNamespace "personal")
    , storageSize = unsafe (mkQuantity "5Gi")
    , sizing = defaultBrokerSizing
    , topics =
        [ unsafe
            (mkBrokerTopic (unsafe (mkTopicName "jobs")) 1 1 (Just 86400000))
        ]
    }

main :: IO ()
main = emitBroker broker

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error (Text.unpack e)
```

Create from the config:

```bash
nagarectl broker create redpanda events \
  --config cluster/examples/broker-worker/nagare/Broker.hs
```

## Bind a workload to a topic

Workloads declare broker/topic names, not Kubernetes DNS:

```haskell
brokers =
  [ BrokerBinding
      { name = unsafe (mkBrokerName "events")
      , topics = [unsafe (mkTopicName "jobs")]
      }
  ]
```

At deploy time, Nagare resolves the live broker and topic and injects:

| Env var | Meaning |
| --- | --- |
| `KAFKA_BOOTSTRAP_SERVERS` | Broker bootstrap address, e.g. `events.personal.svc.cluster.local:9092` |
| `KAFKA_SECURITY_PROTOCOL` | `PLAINTEXT` for the internal v1 broker |
| `NAGARE_BROKER_NAME` | Logical broker name, e.g. `events` |
| `NAGARE_TOPIC_JOBS` | Logical topic name, e.g. `jobs` |

If a broker or topic is missing, deploy fails before rendering a misleading
manifest. This is deliberate: the config says the workload depends on that
broker contract. The same check runs for `--dry-run`, so a broker-bound workload
dry-run also needs the referenced broker and topics to exist.

## Worker or service?

Use a **worker** when the process must run continuously, such as a queue
consumer. Workers render to `apps/v1` Deployments and never scale to zero.

Use a **service** when the process handles HTTP requests and can scale with
traffic. Services render to Knative Services and can still publish or consume
messages during request handling.

See [Running workers](workers.md) for the worker model and
[`cluster/examples/broker-worker`](../../cluster/examples/broker-worker) for a
complete broker plus worker example.

## Sizing

The default profile is intentionally small for Nagare's current single-node VM:
one broker, one replica, `5Gi` storage by default in CLI examples, Redpanda
`smp=1`, and modest process memory. This is enough for personal queues and
small streams, not high availability.

Larger VM example:

```bash
nagarectl broker create redpanda events \
  --namespace personal \
  --size 100Gi \
  --cpu 2 \
  --memory 5Gi \
  --redpanda-smp 2 \
  --redpanda-memory 4G \
  --topic jobs \
  --topic-partitions 3 \
  --topic-retention-ms 604800000
```

These flags change the generated Kubernetes resources and Redpanda runtime
settings without editing manifests by hand.

## Observability

Run `just observability` to install or update the Victoria stack. It applies the
broker scrape config and loads the `Nagare Brokers` Grafana dashboard.

CLI health does not require Grafana:

```bash
nagarectl broker get events --namespace personal
```

Expected health lines:

```text
Health:
  OK      readiness         pod/events-0 Ready
  OK      metrics endpoint  /public_metrics reachable
  OK      metrics scrape    VictoriaMetrics has up=1 for this broker
```

If metrics are missing, check [Troubleshooting](troubleshooting.md#broker-metrics-are-missing).

## Tansu migration readiness

Tansu is not a supported Nagare provider yet. It is documented here so v1
Redpanda choices do not block the future switch.

As of the 2026-06-21 research pass, Tansu describes itself as a stateless
Kafka-compatible broker with PostgreSQL, libSQL/SQLite, S3, and memory storage
engines. Its broker options include Kafka listener and advertised-listener URLs,
a storage-engine URL, topic CLI support, produce/consume helpers, and a
Prometheus listener option.

For Nagare to add a `Tansu` provider later, it must satisfy this checklist:

- Kafka-compatible bootstrap from inside the cluster;
- internal-only listener by default;
- advertised listener that resolves from Nagare workloads;
- topic create/delete/list or describe commands Nagare can run idempotently;
- durable storage configuration appropriate for the chosen Tansu storage engine;
- Prometheus-format metrics reachable through a Nagare-labelled Service;
- mapping to the `Nagare Brokers` dashboard concepts; and
- no change to workload config or generated env names.

Application configs should continue to say "broker `events`, topic `jobs`."
Provider-specific details belong in the broker provider implementation, not in
workload config.
