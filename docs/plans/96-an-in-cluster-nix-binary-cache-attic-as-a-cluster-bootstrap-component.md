---
id: 96
slug: an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component
title: "An in-cluster Nix binary cache (Attic) as a cluster bootstrap component"
kind: exec-plan
created_at: 2026-07-14T19:28:25Z
intention: "intention_01kx3qz212e989078m6ssetr2b"
master_plan: "docs/masterplans/18-platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md"
---

# An in-cluster Nix binary cache (Attic) as a cluster bootstrap component

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare will operate an Attic binary cache at
`http://nix-cache.personal.svc.cluster.local/nagare-cache`. A laptop can build a
Nix derivation, authenticate through a temporary `kubectl port-forward`, and push its
store path. A Nix-capable Pod can mount the checked-in client configuration and obtain
the same path from the in-cluster service instead of rebuilding it. Pulls are public
inside the cluster and signature-verified; pushes require a scoped Attic token.

The cache server is stateless apart from a managed Nagare PostgreSQL database. NAR
chunks live in a dedicated GCS bucket, never on the node's shared 100GB data disk. The
component is reproducible from Pulumi resources, a pinned upstream Attic image, raw
manifests under `cluster/bootstrap/nix-cache/`, encrypted bootstrap material, and an
idempotent install procedure. Operators can observe a laptop push, a cluster
substitution, signature rejection with a wrong key, persistence across a server restart,
garbage collection, and key rotation.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Pin Attic and expose reproducible client and server-image flake outputs.
- [ ] Provision the dedicated GCS bucket, scoped IAM, HMAC key, and protected Pulumi outputs.
- [ ] Add durable JWT bootstrap material and safe Kubernetes Secret publication.
- [ ] Add the managed Postgres dependency and raw Attic migration/API/GC manifests.
- [ ] Initialize the public-read cache and publish its exact client `nix.conf` ConfigMap.
- [ ] Add client/server NetworkPolicies, retention, capacity alerts, and operator runbooks.
- [ ] Pass laptop-push, cluster-substitute, wrong-key, restart, GC, and rotation acceptance.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Use Attic rather than Harmonia.
  Rationale: Both can serve signed NARs, but Attic supplies the authenticated push API,
  per-cache retention, deduplicated chunk storage, and garbage collection required for
  laptop-to-cluster transport. Harmonia would require a separate upload and retention
  system.
  Date: 2026-07-14

- Decision: Provision a dedicated `${project}-nagare-nix-cache` GCS bucket.
  Rationale: Attic garbage collection must never share a deletion boundary with database
  backups or NixOS image staging. The node service account receives object-admin only on
  this bucket.
  Date: 2026-07-14

- Decision: Use GCS's XML/S3-compatible API with an HMAC key for the node service account.
  Rationale: Attic's upstream S3 backend accepts access-key credentials and a custom
  endpoint; it does not directly exchange GCE metadata OAuth tokens. The HMAC key keeps
  storage IAM scoped to the existing service account and cache bucket.
  Date: 2026-07-14

- Decision: Pin upstream Attic by commit in `flake.lock` and build its provided
  `attic-server-image` output.
  Rationale: Upstream still describes Attic as an early prototype. A commit pin, immutable
  pushed digest, migration Job, and source-reviewed configuration make upgrades explicit
  and rollback possible; an unpinned `latest` image does not.
  Date: 2026-07-14

- Decision: Use Nagare's managed Postgres for metadata and run database migrations and
  garbage collection as separate Jobs.
  Rationale: The existing database kind supplies durable RWO storage, credentials, and
  daily backup. A single API replica stays stateless, while one-shot migration and GC
  modes avoid duplicate collectors and make failures visible.
  Date: 2026-07-14

- Decision: Keep Attic private to a ClusterIP and let laptops push through
  `kubectl port-forward`.
  Rationale: This meets the local-to-cluster flow without exposing an early-prototype
  service or building another public authentication boundary. Cluster pulls need no
  ingress, DNS, or TLS dependency.
  Date: 2026-07-14

- Decision: Make `nagare-cache` public-read and require scoped, expiring tokens for push.
  Rationale: Nix already verifies NAR signatures, so a read bearer token adds distribution
  burden to every Pod without improving artifact integrity. Write tokens remain narrow and
  revocable.
  Date: 2026-07-14

