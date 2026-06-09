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

A dry run renders the generated artifacts without touching Docker or the cluster.
Run it from `cli/nagarectl/` (which has a `.ghc.environment.*` so the config
loader's `runghc` can resolve `nagare-dsl`) and point `--file` at this example:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --dry-run \
  --file ../../cluster/examples/tanstack-start/nagare/Config.hs
```

This prints the generated Dockerfile (`FROM node:22-alpine` … `CMD ["node",
".output/server/index.mjs"]`), the Knative Service manifest (Node image,
container port 8080, the env map, scale-to-zero), any DomainMappings, and the URL
that would be deployed (`https://tanstack-start.personal.<base-domain>`).

## Real deploy

On a machine with Docker, `gcloud`, and cluster access, from this directory:

```bash
npm ci && npm run build        # produces .output
nagarectl site deploy \
  --ghc-env /path/to/.ghc.environment.<arch>-<ghc>
```

The command builds the app (or use `--skip-build` if `.output` already exists),
packages `.output` into a Node image, pushes it to Artifact Registry, applies the
Knative Service, waits for it to become Ready, records a release, and prints
`Deployed server site: <url>`. Verify with:

```bash
kubectl get ksvc -n personal
curl -s https://tanstack-start.personal.<base-domain>/   # server-rendered HTML
```

The server's HTML is present in the initial response body (not an empty shell),
and any server function / API route answers — proving the server is executing,
not just serving files.
