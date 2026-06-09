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
- [ ] Add positive fixtures and golden tests for a static site with domains, redirects, headers, cache policy, and a 404 page.
- [ ] Add negative tests for invalid site names, directories, redirect rules, header names, status codes, and conflicting emit output.
- [x] Update `nagare-dsl.cabal` exposed modules; run the `cli/nagare-dsl` test suite after tests are added. (2026-06-09: cabal exposes `Nagare.Dsl.Static.Types` and `Nagare.Dsl.Static.Render`; library builds clean.)


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare's current DSL lives in `cli/nagare-dsl/`. The main modules are:

- `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, which defines the current `Deployment` type and smart
  constructors for Knative service deployment.
- `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, which exposes `emitDeployment :: Deployment -> IO ()`
  for app-supplied `nagare/Config.hs` files.
- `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, which runs a config with `runghc`, captures JSON, and
  decodes it back into a validated `Deployment`.
- `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`, which renders a `Deployment` to Knative Service and
  DomainMapping YAML.

A "static site" here means a directory of files that can be served directly over HTTP after a build
step. Examples are Vite's `dist/`, Astro's `dist/`, Hugo's `public/`, and a plain hand-written
directory containing `index.html`. A "redirect rule" maps one request path to another URL or path
with an HTTP status such as 301 or 302. A "header rule" adds response headers for matching paths,
for example cache headers for immutable assets.

The static site runtime chosen by the parent MasterPlan is an Nginx-based container image deployed
as a Knative Service. This plan owns only the config and renderer pieces. The later plan
`docs/plans/14-static-build-packaging-and-deploy-pipeline.md` will build that image and apply the
rendered manifests.


## Plan of Work

Milestone 1 adds the static model. Create `cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs` and expose
it from `cli/nagare-dsl/nagare-dsl.cabal`. Follow the style in `Nagare.Dsl.Types`: hidden newtype
constructors where values need validation, `mkX :: ... -> Either Text X` smart constructors, strict
record fields, unprefixed field names, and `Nagare.Dsl.Prelude` imports. The initial model should be:

```haskell
data StaticSite = StaticSite
  { name :: SiteName
  , namespace :: Namespace
  , image :: ImageRef
  , build :: StaticBuild
  , domains :: [Domain]
  , redirects :: [RedirectRule]
  , headers :: [HeaderRule]
  , cache :: CachePolicy
  , notFound :: Maybe FilePathText
  }
```

`SiteName` should use the same DNS-label rules as `ServiceName`. `FilePathText` should reject empty
paths, absolute paths, `..` segments, and NUL characters. `StaticBuild` should support at least
`NoBuild FilePathText` and `BuildCommand { command :: Text, outputDirectory :: FilePathText }`.
Redirect status codes should initially allow only 301, 302, 303, 307, and 308. Header names should
reject empty names, whitespace, control characters, and colon.

Milestone 2 extends config emission and loading. Add
`emitStaticSite :: StaticSite -> IO ()` in `Nagare.Dsl.Config`. Keep `emitDeployment` unchanged.
Extend `Nagare.Dsl.Load` with a separate `loadStaticSite :: FilePath -> IO (Either LoadError StaticSite)`
and pure `decodeStaticSite`. Do not change `loadDeployment`'s signature or behavior. The JSON shape
for static sites should include a top-level discriminator such as `"kind": "StaticSite"` so the
loader can report a precise error if a config calls `emitDeployment` under `nagarectl site deploy`.

Milestone 3 adds renderers. Create `cli/nagare-dsl/src/Nagare/Dsl/Static/Render.hs` exposing:

```haskell
data StaticDeployContext = StaticDeployContext
  { imageTag :: Text
  , previewName :: Maybe Text
  }

