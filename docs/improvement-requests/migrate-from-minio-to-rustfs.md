---
type: Improvement Request
title: Migrate Nagare's local object store from MinIO to RustFS
description: Replace the MinIO-backed local S3 transport with a pinned RustFS deployment while preserving backup, restore, inventory evidence, existing data, and context isolation.
timestamp: "2026-10-03T22:23:48Z"
generated:
  by: process:openai-codex
  at: "2026-10-03T22:23:48Z"
requestId: IR-26
status: proposed
origin: mori://shinzui/nagare
acceptanceCriteria:
  - id: AC-1
    statement: A fresh local context installs and reconciles a persistent RustFS object store and seeds its bucket and namespace-local credentials without requiring a MinIO server or administrative client.
    verification: A disposable local cluster reaches readiness, repeated bootstrap converges without destructive changes, and objects survive a server pod restart.
  - id: AC-2
    statement: Database backup and restore, volume snapshot and restore, scheduled backup retention, signing-key escrow, and inventory receipt recovery retain their existing object keys and integrity guarantees on RustFS.
    verification: Native round-trip tests restore database and volume sentinels, verify escrow and receipt bytes, exercise listing and retention, and recover evidence after source-cluster loss through the offline object-store reader.
  - id: AC-3
    statement: RustFS preserves provider-side create-only semantics for both single PUT and multipart completion so concurrent or retried backups cannot overwrite an existing logical backup ID.
    verification: Tests use the deployed clients to race writes to one key, reject a duplicate single PUT and multipart completion with If-None-Match '*', compare the original bytes, and verify aborted multipart uploads do not become valid backups.
  - id: AC-4
    statement: Existing local MinIO data can be migrated to a separate RustFS volume through a reviewed, resumable S3 copy and verified before endpoint cutover or source retirement.
    verification: A populated MinIO fixture migrates backups, snapshots, escrow, and inventory evidence with key, size, and independently computed content-digest comparison; interruption, failed verification, and rollback tests preserve the source and account for writes made after cutover.
  - id: AC-5
    statement: Context resolution, managed-resource inventory, credential ownership, port forwarding, status, and clone-free platform packaging describe the RustFS deployment consistently and preserve local/cloud isolation.
    verification: Render and packaged-command checks cover fresh and legacy local contexts, reviewed resource renames and PVC retention, credential copies, non-default endpoints, and unchanged guarded cloud GCS behavior.
  - id: AC-6
    statement: RustFS server and bootstrap-client artifacts are pinned to verified upstream releases and immutable image digests for every supported local Linux architecture, with documented resource needs, upgrade, and rollback procedures.
    verification: Release and registry checks verify artifact provenance and linux/amd64 and linux/arm64 support; native smoke evidence records readiness, permissions, CPU, memory, backup throughput, and recovery, and current operator documentation uses the new commands and defaults.
reviews:
  - kind: model
    reviewer: openai-codex
    reviewed_at: "2026-10-03T22:23:48Z"
    document_timestamp: "2026-10-03T22:23:48Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: gpt-6
    effort: unspecified
    context: >-
      Author self-review against the current local object-store manifest, data-movement helpers, managed-resource inventory, scheduled-store reader, local development guide, and RustFS upstream documentation. Compatibility and migration criteria describe required future evidence; implementation and independent review remain pending.
---

# Migrate Nagare's local object store from MinIO to RustFS

## Why

