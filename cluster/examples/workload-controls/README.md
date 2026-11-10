# workload-controls

One Application that uses every workload control:

| Workload | Control |
|----------|---------|
| `workload-controls-web` | Independent `/ready`, `/healthz` and `/started` checks |
| `workload-controls-worker` | Readiness from `/tmp/ready`, liveness from `/tmp/alive`, a 60-second shutdown allowance |
| `workload-controls-migrate` | A pre-deploy migration task |

None of them names a service account, so each Pod runs with no Kubernetes API token.

The config uses a public image so it compiles anywhere. That image serves none of these paths and
contains no migration, so a real deploy needs an image that does. Replace the shared image with one
in the selected context's registry, publish it, and follow the
[deployment guide](../../../docs/user/deploying-apps.md).
