---
type: Runbook
title: "In-cluster Nix binary cache"
description: "Enable, use, operate, rotate, and recover Nagare's optional Attic binary cache."
docId: DOC-38
tags: [nix, attic, cache, kubernetes, operations]
generated:
  by: process:codex
  at: 2026-09-15T23:59:00Z
---

# In-cluster Nix binary cache

> **Status:** 🟡 Implemented and statically verified; live cloud acceptance is required
> before enabling it for a production context.

Nagare can run one optional Attic cache inside a cloud cluster. It transports signed Nix
store closures from a trusted producer to Nix-capable Jobs without allowing those Jobs to
build locally. Nagare owns the GCS bucket, credential, PostgreSQL database, server image,
cluster workloads, and client ConfigMap. A consumer such as
`mori://shinzui/kotei` owns its push policy and explicitly opts Jobs into that
ConfigMap; it must not deploy a second Nagare cache.

The component is off by default, is unavailable in local mode, and does not replace the
public Cachix substituter used for Nagare development and releases. Enabling it adds a GCS
bucket, an HMAC credential, a 5 GiB managed PostgreSQL database, and cluster workloads.

## Enable and bootstrap it

Update the intended cloud context, then use the normal retained-review workflow. Never run
an unreviewed `pulumi up` for this change.

```bash
nagarectl context create prod \
  --enable-nix-cache \
  --nix-cache-bucket acme-prod-nagare-nix-cache \
  --force --use

review_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/nix-cache-enable"
nagare infra-preview --save-plan "$review_dir"
jq . "$review_dir/review.json"
nagare infra-up --plan "$review_dir" --yes
```

The enabled preview should add exactly one protected GCS bucket, one bucket-scoped
`roles/storage.objectAdmin` IAM member, and one protected HMAC key. The bucket has uniform
access, public-access prevention, `forceDestroy: false`, and no object versioning because
Attic garbage collection must be able to reclaim chunks.

Create the operator-owned encrypted Secrets once, then run normal bootstrap:

```bash
nagare nix-cache-secret-init
nagare nix-cache-publish
nagare cluster-bootstrap
nagare nix-cache-status
```

`nix-cache-secret-init` prints only the destination of
`cluster-secrets/<context>/nix-cache.yaml`. Keep that sops ciphertext in the private
operator repository and keep its age identity backed up offline. The HMAC secret exists in
Pulumi state by necessity; the stack secrets provider and state-bucket IAM are its
confidentiality boundary. The Attic JWT key never enters Pulumi or the immutable payload.

Bootstrap publishes the payload's digest-pinned Attic image to the selected Artifact
Registry, checks its configuration, migrates PostgreSQL, rolls out Attic, configures public
read with 30-day retention, and writes `nagare-nix-cache-client` in namespace `personal`.
The ConfigMap is generated from the live server because every context has its own NAR
signing key.

## Push a closure

Keep Attic private. Producers reach it through `kubectl port-forward` and use a short-lived,
cache-scoped token. The following keeps the token in a mode-0600 file rather than an
argument or shell history:

```bash
private_dir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-attic-push.XXXXXX")"
chmod 700 "$private_dir"
trap 'rm -rf "$private_dir"' EXIT

kubectl -n nagare-system exec deployment/nix-cache -- \
  atticadm -f /config/server.toml make-token \
    --sub operator-push --validity 1h \
    --pull nagare-cache --push nagare-cache > "$private_dir/token"
chmod 600 "$private_dir/token"

mkdir -p "$private_dir/attic/attic"
printf '%s\n' \
  'default-server = "nagare"' \
  '[servers.nagare]' \
  'endpoint = "http://127.0.0.1:8080/"' \
  "token-file = \"$private_dir/token\"" \
  > "$private_dir/attic/attic/config.toml"

kubectl -n nagare-system port-forward service/nix-cache 8080:80
```

In another terminal, using the same `private_dir` value:

```bash
store_path="$(nix build .#your-output --no-link --print-out-paths)"
XDG_CONFIG_HOME="$private_dir/attic" \
  attic push nagare:nagare-cache "$store_path"
```