- Decision: Treat Attic's JWT key and cache NAR key as distinct secrets.
  Rationale: The JWT RS256 private key signs API capability tokens and is stored as an
  encrypted Pulumi config value. Attic generates the per-cache NAR keypair and stores its
  private half in Postgres. Rotating the NAR key updates client trust; Attic's managed
  signing can serve existing NARs under the new key without re-uploading their chunks.
  Date: 2026-07-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Nix builds immutable paths under `/nix/store`. A binary cache is a “substituter”: when
Nix needs a path, it can download a serialized Nix Archive (NAR) and verify its signature
instead of rebuilding the derivation. Attic stores NAR data as deduplicated chunks,
metadata in PostgreSQL, and a private signing key per logical cache. A client trusts only
the public keys listed in `trusted-public-keys`.

Nagare currently has no cluster substituter. `flake.nix` pins nixpkgs and defines the
developer shells and checks, but no Attic input. `infra/pulumi/index.ts` constructs
`NagarePerimeter`; `infra/pulumi/src/components/NagarePerimeter.ts` currently creates a
backup bucket and image-staging bucket and grants the node service account object-admin
only on backups. The cache needs its own bucket and an HMAC key because Attic speaks an
S3-compatible protocol rather than GCE metadata OAuth.

Cluster add-ons normally live as raw manifests and instructions in
`cluster/bootstrap/<component>/`, while the root `justfile` exposes thin install/status
recipes. The existing database command creates durable Postgres, Service, credentials,
and backup CronJob. For `nagarectl db create postgres nix-cache`, the connection Secret
is `nagare-db-nix-cache` and its `DATABASE_URL` key is the value Attic needs.

The host has a 100GB `pd-balanced` disk shared by local-path PVCs, including 20Gi for
VictoriaLogs and 10Gi for VictoriaTraces. Cache chunks therefore belong in GCS; only a
small Postgres PVC and container scratch use the node disk. The current Victoria values
explicitly disable vmalert and Alertmanager, so this plan must add the narrow disk-capacity
guardrail rather than assume an alert already exists.

Three unrelated credentials must not be confused. The GCS HMAC access/secret pair
authorizes chunk storage. `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64` signs Attic login
tokens. The `nagare-cache` NAR private key signs artifacts and lives in the backed-up
Attic database; its public half is distributed in `nix.conf`.

The source requirement is Kikan's `shinzui/kikan` plan
`docs/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md`.
Its intended `docs/architecture/evolution/conformance/nagare-prereqs/pod-nix.conf`
fixture is absent as of 2026-07-14. The ConfigMap data authored here is the provider-side
source until Kikan copies it, after which the two must remain byte-identical except that
the placeholder in Kikan is replaced by the real Attic public key. Mori has no registered
Attic or Harmonia source project at plan-authoring time, so upgrades must inspect the
pinned upstream source checkout—especially `server/src/config.rs` and its flake image
definition—rather than guessing from an unpinned API.


## Plan of Work

### Milestone 1: pin Attic and provision durable cloud storage

Add an `attic` input to `flake.nix` at a reviewed full commit and make its nixpkgs input
follow this repository's nixpkgs. Expose the upstream `attic-client` package for supported
developer systems and `attic-server-image` for `x86_64-linux`; include the client in the
default development shell. Do not copy an image tag from documentation. Record the full
revision and the expected image name in `cluster/bootstrap/nix-cache/README.md`, and add
`cluster/bootstrap/nix-cache/publish-image.sh` that builds the flake output, copies the
Docker archive to the active target's Artifact Registry with `skopeo`, resolves the pushed
digest, and prints an immutable image reference. Add `skopeo` to the shell if needed.

Extend `NagarePerimeterArgs` with `nixCacheBucketName` and extend the component with:

* a regional GCS bucket using uniform bucket-level access and `forceDestroy: false`;
* a non-authoritative `roles/storage.objectAdmin` BucketIAMMember for the existing node
  service account; and
* `gcp.storage.HmacKey` for that same service account, protected from accidental deletion.

