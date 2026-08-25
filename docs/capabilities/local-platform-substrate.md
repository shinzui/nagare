---
title: "Local platform substrate"
type: Capability
description: "Run the Nagare deploy, data, backup, auth, and TLS paths on a laptop without a GCP account."
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
capabilityId: CAP-3
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - cluster-bootstrap
  - nagarectl
interface:
  - "nagare local-up"
  - "nagare local-bootstrap"
  - "nagare local-minio"
  - "nagare local-smoke"
evidence:
  - kind: test
    resource: scripts/local-smoke.sh
    proves: A zero-cloud run deploys an app, writes data, snapshots and restores through MinIO, checks HTTP, and tears down test state.
  - kind: guide
    resource: docs/user/local-development.md
    proves: The k3d registry, Knative bootstrap, MinIO, local TLS, and auth-plane workflow is documented for operators.
  - kind: example
    resource: cluster/examples/uploads-volume/nagare/Config.hs
    proves: The smoke path uses a shipped typed app with persistent storage rather than a synthetic manifest.
---

# Local platform substrate

Local mode creates a k3d cluster and registry, installs the same Knative/Kourier serving layer used
in cloud mode, and substitutes MinIO for GCS. Local TLS and the auth plane can be installed as part
of the same operating shape. Application configuration and `nagarectl` commands stay target-aware
instead of forking into a separate local implementation.

## Limits

- Local mode depends on a working Docker daemon and host ports 80 and 443.
- It approximates a single-node cluster; it does not reproduce GCP IAM, Cloud DNS, load balancers,
  or Artifact Registry.
- Hostname and registry behavior can require local resolver or Docker insecure-registry setup.
- The smoke test is destructive only to its own named fixtures, but it assumes the local cluster and
  object store are already running.
