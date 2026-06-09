# Static & full-stack site hosting

> **Status:** 🟡 **Built and tested offline; live deploy pending `nagare-01`.**
>
> The typed model, renderers, CLI, and the webhook runner (`nagared`) exist and
> are tested: `nagarectl site deploy --dry-run` loads a typed config and prints
> the exact generated Nginx config / Dockerfile and Knative manifests offline
> today. The *live* leg — build → push → apply → wait → URL — is implemented but
> has not been run end-to-end because `nagare-01` is currently powered down (the
> same caveat as [Deploying apps](deploying-apps.md)). Treat the "live deploy"
> steps as the intended behaviour until the box is back up.

This page is for **app developers** who want to host a website on Nagare the way
Cloudflare Pages hosts one: push a project, get an HTTPS URL, with previews,
rollbacks, redirects, and headers — and no Dockerfiles or Kubernetes YAML to
write. It replaces the static portion of Cloudflare Pages **and** its full-stack
story (server-side rendering, server functions, API routes) for personal
projects, staying entirely inside Nagare's single-node Knative cluster.

One command does it:

```bash
nagarectl site deploy
```

What you write is **not YAML** — it is a small, *typed* `nagare/Config.hs` that
the compiler checks before anything touches the cluster. A name that is not
DNS-safe, an absolute output directory, a redirect with status `200`, or a header
name containing a colon fail to compile or are rejected at load time with a
precise message, never silently accepted.

---

## Two kinds of site, one command

`nagarectl site deploy` reads the **kind** from your config and picks the runtime
automatically — you never choose a flag:

| Kind | For | What Nagare builds | Example |
| --- | --- | --- | --- |
| **`StaticSite`** | A folder of files (Vite/Astro/Hugo output, or hand-written HTML) | A small **Nginx** image serving the files | [`cluster/examples/static-site`](../../cluster/examples/static-site) |
| **`ServerSite`** | A full-stack app that runs a server (TanStack Start, Next.js, Nuxt, SvelteKit) | A small **Node.js** image running the framework's server build | [`cluster/examples/tanstack-start`](../../cluster/examples/tanstack-start) |

Both deploy as ordinary Knative Services — the same request-driven, scale-to-zero
model Nagare uses for any app. A release is a container image; a rollback is a
patch back to a prior image tag.

> **Out of scope:** Workers/`workerd`-style edge JavaScript. Nagare runs a
> full-stack app as an ordinary origin server (a Node process on Knative), which
> is the right model for a single-node personal PaaS and covers the application
> logic you actually write with these frameworks.

---

## Static sites

### The config

Put a `nagare/Config.hs` next to your project. It is an ordinary Haskell program
that builds a `StaticSite` through smart constructors and emits it. Here is the
bundled [`static-site`](../../cluster/examples/static-site/nagare/Config.hs)
example:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkImageRef, mkNamespace)

