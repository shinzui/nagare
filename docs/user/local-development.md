# Local development

> **Status:** 🟢 Local mode is complete. The local cluster, the local
> deploy/build target, local data services, MinIO-backed backups, the optional
> auth plane with locally-trusted TLS, and the `just local-smoke` end-to-end
> regression test all run with no GCP account (MasterPlan 16, EP-82–EP-86).

Local mode runs Nagare on your laptop with no GCP account and no cloud resources.
It replaces the cloud substrate with local equivalents:

| Cloud mode | Local mode |
| --- | --- |
| GCE VM running k3s | k3d cluster running k3s in Docker |
| Artifact Registry | `k3d-registry.localhost:5000` |
| Cloud DNS apps domain | `127-0-0-1.sslip.io` loopback wildcard |
| GCS backup bucket | MinIO in `nagare-system` |
| GCP project guardrail | steps aside only for a `mode=local` context |

The app-facing commands stay the same. In local mode, `nagarectl deploy` builds
for `NAGARE_TARGET_PLATFORM`, skips `gcloud auth configure-docker`, pushes to the
local registry, and serves apps at `<app>.127-0-0-1.sslip.io`. Apps are reachable
over plain HTTP until you install the [optional auth plane](#optional-the-auth-plane);
that step enables Knative auto-TLS against a locally-trusted CA, after which the
deploy URL becomes `https://…` (the secure context WebAuthn requires).

## Prerequisites

- The repo dev shell from [Getting started](getting-started.md).
- Docker or a compatible runtime for k3d.
- Host Docker must be able to push to `k3d-registry.localhost:5000` over HTTP.
  `nagare.local.env.example` includes Docker Desktop, Colima, and Linux notes.

## Create the local context

The context-native path is:

```bash
nagarectl context create local --mode local \
  --registry-host k3d-registry.localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --target-platform linux/arm64 \
  --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups \
  --use
```

Use `linux/amd64` instead of `linux/arm64` on Intel/AMD hosts. After this,
`direnv reload` or re-enter the shell so `.envrc` projects the selected context.
You can also select local mode for one command:

```bash
NAGARE_CONTEXT=local just local-smoke
```

The back-compatible in-repo profile path still works:

```bash
cp nagare.local.env.example nagare.local.env
```

Edit `NAGARE_TARGET_PLATFORM` if needed:

```bash
# Apple Silicon
export NAGARE_TARGET_PLATFORM=linux/arm64

# Intel/AMD
export NAGARE_TARGET_PLATFORM=linux/amd64
```

Then enter local mode:

```bash
nagarectl context use local      # context path
# or, for the legacy in-repo profile path only:
# export NAGARE_MODE=local
direnv allow
```

The important contract variables are:

| Variable | Local value |
| --- | --- |
| `NAGARE_MODE` | `local` |
| `NAGARE_REGISTRY_HOST` | `k3d-registry.localhost:5000` |
| `NAGARE_BASE_DOMAIN` | `127-0-0-1.sslip.io` |
| `NAGARE_TARGET_PLATFORM` | your local node platform |
| `NAGARE_LOCAL_OBJECT_STORE` | `http://minio.nagare-system.svc.cluster.local:9000/nagare-backups` |

See [Target contexts](contexts.md) for the store layout, precedence, and
migration from `nagare.local.env`.

## Bring up the local platform

```bash
just local-up
just local-bootstrap
just local-minio
```

`local-up` creates the k3d cluster and local registry. `local-bootstrap` installs
cert-manager, Knative Serving, Kourier, net-certmanager, the `personal` and
`nagare-system` namespaces, the loopback base domain, and the local registry
tag-resolution skip. `local-minio` installs MinIO and seeds the bucket/credentials
used by local backup Jobs.

Verify:

```bash
kubectl get nodes
kubectl get pods -A
kubectl -n nagare-system get deploy/minio job/minio-make-bucket
```

## Deploy locally

From an app directory or from one of the examples:

```bash
nagarectl deploy -f cluster/examples/dockerfile-app/nagare/Config.hs
```

For a short image name such as `notes`, Nagare qualifies it through the local
target as:

```text
k3d-registry.localhost:5000/<project>/<repo>/notes:<tag>
```

The GCP project/repo segments remain in the image path for a stable naming
scheme, but the registry host is local and no GCP auth is performed.

## Data services and backups

The create paths for managed databases, Redpanda brokers, scheduled tasks, and
PVC-backed app volumes are ordinary Kubernetes objects, so they run on the local
cluster. The backup path switches automatically:

```bash
nagarectl db create postgres pg-main
nagarectl db backup pg-main

nagarectl storage snapshot notes data
```

In cloud mode these Jobs use `google/cloud-sdk:slim` and write `gs://...`. In
local mode they use the AWS CLI image, MinIO credentials from the
`nagare-minio-credentials` Secret, and the same object keys under
`s3://nagare-backups/...`.

Restore commands are also local-mode aware:

```bash
nagarectl db restore pg-main <backup-id>
nagarectl storage restore notes data <snapshot-id>
```

Restores stay scratch-first by default; pass `--into-live` only when you intend
to overwrite live data.

## Optional: the auth plane

Skip this unless you want to test a **require-login** app. The smoke test and
ordinary unauthenticated apps do not need it.

A protected app (`access = Just requireLogin` in its config — see
[Identity-aware access](access.md)) is fronted by the shomei identity service, the
en authorization service, and the nagare-access forward-auth enforcer. WebAuthn —
shomei's second factor — only works in a browser **secure context** (HTTPS, or
`localhost`). A loopback wildcard host like `app.127-0-0-1.sslip.io` is *not*
`localhost`, so the local auth plane ships a locally-trusted CA and points Knative
auto-TLS at it, serving apps over HTTPS.

