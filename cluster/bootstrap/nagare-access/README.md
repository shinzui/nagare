# nagare-access auth enforcer

`nagare-access` is the shared identity-aware reverse proxy for protected Nagare
sites. Install this directory only if the cluster should support
`access = requireLogin`; it is deliberately not part of `just cluster-bootstrap`.

## Build the image

From the repository root:

```bash
cluster/bootstrap/nagare-access/build-image.sh
```

The script builds `cli/nagare-access/Dockerfile` for `linux/amd64`, tags it as
`$NAGARE_REGISTRY_HOST/$CLOUDSDK_CORE_PROJECT/$NAGARE_ARTIFACT_REGISTRY_ID/nagare-access:<git-sha>`,
pushes it by default, and prints the image reference. Set
`NAGARE_ACCESS_PUSH=0` to build locally without pushing. Because the Cabal
workspace pins private `shinzui/shomei` and `shinzui/en` source repositories,
set `GITHUB_TOKEN` when building in a fresh Docker environment; the Dockerfile
consumes it as a BuildKit secret and removes the temporary Git rewrite before
committing the build layer. Edit `service.yaml` to use the printed image before
applying.

To avoid private GitHub fetches during Docker build, set
`NAGARE_ACCESS_LOCAL_SOURCES=1` or `NAGARE_AUTH_LOCAL_SOURCES=1`. That path
delegates to `cluster/bootstrap/auth-images/build-local-image.sh`, assembling a
temporary context from the local Nagare, shomei, en, and codd checkouts plus
pinned public git dependencies for jose, servant-openapi, openapi-hs, and the
Shomei WebAuthn fork before building the same
`nagare-access` executable.

On Apple Silicon or another non-amd64 local Docker host, combine the local-source
path with Cloud Build for the real amd64 image:

```bash
NAGARE_ACCESS_LOCAL_SOURCES=1 NAGARE_AUTH_BUILDER=cloud-build cluster/bootstrap/nagare-access/build-image.sh
```

For the single-node `nagare-01` cluster, combine the local-source path with the
k3s import builder to build on the amd64 VM with Nix-provided podman and import
the image into k3s containerd:

```bash
NAGARE_ACCESS_LOCAL_SOURCES=1 NAGARE_AUTH_BUILDER=k3s-import cluster/bootstrap/nagare-access/build-image.sh
```

This prints an image such as `dev.local/nagare-auth/nagare-access:<git-sha>`.
Use the printed image in `service.yaml`; `dev.local` is already skipped by
Knative's controller-side tag resolver, and the non-`latest` tag lets kubelet use
the locally imported image.

shomei and en now have matching local-source image helpers at
`cluster/bootstrap/shomei/build-image.sh` and `cluster/bootstrap/en/build-image.sh`.
Their manifests expect managed PostgreSQL databases named `shomei-db` and
`en-db` in the `nagare-system` namespace, created with
`nagarectl db create postgres ...`.

## Install

Create a real cookie key secret from the example, update `service.yaml` with the
image and cookie domain for the target base domain, then apply:

```bash
cp cluster/bootstrap/nagare-access/secret.example.yaml.tmpl /tmp/nagare-access-secret.yaml
# edit /tmp/nagare-access-secret.yaml: set cookie-key to a long random value
kubectl apply -f /tmp/nagare-access-secret.yaml
kubectl apply -f cluster/bootstrap/nagare-access/configmap.yaml
kubectl apply -f cluster/bootstrap/nagare-access/service.yaml
```

The Knative Service is always-on (`min-scale=1`) because protected-site traffic
flows through it on every request. `nagarectl` checks for both the Knative
Service and the generated Kubernetes Service named `nagare-access` in
`nagare-system` before it will wire a protected site.
