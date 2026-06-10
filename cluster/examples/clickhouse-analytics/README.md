# clickhouse-analytics — a ClickHouse analytics store (`CLICKHOUSE_URL`)

A managed ClickHouse database (`events`) plus a tiny web app that writes an event
row on `GET /track` and returns the count on `GET /count`, using the injected
ClickHouse connection env. See
[`docs/user/managed-databases.md`](../../../docs/user/managed-databases.md).

> **Memory limit (important).** ClickHouse assumes it owns most of the host RAM;
> on the small `e2-standard-2` VM it must be capped or it destabilizes the node.
> The renderer mounts a `config.d` `max_server_memory_usage` cap (~1.5 GiB), and
> `nagare/Database.hs` additionally sets a container memory limit of `2Gi` via
> `resources`. EP-43 verified these numbers keep the node out of memory pressure.

## Files

- `nagare/Database.hs` — the typed `Database` (`engine = ClickHouse`,
  `version 25.8` LTS, `5Gi`, **`resources` memory request 512Mi / limit 2Gi**,
  `retention = Retain`).
- `nagare/Config.hs` — the app `Deployment`; `databases = ["events"]`.
- `app.py` / `Dockerfile` — a stdlib HTTP app + `clickhouse-driver` (native, 9000).

## Verify offline

```bash
nagarectl db create clickhouse events --size 5Gi --memory 2Gi --dry-run
nagarectl deploy -f cluster/examples/clickhouse-analytics/nagare/Config.hs --dry-run
```

`db create --dry-run` shows a one-replica StatefulSet on
`clickhouse/clickhouse-server:25.8` exposing both 9000 (native) and 8123 (HTTP),
mounting `/var/lib/clickhouse` and the memory-cap ConfigMap at
`/etc/clickhouse-server/config.d/low-memory.xml`, the container memory `limit: 2Gi`,
a `5Gi` PVC, the Secret, and the backup CronJob. The `deploy --dry-run` shows
`CLICKHOUSE_HOST`/`CLICKHOUSE_PORT`(9000)/`CLICKHOUSE_USER` literals and
`CLICKHOUSE_URL`/`CLICKHOUSE_PASSWORD` `secretKeyRef`s.

## Live run (on `nagare-01`)

> Run on the VM via `scripts/iap-ssh.sh`. Backups' GCS upload is currently
> blocked (see the user guide).

```bash
nagarectl db create clickhouse events --size 5Gi --memory 2Gi
nagarectl deploy -f cluster/examples/clickhouse-analytics/nagare/Config.hs
URL=$(nagarectl app get clickhouse-analytics | sed -n 's/^URL:[[:space:]]*//p')
curl -fsS "$URL/track"   # -> events: 1
curl -fsS "$URL/count"   # -> events: 1
```

## Clean up

```bash
nagarectl db delete events --yes        # retention = Retain keeps the PVC
nagarectl app delete clickhouse-analytics
kubectl delete pvc -n personal nagare-db-events-data   # DESTRUCTIVE
gsutil rm -r gs://tan-nb-exp-nagare-backups/databases/events/
```
