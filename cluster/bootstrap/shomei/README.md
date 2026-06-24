# shomei auth service

This directory bootstraps the shomei authentication service for Nagare's
optional auth plane. Install it only when protected sites are needed.

The manifest expects a container image that provides `shomei-server`. shomei's
server startup runs database migrations idempotently and ensures an active
signing key, so the pod only needs a valid PostgreSQL connection string and the
issuer/audience values that `nagare-access` will verify.

```bash
cp cluster/bootstrap/shomei/secret.example.yaml /tmp/shomei-secret.yaml
# edit /tmp/shomei-secret.yaml: set PG_CONNECTION_STRING
kubectl apply -f /tmp/shomei-secret.yaml
kubectl apply -f cluster/bootstrap/shomei/service.yaml
```

The issuer and audience in `service.yaml` must match
`NAGARE_ACCESS_SHOMEI_ISSUER` and `NAGARE_ACCESS_SHOMEI_AUDIENCE` in
`cluster/bootstrap/nagare-access/service.yaml`.
