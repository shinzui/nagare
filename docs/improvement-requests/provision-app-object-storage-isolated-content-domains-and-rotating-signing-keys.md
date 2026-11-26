---
type: Improvement Request
title: Provision app object storage, an isolated wildcard content domain, and rotating signing keys
description: Let an application declare a private GCS bucket with per-workload access and signBlob, route a wildcard host on a separate registrable domain to one workload, and receive a generated signing key set with scheduled rotation, so services such as Hanmoto that serve untrusted content need no hand-made cloud resources.
generated:
  by: process:claude-code
  at: "2026-11-24T00:00:00Z"
requestId: IR-55
status: completed
acceptedAt: "2026-11-24T00:00:00Z"
completedAt: "2026-11-26T08:55:00Z"
resolution: "MasterPlan 39 delivered all three capabilities at 9fa0b262. An app object bucket is a typed standalone scope with expiry rules and per-workload read-write or read-only access: MinIO users on a local context, and on a cloud context a private GCS bucket (uniform access, enforced public access prevention) reached by each workload's own Google service account through workload identity federation, with signing as itself and no key (ADR 42). A content domain on its own registrable domain routes a wildcard, its apex and fixed hosts to one worker with the Host header intact under a DNS-01 wildcard certificate. A generated Ed25519 key set rotates in place through three slots, signers and verifiers reading files (ADR 41). Each retirement is a review naming what it destroys. Evidence: mp39 (local) and ep285 (cloud) transcripts in EP-283 to EP-286. Key sets need a release whose admin API image carries nagare-keyset."
targetPlan: mori://shinzui/nagare/masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys
origin: mori://shinzui/hanmoto
acceptanceCriteria:
  - id: AC-1
    statement: An application can declare a private object-storage bucket as a typed managed resource with uniform bucket-level access, public access prevention, and prefix-scoped lifecycle rules. A local context provides the same declaration through its packaged object store.
    verification: Offline render and reviewed-change tests show the bucket, its lifecycle rule, and its absence of public bindings; a local-substrate test writes and reads through the same application configuration.
  - id: AC-2
    statement: Each workload of a multi-workload application receives its own cloud identity with exactly the declared bucket access (read-write or read-only) and, when declared, permission to sign blobs as itself, with no exported service-account key.
    verification: A disposable-cluster test proves the API workload can write and produce a V4 signed URL, the gateway workload can only read, and neither identity has a downloadable key.
  - id: AC-3
    statement: An application can route a wildcard host on a registrable domain separate from the context's application domain, plus one fixed share host, to one named workload, with wildcard TLS issued through DNS-01 and the original Host header preserved.
    verification: Requests to two different wildcard subdomains reach the same workload with their own Host headers under a valid wildcard certificate; no other application's domains are affected.
  - id: AC-4
    statement: An application can declare a generated Ed25519 signing key set as a managed secret with a rotation schedule. Workloads see the active key and the previous key during an overlap window, and rotation is recorded.
    verification: A rotation test shows the overlap window, a recorded rotation, and that a signer and verifier restarted mid-rotation still agree.
  - id: AC-5
    statement: Removing any of these declarations is a reviewed change that names the data or trust it destroys before applying.
    verification: Reviewed-change output for removing the bucket, domain, and key set lists each destructive effect.
---

# Improvement Request: provision app object storage, an isolated wildcard content domain, and rotating signing keys

**Authored by:** a `claude-code` session specifying `mori://shinzui/hanmoto`.
**Addressed to:** `shinzui/nagare` agents.
**Status:** proposed.
**Created:** 2026-11-24.

## Why

Hanmoto (`mori://shinzui/hanmoto`) is Kikan's publication service for HTML that agents and people
author (`mori://shinzui/kikan/docs/hanmoto-publication-boundary`). Its specification,
`mori://shinzui/hanmoto/docs/initial-spec`, sections 5, 6 and 9, assigns its infrastructure to
Nagare. Nagare provides it without interpreting publications. Published HTML is untrusted active
content, so its serving has requirements an ordinary Knative app does not:

- **Bytes in a private bucket.** Revision bytes live in GCS. The API workload writes them and
  produces V4 signed upload URLs; a separate gateway workload only reads. Today an app has no typed
  way to declare a bucket or per-workload storage access, and Nagare's buckets are platform-owned
  (state, backups, images).
- **An isolated content origin.** Content is served from one subdomain per publication on a
  registrable domain separate from every application domain, so application and Shomei cookies are
  never sent there. That needs a wildcard host on another domain routed to one workload, with
  wildcard TLS, plus a fixed share host for guest links. Nagare's wildcard support today is per
  application namespace under the context's own domain.
- **Signing keys with rotation.** Hanmoto signs short-lived view grants with Ed25519 keys. The keys
  should be generated and rotated by the platform, with the previous key kept during an overlap so
  outstanding grants still verify. Environment and secrets support today is operator-supplied
  values, not generated and rotated key sets.

None of this is Hanmoto-specific. Any service that stores user files, serves untrusted HTML, or
signs tokens has the same needs. The request is written generically.

## Requested Change

The acceptance criteria above state the outcome. Nagare chooses the typed configuration surface,
how workload cloud identity is realized on its single-node substrate, and how rotation is scheduled.
Hanmoto's deployment would declare one bucket, two workload identities, one content domain with its
share host, and one key set.

## Out of scope

- Any knowledge of publications, revisions, or grants. Nagare provisions; Hanmoto decides.
- CDN fronting of the content domain. The existing edge-CDN capability may be applied later.
