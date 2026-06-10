# app-lifecycle-demo

A runnable example for the **[App lifecycle](../../../docs/user/app-lifecycle.md)**
guide. Its `nagare/Config.hs` builds on the `webService` preset and adds the three
extended-model fields (EP-29):

- an HTTP **health check** on `/healthz` (readiness + liveness + startup probes),
- resource **limits** (500m / 512Mi) alongside the preset's requests (250m / 128Mi),
- two **domains** — `demo.example.com` (canonical) and `www.demo.example.com`.

## Render it without a cluster

From this directory:

```bash
nagarectl deploy --dry-run --tag 20260602-120000 --base-domain apps.example.com
```

This prints the Knative Service (with the `nagare.dev/managed-by: nagarectl`
label, the `resources.requests` + `resources.limits` blocks, and
`readinessProbe`/`livenessProbe`/`startupProbe`), one `DomainMapping` per domain,
and the canonical URL:

```text
Build mode: docker build -f Dockerfile .
URL: https://demo.example.com
```

> The image path is `us-west1-docker.pkg.dev/tan-nb-exp/nagare/lifecycle-demo`
> (the real Artifact Registry). A live deploy also needs a `Dockerfile` next to
> this README; the dry-run does not build, so none is required to render.

## End-to-end walk-through

Once `nagare-01` is up, the full day-2 surface (every command in the
[guide](../../../docs/user/app-lifecycle.md)) runs against this app:

```bash
nagarectl deploy --source "$(git rev-parse --short HEAD)"   # build, push, apply, record
nagarectl app list                                          # demo shows up, managed-by filtered
nagarectl app get lifecycle-demo                            # image, revision, URL, domains, health, limits
nagarectl app logs lifecycle-demo --tail 50                 # recent user-container logs
nagarectl deployments list lifecycle-demo                   # history, the live one starred
nagarectl deployments logs lifecycle-demo                   # logs for the live deployment
nagarectl app restart lifecycle-demo                        # roll a fresh revision
nagarectl app stop lifecycle-demo                           # take it offline (recoverable)
nagarectl app restart lifecycle-demo                        # bring it back online
nagarectl app delete lifecycle-demo                         # remove Service, DomainMappings, history
```

> **Status:** verified by `nagarectl deploy --dry-run` and the `nagare-dsl` /
> `nagarectl` unit + golden tests. The live leg is deferred until `nagare-01` is
> powered back on, matching the rest of the operator guide.
