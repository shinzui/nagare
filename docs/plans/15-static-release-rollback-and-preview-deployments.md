---
id: 15
slug: static-release-rollback-and-preview-deployments
title: "Static release rollback and preview deployments"
kind: exec-plan
created_at: 2026-06-07T19:49:33Z
intention: "intention_01ktht1bdme019jxs38yjsebxq"
master_plan: "docs/masterplans/3-static-hosting-for-nagare.md"
---

# Static release rollback and preview deployments

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan is complete, static site deploys are not one-way mutations. Every production deploy
records a release id, image tag, timestamp, source label, and URL. A developer can list releases,
roll back production to a prior release, and deploy branch or pull-request previews without changing
the production site. This closes the largest lifecycle gap between a basic static deploy command and
a Cloudflare Pages-like workflow.

The observable behavior is CLI-driven: `nagarectl site releases` lists prior deploys, `nagarectl site
rollback <release-id>` points the production Knative Service back to an earlier image, and
`nagarectl site preview deploy --name feature-x` creates a separate preview Knative Service and URL.


## Progress

- [x] Define release metadata types and JSON encoding in `nagarectl`. (2026-06-09: `Nagare.Static.Release` — `StaticRelease`/`StaticReleaseLog` with hand-written aeson instances.)
- [x] Store and update release metadata in a Kubernetes ConfigMap per site. (2026-06-09: `renderReleaseConfigMap`/`extractReleaseLog`/`readReleaseLog`/`writeReleaseLog`; ConfigMap `nagare-static-releases-<site>`, data key `releases.json`.)
- [x] Add release recording to successful `nagarectl site deploy`. (2026-06-09: `recordRelease` after `waitForReady`; dry-run prints `Release: <tag>`; malformed history is not overwritten and exits non-zero.)
- [x] Add `nagarectl site releases` and `nagarectl site rollback`. (2026-06-09: `runSiteReleases` prints a table; `runSiteRollback` re-applies the prior image tag and marks it current.)
- [x] Add preview naming, preview deploy, preview list, and preview delete commands. (2026-06-09: `Nagare.Static.Preview` + `site preview deploy|list|delete`.)
- [x] Add tests for release metadata parsing, preview name validation, and rollback manifest generation. (2026-06-09: 14 new `nagarectl-test` cases — JSON round-trip, dedupe, history cap, ConfigMap extract, preview normalization/naming.)
- [ ] Validate the release and preview flow against the static example. (2026-06-09: dry-run paths validated locally; the kubectl-backed `releases`/`rollback`/`preview list|delete` flow needs a live cluster — documented as manual validation.)


## Surprises & Discoveries

- 2026-06-09: Previews reuse EP-13's renderers without a new nagare-dsl function:
  the preview deploy overrides the site's `domains` to the single derived preview
  domain (`site & #domains .~ [pd]`) and sets `StaticDeployContext.previewName` to
  the derived service name. `renderStaticService` then names the Service
  `<site>-pr-<name>` and `renderStaticDomainMappings` emits one mapping for the
  preview domain pointing at it. No preview-specific renderer was needed.
- 2026-06-09: Preview Services are identified by the naming convention
  `<site>-pr-<name>` (`previewPrefix`) rather than by a Kubernetes label, because
  the EP-13 renderer does not emit labels. `site preview list` filters
  `kubectl get ksvc -o name` by that prefix; `site preview delete` deletes the
  Service and DomainMapping by derived name with `--ignore-not-found`.
- 2026-06-09: Release recording deliberately reads-then-writes the ConfigMap and
  refuses to overwrite a *malformed* existing history (`extractReleaseLog` →
  `Left` aborts with a non-zero exit), so a decoder bug can never destroy real
  release history. A *missing* ConfigMap is treated as an empty log.
- 2026-06-09: `aeson` was not yet a direct dependency of `nagarectl` (only of
  `nagare-dsl`); added it to the library and test stanzas for the release-log
  JSON.


## Decision Log

