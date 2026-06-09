---
id: 3
slug: static-hosting-for-nagare
title: "Static Hosting for Nagare"
kind: master-plan
created_at: 2026-06-07T19:49:23Z
intention: "intention_01ktht1bdme019jxs38yjsebxq"
---

# Static Hosting for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan coordinates the addition of first-class static site hosting to Nagare — and, by extension,
first-class hosting for full-stack JavaScript applications such as TanStack Start. The goal is to
replace the common Cloudflare Pages workflow for personal projects while staying inside Nagare's
existing single-node architecture: one GCP Compute Engine VM, k3s, Knative Serving, Kourier ingress,
cert-manager TLS, Artifact Registry, and the Haskell `nagarectl` plus `nagare-dsl` toolchain. The
initiative does not make Nagare depend on Cloudflare or Coolify. It gives Nagare its own typed
configuration surface for both static sites and server-rendered web apps, a CLI pipeline that builds
and packages each, and the release lifecycle features that make hosting useful: immutable deploys,
rollbacks, preview deployments, custom domains, redirects, headers, and Git-triggered deploys.

Static hosting is the core of the initiative; full-stack server-runtime hosting is an additive
extension layered on the same platform. A static site is packaged as an Nginx image that serves a
folder of files; a full-stack site (the TanStack Start case) is packaged as a small Node.js image
that runs the framework's server build, doing server-side rendering, server functions, and API routes
at request time. Both are deployed as ordinary Knative Services through one `nagarectl site deploy`
command that auto-detects which runtime a project needs from its typed config.


## Vision & Scope

After this initiative is complete, a developer can put a typed `nagare/Config.hs` file next to a
static web project and run:

```bash
nagarectl site deploy
```

The command builds the project, collects the configured output directory, packages those files into
a small Nginx-based container image, pushes the image to Nagare's existing Artifact Registry, applies
a Knative Service and any DomainMappings, waits for readiness, records release metadata, and prints
the production URL. A developer can also run a preview deploy for a branch or pull request and get a
separate URL, list prior releases, roll back to a prior release, and configure redirects and headers
without hand-writing Kubernetes YAML or Nginx files.

The user-visible replacement target is the static-site portion of Cloudflare Pages plus its
full-stack story: Git or CLI deploys, framework build commands, static asset serving, server-side
rendering, custom domains, preview deployments, redirect rules, response header rules, immutable
releases, and rollbacks. What remains out of scope is the *edge* execution model specifically —
Workers/`workerd`-compatible JavaScript running at the CDN edge. Nagare runs the full-stack app as an
ordinary origin server (a Node.js process on Knative), which is the right model for a single-node
personal PaaS and covers the application logic developers actually write with TanStack Start, Next.js,
Nuxt, and SvelteKit. A later initiative may add path-based routing from a static site to one or more
dynamic services, but this plan limits itself to static and server-rendered hosting and the lifecycle
around both.

The full-stack runtime is kept *general*. TanStack Start is the reference and proof framework, but the
packaging path — run a build command, copy a self-contained server output directory into a Node image,
run a start command, expose one HTTP port — also fits Next.js standalone output, Nuxt and SolidStart
(also built on the Nitro server toolkit), and SvelteKit's Node adapter. The typed config carries
TanStack Start defaults so the common case needs almost no configuration.

The central architecture decision is that each release is represented as a container image deployed as
a normal Knative Service. For a static site that image serves the generated files with Nginx; for a
full-stack site it runs the framework's Node.js server build. This reuses the platform Nagare already
has instead of introducing host-level Caddy/Nginx on ports 80 and 443, which would conflict with
Kourier and k3s ServiceLB. It also makes releases immutable regardless of runtime: the deploy tag
names one exact image, and rollback is a patch back to a prior image tag. The server runtime fits
Knative especially well — a request-driven Node server is exactly what Knative's scale-to-zero model
is designed for.


## Decomposition Strategy

