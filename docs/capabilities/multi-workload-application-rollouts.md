---
title: "Multi-workload application rollouts"
type: Capability
description: "Deploy a typed application containing hooks, databases, a web Service, workers, and scheduled tasks through dependency-ordered reviewed scopes."
generated:
  by: process:openai-codex
  at: "2026-10-10T05:03:04Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-25T20:51:44Z"
    document_timestamp: "2026-08-25T20:51:44Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the capability, compatibility promise, and repository evidence for inclusion in
      the version 0.1.0 Nix release.
capabilityId: CAP-7
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "Nagare.Dsl.Application"
  - "nagarectl app check"
  - "nagarectl app deploy"
requires:
  - CAP-6
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/ApplicationSpec.hs
    proves: Multi-workload validation, config loading, kind discrimination, and JSON round trips are tested.
  - kind: test
    resource: cli/nagarectl/test/InventoryApplicationSpec.hs
    proves: Accepted images, database members, broker bindings, and scheduled tasks compile into reviewed application resources.
  - kind: test
    resource: cli/nagarectl/test/InventoryTransactionSpec.hs
    proves: Pre-deploy hooks wait for affected data and gate workload execution through the shared operation driver.
  - kind: example
    resource: cluster/examples/multi-workload-app/nagare/Config.hs
    proves: A shipped config combines the workload forms behind one application identity.
  - kind: guide
    resource: docs/user/deploying-apps.md
    proves: The operator guide distinguishes single-workload deploy from application rollouts.
---

# Multi-workload application rollouts

An `Application` groups resources under one `nagare.dev/app` identity and validates shared image,
namespace, database references, broker bindings, and workload-name uniqueness. `nagarectl app check`
validates an Application without context or provider access. In 0.4.0, `nagarectl app deploy` binds
an accepted image publication and explicit tag, then reviews dependency-ordered resources and
release history. Hooks declare their affected data resources, or explicitly declare no data effects;
their completion gates the workloads that depend on them.

This builds on [typed application deployment](typed-application-deployment.md) (CAP-6) for config
loading, image resolution, and manifest application.
Changes use [typed resource inventories](typed-resource-inventories.md) (CAP-21) and the
[reviewed operation ledger](reviewed-operation-ledger.md) (CAP-22), preserving unrelated scopes.

## Limits

- The saved scope and private native evidence supply apply and resume inputs; changing the config
  file does not change an admitted review.
- Rollback is not atomic across resource kinds. Completed effects remain recorded and owned;
  resume or a supported reviewed exit resolves interrupted work.
- Database recovery bindings, accepted broker/topic dependencies, protected-route ownership,
  and hook effects must be supplied where the application requires them. See the
  [deployment guide](../user/deploying-apps.md).
- The model is experimental and may change in a later release.
