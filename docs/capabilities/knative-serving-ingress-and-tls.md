---
title: "Knative serving, ingress, and TLS bootstrap"
type: Capability
description: "Install and configure Knative Serving, Kourier ingress, cert-manager, wildcard domains, and optional automatic TLS on a k3s cluster."
generated:
  by: codex/gpt-5
  at: "2026-08-23T21:36:15Z"
capabilityId: CAP-4
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: unreleased
packages:
  - cluster-bootstrap
interface:
  - "just cluster-bootstrap"
  - "just cluster-enable-tls"
  - "just deploy-hello"
evidence:
  - kind: module
    resource: cluster/bootstrap/knative-serving/config-network.yaml
    proves: Nagare carries the network-layer configuration it applies to Knative Serving.
  - kind: example
    resource: cluster/examples/hello-knative-service/service.yaml
    proves: A minimal Knative service is shipped as the post-bootstrap smoke workload.
  - kind: guide
    resource: docs/user/cluster-bootstrap.md
    proves: Namespace creation, pinned component installation, domain wiring, readiness, and TLS enablement are documented.
  - kind: test
    resource: scripts/live-test.sh
    proves: The live harness checks the deployed hello service and platform endpoints on a real target.
---

# Knative serving, ingress, and TLS bootstrap

The bootstrap installs cert-manager, Knative Serving, Kourier, and net-certmanager, then configures
the registry skip list, base domain, ingress, and certificate integration. It starts HTTP-first so
DNS can be delegated before automatic external-domain TLS is enabled.

## Limits

- The bootstrap downloads pinned upstream manifests at execution time and therefore needs network
  access; it does not vendor the complete upstream installation.
- Cloud TLS requires a delegated domain and DNS credentials. Local mode uses a separate local
  issuer.
- Re-running the recipes applies convergent resources, but there is no hermetic Kubernetes
  conformance suite; the strongest proof is the live harness and operator runbook.
