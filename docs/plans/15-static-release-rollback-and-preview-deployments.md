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

Full plan before trimming: [15-static-release-rollback-and-preview-deployments.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/15-static-release-rollback-and-preview-deployments.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

