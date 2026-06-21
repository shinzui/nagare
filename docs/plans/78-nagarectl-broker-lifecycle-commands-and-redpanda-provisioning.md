---
id: 78
slug: nagarectl-broker-lifecycle-commands-and-redpanda-provisioning
title: "nagarectl broker lifecycle commands and Redpanda provisioning"
kind: exec-plan
created_at: 2026-06-21T15:31:20Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# nagarectl broker lifecycle commands and Redpanda provisioning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan turns the typed broker model from EP-76 into an operational CLI. After it lands, a user can
run `nagarectl broker create redpanda events`, wait for a single internal Redpanda broker to become
ready, create declared topics, list brokers, inspect one broker, restart it, and delete it without
hand-writing Kubernetes manifests.

The behavior is Redpanda-specific in implementation but provider-neutral in CLI shape. Commands use
the noun `broker`, labels use `nagare.dev/broker`, and connection details are expressed as Kafka
bootstrap servers. That keeps the future Tansu provider from needing a new user-facing model.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `broker` command parser and library module stubs to `nagarectl`. Started 2026-06-21 after EP-76 completed.
- [x] M2: Implement idempotent Redpanda create/apply/wait using EP-76 renderer output.
- [x] M3: Implement topic creation and reconciliation for declared topics.
- [x] M4: Implement list, get, restart, and delete commands with label-based discovery.
- [x] M5: Add dry-run output, tests, and live acceptance transcript.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-21: `nagare-dsl` defaults are already `Redpanda` `v26.1.8` and broker runtime memory `1G`,
  so `nagarectl` tests should assert through `defaultBrokerVersion` and `defaultBrokerSizing` rather
  than copy stale version or sizing literals.

- 2026-06-21: The local workstation's default kubectl context is still `sennari`, so live EP-78
  acceptance used the documented VM path. A direct IAP tunnel to port `6443` failed because k3s is
  bound to localhost on `nagare-01`; the successful acceptance used a temporary `kubectl` wrapper that
  forwarded commands through `scripts/iap-ssh.sh ssh nagare-01 -- sudo k3s kubectl ...` and streamed
  `kubectl apply -f <local-temp-file>` over stdin.


## Decision Log

Record every decision made while working on the plan.

- Decision: Put CLI implementation in `Nagare.Broker.*` library modules, not in `app/Main.hs`.
  Rationale: Recent work extracted deploy behavior into library modules so tests can call it without
  going through the executable. Broker lifecycle should follow that pattern.
  Date: 2026-06-21

- Decision: Expose topic creation from flags as `--topic TOPIC`, `--topic-partitions N`, and
  `--topic-retention-ms MS`, while still supporting richer topic declarations through `--config`.
  Rationale: The original plan required CLI control over topic partitions and retention. A repeated
  explicit topic-name flag avoids implicit topic naming and maps cleanly to EP-76's `BrokerTopic`
  model. The Redpanda implementation uses `rpk topic create --if-not-exists` followed by
  `rpk topic describe` compatibility checks so an existing incompatible topic fails loudly.
  Date: 2026-06-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-78 completed on 2026-06-21. `nagarectl broker create redpanda NAME` can build a typed `Broker`
from flags or load one from `--config`, render EP-76 manifests, dry-run them, apply them, annotate the
StatefulSet, wait for rollout, and reconcile declared topics. `broker list`, `broker get`, `broker
restart`, and `broker delete` use the shared `nagare.dev/broker` labels and preserve PVC data by
default. Live acceptance on the Nagare k3s cluster created broker `events` in namespace `broker-live`,
created topic `jobs`, produced and consumed `ep78-live-ok`, restarted the broker, consumed the same
record again, and removed the disposable namespace.


## Context and Orientation

`cli/nagarectl/app/Main.hs` owns command-line parsing. It already contains command groups for
databases (`DbCommand`), tasks (`TaskCommand`), workers (`WorkerCommand`), storage, app deploy, and
CDN. The implementation should keep parsing in `Main.hs` but place broker behavior in library modules
under `cli/nagarectl/src/Nagare/Broker/`.

Use managed databases as the closest operational template:

- `cli/nagarectl/src/Nagare/Database/Create.hs` builds a typed desired resource, applies manifests,
  and waits for rollout.
- `cli/nagarectl/src/Nagare/Database/List.hs`, `Get.hs`, `Restart.hs`, and `Delete.hs` discover
  resources by labels.
- `cli/nagarectl/src/Nagare/Deploy.hs` contains shared Kubernetes apply and wait helpers.

