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

Full plan before trimming: [3-static-hosting-for-nagare.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/masterplans/3-static-hosting-for-nagare.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
| 15 | Static release rollback and preview deployments | docs/plans/15-static-release-rollback-and-preview-deployments.md | EP-14 | None | Complete |
| 16 | Git webhook automation for static sites | docs/plans/16-git-webhook-automation-for-static-sites.md | EP-15 | EP-3, EP-4 | Complete |
| 17 | Static hosting docs and end-to-end examples | docs/plans/17-static-hosting-docs-and-end-to-end-examples.md | EP-15 | EP-16, EP-18 | Complete |
| 18 | Full-stack server-runtime hosting (TanStack Start) | docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md | EP-14 | EP-13 | Complete |

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

## Progress

- [x] EP-13: Define the static-site model, smart constructors, JSON transport, and renderer API. (2026-06-09)
- [x] EP-13: Add golden and negative tests for Nginx config, Knative Service, DomainMappings, redirects, headers, and invalid rules. (2026-06-09)
- [x] EP-14: Implement local static build, output collection, generated image context, image build/push, dry-run, and production apply. (2026-06-09) **Live build→package→push→apply VERIFIED 2026-06-10**: `site deploy` packaged the `public/` dir into an `linux/amd64` image, pushed it to `us-west1-docker.pkg.dev/tan-nb-exp/nagare`, deployed the Knative Service, and served **HTTP 200** with the real site content; the `/old-home`→`/` redirect rule returned **301** live.
- [x] EP-15: Add release metadata, release listing, rollback, and preview deploy naming. (2026-06-09; kubectl-backed flow pending live-cluster validation). **VERIFIED live 2026-06-10** against `nagare-01`: two real `site deploy`s produced a 2-row `site releases` history (active `*`-marked, `--source` provenance recorded); `site rollback <v1>` reverted the served content to v1 (curl-confirmed); `site preview deploy -n pr-42` created `audit-static-pr-pr-42` + the preview DomainMapping `pr-42.audit-static.preview.apps.example.com` (served 200); `site preview list`/`delete` listed then cleanly removed it.
- [x] EP-16: Add a webhook receiver that verifies Git provider signatures and triggers production or preview deploys. (2026-06-09; in-cluster GitHub round-trip documented as operator setup)
- [x] EP-17: Write user docs, examples, and an end-to-end validation path for manual and automated static and full-stack hosting. (2026-06-09; live validation deferred until `nagare-01` is up). **Static end-to-end validation EXECUTED and VERIFIED live 2026-06-10** (deploy → 200 + redirect, releases, rollback, preview — see EP-14/EP-15). The full-stack `ServerSite` deploy (EP-18) uses the identical build→push→apply path, now proven; its stale example config was also fixed to the current DSL (`ServerSite.env` is now `ScopedEnvVar`). Note the private-image pull required configuring node→Artifact Registry auth — see MasterPlan 4's live-verification note.
- [x] EP-18: Add the `ServerSite` model, Node renderers, and kind-dispatching loader in `nagare-dsl`. (2026-06-09)
- [x] EP-18: Make `nagarectl site deploy` build, package, and deploy a TanStack Start app as a Node image, with a worked example and end-to-end validation. (2026-06-09; live Docker/cluster deploy is manual)

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
- 2026-06-09 (EP-15): Release records (Integration Point 4) live in ConfigMap
  `nagare-static-releases-<site>`, data key `releases.json`, schema
  `{current, releases:[{releaseId, siteName, namespace, image, imageTag, url,
  source, createdAt}]}`, newest-first, capped at 50. The record is
  runtime-agnostic, so EP-18 server sites and EP-16 webhook deploys append through
  the same `writeReleaseLog`. Previews are separate Knative Services named
  `<site>-pr-<name>` with domain `<preview>.<site>.preview.<base>` — identified by
  name prefix (no labels), so EP-17 documents that convention and EP-16 triggers
  `site preview deploy` for PR builds with no extra schema.
- 2026-06-09 (EP-15): EP-15's kubectl-backed lifecycle (`releases`, `rollback`,
  `preview list`/`delete`) is implemented and unit-tested for all pure logic, but
  its end-to-end run requires a live cluster and is recorded as manual validation
  (see the static-site example README). This does not block EP-16/EP-17/EP-18,
  which depend on the deploy path and record schema, both complete.