The user requested migration to RustFS, canonical project `mori://rustfs/rustfs`
([upstream repository](https://github.com/rustfs/rustfs)). Nagare currently uses MinIO as the
local S3-compatible substitute for its cloud GCS backup bucket. The desired outcome is a supported
RustFS backend throughout that local workflow, including recovery evidence and retained data.

RustFS is written in Rust and licensed under Apache 2.0. Its upstream
[S3 compatibility matrix](https://github.com/rustfs/rustfs/blob/main/docs/architecture/s3-compatibility-matrix.md)
claims support for a defined set of S3 features, rather than every S3 behavior. Treat that as a
starting point for verifying Nagare's actual operations, not proof that an image swap is sufficient.
No performance improvement is assumed; measure the workload on Nagare's local single-node topology.

## Current integration

- [The local manifest](../../cluster/local/minio/minio.yaml) owns the server, persistent data claim,
  Service, credential Secrets in `nagare-system` and `personal`, and a bucket-seeding Job using `mc`.
- [The local inventory component](../../cli/nagarectl/src/Nagare/Inventory/Components/LocalObjectStore.hs)
  pins the manifest and images, validates the expected endpoint and Secret, and declares resource
  ownership and credential-copy provenance. The migration must update this model alongside the manifests.
- [The data-movement helpers](../../cli/nagarectl/src/Nagare/Cluster/GcsJob.hs) expose `MinioBackend`
  and `MinioRef` while using AWS CLI S3 operations. Their create-only upload path uses conditional
  PUT below 4 GiB and conditional multipart completion for larger files.
- [The scheduled-store reader](../../cli/nagarectl/src/Nagare/Inventory/ScheduledStore.hs) reads
  credentials and recovery objects and includes a hard-coded `svc/minio` port-forward target.
- [Image publication](../../scripts/publish-local-minio-images.sh), `just local-minio`, context
  defaults, packaged payload checks, native rehearsal scripts, and
  [local development guidance](../user/local-development.md) also encode MinIO identities.

Inventory these dependencies at implementation time, including backup and escrow callers and tests.
The current scope is local object storage; replacing cloud GCS or changing the local container
substrate is a separate decision.

## Requested change

Make RustFS the default local object store through Nagare's existing reviewed platform workflow.
Provide persistent storage, verified readiness and liveness probes, bounded bucket initialization,
and credentials available to each consuming namespace. Use a supported S3 client for bootstrap;
remove the requirement for MinIO's `mc` from the default workflow. Verify filesystem ownership and
write permissions against the selected RustFS image, and keep the administrative console within
the intended local access boundary.

Use provider-neutral names for the shared S3 transport types, credential contract, and commands
where they represent generic S3 behavior. Keep the endpoint-and-bucket context contract and object
key layout stable. Resolve every read, write, and port-forward target from the declared store.
Provide a documented transition for saved MinIO endpoints, Secret names, and the `local-minio`
entry point, using compatibility aliases or an actionable migration diagnostic. Avoid silently
redirecting a legacy context to an empty bucket.

Represent server, Service, bucket initialization, credentials, PVCs, image digests, and any resource
renames in the managed-resource inventory. A review must distinguish configuration changes from
data migration and retained source resources. Resume must use verified receipts rather than
repeating an uncertain copy or deleting the old PVC. Coordinate with
[IR-24](make-managed-resources-first-class.md) and the inventory implementation already present.

Before selecting a version, inspect `mori://rustfs/rustfs` through Mori if it has become registered,
then verify the authoritative upstream release tags and container registry artifacts. Neither
RustFS nor MinIO was found by Mori registry search when this request was authored. Pin the selected
server and initialization client by digest, prove both supported Linux architectures, and update
the local image-publication and clone-free payload paths. Record the exact release used in native
evidence; this proposal does not choose a dependency pin.

## Data migration and recovery

Use a separate RustFS data volume and copy through S3. RustFS's upstream
[MinIO file-format interoperability guidance](https://github.com/rustfs/rustfs/blob/main/docs/architecture/minio-file-format-compat.md)
documents a feature-gated compatibility path and encryption limitations. Do not assume that
mounting Nagare's existing MinIO PVC into a normal RustFS image is a supported migration.

Inventory source keys and required metadata, pause scheduled and manual writers for the final
copy and verification window, then compare destination contents and perform real restores before
switching endpoints. Verify content digests independently of ETags, which need not be portable
checksums. Include backup payloads and manifests, volume snapshots, escrow objects, and inventory
recovery receipts. Explicitly handle any discovered versions, delete markers, policies, or
encryption requirements; reject unsupported state before cutover rather than silently dropping it.

Retain the source until verification and the documented rollback window complete. Recovery must
cover interrupted copies, credential or startup failures, and failed integrity checks. Define how
post-cutover writes are paused and copied back or otherwise preserved before rollback; switching
the Service alone is insufficient once new backups exist only in RustFS. Resetting a disposable
local cluster may remain a separately requested option, but normal reconciliation must preserve data.

## Acceptance

The six frontmatter criteria are the completion contract. Run them against the exact pinned RustFS
artifacts in a disposable local context, archive compatibility and migration evidence, and update
current guides, examples, command help, and release compatibility metadata together. Historical
plans and audit evidence may continue to describe the MinIO deployment they actually tested.

The request remains `proposed`; implementation planning and release selection are follow-up work.
