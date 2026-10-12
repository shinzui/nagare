---
id: 13
slug: typed-static-site-model-and-renderer
title: "Typed static site model and renderer"
kind: exec-plan
created_at: 2026-06-07T19:49:33Z
intention: "intention_01ktht1bdme019jxs38yjsebxq"
master_plan: "docs/masterplans/3-static-hosting-for-nagare.md"
---

# Typed static site model and renderer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [13-typed-static-site-model-and-renderer.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/13-typed-static-site-model-and-renderer.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan is complete, Nagare's typed Haskell configuration language can describe a static
site in addition to a long-running web service. A developer can write a `nagare/Config.hs` that emits
a `StaticSite`, run a dry-rendering command or test fixture, and see two concrete outputs: the Nginx
configuration that will serve the generated files, and the Knative Service plus DomainMapping YAML
that will expose the site through Nagare's existing Kourier ingress.

This plan does not build or deploy a real static site. It creates the static-site contract that later
plans consume. The observable proof is offline: cabal tests in `cli/nagare-dsl/` load a static config,
reject invalid rules, and compare rendered YAML/Nginx config against golden files.

## Progress

- [x] Add `Nagare.Dsl.Static.Types` with the `StaticSite` model and validating smart constructors. (2026-06-09)
- [x] Extend `Nagare.Dsl.Config` and `Nagare.Dsl.Load` so config-as-program files can emit and load static sites without breaking existing `Deployment` loading. (2026-06-09)
- [x] Add `Nagare.Dsl.Static.Render` with renderers for Nginx config, Knative Service, and DomainMappings. (2026-06-09)
- [x] Add positive fixtures and golden tests for a static site with domains, redirects, headers, cache policy, and a 404 page. (2026-06-09: `test/fixtures/static-site/nagare/Config.hs` loads via `loadStaticSite` to the expected `StaticSite`; goldens `static-site.nginx.conf`, `static-site.service.yaml`, `static-site.domainmapping.yaml`.)
- [x] Add negative tests for invalid site names, directories, redirect rules, header names, status codes, and conflicting emit output. (2026-06-09: `StaticSpec.hs` covers constructor-level and `decodeStaticSite` rejections incl. `UnexpectedKind` for missing/`ServerSite` kind.)
- [x] Update `nagare-dsl.cabal` exposed modules; run the `cli/nagare-dsl` test suite after tests are added. (2026-06-09: cabal exposes `Nagare.Dsl.Static.Types`/`Nagare.Dsl.Static.Render`, adds `StaticSpec` to the test suite; `cabal test` reports all 95 tests passing.)

## Surprises & Discoveries

- 2026-06-09: Added a dedicated `UnexpectedKind !Text !Text` (expected, actual)
  constructor to `Nagare.Dsl.Load.LoadError` rather than overloading
  `MarshalError` for the kind-discriminator mismatch. This makes "config emitted
  the wrong shape" a distinct, matchable failure for the kind-dispatching
  `loadSite` that EP-18 adds and that EP-14's `nagarectl site deploy` calls. It
  is a backward-compatible addition: existing `loadDeployment`/`decodeDeployment`
  behavior is unchanged (a deployment-shaped config has no `kind` field and is
  only rejected on the *static* path). `renderLoadError` handles the new
  constructor.

- 2026-06-09: The loader subprocess runner was factored out of `loadDeployment`
  into a shared `runConfig :: FilePath -> IO (Either LoadError ByteString)` so
  `loadStaticSite` reuses the exact compile-and-run + `MissingBinding`/`CompileError`
  contract. `loadDeployment = fmap (>>= decodeDeployment) . runConfig` is
  behaviorally identical to the previous inline implementation.

- 2026-06-09: `Nagare.Dsl.Static.Types` exports a few helpers beyond the
  illustrative list in Interfaces and Dependencies, because EP-14/EP-15 will need
  them: `siteNameText`, `filePathText`, `staticOutputDir`, `staticBuildCommand`,
  `allowedRedirectStatuses`, `defaultCachePolicy`, and `mkCachePolicy`. In
  particular `staticOutputDir`/`staticBuildCommand` give EP-14 the directory to
  package and the optional build command to run without re-pattern-matching
  `StaticBuild`.

## Decision Log

- Decision: Model static hosting as a new top-level `StaticSite` value, not as optional fields on
  the existing `Deployment`.
  Rationale: `Deployment` means a containerized Knative web service with resources, scale, env, and
  port. Static sites need build/output directories, redirects, headers, and cache policy. A separate
  type keeps both APIs small and makes illegal combinations harder to express.
  Date: 2026-06-07

