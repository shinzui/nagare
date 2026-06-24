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
artifact or image against the database in `EN_DATABASE_URL`; `en-server` expects
the schema tables to exist at startup.

```bash
cp cluster/bootstrap/en/secret.example.yaml /tmp/en-secret.yaml
# edit /tmp/en-secret.yaml: set EN_DATABASE_URL
kubectl apply -f /tmp/en-secret.yaml
kubectl apply -f cluster/bootstrap/en/configmap.yaml
kubectl apply -f cluster/bootstrap/en/service.yaml
```
