# Bounded one-shot Job runs

This component limits deadline-bounded Pods in the `personal` namespace to two
concurrent admissions. It is the cluster-side backpressure mechanism for the
one-shot `Nagare.Dsl.Job` workload kind.

Kubernetes calls this ResourceQuota scope `Terminating`. The name is easy to
misread: it selects a Pod whose own `spec.activeDeadlineSeconds` is set, not a
Pod that is already shutting down. It also cannot select labels. Consequently,
every deadline-bounded Pod in `personal` shares this pool, whether or not it was
rendered by Nagare. A Job intended for agent execution must set a positive
deadline; the Nagare renderer copies that value to both the Job spec and Pod
template so the Job controller and this quota enforce the same wall clock.

The checked-in limits exactly admit two Jobs using the renderer defaults: each
requests 250m CPU and 512Mi memory and is limited to 1 CPU and 1Gi memory. A
third Job object can be created, but its controller cannot create a Pod. The Job
reports a `FailedCreate` event containing `exceeded quota:
nagare-terminating-jobs`; there is no third Pending Pod. A scheduler must treat
that event as backpressure and retry after an admitted Job releases its slot.

## Install and inspect

From the repository root, after checking the active kubectl context:

```bash
kubectl config current-context
just job-runs-bootstrap
just job-runs-status
```

Both bootstrap steps are declarative, so rerunning them converges the namespace
and quota to the checked-in state. The status recipe prints current usage and
the quota's recent events.

For a direct inspection:

```bash
kubectl -n personal get resourcequota nagare-terminating-jobs
kubectl -n personal describe resourcequota nagare-terminating-jobs
kubectl -n personal get pods \
  -o custom-columns=NAME:.metadata.name,DEADLINE:.spec.activeDeadlineSeconds,PHASE:.status.phase
```

Lowering a quota does not evict existing Pods; it blocks later admissions.
Inspect current usage before changing the limits. If an unrelated
deadline-bounded Pod consumes the shared pool, raise or remove only this quota
temporarily, document the collision, and revisit namespace isolation. Do not
disable the cluster's network-policy controller as a workaround.

Job TTL cleanup deletes a completed Job and its owned Pods, including the
`emptyDir` scratch data. It cannot delete the separately applied ServiceAccount
or NetworkPolicy because those objects were created before the Job had a UID.
Delete those two resources by exact Job name after the run is gone.
