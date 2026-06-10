# app-cleanup-task — an app-associated scheduled task

The `postgres-app` web service (which references the managed `pg-main` database)
co-locating a scheduled task, `cleanup`, that **inherits the app's image and runtime
env/secrets** and runs a nightly cleanup against the same database. The task
references the app by name (`taskApp = Just "postgres-app"`) and leaves
`taskImage = Nothing`, so at deploy time it runs in the app's deployed image with the
app's injected `DATABASE_URL`. Its CronJob carries the `nagare.dev/app: postgres-app`
label. See [`docs/user/scheduled-tasks.md`](../../../docs/user/scheduled-tasks.md).

This example builds on [`postgres-app`](../postgres-app/) — its `Config.hs` is the
same app plus a co-located task, and it needs the same managed database. Provision
the database first (see the postgres-app README).

## Files

- `nagare/Config.hs` — the `postgres-app` `Deployment` (referencing the `pg-main`
  database) whose `tasks` list carries one inheriting `Task`: `taskApp = Just
  "postgres-app"`, `taskImage = Nothing`, schedule `0 3 * * *`, a cleanup command that
  reads the inherited `DATABASE_URL`.

## Verify offline (no cluster)

```bash
# The config emits a Deployment whose tasks array carries the app-associated task:
( cd cli/nagarectl && cabal exec -- runghc -XGHC2024 -XOverloadedStrings \
    ../../cluster/examples/app-cleanup-task/nagare/Config.hs )
# -> {... "name":"postgres-app", "databases":["pg-main"],
#     "tasks":[{"kind":"Task","name":"cleanup","app":"postgres-app","image":null,...}]}
```

> Unlike the [`heartbeat-task`](../heartbeat-task/) example, a full `deploy --dry-run`
> of this app needs a **reachable cluster**, because the app references the managed
> `pg-main` database and Nagare resolves that database's connection env at deploy time
> (exactly as the [managed-database examples](../../../docs/user/managed-databases.md)
> note). The `runghc` emit above is the offline proof; the rendered CronJob is shown by
> the live `deploy` below.

## Live run (on `nagare-01`)

> Run these **on the VM** via `scripts/iap-ssh.sh`, after starting `nagare-01`.
> Provision the `postgres-app` database first (`nagarectl db create postgres pg-main`,
> see the postgres-app README) so the inherited image and `DATABASE_URL` exist.

```bash
# Provision the app, its database connection env, and the task's CronJob:
nagarectl deploy -f cluster/examples/app-cleanup-task/nagare/Config.hs

# It is scoped to the postgres-app app:
nagarectl task list postgres-app
#   NAME       APP            SCHEDULE     LAST RUN   LAST SUCCESS   ACTIVE
#   cleanup    postgres-app   0 3 * * *    never      never          0

# Run it once now (a one-off Job from the CronJob template — bypasses the schedule):
nagarectl task run postgres-app cleanup
#   Starting one-off run nagare-task-cleanup-manual-<timestamp> ...
#   job.batch/nagare-task-cleanup-manual-<timestamp> created
#   job.batch/nagare-task-cleanup-manual-<timestamp> condition met
#   Task cleanup completed (nagare-task-cleanup-manual-<timestamp>).

# Read the most recent run's logs (and the Grafana history hint):
nagarectl task logs postgres-app cleanup
#   cleanup would run against postgresql://...@pg-main.personal.svc.cluster.local:5432/...
#   For older runs, query VictoriaLogs in Grafana with: kubernetes.pod_labels.nagare.dev/task:="cleanup"
```

The `cleanup` pod sees the same `DATABASE_URL` the `postgres-app` container sees,
because the task inherits the app's runtime Secret via `envFrom` — that is the whole
point of the app association.

## Clean up

```bash
nagarectl task delete postgres-app cleanup --yes   # removes the CronJob (idempotent)
```
