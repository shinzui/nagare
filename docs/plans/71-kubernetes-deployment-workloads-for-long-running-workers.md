---
id: 71
slug: kubernetes-deployment-workloads-for-long-running-workers
title: "Kubernetes Deployment workloads for long-running workers"
kind: exec-plan
created_at: 2026-06-18T03:57:12Z
intention: "intention_01kvce00njestav4ejj7dbfwea"
---

# Kubernetes Deployment workloads for long-running workers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [71-kubernetes-deployment-workloads-for-long-running-workers.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/71-kubernetes-deployment-workloads-for-long-running-workers.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today nagare can only deploy **request-driven** apps. Every app a user deploys
becomes a **Knative Service** — a Kubernetes object (API group
`serving.knative.dev/v1`) that runs your container *only while HTTP requests are
arriving* and scales it down to zero pods when traffic stops. That is perfect
for a web site or an API, and wrong for a **worker**: a process that is not
driven by incoming HTTP requests but instead runs continuously in the
background — pulling jobs off a queue (Redis, a database table, a message bus),
processing a stream, or running a long polling loop. A Knative Service would
scale such a worker to zero the moment it stopped receiving HTTP requests, which
for a queue consumer is *always*, so the worker would never run. Knative is also
unable to run a process that exposes **no HTTP port at all**, which most workers
do not.

The standard Kubernetes object for "run N copies of this container continuously,
restart them if they crash, and roll them when the image changes" is a plain
**Deployment** (API group `apps/v1`, `kind: Deployment` — note this is the
Kubernetes primitive, *not* nagare's existing Haskell type also called
`Deployment`). nagare does not use it yet. This plan adds a new, first-class
nagare workload type — a **Worker** — that renders to exactly that `apps/v1`
Deployment, plus a `nagarectl worker deploy` command to build, push, and run it.

After this change a user can write a tiny typed config and run a background
worker on their nagare cluster:

```haskell
-- nagare/Config.hs
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Worker (Worker (..), webWorker)

worker :: Either String Worker
worker = do
  base <- webWorker "queue-consumer" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/queue-consumer"
  Right base {replicas = 2}

main :: IO ()
main = case worker of
  Left err -> ioError (userError err)
  Right w -> emitWorker w
```

```text
$ nagarectl worker deploy
Loaded worker queue-consumer (kind=Worker, replicas=2)
Building image ...
Applying apps/v1 Deployment queue-consumer to namespace personal ...
deployment.apps/queue-consumer created
Waiting for rollout ...
deployment "queue-consumer" successfully rolled out
Worker queue-consumer is running (2/2 replicas ready).
```

The user can then prove it is working with stock `kubectl`:

```text
$ kubectl get deployment queue-consumer -n personal
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
queue-consumer   2/2     2            2           30s

$ kubectl get ksvc -n personal
# queue-consumer is NOT listed here — it is a worker, not a Knative Service.
```

Observable outcome: a continuously-running, replica-controlled background
process exists on the cluster, was produced from a typed Haskell config through
the same maximal-safety pattern every other nagare workload uses, and is **not**
a Knative Service (so it does not scale to zero and needs no HTTP port).

The scope is deliberately bounded to make the worker genuinely useful while
staying inside nagare's single-node, deliberately-constrained design:

* A Worker renders to one `apps/v1` Deployment with `replicas` copies and **no**
  Service, Ingress, DomainMapping, or autoscaling — a worker is not reachable
  from outside and is not request-driven.
* It reuses, unchanged, the building blocks the request-driven `Deployment`
  already has: the same `BuildSpec` (prebuilt / Dockerfile / Nixpacks image
  build), the same scoped env model and managed-env `envFrom` contract, the
  same `Resources` (CPU/memory requests and limits), and the same `Volume`
  (durable `local-path` PVC) model.
* It adds the two things a worker needs that a request-driven app does not: an
  explicit **replica count** (how many copies to run) and an optional
  **command/args override** (the process to launch, when the image's default
  entrypoint is not the worker you want).

