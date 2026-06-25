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
operator-provided release image until en publishes one. Build and mirror an
`en-server` image from the en repository, then edit `service.yaml` before
applying it.

`migrations.yaml` is the Nagare bootstrap wrapper for en's codd-managed SQL
migrations. It mounts the current en migration files into a Kubernetes Job and
runs codd against the same database Secret used by `en-server`. The mounted
ConfigMap keys use codd-compatible dashed timestamps while preserving the SQL
from en's compact-timestamp filenames.

The codd image source is DockerHub `mzabani/codd`. The versioned `0.1.8` tag is
not published as of this bootstrap work; the template therefore uses
`docker.io/mzabani/codd:latest`. For production, mirror that image into Nagare's
Artifact Registry or replace it with a verified digest before applying the Job.
The Job uses `codd up --no-check` because en currently ships SQL migrations but
no committed codd expected-schema snapshot.

```bash
cp cluster/bootstrap/en/secret.example.yaml /tmp/en-secret.yaml
# edit /tmp/en-secret.yaml: set EN_DATABASE_URL
kubectl apply -f /tmp/en-secret.yaml
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
