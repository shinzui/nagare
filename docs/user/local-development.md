# Local development

> **Status:** 🟡 Local cluster, local deploy/build target, local data services,
> and MinIO-backed backups are implemented. Local auth-plane/TLS and the full
> `just local-smoke` harness are still tracked by MasterPlan 16 EP-85/EP-86.

Local mode runs Nagare on your laptop with no GCP account and no cloud resources.
It replaces the cloud substrate with local equivalents:

| Cloud mode | Local mode |
| --- | --- |
| GCE VM running k3s | k3d cluster running k3s in Docker |
| Artifact Registry | `k3d-registry.localhost:5000` |
| Cloud DNS apps domain | `127-0-0-1.sslip.io` loopback wildcard |
| GCS backup bucket | MinIO in `nagare-system` |
| GCP project guardrail | bypassed only when `NAGARE_MODE=local` |

The app-facing commands stay the same. In local mode, `nagarectl deploy` builds
for `NAGARE_TARGET_PLATFORM`, skips `gcloud auth configure-docker`, pushes to the
local registry, and serves apps over HTTP at `<app>.127-0-0-1.sslip.io`.

## Prerequisites

- The repo dev shell from [Getting started](getting-started.md).
- Docker or a compatible runtime for k3d.
- Host Docker must be able to push to `k3d-registry.localhost:5000` over HTTP.
  `nagare.local.env.example` includes Docker Desktop, Colima, and Linux notes.

## Create the local target profile

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
export NAGARE_MODE=local
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

## Tear down

```bash
just local-down
```

This deletes the k3d cluster and the managed local registry container. Any data
inside the local cluster, including MinIO objects and local-path PVC data, is
discarded with it.
