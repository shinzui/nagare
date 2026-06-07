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

This plan coordinates the addition of first-class static site hosting to Nagare. The goal is to
replace the common Cloudflare Pages workflow for personal projects while staying inside Nagare's
existing single-node architecture: one GCP Compute Engine VM, k3s, Knative Serving, Kourier ingress,
cert-manager TLS, Artifact Registry, and the Haskell `nagarectl` plus `nagare-dsl` toolchain. The
initiative does not make Nagare depend on Cloudflare or Coolify. It gives Nagare its own typed
configuration surface for static sites, a CLI pipeline that builds and packages static assets, and
the release lifecycle features that make static hosting useful: immutable deploys, rollbacks,
preview deployments, custom domains, redirects, headers, and Git-triggered deploys.


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

The user-visible replacement target is the static-site portion of Cloudflare Pages: Git or CLI
deploys, framework build commands, static asset serving, custom domains, preview deployments,
redirect rules, response header rules, immutable releases, and rollbacks. Pages Functions and
Workers-compatible JavaScript execution are explicitly out of scope for this initiative. Dynamic
backends remain ordinary Nagare apps deployed through the existing Knative service model. A later
initiative may add path-based routing from a static site to one or more dynamic services, but this
plan limits itself to static hosting and the lifecycle around it.

The central architecture decision is that each static site release is represented as a container
image that serves the generated files with Nginx. That image is deployed as a normal Knative Service.
This reuses the platform Nagare already has instead of introducing host-level Caddy/Nginx on ports
80 and 443, which would conflict with Kourier and k3s ServiceLB. It also makes releases immutable:
the deploy tag names one exact asset set, and rollback is a patch back to a prior image tag.


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


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 13 | Typed static site model and renderer | docs/plans/13-typed-static-site-model-and-renderer.md | None | EP-12 | Not Started |
| 14 | Static build packaging and deploy pipeline | docs/plans/14-static-build-packaging-and-deploy-pipeline.md | EP-13 | EP-12 | Not Started |
| 15 | Static release rollback and preview deployments | docs/plans/15-static-release-rollback-and-preview-deployments.md | EP-14 | None | Not Started |
| 16 | Git webhook automation for static sites | docs/plans/16-git-webhook-automation-for-static-sites.md | EP-15 | EP-3, EP-4 | Not Started |
| 17 | Static hosting docs and end-to-end examples | docs/plans/17-static-hosting-docs-and-end-to-end-examples.md | EP-15 | EP-16 | Not Started |

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
after EP-15.

Parallelism is limited until EP-13 completes because it defines the shared static-site contract. Once
EP-13 is complete, EP-14 is the next hard gate. After EP-15, EP-16 and EP-17 can proceed in parallel:
EP-17 can document the manual flow and leave the webhook chapter pending while EP-16 implements the
automation.


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
deployment path as manual static deploys rather than defining a second deployment engine.


## Progress

- [ ] EP-13: Define the static-site model, smart constructors, JSON transport, and renderer API.
- [ ] EP-13: Add golden and negative tests for Nginx config, Knative Service, DomainMappings, redirects, headers, and invalid rules.
- [ ] EP-14: Implement local static build, output collection, generated image context, image build/push, dry-run, and production apply.
- [ ] EP-15: Add release metadata, release listing, rollback, and preview deploy naming.
- [ ] EP-16: Add a webhook receiver that verifies Git provider signatures and triggers production or preview deploys.
- [ ] EP-17: Write user docs, examples, and an end-to-end validation path for manual and automated static hosting.


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