The initiative is decomposed by functional concern. The first work stream defines what a static site
is in the typed DSL and how that intent renders to Kubernetes and Nginx-compatible configuration.
The second work stream implements the CLI pipeline that turns source files into the immutable image
the renderer expects. The third work stream adds release records, rollback, and preview naming on top
of that deploy path. The fourth work stream adds Git webhook automation, because a Pages-like
workflow should not require a manual CLI deploy after every push. The fifth work stream writes the
user documentation and examples and performs the end-to-end validation that proves the whole workflow
hangs together.

Five child plans are enough to keep each outcome independently verifiable without making the
coordination document granular. Splitting redirects, headers, domains, and preview URL naming into
separate plans was rejected because all of those concepts are part of the same typed static-site
contract and renderer. Splitting image packaging from CLI deployment was rejected because neither is
useful alone: the packaging code must produce exactly the image shape the deploy code applies.
Creating a host-level static server plan was rejected because Kourier already owns public HTTP and
HTTPS on the Nagare VM; competing host-level ingress would create a second routing plane and undo the
existing cluster-native design.

A sixth work stream adds the full-stack server runtime. EP-18 introduces a parallel `ServerSite`
model and a Node image-packaging path so the same `nagarectl site deploy` command can run a
server-rendered app such as TanStack Start. It is a dedicated plan rather than a change folded into
the static model and pipeline (EP-13 and EP-14) because a server site is a genuinely different shape —
"build from source, then run the resulting Node server" — that carries no Nginx redirect/header/cache
concepts and instead carries runtime concerns (env, scale, resources) the static path does not need.
Keeping it separate keeps each typed contract small and leaves the already-scoped static plans intact;
EP-13 and EP-14 take only light amendments to expose the shared leaf types and the kind-dispatching
deploy command that EP-18 plugs into. The lifecycle, webhook, and documentation plans (EP-15, EP-16,
EP-17) are runtime-agnostic: a release is an image tag, a rollback is a tag patch, and a webhook
triggers the same deploy path regardless of which runtime the project uses.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 13 | Typed static site model and renderer | docs/plans/13-typed-static-site-model-and-renderer.md | None | EP-12 | Complete |
| 14 | Static build packaging and deploy pipeline | docs/plans/14-static-build-packaging-and-deploy-pipeline.md | EP-13 | EP-12 | Complete |
| 15 | Static release rollback and preview deployments | docs/plans/15-static-release-rollback-and-preview-deployments.md | EP-14 | None | Not Started |
| 16 | Git webhook automation for static sites | docs/plans/16-git-webhook-automation-for-static-sites.md | EP-15 | EP-3, EP-4 | Not Started |
| 17 | Static hosting docs and end-to-end examples | docs/plans/17-static-hosting-docs-and-end-to-end-examples.md | EP-15 | EP-16, EP-18 | Not Started |
| 18 | Full-stack server-runtime hosting (TanStack Start) | docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md | EP-14 | EP-13 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps reference
child plans by their `EP-<#>` prefix, where the number is the file number in `docs/plans/`.
`EP-12` refers to `docs/plans/12-nagarectl-integration-and-full-yaml-cutover.md`, the existing plan
that integrated the typed Haskell deployment DSL into `nagarectl`.

Implementation waves:

- **Wave 1 - Static contract:** EP-13 defines `StaticSite`, the smart constructors, rule types,
  renderer interfaces, and tests.
- **Wave 2 - Manual deploy path:** EP-14 consumes EP-13 and makes `nagarectl site deploy` work for a
  local static project.
- **Wave 3 - Lifecycle:** EP-15 adds immutable release metadata, rollback, and preview deployments.
- **Wave 4 - Automation and proof:** EP-16 adds Git webhook deploys; EP-17 documents and validates
  the full workflow, with EP-16 as a soft dependency because the manual static hosting flow can be
  documented before webhook automation is complete.