Out of scope (recorded so a later reader does not expect them): horizontal
autoscaling of workers (the node is single-node; you set a fixed replica count),
exposing a worker via a Service or domain (it is headless by definition),
`StatefulSet` semantics for workers (that is the database path), and multi-node
scheduling.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — Typed `Worker` model.** (2026-06-17) Added
      `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs` (the `Worker` record + `Replicas`
      newtype + `Command` model + `webWorker` preset), exported it from
      `nagare-dsl.cabal`, and added `WorkerSpec` constructor/preset cases.
      `cabal test nagare-dsl-test` passes (285 tests).
- [x] **M2 — Render `Worker` → `apps/v1` Deployment.** (2026-06-17) Added
      `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs` with
      `renderWorker :: Worker -> Text -> [ByteString]`,
      `renderWorkerDeployment`, and `workerDeploymentName`; exported `envField`/
      `envFromField` from `Nagare.Dsl.Render` and reused them. Golden files
      `worker-minimal.deployment.yaml`, `worker-rich.deployment.yaml`,
      `worker-rich.manifests.yaml` generated and read by eye — valid `apps/v1`
      Deployment, `spec.replicas: 2`, matching selector/pod labels, managed
      `envFrom`, command/env/resources/volume blocks, no Service/Knative annotations.
- [x] **M3 — Emit + load round-trip.** (2026-06-17) Added
      `emitWorker`/`encodeWorker` to `Nagare.Dsl.Config` (lifting a shared
      `buildSpecJSON` + `scopedEnvJSON`) and `loadWorker`/`decodeWorker` to
      `Nagare.Dsl.Load` with a `"kind": "Worker"` discriminator. Round-trip and
      kind-guard tests pass (rich + minimal round-trip; Worker↔Deployment kind
      discrimination).
- [x] **M4 — `nagarectl worker deploy` command.** (2026-06-17) Added
      `cli/nagarectl/src/Nagare/Worker/Deploy.hs` (`runWorkerDeploy` /
      `WorkerDeployParams`), `waitForWorkerRollout` to `Nagare.Deploy`, and the
      `Worker WorkerCommand` arm + `worker` subparser + `runWorker` dispatcher in
      `app/Main.hs`. Build/push reuse `Nagare.Build`/`Nagare.Image` and
      `gatherBuildArgs` verbatim; apply via `applyPVCs`+`applyManifests`; gate on
      `waitForWorkerRollout`. `nagarectl worker --help` lists `deploy`;
      `worker deploy --help` shows the options; `cabal build all` and both test
      suites pass (`nagare-dsl-test` 286, `nagarectl-test` 285). A
      config-as-program `loadWorker` fixture test lives in `nagare-dsl-test`
      (which owns the runghc harness).
- [x] **M5 — Example + docs + CI.** (2026-06-17) Added
      `cluster/examples/queue-worker/` (`nagare/Config.hs` using the public
      `helloworld-go` image + a `command` override, `replicas = 2`) and its
      `README.md`; added the `docs/user/workers.md` user guide and indexed it in
      `docs/user/README.md`. `nix flake check` passes — all four checks green
      (`nagare-dsl-build-test`, `nagarectl-build-test`, `shellcheck-scripts`, and
      `examples-compile`, which compiled the new example through the loader's
      runghc contract).
- [ ] **M6 — Live validation (optional, requires a running cluster).** DEFERRED
      (2026-06-17): `nagare-01` is `TERMINATED` (confirmed via
      `gcloud compute instances list`), as the standing memory note anticipates.
      M1–M5 are complete and verified offline (`nix flake check` green). Live
      validation needs the VM started (`just vm-start` + `just live-test`), which
      is a billable, outward-facing action left for an operator to run. The exact
      commands and expected transcript are in Concrete Steps / Validation.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The request-driven `Deployment` and the new `Worker` both export fields named
  `build`, `replicas`, `env`, `resources`, `volumes`, so bare field /selectors/
  (`build w`) are ambiguous in a module importing both. The test suite has no
  `lens`/`generic-lens` dependency, so `WorkerSpec` disambiguates with record
  /pattern/ matching (`Right Worker {build = b}`) rather than `^. #build`. No
  production code is affected (those modules use `Data.Generics.Labels` lenses).
