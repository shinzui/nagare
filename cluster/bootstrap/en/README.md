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

Before serving real traffic, run en's PostgreSQL migrations from the en release
artifact against the database in `EN_DATABASE_URL`; `en-server` expects the
schema tables to exist at startup. The current en repository does not publish a
container image or a migration executable; the `image:` in `service.yaml` is an
operator-provided release image until en publishes one or Nagare adds an en
image helper. Build and mirror an `en-server` image from the en repository, then
edit `service.yaml` before applying it.

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
kubectl apply -f cluster/bootstrap/en/configmap.yaml
kubectl apply -f cluster/bootstrap/en/service.yaml
```

If the migration Job fails, inspect it before retrying:

```bash
kubectl -n nagare-system logs job/en-migrate
kubectl -n nagare-system delete job en-migrate
kubectl apply -f cluster/bootstrap/en/migrations.yaml
```