- **Server runtime (parallel to Waves 3-4):** EP-18 adds the full-stack server runtime (TanStack
  Start) on top of EP-14's deploy pipeline. It hard-depends only on EP-14 and so can be implemented
  in parallel with EP-15/16, then folded into the lifecycle and documentation: EP-17 soft-depends on
  EP-18 so the full-stack flow is documented alongside the static flow.


## Dependency Graph

EP-13 has no hard dependency because it can be implemented in `cli/nagare-dsl/` as a library change
and tested offline. It soft-depends on EP-12 because it extends the typed config-as-program model
that EP-12 wired into `nagarectl`; its public API should match the existing modules
`Nagare.Dsl.Types`, `Nagare.Dsl.Config`, `Nagare.Dsl.Load`, and `Nagare.Dsl.Render`.

EP-14 hard-depends on EP-13 because the CLI cannot load or render a static site until the typed
static model exists. It soft-depends on EP-12 for the existing Haskell CLI patterns: `Options.Applicative`
subcommands in `cli/nagarectl/app/Main.hs`, image build/push helpers in `cli/nagarectl/src/Nagare/Image.hs`,
and `kubectl` apply/wait helpers in `cli/nagarectl/src/Nagare/Deploy.hs`.

EP-15 hard-depends on EP-14 because releases and previews are lifecycle features on top of a working
manual static deploy. Rollback needs prior deploy metadata and a known image-tagging scheme; preview
deployments need the same build and apply path with a different service name and domain.

EP-16 hard-depends on EP-15 because webhook automation must trigger the same production and preview
deploy behaviors that EP-15 defines. It soft-depends on EP-3 and EP-4 from
`docs/masterplans/1-bootstrap-nagare-personal-paas.md` because it adds a long-running Nagare service
inside the cluster and exposes it through the existing Knative/Kourier ingress.

EP-17 hard-depends on EP-15 because the documentation must describe deploy, release listing,
rollback, and previews. It soft-depends on EP-16 because webhook documentation and validation can be
added once automation exists, but the CLI-driven static hosting documentation is already valuable
after EP-15. It also soft-depends on EP-18 so the full-stack server-runtime workflow (TanStack Start)
is documented alongside the static workflow; the static documentation does not block on EP-18.

EP-18 hard-depends on EP-14 because it extends the same `nagarectl site deploy` pipeline — local
build, image-context generation, image build/push, manifest apply, and readiness wait — with a Node
runtime instead of an Nginx one. It soft-depends on EP-13 because it reuses EP-13's shared leaf types
(`SiteName`, `FilePathText`) and the `kind` discriminator convention, adding a `ServerSite` model
beside `StaticSite`. It does not depend on EP-15, EP-16, or EP-17: those plans are runtime-agnostic
and absorb the server runtime through the shared release record, deploy path, and docs without code
changes specific to EP-18.

Parallelism is limited until EP-13 completes because it defines the shared static-site contract. Once
EP-13 is complete, EP-14 is the next hard gate. After EP-14, three streams open in parallel: EP-15
(lifecycle) and EP-18 (server runtime) both build directly on EP-14, and once EP-15 lands EP-16 and
EP-17 follow. EP-17 can document the manual static flow and leave the webhook and full-stack chapters
pending while EP-16 and EP-18 implement automation and the server runtime respectively.


## Integration Points

**1. Static-site DSL types and JSON transport (defined by EP-13; consumed by EP-14, EP-15, EP-17).**
EP-13 owns the public static-site types in `cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs` and the
JSON transport shape emitted by `Nagare.Dsl.Config`. Later plans must not parse an app's
`nagare/Config.hs` themselves; they call the loader that EP-13 extends. The core type is
`StaticSite`, with smart constructors for static site names, output directories, build commands,
redirect rules, header rules, cache policies, and domain lists.