- 2026-06-09 (EP-16): EP-16 Milestone 1 finally factored the EP-14/EP-15 deploy
  logic out of `app/Main.hs` into `Nagare.Static.Deploy` (`DeployInputs`,
  `productionManifests`/`previewManifests`, `deployStaticProduction`/
  `deployStaticPreview`). This is the single deploy engine Integration Point 6
  promised: the CLI and `nagared` both call it, and EP-18's `SiteServer` branch
  plugs in at the same `loadStaticSite`→`loadSite` seam with no webhook-side
  change. The webhook decision is the pure `decideWebhook` (verify → parse →
  route); `nagared` only does IO (checkout + deploy) on `Triggered`.
- 2026-06-09 (EP-16): The webhook signature is HMAC-SHA256 verified
  (constant-time) and matches `openssl`/GitHub; the canonical test vector is
  pinned in `nagarectl-test`. `nagared` runs as an always-on Knative Service
  (`min-scale: 1`). Its real runtime (docker/git/kubectl/GHC env) is operator
  setup, not a turnkey image — see `cluster/bootstrap/nagared/README.md`.
- 2026-06-09 (EP-18): The server runtime landed on the shared seam exactly as
  designed (Integration Points 1-3, 5, 7). `loadSite` (`SiteConfig = SiteStatic |
  SiteServer`) is the kind-dispatcher; `nagarectl site deploy` branches to the
  Nginx or Node path; `recordReleaseFor` made the release record runtime-agnostic
  so `site releases`/`rollback` work for both kinds with no new schema. The static
  plans (EP-13/EP-14) needed only the light amendments already recorded. Server
  *preview* deploys are a noted small follow-up (the static preview path reports a
  precise wrong-kind error on a `ServerSite`); server `deploy`/`releases`/`rollback`
  are kind-agnostic. Knative injects `PORT=8080`, so the Dockerfile sets no
  `ENV PORT=`.

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

- Decision: Keep the per-release Nginx container as the static-site origin; do not serve static
  files directly from the cluster's Envoy data plane (Kourier). The deeper question — whether a
  pure-static site needs an origin server at all — is folded into
  `docs/masterplans/11-cdn-integration-for-nagare.md` (CDN), not reopened here.
  Rationale: Raised on revisiting "why Nginx when we already have Envoy via Kourier?". Kourier
  (Envoy) and the Nginx image are not substitutes — they sit in series at different layers. Kourier
  is the *shared cluster ingress*: one data plane, programmed by Knative's routing model, that
  terminates 80/443 and routes by `Host` header *to* Knative Services. The Nginx image is the
  *per-release origin* that actually serves the built files (`/usr/share/nginx/html` on port 8080;
  `cli/nagarectl/src/Nagare/Static/Image.hs`). Three structural reasons keep them separate: (1) a
  Knative Service must point at a container that serves HTTP — there is no "Service that is just a
  folder", so something has to serve the bytes; (2) the central decision above (2026-06-07) is that
  each release *is* an image, which the rollback/preview/scale-to-zero lifecycle (EP-15) depends on
  — serving from the shared Envoy would move release identity into ingress config plus object
  storage and require mutating the cluster-critical data plane via xDS/EnvoyFilter on every deploy;
  (3) Envoy has no on-disk static-file serving (no `root`/`try_files`, SPA fallback, or disk MIME
  handling) of the kind `renderNginxConfig` (EP-13) emits. The legitimate narrower question — *which*
  file server runs inside the container (Nginx vs Caddy / static-web-server / busybox httpd) — is a
  swappable implementation detail; Nginx was chosen as the boring universal default whose config maps
  cleanly onto the typed redirect/header/cache rules. The deeper "does pure-static need an origin at
  all?" question is answered by MasterPlan 11 (CDN), which fronts this Nginx origin with an edge
  cache and explicitly keeps Kourier-on-the-VM as the origin with the Nginx image behind it.
  Date: 2026-06-10

