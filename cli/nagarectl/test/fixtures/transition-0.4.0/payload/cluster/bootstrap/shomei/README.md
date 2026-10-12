# shomei auth service

This directory bootstraps the shomei authentication service for Nagare's
optional auth plane. Install it only when protected sites are needed.

The manifests expect one container image that provides `shomei-server`,
`shomei-admin`, and `shomei-migrate`. Build it from the local Shomei checkout with:

```bash
cluster/bootstrap/shomei/build-image.sh
```

The script delegates to `cluster/bootstrap/auth-images/build-local-image.sh`,
which assembles a temporary Docker context from the local Shomei checkout. Its
generated Cabal project follows Shomei's current dependency policy: OpenAPI, JOSE,
pg-migrate, and health libraries come from Hackage; the reviewed WebAuthn fork stays
Git-pinned; and the cryptographic compatibility floors are explicit. It builds for
`linux/amd64` by default, tags the
image as
`$NAGARE_REGISTRY_HOST/$CLOUDSDK_CORE_PROJECT/$NAGARE_ARTIFACT_REGISTRY_ID/shomei:<git-sha>`,
pushes it by default, and prints the image reference. Set `NAGARE_AUTH_PUSH=0`
to build locally without pushing. Set `NAGARE_AUTH_SHOMEI_IMAGE` to the
resulting immutable reference before publishing a bootstrap review.

On Apple Silicon or another non-amd64 local Docker host, use Cloud Build for the
real amd64 image:

```bash
NAGARE_AUTH_BUILDER=cloud-build cluster/bootstrap/shomei/build-image.sh
```

For the single-node `nagare-01` cluster, you can avoid a registry push entirely
by building on the amd64 VM with Nix-provided podman and importing the image into
k3s containerd:

```bash
NAGARE_AUTH_BUILDER=k3s-import cluster/bootstrap/shomei/build-image.sh
```

This prints an image such as `dev.local/nagare-auth/shomei:<git-sha>`. Use the
printed image in `NAGARE_AUTH_SHOMEI_IMAGE`; `dev.local` is already skipped by Knative's
controller-side tag resolver, and the non-`latest` tag lets kubelet use the
locally imported image.

Override `SHOMEI_SRC` if the local checkout lives somewhere other than the helper's
default path.

The explicit `shomei-migrate` Job applies Shomei's embedded pg-migrate plan before
the server rollout. Shomei startup also migrates idempotently when the published
history is unchanged and ensures an active signing key. The manifest reads
`POSTGRES_USER`, `POSTGRES_PASSWORD`, and
`POSTGRES_DB` from Nagare's managed database Secret `nagare-db-shomei-db`, then
builds `PG_CONNECTION_STRING` as a libpq keyword connection string. The reviewed
auth component creates `shomei-db` in `nagare-system` before applying the service. The database
name intentionally differs from the service name `shomei` to avoid a Kubernetes
Service name collision.

Shomei 0.2.0.0 repaired migration bugs by rewriting its existing 36-file history to
be schema-qualified. The corrected SQL has different pg-migrate checksums, so a
pre-0.2 database needs operator-led ledger remediation before this migration.
Preserve its data and review that recovery separately. The owning component is
`mori://shinzui/shomei/packages/shomei-migrations`.

For a new installation, publish and apply the complete reviewed bootstrap:

```bash
review_dir="$(mktemp -d)"
nagarectl platform bootstrap plan --out "$review_dir"
nagarectl platform bootstrap apply "$review_dir" --yes
```

The supported `cluster/bootstrap/auth-install.sh` entry point runs those same
reviewed commands. The auth component creates and preserves `nagare-shomei-keys`, whose
`key-encryption-key` value is mandatory at server startup. Readiness is served at
`/health/ready` and liveness at `/health/live`.

The issuer and audience in `service.yaml` must match
`NAGARE_ACCESS_SHOMEI_ISSUER` and `NAGARE_ACCESS_SHOMEI_AUDIENCE` in
`cluster/bootstrap/nagare-access/service.yaml`.
