---
type: Improvement Request
title: Keep Knative's system-internal certificate off the public ACME issuer
description: cluster-bootstrap sets only config-certmanager's issuerRef, so Knative's routing-serving-certs (kn-routing, data-plane.knative.dev) is re-issued through letsencrypt-dns, and every run sends Let's Encrypt an order it rejects.
timestamp: "2026-09-14T17:49:14Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:50:00Z"
requestId: IR-22
status: completed
acceptedAt: "2026-09-14T04:26:09Z"
completedAt: "2026-09-14T17:49:14Z"
resolution: "ExecPlan 138 explicitly assigns system-internal and cluster-local certificate roles to knative-selfsigned-issuer and keeps only external domains on letsencrypt-dns. Because the latest and final archived net-certmanager v1.14.0 release aliases its three issuer pointers, Nagare now applies a focused source patch at the exact release commit, runs a native upstream regression, embeds the reproducible Linux/amd64 controller image in the immutable platform payload, and imports it directly into k3s. A fresh disposable cluster proved both internal roles self-signed and the labeled public wildcard on letsencrypt-dns; the fail-closed certificate-policy diagnostic passed, all 520 Haskell tests passed, and the full native flake gate passed. ADR 10 records the durable boundary."
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
      Audited the request against the current Knative and cert-manager configuration,
      ExecPlan 138's zero-of-four milestone state, and MasterPlan 22; the target plan
      remains not started, so the accepted status and Nagare fit remain accurate.
verified:
  by: process:openai-codex
  at: "2026-09-14T14:45:36Z"
---

# Improvement Request: pin the internal Knative issuers to the self-signed issuer

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by
[ExecPlan 138](../plans/138-keep-bootstrap-tls-issuance-within-intended-names.md).
**Created:** 2026-09-14.


## Why

On the `labs` cluster (`v0.2.2`: Knative `knative-v1.22.0`, net-certmanager `v1.14.0`), the
cert-manager `Certificate` `knative-serving/routing-serving-certs` never becomes ready:

```text
Reason:   IncorrectIssuer
Message:  Issuing certificate as Secret was previously issued by "ClusterIssuer.cert-manager.io/knative-selfsigned-issuer"
```

Its request `routing-serving-certs-2` names issuer `letsencrypt-dns` and failed with:

```text
Failed to create Order: 400 urn:ietf:params:acme:error:rejectedIdentifier: Invalid identifiers requested :: Cannot issue for "kn-routing": Domain name needs at least one dot
```

The Knative certificate behind it carries `networking.knative.dev/certificate-type: system-internal`
and `dnsNames: ["kn-routing", "data-plane.knative.dev"]`. It was first issued by
`knative-selfsigned-issuer`. After `cluster-bootstrap` patched `config-certmanager` with
`cluster/bootstrap/knative-serving/config-certmanager.yaml`, it was reissued through the public DNS-01
issuer. That patch sets only `issuerRef`. The `systemInternalIssuerRef` and `clusterLocalIssuerRef`
keys appear only inside the ConfigMap's `_example` block, so they are not set, and net-certmanager
used `issuerRef` for this certificate. A later `cluster-bootstrap` run created a fresh request against
the **production** Let's Encrypt directory, which was rejected the same way. `system-internal-tls` is
`Disabled`, so nothing is served with this certificate today. It is still a permanently not-ready
object and a stream of rejected orders against a shared ACME account, and it would break as soon as
internal TLS is enabled.


## Requested change

- Set `systemInternalIssuerRef` and `clusterLocalIssuerRef` explicitly to
  `knative-selfsigned-issuer` in `config-certmanager.yaml`, next to `issuerRef`.
- Have `cluster-bootstrap` (or a status check) flag any cert-manager `Certificate` whose issuer is
  the ACME issuer and whose `dnsNames` include a name without a dot.
- Re-check the net-certmanager pin: `v1.14.0` against Knative Serving `v1.22.0` is the skew the
  justfile already notes, and the issuer-fallback behaviour may be part of it.


## Required verification

- A render or kind/k3d test that, after bootstrap with external-domain TLS enabled, every
  `system-internal` and `cluster-local` certificate names the self-signed issuer and is `Ready`.


## Acceptance

After `cluster-bootstrap` and `cluster-enable-tls` on a fresh cluster, `kubectl get certificate -A`
shows no not-ready certificates, and no ACME order is created for a non-public name.


## Non-goals

Enabling `system-internal-tls` or `cluster-local-domain-tls`.
