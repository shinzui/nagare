---
id: 80
slug: messaging-broker-docs-examples-and-tansu-migration-readiness
title: "Messaging broker docs examples and Tansu migration readiness"
kind: exec-plan
created_at: 2026-06-21T15:31:24Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# Messaging broker docs examples and Tansu migration readiness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan finishes the messaging broker initiative by making it usable and maintainable. After it
lands, a developer can read the user docs, provision a Redpanda-backed broker, deploy a worker or app
that uses a topic, produce a test message, watch the worker consume it, and inspect broker health in
Grafana. The docs also explain how the v1 Redpanda provider is intentionally shaped so a future Tansu
provider can replace it without changing application config.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add user documentation for broker provisioning, topic binding, and operational commands.
- [x] M2: Add a working broker producer/consumer example under `cluster/examples/`.
- [x] M3: Add observability and troubleshooting docs.
- [x] M4: Add Tansu migration readiness notes and provider contract checklist.
- [x] M5: Run docs/example validation and update reference indexes.

Update 2026-06-21: EP-80 is complete. `docs/user/messaging-brokers.md` now explains broker
provisioning, topic bindings, generated env, sizing, observability, cleanup, and Tansu migration
readiness. It is linked from `docs/user/README.md` and `docs/user/reference.md`.
`docs/user/troubleshooting.md` covers broker readiness, missing metrics, missing topics, advertised
listener mistakes, and storage pressure. `cluster/examples/broker-worker/` now contains a broker
config, a worker config, and a README. The worker uses the Redpanda image's `rpk` as a minimal
consumer, so the example has no custom build step.

Live validation created broker `events` from `cluster/examples/broker-worker/nagare/Broker.hs`,
deployed worker `broker-worker`, produced `hello from nagare` to topic `jobs`, and saw the worker log
the message. Cleanup deleted the worker Deployment, broker StatefulSet/Service, and retained PVC;
`broker list --namespace personal` returned `(no managed brokers)`.

Final validation 2026-06-21:

- `cabal test nagare-dsl-test` from `cli/nagare-dsl` passed: 343 tests.
- `cabal test nagarectl-test` from `cli/nagarectl` passed: 315 tests.
- `cabal run exe:nagarectl -- broker create redpanda events --config ../../cluster/examples/broker-worker/nagare/Broker.hs --dry-run` passed.
- Live `broker create`, `worker deploy --dry-run`, `worker deploy`, produce, log verification, and cleanup passed.
- `nix fmt ...` could not run because the flake does not provide `formatter.aarch64-darwin`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-21: A broker-bound worker dry-run is not a pure offline render. It resolves live broker and
  topic state before rendering generated env, so the docs now say to create the broker first and then
  use worker `--dry-run`.

- 2026-06-21: `webWorker` validates an untagged image repository and pairs it with `PrebuiltImage
  latest`. The broker-worker example needs Redpanda's pinned tag, so it constructs `Worker` directly
  with `image = docker.redpanda.com/redpandadata/redpanda` and `build = PrebuiltImage v26.1.8`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Document Tansu as a future provider, not an alternative v1 install path.
  Rationale: The user wants to switch to Tansu once it matures. Presenting it as a current supported
  provider would overstate the implementation.
  Date: 2026-06-21

- Decision: Use the Redpanda image's bundled `rpk` CLI for the broker-worker example.
  Rationale: It gives a real Kafka-compatible consumer/producer example without adding a custom image,
  package manager, or client-library dependency to the repo.
  Date: 2026-06-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-80 is complete. The messaging broker feature now has user-facing docs, reference links, a working
producer/consumer example, troubleshooting coverage, and a concrete Tansu compatibility checklist. The
example proves the full workflow: provision broker/topic, deploy a worker bound by logical names,
receive generated env, produce a message, observe consumption, and clean up retained storage.


## Context and Orientation

User docs live in `docs/user/`. Existing examples live in `cluster/examples/`, with a `README.md` and
`nagare/Config.hs` per example. The worker docs at `docs/user/workers.md` and the managed database
docs at `docs/user/managed-databases.md` are the closest style references: they explain concepts,
show a typed config, show a `nagarectl` command, and include verification commands.

