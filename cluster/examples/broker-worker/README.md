# broker-worker

This example provisions a Redpanda-backed Nagare broker named `events`, creates a
topic named `jobs`, and deploys a headless worker that receives generated
Kafka-compatible environment variables:

- `KAFKA_BOOTSTRAP_SERVERS`
- `KAFKA_SECURITY_PROTOCOL`
- `NAGARE_BROKER_NAME`
- `NAGARE_TOPIC_JOBS`

The worker image is Redpanda itself so the example can use the bundled `rpk`
tool as a tiny consumer without building a custom image.

## Render the broker plan

```bash
nagarectl broker create redpanda events \
  --config cluster/examples/broker-worker/nagare/Broker.hs \
  --dry-run
```

That command needs no cluster changes. The worker dry-run does need a live
broker because Nagare resolves broker/topic bindings before rendering generated
env:

```bash
nagarectl broker create redpanda events \
  --config cluster/examples/broker-worker/nagare/Broker.hs

nagarectl worker deploy \
  -f cluster/examples/broker-worker/nagare/Config.hs \
  --dry-run
```

The worker dry-run must show env entries like:

```text
KAFKA_BOOTSTRAP_SERVERS=events.personal.svc.cluster.local:9092
NAGARE_TOPIC_JOBS=jobs
```

The worker binding does not create the broker or topic. It only declares which
live broker/topic names must be resolved before deploy or dry-run.

## Live Run

```bash
nagarectl broker create redpanda events \
  --config cluster/examples/broker-worker/nagare/Broker.hs

nagarectl worker deploy \
  -f cluster/examples/broker-worker/nagare/Config.hs
```

Produce a message through the broker pod:

```bash
printf 'hello from nagare\n' | kubectl exec -i -n personal pod/events-0 -- \
  rpk topic produce jobs -X brokers=events.personal.svc.cluster.local:9092
```

Watch the worker consume:

```bash
kubectl logs deploy/broker-worker -n personal --tail=40
```

Inspect health and metrics:

```bash
nagarectl broker get events --namespace personal
```

Grafana loads the `Nagare Brokers` dashboard from
`cluster/observability/grafana/dashboards/nagare-brokers.json` after
`just observability`.

## Cleanup

```bash
kubectl delete deployment broker-worker -n personal --ignore-not-found=true
nagarectl broker delete events --namespace personal --yes
kubectl delete pvc nagare-broker-events-data -n personal --ignore-not-found=true
```

`broker delete` keeps the PVC by design. Delete the PVC only when you intend to
lose broker data.
