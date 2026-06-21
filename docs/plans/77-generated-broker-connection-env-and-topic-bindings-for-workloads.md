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
- [ ] M3: Implement broker discovery and generated env assembly in `nagarectl`.
- [ ] M4: Wire generated env into deploy, worker deploy, and app deploy paths.
- [ ] M5: Add tests and a dry-run example proving env injection.

Update 2026-06-21: M1/M2 landed as a DSL-only slice. `BrokerName`, `TopicName`, and
`BrokerBinding` now live in `Nagare.Dsl.Broker.Types` and are re-exported by `Nagare.Dsl.Broker`.
`Deployment`, `Worker`, and `Application` each have `brokers :: [BrokerBinding]`; JSON emit/load
round-trips the field, and omitted `brokers` decodes as `[]`.

Validation 2026-06-21:

- `fourmolu --mode inplace` passed for the edited `nagare-dsl` source and test modules.
- `cabal test nagare-dsl-test` from `cli/nagare-dsl` passed: 342 tests.
- `nix fmt cli/nagare-dsl` failed because the flake does not provide
  `formatter.aarch64-darwin`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Splitting `BrokerBinding` out of `Nagare.Dsl.Broker` was necessary to avoid an import cycle:
  `Deployment` lives in `Nagare.Dsl.Types`, while `Nagare.Dsl.Broker` already imports
  `Nagare.Dsl.Types` for broker resource fields.
- The project convention for new records is strict, unprefixed fields with `deriving stock
  (Generic, ...)`; the binding shape uses `BrokerBinding { name, topics }`, not prefixed field names.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Workload types live in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` (`Deployment`),
`cli/nagare-dsl/src/Nagare/Dsl/Worker.hs` (`Worker`), and
`cli/nagare-dsl/src/Nagare/Dsl/Application.hs` (`Application`). Their JSON wire shape is in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, and decoding is in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`.

Generated environment variables already exist. `cli/nagarectl/src/Nagare/Env/Generated.hs` builds
`NAGARE_*` identity env, and `cli/nagarectl/src/Nagare/Database/Connection.hs` plus
`cli/nagarectl/src/Nagare/Deploy/Resolve.hs` resolve database references into runtime env maps. This
plan should mirror the database approach: typed references in DSL, cluster lookup at deploy time, then
merge generated env into the workload env before rendering.

A **binding** in this plan means "this workload consumes this logical broker/topic." A binding is not
a client library and does not create application code. It gives app code the connection settings and
topic names it needs.


## Plan of Work

M1 adds type fields. Define `BrokerBinding` in `Nagare.Dsl.Broker` or a small
`Nagare.Dsl.Broker.Binding` module:

```haskell
data BrokerBinding = BrokerBinding
  { name :: BrokerName
  , topics :: [TopicName]
  }
```

Add `brokers :: [BrokerBinding]` to `Deployment` and `Worker`. For `Application`, decide whether the
aggregate declares broker bindings once and fans them down, or each embedded workload carries its own
bindings. Prefer a shared application field if it matches the existing `appDatabases` pattern.

M2 updates JSON emit/load. Existing configs must remain source-compatible except for full record
literals in tests, which need `brokers = []`. Omitted JSON fields must decode as empty lists.

M3 adds `cli/nagarectl/src/Nagare/Broker/Discover.hs` and `Connection.hs`. Discovery should read
labeled broker resources and return a provider-neutral identity: provider, namespace, bootstrap
servers, and known topics. Generated env for a binding must include:

```text
KAFKA_BOOTSTRAP_SERVERS=<internal-service>:9092
KAFKA_SECURITY_PROTOCOL=PLAINTEXT
NAGARE_BROKER_NAME=<broker>
NAGARE_TOPIC_<NORMALIZED_TOPIC>=<topic>
```

M4 wires env into existing deploy paths. Update `Nagare.Deploy.Resolve` with a broker resolver similar
to `resolveConnectionEnv`. Update single-service deploy in `Main.hs`, worker deploy in
`Nagare.Worker.Deploy`, and app deploy in `Nagare.App.Deploy`.

M5 tests conflicts and dry-run output. Two bindings that attempt to set incompatible
`KAFKA_BOOTSTRAP_SERVERS` should fail with a clear error unless the plan intentionally supports only
one broker per workload in v1.


## Concrete Steps

Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
mori show --full
cabal test nagare-dsl-test
cabal test nagarectl-test
```

After implementation:

```bash
nix fmt cli/nagare-dsl cli/nagarectl
cabal test nagare-dsl-test
cabal test nagarectl-test
```

Dry-run validation should resemble:

```bash
nagarectl worker deploy -f cluster/examples/broker-worker/nagare/Config.hs --dry-run
```

Expected rendered env excerpt:

```yaml
env:
  - name: KAFKA_BOOTSTRAP_SERVERS
    value: events.personal.svc.cluster.local:9092
  - name: NAGARE_TOPIC_JOBS
    value: jobs
```


## Validation and Acceptance

Acceptance requires:

- `Deployment`, `Worker`, and `Application` config fixtures round-trip broker bindings;
- old fixtures with no broker binding decode to empty bindings;
- generated env uses stable Kafka-compatible names;
- deploy fails with a clear error when the referenced broker or topic does not exist;
- dry-run output for a worker with a topic binding contains the bootstrap and topic env variables;
- all existing golden tests either remain unchanged or change only where this plan explicitly adds
  `brokers = []` / env output.


## Idempotence and Recovery

This plan does not create broker resources. Deploy commands remain idempotent: resolving broker state
and injecting env can be repeated safely. If generated env conflicts with user-specified env, fail
before applying any manifests and tell the user which variable conflicts.


## Interfaces and Dependencies

Expected new or changed modules:

- `Nagare.Dsl.Broker` or `Nagare.Dsl.Broker.Binding` for `BrokerBinding`
- `Nagare.Broker.Discover`
- `Nagare.Broker.Connection`
- `Nagare.Deploy.Resolve`
- `Nagare.Worker.Deploy`
- `Nagare.App.Deploy`

Expected signatures:

```haskell
data BrokerBinding = BrokerBinding { name :: BrokerName, topics :: [TopicName] }

data BrokerConn = BrokerConn
  { brokerProvider :: BrokerProvider
  , brokerBootstrapServers :: Text
  , brokerTopics :: [TopicName]
  }

lookupBrokerConnection :: Text -> Text -> IO (Either Text BrokerConn)
brokerConnectionEnv :: BrokerBinding -> BrokerConn -> Either Text (Map EnvName ScopedEnvVar)
mergeBrokerConnectionEnvs :: [Map EnvName ScopedEnvVar] -> Either Text (Map EnvName ScopedEnvVar)
resolveBrokerEnv :: Namespace -> [BrokerBinding] -> IO (Map EnvName ScopedEnvVar)
```