The new docs should assume the user knows Nagare basics but not Kafka. Define a broker, topic,
producer, consumer, and bootstrap server in plain English. Keep Redpanda provider details in a
provider section so the main usage docs read as Nagare broker docs.


## Plan of Work

M1 adds `docs/user/messaging-brokers.md` and links it from `docs/user/README.md` and
`docs/user/reference.md`. Cover:

- what Nagare brokers are for;
- `nagarectl broker create/list/get/restart/delete`;
- typed broker config and topic config;
- workload topic bindings and generated env;
- retention/resource caveats for a single-node broker;
- a sizing section showing the small default profile and a larger GCP-instance profile with increased
  CPU, memory, Redpanda `smp`, Redpanda memory, storage, partitions, and retention; and
- when to use a worker versus a service.

M2 adds `cluster/examples/broker-worker/`. The example should include a broker config, a worker config
binding to a topic, and a small app that consumes from Kafka using a widely available client for the
example language. Keep the app minimal and deterministic. If a producer example is separate, add
`cluster/examples/broker-producer/` or include a `README` command that uses `rpk`.

M3 updates observability docs. Add broker dashboard and metric troubleshooting to
`docs/user/observability.md` and `docs/user/troubleshooting.md`.

M4 adds a Tansu migration readiness section. It should describe the future provider contract:
Kafka-compatible bootstrap, internal-only listener, topic create/list, durable storage, Prometheus
metrics, and generated env compatibility. Include facts researched on 2026-06-21: Tansu is a
Kafka-compatible broker with PostgreSQL, SQLite/libSQL, S3, and memory storage engines, and exposes a
Prometheus listener option. Do not promise that Nagare supports Tansu until a later implementation
plan lands.

M5 validates docs and examples. Run the dry-run commands in the example README and any available docs
link checks. If a live cluster is available, run the end-to-end example and capture the transcript.


## Concrete Steps

Run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
rg -n "managed databases|workers|observability" docs/user cluster/examples
```

After docs and examples are added:

```bash
nagarectl broker create redpanda events --dry-run
nagarectl worker deploy -f cluster/examples/broker-worker/nagare/Config.hs --dry-run
```

Expected docs example output should show generated broker env:

```text
KAFKA_BOOTSTRAP_SERVERS=events.personal.svc.cluster.local:9092
NAGARE_TOPIC_JOBS=jobs
```

If live validation is possible:

```bash
nagarectl broker create redpanda events
nagarectl worker deploy -f cluster/examples/broker-worker/nagare/Config.hs
```


## Validation and Acceptance

Acceptance requires:

- `docs/user/messaging-brokers.md` exists and is linked from user doc indexes;
- example configs compile and dry-run;
- the docs explain generated env names and do not require users to copy Kubernetes service DNS by
  hand;
- the docs explain how larger-instance users configure broker resources without editing generated
  manifests;
- observability docs explain where to find broker dashboards and what to check when metrics are
  missing;
- troubleshooting covers broker pod not ready, bad advertised listener, missing topic, and storage
  pressure; and
- Tansu is documented as the planned future provider with a concrete compatibility checklist.


## Idempotence and Recovery

Docs edits are safe to repeat. Example live runs should use a disposable namespace or clearly named
broker. Cleanup commands must be included in the example README:

```bash
nagarectl broker delete events --namespace personal
kubectl delete deployment broker-worker -n personal
```

If deletion preserves PVCs by design, the docs must say how to inspect and remove them only when the
user intends to lose broker data.


## Interfaces and Dependencies

Files likely touched:

- `docs/user/messaging-brokers.md`
- `docs/user/README.md`
- `docs/user/reference.md`
- `docs/user/observability.md`
- `docs/user/troubleshooting.md`
- `cluster/examples/broker-worker/README.md`
- `cluster/examples/broker-worker/nagare/Config.hs`

This plan depends on EP-77, EP-78, and EP-79 because it documents behavior they implement. It should
not invent commands or env variables that those plans did not ship.


## Revision Notes

2026-06-21: Completed EP-80 by adding messaging broker user docs, reference links, troubleshooting,
the broker-worker producer/consumer example, Tansu migration readiness notes, and live example
validation.
