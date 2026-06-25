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
which assembles a temporary Docker context from the local Nagare, shomei, en,
codd, hs-jose, and webauthn checkouts. It builds for `linux/amd64`, tags the
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

Override `EN_SRC` or `CODD_SRC` if the local checkouts live somewhere other than
the helper's default paths.

The service and migration Job both read `POSTGRES_USER`, `POSTGRES_PASSWORD`,
and `POSTGRES_DB` from Nagare's managed database Secret `nagare-db-en-db`. The
service builds `EN_DATABASE_URL` as a libpq keyword connection string, and the
migration Job uses the standard `PG*` environment variables for `psql`. Create
the database `en-db` in `nagare-system` before running migrations. The database
name intentionally differs from the service name `en` to avoid a Kubernetes
Service name collision.

`migrations.yaml` is the Nagare bootstrap wrapper for en's current SQL
migrations. It mounts the en migration files into a Kubernetes Job and runs
`psql` from the `postgres:18` image against the same database Secret used by
`en-server`. The Job first checks whether `public.relation_tuple` already
exists; if it does, the Job exits successfully without reapplying the SQL. This
keeps the first bootstrap idempotent while en does not publish a migration image
or executable.

Earlier bootstrap work tried DockerHub `mzabani/codd:latest`, but containerd on
`nagare-01` rejects that image because its image config encodes `Entrypoint` as
a string instead of the OCI array shape. Replace this psql bootstrap with codd
when en publishes a valid migration image or embedded migration executable.

```bash
kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -
nagarectl db create postgres en-db --namespace nagare-system
kubectl apply -f cluster/bootstrap/en/migrations.yaml
kubectl -n nagare-system wait --for=condition=complete job/en-migrate --timeout=120s
cluster/bootstrap/en/build-image.sh
kubectl apply -f cluster/bootstrap/en/configmap.yaml
kubectl apply -f cluster/bootstrap/en/service.yaml
```

If the migration Job fails, inspect it before retrying:

```bash
kubectl -n nagare-system logs job/en-migrate
kubectl -n nagare-system delete job en-migrate
kubectl apply -f cluster/bootstrap/en/migrations.yaml
```
