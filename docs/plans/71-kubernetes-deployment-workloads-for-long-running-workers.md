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


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before
editing.

### What nagare is, in one paragraph

nagare is a personal Platform-as-a-Service: a single-node Kubernetes cluster
(the `k3s` distribution) running on one Google Cloud VM, plus a command-line
tool, **`nagarectl`**, that deploys apps to it. The novelty is that an app is
not configured with YAML; it is configured with a tiny **typed Haskell program**
named `nagare/Config.hs` inside the app's repository. That program builds a
value (e.g. a `Deployment`) using *smart constructors* that reject invalid
input at compile time, then prints it as JSON to standard output.
`nagarectl` runs that program, reads the JSON back, re-validates it, renders the
appropriate Kubernetes YAML, and applies it with `kubectl`. "Smart constructor"
means: a type whose data constructor is hidden, exposed only through a function
`mkX :: Raw -> Either Text X` that returns `Left "why it is invalid"` or
`Right` a guaranteed-valid value. Because the constructor is hidden, code
elsewhere *cannot* build an invalid value. You will follow this same pattern.

### The two Haskell packages

The Haskell code lives under `cli/`, built with **Cabal** and GHC 9.12,
orchestrated by Nix. There are two packages:

1. `cli/nagare-dsl/` — the **library**: the pure, typed workload models and
   their YAML renderers. No cluster I/O. This is where the `Worker` *type* and
   its *renderer* go. The cabal file is
   `cli/nagare-dsl/nagare-dsl.cabal`; its test suite is
   `cli/nagare-dsl/test/` (the `nagare-dsl-test` target, a `tasty` suite with
   HUnit, golden, and QuickCheck tests).

2. `cli/nagarectl/` — the **CLI executable** plus its support library: it does
   the cluster I/O (build an image, `kubectl apply`, wait for readiness). This
   is where the `nagarectl worker deploy` *command* goes. The cabal file is
   `cli/nagarectl/nagarectl.cabal`; the CLI entry point is
   `cli/nagarectl/app/Main.hs`; its library modules are under
   `cli/nagarectl/src/Nagare/`; its test suite is `cli/nagarectl/test/` (the
   `nagarectl-test` target).

To enter the build environment, from the repo root run `nix develop` (full
shell) or the lighter `nix develop .#haskell` (GHC + cabal only). All `cabal`
commands below assume you are inside one of these shells.

### How an existing non-Knative workload already works — the model to copy

You do **not** need to invent the design. Two existing workloads already render
to non-Knative Kubernetes objects, and the `Worker` follows the same shape as
the closest one, the **database**:

* The database **type** is `Nagare.Dsl.Database.Database`
  (`cli/nagare-dsl/src/Nagare/Dsl/Database.hs`). It is a plain record whose
  fields are all smart-constructed (`DatabaseName`, `EngineVersion`, reused
  `Namespace`/`Quantity`/`Resources`/`RetentionPolicy`). Notably it has **no
  hidden constructor for the record itself** — the safety comes from the field
  types. Your `Worker` record does the same.

* The database **renderer** is `Nagare.Dsl.Database.Render`
  (`cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs`). Its
  `renderStatefulSet` builds an `apps/v1` `StatefulSet` via `Data.Aeson.object`
  and serialises it with `Data.Yaml.Pretty.encodePretty dbConfig`, where
  `dbConfig` is a key-ordering comparator (a local `keyCompare` rank table) that
  forces a fixed, non-alphabetical key order. **Your worker renderer copies this
  file's structure almost verbatim**, emitting `kind: Deployment` instead of
  `kind: StatefulSet` (a Deployment has the same `spec.selector` /
  `spec.template.spec.containers` shape, plus `spec.replicas`, and *no*
  `spec.serviceName`). Read this file end-to-end before writing the renderer;
  it is your template.

* The database **emit** functions are in `Nagare.Dsl.Config`
  (`cli/nagare-dsl/src/Nagare/Dsl/Config.hs`): `emitDatabase`/`encodeDatabase`
  print the database as JSON with a top-level `"kind": "Database"` discriminator
  (see line ~69, `"kind" .= ("Database" :: Text)`).

* The database **loader** functions are in `Nagare.Dsl.Load`
  (`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`): `loadDatabase`/`decodeDatabase`.
  `decodeDatabase` first reads the top-level `kind` through a tiny envelope
  (`JsonKindEnvelope`, a record with an optional `kind` field, parsed by
  `eitherDecodeStrict`), and returns `UnexpectedKind "Database" other` if the
  config emitted a different kind. Your `decodeWorker` mirrors this exactly.

* The database **CLI** lives in `cli/nagarectl/src/Nagare/Database/` (e.g.
  `Create.hs`) and is wired into `cli/nagarectl/app/Main.hs` via a `DbCommand`
  sum type (line ~383) and a `dbCmd` subparser (registered at line ~1013,
  `command "db" dbCmd`). Your `worker` command mirrors this wiring.

The request-driven app path is worth reading once for the **reused pieces**:

