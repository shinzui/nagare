# static-site example

A minimal static site deployed with `nagarectl site deploy` (EP-14). The files
in `public/` are served as-is by an Nginx image that Nagare generates — there is
no Dockerfile, `nginx.conf`, or Kubernetes YAML to write by hand.

## Files

- `nagare/Config.hs` — the typed `StaticSite` config. Uses `NoBuild "public"`,
  one redirect (`/old-home` → `/`, 301), one header rule
  (`X-Content-Type-Options: nosniff` on `/assets/`), an immutable-asset cache
  policy with a 600s default max-age, and a `404.html` page.
- `public/index.html`, `public/404.html` — the served content.

## Dry run

A dry run renders the generated artifacts without touching Docker or the
cluster. The config loader runs the config with `runghc`, which needs to resolve
the `nagare-dsl` package, so run it from `cli/nagarectl/` (which has a
`.ghc.environment.*`) and point `--file` at this example:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --dry-run \
  --file ../../cluster/examples/static-site/nagare/Config.hs
```

This prints the generated `nginx.conf`, the Knative Service manifest (Nginx
image on container port 8080), and the URL that would be deployed
(`https://static-site.personal.<base-domain>`, since this example sets no custom
domain).

## Real deploy

On a machine with Docker, `gcloud`, and cluster access (and the project's
`tan-nb-exp` GCP context), from this directory:

```bash
nagarectl site deploy --skip-build \
  --ghc-env /path/to/.ghc.environment.<arch>-<ghc>
```

`--skip-build` is used because `NoBuild` sites have no build command; the
`public/` directory is packaged directly. The command builds the Nginx image,
pushes it to Artifact Registry, applies the Knative Service, waits for it to
become Ready, and prints `Deployed static site: <url>`. Verify with:

```bash
kubectl get ksvc -n personal
```