Add component outputs `nixCacheBucket`, `nixCacheHmacAccessId`, and
`nixCacheHmacSecret`; register them and export them from `infra/pulumi/index.ts`, preserving
the HMAC secret as a Pulumi secret. Add config `nixCacheBucket` with default
`${gcpProject}-nagare-nix-cache`. Add optional secret config
`nixCacheJwtPrivateKeyBase64`; export a secret sentinel when it is not configured so old
stacks can still preview, but make the cache installer refuse the sentinel. Generate the
RSA key once into a mode-0600 temporary file and set it through Pulumi's secret-value
prompt/stdin, never a command-line value. Pulumi's encrypted state is the durable rebuild
source for this JWT key.

Milestone 1 is complete when TypeScript compiles, `pulumi preview` shows exactly the
bucket/IAM/HMAC additions, the flake builds the Attic client and server archive, and a
secret scan finds no private key or HMAC secret in Git or build logs.

### Milestone 2: bootstrap Postgres and the Attic service

Create `cluster/bootstrap/nix-cache/` in the same raw-manifest style as `en/` and
`shomei/`. It contains `README.md`, `publish-image.sh`, `bootstrap-secrets.sh`,
`install.sh`, `server-config.yaml`, `service.yaml`, `migration-job.yaml.tmpl`,
`deployment.yaml.tmpl`, `gc-cronjob.yaml.tmpl`, `networkpolicy.yaml`, and the client files
described in Milestone 3. Shell scripts use `set -euo pipefail`, the repository target
context guard, temporary directories with umask `077`, traps, and no tracing.

Create the metadata database idempotently with:

```bash
nagarectl db create postgres nix-cache --namespace personal --size 5Gi --cpu 500m --memory 1Gi
```

Reuse its `nagare-db-nix-cache` Secret; map key `DATABASE_URL` to
`ATTIC_SERVER_DATABASE_URL`. Confirm the generated daily database backup CronJob is
present, because the NAR private key lives in this database.

`bootstrap-secrets.sh` reads the active stack's JSON outputs. With `--show-secrets`, pipe
the HMAC access ID, HMAC secret, and JWT private-key base64 through `jq -j` into separate
mode-0600 files, validate that none is empty or the sentinel, and create/apply two Secrets
with `--from-file`: `nagare-nix-cache-storage` containing `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`, and `nagare-nix-cache-token-key` containing
`ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64`. Values must never appear in argv, YAML in the
repository, stdout, or journal output.

`server-config.yaml` supplies non-secret Attic configuration: listen on port 8080, use
Postgres, select the S3 backend, use region `auto`, the Pulumi cache-bucket output, and
endpoint `https://storage.googleapis.com`, and configure managed signing. Match keys to
the pinned `server/src/config.rs`; do not assume a field name from a newer Attic release.
The migration Job runs `atticd --mode db-migrations` to completion before the API rollout.
The Deployment runs one replica as a non-root UID, uses a read-only root filesystem plus
an `emptyDir` for `/tmp`, drops all capabilities, sets requests 250m/256Mi and limits
1 CPU/1Gi, consumes only the three Secrets/ConfigMap above, and uses TCP startup/readiness/
liveness probes on 8080. The Service is `nix-cache`, port 80 to targetPort 8080, giving the
stable URL with no explicit port.

The GC CronJob runs `atticd --mode garbage-collector-once` daily with
`concurrencyPolicy: Forbid`, a deadline, backoff 0, and the same config/credentials. It
does not run alongside an in-process automatic collector. The Attic NetworkPolicy permits
ingress on 8080 only from Pods labeled `nagare.dev/nix-cache-client: "true"` (node-local
port-forward traffic remains permitted by Kubernetes semantics). It permits egress to the
managed Postgres Pods on 5432, kube-dns on TCP/UDP 53, and HTTPS on 443 for GCS; document
that Kubernetes NetworkPolicy cannot restrict that last rule by DNS name.

`install.sh` requires an immutable Attic image digest and active target outputs, creates
`personal`, runs the secret bootstrap, renders all bucket/image placeholders, deletes and
recreates only the completed migration Job, waits for it, applies the API resources, and
waits for rollout. It must not recreate Postgres, delete the cache bucket, or generate a
new JWT key implicitly.

Milestone 2 is complete when migrations and rollout succeed, the API answers through a
local port-forward, restarting the Deployment preserves metadata, and manifests contain no
plaintext credential or mutable image tag.

### Milestone 3: initialize the cache and distribute the client contract

