# heartbeat-task — a co-located scheduled task

A minimal app, `heartbeat-app`, that co-locates one scheduled task, `heartbeat`,
which runs every 15 minutes in the app's own image (it inherits the app's image —
`taskImage = Nothing`) and prints the current UTC time. `nagarectl deploy`
provisions the app's Knative Service **and** the task's CronJob in one pass — there
is no separate "apply a standalone task" command. See
[`docs/user/scheduled-tasks.md`](../../../docs/user/scheduled-tasks.md).

## Files

- `nagare/Config.hs` — a `Deployment` for `heartbeat-app` whose `tasks` list carries
  one inheriting `Task` (name `heartbeat`, schedule `*/15 * * * *`, command
  `date -u`). It emits a `Deployment` JSON whose `tasks` array carries the task as
  `{"kind":"Task", ...}`.

## Verify offline (no cluster)

```bash
# 1) The config emits a Deployment whose tasks array carries the task:
( cd cli/nagarectl && cabal exec -- runghc -XGHC2024 -XOverloadedStrings \
    ../../cluster/examples/heartbeat-task/nagare/Config.hs )
# -> {... "name":"heartbeat-app", ... "tasks":[{"kind":"Task","name":"heartbeat","app":"heartbeat-app","image":null,...}]}

# 2) Render the app's Service and the task's CronJob without applying anything:
cabal --project-dir=cli/nagarectl run nagarectl -- deploy \
  -f cluster/examples/heartbeat-task/nagare/Config.hs \
  --base-domain apps.example.com --tag 20260610-180000 --dry-run
```

The `deploy --dry-run` output shows, after the Knative Service, a
`--- Task CronJob manifest ---` banner with a `batch/v1` CronJob named
`nagare-task-heartbeat`, the labels `nagare.dev/managed-by: nagarectl`,
`nagare.dev/task: heartbeat`, and `nagare.dev/app: heartbeat-app`, `schedule:
"*/15 * * * *"`, the inherited image
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/heartbeat-app:20260610-180000`, the
command `date -u`, and the predefined `NAGARE_TASK_NAME`/`NAGARE_NAMESPACE`/
`NAGARE_APP`/`NAGARE_RUN_ID` env entries.

## Live run (on `nagare-01`)

> The workstation cannot reach the k3s API (IAP forwards only SSH/22). Run these
> **on the VM** via `scripts/iap-ssh.sh`, after `gcloud compute instances start
> nagare-01 --project=tan-nb-exp --zone=us-west1-a`.

```bash
nagarectl deploy -f cluster/examples/heartbeat-task/nagare/Config.hs
nagarectl task list heartbeat-app    # heartbeat appears, scoped to its app
nagarectl task run heartbeat-app heartbeat    # runs once now (a one-off Job)
nagarectl task logs heartbeat-app heartbeat   # the most recent run's output (a UTC timestamp)
```

## Clean up

```bash
nagarectl task delete heartbeat-app heartbeat --yes   # removes the CronJob (idempotent)
```
