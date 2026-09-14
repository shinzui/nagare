---
type: Improvement Request
title: Wait for the Knative webhook before cluster-bootstrap patches Knative ConfigMaps
description: On a fresh cluster, cluster-bootstrap applies serving-core and immediately patches config-network, config-certmanager and friends, which the not-yet-ready Knative validating webhook rejects, so the first run fails partway.
timestamp: "2026-09-14T03:42:01Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:40:00Z"
requestId: IR-21
status: accepted
acceptedAt: "2026-09-14T03:42:01Z"
targetPlan: docs/plans/132-make-cluster-bootstrap-wait-for-knative-webhooks.md
origin: mori://shinzui/nagare
---

# Improvement Request: make `cluster-bootstrap` pass on its first run

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** accepted for implementation by
[ExecPlan 132](../plans/132-make-cluster-bootstrap-wait-for-knative-webhooks.md).
**Created:** 2026-09-14.


## Why

The first `nagare cluster-bootstrap` on the new `labs` cluster (`v0.2.2`, node `Ready` for about a
minute) exited 1:

```text
Error from server (InternalError): Internal error occurred: failed calling webhook "config.webhook.serving.knative.dev": failed to call webhook: Post "https://webhook.knative-serving.svc:443/config-validation?timeout=10s": no endpoints available for service "webhook"
error: recipe `cluster-bootstrap` failed on line 161 with exit code 1
```

The `justfile` waits for cert-manager (`kubectl -n cert-manager rollout status deploy/cert-manager-webhook`)
before applying the issuer, but after `kubectl apply -f …/serving-core.yaml` it goes straight to
`kubectl -n knative-serving patch configmap config-network`, with no equivalent wait. Every Knative
ConfigMap patch goes through that validating webhook. After
`kubectl -n knative-serving rollout status deploy/webhook` succeeded, a second run of the recipe exited
0 and stamped the cluster. The recipe is idempotent, so no damage was done, but a first run always
failing on a fresh cluster is noise that looks like a real problem.


## Requested change

- Add `kubectl -n knative-serving rollout status deploy/webhook` (with a timeout) after applying
  `serving-core.yaml`, and the matching wait for `net-certmanager-webhook` before patching
  `config-certmanager`.
- Consider a short retry around the ConfigMap patches, since a rolled-out Deployment can still have no
  endpoints for a moment.


## Required verification

- The local bootstrap test (k3d) run from an empty cluster passes on the first invocation.


## Acceptance

`nagare cluster-bootstrap` on a newly created cloud cluster exits 0 the first time.


## Non-goals

Changing the pinned Knative, cert-manager or net-certmanager versions.