Through a port-forward, use the server image's `atticadm` to mint a five-minute bootstrap
token with only cache-creation/configuration permissions. Log the laptop client in without
putting the token in shell history. Create public cache `nagare-cache`, set a 30-day
retention period, and query its substituter endpoint and NAR public key. The operation is
idempotent: if the cache exists, verify its public/read and retention settings instead of
regenerating it.

Generate and commit `cluster/bootstrap/nix-cache/client-config.yaml` only after replacing
its public-key placeholder. It defines ConfigMap `nagare-nix-cache-client` in `personal`
with key `nix.conf` whose bytes are exactly:

```text
substituters = http://nix-cache.personal.svc.cluster.local/nagare-cache https://cache.nixos.org/
trusted-public-keys = nagare-cache-1:<actual-base64-public-key> cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
```

The Attic public key is not secret and belongs in Git. Add an additive client
NetworkPolicy selecting `nagare.dev/nix-cache-client: "true"`; allow DNS and TCP 8080
only to the `nix-cache` Pods. EP-2 of the parent MasterPlan adds that label and mounts the
ConfigMap only when a Job opts into the cache. Kotei can use the same label and mount.

Create a long-lived laptop push token scoped only to pushing `nagare-cache`; store it in
the Attic client config or password manager, not the repository. Add the complete laptop
port-forward/login/build/push flow and cluster mount/substitution flow to `README.md` and
`docs/user/nix-binary-cache.md`, linking the latter from `docs/user/README.md`. Include
token revocation, public pull, signing-key rotation, JWT-key rotation, HMAC recovery,
database restore, and bucket retention.

Milestone 3 is complete when the checked-in ConfigMap contains the server-reported public
key, the future Kikan `pod-nix.conf` fixture matches its two lines, and an opted-in client
Pod can reach only DNS and the cache under its additive policy.

### Milestone 4: retention, capacity guardrails, and end-to-end proof

Add a tiny deterministic `cache-smoke` flake package or equivalent checked-in derivation
that can be built on both laptop and an x86_64-linux Pod. Build and push it from the
laptop. Start a fresh Nix Pod with the client ConfigMap mounted, copy only the smoke source
into it, and build with verbose logging. The log must say it is copying the output path
from the in-cluster URL and must not execute the builder. Repeat with a ConfigMap carrying
a deliberately wrong Attic public key; because this test path is absent from the upstream
cache, Nix must reject the untrusted signature rather than silently succeed elsewhere.

Delete and recreate the Attic API Pod, remove the smoke path from a new test Pod's local
store, and substitute again to prove GCS/Postgres durability. Run an ad-hoc Job from the
checked-in GC CronJob and verify successful completion. Do not shorten production
retention on the real cache to test deletion; use a disposable cache and disposable path
if destructive GC behavior itself needs validation.

Add `cluster/observability/victoria-metrics/nix-cache-rules.yaml` with VMRule warnings at
80% and critical alerts at 90% for the `/var/lib/nagare` host filesystem (or the exact
node-exporter mount label observed live), each held for 15 minutes. Enable the minimal
vmalert/Alertmanager path in `cluster/observability/victoria-metrics/values.yaml`, with
explicit small requests/limits, and document that v1 surfaces firing alerts in the
Victoria/Grafana UI; external paging remains a separate operator choice. Also document
`gcloud storage du` for billed GCS growth, since node filesystem metrics do not include
the chunk bucket.

Finally rotate the NAR key with the pinned Attic cache-configure command, read the new
public key, update/apply `client-config.yaml`, and show a new Pod can fetch the already
stored smoke path. This proves managed signing does not require re-uploading chunks.
Treat the old key as trusted only for a short overlap if clients cannot update atomically.

Milestone 4 is complete when all positive and negative substitution, restart, policy,
alert-rule, GC, and NAR-key-rotation observations are recorded and the cluster is returned
to the production retention/key configuration.


## Concrete Steps

Run repository commands from `/Users/shinzui/Keikaku/bokuno/nagare`. After adding the
pin, build the upstream artifacts and compile Pulumi:

```bash
nix flake lock --update-input attic
nix build .#attic-server-image
nix build .#attic-client
cd infra/pulumi && bun run build
cd ../..
```

