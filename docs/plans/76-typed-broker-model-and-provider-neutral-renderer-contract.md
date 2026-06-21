---
id: 76
slug: typed-broker-model-and-provider-neutral-renderer-contract
title: "Typed Broker model and provider-neutral renderer contract"
kind: exec-plan
created_at: 2026-06-21T15:31:05Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# Typed Broker model and provider-neutral renderer contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds the provider-neutral broker model to `nagare-dsl`. After it lands, a typed
`nagare/Config.hs` can describe a broker and its topics without committing user config to Redpanda
forever. Redpanda is the only implemented provider in v1, but the type has an explicit `Tansu`
provider placeholder and keeps provider-specific options isolated.

The observable behavior is offline and deterministic: `cabal test nagare-dsl-test` passes with tests
that construct valid brokers, reject invalid names and unpinned versions, round-trip broker JSON
through `emitBroker`/`loadBroker`, and render provider-neutral Kubernetes manifests or manifest plans
with stable labels and names. Later plans consume these types for lifecycle commands, workload env
injection, observability, and docs.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `BrokerName`, `TopicName`, `BrokerProvider`, `BrokerTopic`, and `Broker` types with smart constructors.
- [ ] M2: Add `emitBroker`, `encodeBroker`, `loadBroker`, and load-error tests.
- [ ] M3: Add provider-neutral renderer helpers, Redpanda v1 manifest rendering, and golden tests.
- [ ] M4: Export the new modules and integrate them into `Nagare.Dsl.Presets` or docs-friendly helper APIs.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Put broker types in dedicated `Nagare.Dsl.Broker` modules.
  Rationale: Brokers are top-level resources like databases, not fields on a single deployment. A
  dedicated module keeps provider-specific facts out of `Nagare.Dsl.Types`.
  Date: 2026-06-21

- Decision: Reserve `Tansu` in the provider enum before implementing it.
  Rationale: The user explicitly wants to switch to Tansu once mature. A reserved constructor forces
  every later interface to think about provider neutrality while allowing the renderer to reject Tansu
  provisioning until a future plan implements it.
  Date: 2026-06-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`cli/nagare-dsl/` is the Haskell library that app config files import. The existing top-level resource
models are useful templates:

- `cli/nagare-dsl/src/Nagare/Dsl/Database.hs` defines `Engine`, `Database`, version validation, and
  deterministic Secret names.
- `cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` renders StatefulSet, Service, PVC, and optional
  ConfigMap YAML for stateful engines.
- `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` contains `emitDatabase` and `encodeDatabase`, which print
  JSON for `nagarectl` to load.
- `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` decodes each top-level resource kind and rejects the wrong
  kind with a precise error.
- `cli/nagare-dsl/test/Spec.hs` wires unit, load, and golden tests together.

A broker is a top-level resource, not a workload. It should not be modelled as a `Deployment` or
`Worker`, even if the renderer emits Kubernetes workload objects. A topic is also part of the broker
contract. For Kafka-compatible providers, topic names are part of the application interface: a worker
or service must be able to refer to a topic by a typed name and receive that topic name in its runtime
environment.


## Plan of Work

M1 creates `cli/nagare-dsl/src/Nagare/Dsl/Broker.hs`. Define:

- `BrokerName`, validated like `ServiceName`;
- `TopicName`, validated as a conservative Kafka-compatible token: non-empty, no spaces, no slash, no
  colon, and no leading dot;
- `BrokerProvider = Redpanda | Tansu`;
- `BrokerVersion`, rejecting empty and `latest`;
- `BrokerSizing`, carrying Kubernetes `Resources` plus provider-level knobs such as Redpanda core
  count (`smp`) and Redpanda process memory. The small default should be suitable for Nagare's current
  single-node VM, but the type must allow larger GCP instances to request more CPU, memory, and broker
  runtime memory without changing renderer code;
- `TopicRetention` or a simple retention field, with a default suitable for a small node;
- `BrokerTopic`, carrying name, partitions, replication factor, and optional retention;
- `Broker`, carrying broker name, provider, version, namespace, storage size, resources, and topics.