- Decision: Store release metadata in a ConfigMap before introducing a database.
  Rationale: Nagare is a single-node personal PaaS. ConfigMaps are available immediately, easy to
  inspect, covered by Kubernetes backup practices, and sufficient for compact release history.
  Date: 2026-06-07

- Decision: Use image tags as immutable release artifacts.
  Rationale: EP-14 packages every static asset set into a tagged container image. Rollback can be a
  Kubernetes patch to an older image tag; no separate asset store or symlink manager is required.
  Date: 2026-06-07

- Decision: Model preview deployments as separate Knative Services, not as traffic splits on the
  production service.
  Rationale: Branch and pull-request previews need independent domains and lifecycle. Separate
  services are easy to list, delete, and isolate, and fit the existing Knative resource model.
  Date: 2026-06-07


## Outcomes & Retrospective

Completed 2026-06-09 (cluster-backed flow validated by dry-run + unit tests;
full kubectl flow documented as manual validation pending a live cluster).

What exists now that did not before:

- `Nagare.Static.Release` — `StaticRelease`/`StaticReleaseLog`, `addRelease`
  (newest-first, dedupe-by-id, capped at `historyCap = 50`), `findRelease`, the
  per-site ConfigMap rendering/extraction, and `readReleaseLog`/`writeReleaseLog`
  over `kubectl`.
- `Nagare.Static.Preview` — `normalizePreviewName`, `previewServiceName`
  (`<site>-pr-<name>`, clipped to 63 chars), `previewDomain`
  (`<preview>.<site>.preview.<base>`), and `listPreviews`/`deletePreview`.
- New CLI surface: `site deploy` now records a release; `site releases`,
  `site rollback RELEASE_ID`, and `site preview deploy|list|delete`. `site deploy`
  gained `--source` for release provenance.

Validation: `site deploy --dry-run` prints `Release: <tag>`; `site preview
deploy --dry-run --name 'Feature/X-1'` derives service `static-site-pr-feature-x-1`,
domain `feature-x-1.static-site.preview.apps.example.com`, and a matching
DomainMapping; `cabal test` passes all 20 tests (6 from EP-14 + 14 new). The
`releases`/`rollback`/`preview list|delete` operations call `kubectl` and are
validated against a live cluster per the example README.

Handoffs:

- EP-16's webhook runner triggers the same `site deploy` path (production) and
  `site preview deploy` path; it appends release records through the same
  `writeReleaseLog` rather than a second engine.
- EP-17 documents `site releases`/`rollback`/`preview` using the
  `nagare-static-releases-<site>` ConfigMap schema and the `<site>-pr-<name>`
  preview convention.
- EP-18's server sites flow through `recordRelease` unchanged — the release
  record stores the image tag and is runtime-agnostic.


## Context and Orientation

This plan builds on `docs/plans/14-static-build-packaging-and-deploy-pipeline.md`, which provides
`nagarectl site deploy` for a production static site. That command builds a static site into an
Nginx container image and applies a Knative Service. This plan adds lifecycle state around that
working deploy path.

A "release" is one successful production deploy. It records which image tag was activated and enough
metadata to show it to a human. A "rollback" means changing the live production Knative Service back
to the image tag from an older release. A "preview deployment" means a non-production copy of the
site for a branch or pull request, usually under a URL such as
`feature-x.<site>.preview.<baseDomain>`.

The chosen metadata store is a Kubernetes ConfigMap in the site's namespace. The ConfigMap should be
named predictably, for example `nagare-static-releases-<site>`, and contain a compact JSON document
with recent release records. Keep the schema small to avoid ConfigMap size issues.


## Plan of Work

Milestone 1 defines release metadata. Add a module such as
`cli/nagarectl/src/Nagare/Static/Release.hs` with strict records:

```haskell
data StaticRelease = StaticRelease
  { releaseId :: Text
  , siteName :: Text
  , namespace :: Text
  , image :: Text
  , imageTag :: Text
  , url :: Text
  , source :: Maybe Text
  , createdAt :: UTCTime
  }

data StaticReleaseLog = StaticReleaseLog
  { current :: Maybe Text
  , releases :: [StaticRelease]
  }
```