- Decision: Preserve the existing `emitDeployment` API and add a parallel static emission helper
  instead of changing its return type.
  Rationale: Existing app configs should continue to compile. Later CLI work can choose which loader
  to call for `nagarectl deploy` versus `nagarectl site deploy`.
  Date: 2026-06-07

- Decision: Generate Nginx configuration from typed rules rather than requiring users to commit an
  Nginx file.
  Rationale: The replacement target is Cloudflare Pages-style static hosting, where redirects and
  headers are project-level declarations. A typed renderer can validate rule shape before deploy and
  can later import `_redirects` and `_headers` compatibility without exposing Nginx internals.
  Date: 2026-06-07

- Decision: Treat the JSON `kind` discriminator and the shared leaf types (`SiteName`,
  `FilePathText`) as an open extension surface, not a static-only one.
  Rationale: `docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md` (EP-18) adds a
  sibling `ServerSite` model for server-rendered apps such as TanStack Start, emitted with
  `"kind":"ServerSite"` and reusing `SiteName` and `FilePathText` from `Nagare.Dsl.Static.Types`.
  This plan therefore keeps the loader's `kind` handling tolerant of additional known kinds (returning
  a precise error for an unexpected kind rather than assuming static), and exposes `SiteName`,
  `FilePathText`, and `mkFilePathText` so EP-18 can import them instead of redefining them.
  Date: 2026-06-09

- Decision: Keep Nginx as the static origin server rendered by `renderNginxConfig`; do not switch the
  renderer to a Caddyfile/Caddy image.
  Rationale: Evaluated Caddy as an alternative while the renderer surface is still small. Caddy's
  headline automatic-HTTPS feature is irrelevant here — TLS terminates upstream (Kourier today, the
  CDN edge after MasterPlan 11) and the origin serves plain HTTP on port 8080 from an immutable image
  — leaving only generated-config readability, which users never see because the config is
  machine-generated from the typed rules. Nginx idles lighter for scale-to-zero density and its
  generator is already golden-tested, so a switch is churn that would re-derive the `location`
  precedence (immutable-asset regex vs header-prefix) this plan already resolved. Recorded at the
  coordination level in `docs/masterplans/3-static-hosting-for-nagare.md` (Decision Log, 2026-06-10).
  Date: 2026-06-10

## Outcomes & Retrospective

Completed 2026-06-09. Nagare's typed DSL can now describe a static site and
render it to the three deploy artifacts, all proven offline by `cabal test`.

What exists now that did not before:

- `Nagare.Dsl.Static.Types` — the `StaticSite` model with hidden-constructor
  leaf newtypes (`SiteName`, `FilePathText`) and validating smart constructors
  for site names, relative paths, redirect rules (status restricted to
  301/302/303/307/308), header rules (name rejects whitespace, control chars,
  and colon), and `CachePolicy`. `StaticBuild` is `NoBuild`/`BuildCommand`.
- `Nagare.Dsl.Config.emitStaticSite` — JSON transport tagged
  `"kind":"StaticSite"`; `emitDeployment` is untouched.
- `Nagare.Dsl.Load.loadStaticSite`/`decodeStaticSite` — kind-checked decode that
  re-runs every smart constructor and reports `UnexpectedKind` when a config
  emits the wrong shape.
- `Nagare.Dsl.Static.Render` — `renderNginxConfig`, `renderStaticService`,
  `renderStaticDomainMappings`, with `StaticDeployContext { imageTag, previewName }`.

Validation: `cabal test` in `cli/nagare-dsl/` reports all 95 tests passing
(63 pre-existing + 32 new), including the fixture round-trip, three render
goldens, and the constructor/decoder negative cases.

Handoffs to later plans:

- EP-14 consumes `loadStaticSite` and the three renderers. `previewName` in
  `StaticDeployContext` is wired for EP-15 but unused on the production path
  (pass `Nothing`). The Nginx image must serve `/usr/share/nginx/html` on port
  8080 and place `renderNginxConfig` output where Nginx reads its server block.
- EP-18 imports `SiteName`, `FilePathText`, and `mkFilePathText` from
  `Nagare.Dsl.Static.Types` and adds a sibling `ServerSite` kind; the loader's
  kind handling already returns a precise `UnexpectedKind` for any kind it does
  not recognise, so EP-18's `loadSite` dispatcher slots in without changing the
  static path.

Possible follow-ups (not blocking): the Nginx `location` precedence when a
header-rule path and the immutable-asset regex both match a request is resolved
by nginx's longest-prefix/regex rules, not by declaration order; EP-14's
end-to-end serving test should confirm the intended header wins for a real
fingerprinted asset. A `_redirects`/`_headers` importer was deliberately left
out of this plan (see Decision Log).