**2. Static rendering interfaces (defined by EP-13; consumed by EP-14 and EP-15).** EP-13 owns
renderers for the Kubernetes resources and generated Nginx configuration. The expected functions are
`renderStaticService :: StaticSite -> StaticDeployContext -> ByteString`,
`renderStaticDomainMappings :: StaticSite -> StaticDeployContext -> [ByteString]`, and
`renderNginxConfig :: StaticSite -> ByteString`. EP-14 writes the generated Nginx config into the
image build context; EP-15 uses the same renderers for preview deploys and rollback patches.

**3. Static image contract (defined by EP-14; consumed by EP-15 and EP-17).** EP-14 defines the image
shape used for every static site release: an Nginx-based image listening on port 8080, serving files
from `/usr/share/nginx/html`, with the generated config copied into Nginx's config directory. EP-15
records image tags as release ids and uses those tags for rollback. EP-17's examples and docs must
describe this image contract only at the user-visible level; users should not need to hand-write it.

**4. Release metadata (defined by EP-15; consumed by EP-16 and EP-17).** EP-15 owns the release record
schema and storage mechanism. The selected storage is a Kubernetes ConfigMap per static site, in the
application namespace, containing compact JSON release records keyed by deploy id. EP-16 appends
records when webhook-triggered deploys complete. EP-17 documents release listing and rollback using
this schema.

**5. Static CLI namespace (defined by EP-14; extended by EP-15 and EP-16).** The CLI surface is under
`nagarectl site ...`. EP-14 owns `nagarectl site deploy` and `nagarectl site dry-run` behavior. EP-15
adds `nagarectl site releases`, `nagarectl site rollback`, and `nagarectl site preview ...`. EP-16
adds webhook-related setup or status commands only if needed, and must not overload the existing
application `deploy` command.

**6. Git webhook service (defined by EP-16; documented by EP-17).** EP-16 owns any new long-running
service, its manifests, secrets, and webhook verification behavior. The service is named `nagared`
if no better existing daemon name emerges during implementation. It must trigger the same CLI/library
deployment path as manual static deploys rather than defining a second deployment engine. Because that
path is kind-dispatching (see point 7), the same webhook trigger deploys a static site or a full-stack
server site with no webhook-side branching.

**7. Server-site model, runtime, and Node image contract (defined by EP-18; consumed by EP-15, EP-17;
extends points 1, 2, 3, 5).** EP-18 owns the `ServerSite` type in
`cli/nagare-dsl/src/Nagare/Dsl/Server/Types.hs`, its `"kind":"ServerSite"` JSON transport, and the
renderers `renderServerDockerfile`, `renderServerService`, and `renderServerDomainMappings` in
`cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs`. The CLI deploy command from EP-14 dispatches on kind
through a `loadSite :: FilePath -> IO (Either LoadError SiteConfig)` loader (where
`SiteConfig = SiteStatic StaticSite | SiteServer ServerSite`) that EP-18 adds to `Nagare.Dsl.Load`;
EP-14's `nagarectl site deploy` calls it and runs the static path for `SiteStatic` and EP-18's Node
path for `SiteServer`. The server image contract parallels the static one (point 3): a Node base image
(default `node:22-alpine`) listening on container port 8080, with the framework's self-contained server
build copied into `/app` and started by the configured start command (default
`node .output/server/index.mjs` for TanStack Start); Knative injects `PORT=8080` so the server binds
the right port. EP-15's release records (point 4) store the image tag and runtime kind but are
otherwise unchanged, so release listing and rollback work identically for server sites. EP-17's docs
describe the server image only at the user-visible level; users never hand-write the Dockerfile.


## Progress

