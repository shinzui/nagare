---
type: Guide
title: "Running workers"
description: "Define, deploy, observe, scale, pause, and test long-running worker workloads on Nagare."
docId: DOC-36
tags: [workers, workloads, queues, deployment]
generated:
  by: human:nadeem
  at: 2026-07-01T01:38:13Z
---

# Running workers

> 🟡 **In progress.** Built and offline-verified — the typed `Worker` model, the
> `apps/v1` Deployment renderer, `emit`/`load` round-trip, and the
> `nagarectl worker deploy` command all ship and are covered by unit, golden, and
> config-load tests. A worker config renders a valid `apps/v1` Deployment via
> `nagarectl worker deploy --dry-run`. The full **live** end-to-end run (apply
> the Deployment, observe `2/2` Ready, stream logs) is pending only because
> `nagare-01` is often `TERMINATED`; the exact on-VM commands are below.

For **app developers** who need to run a process **continuously in the
background** — a queue consumer, a stream processor, a long polling loop — rather
than a request-driven web app.

A **worker** is **not** a Knative Service. Every other nagare app becomes a
Knative Service: a workload that runs *only while HTTP requests are arriving* and
scales to **zero pods** when traffic stops. That is right for a web site or API
and **wrong** for a worker, which is never driven by incoming HTTP requests — a
Knative Service would scale it to zero the moment it stopped receiving requests
(for a queue consumer, that is *always*). Knative also cannot run a process that
exposes **no HTTP port**, which most workers do not.

So a `Worker` renders to the standard Kubernetes primitive for "run N copies of
this container continuously, restart on crash, roll on image change": a plain
**`apps/v1` Deployment**. It has a fixed **replica count** (not an autoscaler —
the node is single-node), an optional **command override**, and **no** Service,
Ingress, DomainMapping, or autoscaling. It is headless by design.

## When to use a worker (vs. an app, a task, a database)

| You want to…                                   | Use          | Renders to              |
| ---------------------------------------------- | ------------ | ----------------------- |
| Serve HTTP requests (web site, API)            | `deploy`     | Knative Service         |
| Run a continuous background process            | **`worker`** | **`apps/v1` Deployment**|
| Run work on a cron schedule or once on demand  | `task`       | CronJob                 |
| Run a Postgres / Redis / ClickHouse database   | `db`         | StatefulSet             |

## The smallest thing that works

A worker is its own workload **kind** with its own `nagare/Config.hs` that emits
a `Worker` (via `emitWorker`) and its own `nagarectl worker deploy` command. The
`webWorker` preset builds a runnable worker from a name and an image repository:

```haskell
-- nagare/Config.hs — a long-running background worker.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Worker (Worker (..), mkCommand, mkReplicas, webWorker)

worker :: Either String Worker
worker = do
  base <- webWorker "queue-consumer" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/queue-consumer"
  cmd  <- first show (mkCommand ["python", "-m", "worker"])
  reps <- first show (mkReplicas 2)
  Right base {command = Just cmd, replicas = reps}

main :: IO ()
main = case worker of
  Left err -> ioError (userError err)
  Right w  -> emitWorker w
```

Note the `{-# LANGUAGE OverloadedStrings #-}` and **plain record updates**
(`base {replicas = ...}`): the loader compiles configs under `-XGHC2024`, which
does *not* enable `OverloadedLabels`, so `#replicas` lenses are unavailable in a
config file.

For an independently managed worker, save a reviewed inventory plan using a
published image and an accepted platform Namespace. Create the image resource
with the [image publication review](deploying-apps.md) first, then use the
resource ID it prints:

```bash
nagarectl worker deploy --tag release-1 \
  --image-resource RESOURCE-ID \
  --save-plan worker-review
nagarectl inventory apply worker-review --yes
```

For a standard create or update, omit `--save-plan` to publish and apply that
reviewed worker scope in one invocation:

```bash
nagarectl worker deploy --tag release-1 \
  --image-resource RESOURCE-ID
```

The command prints the published review digest and public operations before
applying them. Retiring a worker still uses a separate review.
The reviewed route also accepts a worker config with a Dockerfile or Nixpacks
build when `--image-resource` names its already accepted image and tag; it does
not rebuild the image during deployment.

To inspect that same public worker scope before saving a review, supply the
accepted image with `--dry-run` instead of `--save-plan`:

```bash
nagarectl worker deploy --tag release-1 \
  --image-resource RESOURCE-ID --dry-run
```

This reads the accepted inventory and checks scope claims without saving or
applying a review. Without `--image-resource`, `worker deploy --dry-run` keeps
its offline manifest rendering behavior. The two review options cannot be
combined.

The image resource must name the exact image and tag resolved by the worker
config. A retained PVC also needs one `--volume-recovery
VOLUME=BACKUP:KEY:VERSION` per retained volume. Runtime Secret references need
the corresponding accepted `--env-secret-resource RESOURCE-ID`. This reviewed
path accepts topic free references to accepted standalone brokers. Worker
database references bind to accepted standalone databases in the same cluster
and namespace. Planning reads the saved credential template to identify the
engine, adds a dependency on its StatefulSet, and places only Secret references
in the reviewed workload. Missing accepted objects or private evidence refuse.
Accepted standalone broker topics become explicit workload dependencies and
provide the topic environment. This path does not build or publish images.

Retire the accepted standalone worker through a separate review. Retained PVCs
remain recorded for recovery:

```bash
nagarectl worker delete queue-consumer --save-plan worker-retirement
nagarectl inventory apply worker-retirement --yes
```

If several accepted worker scopes could match, pass `--scope-key KEY` to pin the
worker's stable logical key. Retirement still verifies the native Deployment
name and namespace against accepted history.

