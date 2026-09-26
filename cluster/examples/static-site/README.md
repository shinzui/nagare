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

A dry run prints the canonical public site scope after checking the selected
context's accepted image publication and Namespace. The config loader needs to
resolve `nagare-dsl`, so run from `cli/nagarectl/` and point `--file` at this
example:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --skip-build --tag TAG \
  --image-resource RESOURCE-ID --dry-run \
  --file ../../cluster/examples/static-site/nagare/Config.hs
```

The scope lists the Service, release history, and their dependencies without
printing private native manifests.

## Real deploy

Publish the exact Nginx image archive with `app image-plan` first. With the
accepted resource ID, submit the reviewed site from this directory:

```bash
nagarectl site deploy --skip-build --tag TAG --image-resource RESOURCE-ID \
  --ghc-env /path/to/.ghc.environment.<arch>-<ghc>
```

The command publishes an immutable review and applies its declared Service
and release history. Verify with:

```bash
kubectl get ksvc -n personal
```