M2 adds JSON encode/load. Extend `Nagare.Dsl.Config` with `emitBroker` and `encodeBroker`. Extend
`Nagare.Dsl.Load` with `loadBroker` and `decodeBroker`. The top-level JSON discriminator is
`"kind": "Broker"`. Add fixtures under `cli/nagare-dsl/test/fixtures/broker/redpanda/nagare/Config.hs`
and tests that `loadDeployment` rejects a broker and `loadBroker` rejects a deployment.

M3 adds `cli/nagare-dsl/src/Nagare/Dsl/Broker/Render.hs`. The renderer should expose pure helpers, not
cluster operations. It must stamp labels `nagare.dev/managed-by`, `nagare.dev/broker`, and
`nagare.dev/broker-provider`. Redpanda rendering may emit raw Kubernetes manifests if EP-75 proves a
simple StatefulSet shape, or a structured "Helm values" manifest plan if EP-75 proves Helm is required.
In either case, tests must pin the provider-neutral names and labels.

M4 exports the modules in `cli/nagare-dsl/nagare-dsl.cabal`, adds tests to `cli/nagare-dsl/test/Spec.hs`,
and optionally adds a small preset helper in `Nagare.Dsl.Presets` if existing style supports it.


## Concrete Steps

Run research commands first:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
mori show --full
mori registry search kafka
```

After edits, format and test:

```bash
nix fmt cli/nagare-dsl
cabal test nagare-dsl-test
```

Expected final test shape:

```text
All <N> tests passed
```

If this repository's preferred command is through `nix develop`, use:

```bash
nix develop -c cabal test nagare-dsl-test
```


## Validation and Acceptance

Acceptance requires:

- compiling `nagare-dsl`;
- tests that reject invalid broker names, topic names, and floating provider versions;
- tests that render both the small default sizing profile and an explicitly larger profile;
- a broker fixture that emits JSON and loads to the same `Broker`;
- wrong-kind tests for broker versus deployment;
- golden output for the Redpanda v1 rendered contract; and
- no unrelated golden changes.

The rendered contract must be provider-neutral in labels and function names. Redpanda-specific values
may appear only in Redpanda branches or provider options.


## Idempotence and Recovery

This plan is pure code and test data. It does not touch a live cluster. Re-running tests is safe. If
goldens change unexpectedly, inspect the diff and update only files whose behavior this plan owns.


## Interfaces and Dependencies

New modules:

- `Nagare.Dsl.Broker`
- `Nagare.Dsl.Broker.Render`

Expected exported functions and types:

```haskell
data BrokerProvider = Redpanda | Tansu
newtype BrokerName = BrokerName Text
newtype TopicName = TopicName Text
newtype BrokerVersion = BrokerVersion Text
data BrokerSizing = BrokerSizing { ... }

mkBrokerName :: Text -> Either Text BrokerName
mkTopicName :: Text -> Either Text TopicName
mkBrokerVersion :: BrokerProvider -> Text -> Either Text BrokerVersion
mkBrokerSizing :: Maybe Quantity -> Maybe Resources -> Maybe Int -> Maybe Quantity -> Either Text BrokerSizing

data BrokerTopic = BrokerTopic { ... }
data Broker = Broker { ... }

brokerNameText :: BrokerName -> Text
topicNameText :: TopicName -> Text
brokerProviderToken :: BrokerProvider -> Text
parseBrokerProvider :: Text -> Maybe BrokerProvider
renderBroker :: Broker -> [ByteString]
brokerServiceName :: Text -> Text
brokerPvcName :: Text -> Text
```

`Nagare.Dsl.Config` must expose:

```haskell
emitBroker :: Broker -> IO ()
encodeBroker :: Broker -> LBS.ByteString
```

`Nagare.Dsl.Load` must expose:

```haskell
loadBroker :: FilePath -> IO (Either LoadError Broker)
decodeBroker :: LBS.ByteString -> Either LoadError Broker
```
