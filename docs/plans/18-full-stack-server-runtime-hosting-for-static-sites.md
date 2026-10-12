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

Full plan before trimming: [18-full-stack-server-runtime-hosting-for-static-sites.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

