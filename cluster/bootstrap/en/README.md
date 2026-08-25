# en authorization service

This directory bootstraps the en relationship-based authorization service for
Nagare's optional auth plane. Install it only when protected sites are needed.

`configmap.yaml` mounts the Nagare app authorization schema:

```text
object user {}

object app {
  relation viewer: user
  permission access: viewer
}
```

Before serving real traffic, run en's PostgreSQL migrations against the database
in `EN_DATABASE_URL`; `en-server` expects the schema tables to exist at startup.
Build the `en-server` image from the local en checkout with:

```bash
cluster/bootstrap/en/build-image.sh
```

The script delegates to `cluster/bootstrap/auth-images/build-local-image.sh`,
which assembles a temporary Docker context from the local En checkout. Its generated
Cabal project includes `en-biscuit`, pins the reviewed
`mori://shinzui/biscuit-haskell` fork, and resolves the remaining dependency closure
from Hackage with the crypton 1.1 floor. It builds for `linux/amd64` by default, tags the
image as
`$NAGARE_REGISTRY_HOST/$CLOUDSDK_CORE_PROJECT/$NAGARE_ARTIFACT_REGISTRY_ID/en:<git-sha>`,
pushes it by default, and prints the image reference. Set `NAGARE_AUTH_PUSH=0`
to build locally without pushing. Edit `service.yaml` to use the printed image
before applying.

On Apple Silicon or another non-amd64 local Docker host, use Cloud Build for the
real amd64 image:

```bash
NAGARE_AUTH_BUILDER=cloud-build cluster/bootstrap/en/build-image.sh
```

For the single-node `nagare-01` cluster, you can avoid a registry push entirely
by building on the amd64 VM with Nix-provided podman and importing the image into
k3s containerd:

```bash
NAGARE_AUTH_BUILDER=k3s-import cluster/bootstrap/en/build-image.sh
```

This prints an image such as `dev.local/nagare-auth/en:<git-sha>`. Use the
printed image in `service.yaml`; `dev.local` is already skipped by Knative's
controller-side tag resolver, and the non-`latest` tag lets kubelet use the
locally imported image.

Override `EN_SRC` if the local checkout lives somewhere other than the helper's
default path.

The service and migration Job both read `POSTGRES_USER`, `POSTGRES_PASSWORD`,
and `POSTGRES_DB` from Nagare's managed database Secret `nagare-db-en-db`. The
service builds `EN_DATABASE_URL` as a libpq keyword connection string, and the
migration executable uses the same standard `PG*` environment variables through
libpq. Create
the database `en-db` in `nagare-system` before running migrations. The database
name intentionally differs from the service name `en` to avoid a Kubernetes
Service name collision.

`migrations.yaml` runs en's supported `en-migrate up` executable from the exact
same image tag as `en-server`. The executable embeds the append-only migration
manifest owned by `mori://shinzui/en/packages/en-migrations` and records applied
checksums in pg-migrate's database ledger (`mori://shinzui/pg-migrate`). Both auth
installers delete the completed Kubernetes Job before applying it because Job pod
templates are immutable and completed Jobs do not rerun. Recreating the Job is
safe: pg-migrate takes an advisory lock and applies only pending migrations.

En requires bearer authentication. Both installers create and preserve the
`nagare-en-api-keys` Secret: En receives named read-write and read-only entries,
`nagarectl` uses the raw read-write key, and nagare-access receives only the raw
read-only key.

```bash
kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -
nagarectl db create postgres en-db --namespace nagare-system
cluster/bootstrap/render-context-template.sh cluster/bootstrap/en/migrations.yaml | kubectl apply -f -
kubectl -n nagare-system wait --for=condition=complete job/en-migrate --timeout=120s
cluster/bootstrap/en/build-image.sh
kubectl apply -f cluster/bootstrap/en/configmap.yaml
cluster/bootstrap/render-context-template.sh cluster/bootstrap/en/service.yaml | kubectl apply -f -
```

If the migration Job fails, inspect it before retrying:

```bash
kubectl -n nagare-system logs job/en-migrate
cluster/bootstrap/auth-install.sh
```
