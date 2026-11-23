---
type: Bug Report
title: Forced Attic chunking makes GCS-backed cache hits slow
description: Nagare forces Attic to stream reassembled NARs through the cache Pod, and a cold Kotei UI build took 35 seconds longer with that cache preferred.
generated:
  by: process:codex
  at: "2026-11-23T04:12:13Z"
bugId: BUG-11
status: reported
severity: degraded
origin: mori://tan/tan-ng-labs/plans/23-enable-the-shared-attic-cache-on-labs
affects: mori://shinzui/nagare/packages/nagarectl
affectedVersion: "0.27.0"
environment: >-
  Nagare v0.27.0 on the amd64 Labs Kubernetes node. The managed Attic instance
  uses PostgreSQL and a private GCS bucket in us-west1 through the S3 API.
  The disposable comparison instance used the same pinned Attic image and
  node, a separate private GCS bucket in us-west1, a fresh SQLite metadata
  database, and a temporary signing key.
observed: >-
  With Nagare's managed cache preferred, a fresh Kotei UI console-image build
  took 102 seconds and substituted 15 dependencies from Attic. With only the
  public substituter it took 67 seconds. Direct cache-hit downloads of the same
  Bun and Caddy NARs took 11–24 seconds through the managed chunked cache and
  0.25–0.45 seconds through the disposable unchunked cache.
expected: >-
  Fresh Jobs should benefit from reusing signed closures, as described in
  Use Case 002. A cloud operator should be able to select Attic's direct
  object-download path through reviewed Nagare configuration and retain that
  choice across bootstrap and platform upgrades.
reproduction:
  - Enable and bootstrap the Nagare v0.27.0 cloud Nix cache and confirm that its server ConfigMap sets the NAR size threshold to 65536 bytes.
  - Push x86_64-linux Bun 1.4.2 and Caddy 2.11.7 to that cache. Push the same store paths to an isolated Attic instance with the same image, a fresh metadata database and GCS bucket in the same region, and a threshold of zero.
  - From a fresh Job on the same node, match the NAR hashes across both caches and time two downloads of each advertised NAR URL. Follow redirects and record the redirect count and total transfer time.
  - In a separate fresh Job, select only the unchunked substituter and trust its public signing key. Disable local builds, remote builders, and fallback, then substitute both outputs and verify their signatures.
  - Compare fresh Kotei UI console-image builds of commit c8d465d16d00fac0a69d6d1ec23c721caceba56f with the public substituter alone and with the managed chunked Attic cache preferred.
workaround: >-
  Prefer the public substituter so the managed Attic cache can still supply
  private paths. Labs uses priority 40 for the public substituter and 41 for
  Attic.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-23T04:12:13Z"
    document_timestamp: "2026-11-23T04:12:13Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.2-sol
    effort: unspecified
    context: Compared the Labs build and download measurements with the Nagare v0.27.0 server template, renderer, and cache use case.
---

# Forced Attic chunking makes GCS-backed cache hits slow

The cache delivers signed closures, but forced chunking makes common cache hits
slow enough to undermine the fresh-Job reuse described in the use case.
[Use Case 002](../use-cases/002-deliver-prebuilt-nix-closures-to-nagare-jobs.md)

## Evidence

The probe matched the NAR hashes across both caches and the public substituter.
The unchunked endpoint returned HTTP 307 to a presigned GCS URL. The chunked
endpoint streamed the archive through Attic without a redirect.

| NAR | Managed chunked cache, seconds | Disposable unchunked cache, seconds |
| --- | ---: | ---: |
| Bun 1.4.2 | 24.19, 19.15 | 0.444, 0.444 |
| Caddy 2.11.7 | 15.06, 11.19 | 0.247, 0.301 |

With builders and fallback disabled, a fresh Nix Job fetched both outputs and
seven dependency paths from the unchunked instance in about one second.
Signature verification passed with `nix store verify --sigs-needed 1`. The
disposable comparison used SQLite, so the timings measure the two deployments
as tested. The redirect confirmed that the unchunked deployment served the NAR
body directly from GCS. The 67-second and 102-second image builds used the
public cache and the managed chunked cache respectively. A full Kotei UI image
build with the unchunked cache remains to be measured.
[Labs rollout and build comparison](mori://tan/tan-ng-labs/plans/23-enable-the-shared-attic-cache-on-labs)

## Cause and rollout criteria

The packaged Attic configuration hard-codes `nar-size-threshold = 65536`.
Nagare's renderer substitutes the bucket name and uses the rendered config
digest in the workload revision. A context cannot currently choose a different
threshold through that renderer.
[Server template](../../cluster/bootstrap/nix-cache/server.toml.tmpl)
[Cache renderer](../../cli/nagarectl/src/Nagare/Inventory/Cache.hs)

Attic revision `12cbeca141f46e1ade76728bce8adc447f2166c6` supports
`nar-size-threshold = 0` for whole-NAR storage. When a NAR is a single object,
Attic can redirect to its signed storage URL instead of reconstructing the
archive from chunks. Attic looks up existing NARs by hash at upload time, so
changing the threshold or pushing to a different cache name in the same
metadata database leaves previously stored NARs chunked.

- Expose a reviewed per-context NAR size threshold in bytes, including zero.
  Verify rendering of the default and zero and verify that the selected value
  survives bootstrap and upgrade.
- Document a reviewed reseed or migration for existing chunked entries.
  Preserve signature verification and a rollback path during the transition.
- Verify cold signed pulls and direct GCS redirects in the managed
  PostgreSQL-backed deployment, then repeat the fresh Kotei UI build comparison.
