# postgres-app — a Postgres-backed app (`DATABASE_URL`)

A managed Postgres database (`pg-main`) plus a tiny web app that reads the
injected `DATABASE_URL`, inserts a row on `GET /add`, and returns the row count
on `GET /`. It demonstrates the full managed-database pipeline: declare →
provision → connect by name → back up. See
[`docs/user/managed-databases.md`](../../../docs/user/managed-databases.md).

## Files

- `nagare/Database.hs` — the typed `Database` (`engine = Postgres`, `version 18`,
  `10Gi`, `retention = Retain`).
- `nagare/Config.hs` — the app `Deployment`; `databases = ["pg-main"]` is what
  wires the connection env in.
- `app.py` / `Dockerfile` — a stdlib HTTP app + the `psycopg` driver.

## Verify offline (no cluster)

```bash
# The database manifests (Secret, PVC, Service, StatefulSet, backup CronJob):
nagarectl db create postgres pg-main --size 10Gi --dry-run

# The app, with the injected connection env (needs a reachable cluster to read
# the engine + identity for the database it references):
nagarectl deploy -f cluster/examples/postgres-app/nagare/Config.hs --dry-run
```

The `db create --dry-run` output shows a one-replica StatefulSet on `postgres:18`
mounting `/var/lib/postgresql/data`, a ClusterIP Service on 5432, a `10Gi`
`local-path` RWO PVC, and the `nagare-db-pg-main` Secret. The `deploy --dry-run`
shows `POSTGRES_HOST` as a literal and `DATABASE_URL`/`POSTGRES_PASSWORD` as
`secretKeyRef`s into `nagare-db-pg-main`.

## Live run (on `nagare-01`)

> The workstation cannot reach the k3s API (IAP forwards only SSH/22). Run these
> **on the VM** via `scripts/iap-ssh.sh`, after `gcloud compute instances start
> nagare-01 --project=tan-nb-exp --zone=us-west1-a`.
>
> **Backups are currently blocked** by a cluster routing regression (the in-pod
> metadata IP is unreachable — see the user guide); `db create`/`deploy`/`db
> restart` work, but `db backup`'s GCS upload will not until the node route is
> fixed.

```bash
nagarectl db create postgres pg-main --size 10Gi
nagarectl deploy -f cluster/examples/postgres-app/nagare/Config.hs
URL=$(nagarectl app get postgres-app | sed -n 's/^URL:[[:space:]]*//p')
curl -fsS "$URL/add"          # -> rows: 1
nagarectl db restart pg-main  # roll the database pod
curl -fsS "$URL/"             # -> rows: 1  (data survived the restart)
nagarectl db backup pg-main   # (blocked: GCS upload, see above)
gsutil ls "gs://tan-nb-exp-nagare-backups/databases/pg-main/"
```

## Clean up

```bash
nagarectl db delete pg-main --yes   # retention = Retain keeps the PVC and data
nagarectl app delete postgres-app
# To reclaim the disk (DESTRUCTIVE):
kubectl delete pvc -n personal nagare-db-pg-main-data
# GCS dumps survive deletion (bucket is forceDestroy: false); remove explicitly:
gsutil rm -r gs://tan-nb-exp-nagare-backups/databases/pg-main/
```
