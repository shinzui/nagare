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
  `version 26.8` LTS, `5Gi`, **`resources` memory request 512Mi / limit 2Gi**,
  `retention = Retain`).
- `nagare/Config.hs` — the app `Deployment`; `databases = ["events"]`.
- `app.py` / `Dockerfile` — a stdlib HTTP app + `clickhouse-driver` (native, 9000).

## Verify offline

```bash
nagarectl db create clickhouse events --size 5Gi --memory 2Gi --dry-run
```

`db create --dry-run` shows a one-replica StatefulSet on
`clickhouse/clickhouse-server:26.8` exposing both 9000 (native) and 8123 (HTTP),
mounting `/var/lib/clickhouse` and the memory-cap ConfigMap at
`/etc/clickhouse-server/config.d/low-memory.xml`, the container memory `limit: 2Gi`,
a `5Gi` PVC, the Secret, and the backup CronJob. Omitting `--version` selects the
`26.8` default; `--version 26.8.29.10` pins a full patch tag instead. A reviewed
app deploy injects `CLICKHOUSE_HOST`/`CLICKHOUSE_PORT`(9000)/`CLICKHOUSE_USER`
literals and `CLICKHOUSE_URL`/`CLICKHOUSE_PASSWORD` `secretKeyRef`s.

## Live run

Select the target context first (`nagarectl context current`). Creating the
database publishes and applies a reviewed inventory scope:

```bash
nagarectl db create clickhouse events --size 5Gi --memory 2Gi \
  --recovery-backup events-backup --recovery-key-version v1
nagarectl db get events
```

Build and publish the app image with `app image-plan` as described in
[Deploying apps](../../../docs/user/deploying-apps.md), then deploy the accepted
publication through the reviewed single-Service route:

```bash
nagarectl deploy -f cluster/examples/clickhouse-analytics/nagare/Config.hs \
  --tag TAG --image-resource IMAGE_RESOURCE_ID
URL=$(nagarectl app get clickhouse-analytics | sed -n 's/^URL:[[:space:]]*//p')
curl -fsS "$URL/track"   # -> events: 1
curl -fsS "$URL/count"   # -> events: 1
```

## Clean up

Retire the app first, then the database. Retirement keeps every provider
resource, including the PVC, as retained inventory history; delete them only
through separate `inventory collect` reviews
([inventory operations](../../../docs/runbooks/inventory-operations.md)).

```bash
nagarectl app delete clickhouse-analytics --save-plan ./app-retire
nagarectl inventory apply ./app-retire --yes
nagarectl db retire events --save-plan ./events-retire
nagarectl inventory apply ./events-retire --yes
```
