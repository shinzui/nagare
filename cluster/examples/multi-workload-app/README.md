# multi-workload-app — one app, four kinds, one identity

Most nagare apps are a single workload: one Knative Service, or one Worker, or
one Task. A real application is often **several workloads at once**. This example
is the `shinzui/kizashi` shape — one logical app that is, in Nagare terms, **six
objects across four kinds**:

| Workload | Kind | What it is |
|----------|------|------------|
| `kizashi-serve` | Knative Service | the HTTP API |
| `kizashi-worker` | `apps/v1` Deployment (Worker) | a background reactor |
| `kizashi-agent-worker` | `apps/v1` Deployment (Worker) | a second reactor |
| `kizashi-db` | StatefulSet (managed Database) | Postgres 18 |
| `kizashi-migrate` | Task | schema migration, run before the app boots |

Instead of four-plus separate `Config.hs` files repeating the same name prefix,
namespace, image, and database binding — deployed by four-plus separate commands
with no shared identity or ordering — the whole app is **one typed `Application`**
in [`nagare/Config.hs`](nagare/Config.hs):

- The **image**, **namespace**, **env**, and **database binding** are declared
  **once** on the `Application` and validated to flow down to every workload. A
  worker pointing at an undeclared database, a workload disagreeing on the shared
  image, or two workloads sharing a name are **rejected at config-load time** with
  a precise message — the same maximal-safety discipline as the rest of the DSL.
- Every object the app renders carries one shared identity label,
  `nagare.dev/app: kizashi`, so the whole app can be listed, inspected, and torn
  down as a unit.

A public, pullable image (`gcr.io/knative-samples/helloworld-go`) is used for
every workload so this example deploys with no build step and no registry
credentials of your own.

## Deploy

`nagarectl app deploy` (EP-2) builds and pushes the shared image once, then rolls
the app out in dependency order — **pre-deploy hooks first** (the migration Task
runs to completion and must succeed), **then** the managed databases are ensured,
**then** the Service and Workers are applied and waited on:

```bash
# Dry-run (no cluster needed): see every rendered object with its nagare.dev/app label.
nagarectl app deploy -f cluster/examples/multi-workload-app/nagare/Config.hs --dry-run
```

A failed pre-deploy hook aborts the release before any Service or Worker is
touched — so "run migrations before the new code boots" is a first-class,
enforced property rather than a manual runbook step.

See [Deploying apps](../../../docs/user/deploying-apps.md) and
[Running workers](../../../docs/user/workers.md) for the per-kind guides.