staticSite :: Either String StaticSite
staticSite = do
  name' <- mapLeft show (mkSiteName "static-site")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/static-site")
  dir' <- mapLeft show (mkFilePathText "public")
  redirect' <- mapLeft show (mkRedirectRule "/old-home" "/" 301)
  header' <- mapLeft show (mkHeaderRule "/assets/" "X-Content-Type-Options" "nosniff")
  cache' <- mapLeft show (mkCachePolicy True (Just 600))
  notFound' <- mapLeft show (mkFilePathText "404.html")
  Right
    StaticSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = NoBuild dir'
      , domains = []
      , redirects = [redirect']
      , headers = [header']
      , cache = cache'
      , notFound = Just notFound'
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case staticSite of
  Left err -> ioError (userError err)
  Right s -> emitStaticSite s
```

### Field reference

| Field | Meaning |
| --- | --- |
| `name` | DNS-label site name (also the Knative Service name). |
| `namespace` | Kubernetes namespace; use `mkNamespace "personal"`. |
| `image` | Artifact Registry repo for the built image, **no tag** (Nagare appends the tag). |
| `build` | `NoBuild dir` to serve an existing directory, or `BuildCommand { command, outputDirectory }` to run a build first (e.g. `npm run build` → `dist`). |
| `domains` | Custom hostnames (`[Domain]`); each becomes a Knative DomainMapping. Empty = the wildcard URL. |
| `redirects` | `[RedirectRule]`; `mkRedirectRule from to status` with status ∈ {301,302,303,307,308}. |
| `headers` | `[HeaderRule]`; `mkHeaderRule path name value` adds a response header for matching paths. |
| `cache` | `mkCachePolicy immutableAssets defaultMaxAge` — long-immutable caching for fingerprinted assets, plus a default `max-age`. |
| `notFound` | Optional `404.html`; when set, unmatched paths return 404 with that page. When unset, the catch-all falls back to `index.html` (SPA mode). |

Everything is validated at construction: `mkFilePathText` rejects absolute paths
and `..` escapes; `mkRedirectRule` rejects a bad status; `mkHeaderRule` rejects a
header name with whitespace, control characters, or a colon.

### Dry run

A dry run renders the two generated artifacts (the Nginx config and the Knative
manifests) with **no** Docker or cluster side effects:

```bash
cd cluster/examples/static-site
nagarectl site deploy --dry-run
```

If the binary cannot resolve `nagare-dsl` from the example directory, point it at
a package environment (the same mechanism as `nagarectl deploy`):

```bash
nagarectl site deploy --dry-run --ghc-env /path/to/.ghc.environment.<arch>-<ghc>
```

The output starts with the generated Nginx config and the Knative Service, and
ends with the URL and the release id that *would* be used:

```text
--- Generated nginx.conf ---
server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # redirect /old-home -> / (301)
    location = /old-home {
        return 301 /;
    }

    location /assets/ {
        add_header X-Content-Type-Options "nosniff" always;
        try_files $uri $uri/ =404;
    }

    # immutable fingerprinted assets
    location ~* \.(?:js|css|woff2?|png|jpe?g|gif|svg|ico|webp|avif)$ {
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        try_files $uri =404;
    }
    ...
}
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: static-site
  namespace: personal
spec:
  template:
    spec:
      containers:
      - image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/static-site:20260609-225143
        ports:
        - containerPort: 8080
URL: https://static-site.personal.apps.example.com
Release: 20260609-225143
```

### Live deploy

On a machine with Docker, `gcloud`, and cluster access (and the `tan-nb-exp` GCP
context), drop `--dry-run`. For a `NoBuild` site, add `--skip-build` (there is no
build command to run):

```bash
nagarectl site deploy --skip-build
```

Nagare runs the build (if any), packages the output into the generated Nginx
image, pushes it to Artifact Registry, applies the Knative Service and any
DomainMappings, waits for readiness, records a release, and prints
`Deployed static site: <url>`. Verify:

```bash
kubectl get ksvc -n personal
```

The image contract (you never write it): an `nginx:1.27-alpine` image listening
on container port 8080, serving `/usr/share/nginx/html`, with the generated
config copied over Nginx's `default.conf`.

---

## Releases and rollback

Every successful production deploy records a **release** — image tag, timestamp,
source, and URL — in a per-site Kubernetes ConfigMap
(`nagare-static-releases-<site>`). These commands are **runtime-agnostic**: they
work for both static and server sites.

```bash
nagarectl site releases             # list recorded releases (newest first; * = live)
nagarectl site rollback 20260609-120000   # re-point production at a prior image tag
```

Rollback re-applies the Service with the older image (already in the registry —
no rebuild) and marks that release current. History is capped at 50 records and a
re-deploy of the same tag updates in place rather than duplicating.

---

## Preview deployments

Deploy an isolated copy of the site — for a branch or pull request — under its
own name and domain, without touching production:

```bash
nagarectl site preview deploy --name feature-x
nagarectl site preview list
nagarectl site preview delete feature-x
```

A preview becomes a separate Knative Service named `<site>-pr-<name>` at
`https://<name>.<site>.preview.<base-domain>`. The name is normalized to a
DNS-safe form (`Feature/X-1` → `feature-x-1`). `delete` removes the preview's
Service and DomainMapping and is safe to repeat.

> Preview deploys currently target **static** sites. Server-site previews are a
> planned follow-up (see
> [`docs/plans/18`](../plans/18-full-stack-server-runtime-hosting-for-static-sites.md));
> production deploy, releases, and rollback already work for server sites.

---

## Full-stack sites (TanStack Start)

A full-stack app is the same command with a `ServerSite` config. The
[`tanstack-start`](../../cluster/examples/tanstack-start/nagare/Config.hs) example
uses the TanStack Start defaults, so the config is tiny:

```haskell
ServerSite
  { name = name'
  , namespace = ns'
  , image = img'
  , build = tanstackStartBuild      -- "npm ci && npm run build" -> .output
  , runtime = defaultServerRuntime  -- node:22-alpine, "node .output/server/index.mjs"
  , port = defaultPort              -- 8080
  , env = Map.fromList [(host, EnvLiteral "0.0.0.0")]  -- bind the wildcard address
  , resources = Nothing
  , scale = Nothing                 -- scale-to-zero; use Just (mkScale 1 n) to avoid cold starts
  , domains = []
  }
```

`build`/`runtime` cover the common Node frameworks: the same shape fits Next.js
`standalone` output, Nuxt/SolidStart (also Nitro), and SvelteKit's Node adapter —
override `command`, `outputDirs`, `baseImage`, and `startCommand` for those.

A dry run prints the generated Dockerfile and the Node Service:

```text
--- Generated Dockerfile ---
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY app/ ./
EXPOSE 8080
CMD ["node", ".output/server/index.mjs"]
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: tanstack-start
  namespace: personal
spec:
  template:
    spec:
      containers:
      - image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/tanstack-start:20260609-233748
        ports:
        - containerPort: 8080
        env:
        - name: HOSTNAME
          value: 0.0.0.0
URL: https://tanstack-start.personal.apps.example.com
Release: 20260609-233748
```

There is no `ENV PORT=` line — Knative injects `PORT=8080` to match the container
port, and Nitro/Next/SvelteKit read it. Make sure the server binds `0.0.0.0`
(Nitro and SvelteKit do by default; Next.js may need `HOSTNAME=0.0.0.0`, set
through the env map as above). The live path is the same as static: it builds the
app, copies the self-contained output (`.output`) into the Node image, pushes,
applies, waits, records a release, and prints `Deployed server site: <url>`.

---

## Git-triggered deploys (webhooks)

> **Status:** 🟡 **Implemented (`nagared`); in-cluster GitHub round-trip is
> operator setup.** See [`cluster/bootstrap/nagared/README.md`](../../cluster/bootstrap/nagared/README.md).

`nagared` is a small webhook service that deploys automatically from GitHub:

- a push to the configured **production branch** → production deploy + release;
- a pull request `opened`/`synchronize`/`reopened` → preview deploy named `pr-<number>`.

It verifies the GitHub `X-Hub-Signature-256` HMAC-SHA256 signature (an unsigned or
mis-signed request is rejected with 401 before anything runs), checks out the
named commit, and drives the **same** deploy path as the CLI — there is no second
deploy engine. Configure the GitHub webhook with:

- **Payload URL**: `https://hooks.<base-domain>/webhooks/github/static/<site>`
- **Content type**: `application/json`
- **Secret**: the value in the `nagared` Kubernetes Secret
- **Events**: push (production) and pull requests (previews)

`nagared`'s deploy path shells out to `docker`, `git`, and `kubectl` and loads the
typed config with `runghc`, so its image must provide those; on a single-node box
it is often simplest to run it on the host. The manifests in
`cluster/bootstrap/nagared/` are the starting point.

---

## CLI reference

```text
nagarectl site deploy [--dry-run] [--skip-build] [--file FILE] [--tag TAG]
                      [--base-domain DOMAIN] [--project-dir DIR] [--source REF]
                      [--ghc-env FILE]
nagarectl site releases
nagarectl site rollback RELEASE_ID
nagarectl site preview deploy --name NAME [build options as above]
nagarectl site preview list
nagarectl site preview delete NAME
```

`--file` defaults to `nagare/Config.hs`. `--tag` defaults to a UTC timestamp
`YYYYMMDD-HHMMSS`. `--base-domain` defaults to `NAGARE_BASE_DOMAIN`, then
`apps.example.com`. `--project-dir` (default `.`) is where the build runs and the
output directory is resolved. `--source` records provenance (e.g. a git SHA) with
the release.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `config emitted a '<none>' but 'StaticSite or ServerSite' was expected` | The config calls `emitDeployment` (an app, not a site). Use `nagarectl deploy`, or switch the config to `emitStaticSite` / `emitServerSite`. |
| `field '…' failed validation: …` | A smart constructor rejected a value (bad name, absolute path, bad redirect status, header name with a colon). Fix the config; the message names the field. |
| `static output directory not found after build: …` | The build did not produce the configured directory. Check the build command and `outputDirectory` (static) / `outputDirs` (server). |
| `runghc` cannot find `nagare-dsl` | Pass `--ghc-env /path/to/.ghc.environment.<arch>-<ghc>` (or set `NAGARE_GHC_ENVIRONMENT`), as with `nagarectl deploy`. |
| Server app returns 502 / never ready | The framework must bind `0.0.0.0` and read `PORT`. Set `HOSTNAME=0.0.0.0` in `env` for Next.js. |

Custom domains and TLS follow the cluster's wildcard DNS + cert-manager wiring;
see [Cluster bootstrap](cluster-bootstrap.md). Until `nagare-01` is up and the
base domain is real, the `apps.example.com` URLs above are placeholders.

---

## How it maps to the implementation

Designed and built under
[MasterPlan 3 — Static Hosting for Nagare](../masterplans/3-static-hosting-for-nagare.md)
(child plans EP-13 … EP-18). The typed model and renderers live in
`cli/nagare-dsl/` (`Nagare.Dsl.Static.*`, `Nagare.Dsl.Server.*`); the CLI and
webhook runner live in `cli/nagarectl/` (`Nagare.Static.*`, `Nagare.Server.*`,
the `nagarectl` and `nagared` executables).