An anonymous client may pull, but anonymous push must fail. A writer token can push only
to `nagare-cache`; it cannot create or configure another cache.

## Opt a Job in

The consumer contract is ConfigMap `nagare-nix-cache-client`, key `nix.conf`, in
`personal`. A `Nagare.Dsl.Job` consumer sets:

```haskell
nixConfigMap = Just "nagare-nix-cache-client"
```

The renderer mounts the key at `/etc/nix/nix.conf` and labels the Pod
`nagare.dev/nix-cache-client: "true"`. That label activates the additive NetworkPolicy.
The policy permits DNS, Attic, and TCP 443. The broad HTTPS allowance is deliberate:
Attic redirects single-chunk downloads to presigned GCS URLs, and Kubernetes
NetworkPolicy cannot select destinations by hostname. kube-router also has a short policy
reconciliation window when a Pod starts; treat the policy as defense in depth.

To prove a cache hit, use `cluster/bootstrap/nix-cache/smoke-pod.yaml`. Its positive Pod
sets `--max-jobs 0` and disables fallback, so it cannot silently build. The negative Pod
uses the same cache with a wrong public key and must fail signature verification.

## Observe and maintain it

```bash
nagare nix-cache-status
kubectl -n nagare-system create job --from=cronjob/nix-cache-gc nix-cache-gc-manual
kubectl -n nagare-system logs -f job/nix-cache-gc-manual
gcloud storage du --summarize "gs://${NAGARE_NIX_CACHE_BUCKET}"
```

Status reports only non-secret data: immutable image, database and rollout readiness,
migration, public key, retention, GC and backup schedules, and the client ConfigMap digest.
Victoria alerts at 80 percent node-disk use and critically at 90 percent for 15 minutes.
GCS cache growth is separate and must be checked with `gcloud storage du`.

Normal `cluster-bootstrap` and platform upgrades reconcile the enabled cache from the
selected immutable payload. Before upgrading Attic, review its migrations and rollback
compatibility. If the schema cannot run safely on the prior release, restore the matching
PostgreSQL backup rather than running two server versions against one database.

## Rotate and recover

- **Writer token:** stop using it and wait for expiry, or rotate the JWT key to revoke all
  existing tokens. Issue another narrow, short-lived token. Public pull and NAR trust do
  not depend on JWT.
- **JWT key:** run `nagare nix-cache-secret-init --rotate`, apply the new ciphertext with
  `nagare nix-cache-bootstrap`, then issue new writer tokens. This also refreshes the HMAC
  values currently read from Pulumi, so use the dedicated HMAC procedure below when that
  credential was exposed.
- **HMAC credential:** provision an overlapping replacement in one reviewed Pulumi
  change, update the sops Secret and verify the rollout, then remove the old key in a
  second reviewed change. Avoid a single-step replacement outage.
- **NAR signing key:** it lives in PostgreSQL, not the JWT Secret. Rotate it through Attic,
  rerun bootstrap to regenerate the client ConfigMap, and verify an existing path before
  retiring the previous trust. Consumers must never silently trust an unexpected key.
- **Database loss:** restore managed database `nix-cache`, reconcile bootstrap, and compare
  the public key. A missing database loses metadata and signing identity even if GCS
  chunks remain.
- **Bucket loss:** recreate through a reviewed plan and repush reproducible closures. The
  cache is transport, not the artifact source of truth.

The daily `nagare-dbbackup-nix-cache` CronJob protects the signing identity and metadata.
The cache bucket itself is deliberately not versioned; protect important closures by
keeping their reproducible source and producer inputs.

## Disable or retire it

Changing the context to `--disable-nix-cache` makes bootstrap skip the component; it does
not delete the existing database, bucket, Secrets, or workloads. This is the safe pause
path.

For permanent retirement, first revoke writers, stop consumers, take and verify a database
backup, and decide whether to export or retain the bucket. Only then remove Pulumi
protection and execute a new retained, reviewed plan. Never make component disablement an
implicit destructive operation.