The existing direct deploy command is:

```bash
$ nagarectl worker deploy
Worker queue-consumer is running (2 replicas requested) in namespace personal.
Inspect: kubectl get deployment queue-consumer -n personal
```

## The `Worker` config fields

| Field        | Meaning                                                                  |
| ------------ | ------------------------------------------------------------------------ |
| `name`       | DNS-1123 label; the Deployment's name and `nagare.dev/worker` label.     |
| `namespace`  | Kubernetes namespace (default `personal`).                               |
| `image`      | Image repository (no tag). A bare name is registry-prefixed at deploy.   |
| `build`      | How the image is produced — reuses the app `BuildSpec` (prebuilt / Dockerfile / Nixpacks). |
| `command`    | Optional entrypoint override, e.g. `["python","-m","worker"]`. Absent = the image's own entrypoint. |
| `replicas`   | Fixed number of identical copies to run (default 1; `0` = paused).       |
| `env`        | Scoped env (same model as an app); managed `envFrom` is always wired.    |
| `resources`  | CPU/memory requests and limits (same `Resources` as an app).            |
| `volumes`    | Durable `local-path` PVCs (same `Volume` model as an app).               |
| `databases`  | Names of managed databases this worker connects to.                      |
| `liveness`   | Optional liveness probe — `exec` (run a command), `tcp` (open a port), or `http`. Absent = no probe. Restarts a hung worker that never crashes. |

A worker reuses the app's env/secret store, so `nagarectl env` and
`nagarectl secret` work for a worker exactly as for an app — values flow in
through the managed `nagare-env-<name>-runtime` ConfigMap and
`nagare-secret-<name>-runtime` Secret without a redeploy.

## Liveness probes for hung workers

Kubernetes only restarts a container when its process **exits**. A worker that is
a NOTIFY/timer loop can **hang without crashing** — the process is still alive, so
the kubelet never recovers it, and jobs silently stop being processed. A
`liveness` probe closes that gap: the kubelet runs the check periodically and, on
`failureThreshold` consecutive failures, kills and restarts the container.

Because a worker is **headless** (no Service, no HTTP port), the primary mechanism
is **exec** — the worker ships a small healthcheck that exits non-zero when the
loop has stalled (e.g. a heartbeat file is stale, or a "last processed" timestamp
is too old). `tcp` (open an internal port) and `http` (GET an internal `/healthz`)
are also available for workers that expose one.

```haskell
import Data.Bifunctor (first)
import Nagare.Dsl.Worker (Worker (..), execProbe, mkReplicas, webWorker)

worker :: Either String Worker
worker = do
  base <- webWorker "reactor" "myrepo/reactor"
  -- the worker's loop refreshes /tmp/heartbeat each iteration; this exec probe
  -- fails (and triggers a restart) once the heartbeat goes stale.
  probe <- first show (execProbe ["sh", "-c", "test -f /tmp/heartbeat"])
  reps <- first show (mkReplicas 1)
  Right base {replicas = reps, liveness = Just probe}
```

`execProbe` uses sensible default timing (first probe immediately, every 10s, 1s
timeout, restart after 3 consecutive failures). For custom timing or a TCP/HTTP
check, build a `ProbeTiming` and use `mkExecProbe` / `mkTcpProbe` / `mkHttpProbe`.
With `asStartup = True`, a matching `startupProbe` is also emitted so a
slow-starting worker is not killed before its first successful check.

## The `nagarectl worker deploy` command

```text
nagarectl worker deploy [-f|--file FILE] [-t|--tag TAG]
                        [-c|--build-context DIR] [--dockerfile FILE]
                        [--ghc-env FILE] [--dry-run]
```

It loads `nagare/Config.hs` as a `Worker`, qualifies the image against your
active context, builds and pushes the image (unless it is a prebuilt image,
reusing the same build path as `nagarectl deploy`), applies the PVCs (if any) and
then the `apps/v1` Deployment, and waits for the rollout
(`kubectl rollout status deployment/<name>`). A worker has no URL, so none is
printed. `--dry-run` prints the rendered manifests and the build mode and applies
nothing.

## Inspect, scale, pause, and stop with kubectl

A worker is a standard Deployment, so you operate it with stock `kubectl`:

```bash
kubectl get deployment <name> -n <namespace>            # READY shows replicas
kubectl get ksvc -n <namespace>                         # a worker is NOT listed here
kubectl logs deploy/<name> -n <namespace> --tail=20     # worker output
kubectl scale deployment <name> -n <namespace> --replicas=4   # scale
kubectl scale deployment <name> -n <namespace> --replicas=0   # pause (no pods)
kubectl delete deployment <name> -n <namespace>         # remove
```

You can also pause a worker by setting `replicas = 0` in the config and
redeploying. A worker's durable volumes default to `Retain`, so a `Retain` PVC is
intentionally left behind when you delete the Deployment.

## Worked example

[`cluster/examples/queue-worker`](../../cluster/examples/queue-worker) is a
compiling worker that uses a public image with a `command` override (it prints
`working` every 5 seconds) and runs 2 replicas — see its
[README](../../cluster/examples/queue-worker/README.md).

## Live verification (when `nagare-01` is up)

```bash
just live-test     # opens the IAP tunnel and forwards the k3s API to 127.0.0.1:6443
cd cluster/examples/queue-worker
nagarectl worker deploy
kubectl get deployment queue-worker -n personal   # 2/2 Ready
kubectl get ksvc -n personal                      # queue-worker must NOT appear
kubectl logs deploy/queue-worker -n personal --tail=5
```