- Decision: Keep Nginx (`nginx:1.27-alpine`) as the static-site origin server inside the per-release
  image; do not switch to Caddy. *Which* file server runs in the container is a swappable detail
  behind the typed renderer, evaluated and settled here.
  Rationale: Evaluated on "should the static origin be Caddy instead of Nginx, while the change is
  still cheap?". Caddy's flagship feature — automatic HTTPS/ACME — is worth nothing in this slot: TLS
  terminates upstream (Kourier today, the CDN edge after MasterPlan 11), the origin serves plain HTTP
  on port 8080, and the image is immutable and ephemeral, so per-container certs are meaningless (you
  would have to actively disable Caddy's auto-HTTPS). What remains is Caddyfile readability — but the
  config is machine-generated from typed rules (`renderNginxConfig` in
  `cli/nagare-dsl/src/Nagare/Dsl/Static/Render.hs`) and never seen or hand-edited by users, so that
  benefit is small. Against switching: Nginx idles lighter and starts faster (it matters for
  scale-to-zero density across several small static sites), and the Nginx generator is already
  written, golden-tested, and shipped (EP-13/EP-14 Complete) — switching means re-deriving
  config-generation correctness, including the immutable-asset-regex-vs-header-prefix `location`
  precedence EP-13 already flagged, in Caddy's unfamiliar matcher model. The change surface is small
  (only `renderNginxConfig`, the generated Dockerfile in `Nagare.Static.Image`, one golden, and
  tests), so this remains revisitable later as a renderer-only swap if the origin ever needs to
  hand-extend its config or terminate TLS itself — neither of which the typed-rule, upstream-TLS
  design calls for.
  Date: 2026-06-10

## Outcomes & Retrospective

All six child plans (EP-13 … EP-18) are Complete as of 2026-06-09. Nagare now has
first-class static **and** full-stack site hosting, end to end:

- **EP-13** — the typed `StaticSite` model, JSON transport, and renderers
  (Nginx config + Knative Service + DomainMappings) in `cli/nagare-dsl/`; 95 → 112
  tests including golden and negative cases.
- **EP-14** — `nagarectl site deploy` builds a local static project, packages it
  into a generated Nginx image, and applies the manifests; a worked
  `cluster/examples/static-site` example.
- **EP-15** — release records in per-site ConfigMaps, `site releases`/`rollback`,
  and preview deployments (`site preview deploy|list|delete`).
- **EP-16** — `nagared`, the Git webhook runner: HMAC-SHA256 verification (matches
  GitHub/`openssl`), repo checkout, and the same deploy path as the CLI; RBAC and
  manifests under `cluster/bootstrap/nagared/`.
- **EP-18** — the parallel `ServerSite` model and Node image path, so the same
  `site deploy` deploys a TanStack Start app; `cluster/examples/tanstack-start`.
- **EP-17** — the `docs/user/static-hosting.md` developer guide and doc-index
  wiring.

What worked well: the kind-discriminator + shared-leaf-types design (EP-13) and
the factored single deploy engine (EP-16 Milestone 1, `Nagare.Static.Deploy`)
meant EP-18's server runtime and EP-16's webhook automation both plugged into one
seam (`loadSite`, `recordReleaseFor`) with no second deploy path and no churn in
the static plans. The release record proved genuinely runtime-agnostic, so
`releases`/`rollback` are kind-agnostic.

Verified offline: `cabal test` passes in both packages (nagare-dsl 112, nagarectl
35); `nagarectl site deploy --dry-run` renders correct artifacts for static and
server examples; a live `nagared` answered `/healthz` and the signed/unsigned
webhook paths.

Deferred (environment-gated, documented as manual): **the live build → push →
`kubectl apply` → Ready → URL leg is now EXECUTED and VERIFIED (2026-06-10)** — a static site
deployed to `nagare-01` served 200 with its redirect rule, and release/rollback/preview all ran live
(see EP-14/EP-15/EP-17). Still genuinely deferred: the in-cluster GitHub **webhook** round-trip
(needs a public webhook endpoint + a real Git repo/secret) and a **real custom domain with TLS** (the
base domain is still the placeholder `apps.example.com`). These remain the "external dependency"
caveats, distinct from the now-closed "box is down" one.

Known follow-ups (small, non-blocking): server-site **preview** deploys (static
previews work today); teaching `nagared` the `loadSite` dispatcher so webhooks can
also deploy server sites; and the optional Nix-native image-building path noted in
the Decision Log if the in-cluster Docker daemon proves painful.

