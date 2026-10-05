# MP-23 work held by operator instruction (2026-10-05)

The operator paused new finding fixes after the F59/F63–F65 checkpoint, pending an exhaustive
enumeration review and a structural proposal for one proof-based exit rule (relayed by nagare-84).
Work that was written but not committed is kept here so that review can use it.

## `f63-worker-deployment.patch`

This extends F63's landed-update stop from database StatefulSets to application worker Deployments,
and adds the recovery model scenario "create with a worker, bad worker update, corrected update".
Apply it with `git apply` at the checkpoint commit.

- **Without the patch (observed, the scenario alone):** the fault-free worker update fails I1. A
  worker Deployment that lands unready has no exit.
- **With the patch (observed, fast tier, 2026-10-05):** the fault-free case passes. The fault sweep
  over the worker scenario still reports 9 I1 violations:
  - `LandsUnready` on the worker create: F16's create-path stop admits only a Knative Service.
  - `LandsUnready` on the Service in a worker review: two workloads are unready.
  - `Replaced` on the worker: F56 covers only Knative Services.
  - `Deleted` on the worker or the Service after a stop.

These are the per-kind allowlist instances the enumeration review is meant to cover with one rule.
