---
title: "Bounded one-shot Jobs"
type: Capability
description: "Render finite Kubernetes Jobs with deadlines, hardened pod defaults, scratch space, network policy, and namespace-level admission backpressure."
generated:
  by: codex/gpt-5
  at: "2026-08-25T20:51:44Z"
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
verified:
  by: process:openai-codex
  at: "2026-08-25T20:51:44Z"
capabilityId: CAP-16
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - cluster-bootstrap
interface:
  - "Nagare.Dsl.Job"
  - "nagare job-runs-bootstrap"
  - "nagare job-runs-status"
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/JobSpec.hs
    proves: Job construction, config loading, round trips, deadlines, resources, hardening, ServiceAccount, NetworkPolicy, and bundle ordering are golden tested.
  - kind: module
    resource: cluster/bootstrap/job-runs/resourcequota.yaml
    proves: The personal namespace admits at most two deadline-bounded terminating workloads at once.
  - kind: example
    resource: cluster/examples/agent-run-job/nagare/Config.hs
    proves: A shipped typed config describes a finite agent execution with its runtime inputs.
  - kind: guide
    resource: docs/user/one-shot-jobs.md
    proves: The execution contract, scratch space, quota, hardening, and current integration boundary are documented.
---

# Bounded one-shot Jobs

The `Job` DSL models one finite execution and renders a ServiceAccount, NetworkPolicy, and hardened
Kubernetes Job bundle. Defaults include an active deadline, no retries, a finished-object TTL,
bounded resource requests and limits, a read-only root filesystem, dropped Linux capabilities,
seccomp, and ephemeral scratch space. A namespace ResourceQuota limits concurrent terminating Jobs
to two and exposes admission pressure through normal Kubernetes events.

## Limits

- There is intentionally no `nagarectl job` command. A scheduler or another platform integration
  loads and applies the rendered bundle.
- Admission backpressure is Kubernetes quota, not a fair queue; rejected creations must be retried by
  the caller.
- NetworkPolicy effectiveness depends on the cluster network plugin enforcing it.
- The DSL and local acceptance contract are complete, but no generic execution service is claimed.