* The app type `Nagare.Dsl.Types.Deployment`
  (`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, lines 580–622). Note the fields you
  will reuse on the worker — `name :: ServiceName`, `namespace :: Namespace`,
  `image :: ImageRef`, `build :: BuildSpec`, `env :: Map EnvName ScopedEnvVar`,
  `resources :: Maybe Resources`, `volumes :: [Volume]`, `databases ::
  [DatabaseName]` — and the fields you will **not** carry (`domains`, `port`,
  `scale`, `healthCheck`, `tasks`, `cdn`), because they are Knative- or
  request-specific.

* The app renderer `Nagare.Dsl.Render`
  (`cli/nagare-dsl/src/Nagare/Dsl/Render.hs`). This module **exports helpers you
  will import and reuse** rather than re-implement:
  - `managedConfigMapName :: Text -> EnvScope -> Text` and
    `managedSecretName :: Text -> EnvScope -> Text` — the
    `nagare-env-<app>-<scope>` / `nagare-secret-<app>-<scope>` names of the
    managed-env ConfigMap/Secret (so `nagarectl env` keeps working for workers).
  - `pvcName :: Text -> Text -> Text` (`nagare-vol-<app>-<vol>`),
    `renderPersistentVolumeClaims :: Text -> Text -> [Volume] -> [ByteString]`,
    `volumeMountsField :: [Volume] -> [Pair]`, and
    `volumesField :: Text -> [Volume] -> [Pair]` — the PVC manifest and the
    container/pod volume blocks, so a worker's durable disks obey the same
    contract storage discovery relies on.
  - From `Nagare.Dsl.Build`: `resolveImageTag :: BuildSpec -> Text -> Text`,
    which turns the resolved deploy tag into the final `image:tag` string the
    same way the app renderer does (`Render.hs` line 332).

* The app deploy I/O `Nagare.Deploy`
  (`cli/nagarectl/src/Nagare/Deploy.hs`): `applyManifests :: [ByteString] ->
  IO ()` (writes each manifest to a temp file and runs `kubectl apply -f`),
  `applyPVCs`, and `waitForRollout :: Text -> Text -> IO ()` (wraps
  `kubectl rollout status statefulset/<name>`). You will reuse `applyManifests`
  and `applyPVCs` unchanged and add a sibling `waitForWorkerRollout` for the
  `deployment/<name>` form.

### Key terms used in this plan

* **Knative Service** — `serving.knative.dev/v1` `kind: Service`. A
  request-driven, scale-to-zero workload. Today every nagare app is one. A
  worker is deliberately *not* this.
* **`apps/v1` Deployment** (the Kubernetes primitive) — the standard object for
  "run and maintain N replicas of a pod continuously, restart on crash, roll on
  change". This is what a worker renders to. Throughout this plan, when the
  Kubernetes primitive is meant it is written "`apps/v1` Deployment"; nagare's
  Haskell type `Nagare.Dsl.Types.Deployment` is always written with its module
  path or as "the request-driven `Deployment` type".
* **Worker** — nagare's new typed workload for a long-running, non-request-driven
  background process. Renders to one `apps/v1` Deployment.
* **`replicas`** — how many identical copies of the worker pod to run. A fixed
  integer chosen by the user (default 1). Not an autoscaler.
* **Smart constructor** — a `mkX :: Raw -> Either Text X` validator for a type
  with a hidden data constructor (see the one-paragraph explanation above).
* **`BuildSpec`** — `Nagare.Dsl.Build.BuildSpec`: how the container image is
  produced (a prebuilt image already in a registry, a Dockerfile build, or a
  Nixpacks build). Reused unchanged.
* **Managed env `envFrom`** — every nagare workload's container references a
  per-app ConfigMap (`nagare-env-<app>-runtime`) and Secret
  (`nagare-secret-<app>-runtime`) with `optional: true`, so values written by
  `nagarectl env`/`secret` flow in without redeploying. The worker keeps this
  contract.


## Plan of Work

The work proceeds in six milestones, each independently verifiable. Milestones
M1–M5 require only a checkout and the Nix dev shell (no cluster). M6 is an
optional live validation against a running `nagare-01`.

Throughout, follow the existing house style exactly: hidden data constructors
with `mkX :: ... -> Either Text X` smart constructors and read-only accessors
(see `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), records with public
constructors but smart-constructed fields (see `Nagare.Dsl.Database.Database`),
`Data.Aeson.object` + `Data.Yaml.Pretty.encodePretty` with an explicit
`keyCompare` rank table for rendering (see `Nagare.Dsl.Database.Render`), and a
`"kind"` discriminator on the emitted JSON.


### Milestone 1 — The typed `Worker` model

Scope: introduce the new type and its smart constructors in the `nagare-dsl`
library, with unit tests, and nothing else (no rendering, no CLI). At the end of
this milestone the `nagare-dsl` package compiles, exposes a `Worker` value that
cannot be constructed in an invalid state, and `cabal test nagare-dsl-test`
passes with new constructor tests.

