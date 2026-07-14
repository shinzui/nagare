# agent-run-job — a bounded one-shot workload

This example uses `Nagare.Dsl.Job` for one finite execution rather than a
scheduled `Task` or continuously reconciled `Worker`. Its BusyBox command exits
successfully only when it runs as UID 65532, cannot write under `/etc`, can write
under `/scratch`, and has no mounted Kubernetes service-account token.

The image is pinned to a version tag for a readable example. Production runs
should use an immutable digest or a repository-specific tag that cannot be
moved. The renderer never invents a registry prefix: `jobImage` is an input, and
the `BuildSpec` decides whether a supplied deploy tag or prebuilt tag is used.

## Per-run inputs

Every real run needs a unique `jobName` and `NAGARE_RUN_ID`; Kubernetes Job Pod
templates are immutable, so reapplying changed work under an old name fails.
The example's `REPO_REF` shows the provisional repository coordinate shape:
`repo_<id>@<full-40-character-sha>`. Always use a full commit SHA, never a branch
or abbreviated revision. Change all three values before rendering another run.

The preset supplies a positive 1800-second deadline. Do not remove it for agent
execution: the renderer copies it to the Pod, which makes the Pod participate in
the namespace's `Terminating` ResourceQuota. A Job without a deadline is valid
for general use but bypasses that concurrency pool.

Compile and execute the config-as-program contract offline from the repository
root:

```bash
cd cli/nagarectl
cabal exec -v0 -- runghc -XGHC2024 \
  ../../cluster/examples/agent-run-job/nagare/Config.hs
```

The output is the validated `kind: Job` JSON envelope consumed by
`Nagare.Dsl.Load.loadJob`. The deterministic Kubernetes resources are exercised
by `cli/nagare-dsl/test/golden/job-agent-run.bundle.yaml` until a dedicated
`nagarectl job` command owns loading and applying them.

## Backpressure and networking

Install the two-slot quota with `just job-runs-bootstrap`. When two default Jobs
are active, applying a third Job object succeeds but its controller reports
`FailedCreate` with `exceeded quota: nagare-terminating-jobs`; it has no Pod.
Deleting or completing an admitted Job releases a slot and lets the controller
create the waiting Pod. Callers must observe Job events/status and retry instead
of waiting for a nonexistent third Pending Pod.

Every Job bundle contains a NetworkPolicy with empty ingress and egress rules.
The example therefore receives no network by default, including DNS. Forge,
cache, and result-sink connectivity must be granted through separate additive
policies selecting the specific opted-in Pod labels and destinations. Never add
a blanket egress rule to the base Job policy.

NetworkPolicy controllers reconcile asynchronously. On the local k3s
kube-router dataplane, a process that connected immediately at container start
could send traffic before the controller installed the new Pod IP's iptables
rules; the same connection was denied after reconciliation. Treat the policy as
steady-state isolation, not a fail-closed startup barrier. Do not run untrusted
agent code in production until the target CNI or an admission-time isolation
mechanism proves enforcement before the workload process starts.

## Scratch and cleanup

`/scratch` is a size-limited `emptyDir`. It exists only for the Pod lifetime and
is permanently lost when the Pod is deleted; copy durable results to an allowed
sink before exit. The root filesystem remains read-only.

`ttlSecondsAfterFinished` removes the completed Job and its Pods after one hour.
It does not remove the separately applied ServiceAccount or NetworkPolicy. After
the Job disappears, clean those by exact resource name:

```bash
kubectl -n personal delete serviceaccount,networkpolicy nagare-job-<run-name>
```

Use a concrete run name in place of `<run-name>`. Deletion is safe to retry with
`--ignore-not-found` when automating cleanup.
