# prebuilt-image-app — prebuilt build mode

Deploys an image that **already exists** in a registry. Nothing is built or
pushed locally; the tag to deploy lives in the config (`PrebuiltImage "latest"`),
not computed at deploy time.

This example points at the public `gcr.io/knative-samples/helloworld-go` image,
so it deploys with no build step and no registry credentials of your own.

## Deploy

```bash
# Dry-run (no cluster needed): see the rendered manifest and the build action.
nagarectl deploy -f cluster/examples/prebuilt-image-app/nagare/Config.hs --dry-run
```

Expected:

```text
        image: gcr.io/knative-samples/helloworld-go:latest
Build mode: prebuilt image (no local build), tag latest
```

A real `nagarectl deploy` (against a running cluster) applies the Knative Service
referencing the upstream image directly — no `docker build`, no `docker push`.

See [build modes](../../../docs/user/build-modes.md) for the full guide.
