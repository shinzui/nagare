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

shomei advertises a Nix flake `.#dockerImage` output, but validation from this
Nagare worktree currently fails before it produces an image. en does not
currently expose an equivalent image build output. Their bootstrap manifests
therefore keep operator-provided image references until those upstream images
are fixed/published or Nagare adds dedicated, verified build helpers for them.

## Install

Create a real cookie key secret from the example, update `service.yaml` with the
image and cookie domain for the target base domain, then apply:

```bash
cp cluster/bootstrap/nagare-access/secret.example.yaml /tmp/nagare-access-secret.yaml
# edit /tmp/nagare-access-secret.yaml: set cookie-key to a long random value
kubectl apply -f /tmp/nagare-access-secret.yaml
kubectl apply -f cluster/bootstrap/nagare-access/configmap.yaml
kubectl apply -f cluster/bootstrap/nagare-access/service.yaml
```

The Knative Service is always-on (`min-scale=1`) because protected-site traffic
flows through it on every request. `nagarectl` checks for both the Knative
Service and the generated Kubernetes Service named `nagare-access` in
`nagare-system` before it will wire a protected site.