- At M6 time `nagare-01` was `TERMINATED` (`gcloud compute instances list` shows
  `nagare-01` and `nix-builder-x86` both stopped in `us-west1-a`), matching the
  standing memory note that the VM is often off and must be started first. M6 is
  deferred to an operator rather than auto-starting a billable VM.
- The PVC a worker volume renders carries the existing `nagare.dev/app` label
  (it reuses `renderPersistentVolumeClaims`, the single owner of the PVC
  contract), not a `nagare.dev/worker` label. This is intentional: storage
  discovery (EP-35/36) keys off `nagare.dev/app`/`nagare.dev/volume`, so a
  worker's durable disk is discovered by the same machinery as an app's.

## Decision Log

Record every decision made while working on the plan.

- Decision: Model workers as a brand-new top-level workload **kind** (`Worker`)
  with its own `nagarectl worker` command group, rather than adding a
  `runtime: Knative | Deployment` mode flag to the existing
  `Nagare.Dsl.Types.Deployment`.
  Rationale: This mirrors the established precedent — `Database` (renders to a
  `StatefulSet`) and `Task` (renders to a `CronJob`) are each their own kind
  with their own renderer, loader branch, `emit*` function, and CLI command
  group. The request-driven `Deployment` type carries Knative-only fields
  (`domains`, `scale`, `cdn`, `port`, `healthCheck` as a Knative probe) that are
  meaningless for a worker; bolting a mode flag onto it would force every one of
  those fields to mean "ignored when runtime=Deployment", complicate the
  existing renderer's every branch, and risk regressing the Knative path that
  all current apps depend on. A separate `Worker` type keeps each renderer
  simple and the Knative path untouched. Confirmed with the user on 2026-06-17.
  Date: 2026-06-17

- Decision: A Worker renders to a single `apps/v1` Deployment with **no**
  Service/Ingress/DomainMapping and **no** Knative autoscaling annotations.
  Rationale: A worker is not request-driven and not reachable from outside; it
  consumes work (queues, streams) and produces side effects. Exposing it would
  contradict its purpose and add cluster surface with no consumer. Replica count
  is a fixed user-chosen integer (default 1), not an autoscaler, because the
  cluster is single-node.
  Date: 2026-06-17

- Decision: Reuse `Nagare.Dsl.Types`' existing `Resources`, `Volume`,
  `ScopedEnvVar`/`EnvVar`/`EnvScope`, `ServiceName`, `Namespace`, `ImageRef`,
  and `Nagare.Dsl.Build.BuildSpec` verbatim, and reuse
  `Nagare.Dsl.Render`'s exported helpers `managedConfigMapName`,
  `managedSecretName`, `pvcName`, `renderPersistentVolumeClaims`,
  `volumeMountsField`, `volumesField`, and `resolveImageTag`.
  Rationale: These are already the single owners of the env-naming, PVC-naming,
  and image-tag contracts. The worker must obey the same contracts (so
  `nagarectl env`, storage discovery, and image builds keep working for
  workers), and re-deriving any of them by hand would silently fork the
  contract. The worker reuses `ServiceName` as its name newtype (a DNS-1123
  label — exactly the validation a Kubernetes object name needs) rather than
  introducing a parallel `WorkerName`.
  Date: 2026-06-17

- Decision: Export the existing private `envField` / `envFromField` from
  `Nagare.Dsl.Render` (a purely additive export) and import them into
  `Nagare.Dsl.Worker.Render`, rather than reimplementing the inline-env and
  managed-`envFrom` rendering. Rationale: this is the option the plan preferred
  ("prefer exporting to avoid a forked contract"); the worker's env is now
  byte-identical to an app's and cannot drift from the managed-env naming
  contract. Date: 2026-06-17

- Decision: In `Nagare.Dsl.Config`, lift the previously-local Deployment
  `buildJSON` to a top-level `buildSpecJSON` and add a top-level `scopedEnvJSON`,
  both shared by `workerJSON`. Rationale: the worker reuses the `BuildSpec` and
  scoped-env JSON contracts verbatim; sharing the encoder (not just the decoder)
  prevents the worker's emitted shape from drifting from what the loader's
  `toBuildSpec` / `toEnvEntry` read back. `deploymentJSON`'s output is unchanged
  (the existing goldens still pass). Date: 2026-06-17

