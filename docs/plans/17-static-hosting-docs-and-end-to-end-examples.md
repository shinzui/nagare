---
id: 17
slug: static-hosting-docs-and-end-to-end-examples
title: "Static hosting docs and end-to-end examples"
kind: exec-plan
created_at: 2026-06-07T19:50:00Z
intention: "intention_01ktht1bdme019jxs38yjsebxq"
master_plan: "docs/masterplans/3-static-hosting-for-nagare.md"
---

# Static hosting docs and end-to-end examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [17-static-hosting-docs-and-end-to-end-examples.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/17-static-hosting-docs-and-end-to-end-examples.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan is complete, static hosting is understandable and verifiable from the repository.
The user docs explain how to configure a static site, deploy it, preview it, roll it back, and wire
GitHub webhooks if automation is implemented. The examples give future implementers and users a
concrete project they can run through the whole workflow.

The proof is not just prose. A reader can run the documented dry-run commands against
`cluster/examples/static-site/` and compare the observed output to the guide. With Docker and a live
Nagare cluster, they can follow the end-to-end section and get a public static site URL.

## Progress

- [x] Add a static hosting user guide under `docs/user/`. (2026-06-09: `docs/user/static-hosting.md`, covering static + full-stack hosting.)
- [x] Add or finalize `cluster/examples/static-site/` with a typed config, static files, redirects, headers, and README. (2026-06-09: present since EP-14; added `public/assets/app.css` and linked it from `index.html` to exercise the immutable-asset cache.)
- [x] Document `nagarectl site deploy`, dry-run, releases, rollback, and preview commands. (2026-06-09: full CLI reference + worked sections.)
- [x] Document Git webhook setup if EP-16 is complete; otherwise document it as a planned follow-up with exact status. (2026-06-09: EP-16 is complete — documented `nagared`, signature verification, and GitHub webhook config, pointing at `cluster/bootstrap/nagared/README.md`.)
- [x] Update `docs/user/README.md` and `docs/user/reference.md` to link the static hosting guide. (2026-06-09: status table row, read-in-order sub-bullet, and a `nagarectl site` command table.)
- [x] Run the dry-run validation path and record expected output excerpts in the guide. (2026-06-09: static and server dry-run excerpts captured and verified against live `--dry-run` output.)
- [x] Run live validation if Docker and the Nagare cluster are available; record any deferred steps clearly. (2026-06-09: deferred — `nagare-01` is powered down; the guide marks the live deploy 🟡 and the `apps.example.com` URLs as placeholders, matching `deploying-apps.md`.) (2026-10-17: the static-site flow ran live on a disposable local context: reviewed `site deploy`, `site releases`, `site rollback` and a preview deploy, each answering over HTTPS; [MasterPlan 27 site-access drill](../audits/mp27-site-access-drill-2026-10-13/README.md). Not run live: the full-stack and webhook legs.)

## Surprises & Discoveries

- 2026-06-09: Both soft dependencies were already complete when this plan ran
  (EP-16 webhooks and EP-18 full-stack), so the guide documents the *full*
  workflow — static + server hosting, releases, rollback, previews, and Git
  webhooks — rather than leaving chapters pending. The guide notes the one real
  gap (server-site previews, an EP-18 follow-up) inline.
- 2026-06-09: The repo doc convention is that an *opening* fence carries a
  language tag while the *closing* fence is bare ```` ``` ````, so the plan's
  `rg '^```$'` check necessarily matches every closing fence. Verified instead by
  parity (tagged-openings + bare-closings == total fences) that no opening fence
  is untagged.

## Decision Log

- Decision: Documentation should lead with the static-site workflow, not with Nginx or Kubernetes internals.
  Rationale: The feature is meant to replace Cloudflare Pages-style deployment for users. Internal
  image and manifest details should be reference material, not the first screen.
  Date: 2026-06-07

- Decision: Keep the example framework-free.
  Rationale: A plain `public/` directory with `index.html`, `404.html`, redirects, and headers proves
  the hosting pipeline without adding Node, Hugo, or another framework as a prerequisite. Framework
  presets can be added later.
  Date: 2026-06-07

## Outcomes & Retrospective

Completed 2026-06-09 (offline/dry-run validated; live cluster validation deferred
until `nagare-01` is up).

What exists now that did not before:

- `docs/user/static-hosting.md` — the developer guide: the two site kinds and the
  one command, the `StaticSite` and `ServerSite` config shapes with field
  references, dry-run and live deploy, releases/rollback, previews, the full-stack
  (TanStack Start) path, Git webhooks (`nagared`), a CLI reference, and a
  troubleshooting table. It leads with the workflow, not Nginx/Kubernetes
  internals (per the Decision Log).
- `docs/user/README.md` links it (status table row + read-in-order sub-bullet);
  `docs/user/reference.md` gains a `nagarectl site` command table.
- `cluster/examples/static-site/` finalized with `public/assets/app.css` linked
  from `index.html`, so the immutable-asset cache rule is exercised. The
  `cluster/examples/tanstack-start/` example (from EP-18) is linked for the
  full-stack path.

Validation: the static and server `--dry-run` excerpts in the guide were captured
from and re-checked against live `nagarectl site deploy --dry-run` output. Fence
parity was verified (no untagged opening fence). The guide states the exact status
of every leg: dry-run works today; the live build→push→apply→URL leg and the
in-cluster GitHub webhook round-trip are 🟡 pending the box and a real base domain.

This completes MasterPlan 3: static hosting is now understandable and verifiable
from the repository, from config through deploy, lifecycle, automation, and the
full-stack runtime.

