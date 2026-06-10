# redis-cache — a Redis-backed cache app (`REDIS_URL`)

A managed Redis database (`cache`) plus a tiny web app that uses the injected
`REDIS_URL` as a key/value cache. Demonstrates the Redis connection-env
injection. See [`docs/user/managed-databases.md`](../../../docs/user/managed-databases.md).

> Redis here is a single-replica **cache** (no replication). Treat its contents
> as ephemeral-tolerant — durable data belongs in Postgres/ClickHouse.

## Files

- `nagare/Database.hs` — the typed `Database` (`engine = Redis`, `version 8`,
  `2Gi`, `retention = Retain`).
- `nagare/Config.hs` — the app `Deployment`; `databases = ["cache"]`.
- `app.py` / `Dockerfile` — a stdlib HTTP app + the `redis-py` client.

## Verify offline

```bash
nagarectl db create redis cache --size 2Gi --dry-run
nagarectl deploy -f cluster/examples/redis-cache/nagare/Config.hs --dry-run
```

`db create --dry-run` shows a one-replica StatefulSet on `redis:8` started with
`redis-server --requirepass "$REDIS_PASSWORD" ...` (the password from the Secret),
mounting `/data`, a ClusterIP Service on 6379, a `2Gi` PVC, and the Secret. The
`deploy --dry-run` shows `REDIS_HOST`/`REDIS_PORT` literals and
`REDIS_URL`/`REDIS_PASSWORD` `secretKeyRef`s.

## Live run (on `nagare-01`)

> Run on the VM via `scripts/iap-ssh.sh` (the workstation cannot reach the k3s
> API). Backups' GCS upload is currently blocked (see the user guide).

```bash
nagarectl db create redis cache --size 2Gi
nagarectl deploy -f cluster/examples/redis-cache/nagare/Config.hs
URL=$(nagarectl app get redis-cache | sed -n 's/^URL:[[:space:]]*//p')
curl -fsS "$URL/set?k=hello&v=world"   # -> OK
curl -fsS "$URL/get?k=hello"           # -> world
```

## Clean up

```bash
nagarectl db delete cache --yes        # retention = Retain keeps the PVC
nagarectl app delete redis-cache
kubectl delete pvc -n personal nagare-db-cache-data   # DESTRUCTIVE
gsutil rm -r gs://tan-nb-exp-nagare-backups/databases/cache/
```
