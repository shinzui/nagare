# tanstack-start example

A full-stack JavaScript app deployed with `nagarectl site deploy` (EP-18). The
same command that deploys a static site deploys this server-rendered app — it
detects `kind = ServerSite` from the typed config and runs the Node path instead
of the Nginx path.

## Files

- `nagare/Config.hs` — the typed `ServerSite` config, using the TanStack Start
  defaults (`tanstackStartBuild` = `npm ci && npm run build` producing `.output`;
  `defaultServerRuntime` = `node:22-alpine` starting `node .output/server/index.mjs`),
  one env var (`HOSTNAME=0.0.0.0`), and scale-to-zero.
- `package.json` — a representative TanStack Start project with a `build` script.

This directory carries the Nagare config and a representative `package.json`; a
real project also has its `src/` routes. `npm run build` produces the
self-contained `.output` directory Nagare packages — Nagare copies that directory
into a Node image; it never builds inside the image.

## Dry run

A dry run prints the canonical public site scope using an accepted image
publication and Namespace. Run it from `cli/nagarectl/` so the config loader
can resolve `nagare-dsl`:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --skip-build --tag TAG \
  --image-resource RESOURCE-ID --dry-run \
  --file ../../cluster/examples/tanstack-start/nagare/Config.hs
```

The scope lists the Service, release history, and their dependencies without
printing private native manifests.

## Real deploy

Build the server output and publish its exact image archive with
`app image-plan` first. From this directory:

```bash
npm ci && npm run build        # produces .output for image preparation
nagarectl site deploy --skip-build --tag TAG --image-resource RESOURCE-ID \
  --ghc-env /path/to/.ghc.environment.<arch>-<ghc>
```

The command publishes an immutable review and applies its declared Service
and release history. Verify with:

```bash
kubectl get ksvc -n personal
curl -s https://tanstack-start.personal.<base-domain>/   # server-rendered HTML
```

The server's HTML is present in the initial response body (not an empty shell),
and any server function / API route answers — proving the server is executing,
not just serving files.