- [x] EP-13: Define the static-site model, smart constructors, JSON transport, and renderer API. (2026-06-09)
- [x] EP-13: Add golden and negative tests for Nginx config, Knative Service, DomainMappings, redirects, headers, and invalid rules. (2026-06-09)
- [x] EP-14: Implement local static build, output collection, generated image context, image build/push, dry-run, and production apply. (2026-06-09)
- [ ] EP-15: Add release metadata, release listing, rollback, and preview deploy naming.
- [ ] EP-16: Add a webhook receiver that verifies Git provider signatures and triggers production or preview deploys.
- [ ] EP-17: Write user docs, examples, and an end-to-end validation path for manual and automated static and full-stack hosting.
- [ ] EP-18: Add the `ServerSite` model, Node renderers, and kind-dispatching loader in `nagare-dsl`.
- [ ] EP-18: Make `nagarectl site deploy` build, package, and deploy a TanStack Start app as a Node image, with a worked example and end-to-end validation.


## Surprises & Discoveries

- 2026-06-09 (EP-13): The shared loader gained a dedicated
  `UnexpectedKind !Text !Text` constructor on `Nagare.Dsl.Load.LoadError`,
  distinct from `MarshalError`, so a config emitting the wrong `kind` fails
  precisely. This is the hook EP-18's kind-dispatching `loadSite` and EP-14's
  `nagarectl site deploy` rely on (Integration Points 1 and 7): the static path
  already rejects a `Deployment`-shaped or `ServerSite` config rather than
  misreading it. Backward compatible — `loadDeployment` is unchanged.
- 2026-06-09 (EP-13): `Nagare.Dsl.Static.Types` exposes more than the
  illustrative export list — notably `staticOutputDir`/`staticBuildCommand`
  (the directory to package and the optional build command) and
  `siteNameText`/`filePathText`. EP-14 should import these rather than
  re-pattern-matching `StaticBuild`. The renderer's `StaticDeployContext` already
  carries `previewName`, wired for EP-15's preview deploys but passed `Nothing`
  on the production path.
- 2026-06-09 (EP-14): `cradle`, the process library every `nagarectl` shell-out
  uses, requires GHC's threaded runtime. The executable lacked `-threaded`, so a
  real `nagarectl deploy` (not just `--dry-run`) would have thrown before this
  plan. Added `-threaded` to the `nagarectl` common ghc-options — this also
  un-breaks the pre-existing app `deploy` path, not just the new `site deploy`.
- 2026-06-09 (EP-14): `Nagare.Image.taggedImageRef :: ImageRef -> Text -> Text`
  is the runtime-agnostic image-ref helper (Integration Point 3); EP-18's Node
  path and EP-15's rollback both use it. The kind-dispatch seam in
  `runSiteDeploy` (currently `loadStaticSite`) is where EP-18 plugs in `loadSite`,
  and `withStaticImageContext` is the static sibling of EP-18's future Node
  image-context generator.


## Decision Log

- Decision: Use containerized static hosting through Knative rather than a host-level Caddy or Nginx
  server.
  Rationale: Nagare already routes public HTTP/HTTPS through Kourier and Knative. A host-level
  server would compete for ports 80/443 and introduce a second routing plane. Containerized static
  releases reuse the existing Artifact Registry, Knative readiness, DomainMapping, observability,
  and `kubectl` deployment patterns.
  Date: 2026-06-07

- Decision: Treat Pages Functions and Workers-compatible JavaScript as out of scope for this
  initiative.
  Rationale: Static hosting, previews, domains, redirects, headers, rollbacks, and Git-triggered
  deploys are already a large useful replacement for the static portion of Cloudflare Pages. Worker
  compatibility would require a separate runtime decision such as `workerd` and should not block the
  static hosting path.
  Date: 2026-06-07

- Decision: Store release metadata in Kubernetes ConfigMaps at first.
  Rationale: ConfigMaps require no new database, are easy to inspect with `kubectl`, fit the
  single-node personal PaaS scope, and can be backed up by the existing cluster backup strategy. If
  release history grows beyond ConfigMap limits, a later plan can move it to a small control-plane
  database without changing the user-facing CLI.
  Date: 2026-06-07