Local mode builds the three auth images into the local registry (no gcloud), runs
shomei and en on local managed Postgres, and installs a self-signed
`nagare-local-ca` `ClusterIssuer`:

```bash
# Build + push shomei, en, and nagare-access to k3d-registry.localhost:5000,
# create the shomei-db/en-db managed Postgres, install the auth manifests, and
# stand up the nagare-local-ca ClusterIssuer + Knative auto-TLS wiring.
cluster/bootstrap/local-auth/install.sh
```

Then **trust the CA on your machine** so the browser accepts the local HTTPS and
the WebAuthn ceremony can run — see `cluster/bootstrap/local-tls/README.md` for the
OS/browser trust-store steps (or the `mkcert` alternative). The headless parts of
the flow (302 → 403 → `nagarectl access grant` → 200 → `revoke` → 403) work over
the local HTTPS origin with `curl --cacert`; only the passkey gesture itself needs
a real browser and authenticator. The enforcer caches decisions for ~30 s and en
caches reads for ~5 s, so **poll** after a grant/revoke rather than expecting an
instant change.

## Run the local smoke test

`just local-smoke` is the zero-cloud twin of the cloud `just smoke`: it runs the
same scenario — deploy → write a sentinel into a volume → snapshot → restore →
HTTP 200 → teardown — entirely on the local cluster, with **no gcloud, no IAP, and
no GCS**. It is the fastest way to confirm local mode is healthy end to end.

```bash
just local-smoke
```

It deploys the shipped `cluster/examples/uploads-volume` example, snapshots its
`/uploads` volume to local MinIO (an `s3://nagare-backups/...` object, never
`gs://`), restores it and confirms the sentinel round-trips, and asserts HTTP 200.
A teardown trap deletes the app, the MinIO snapshot object, and any restore-scratch
PVC on every exit (including Ctrl-C). If the cluster is down it runs `just
local-up` + `local-bootstrap` + `local-minio` first. A green run ends with:

```text
== step 4: verify HTTP 200 ==
  HTTP 200 OK
local smoke: OK
== teardown ==
== teardown done ==
```

The test reaches the app through a `kubectl -n kourier-system port-forward
svc/kourier` plus a `Host:` header rather than curling the loopback domain
directly, so it is robust even when a host reverse proxy (Caddy, portless, …) holds
ports 80/443 (see [Troubleshooting](#troubleshooting)). It is an on-demand
developer command and is **not wired into CI** — that would need a Docker-in-Docker
runner; a future DinD job is a clean addition since the local smoke has no cloud
credentials to manage.

## Tear down

```bash
just local-down
```

This deletes the k3d cluster and the managed local registry container. Any data
inside the local cluster, including MinIO objects and local-path PVC data, is
discarded with it.

## Troubleshooting

**Image won't pull (`ImagePullBackOff`).** The local registry host must resolve
*identically* from the host doing `docker push` and from in-cluster containerd.
Two host-side prerequisites (documented in `nagare.local.env.example`): add
`127.0.0.1 k3d-registry.localhost` to `/etc/hosts` if your resolver ignores
`.localhost`, and add `k3d-registry.localhost:5000` to your Docker daemon's
`insecure-registries` (the registry serves plain HTTP) and restart Docker. The
in-cluster pull needs neither — k3d wires it automatically.

**App returns 404 / a stranger's page on the loopback domain.** Curling
`http://<app>.127-0-0-1.sslip.io` directly can be intercepted by a host reverse
proxy (Caddy, portless, …) bound to ports 80/443, which shadows the k3d load
balancer and answers with *its* 404. Reach Knative through a port-forward instead:

```bash
kubectl -n kourier-system port-forward svc/kourier 18080:80 &
curl -sS -H "Host: <app>.personal.127-0-0-1.sslip.io" http://127.0.0.1:18080/
```

This is exactly what `just local-smoke` does. A genuine Knative 404 (no host proxy)
instead means the deploy-printed host does not match the Knative `config-domain`
set from `NAGARE_BASE_DOMAIN`; confirm the URL `nagarectl deploy` printed.

**macOS: registry catalog returns 403 / `Server: AirTunes`.** AirPlay Receiver
holds host port 5000, but the Docker daemon still pushes/pulls fine. Inspect the
registry from inside its container — `docker exec k3d-registry.localhost wget -qO-
http://localhost:5000/v2/_catalog` — or disable AirPlay Receiver in Control Center.

**`storage`/`db backup` writes a 0-byte object, or `secret not found`.** Run `just
local-minio` (the data-movement Job needs MinIO and its `nagare-minio-credentials`
Secret). The Secret is **namespace-local**; `cluster/local/minio/minio.yaml` seeds
it into `nagare-system` and `personal`. An app or database in a *different*
namespace needs the Secret copied there too.

**WebAuthn / login blocked.** The local CA is not trusted by your browser/OS, so
the secure-context requirement fails on the non-`localhost` loopback domain. Trust
the `nagare-local-ca` root per `cluster/bootstrap/local-tls/README.md`. This
applies only to the [optional auth plane](#optional-the-auth-plane).
