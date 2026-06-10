# env-and-secrets — managed env & secrets, end to end

A tiny `Deployment` example that **shows environment management taking effect**. The app
([`app.js`](app.js)) prints its `NAGARE_*` generated variables and a couple of
managed/inline variables, so you can `curl` the deployed URL and watch `nagarectl env`/
`nagarectl secret` changes appear.

This example is the worked companion to the user guide
[`docs/user/env-and-secrets.md`](../../../docs/user/env-and-secrets.md) — read that for the
full explanation of scopes, precedence, the CLI, and the live walkthrough.

## Files

- [`nagare/Config.hs`](nagare/Config.hs) — the typed `Deployment`. Declares three
  variables across scopes: `GREETING` (a Runtime literal), `BUILD_STAMP` (a Build-scoped
  literal — reaches `docker build`, not the runtime container), and `API_KEY` (a Runtime
  secret reference resolved from the Kubernetes Secret `envdemo-api-key`).
- [`app.js`](app.js) — a dependency-free Node HTTP server that echoes the selected env
  variables as plain text.
- [`Dockerfile`](Dockerfile) — builds the Node image and reads the Build-scoped
  `BUILD_STAMP` via `ARG`/`ENV`.
- [`.env.production`](.env.production) — a dotenv file for `nagarectl env sync`.
- [`.env.preview`](.env.preview) — a preview overlay (applied with `--preview`).

## Preview the rendered manifest (no cluster)

`deploy --dry-run` compiles-and-runs `nagare/Config.hs` and prints the manifests; it does
**not** build the Docker image. Run it from `cli/nagarectl` so the loader's `runghc`
resolves the `nagare-dsl` package:

```bash
cd cli/nagarectl
cabal run -v0 nagarectl -- deploy --dry-run \
  --file ../../cluster/examples/env-and-secrets/nagare/Config.hs \
  --base-domain apps.example.com --tag 20260602-120000
```

The container's inline `env:` shows `API_KEY` (secret-ref), `GREETING`, and the `NAGARE_*`
block, followed by the runtime `envFrom`. The Build-scoped `BUILD_STAMP` is **absent**
(scope filtering keeps it out of the running container) — confirm with:

```bash
cabal run -v0 nagarectl -- deploy --dry-run \
  --file ../../cluster/examples/env-and-secrets/nagare/Config.hs \
  --base-domain apps.example.com --tag 20260602-120000 | grep -c BUILD_STAMP
# Expect: 0
```

## Manage env and secrets

Every mutating command supports `--dry-run` (prints the ConfigMap/Secret that would be
applied, as compact JSON, and touches no cluster):

```bash
cd cli/nagarectl
C=../../cluster/examples/env-and-secrets/nagare/Config.hs

# set a managed env var
cabal run -v0 nagarectl -- env set envdemo REGION us-west1 --config $C --dry-run

# set a secret from stdin (value never appears in argv)
printf 'topsecret' | cabal run -v0 nagarectl -- secret set envdemo API_KEY --config $C --dry-run

# bulk-import a dotenv, replacing the store exactly
cabal run -v0 nagarectl -- env sync envdemo \
  --file ../../cluster/examples/env-and-secrets/.env.production --reconcile-exact \
  --config $C --dry-run
```

The full live walkthrough (deploy → `env set` + `curl` → `secret set` + `curl` →
`reconcile-exact` sync makes a key disappear → preview overlay) is in the
[user guide](../../../docs/user/env-and-secrets.md#the-cli).

## Cleanup

After a live walkthrough, remove the Service, any preview, and the managed stores (scoped
to namespace `personal` on `tan-nb-exp`):

```bash
kubectl -n personal delete ksvc envdemo --ignore-not-found
kubectl -n personal delete configmap \
  nagare-env-envdemo-runtime nagare-env-envdemo-build nagare-env-envdemo-preview \
  --ignore-not-found
kubectl -n personal delete secret \
  nagare-secret-envdemo-runtime nagare-secret-envdemo-build nagare-secret-envdemo-preview \
  envdemo-api-key --ignore-not-found
```
