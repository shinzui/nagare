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

A public image (`gcr.io/knative-samples/helloworld-go`) is used for every
workload in the typed config. For a reviewed deploy, change the shared image
reference to the selected context's registry, then publish an archive at that
exact destination and tag.

## Deploy

`nagarectl app deploy` requires an accepted image publication, an explicit tag,
and an initialized inventory store. Publish the image archive with
`app image-plan`, then supply its resource ID and the reviewed recovery and
hook-effect inputs described in the [deployment guide](../../../docs/user/deploying-apps.md).
The reviewed application workload waits for its declared pre-deploy Job proof:

```bash
nagarectl app deploy -f cluster/examples/multi-workload-app/nagare/Config.hs \
  --tag RELEASE_TAG --image-resource RESOURCE-ID \
  --hook-affects MIGRATION_TASK=database:DATABASE_NAME \
  --database-recovery DATABASE_NAME=BACKUP:KEY_VERSION
```

`--dry-run` uses the same reviewed compiler and requires the same accepted
dependencies. A failed migration Job leaves the workload unchanged until an
operator resolves that operation.

See [Deploying apps](../../../docs/user/deploying-apps.md) and
[Running workers](../../../docs/user/workers.md) for the per-kind guides.