Create `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`. It defines:

* `newtype Replicas` hiding its constructor, with
  `mkReplicas :: Int -> Either Text Replicas` (reject `< 0`; `0` is allowed and
  means "scaled to zero / paused"), `defaultReplicas :: Replicas` (= 1), and
  `replicasInt :: Replicas -> Int`. Follow the exact shape of
  `Nagare.Dsl.Types.mkPort`.

* A `Command` model for the optional entrypoint override. Use:

  ```haskell
  data Command = Command
    { commandArgv :: ![Text]  -- non-empty; argv[0] is the executable
    }
  ```

  with `mkCommand :: [Text] -> Either Text Command` rejecting the empty list and
  any element containing a NUL. (A worker often needs to launch a specific
  process, e.g. `["python", "-m", "worker"]`, when the image's default
  entrypoint is a web server. When `Command` is absent the image's own
  entrypoint runs.)

* The `Worker` record (public constructor, smart-constructed fields), reusing
  types from `Nagare.Dsl.Types` and `Nagare.Dsl.Build`:

  ```haskell
  data Worker = Worker
    { name       :: !ServiceName            -- DNS-1123 label; reused newtype
    , namespace  :: !Namespace
    , image      :: !ImageRef
    , build      :: !BuildSpec
    , command    :: !(Maybe Command)        -- entrypoint override; Nothing = image default
    , replicas   :: !Replicas
    , env        :: !(Map EnvName ScopedEnvVar)
    , resources  :: !(Maybe Resources)
    , volumes    :: ![Volume]
    , databases  :: ![DatabaseName]
    }
    deriving stock (Generic, Eq, Show)
  ```

* `webWorker :: Text -> Text -> Either String Worker` — a preset mirroring
  `Nagare.Dsl.Presets.webService`'s signature style (name, image-repo → a
  sensible default `Worker`): default namespace `defaultNamespace`, a
  `PrebuiltImage` build with tag `latest` (so the preset alone is runnable),
  `replicas = defaultReplicas`, empty env/volumes/databases, no command, no
  resources. The `Either String` (not `Either Text`) return matches the existing
  preset convention so example `Config.hs` files can `mapLeft show` uniformly.

Export everything from the module header. Then register the module in
`cli/nagare-dsl/nagare-dsl.cabal`: add `Nagare.Dsl.Worker` to the library's
`exposed-modules` list (find the existing `Nagare.Dsl.Database` entry and add the
new module alphabetically near it).

Reuse note: `ServiceName`, `Namespace`, `ImageRef`, `EnvName`, `ScopedEnvVar`,
`Resources`, `Volume`, and `DatabaseName` are all already exported from
`Nagare.Dsl.Types`; `BuildSpec` from `Nagare.Dsl.Build`. Import them; do not
redefine.