The lock update is intentional only during initial pin or a reviewed upgrade. Subsequent
builds must leave `flake.lock` unchanged. Generate the JWT key without exposing it:

```bash
work=$(mktemp -d)
chmod 700 "$work"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$work/attic-jwt.pem"
base64 < "$work/attic-jwt.pem" | tr -d '\n' > "$work/attic-jwt.b64"
(cd infra/pulumi && pulumi config set --secret nixCacheJwtPrivateKeyBase64 < "$work/attic-jwt.b64")
rm -rf "$work"
```

The key-setting command prompts/reads stdin and prints only confirmation. Before applying
cloud changes, inspect the active context and preview:

```bash
just context-show
just infra-preview
just infra-up
pulumi -C infra/pulumi stack output nixCacheBucket
```

Expected output is the active project's dedicated cache bucket. Do not run
`pulumi stack output --show-secrets` interactively; only `bootstrap-secrets.sh` may read
those outputs into protected temporary files.

Publish an immutable image and install:

```bash
cluster/bootstrap/nix-cache/publish-image.sh
nagarectl db create postgres nix-cache --namespace personal --size 5Gi --cpu 500m --memory 1Gi
ATTIC_IMAGE='<printed-reference-with-@sha256>' just nix-cache-bootstrap
kubectl -n personal rollout status deployment/nix-cache
kubectl -n personal port-forward service/nix-cache 8080:80
```

The image script prints one digest reference. The rollout finishes with
`deployment "nix-cache" successfully rolled out`; `curl -fsS http://127.0.0.1:8080/`
returns an Attic response rather than a connection error.

Use a second terminal with `set +x`. Mint the bootstrap token into a mode-0600 temporary
file, create/configure the cache with the pinned Attic CLI, then destroy that bootstrap
token/file. Mint the narrower laptop push token separately. Exact `atticadm` option names
must come from `atticadm make-token --help` in the pinned image and be copied into the
README; do not substitute remembered options from another release.

For the end-to-end proof:

```bash
nix build .#cache-smoke --print-out-paths
attic push nagare-cache "$(nix path-info .#cache-smoke)"
kubectl -n personal apply -f cluster/bootstrap/nix-cache/smoke-pod.yaml
kubectl -n personal logs -f pod/nix-cache-smoke
```

Expected Pod output includes `copying path ... from
'http://nix-cache.personal.svc.cluster.local/nagare-cache'`. The wrong-key variant exits
nonzero with an untrusted/invalid-signature message. Record the exact observed wording in
Surprises because it is Nix-version dependent.

Run final checks:

```bash
nix fmt
nix flake check
cd infra/pulumi && bun run build
cd ../..
shellcheck cluster/bootstrap/nix-cache/*.sh
kubectl apply --dry-run=server -f cluster/bootstrap/nix-cache/client-config.yaml
git diff --check
```

If Kikan's fixture now exists, locate its repository with Mori and compare its two lines
to the ConfigMap's `nix.conf`. Never replace a real public key with Kikan's original
`AAAA...` placeholder.


## Validation and Acceptance

Acceptance requires all of these observable behaviors:

* `flake.lock` pins one reviewed Attic revision; the server is pushed and deployed by
  immutable digest; `nix flake check` and Pulumi TypeScript compilation succeed.
* Pulumi owns a dedicated non-force-destroy cache bucket, bucket-scoped IAM, and protected
  HMAC key. Secret outputs remain encrypted, and repository/log scans contain no HMAC,
  JWT private key, push token, or NAR private key.
* The migration Job completes, the single API Deployment becomes Ready, the daily GC and
  Postgres backup CronJobs exist, and deleting the API Pod loses no cache or metadata.
* `nagare-nix-cache-client` contains the exact service URL and server-reported public key.
  A Pod opting in receives the file at `/etc/nix/nix.conf` and can reach DNS/cache but not
  arbitrary egress under the combined Job/cache NetworkPolicies.
* A laptop push succeeds through a port-forward. A fresh Pod builds the same checked-in
  derivation by copying from Attic, with the cache URL visible in logs. Replacing only the
  public key with a wrong key makes the same path fail signature validation.
* An unauthenticated push fails, while public pull remains successful. A scoped laptop
  token cannot create/configure another cache.
* An ad-hoc GC run succeeds, 30-day retention remains configured, the node-disk alert rules
  load, and current Postgres plus observability PVC use remains below the 80% warning.
