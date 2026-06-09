---
id: 18
slug: full-stack-server-runtime-hosting-for-static-sites
title: "Full-stack server-runtime hosting for static sites"
kind: exec-plan
created_at: 2026-06-09T22:21:54Z
intention: "intention_01ktht1bdme019jxs38yjsebxq"
master_plan: "docs/masterplans/3-static-hosting-for-nagare.md"
---

# Full-stack server-runtime hosting for static sites

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan is complete, Nagare can host a full-stack JavaScript web application — the kind built
with TanStack Start — not just a directory of pre-built static files. A developer can put a typed
`nagare/Config.hs` next to a TanStack Start project, run `nagarectl site deploy`, and get a running
server that renders pages on the server (server-side rendering, "SSR"), executes server functions and
API routes, and still serves the project's static client assets. The same command that already deploys
a purely static site (see `docs/plans/14-static-build-packaging-and-deploy-pipeline.md`) now also
deploys a server-rendered application, choosing the right runtime automatically from the typed config.

The concrete user-visible change is this. Before this plan, `nagarectl site deploy` only knew how to
package a folder of files behind an Nginx web server (Nginx is a program that serves files over HTTP).
That works for output from Vite, Astro, or Hugo, but it cannot run TanStack Start, because TanStack
Start's production build is not a folder of static files — it is a small Node.js server program that
must be running to answer each request. After this plan, the developer writes a config that describes
a *server site* instead of a *static site*, and `nagarectl site deploy` builds the app, packages its
server output into a small Node.js container image, deploys that image as a normal Knative Service
(the same request-driven service model Nagare already uses for ordinary apps), and prints the
production URL.

The proof is a worked example under `cluster/examples/tanstack-start/`: a minimal TanStack Start app
with a `nagare/Config.hs` that emits a server site. Running `nagarectl site deploy --dry-run` in that
directory prints the generated Dockerfile (the recipe for the container image), the generated Knative
Service manifest with the Node image and container port 8080, any custom DomainMapping manifests, and
the URL that would be deployed. On a machine with Docker and cluster access, the non-dry-run path
builds and pushes the image, applies the manifests, waits for the Knative Service to become Ready, and
prints `Deployed server site: <url>`, after which visiting that URL returns server-rendered HTML.

