# shomei auth service

This directory bootstraps the shomei authentication service for Nagare's
optional auth plane. Install it only when protected sites are needed.

The manifest expects a container image that provides `shomei-server`. The
shomei repository advertises a Nix flake `.#dockerImage` output, but validation
from this Nagare worktree currently fails before it produces an image because
shomei's Nix `callCabal2nix` path points at the multi-package repo root instead
of a package directory. Until shomei fixes that output or publishes a release
image, build and mirror a `shomei-server` image from the shomei repository and
edit `service.yaml` before applying it.

shomei's server startup runs database migrations idempotently and ensures an
active signing key. The manifest reads `POSTGRES_USER`, `POSTGRES_PASSWORD`, and
`POSTGRES_DB` from Nagare's managed database Secret `nagare-db-shomei-db`, then
builds `PG_CONNECTION_STRING` as a libpq keyword connection string. Create the
database `shomei-db` in `nagare-system` before applying the service. The database
name intentionally differs from the service name `shomei` to avoid a Kubernetes
Service name collision.

```bash
kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -
nagarectl db create postgres shomei-db --namespace nagare-system
kubectl apply -f cluster/bootstrap/shomei/service.yaml
```

The issuer and audience in `service.yaml` must match
`NAGARE_ACCESS_SHOMEI_ISSUER` and `NAGARE_ACCESS_SHOMEI_AUDIENCE` in
`cluster/bootstrap/nagare-access/service.yaml`.