Do not expose the broker to the public internet. The initial service is internal ClusterIP only.
Kafka-compatible external access is deferred because it requires advertised listener and security
work beyond "messaging inside the cluster."


## Plan of Work

M1 adds command parsing in `cli/nagarectl/app/Main.hs`. Add a `BrokerCommand` sum type with:

```text
nagarectl broker create redpanda NAME [--namespace personal] [--version VERSION] [--size SIZE] [--cpu CPU] [--memory MEMORY] [--config FILE] [--dry-run]
nagarectl broker list [--namespace personal]
nagarectl broker get NAME [--namespace personal]
nagarectl broker restart NAME [--namespace personal]
nagarectl broker delete NAME [--namespace personal] [--yes]
```

The create command must also expose provider sizing flags for users on larger instances:

```text
--redpanda-smp N
--redpanda-memory SIZE
--topic-partitions N
--topic-retention SIZE_OR_DURATION
```

Exact flag names may change during implementation, but the capability must exist. The default profile
targets Nagare's small VM; explicit flags or `--config` override it for larger GCP instances.

M2 adds `cli/nagarectl/src/Nagare/Broker/Create.hs`. It loads a `Broker` from `--config` or builds one
from flags using EP-76 smart constructors, renders manifests, applies them, and waits for readiness.
The implementation must be idempotent: re-running create updates manifests and does not delete the PVC
or topic data.

M3 adds topic reconciliation. If the `Broker` contains topics, the create path must run provider
commands after the broker is ready. For Redpanda this can use an `rpk` invocation in the broker pod or
a short-lived client pod, whichever EP-75 proves reliable. Topic creation should be create-if-missing
and should fail loudly if an existing topic has incompatible partitions or retention.

M4 adds discovery modules. `list` and `get` read Kubernetes resources labeled
`nagare.dev/broker=<name>`. `restart` deletes or rolls the provider pod in a controlled way and waits
for readiness. `delete` removes provider resources but must default to preserving data unless an
explicit destructive flag is introduced and documented.

M5 adds tests and dry-run output. Unit tests should cover pure command planning and rendered dry-run
text. Live acceptance can be a transcript against the disposable namespace from EP-75 or a new
`broker-live` namespace.


## Concrete Steps