Tests: create `cli/nagare-dsl/test/WorkerSpec.hs` with `tasty`-HUnit cases
asserting: `mkReplicas (-1)` is `Left`; `mkReplicas 0` and `mkReplicas 3` are
`Right`; `mkCommand []` is `Left`; `mkCommand ["python","-m","worker"]` is
`Right`; `webWorker "queue-consumer" "registry/x"` is `Right` and has
`replicas == defaultReplicas`. Wire `WorkerSpec.tests` into the suite's root
`tasty` group (open `cli/nagare-dsl/test/Spec.hs` — or whatever the suite's
`main` module is named per `nagare-dsl.cabal`'s `test-suite` stanza — and add
`WorkerSpec.tests` alongside the existing `ServerSpec`/`StaticSpec`/`CdnSpec`
groups, and add `WorkerSpec` to the test-suite's `other-modules`).

Acceptance: `cd cli/nagare-dsl && cabal test nagare-dsl-test
--test-show-details=streaming` passes, including the new Worker cases.


### Milestone 2 — Render a `Worker` to an `apps/v1` Deployment

Scope: add the pure renderer. At the end, `renderWorker :: Worker ->
[ByteString]` produces a valid `apps/v1` Deployment manifest (plus one PVC per
declared volume), and golden tests pin the exact YAML.

Create `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs`, modelled on
`Nagare.Dsl.Database.Render`. It exposes:

* `renderWorker :: Worker -> [ByteString]` — the full manifest set in apply
  order: the PVCs first (reusing `renderPersistentVolumeClaims` from
  `Nagare.Dsl.Render`, exactly as the app path applies PVCs before the
  consuming workload), then the Deployment. For a volume-free worker this is a
  one-element list.
* `renderWorkerDeployment :: Worker -> ByteString` — the single Deployment
  document, the way `renderStatefulSet` renders the single StatefulSet.
* `workerDeploymentName :: Text -> Text` — `= id` (the Deployment's name is the
  worker name), exposed as a named owner so the CLI never re-derives it.

The Deployment value (built with `Data.Aeson.object`) has this shape — note it
is the database `StatefulSet` shape minus `serviceName`, plus `replicas`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <worker-name>
  namespace: <namespace>
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/worker: <worker-name>
spec:
  replicas: <replicas>
  selector:
    matchLabels:
      nagare.dev/worker: <worker-name>
  template:
    metadata:
      labels:
        nagare.dev/worker: <worker-name>
    spec:
      containers:
        - name: <worker-name>
          image: <imageRef>:<resolvedTag>
          command: [ ... ]    # only when Worker.command is Just
          env: [ ... ]        # Runtime-scoped inline env, omitted when empty
          envFrom:            # always present (managed ConfigMap + Secret, optional:true)
            - configMapRef: { name: nagare-env-<name>-runtime, optional: true }
            - secretRef:    { name: nagare-secret-<name>-runtime, optional: true }
          resources: { ... }  # omitted when absent/empty
          volumeMounts: [ ... ] # omitted when no volumes
      volumes: [ ... ]        # omitted when no volumes
```

Reuse, by import:

* The inline `env:` block and the managed `envFrom:` block. The cleanest path is
  to **export the existing private helpers** `envField` and `envFromField` from
  `Nagare.Dsl.Render` (add them to that module's export list) and import them
  here, so the worker's env rendering is byte-identical to the app's. If
  exporting them proves awkward (they are currently local), reimplement them in
  `Worker.Render` *calling the already-exported* `managedConfigMapName` /
  `managedSecretName` for the names — but prefer exporting to avoid a forked
  contract; record whichever you choose in the Decision Log.
* `volumeMountsField` and `volumesField` (already exported from
  `Nagare.Dsl.Render`) for the container/pod volume blocks.
* `resolveImageTag` (from `Nagare.Dsl.Build`) to build `image:tag`, exactly as
  `Render.hs` line 332 does: `imageRefText (w ^. #image) <> ":" <>
  resolveImageTag (w ^. #build) tag`. The worker renderer takes the resolved
  `tag :: Text` as a second argument, like `renderService dep tag`.
  (Adjust `renderWorker`'s signature to `Worker -> Text -> [ByteString]` to
  thread the tag — match `renderService`'s `Deployment -> Text -> ByteString`
  precedent. Update M1/M2 acceptance code accordingly.)

Copy the `dbConfig`/`keyCompare` key-ordering apparatus from
`Database/Render.hs` into a local `workerConfig`/`keyCompare`, extending the
rank table with the Deployment-specific keys (`replicas`, `command`, `envFrom`,
`configMapRef`, `secretRef`, `optional`) so the emitted key order is
deterministic. The `command` field renders as a YAML list of the `commandArgv`
strings.

Tests: add golden tests under `cli/nagare-dsl/test/golden/`. Create two fixture
`Worker` values in `WorkerSpec.hs` (or a `WorkerRenderSpec.hs`): a minimal one
(`webWorker` with `replicas = 2`, no env/volumes/command) producing
`worker-minimal.deployment.yaml`, and a rich one (a `Command` override, two
`Runtime` env vars — one literal, one secret ref — a `Resources` with requests
and limits, and one `Volume`) producing `worker-rich.deployment.yaml` plus
`worker-rich.pvc.yaml`. Generate the golden files once with `--accept`
(`tasty-golden`'s flag — confirm the exact invocation against the existing
golden tests, which already use `goldenVsString`), then **read the generated
YAML by eye** to confirm it is a sane `apps/v1` Deployment before committing the
golden file.

Acceptance: `cd cli/nagare-dsl && cabal test nagare-dsl-test
--test-show-details=streaming` passes; the golden YAML files exist and a manual
read confirms `kind: Deployment`, `spec.replicas: 2`, correct labels, and (for
the rich case) the command/env/resources/volume blocks.


### Milestone 3 — Emit and load round-trip

Scope: make a `nagare/Config.hs` able to *emit* a `Worker` as JSON and make the
loader able to *read it back* into a validated `Worker`. At the end, the
encode→decode round-trip is identity, proven by a test.

In `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`:

* Add `emitWorker :: Worker -> IO ()` and `encodeWorker :: Worker ->
  LBS.ByteString`, mirroring `emitDatabase`/`encodeDatabase`. The emitted JSON
  has a top-level `"kind" .= ("Worker" :: Text)` and fields for name, namespace,
  image, build (reuse the existing build-JSON helper used by
  `deploymentJSON`/`databaseJSON`), command (a JSON array or null), replicas (an
  Int), env (reuse the existing scoped-env JSON encoder used by
  `deploymentJSON`), resources (reuse the existing resources encoder), volumes
  (reuse the existing volume encoder), and databases (array of names). Export
  both from the module header alongside `emitDatabase`.

In `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`:

* Add `loadWorker :: FilePath -> IO (Either LoadError Worker)` and
  `decodeWorker :: ByteString -> Either LoadError Worker`, mirroring
  `loadDatabase`/`decodeDatabase`. `decodeWorker` first reads the top-level
  `kind` via the existing `JsonKindEnvelope`, returning
  `UnexpectedKind "Worker" other` / `UnexpectedKind "Worker" "<none>"` on
  mismatch, then `eitherDecodeStrict` into a `JsonWorker` and runs
  `toWorker :: JsonWorker -> Either LoadError Worker`, which re-runs every smart
  constructor (`mkServiceName`, `mkNamespace`, `mkImageRef`, `mkReplicas`,
  `mkCommand`, the existing build/env/resources/volume marshallers reused from
  the `Deployment` decoder, and `mkDatabaseName`). A worker with duplicate
  volume names or mount paths is rejected here the same way `toDeployment`
  enforces volume uniqueness (reuse `toVolumes`). Export `loadWorker` and
  `decodeWorker` from the module header.

Tests: in `cli/nagare-dsl/test/` add a round-trip case:
`decodeWorker (LBS.toStrict (encodeWorker w)) == Right w` for the rich fixture
`Worker` from M2. Also assert `decodeWorker` of a *database*'s JSON yields
`Left (UnexpectedKind "Worker" "Database")` (kind guarding works). Mirror the
existing Database round-trip test if one exists (search the test dir for
`decodeDatabase`/`encodeDatabase` usages and copy the pattern).

Acceptance: `cabal test nagare-dsl-test --test-show-details=streaming` passes
including the round-trip and kind-guard cases.


### Milestone 4 — The `nagarectl worker deploy` command

Scope: wire a user-facing command that loads `nagare/Config.hs` as a `Worker`,
builds and pushes the image (reusing the existing build path), renders the
manifests, applies them, and waits for the rollout. At the end,
`nagarectl worker deploy` works end-to-end against a cluster (verified live in
M6) and `nagarectl worker --help` documents it.

Add the deploy I/O gate in `cli/nagarectl/src/Nagare/Deploy.hs`:

* `waitForWorkerRollout :: Text -> Text -> IO ()` — identical to the existing
  `waitForRollout` but for `deployment/<name>`:
  `kubectl rollout status deployment/<name> -n <namespace> --timeout=300s`.
  Export it.

Create `cli/nagarectl/src/Nagare/Worker/Deploy.hs` with
`runWorkerDeploy :: WorkerDeployParams -> IO ()`, modelled on the existing
deploy command flow. Study `cli/nagarectl/src/Nagare/Database/Create.hs` (the
`runDbCreate` flow: load, render, apply in order, `waitForRollout`, print
result) and the request-driven deploy command in `app/Main.hs` (the `deploy`
handler — find `deployCmd`/the `Deploy` constructor's run function — for the
build/push half). `runWorkerDeploy` should:

1. Resolve the config path (default `nagare/Config.hs`) and call
   `loadWorker`. On `Left`, print `renderLoadError` and exit non-zero.
2. Resolve the image tag and, unless the build is `PrebuiltImage`, build and
   push the image through the **existing** `Nagare.Build`/`Nagare.Image` path
   the request-driven deploy already uses (do not fork it; call the same
   function the app deploy calls — identify it while reading the `deploy`
   handler). The worker reuses `BuildSpec`, so this is the same code.
3. `renderWorker worker tag` → manifest list; `applyPVCs` the PVC subset first
   (the PVCs are the head of the list for a worker with volumes — split them the
   way the app deploy splits `renderVolumeClaims` from `renderService`), then
   `applyManifests` the Deployment.
4. `waitForWorkerRollout namespace name`.
5. Print a confirmation including the namespace, name, and replica count, and a
   `kubectl get deployment <name> -n <namespace>` hint. A worker has no URL, so
   do **not** call `serviceUrl`.

Wire the command into `cli/nagarectl/app/Main.hs`:

* Add a `Worker WorkerCommand` constructor to the top-level `data Command` sum
  (near `Db DbCommand`, line ~323).
* Add `newtype WorkerCommand = WorkerDeploy WorkerDeployOpts` (mirror
  `DomainsCommand`/`TaskCommand`).
* Add a `workerCmd :: ParserInfo Command` subparser with a single
  `command "deploy"` whose `progDesc` is
  `"Build, push, and run a long-running worker (apps/v1 Deployment) from the current directory"`.
  Mirror `dbCmd`'s structure (line ~1013 registration; the per-subcommand
  `info`/`progDesc` style elsewhere in the file).
* Register it in the root `subparser` block (line ~1005) with
  `<> command "worker" workerCmd`.
* In the top-level command dispatcher (the `case`/handler that maps each
  `Command` constructor to its `run*`), add the `Worker (WorkerDeploy opts) ->
  runWorkerDeploy (...)` arm.
* Add the `import Nagare.Worker.Deploy (WorkerDeployParams (..), runWorkerDeploy)`
  and register `Nagare.Worker.Deploy` in `cli/nagarectl/nagarectl.cabal`'s
  library `exposed-modules` (next to the `Nagare.Database.Create` entry). Add
  `Nagare.Worker.Deploy` wherever `Nagare.Database.Create` is listed.

Tests: extend `cli/nagarectl/test/` with a pure test of `runWorkerDeploy`'s
non-I/O pieces if any are factored out (e.g. a helper that splits PVCs from the
Deployment manifest). At minimum, add a test that `loadWorker` on a fixture
`nagare/Config.hs` returns the expected `Worker` (mirror the existing
`app-with-task` fixture under `cli/nagarectl/test/fixtures/`: create
`cli/nagarectl/test/fixtures/worker-app/nagare/Config.hs` calling `emitWorker`,
and assert `loadWorker` succeeds). Keep cluster I/O out of the unit tests.

Acceptance: `cd cli/nagarectl && cabal build all` succeeds;
`cabal run nagarectl -- worker --help` prints the `deploy` subcommand;
`cabal run nagarectl -- worker deploy --help` prints its options;
`cabal test nagarectl-test --test-show-details=streaming` passes.


### Milestone 5 — Example, documentation, and CI

Scope: ship a compiling example and document the workflow, so the
`examples-compile` flake check covers the worker path and a user has a working
template. At the end, `nix flake check` passes with the new example.

Create `cluster/examples/queue-worker/nagare/Config.hs` modelled on
`cluster/examples/prebuilt-image-app/nagare/Config.hs` (note its header comment
explaining the `-XGHC2024` / no-`OverloadedLabels` constraint — the loader
compiles configs under `-XGHC2024`, which does *not* enable `OverloadedLabels`,
so use plain record updates `base {replicas = ...}`, not `#replicas` lenses).
The example uses a public, pullable image so `examples-compile` does not need a
private registry: use `gcr.io/knative-samples/helloworld-go` (already used by
the prebuilt example) with a `command` override that turns it into a visible
"worker" (e.g. `["sh","-c","while true; do echo working; sleep 5; done"]`) and
`replicas = 2`. Add a short `README.md` next to it explaining what a worker is
and the deploy command.

Verify the example is picked up by the `examples-compile` flake check (it globs
`cluster/examples/*/nagare/Config.hs` — confirm by reading `flake.nix`'s
`examples-compile` check; the new directory matches the glob automatically). If
the check enumerates a fixed list rather than globbing, add the new path.

Documentation: add a worker section to the user-facing docs. Find the existing
per-workload docs (search `docs/` for the database or task user guide — e.g.
`docs/` runbooks/user-guides referenced from `MasterPlan` 9/10) and add a
parallel "Running workers" page or section covering: what a worker is and when
to use it instead of a Knative app, the `Worker` config fields, the
`nagarectl worker deploy` command, and how to inspect/scale/stop it with
`kubectl` (`kubectl get deployment`, `kubectl scale deployment <name>
--replicas=N`, `kubectl delete deployment <name>`). If there is no central
per-workload doc index, at minimum document it in the example's `README.md` and
in this plan's Validation section.

Acceptance: from the repo root, `nix flake check` passes (it runs
`nagare-dsl-build-test`, `nagarectl-build-test`, `examples-compile`, and
`shellcheck-scripts`); the `examples-compile` check compiles
`cluster/examples/queue-worker/nagare/Config.hs` without error.


### Milestone 6 — Live validation (optional; requires a running cluster)

Scope: prove the worker actually runs on `nagare-01`. This milestone needs a
running VM and cluster access; if the cluster is down, record that M1–M5 are
complete and this is deferred.

Bring up access the way the repo already documents (the `just live-test`
recipe opens an IAP tunnel and forwards the k3s API to `127.0.0.1:6443`; see
also the memory note that the VM must be started first and the GKE default
kubectl context must not be used). Then, from a directory containing the
`queue-worker` example config, run `nagarectl worker deploy` and capture the
transcript. Confirm with `kubectl get deployment queue-worker -n personal`
showing `2/2` Ready, `kubectl get ksvc -n personal` *not* listing it, and
`kubectl logs deploy/queue-worker -n personal` showing the worker's output.
Paste these transcripts into Validation and Acceptance and the Outcomes section.

Acceptance: a `2/2`-Ready Deployment exists, is absent from the Knative Service
list, and emits log output — all captured as transcripts in this plan.


## Concrete Steps

All commands assume the repo root `/Users/shinzui/Keikaku/bokuno/nagare` and an
active Nix dev shell (`nix develop` or `nix develop .#haskell`).

Build and test the DSL library (M1–M3):

```bash
cd cli/nagare-dsl
cabal build all
cabal test nagare-dsl-test --test-show-details=streaming
```

Regenerate golden files after writing the renderer (M2) — confirm the accept
flag against the existing golden suite first (`grep -rn "goldenVsString\|--accept\|acceptTests" cli/nagare-dsl/test`):

```bash
cd cli/nagare-dsl
cabal test nagare-dsl-test --test-options=--accept
git status cli/nagare-dsl/test/golden   # review the new worker-*.yaml before committing
```

Build and exercise the CLI (M4):

```bash
cd cli/nagarectl
cabal build all
cabal run nagarectl -- worker --help
cabal run nagarectl -- worker deploy --help
cabal test nagarectl-test --test-show-details=streaming
```

Full CI gate (M5), from the repo root:

```bash
nix flake check
```

Live deploy (M6), from the example directory after `just live-test` has opened
the tunnel:

```bash
cd cluster/examples/queue-worker
nagarectl worker deploy
kubectl get deployment queue-worker -n personal
kubectl get ksvc -n personal           # queue-worker must NOT appear
kubectl logs deploy/queue-worker -n personal --tail=5
```

Expected M6 transcript (replicas Ready, absent from Knative, logging):

```text
$ kubectl get deployment queue-worker -n personal
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
queue-worker   2/2     2            2           25s
$ kubectl get ksvc -n personal
NAME            URL   ...
notes           ...         # other apps, but NOT queue-worker
$ kubectl logs deploy/queue-worker -n personal --tail=2
working
working
```

Every commit while working on this plan must carry both trailers (blank line
before them):

```text
ExecPlan: docs/plans/71-kubernetes-deployment-workloads-for-long-running-workers.md
Intention: intention_01kvce00njestav4ejj7dbfwea
```

Stage files by explicit path (the repo's convention forbids `git add -A`; a
concurrent actor may commit mid-session). Example:

```bash
git add cli/nagare-dsl/src/Nagare/Dsl/Worker.hs cli/nagare-dsl/nagare-dsl.cabal \
        cli/nagare-dsl/test/WorkerSpec.hs cli/nagare-dsl/test/Spec.hs
git commit
```


## Validation and Acceptance

The plan is successful when all of the following hold:

1. **Type safety (M1).** `mkReplicas (-1)` and `mkCommand []` return `Left`;
   valid inputs return `Right`. Proven by `WorkerSpec` in `nagare-dsl-test`.

2. **Correct rendering (M2).** `renderWorker` produces an `apps/v1` `kind:
   Deployment` with the chosen `spec.replicas`, the
   `nagare.dev/managed-by: nagarectl` and `nagare.dev/worker: <name>` labels, a
   `selector.matchLabels` that matches the pod template labels, the managed
   `envFrom` ConfigMap+Secret block, and — when present — the command override,
   inline Runtime env, resources, and volume mounts. It emits **no** Service,
   DomainMapping, Ingress, or `autoscaling.knative.dev/*` annotation. Pinned by
   the `worker-minimal.deployment.yaml` and `worker-rich.deployment.yaml`
   (+`worker-rich.pvc.yaml`) golden files and a manual read of them.

3. **Round-trip integrity (M3).**
   `decodeWorker (encodeWorker w) == Right w` for the rich fixture; decoding a
   `Database`'s JSON as a worker yields `Left (UnexpectedKind "Worker"
   "Database")`. Proven in `nagare-dsl-test`.

4. **Usable command (M4).** `nagarectl worker --help` lists `deploy`;
   `nagarectl worker deploy --help` lists its options; `nagarectl-test` passes;
   `loadWorker` on the `worker-app` fixture returns the expected `Worker`.

5. **CI green (M5).** `nix flake check` passes; the `queue-worker` example
   compiles under `examples-compile`.

6. **Live behavior (M6, when a cluster is available).** A `nagarectl worker
   deploy` of the example yields a `2/2`-Ready `apps/v1` Deployment that does
   **not** appear in `kubectl get ksvc` and produces log output — the concrete
   proof that nagare now runs workers, not only Knative Services. Transcript
   pasted above and into Outcomes.

The headline acceptance, phrased as observable behavior: *after this change, a
user writes a `Worker` config and runs `nagarectl worker deploy`; a
continuously-running background process with the requested replica count appears
on the cluster as a plain Kubernetes Deployment, never scales to zero, needs no
HTTP port, and is absent from the Knative Service list* — none of which was
possible before, when every deploy became a Knative Service.


## Idempotence and Recovery

Every step is safe to repeat.

* `cabal build`/`cabal test` are pure and idempotent.
* `kubectl apply -f` (the mechanism behind `applyManifests`) is declarative: a
  second `nagarectl worker deploy` of an unchanged config is a no-op for
  unchanged fields and a rolling update for changed ones; it never duplicates
  the Deployment. PVCs are applied before the Deployment (via `applyPVCs`) and
  re-applying an existing PVC never recreates the underlying disk (the same
  guarantee the app path documents in `Nagare.Deploy.applyPVCs`).
* If a deploy half-fails (image pushed, rollout not Ready), re-running after
  fixing the cause resumes cleanly: the image is content-addressed by tag, and
  `kubectl rollout status` simply waits again.
* To remove a worker entirely: `kubectl delete deployment <name> -n
  <namespace>` (and, if it declared volumes you no longer want, the PVC
  `nagare-vol-<name>-<vol>` — but a `Retain` volume is intentionally left for
  safety). Deleting the Deployment stops all replicas immediately.
* To pause a worker without deleting it: `kubectl scale deployment <name>
  --replicas=0 -n <namespace>`, or set `replicas = 0` in the config and
  redeploy.
* Recovery from a bad golden file (M2): delete the offending
  `cli/nagare-dsl/test/golden/worker-*.yaml`, re-run the renderer by eye, and
  regenerate with `--accept` only after confirming the YAML is correct.


## Interfaces and Dependencies

New and changed module surface, by milestone. Full module paths throughout.

**M1 — `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs` (new):**

```haskell
newtype Replicas
mkReplicas        :: Int -> Either Text Replicas      -- rejects < 0
defaultReplicas   :: Replicas                         -- = 1
replicasInt       :: Replicas -> Int

data Command = Command { commandArgv :: ![Text] }
mkCommand         :: [Text] -> Either Text Command    -- non-empty, no NUL
commandArgvList   :: Command -> [Text]

data Worker = Worker
  { name :: !ServiceName, namespace :: !Namespace, image :: !ImageRef
  , build :: !BuildSpec, command :: !(Maybe Command), replicas :: !Replicas
  , env :: !(Map EnvName ScopedEnvVar), resources :: !(Maybe Resources)
  , volumes :: ![Volume], databases :: ![DatabaseName] }

webWorker         :: Text -> Text -> Either String Worker
```

Depends on: `Nagare.Dsl.Types` (reused `ServiceName`, `Namespace`, `ImageRef`,
`EnvName`, `ScopedEnvVar`, `Resources`, `Volume`, `DatabaseName`,
`defaultNamespace`, and their `mk*` constructors), `Nagare.Dsl.Build`
(`BuildSpec`, `PrebuiltImage`, `mkTag`), `Nagare.Dsl.Prelude`. Registered in
`cli/nagare-dsl/nagare-dsl.cabal` `exposed-modules`.

**M2 — `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs` (new):**

```haskell
renderWorker            :: Worker -> Text -> [ByteString]   -- PVCs then Deployment
renderWorkerDeployment  :: Worker -> Text -> ByteString
workerDeploymentName    :: Text -> Text                     -- = id
```

Depends on (by import, not re-implementation): `Nagare.Dsl.Render`
(`managedConfigMapName`, `managedSecretName`, `pvcName`,
`renderPersistentVolumeClaims`, `volumeMountsField`, `volumesField`, and —
newly exported — `envField`, `envFromField`), `Nagare.Dsl.Build`
(`resolveImageTag`), `Nagare.Dsl.Worker`, `Data.Aeson`, `Data.Yaml.Pretty`.
**Change to existing file:** `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` adds
`envField` and `envFromField` to its export list (a purely additive export).

**M3 — `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` and `.../Load.hs` (changed):**

```haskell
-- Config.hs (exports added)
emitWorker    :: Worker -> IO ()
encodeWorker  :: Worker -> LBS.ByteString
-- Load.hs (exports added)
loadWorker    :: FilePath -> IO (Either LoadError Worker)
decodeWorker  :: ByteString -> Either LoadError Worker   -- kind-guarded ("Worker")
```

Reuse the existing build/env/resources/volume JSON encoders in `Config.hs` and
the matching marshallers (`toBuildSpec`, `toEnvEntry`/scope parsing,
`toResources`, `toVolumes`) in `Load.hs`; do not duplicate them. `decodeWorker`
reuses the existing `JsonKindEnvelope` and `UnexpectedKind` machinery.

**M4 — `cli/nagarectl/src/Nagare/Worker/Deploy.hs` (new) and
`cli/nagarectl/src/Nagare/Deploy.hs` + `cli/nagarectl/app/Main.hs` (changed):**

```haskell
-- Nagare.Worker.Deploy (new)
data WorkerDeployParams = WorkerDeployParams { wdpConfigPath :: !FilePath, ... }
runWorkerDeploy :: WorkerDeployParams -> IO ()
-- Nagare.Deploy (export added)
waitForWorkerRollout :: Text -> Text -> IO ()   -- kubectl rollout status deployment/<name>
```

`Main.hs` gains: a `Worker WorkerCommand` arm on `data Command`; a
`newtype WorkerCommand = WorkerDeploy WorkerDeployOpts`; a `workerCmd`
subparser; `<> command "worker" workerCmd` in the root subparser; the dispatch
arm calling `runWorkerDeploy`; and the import. Reuses the **existing** build/push
function from the request-driven `deploy` handler (identify it while reading that
handler — it is the same `Nagare.Build`/`Nagare.Image` entry the app deploy uses)
and `applyManifests`/`applyPVCs` from `Nagare.Deploy`. `Nagare.Worker.Deploy`
is registered in `cli/nagarectl/nagarectl.cabal` `exposed-modules`.

**M5 — `cluster/examples/queue-worker/nagare/Config.hs` + `README.md` (new):**
A compiling example using a public image and a `command` override; picked up by
the `examples-compile` flake check (verify the check globs
`cluster/examples/*/nagare/Config.hs` in `flake.nix`).

External dependencies: none new. Everything builds on the existing `aeson`,
`yaml`, `optparse-applicative`, `cradle`, and `kubectl`/`docker` toolchain
already used by the two packages. No new cluster components are installed; a
worker uses the stock `apps/v1` API the cluster already serves.
