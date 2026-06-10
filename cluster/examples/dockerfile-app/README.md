# dockerfile-app — Dockerfile build mode

Builds the container image from the `Dockerfile` in this directory and pushes it
to `us-west1-docker.pkg.dev/tan-nb-exp/nagare/dockerfile-app`.

It demonstrates a **build argument**: the config's
`buildArgs = {"SITE_MESSAGE": ...}` is passed as `--build-arg SITE_MESSAGE=...`,
and the `Dockerfile`'s `ARG SITE_MESSAGE` bakes it into the served page.

## Deploy

```bash
# Dry-run (no cluster needed):
nagarectl deploy -f cluster/examples/dockerfile-app/nagare/Config.hs --dry-run
```

Expected:

```text
Build mode: docker build -f Dockerfile .
```

A real `nagarectl deploy` runs
`docker build -f Dockerfile -t <ref> --build-arg SITE_MESSAGE=... .`, pushes the
image, and waits for the Knative Service to become Ready.

### Overrides

The Dockerfile path and build context can be overridden on the command line
(handy for a monorepo subdirectory) — these win over the config:

```bash
nagarectl deploy -f .../Config.hs --dockerfile docker/Dockerfile.prod -c services/web
```

See [build modes](../../../docs/user/build-modes.md) for the full guide.