* NAR-key rotation changes the public key; after ConfigMap rollout, a fresh Pod retrieves
  the already stored smoke path without re-upload. JWT rotation invalidates old push
  tokens but does not change NAR trust or public pull.

The exact substitute log and wrong-key error should be captured in this plan during
implementation. Do not mark completion based only on HTTP health or successful image
deployment; the laptop-to-Pod artifact transfer is the feature.


## Idempotence and Recovery

Pulumi preview/up, database creation, Secret creation via dry-run/apply, ConfigMap apply,
and Deployment apply are convergent. The installer may delete/recreate the migration Job
after it has finished; migrations themselves must be upstream-idempotent. Cache
initialization checks before create, and must never regenerate a key or token merely
because the script is rerun.

The GCS bucket has `forceDestroy: false` and the HMAC resource is protected. A normal
Pulumi destroy therefore cannot silently remove cached artifacts or credentials. To roll
back an Attic upgrade, restore the prior `flake.lock`, republish its image, run only
backward-compatible migrations, and set the Deployment back to the prior digest. If the
new migration is not backward-compatible, restore the managed Postgres backup before
starting the older server; do not point two versions at the database simultaneously.

If the JWT key is lost, generate and store a new Pulumi secret, republish its Kubernetes
Secret, restart Attic, and issue new push tokens. Public reads and the NAR key are
unaffected. If an HMAC secret is exposed, create a second HMAC credential for the same
service account, update the Kubernetes Secret and rollout first, verify reads/writes, then
deactivate and delete the old credential and reconcile Pulumi state. Never revoke the only
working key before the new rollout.

The NAR key is recovered with Postgres, not with the JWT or Kubernetes storage Secret.
Restore the latest database backup and verify its public key before serving. If it is
irrecoverable, create a new cache/key, update every client ConfigMap, and repopulate
artifacts; Nix will correctly refuse paths signed only by the lost key unless clients
temporarily retain its public half.

Garbage collection deletes unreferenced chunks and is intentionally irreversible. Test
destructive retention on a disposable cache. The cache is an optimization, so complete
loss can be recovered by recreating metadata/bucket and rebuilding/pushing paths, but
database backups are still required to preserve signing identity and avoid a coordinated
trust reset.


## Interfaces and Dependencies

The external implementation dependency is the exact Attic commit in `flake.lock`. Its
reviewed interfaces are `attic`, `atticadm`, `atticd --mode api-server`,
`atticd --mode db-migrations`, `atticd --mode garbage-collector-once`, the PostgreSQL
database URL, S3 backend configuration, AWS credential environment variables, and
`ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64`. Any upstream change to those names requires an
explicit lock update and plan Decision entry.

Cloud interfaces added to `NagarePerimeter` are:

```typescript
nixCacheBucketName: string
nixCacheBucket: pulumi.Output<string>
nixCacheHmacAccessId: pulumi.Output<string>
nixCacheHmacSecret: pulumi.Output<string>  // Pulumi secret
```

Top-level stack outputs use those last three exact names plus secret output
`nixCacheJwtPrivateKeyBase64`. The cache storage Secret maps them to the standard
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` names.

The cluster contract is:

```text
Namespace: personal
Deployment/Service: nix-cache
URL: http://nix-cache.personal.svc.cluster.local/nagare-cache
Database Secret: nagare-db-nix-cache, key DATABASE_URL
Storage Secret: nagare-nix-cache-storage
JWT Secret: nagare-nix-cache-token-key
Client ConfigMap: nagare-nix-cache-client, key nix.conf
Client opt-in label: nagare.dev/nix-cache-client: "true"
```

EP-2 of the parent MasterPlan consumes only the ConfigMap name/key and opt-in label. Kotei
will consume the same stable URL, public key, mount, and label in its own plan; it is not a
Nagare source dependency. GCS is the chunk store, managed Postgres is metadata and signing
identity, Artifact Registry carries the pinned server image, and Victoria supplies the
capacity-alert evaluation path.


## Revision Notes

2026-07-14: Replaced every indented command, Nix configuration, TypeScript interface,
and cluster-contract excerpt with an explicitly language-tagged fenced code block, as
required by the ExecPlan formatting specification. No cache design or acceptance behavior
changed.
