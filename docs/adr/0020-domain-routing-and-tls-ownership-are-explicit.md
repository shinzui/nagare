---
title: "Domain routing and TLS ownership are explicit"
status: accepted
date: 2026-09-14
authors: [shinzui]
related:
  - docs/plans/131-make-apex-and-multi-domain-routing-production-ready.md
  - docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md
  - docs/adr/0010-the-active-context-owns-the-acme-identity.md
  - docs/adr/0014-the-active-context-owns-the-vm-shape.md
---

# ADR 20 — Domain routing and TLS ownership are explicit

## Status

Accepted, 2026-09-14. Implemented by
[ExecPlan 131](../plans/131-make-apex-and-multi-domain-routing-production-ready.md).

## Context

Nagare's ordinary, static, and server workloads previously disagreed about
domain shape and canonical selection. The platform owned a wildcard DNS record
but no exact base-domain record, even though DNS wildcard synthesis cannot
answer the zone apex. A deploy could also retarget a hostname claimed by
another workload. Origin certificates and CDN edge certificates were implicit,
and Google CDN could receive hostnames its one-name certificate did not cover.

These are ownership failures rather than renderer details. The same hostname is
a Kubernetes resource name, DNS owner, SNI name, advertised URL, and deletion
key. DNS, routing, origin TLS, and edge TLS have different controllers and must
not be treated as one readiness signal.

## Decision

All three web workload kinds use one normalized `DomainSpec` list. A non-empty
list has exactly one explicitly canonical entry and every entry selects either
automatic origin TLS or a supplied namespace-local TLS Secret. Canonical
selection controls the advertised URL only; Nagare does not redirect alternate
hostnames.

Pulumi owns both `*.<baseDomain>` and the exact `<baseDomain>` A records. The
wildcard always targets the VM. The apex targets the VM unless the standing
Google CDN exists, in which case it targets the CDN global IP. Application
deploys read all claims and routes before mutation, refuse conflicting
ownership, and wait for every DomainMapping and covering origin certificate.

Automatic origin TLS uses Knative and net-certmanager. It is supported for the
context base zone and other authoritative Cloud DNS parent zones in the active
project. An external authority requires an explicitly configured solver or a
supplied Secret containing `tls.crt` and `tls.key`. Every cloud read and write is
pinned to the active project, consistent with ADR 9; ACME identity remains
context-owned under ADR 10.

Google CDN uses a Certificate Manager DNS authorization, one certificate for
the apex and `*.<baseDomain>`, and exact plus wildcard certificate-map entries.
Migration is an explicit `legacy` → `prepare` → `certificate-map` state machine.
Prepare leaves the legacy proxy serving while the replacement is issued; the
status command offers activation only after `ACTIVE`. Google accepts only the
apex and one-label names under the base domain. Cloudflare remains the provider
for unrelated CDN zones.

## Consequences

The base domain can safely host an ordinary landing workload, and multi-domain
deployments behave identically across workload kinds. Conflicts, unsupported
certificate authority, missing supplied-secret keys, and unhealthy routes fail
before success is reported. `domains list` exposes partial observations while
`domains check` is a strict operational gate.

DNS-zone replacement remains protected by ADR 14. Existing CDN stacks retain
legacy serving until an operator previews and advances the certificate mode.
Certificate Manager adds a DNS-authorization record and service API, but avoids
per-host edge-certificate changes for every supported first-level hostname.

The stronger model intentionally does not add canonical redirects, multiple
platform base domains, or credentials for arbitrary external DNS providers.
