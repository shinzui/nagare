---
title: "Multi-workload application rollouts"
type: Capability
description: "Deploy one application containing hooks, databases, a serving workload, and workers in a validated fail-fast rollout order."
generated:
  by: codex/gpt-5
  at: "2026-08-23T21:36:15Z"
capabilityId: CAP-7
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: unreleased
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Application"
  - "nagarectl app deploy"
requires:
  - CAP-6
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/ApplicationSpec.hs
    proves: Multi-workload validation, config loading, kind discrimination, and JSON round trips are tested.
  - kind: test
    resource: cli/nagarectl/test/AppDeploySpec.hs
    proves: Hooks, databases, service, and workers render and execute in order, with later phases aborted after failure.
  - kind: example
    resource: cluster/examples/multi-workload-app/nagare/Config.hs
    proves: A shipped config combines the workload forms behind one application identity.
  - kind: guide
    resource: docs/user/deploying-apps.md
    proves: The operator guide distinguishes single-workload deploy from application rollouts.
---

# Multi-workload application rollouts

An `Application` groups resources under one `nagare.dev/app` identity and validates shared image,
namespace, database references, broker bindings, and workload-name uniqueness. `nagarectl app deploy`
renders hooks, databases, service, and workers and advances through those phases in order. A failed
hook or database phase prevents later workloads from being applied.

This builds on [typed application deployment](typed-application-deployment.md) (CAP-6) for config
loading, image resolution, and manifest application.

## Limits

- Rollout ordering and failure behavior are proven by an injected executor, not a live
  multi-workload cluster acceptance test.
- Rollback is not transactional across all resource kinds; fail-fast prevents later phases but does
  not undo objects from successful earlier phases.
- The model is unreleased and may change before its first published version.