Run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
mori show --full
cabal test nagarectl-test
```

After implementation:

```bash
nix fmt cli/nagarectl cli/nagare-dsl
cabal test nagare-dsl-test
cabal test nagarectl-test
```

Dry-run acceptance:

```bash
nagarectl broker create redpanda events --namespace personal --size 5Gi --dry-run
nagarectl broker create redpanda events --namespace personal --size 5Gi --topic jobs --topic-partitions 3 --topic-retention-ms 86400000 --dry-run
nagarectl broker create redpanda events --namespace personal --size 100Gi --cpu 2 --memory 5Gi --redpanda-smp 2 --redpanda-memory 4G --dry-run
```

Expected dry-run output should include a broker manifest header, the internal Service DNS or bootstrap
address, and a statement that no cluster changes were applied.

Live acceptance:

```bash
nagarectl broker create redpanda events --namespace broker-live --size 5Gi --topic jobs --topic-partitions 1 --topic-retention-ms 86400000
nagarectl broker list --namespace broker-live
nagarectl broker get events --namespace broker-live
nagarectl broker restart events --namespace broker-live
kubectl exec -n broker-live pod/events-0 -- /usr/bin/rpk topic consume jobs --offset 0 -n 1 -f '%v' -X brokers=events.broker-live.svc.cluster.local:9092
```


## Validation and Acceptance

Acceptance requires:

- `nagarectl broker create redpanda events --dry-run` prints deterministic manifests and no side
  effects;
- creating a broker in a test namespace reaches ready;
- declared topics exist after create;
- `broker list` shows the broker name, provider, namespace, ready status, bootstrap address, and
  storage size;
- `broker get events` shows provider, version, bootstrap servers, topics, PVC, and pod status;
- a larger-instance dry run shows the requested CPU, memory, Redpanda runtime memory, and storage size
  in the rendered plan;
- `broker restart events` returns after the broker is ready again and topic data still exists; and
- tests pass for `nagare-dsl-test` and `nagarectl-test`.

Validation so far:

- 2026-06-21: `fourmolu --mode inplace` on touched `nagarectl` Haskell files passed.
- 2026-06-21: `cabal test nagarectl-test` from `cli/nagarectl` passed with 303 tests, including
  `Nagare.Broker (EP-78)` coverage for broker construction defaults, Redpanda sizing flags, label
  selectors, StatefulSet JSON discovery, image-version fallback, malformed JSON handling, and table
  formatting.
- 2026-06-21: `fourmolu --mode inplace` on touched `nagarectl` Haskell files passed after adding topic
  reconciliation. `nix fmt cli/nagarectl cli/nagare-dsl` failed because the flake still does not
  provide `formatter.aarch64-darwin`.
- 2026-06-21: `cabal test nagarectl-test` from `cli/nagarectl` passed with 307 tests, adding coverage
  for CLI topic construction, `rpk topic create` argument construction, `rpk topic describe` parsing,
  and rendered dry-run topic plans.
- 2026-06-21: `cabal test nagare-dsl-test` from `cli/nagare-dsl` passed with 339 tests.
- 2026-06-21: Dry-run acceptance passed for
  `cabal run exe:nagarectl -- broker create redpanda events --namespace personal --size 5Gi --topic jobs --topic-partitions 3 --topic-retention-ms 86400000 --dry-run`.
  Output included PVC, Service, StatefulSet manifests, `Would reconcile topics: jobs partitions=3
  replicationFactor=1 retentionMs=86400000`, bootstrap
  `events.personal.svc.cluster.local:9092`, and `No cluster changes were applied.`
- 2026-06-21: Larger-instance dry-run acceptance passed for
  `cabal run exe:nagarectl -- broker create redpanda events --namespace personal --size 100Gi --cpu 2 --memory 5Gi --redpanda-smp 2 --redpanda-memory 4G --dry-run`.
  Output showed PVC storage `100Gi`, Redpanda `--smp '2'`, Redpanda `--memory 4G`, and container
  resource limits `cpu: '2'` and `memory: 5Gi`.
- 2026-06-21: Live acceptance passed in disposable namespace `broker-live` on the Nagare k3s cluster
  through the VM `sudo k3s kubectl` path. `nagarectl broker create redpanda events --namespace
  broker-live --size 5Gi --topic jobs --topic-partitions 1 --topic-retention-ms 86400000` applied the
  PVC, Service, and StatefulSet, waited for rollout, printed `Reconciled topic jobs`, and reported
  `Created broker events at events.broker-live.svc.cluster.local:9092`. `broker list` showed
  `events redpanda v26.1.8 5Gi Ready events.broker-live.svc.cluster.local:9092`. `broker get` showed
  provider, version, bootstrap, PVC, and Ready `True`. `rpk topic describe jobs` showed `PARTITIONS 1`,
  `REPLICAS 1`, and dynamic `retention.ms 86400000`. Producing and consuming `ep78-live-ok` succeeded
  before restart; after `nagarectl broker restart events --namespace broker-live`, consuming offset 0
  returned `ep78-live-ok` again. `nagarectl broker delete events --namespace broker-live --yes`
  removed StatefulSet and Service while retaining the PVC, and `kubectl delete namespace broker-live
  --wait=true` removed the disposable namespace; `kubectl get namespace broker-live` returned
  `NotFound`.


## Idempotence and Recovery

Create and restart must be safe to repeat. Delete is the risky command. Require an explicit
confirmation mechanism for deletion and document whether PVCs are retained. If live testing fails,
remove only the test namespace:

```bash
kubectl delete namespace broker-live --wait=true
```

Never delete shared namespaces or unlabeled PVCs.


## Interfaces and Dependencies

New `nagarectl` modules:

- `Nagare.Broker.Create`
- `Nagare.Broker.List`
- `Nagare.Broker.Get`
- `Nagare.Broker.Restart`
- `Nagare.Broker.Delete`
- `Nagare.Broker.Topic`

Expected library entry points:

```haskell
data BrokerCreateParams = BrokerCreateParams { ... }
runBrokerCreate :: BrokerProvider -> Text -> BrokerCreateParams -> IO ()
runBrokerList :: Text -> IO ()
runBrokerGet :: Text -> Text -> IO ()
runBrokerRestart :: Text -> Text -> IO ()
runBrokerDelete :: BrokerDeleteParams -> IO ()
reconcileBrokerTopics :: Broker -> IO ()
```

The implementation depends on EP-76's `Nagare.Dsl.Broker` and `Nagare.Dsl.Broker.Render`. It may use
Redpanda's `rpk` CLI inside Kubernetes for topic management if EP-75 validates that path. It must not
depend on Haskell Kafka client libraries unless topic operations cannot be done safely through
provider CLI tools; if a library is needed, use Mori to inspect `hw-kafka-client` or the relevant
local package source first.


## Revision Notes

2026-06-21: Completed EP-78 by adding Redpanda topic reconciliation, explicit topic CLI flags,
focused unit tests, dry-run verification, live `broker-live` acceptance, and final plan/master-plan
status updates.
