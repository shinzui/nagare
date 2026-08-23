---
title: "Long-running workers"
type: Capability
description: "Run non-HTTP background processes as typed Kubernetes Deployments with fixed replicas, volumes, resources, and optional liveness or startup probes."
generated:
  by: codex/gpt-5
  at: "2026-08-23T21:36:15Z"
capabilityId: CAP-14
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: unreleased
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Worker"
  - "nagarectl worker deploy"
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/WorkerSpec.hs
    proves: Replica, command, probe, config-loading, round-trip, PVC, and Deployment rendering behavior is tested with goldens.
  - kind: example
    resource: cluster/examples/queue-worker/nagare/Config.hs
    proves: A shipped typed worker runs a queue consumer without an HTTP service.
  - kind: example
    resource: cluster/examples/multi-workload-app/nagare/Config.hs
    proves: Workers can also participate in an application rollout with shared image and bindings.
  - kind: guide
    resource: docs/user/workers.md
    proves: Standalone deploy, replicas, probes, environment, volumes, and operations are documented.
---

# Long-running workers

Workers are `apps/v1` Deployments rather than Knative Services: they do not require a listening
port, do not scale to zero, and run a fixed replica count. The typed model supports command
overrides, scoped environment, persistent volumes, resource requests and limits, and HTTP, TCP, or
exec health probes. They can deploy alone or as part of a multi-workload application.

## Limits

- Day-2 worker operations use stock Kubernetes tooling after deployment; there is only a dedicated
  `nagarectl worker deploy` command today.
- Autoscaling and queue-depth controllers are outside this capability.
- The renderer is strongly golden tested, while a standalone live worker acceptance run is not part
  of the default CI suite.
