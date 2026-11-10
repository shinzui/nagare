---
title: "Application Pods hold no Kubernetes API token unless they name an account"
status: accepted
date: 2026-11-09
authors: [shinzui]
related:
  - docs/masterplans/34-extend-application-workloads-with-independent-health-checks-explicit-pod-policy-and-a-native-arm64-sdk.md
  - docs/plans/254-add-independent-application-worker-and-web-health-checks.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
---

# ADR 36 — Application Pods hold no Kubernetes API token unless they name an account

## Status

Accepted and implemented by [EP-254](../plans/254-add-independent-application-worker-and-web-health-checks.md). Live confirmation is EP-256.

## Context

Web, worker and task Pods mounted the namespace's default service-account token, so a pre-deploy task holding the
maintenance database login also held a Kubernetes credential nobody had asked for. Knative Serving 1.22 admits
`automountServiceAccountToken` only when it is `false` (`pkg/apis/serving/fieldmask.go`), and it has no Pod termination
field. Its revision's `timeoutSeconds`, 300 by default, is the Pod's grace period.

## Decision

A web, worker or task with no `serviceAccount` renders `automountServiceAccountToken: false`. Naming an account renders
`serviceAccountName` alone, so one rule holds for all three and the token follows that account's own setting. The
`default` account cannot be named, and there is no boolean to re-enable it. Nagare authors neither the account nor its
RBAC.

A web probe's type holds independent readiness, liveness and startup checks, and a port other than the serving port is
refused at load because Knative would rewrite it silently. A worker's shutdown allowance is a typed field rendered as
`terminationGracePeriodSeconds`. A web Pod's allowance stays the Knative revision timeout.

## Consequences

Every existing workload's rendered bytes change on its next deploy, visible in the saved review, and a workload that
reads the Kubernetes API must name an account first. A Knative Service naming a missing account is refused at admission,
while a worker or task Pod waits unscheduled until the account exists.
