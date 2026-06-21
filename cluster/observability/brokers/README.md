# Nagare Broker Observability

Nagare treats broker observability as a provider-neutral contract. Providers may
export different raw metric names, but dashboards and CLI health checks should
answer the same questions:

- broker up: can VictoriaMetrics scrape the broker metrics endpoint?
- readiness: is the broker pod Ready?
- storage: how much disk is used or available for broker data?
- topic activity: are produce and consume bytes or records changing?
- topic inventory: how many topics and partitions exist?
- consumer lag: are consumers falling behind, when the provider exposes lag?

## Redpanda v1 Mapping

Redpanda exposes Prometheus-format public metrics on the Admin API port
`9644` at `/public_metrics`. Nagare scrapes that endpoint from broker Services
selected by:

```yaml
nagare.dev/managed-by: nagarectl
nagare.dev/broker: <broker-name>
```

The `VMServiceScrape` in this directory maps Kubernetes discovery labels into
normal Prometheus labels:

- `nagare_broker`
- `nagare_broker_provider`
- `kubernetes_namespace`
- `kubernetes_service`

Dashboard concepts use these Redpanda public metrics where available:

| Nagare concept | Redpanda metric |
| --- | --- |
| Broker up | `up{job="nagare-brokers"}` |
| Topic count | `count(count by (nagare_broker, redpanda_topic) (redpanda_kafka_partitions))` |
| Partition count | `sum(redpanda_kafka_partitions)` |
| Produce/consume throughput | `rate(redpanda_kafka_request_bytes_total[5m])` split by `redpanda_request` |
| Consumer lag | `redpanda_kafka_consumer_group_lag_sum` when consumer lag metrics are enabled |
| Broker uptime | `redpanda_application_uptime_seconds_total` |

Redpanda exports consumer lag only after enabling consumer group metrics with
the `consumer_lag` property. Until then, the lag panel is expected to be empty.

## Tansu Requirements

A future Tansu provider satisfies the same Nagare contract by exposing
Prometheus-format metrics over HTTP and letting Nagare scrape them from a
Kubernetes Service with the same Nagare labels. The provider mapping must
identify equivalents for broker up, topic count, partition count,
produce/consume throughput, storage usage, and consumer lag if available.