- Decision: Keep the child plan count to five and make Git webhooks a separate plan.
  Rationale: Manual CLI deploy is independently valuable and should be finished before the more
  operationally sensitive webhook service. Separating webhooks also lets the static DSL and CLI land
  without requiring Git provider secrets or a public control endpoint.
  Date: 2026-06-07

- Decision: Extend the initiative to host full-stack JavaScript apps (TanStack Start) as a sixth child
  plan, EP-18, rather than fold the change into the static model and pipeline (EP-13, EP-14).
  Rationale: A server-rendered app is a genuinely different shape — "build from source, then run the
  resulting Node server" — carrying runtime concerns (env, scale, resources) but none of the
  Nginx redirect/header/cache concepts of a static site. A dedicated `ServerSite` model keeps each
  typed contract small and unrepresentable-when-illegal, and leaves the already-scoped static plans
  intact with only light amendments (shared leaf types and a kind-dispatching deploy command). EP-18
  hard-depends only on EP-14, so it parallelizes with the lifecycle and webhook work.
  Date: 2026-06-09

- Decision: Make the server runtime a general Node/Nitro adapter with TanStack Start defaults rather
  than a TanStack-Start-specific path.
  Rationale: TanStack Start's production output is a self-contained Node server directory started by a
  single command — the same shape as Next.js standalone, Nuxt, SolidStart, and SvelteKit's Node
  adapter. Exposing the build command, output directory, start command, and base image as typed config
  with TanStack Start defaults covers the common case with near-zero configuration while keeping the
  other frameworks expressible. Workers/`workerd` edge execution stays out of scope; Nagare runs the
  app as an ordinary origin server, which fits a single-node PaaS.
  Date: 2026-06-09

- Decision: Deploy static and full-stack sites through one kind-dispatching `nagarectl site deploy`
  command rather than a separate `app deploy`.
  Rationale: "Deploy my web project from source" is one user action; whether the project is static or
  server-rendered is a property of the project already encoded in its typed config. Auto-detecting the
  runtime keeps the CLI surface small and means the webhook automation (EP-16) triggers either runtime
  with no branching of its own.
  Date: 2026-06-09

- Decision: Assemble release images with a generated Dockerfile and `docker build`, not Nix-native
  image building (`dockerTools` / `nix2container`), for both runtimes.
  Rationale: Considered making image assembly Nix-native to fit the NixOS host and to give EP-16's
  in-cluster webhook runner a daemonless build. Chose `docker build` for simplicity and universality:
  it is the path every developer understands, it is what EP-14 and EP-18 already specify, and the JS
  build itself stays framework-native (`npm run build`) either way. The Nix-native option was not
  rejected on technical merit — if EP-16's in-cluster build proves painful with a Docker daemon, image
  assembly can be revisited as a packaging-only amendment to EP-14 and EP-18 without touching the
  decomposition, the typed model, or the dependency graph.
  Date: 2026-06-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Notes

- 2026-06-09: Extended the initiative from static-only hosting to also host full-stack JavaScript apps
  such as TanStack Start, per a request to "support something like tanstack start." Added child plan
  EP-18 (`docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md`), a general
  Node/Nitro server runtime with TanStack Start defaults deployed through a kind-dispatching
  `nagarectl site deploy`. Updated the intro, Vision & Scope, Decomposition Strategy, Exec-Plan
  Registry (added EP-18; EP-17 now soft-depends on EP-18), Dependency Graph, Integration Points (new
  point 7; amended point 6), Progress, and Decision Log. Lightly amended EP-13 (shared leaf types and
  open `kind` discriminator) and EP-14 (kind-dispatching `site deploy`, factored image-context helper)
  with revision notes of their own. The static plans' scope and tests are unchanged. A related question
  raised in the same session — whether image building should be Nix-native — was resolved in favor of
  generated Dockerfile + `docker build` (see Decision Log, 2026-06-09); the JS build stays
  framework-native regardless.
