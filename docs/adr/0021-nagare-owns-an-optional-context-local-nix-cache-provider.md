---
title: "Nagare owns an optional context-local Nix cache provider"
status: accepted
date: 2026-09-16
authors: [shinzui]
related:
  - docs/plans/96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
  - docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md
  - docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md
  - docs/adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md
  - mori://shinzui/kotei/masterplans/10-first-class-shared-nix-cache-infrastructure
---

# ADR 21 — Nagare owns an optional context-local Nix cache provider

## Status

Accepted, 2026-09-16. Implemented by
[ExecPlan 96](../plans/96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md).

## Context

Nix-capable Kubernetes Jobs need to consume signed store closures without rebuilding them in
restricted Pods. The provider crosses cloud IAM, object storage, immutable release payloads,
managed PostgreSQL, cluster bootstrap, secrets, policy, backup, and observability. Treating it as
a consumer-specific service would split those responsibilities and risk multiple caches with
different trust roots in one Nagare context.

Attic also has three trust domains. Its JWT key authorizes API capabilities, its context-generated
NAR key signs store paths, and its GCS HMAC credential authorizes chunk storage. They have different
rotation and recovery behavior and must not become one release-global secret.

## Decision

Nagare owns one optional, cloud-only Attic provider per context. It is disabled by default. When
enabled, Nagare provisions a dedicated protected GCS bucket and HMAC key, a managed PostgreSQL
database, a digest-pinned server image, the `nagare-system` workloads, and a live-generated client
ConfigMap in `personal`. Consumers such as `mori://shinzui/kotei` opt individual Jobs into that
ConfigMap and own producer policy; they do not deploy another provider into the context.

The server remains a private ClusterIP. Producers push through a guarded port-forward using narrow,
expiring tokens. Reads are anonymous because Nix verifies NAR signatures. The immutable payload
contains templates, exact source/image pins, and tools, but no credential or universal public key.
The JWT and HMAC values enter the cluster only from context-owned sops ciphertext. Attic generates
the NAR key in PostgreSQL, and bootstrap publishes its live public half to consumers.

GCS stores rebuildable chunks in an unversioned bucket so garbage collection remains effective.
PostgreSQL backup is the signing-identity recovery boundary. Client policy permits HTTPS because
Attic's S3 backend can redirect downloads to presigned GCS URLs; Kubernetes NetworkPolicy cannot
restrict that egress by hostname.

## Consequences

Normal bootstrap and upgrades reconcile the enabled provider from one immutable Nagare release,
and disabling the context is non-destructive. Permanent retirement requires a separate reviewed
teardown of protected resources. Server upgrades must consider database migration compatibility;
rollback can require the matching PostgreSQL backup.

JWT, HMAC, and NAR keys rotate independently. JWT rotation revokes writers without changing Nix
trust. HMAC rotation needs an overlapping credential rollout. NAR rotation changes the consumer
ConfigMap and requires coordinated trust refresh, while database restore should preserve the key.

The cache improves only closure transfer on a hit. It is not an OCI registry, source of truth,
cross-context trust federation, or replacement for Nagare's public development/release Cachix.

Amendment (2026-11-22, [ExecPlan 278](../plans/278-let-a-context-choose-the-attic-nar-size-threshold-so-gcs-cache-hits-redirect.md)):
each context chooses Attic's chunking layout with `NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD`. Only a
single-chunk NAR is served as a presigned GCS redirect; a chunked NAR is reassembled and streamed
through the cache Pod, which made GCS-backed hits slower than the public cache (BUG-11). `0` stores
every NAR whole and gives up cross-NAR chunk deduplication, so GCS usage grows. The default stays
`65536`, and its rendered server configuration is byte-identical to earlier releases, so a context
that does not opt in sees no rollout. The setting applies to new uploads only; moving existing
chunked NARs is an operator reseed that keeps the cache row and therefore the signing key.
