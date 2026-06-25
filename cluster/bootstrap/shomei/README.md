# shomei auth service

This directory bootstraps the shomei authentication service for Nagare's
optional auth plane. Install it only when protected sites are needed.

The manifest expects a container image that provides `shomei-server` and
`shomei-admin`. Build it from the local shomei checkout with:

```bash
cluster/bootstrap/shomei/build-image.sh
```

The script delegates to `cluster/bootstrap/auth-images/build-local-image.sh`,
which assembles a temporary Docker context from the local Nagare, shomei, en,
codd, hs-jose, and webauthn checkouts. It builds for `linux/amd64`, tags the
image as
`$NAGARE_REGISTRY_HOST/$CLOUDSDK_CORE_PROJECT/$NAGARE_ARTIFACT_REGISTRY_ID/shomei:<git-sha>`,
pushes it by default, and prints the image reference. Set `NAGARE_AUTH_PUSH=0`
to build locally without pushing. Edit `service.yaml` to use the printed image
before applying.

Override `SHOMEI_SRC`, `CODD_SRC`, `JOSE_SRC`, or `WEBAUTHN_SRC` if the local
dependency checkouts live somewhere other than the helper's default paths.

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
cluster/bootstrap/shomei/build-image.sh
kubectl apply -f cluster/bootstrap/shomei/service.yaml
```

The issuer and audience in `service.yaml` must match
`NAGARE_ACCESS_SHOMEI_ISSUER` and `NAGARE_ACCESS_SHOMEI_AUDIENCE` in
`cluster/bootstrap/nagare-access/service.yaml`.
