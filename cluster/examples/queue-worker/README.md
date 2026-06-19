# queue-worker — a long-running background worker

A **worker** is a process that is *not* driven by HTTP requests: it pulls jobs
off a queue, processes a stream, or runs a polling loop continuously. Unlike
every other nagare app (which becomes a **Knative Service** that scales to zero
when no requests arrive), a worker renders to a plain **`apps/v1` Deployment** —
so it runs continuously, never scales to zero, and needs no HTTP port.

This example uses the public `gcr.io/knative-samples/helloworld-go` image with a
`command` override that turns it into a visible worker (it prints `working` and
refreshes a `/tmp/heartbeat` file every 5 seconds) and runs **2 replicas**, so it
deploys with no build step and no registry credentials of your own.

It also declares an **exec liveness probe** (`test -f /tmp/heartbeat`): because a
worker is headless (no HTTP port), Kubernetes can only restart it on a *crash*, so
the probe is what recovers a loop that **hangs without exiting**. After the probe
fails `failureThreshold` times, the kubelet restarts the container. See
[Liveness probes for hung workers](../../../docs/user/workers.md#liveness-probes-for-hung-workers).

## Deploy

```bash
# Dry-run (no cluster needed): see the rendered apps/v1 Deployment and build action.
nagarectl worker deploy -f cluster/examples/queue-worker/nagare/Config.hs --dry-run
```

A real `nagarectl worker deploy` (against a running cluster) builds/pushes only
if the config is not a prebuilt image, applies the Deployment, and waits for the
rollout:

```text
Applying apps/v1 Deployment queue-worker to namespace personal ...
deployment "queue-worker" successfully rolled out
Worker queue-worker is running (2 replicas requested) in namespace personal.
```

Prove it with stock `kubectl`:

```bash
kubectl get deployment queue-worker -n personal   # READY 2/2
kubectl get ksvc -n personal                      # queue-worker is NOT listed
kubectl logs deploy/queue-worker -n personal --tail=5
```

## Operate it with kubectl

A worker is a standard Deployment, so you scale, pause, and remove it with stock
commands:

```bash
kubectl scale deployment queue-worker -n personal --replicas=4   # scale up
kubectl scale deployment queue-worker -n personal --replicas=0   # pause (no pods)
kubectl delete deployment queue-worker -n personal               # remove
```

See [Running workers](../../../docs/user/workers.md) for the full guide.
