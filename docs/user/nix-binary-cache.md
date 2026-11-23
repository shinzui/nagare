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

Keep Attic private. A producer pushes from its workstation with one command, from a shell whose
active context is the cloud context with the cache enabled:

```bash
nagarectl nix-cache push "$(nix build .#your-output --no-link --print-out-paths)"
```

`push` checks that every argument is a `/nix/store` path in the local store before it touches
the cluster. It then mints a 15-minute token with `atticadm` inside `deployment/nix-cache`,
writes it to a mode-0600 file in a private temporary directory, forwards 127.0.0.1:18080 to
the cache, and runs the packaged Attic client against a private configuration that names the
token file. The directory and the port-forward are removed whether the push succeeds, fails or
is interrupted. No token appears in an argument, an environment variable or the output. The
command prints `pushed N paths to nagare-cache at http://127.0.0.1:18080/`, or with
`--contract 1` a `nix-cache-push-result` document. A local context is refused.

Two primitives serve other producers, such as Kotei, which need an endpoint, a cache name
and a token file:

```bash
nagarectl nix-cache token --out "$private_dir/token"   # 1h pull+push token, mode 0600
nagarectl nix-cache forward                            # endpoint and public key; Ctrl-C ends it
```

`token` refuses an existing file; `--validity` takes Attic durations up to `24h` and
`--subject` names the token's holder. `forward` binds 127.0.0.1:18080 because the server
admits only that loopback host, so it refuses while another forward,
`nagare nix-cache-status` or the reviewed cache transport holds the port.

`push --endpoint URL --token-file FILE [--cache NAME]` pushes to any Attic reachable by URL,
such as a self-run one, with no cluster contact; the token file is read only by the client.

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

## Choose the chunking threshold

Attic splits a newly pushed NAR into content-defined chunks when the NAR is at least
`NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD` bytes; the default is `65536`. A client that downloads a
single-chunk NAR gets an HTTP 307 redirect to a presigned GCS URL and reads the object directly. A
chunked NAR is fetched chunk by chunk from GCS and streamed through the cache Pod. On a real
context that made one Bun NAR take about 20 seconds instead of under half a second, and made a
build slower with the cache preferred than with the public cache alone
([BUG-11](../bug-reports/forced-attic-chunking-slows-gcs-cache-hits.md)).

Set the threshold to `0` to store every NAR whole, so every hit is a redirect. The cost is chunk
deduplication: two NARs that share most of their bytes, such as successive builds of one package,
are stored twice, so the bucket grows faster. Keep the default when GCS usage matters more than
pull speed. The chunk size settings have no effect when the threshold is `0`.

Opt in by adding one line to the context file and running normal bootstrap:

```bash
export NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD=0
```

```bash
nagare cluster-bootstrap
kubectl -n nagare-system get configmap nagare-nix-cache-server \
  -o jsonpath='{.data.server\.toml}' | grep nar-size-threshold
# nar-size-threshold = 0
```

`nagarectl context create NAME --force --nix-cache-nar-size-threshold 0` writes the same line.
The value is read from the stored context, so a shell variable cannot change it. Bootstrap rolls
Attic out under a new revision. The setting changes only how new uploads are stored: a NAR that
is already chunked stays chunked, and a repush reuses it. To move those NARs, follow the next
section. Setting the threshold back and bootstrapping restores the old layout for new uploads;
NARs stored whole keep working.

## Move existing NARs to whole-object storage

Run this once on a context after its bootstrap has rolled out the zero threshold. It removes
the cache entries that point at chunked NARs, lets Attic's garbage collector delete those NARs,
and repushes. It never touches the cache row, which holds the NAR signing key, so consumer trust
and `nagare-nix-cache-client` do not change. Consumers miss on the removed paths and fall back to
their other substituters until the repush finishes. Until the procedure ends, push nothing
except the repush below and do not run bootstrap: an early push can attach a path to a chunked
NAR again, and bootstrap clears the CronJob suspension.

Record the public key so you can compare it at the end, and hold scheduled collection:

```bash
nagare nix-cache-status          # note the public key
kubectl -n nagare-system patch cronjob nix-cache-gc -p '{"spec":{"suspend":true}}'
```

Run SQL in the cache database. Confirm the Pod name with `kubectl -n nagare-system get pods`:

```bash
attic_sql() { kubectl -n nagare-system exec -i nix-cache-db-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'; }
```

Inspect the scope. Only `nagare-cache` should exist:

```bash
attic_sql <<'SQL'
SELECT name FROM cache;
SELECT count(*) AS chunked_nars, coalesce(sum(nar_size), 0) AS bytes FROM nar WHERE num_chunks > 1;
SQL
```

Copy the entries you are about to remove into a side table, then remove them, in one
transaction. The copy is the rollback until garbage collection runs:

```bash
attic_sql <<'SQL'
BEGIN;
CREATE TABLE nagare_reseed_object AS
  SELECT o.* FROM object o
    JOIN nar n ON n.id = o.nar_id
    JOIN cache c ON c.id = o.cache_id
   WHERE c.name = 'nagare-cache' AND n.num_chunks > 1;
DELETE FROM object WHERE id IN (SELECT id FROM nagare_reseed_object);
COMMIT;
SELECT count(*) AS removed FROM nagare_reseed_object;
SQL
```

To roll back at this point, put the entries back, drop the copy and resume the CronJob. Every
chunk is still in GCS, so the cache serves exactly what it served before:

```bash
attic_sql <<'SQL'
INSERT INTO object SELECT * FROM nagare_reseed_object;
DROP TABLE nagare_reseed_object;
SQL
kubectl -n nagare-system patch cronjob nix-cache-gc -p '{"spec":{"suspend":false}}'
```

Otherwise run garbage collection once. It deletes the NARs that no entry references and their
chunks:

```bash
kubectl -n nagare-system create job --from=cronjob/nix-cache-gc nix-cache-gc-reseed
kubectl -n nagare-system wait --for=condition=complete --timeout=30m job/nix-cache-gc-reseed
attic_sql <<'SQL'
SELECT count(*) FROM nar WHERE num_chunks > 1;
SQL
```

The collector logs only its banner, so this count is the check: it must be `0`. If it is not, a push attached a path to a chunked NAR: repeat the copy,
delete and collection steps, appending to the side table with `INSERT INTO nagare_reseed_object
SELECT ...` instead of `CREATE TABLE`. One run deletes at most 65535 chunks from GCS; later
scheduled runs delete the rest, which costs only bucket space. From here there is no rollback:
the removed NARs are gone, so repush instead. The cache is transport, and every closure is
reproducible from its producer.

Repush the producer closures, drop the copy, and resume scheduled collection:

```bash
nagarectl nix-cache push "$(nix build .#your-output --no-link --print-out-paths)"
attic_sql <<'SQL'
DROP TABLE nagare_reseed_object;
SQL
kubectl -n nagare-system patch cronjob nix-cache-gc -p '{"spec":{"suspend":false}}'
nagare nix-cache-status          # the public key must match the one you noted
```

A repushed NAR now redirects. From an opted-in Pod, `curl -s -o /dev/null -w '%{http_code}\n'`
against its `nar/` URL from the path's `.narinfo` prints `307`. Every step is safe to repeat: a
second delete finds no rows, a second collection finds no orphans, and the push skips paths the
cache already holds.

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