The runtime added here is deliberately *general*, not TanStack-Start-specific. TanStack Start is the
reference and proof case, but the same packaging path — "run a build command, copy a self-contained
server output directory into a Node image, run a start command, expose one HTTP port" — also fits
Next.js (`next build` with `output: 'standalone'`), Nuxt and SolidStart (which, like TanStack Start,
build on the Nitro server toolkit), and SvelteKit's Node adapter. The typed config exposes the build
command, the output directory to copy, the start command, and the base image, all with TanStack Start
defaults, so the common case needs almost no configuration while other Node frameworks remain
expressible.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Add `Nagare.Dsl.Server.Types` with the `ServerSite` model, `ServerBuild`, `ServerRuntime`, and validating smart constructors, reusing shared types from `Nagare.Dsl.Static.Types` and `Nagare.Dsl.Types`. (2026-06-09: incl. `RuntimeImage`, `defaultServerRuntime`, `tanstackStartBuild`; `NonEmpty` outputDirs/startCommand.)
- [x] Add `emitServerSite` to `Nagare.Dsl.Config` and `loadServerSite`/`decodeServerSite` plus a kind-dispatching `loadSite` to `Nagare.Dsl.Load`, keeping `loadStaticSite` and `loadDeployment` unchanged. (2026-06-09: `SiteConfig = SiteStatic | SiteServer`.)
- [x] Add `Nagare.Dsl.Server.Render` with `renderServerService`, `renderServerDomainMappings`, and `renderServerDockerfile`. (2026-06-09)
- [x] Add positive fixtures and golden tests for a server site with env, scale, resources, a custom domain, and the default TanStack Start runtime. (2026-06-09: `test/fixtures/server-site/` + 3 goldens; loads via `loadServerSite` and `loadSite`.)
- [x] Add negative tests for invalid output directories, empty start command, invalid base image, and wrong emitted kind. (2026-06-09: `ServerSpec.hs` decode-failure cases + `mkRuntimeImage` tests.)
- [x] Make `nagarectl site deploy` dispatch on config kind: static path (existing) vs. server path (new), sharing options and image/deploy helpers. (2026-06-09: `runSiteDeploy` calls `loadSite`; `deployStatic`/`deployServer`.)
- [x] Implement `Nagare.Server.Build`/`Nagare.Server.Image` for server build execution and Node image-context generation, reusing image tagging/build/push helpers. (2026-06-09: + `Nagare.Server.Deploy` for the effect.)
- [x] Implement server dry-run output and non-dry-run build, push, `kubectl apply`, wait, and URL printing. (2026-06-09: dry-run prints Dockerfile + Service + DomainMappings + URL + Release; non-dry-run records a release and prints `Deployed server site:`.)
- [x] Add the `cluster/examples/tanstack-start/` example and end-to-end manual validation notes. (2026-06-09: example + README; live build/deploy is manual since it needs npm + Docker + cluster.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-09: The kind-dispatch seam EP-14/EP-16 left (`runSiteDeploy` calling
  `loadStaticSite`, the factored `Nagare.Static.Deploy`) made plugging in the
  server path a small change: `runSiteDeploy` now calls `Load.loadSite` and
  branches to `deployStatic`/`deployServer`. The webhook runner (`nagared`)
  needs no change — it drives `Nagare.Static.Deploy`; a follow-up can teach it
  `loadSite` to also deploy server sites from webhooks.
- 2026-06-09: The release record is genuinely runtime-agnostic. Factoring
  `recordReleaseFor :: image -> tag -> url -> name -> ns -> source -> IO (Either Text ())`
  into `Nagare.Static.Release` let the server deploy record releases through the
  same ConfigMap, and made `site releases` and `site rollback` kind-agnostic
  (both load via `loadSite` and dispatch the renderer). So server sites list and
  roll back with no new schema, exactly as the MasterPlan predicted.
- 2026-06-09: `Nagare.Server.Build.PreparedServerOutput` records each output as a
  `(relativePath, absolutePath)` pair, not just the absolute path, so
  `Nagare.Server.Image.withServerImageContext` can recreate the relative layout
  under `app/` (`.output` → `app/.output`). This is the one structural difference
  from the static image context (which copies a single dir's contents to `site/`).
- 2026-06-09 (scope note): server *preview* deploys are not yet wired — `site
  preview deploy|list|delete` still load the static config and report a precise
  wrong-kind error on a `ServerSite`. Server `deploy`, `releases`, and `rollback`
  are kind-agnostic. Server previews are a small follow-up (a `previewServerManifests`
  beside the static one); they are out of this plan's stated Milestone-2 scope,
  which is the server `site deploy` path.


## Decision Log

Record every decision made while working on the plan.

- Decision: Model server hosting as a new top-level `ServerSite` value in a new module
  `Nagare.Dsl.Server.Types`, parallel to EP-13's `StaticSite`, rather than adding a runtime
  discriminator inside `StaticSite` or overloading the existing `Deployment` type.
  Rationale: `StaticSite` means "a folder of files served by Nginx" and carries Nginx-only concepts
  (redirect rules, header rules, cache policy, 404 page) that have no meaning for a server that does
  its own routing. `Deployment` means "run this prebuilt image" and has no build step. A server site
  is "build from source, then run the resulting Node image," which is genuinely a third shape. A
  separate type keeps each API small and keeps illegal combinations (Nginx cache policy on an SSR
  app) unrepresentable. The three share leaf types (`SiteName`, `Domain`, `Port`, `EnvVar`,
  `Resources`, `Scale`) so there is no duplication of validation logic.
  Date: 2026-06-09

- Decision: Build the application on the developer's machine (or webhook runner) and copy only the
  framework's self-contained server output into a minimal Node runtime image, instead of building
  inside a multi-stage Dockerfile.
  Rationale: This mirrors exactly the static pipeline in
  `docs/plans/14-static-build-packaging-and-deploy-pipeline.md`, which runs the build locally and
  copies the output directory into the image. TanStack Start's production output (the `.output`
  directory produced by its Nitro server build) is self-contained: it bundles its own dependencies,
  so the runtime image needs only Node and that directory. Next.js `standalone` output and SvelteKit's
  Node adapter output are self-contained in the same way. Avoiding in-image builds keeps the runtime
  image small, keeps the Dockerfile single-stage and easy to read, and reuses EP-14's
  build-then-package machinery.
  Date: 2026-06-09

- Decision: Rely on Knative's automatic `PORT` environment variable injection rather than setting
  `PORT` ourselves in the rendered manifest.
  Rationale: Knative Serving injects a `PORT` environment variable into the user container set to the
  declared container port (8080 here), and treats `PORT` as reserved. TanStack Start's Nitro server,
  Next.js, and SvelteKit's Node adapter all read `PORT` to decide which port to listen on, so they
  bind to 8080 with no configuration. Setting `PORT` explicitly in the manifest risks a conflict with
  Knative's injection. The user-facing config therefore does not expose `PORT`; it exposes the
  container port, which defaults to 8080. We still document that the framework must bind the wildcard
  address `0.0.0.0` (Nitro and SvelteKit do by default; Next.js may need `HOSTNAME=0.0.0.0`, settable
  through the env map).
  Date: 2026-06-09

- Decision: Default a server site to scale-to-zero (Knative `minScale: 0`).
  Rationale: This is a single-node personal PaaS; idle apps should cost nothing. The tradeoff is a
  cold start on the first request after the app scales to zero. Users who want to avoid cold starts
  set `minScale: 1` through the same `Scale` smart constructor the existing `Deployment` model uses.
  The default and the override are both expressed in typed config, so the choice is explicit and
  validated.
  Date: 2026-06-09

- Decision: Keep one CLI command, `nagarectl site deploy`, and dispatch on the config's `kind`
  discriminator (static vs. server) rather than adding a separate `nagarectl app deploy`.
  Rationale: From the user's point of view "deploy my web project from source" is one action; whether
  the project is static or server-rendered is a property of the project, already encoded in the typed
  config. Cloudflare Pages, the replacement target, similarly covers both static output and
  server/edge functions behind one deploy. Auto-detection keeps the surface small and means the
  webhook automation in `docs/plans/16-git-webhook-automation-for-static-sites.md` does not need to
  know which kind of site it is triggering.
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed 2026-06-09 (offline DSL tests + dry-run validated; live build/deploy of
a real TanStack Start app is manual, needing npm + Docker + a cluster).

What exists now that did not before:

- `Nagare.Dsl.Server.Types` — `ServerSite`/`ServerBuild`/`ServerRuntime`/
  `RuntimeImage` with TanStack Start defaults, reusing `SiteName`/`FilePathText`
  and the core leaf types. `outputDirs`/`startCommand` are `NonEmpty`, so empty
  sets are unrepresentable.
- `Nagare.Dsl.Config.emitServerSite`, `Nagare.Dsl.Load.{loadServerSite,
  decodeServerSite, SiteConfig, loadSite}`, and `Nagare.Dsl.Server.Render`
  (`renderServerDockerfile`/`renderServerService`/`renderServerDomainMappings`).
- `Nagare.Server.{Build,Image,Deploy}` and the kind-dispatching `nagarectl site
  deploy` (static Nginx path vs. server Node path), plus kind-agnostic `releases`
  and `rollback`.
- The `cluster/examples/tanstack-start/` worked example.

Validation: `cabal test` in `cli/nagare-dsl/` passes all 112 tests (incl. the
server fixture round-trip through `loadServerSite` and `loadSite`, and the three
render goldens — Dockerfile with `EXPOSE 8080` and no `ENV PORT=`, Service on port
8080 with env/scale/resources, one DomainMapping per domain). `cabal test` in
`cli/nagarectl/` passes all 35 tests. `nagarectl site deploy --dry-run` on
`cluster/examples/tanstack-start` prints the Dockerfile, the Node Service, the
URL, and the release id; the existing app `deploy` and static `site deploy` paths
are unchanged; a `Deployment`-shaped config under `site deploy` fails with a
precise "StaticSite or ServerSite expected" error.

Gaps: server preview deploys are a noted follow-up (see Surprises). The live
non-dry-run path (real `npm run build`, Docker build/push, cluster apply, `curl`
of server-rendered HTML) is documented in the example README and requires a
machine with the JS toolchain, Docker, and cluster access.


## Context and Orientation

This plan extends Nagare's static-hosting work to run server-rendered JavaScript applications. The
reader needs to understand three existing pieces of the repository and one external framework.

The typed configuration language lives in `cli/nagare-dsl/`. Its modules are
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs` (the `Deployment` model and shared leaf types such as
`ServiceName`, `Namespace`, `ImageRef`, `Port`, `EnvName`, `EnvVar`, `Resources`, `Scale`, and
`Domain`, each with a validating `mkX :: ... -> Either Text X` smart constructor and a hidden data
constructor), `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` (emit helpers used by an app's
`nagare/Config.hs`), `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` (runs a config with `runghc`, captures
its JSON output, and decodes it back into a validated value), and `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`
(renders a `Deployment` to Knative Service and DomainMapping YAML). "Knative Service" is a Kubernetes
resource that runs a container image as a request-driven web service that can scale to zero pods when
idle; "DomainMapping" is the Knative resource that attaches a custom hostname to such a service.

The static-site contract this plan builds on is defined by
`docs/plans/13-typed-static-site-model-and-renderer.md` (EP-13). That plan adds
`cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs` with a `StaticSite` type and reusable leaf types this
plan also needs: `SiteName` (a DNS-label name with the same rules as `ServiceName`), `FilePathText`
(a relative path that rejects empty strings, absolute paths, `..` segments, and NUL characters, built
with `mkFilePathText`), and the `StaticBuild` shape (`NoBuild FilePathText` or
`BuildCommand { command :: Text, outputDirectory :: FilePathText }`). EP-13 also establishes that an
emitted config carries a top-level JSON discriminator field `kind` (for example `"kind":"StaticSite"`)
so the loader can tell what was emitted and report a precise error if the wrong kind is deployed. This
plan adds a new `kind` value, `"ServerSite"`, and must reuse `SiteName` and `FilePathText` from
`Nagare.Dsl.Static.Types` rather than redefining them.

The deploy pipeline this plan extends is defined by
`docs/plans/14-static-build-packaging-and-deploy-pipeline.md` (EP-14). That plan adds the
`nagarectl site deploy` command in `cli/nagarectl/app/Main.hs`, a local build step
(`prepareStaticOutput`), temporary image-context generation that writes a generated Dockerfile and
copies output files, and reuse of the image helpers in `cli/nagarectl/src/Nagare/Image.hs`
(`computeTag`, `configureDockerAuth`, `buildImage`, `pushImage`, and an image-ref helper) and the
cluster helpers in `cli/nagarectl/src/Nagare/Deploy.hs` (`applyManifests`, `waitForReady`). The static
deploy options EP-14 defines are `--file`, `--tag`, `--base-domain`, `--ghc-env`, `--dry-run`, and
`--skip-build`. This plan reuses all of those options unchanged and adds no new ones; the server path
is selected by the config's kind, not by a flag.

The external framework, TanStack Start, is a full-stack React framework. "Full-stack" means a single
project contains both the browser UI and server-side logic; "SSR" (server-side rendering) means the
server produces the initial HTML for each page instead of shipping an empty page that the browser
fills in. TanStack Start is built on Vite (a build tool) and Nitro (a server toolkit). Running its
production build — typically `npm run build` — produces a directory named `.output` containing
`.output/server/index.mjs` (the server program to run with `node`) and `.output/public` (static client
assets the server itself serves). The server is started with `node .output/server/index.mjs` and, like
all Nitro servers, reads the `PORT` environment variable to decide which port to listen on and binds
the wildcard address `0.0.0.0` by default. This is exactly the shape this plan packages: a build
command, a self-contained output directory to copy, and a start command. Because Next.js standalone
output (`node .next/standalone/server.js`), Nuxt/SolidStart (also Nitro-based), and SvelteKit's Node
adapter (`node build`) follow the same shape, the model is kept general with TanStack Start defaults.

A note on Knative and ports: Knative injects the `PORT` environment variable into the running
container, set to the declared container port. So if the manifest declares container port 8080, the
Nitro server sees `PORT=8080` and listens there with no extra configuration. This plan therefore
declares container port 8080 and does not set `PORT` itself (Knative reserves it).


## Plan of Work

The work splits into two milestones that mirror EP-13 and EP-14: first the typed model and renderers
in `cli/nagare-dsl/`, validated entirely offline by `cabal test`; then the CLI deploy path in
`cli/nagarectl/`, validated by a dry run against a real example and, where Docker and a cluster are
available, by a live deploy. A short third milestone adds the worked TanStack Start example and the
end-to-end validation narrative.

### Milestone 1 — The typed server-site model and renderers

At the end of this milestone, `cli/nagare-dsl/` can describe a server site in typed config, load it
back from emitted JSON, and render the three artifacts a deploy needs (a Dockerfile, a Knative
Service, and DomainMappings), all proven by `cabal test` with golden files. Nothing is built or
deployed yet.

Create `cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs` and expose it from
`cli/nagare-dsl/nagare-dsl.cabal`. Follow the style in `Nagare.Dsl.Types`: hidden newtype constructors
where values need validation, `mkX :: ... -> Either Text X` smart constructors, strict record fields,
unprefixed field names, and `Nagare.Dsl.Prelude` imports. Reuse `SiteName` and `FilePathText` from
`Nagare.Dsl.Static.Types` (do not redefine them) and `Namespace`, `ImageRef`, `Port`, `defaultPort`,
`EnvName`, `EnvVar`, `Resources`, `Scale`, and `Domain` from `Nagare.Dsl.Types`. The model should be:

```haskell
data ServerSite = ServerSite
  { name :: SiteName
  , namespace :: Namespace
  , image :: ImageRef            -- registry repository for the built image (no tag)
  , build :: ServerBuild         -- how to produce the runtime output from source
  , runtime :: ServerRuntime     -- how to package and start that output
  , port :: Port                 -- container port Knative routes to; defaults to 8080
  , env :: Map EnvName EnvVar    -- runtime environment, e.g. HOSTNAME=0.0.0.0, API keys
  , resources :: Maybe Resources
  , scale :: Maybe Scale         -- Nothing means platform default (scale-to-zero)
  , domains :: [Domain]
  }

data ServerBuild = ServerBuild
  { command :: Text              -- e.g. "npm ci && npm run build"
  , outputDirs :: NonEmpty FilePathText  -- self-contained dirs to copy, e.g. [".output"]
  }

data ServerRuntime = ServerRuntime
  { baseImage :: RuntimeImage    -- e.g. node:22-alpine
  , startCommand :: NonEmpty Text  -- argv, e.g. ["node", ".output/server/index.mjs"]
  }
```

`RuntimeImage` should be a validated newtype (non-empty, no spaces, no URI scheme; a tag such as
`:22-alpine` is allowed because this is a base image reference, unlike `ImageRef` which forbids tags).
Provide TanStack Start defaults as named values so the common config is tiny: a `defaultServerRuntime`
equal to `ServerRuntime (node:22-alpine) ("node" :| [".output/server/index.mjs"])` and a
`tanstackStartBuild` equal to `ServerBuild "npm ci && npm run build" (".output" :| [])`. The build's
`outputDirs` reuse `FilePathText`, so absolute paths and `..` escapes are rejected at construction.
`startCommand` and `outputDirs` are `NonEmpty` so an empty start command or empty copy set cannot be
constructed.

Extend config emission and loading. In `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, add
`emitServerSite :: ServerSite -> IO ()` next to the existing `emitDeployment` and EP-13's
`emitStaticSite`, emitting JSON with `"kind":"ServerSite"`. Keep the other emit functions unchanged.
In `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, add `decodeServerSite :: ByteString -> Either LoadError ServerSite`
and `loadServerSite :: FilePath -> IO (Either LoadError ServerSite)`, mirroring EP-13's
`loadStaticSite`. Then add a single dispatching loader the CLI will use:

```haskell
data SiteConfig = SiteStatic StaticSite | SiteServer ServerSite

loadSite :: FilePath -> IO (Either LoadError SiteConfig)
```

`loadSite` runs the config once, reads the top-level `kind` field, and decodes into the matching
branch, returning a precise `LoadError` if `kind` is `"Deployment"` (tell the user to use
`nagarectl deploy`) or anything unrecognized. Do not change `loadDeployment` or `loadStaticSite`.

Create `cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs` exposing:

```haskell
data ServerDeployContext = ServerDeployContext
  { imageTag :: Text
  , previewName :: Maybe Text   -- reserved for EP-15 preview deploys; Nothing for production
  }

renderServerDockerfile :: ServerSite -> Text
renderServerService :: ServerSite -> ServerDeployContext -> ByteString
renderServerDomainMappings :: ServerSite -> ServerDeployContext -> [ByteString]
```

`renderServerDockerfile` produces a single-stage Dockerfile from the runtime: it starts from
`baseImage`, sets a working directory, copies the packaged app in, declares `EXPOSE 8080`, and sets
the `CMD` to the start command. With the defaults it renders:

```dockerfile
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY app/ ./
EXPOSE 8080
CMD ["node", ".output/server/index.mjs"]
```

where `app/` is the directory the deploy step fills with the copied `outputDirs`. Note there is no
`ENV PORT=` line — Knative injects `PORT=8080` to match the container port. `renderServerService`
renders a Knative Service that points at `imageRefText site.image <> ":" <> imageTag`, declares
container port `portInt site.port` (8080 by default), and includes the env map, resources, and scale.
This is close to the existing `Nagare.Dsl.Render.renderService` for `Deployment`; reuse its env,
resource, and scale rendering rather than duplicating YAML construction (factor a shared helper in
`Nagare.Dsl.Render` if needed, preserving the existing `renderService` API). `renderServerDomainMappings`
renders one DomainMapping per configured domain, identical in shape to EP-13's
`renderStaticDomainMappings`.

Add tests and fixtures. Add a fixture at
`cli/nagare-dsl/test/fixtures/server-site/nagare/Config.hs` that emits a server site using the
TanStack Start defaults, one custom domain, a couple of env vars (including `HOSTNAME=0.0.0.0`), a
`Scale` with `minScale: 1`, and a `Resources`. Add golden files under `cli/nagare-dsl/test/golden/`
for the Dockerfile, the Knative Service YAML (for image tag `20260607-120000`), and the DomainMapping
YAML. Extend `cli/nagare-dsl/test/Spec.hs` (or add `ServerSpec.hs`) so `cabal test` exercises: the
fixture loads through `loadServerSite` and through `loadSite` (returning `SiteServer`) and equals the
expected value; the three renderers match the golden files; and negative cases fail precisely —
absolute or `..` output dirs, empty start command (unconstructable, so test the smart-constructor or
JSON-decode rejection), invalid base image, and a static config decoded by `loadServerSite` (wrong
kind).

### Milestone 2 — The CLI server deploy path

At the end of this milestone, `nagarectl site deploy` deploys a server site. Run in a TanStack Start
project, `--dry-run` prints the generated Dockerfile, the Knative Service, the DomainMappings, and the
URL; the non-dry-run path builds and pushes a Node image and applies the manifests.

Make `site deploy` dispatch on kind. In `cli/nagarectl/app/Main.hs`, change the `site deploy` handler
(added by EP-14) to call `loadSite` instead of `loadStaticSite`. On `SiteStatic`, run the existing
static path unchanged. On `SiteServer`, run the new server path described below. Keep all existing
options; the server path interprets `--skip-build` as "the output directory already exists, skip the
build command," exactly as the static path does.

Implement server build execution. Create `cli/nagarectl/src/Nagare/Server/Build.hs` (or
`Nagare/Static/Server.hs` if colocating is cleaner) exposing:

```haskell
prepareServerOutput :: ServerSite -> FilePath -> IO PreparedServerOutput
```

The second argument is the project root. Unless `--skip-build` is set, run the build's `command` in
the project root through the same shell-exec helper the static build uses; fail clearly with the
command's exit code and captured output if it exits non-zero. Then validate that every directory in
`outputDirs` exists; fail with a precise message naming the missing directory if not (for the default
that message names `.output`). `PreparedServerOutput` records the absolute paths of the validated
output directories.

Implement Node image-context generation. In a sibling module `Nagare.Server.Image`, create a
temporary directory with `withSystemTempDirectory` containing a generated `Dockerfile` and an `app/`
directory. Write `Dockerfile` from `renderServerDockerfile`. Copy each prepared output directory into
`app/` preserving its name (so `.output` lands at `app/.output`, which is what the default start
command `node .output/server/index.mjs` expects relative to `WORKDIR /app`). Then reuse `computeTag`,
`configureDockerAuth`, `buildImage`, and `pushImage` from `cli/nagarectl/src/Nagare/Image.hs`, and the
tagged-image-ref helper, to build and push the image. If those helpers are too `Deployment`-specific,
add a general `taggedImageRef :: ImageRef -> Text -> Text` while preserving the old API, as EP-14 also
contemplates.

Wire the deploy. For `--dry-run`, print the generated Dockerfile, the `renderServerService` output,
the `renderServerDomainMappings` outputs, and the URL — and stop before any Docker or cluster side
effect. For the real path, after build and push, render the manifests, apply them with
`applyManifests`, wait with `waitForReady`, and print `Deployed server site: <url>`. The URL rule
matches the static path: the first configured custom domain if present; otherwise
`https://<site>.<namespace>.<baseDomain>`.

### Milestone 3 — The TanStack Start example and end-to-end validation

At the end of this milestone there is a runnable example proving the whole path. Add
`cluster/examples/tanstack-start/` containing a minimal TanStack Start application (a single route that
returns server-rendered HTML and one trivial server function or API route to prove server execution),
a `package.json` with a `build` script, a `nagare/Config.hs` that emits a `ServerSite` with the
TanStack Start defaults and one example env var, and a `README.md` describing how to deploy it. Record
the dry-run transcript in the README and in this plan's Validation section. Where Docker and the
cluster are available, perform a live deploy and capture the `kubectl get ksvc -n personal` line and a
`curl` of the deployed URL showing server-rendered HTML.


## Concrete Steps

Work from the repository root unless noted:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Inspect the patterns this plan reuses before editing:

```bash
sed -n '1,320p' cli/nagare-dsl/src/Nagare/Dsl/Types.hs
sed -n '1,260p' cli/nagare-dsl/src/Nagare/Dsl/Render.hs
sed -n '1,260p' cli/nagare-dsl/src/Nagare/Dsl/Load.hs
sed -n '1,280p' cli/nagarectl/app/Main.hs
sed -n '1,220p' cli/nagarectl/src/Nagare/Image.hs
```

After Milestone 1, build and test the DSL package:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test
```

Success means all existing deployment and static tests plus the new server tests pass. If a fixture's
`runghc` cannot find `nagare-dsl`, use the `NAGARE_GHC_ENVIRONMENT` / cabal package-environment pattern
documented in `docs/plans/10-config-surface-and-loading-for-the-chosen-substrate.md`, the same way
EP-13's fixtures do.

After Milestone 2, build and test the CLI package and run a dry run:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build
cabal test
cd /Users/shinzui/Keikaku/bokuno/nagare/cluster/examples/tanstack-start
npm ci && npm run build      # produces .output
nagarectl site deploy --dry-run --skip-build --ghc-env /path/to/ghc-environment
```

The expected dry-run output contains a Dockerfile block, a Knative Service manifest naming the server
image and container port 8080, any DomainMapping manifests, and the URL line. The exact `--ghc-env`
path depends on how the executable is run; follow the existing deployment docs for
`NAGARE_GHC_ENVIRONMENT` if `runghc` cannot find `nagare-dsl`.


## Validation and Acceptance

This plan is accepted when all of the following hold.

In `cli/nagare-dsl/`, `cabal test` proves: the server fixture config loads through `loadServerSite`
and through `loadSite` (as `SiteServer`) and equals the expected `ServerSite`; `renderServerDockerfile`
produces the expected single-stage Node Dockerfile with `EXPOSE 8080`, no `ENV PORT=` line, and the
configured start command; `renderServerService` produces deterministic Knative Service YAML for image
tag `20260607-120000` with container port 8080, the env map, resources, and scale; and
`renderServerDomainMappings` produces one DomainMapping per domain. Negative cases fail precisely:
absolute or parent-directory output dirs, invalid base image, and a static config fed to
`loadServerSite` all return precise `LoadError` or constructor errors.

The existing `nagarectl deploy` and the existing static `nagarectl site deploy --dry-run` paths still
work unchanged for their bundled examples — dispatch on kind must not regress them.

For `cluster/examples/tanstack-start`, `nagarectl site deploy --dry-run` prints a generated Dockerfile,
a Knative Service manifest with the server image and port 8080, any DomainMapping manifests, and the
URL that would be deployed.

On a machine with Docker and cluster access, the non-dry-run path builds the Node image, pushes it,
applies the manifests, waits for the Knative Service to become Ready, and prints
`Deployed server site: <url>`. A follow-up `kubectl get ksvc -n personal` shows the service Ready, and
`curl -s <url>` returns server-rendered HTML (the page's content present in the initial response body,
not an empty shell), and the example's server function or API route returns its expected response —
proving the server is executing, not just serving files.


## Idempotence and Recovery

Dry runs have no side effects. Non-dry-run deploys are safe to repeat: image tags are timestamped
unless `--tag` is given, and `kubectl apply` is declarative. Build the image context with
`withSystemTempDirectory` so a partial failure cleans up automatically. If the build command fails, no
image is built and no cluster resources are applied. If `docker push` succeeds but `kubectl apply`
fails, rerun with the same `--tag` to retry only the cluster leg without rebuilding. Re-running
`cabal test` is always safe; if a golden file changes, inspect the rendered output and decide whether
the contract genuinely changed before accepting the new golden.


## Interfaces and Dependencies

This plan depends on the interfaces EP-13 defines and reuses leaf types from the core DSL:

```haskell
-- from Nagare.Dsl.Static.Types (EP-13)
SiteName, FilePathText, mkFilePathText

-- from Nagare.Dsl.Types (existing)
Namespace, ImageRef, imageRefText, Port, defaultPort, portInt,
EnvName, EnvVar, Resources, Scale, Domain
```

It adds these public interfaces consumed by EP-14's CLI dispatch and by EP-15's lifecycle work:

```haskell
module Nagare.Dsl.Server.Types
  ( ServerSite(..)
  , ServerBuild(..)
  , ServerRuntime(..)
  , RuntimeImage, mkRuntimeImage, runtimeImageText
  , defaultServerRuntime
  , tanstackStartBuild
  ) where

module Nagare.Dsl.Config
  ( emitDeployment, emitStaticSite, emitServerSite ) where

module Nagare.Dsl.Load
  ( loadDeployment, loadStaticSite, loadServerSite
  , decodeServerSite
  , SiteConfig(..), loadSite ) where

module Nagare.Dsl.Server.Render
  ( ServerDeployContext(..)
  , renderServerDockerfile
  , renderServerService
  , renderServerDomainMappings ) where
```

It depends only on packages already used by `nagare-dsl` (`aeson`, `bytestring`, `containers`, `text`,
`yaml`) plus `NonEmpty` from `base`'s `Data.List.NonEmpty`. The CLI additions live under
`cli/nagarectl/src/Nagare/Server/` and are exposed in `cli/nagarectl/nagarectl.cabal` if tests import
them. External command dependencies are `docker`, `gcloud`, and `kubectl`, matching the existing deploy
commands. The deployed application additionally requires that the chosen base image contains Node and
that the framework binds `0.0.0.0` and reads `PORT` (TanStack Start's Nitro server does both by
default).
