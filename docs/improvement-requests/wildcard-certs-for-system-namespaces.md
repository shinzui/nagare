---
type: Improvement Request
title: Scope namespace wildcard certificates to app namespaces instead of every namespace
description: cluster-enable-tls sets namespace-wildcard-cert-selector to {}, so Knative requests a public Let's Encrypt wildcard for kube-system, kube-node-lease, cert-manager and every other namespace, spending the registered domain's weekly certificate limit on names that never serve traffic.
timestamp: "2026-09-14T17:49:14Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:50:00Z"
requestId: IR-23
status: completed
acceptedAt: "2026-09-14T04:26:09Z"
completedAt: "2026-09-14T17:49:14Z"
resolution: "ExecPlan 138 replaces the all-namespace wildcard selector with the opt-in nagare.dev/app-namespace=true label, labels personal during bootstrap, and reconciles the label across every Nagare application workload path while refusing fixed platform namespaces. Parsed diagnostics reject internal ACME names, public wildcards in unlabeled namespaces, and public wildcards on the wrong issuer. A fresh disposable cluster issued the personal wildcard only through letsencrypt-dns and none for unlabeled namespaces; all 520 Haskell tests, strict bundle validation, and the full native flake gate passed. The operator guides document rate-budget and Certificate Transparency consequences plus reviewed stale-object cleanup, and ADR 10 records the label as a security boundary."
targetPlan: docs/plans/138-keep-bootstrap-tls-issuance-within-intended-names.md
origin: mori://shinzui/nagare
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-14T14:45:36Z"
    document_timestamp: "2026-09-14T04:26:09Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: high
    context: >-
      Audited the request against the current wildcard selector and namespace
      creation paths, ExecPlan 138's zero-of-four milestone state, and MasterPlan 22;
      the target plan remains not started, so the accepted status and Nagare fit remain accurate.
verified:
  by: process:openai-codex
  at: "2026-09-14T14:45:36Z"
---

# Improvement Request: issue wildcard certificates only for namespaces that host apps

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by
[ExecPlan 138](../plans/138-keep-bootstrap-tls-issuance-within-intended-names.md).
**Created:** 2026-09-14.


## Why

`cluster/bootstrap/knative-serving/config-network-tls.yaml` (`v0.2.2`) sets
`namespace-wildcard-cert-selector: "{}"`, which its own comment glosses as "one wildcard cert PER
NAMESPACE ... matching every namespace". Within seconds of `nagare cluster-enable-tls` on the `labs`
cluster, cert-manager was running DNS-01 orders for nine wildcards:

```text
cert-manager, default, knative-serving, kourier-system, kube-node-lease, kube-public,
kube-system, nagare-system, personal   (*.<namespace>.labs.topagentnetwork.net)
```

Only `personal` hosts an application. Switching to the production directory, as
`docs/user/cluster-bootstrap.md` and the ACME-directory flow in `contexts.md` recommend, then issues nine
**production** certificates, and nine more every time the operator re-issues. Let's Encrypt limits
new certificates per registered domain (`topagentnetwork.net` here, shared with every other use of the
company domain), so a lab cluster spends that budget on `kube-node-lease` and `kube-system`. Knative's
own ConfigMap documentation suggests excluding those with a `kubernetes.io/metadata.name` selector.
Each namespace added to the cluster later (observability, databases, brokers) adds another public
certificate, and publishes its name in Certificate Transparency logs.


## Requested change

- Replace `{}` with an opt-in selector, e.g. `matchLabels: {nagare.dev/app-namespace: "true"}`,
  applied by the namespace-creating paths (`cluster-bootstrap` for `personal`, `nagarectl deploy`
  for a new namespace). Alternatively, use a `NotIn` expression that excludes `kube-*`, `cert-manager`,
  `knative-serving`, `kourier-system` and `nagare-system`.
- Mention the per-domain rate limit and the Certificate Transparency exposure in
  `cluster-bootstrap.md` next to the production switch.


## Required verification

- A bootstrap test that after `cluster-enable-tls` only app namespaces have a
  `*.<namespace>.<baseDomain>` certificate, and that deploying into a new namespace through
  `nagarectl deploy` gets one.


## Acceptance

On a fresh cluster with TLS enabled, `kubectl get certificate -A` lists public wildcard certificates
only for namespaces that host apps.


## Non-goals

Switching away from per-namespace wildcards, or supporting HTTP-01.
