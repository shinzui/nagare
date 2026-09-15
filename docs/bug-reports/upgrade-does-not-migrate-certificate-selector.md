---
type: Bug Report
title: Upgrade does not migrate the namespace wildcard certificate selector
description: >-
  A TLS-enabled 0.2.2 cluster retains its broad wildcard selector during a 0.3.0
  upgrade, so the new certificate-policy gate fails and stale TLS Secrets remain.
generated:
  by: process:openai-codex
  at: "2026-09-15T13:52:11Z"
bugId: BUG-3
status: confirmed
severity: degraded
origin: mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use
affects: mori://shinzui/nagare/packages/cluster-bootstrap
capability: mori://shinzui/nagare/okf/capabilities/concepts/CAP-4
affectedVersion: 0.3.0
environment: cloud cluster upgraded from 0.2.2 after external-domain TLS was enabled
observed: >-
  Cluster bootstrap leaves namespace-wildcard-cert-selector as {}, then fails the
  0.3.0 policy on eight legacy system-namespace wildcards; ownerless TLS Secrets remain after convergence.
expected: >-
  A supported release upgrade should migrate shipped TLS configuration before its
  policy gate, preserve opted-in application certificates, and identify stale managed artifacts.
reproduction:
  - On 0.2.2, enable external-domain TLS so config-network contains namespace-wildcard-cert-selector {}.
  - Allow Knative to issue wildcard certificates and Secrets in system namespaces.
  - Plan and apply a 0.3.0 platform upgrade through cluster bootstrap.
  - Observe the certificate-policy failure and, after selector convergence, the ownerless legacy TLS Secrets.
workaround: >-
  During the upgrade window, run NAGARE_UPGRADE_APPLY=1 nagare cluster-enable-tls,
  then inventory owners and delete only the exact obsolete Certificate chains and matching Secrets.
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-15T13:52:11Z"
    document_timestamp: "2026-09-15T13:52:11Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: unspecified
    context: >-
      Reviewed against the live 0.2.2 selector, the 0.3.0 payload and policy output,
      and the recovered cluster inventory with the valid personal wildcard preserved.
---

# Upgrade does not migrate the namespace wildcard certificate selector

The 0.3.0 payload narrows fresh TLS enablement to namespaces labeled
`nagare.dev/app-namespace=true`, but `cluster-bootstrap` deliberately omits the deferred TLS
ConfigMap. An already TLS-enabled cluster therefore retains the 0.2.2 selector `{}` and immediately
violates the new policy. On the live cluster this produced eight violations across system
namespaces. Applying the new selector removed obsolete Certificate chains, but their unowned TLS
Secrets were outside the policy inventory and remained until exact-name cleanup.

The fix should stage this configuration migration in the reviewed Kubernetes diff, apply it before
the policy gate, and report exact stale chains and Secrets. A 0.2.2 fixture must preserve a valid
opted-in wildcard, converge all obsolete managed artifacts, and remain idempotent across retries.