- Decision: Place the `loadWorker`-from-fixture subprocess test in
  `nagare-dsl-test` (`WorkerSpec`), with the fixture at
  `cli/nagare-dsl/test/fixtures/worker/nagare/Config.hs`, rather than in
  `nagarectl-test`. Rationale: `nagare-dsl-test` already owns the working
  `runghc` config-loader harness (it loads `loadDeployment`/`loadServerSite`
  fixtures and the cabal project writes the GHC package-environment file
  `runghc` needs); `nagarectl-test` is a pure-helper suite that spawns no
  subprocess. Putting it where the harness already works keeps it robust and
  still proves the full `Config.hs` → `emitWorker` → `loadWorker` path the CLI
  uses. Date: 2026-06-17

- Decision: The worker's readiness gate is
  `kubectl rollout status deployment/<name>`, not the Knative
  `kubectl wait --for=condition=Ready ksvc/<name>` used by request-driven apps.
  Rationale: A worker is an `apps/v1` Deployment, which exposes rollout status
  exactly as the database `StatefulSet` does (`Nagare.Deploy.waitForRollout`
  already wraps `kubectl rollout status statefulset/<name>`); the worker adds
  the parallel `deployment/<name>` form.
  Date: 2026-06-17

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### Status at 2026-06-17 — M1–M5 complete, M6 deferred

The original purpose is met offline: nagare can now describe and deploy a
long-running **Worker** from a tiny typed `nagare/Config.hs`, and it renders to a
plain `apps/v1` Deployment — never a Knative Service — so it runs continuously,
never scales to zero, and needs no HTTP port. Concretely:

* **M1** — `Nagare.Dsl.Worker` adds the `Worker` record, the `Replicas` newtype
  (rejects `< 0`, default 1), the `Command` entrypoint override (non-empty,
  NUL-free), and the `webWorker` preset. Unit tests pin the constructors.
* **M2** — `Nagare.Dsl.Worker.Render` renders an `apps/v1` Deployment (replicas,
  matching selector/pod labels, managed `envFrom`, optional command/env/
  resources/volumes) plus one PVC per volume. Golden files
  (`worker-minimal.deployment.yaml`, `worker-rich.deployment.yaml`,
  `worker-rich.manifests.yaml`) pin the exact YAML; a manual read confirmed a
  valid Deployment with **no** Service/DomainMapping/Knative annotation. The
  inline-env and managed-`envFrom` rendering reuses the app's exported
  `envField`/`envFromField`, so it cannot fork the contract.
* **M3** — `emitWorker`/`encodeWorker` + `loadWorker`/`decodeWorker` with a
  `"kind": "Worker"` discriminator; the encode→decode round-trip is identity and
  decoding a `Database`/`Deployment` as a Worker is `UnexpectedKind`.
* **M4** — `nagarectl worker deploy` loads the config, qualifies the image,
  reuses the app build/push path (incl. `gatherBuildArgs`), applies the
  PVCs+Deployment, and gates on `waitForWorkerRollout`
  (`kubectl rollout status deployment/<name>`). `worker --help` and
  `worker deploy --help` document it; both test suites pass (286 + 285).
* **M5** — the `queue-worker` example and the `docs/user/workers.md` guide ship;
  `nix flake check` is green, including `examples-compile`.

**Gap:** M6 (live `2/2`-Ready Deployment on `nagare-01`, absent from
`kubectl get ksvc`, emitting logs) is **deferred** — the VM is `TERMINATED` and
bringing it up is a billable, outward-facing action for an operator. Everything
M6 needs (the example, the command, the readiness gate) is in place; only the
on-cluster run remains.

**Lessons:** (1) Reusing the app renderer's `envField`/`envFromField` (exported,
not reimplemented) and lifting a shared `buildSpecJSON`/`scopedEnvJSON` kept the
worker byte-identical to the app on the env/build contracts — the single-owner
discipline the plan insisted on. (2) The two workloads now share field names
(`build`, `replicas`, `env`, …); production modules disambiguate with
`Data.Generics.Labels` lenses, but the lens-free test suite needed record-pattern
matching instead.