renderNginxConfig :: StaticSite -> ByteString
renderStaticService :: StaticSite -> StaticDeployContext -> ByteString
renderStaticDomainMappings :: StaticSite -> StaticDeployContext -> [ByteString]
```

`renderStaticService` should render a Knative Service that points at `imageRefText site.image <> ":" <> imageTag`
and container port 8080. `renderStaticDomainMappings` should render one DomainMapping per configured
domain. `renderNginxConfig` should serve `/usr/share/nginx/html`, use `try_files` for extensionless
static page lookup where practical, honor `notFound` if set, apply redirects before headers for the
same path, and emit cache headers from `CachePolicy`.

Milestone 4 adds tests and fixtures. Add a fixture under
`cli/nagare-dsl/test/fixtures/static-site/nagare/Config.hs` that emits a static site with one custom
domain, one redirect, one header rule, an immutable asset cache policy, and a `404.html` page. Add
golden files under `cli/nagare-dsl/test/golden/` for the Nginx config, Knative Service, and
DomainMapping YAML. Extend `cli/nagare-dsl/test/Spec.hs` or add a new `StaticSpec.hs` so `cabal test`
exercises both success and failure cases.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Inspect the existing DSL patterns before editing:

```bash
sed -n '1,260p' cli/nagare-dsl/src/Nagare/Dsl/Types.hs
sed -n '1,260p' cli/nagare-dsl/src/Nagare/Dsl/Load.hs
sed -n '1,240p' cli/nagare-dsl/src/Nagare/Dsl/Render.hs
```

After adding modules and tests, run:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagare-dsl
cabal test
```

Success means the test executable reports all existing deployment tests plus the new static-site
tests passing. If `runghc` cannot find `nagare-dsl` in a fixture test, use the existing
`NAGARE_GHC_ENVIRONMENT` or cabal package-environment pattern documented in
`docs/plans/10-config-surface-and-loading-for-the-chosen-substrate.md`.


## Validation and Acceptance

This plan is accepted when `cabal test` in `cli/nagare-dsl/` proves all of the following:

The fixture static config loads through `loadStaticSite` and returns a `StaticSite` equal to the
expected value built in the test. `renderStaticService` produces deterministic Knative Service YAML
for image tag `20260607-120000`. `renderStaticDomainMappings` produces one DomainMapping per domain.
`renderNginxConfig` produces a config containing the expected redirect, header rule, root directory,
and 404 behavior. Invalid static site names, absolute output directories, parent-directory segments,
invalid redirect status codes, invalid header names, and wrong emitted kind all return precise
`LoadError` or constructor errors.


## Idempotence and Recovery

All changes are source files and tests. Re-running `cabal test` is safe. If a golden file changes
unexpectedly, inspect the rendered output and decide whether the type/rendering contract changed; do
not blindly accept new output. If the static loader change breaks existing deployment fixtures, revert
only the static loader edits and preserve unrelated user changes.


## Interfaces and Dependencies

This plan depends only on packages already used by `nagare-dsl`: `aeson`, `bytestring`, `containers`,
`text`, `yaml`, and the existing test stack. If an additional parsing helper is needed, prefer small
local validation code over adding a dependency. Later plans consume these public interfaces:

```haskell
module Nagare.Dsl.Static.Types
  ( StaticSite(..)
  , SiteName
  , mkSiteName
  , StaticBuild(..)
  , FilePathText
  , mkFilePathText
  , RedirectRule(..)
  , mkRedirectRule
  , HeaderRule(..)
  , mkHeaderRule
  , CachePolicy(..)
  ) where

module Nagare.Dsl.Config
  ( emitDeployment
  , emitStaticSite
  ) where

module Nagare.Dsl.Load
  ( loadDeployment
  , loadStaticSite
  , decodeDeployment
  , decodeStaticSite
  ) where

module Nagare.Dsl.Static.Render
  ( StaticDeployContext(..)
  , renderNginxConfig
  , renderStaticService
  , renderStaticDomainMappings
  ) where
```


## Revision Notes

- 2026-06-09: Recorded that the `kind` discriminator and the `SiteName`/`FilePathText` leaf types are
  a shared extension surface reused by `docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md`
  (EP-18), which adds a `ServerSite` model for server-rendered apps (TanStack Start and other Node
  frameworks). No change to this plan's static-site model, renderers, or tests; the amendment only
  fixes the contract EP-18 builds on. Reason: the parent MasterPlan was extended to support full-stack
  server-runtime hosting in addition to static hosting.