The release id should default to the image tag computed by the deploy pipeline. Keep the newest
records first and cap history at a reasonable number such as 50 releases.

Milestone 2 implements ConfigMap persistence. Add helpers that call `kubectl get configmap ... -o
json`, decode the release log, and `kubectl apply` an updated ConfigMap. Use the same process style
as `Nagare.Deploy`, through `cradle` if that is still the pattern. A missing ConfigMap should be
treated as an empty release log. Malformed JSON should be a clear CLI error, not silent data loss.

Milestone 3 records successful deploys. Extend the non-dry-run path from EP-14 so release metadata is
written only after the Knative Service is Ready. Dry-run should print the release id it would use but
not write the ConfigMap. If release recording fails after the service is live, print the error and
exit non-zero so the operator knows the deploy succeeded but history is incomplete.

Milestone 4 adds release commands. Add these CLI forms under `nagarectl site`:

```text
nagarectl site releases
nagarectl site rollback RELEASE_ID
```

`site releases` loads the static config to identify the site and namespace, reads the ConfigMap, and
prints a compact table of release id, timestamp, current marker, source, image tag, and URL.
`site rollback` finds the release, renders the production Static Service with that old image tag,
applies it, waits for readiness, sets `current` in the release log, and prints the URL.

Milestone 5 adds previews. Add:

```text
nagarectl site preview deploy --name NAME
nagarectl site preview list
nagarectl site preview delete NAME
```

Preview names must be DNS-safe after normalization. A preview service name should be derived from
the production site name and preview name without exceeding Kubernetes DNS label limits. The preview
domain should be derived from the apps base domain, for example
`<preview>.<site>.preview.<baseDomain>`, unless the static config later adds explicit preview domain
settings. Preview delete should remove the preview Knative Service and DomainMapping manifests that
Nagare created; it should not delete production releases.


## Concrete Steps

Start from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Inspect the static deploy implementation from EP-14:

```bash
sed -n '1,320p' cli/nagarectl/app/Main.hs
rg "site" cli/nagarectl/src cli/nagarectl/app
```

After editing, run:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build
cabal test
```

With a live cluster, validate against the static example:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cluster/examples/static-site
nagarectl site deploy
nagarectl site releases
nagarectl site preview deploy --name feature-x
nagarectl site preview list
nagarectl site preview delete feature-x
```


## Validation and Acceptance

This plan is accepted when the static deploy flow records a release ConfigMap after successful
deployment, `site releases` prints that release, and `site rollback <release-id>` applies the older
image tag and marks it current. Preview deploy acceptance requires that `site preview deploy --name
feature-x` creates a distinct Knative Service, prints a preview URL, and leaves the production
service unchanged. `site preview delete feature-x` should remove the preview resources and tolerate a
second delete with a clear "not found" or no-op message.

Unit tests should cover JSON round-tripping for release logs, malformed release log handling, history
capping, preview name validation, and production versus preview service naming.


## Idempotence and Recovery

Release listing is read-only. Recording a release should be idempotent for the same release id:
re-running the same deploy with the same tag should update or preserve that record rather than
duplicating it. Rollback is safe to repeat because it reapplies the same desired Knative Service.
Preview deploy with the same name should update that preview to the new image tag; preview delete
should be safe to retry.

If ConfigMap JSON is malformed, do not overwrite it automatically. Print the ConfigMap name and ask
the operator to inspect it. This avoids destroying release history because of a decoder bug.


## Interfaces and Dependencies

This plan consumes the static deploy functions and renderer context from EP-14 and EP-13. It should
add release helpers in `cli/nagarectl/src/Nagare/Static/Release.hs` and preview helpers in
`cli/nagarectl/src/Nagare/Static/Preview.hs` if the implementation grows beyond one module.

No new external service is required. The only external command dependency is `kubectl`, already used
by `Nagare.Deploy`.
