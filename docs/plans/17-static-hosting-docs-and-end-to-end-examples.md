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


## Purpose / Big Picture

After this plan is complete, static hosting is understandable and verifiable from the repository.
The user docs explain how to configure a static site, deploy it, preview it, roll it back, and wire
GitHub webhooks if automation is implemented. The examples give future implementers and users a
concrete project they can run through the whole workflow.

The proof is not just prose. A reader can run the documented dry-run commands against
`cluster/examples/static-site/` and compare the observed output to the guide. With Docker and a live
Nagare cluster, they can follow the end-to-end section and get a public static site URL.


## Progress

- [ ] Add a static hosting user guide under `docs/user/`.
- [ ] Add or finalize `cluster/examples/static-site/` with a typed config, static files, redirects, headers, and README.
- [ ] Document `nagarectl site deploy`, dry-run, releases, rollback, and preview commands.
- [ ] Document Git webhook setup if EP-16 is complete; otherwise document it as a planned follow-up with exact status.
- [ ] Update `docs/user/README.md` and `docs/user/reference.md` to link the static hosting guide.
- [ ] Run the dry-run validation path and record expected output excerpts in the guide.
- [ ] Run live validation if Docker and the Nagare cluster are available; record any deferred steps clearly.


## Surprises & Discoveries

(None yet.)


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

(To be filled during and after implementation.)


## Context and Orientation

Nagare's user documentation lives under `docs/user/`. Existing guides include:

- `docs/user/deploying-apps.md`, for dynamic app deployment through `nagarectl deploy`.
- `docs/user/config-reference.md`, for the current typed deployment DSL.
- `docs/user/reference.md`, for operational reference values.

The static hosting feature spans several earlier child plans under
`docs/masterplans/3-static-hosting-for-nagare.md`. This plan should not redefine implementation
details, but it must document the final user-facing behavior accurately. It hard-depends on
`docs/plans/15-static-release-rollback-and-preview-deployments.md` because release and preview
commands are part of the core workflow. It soft-depends on `docs/plans/16-git-webhook-automation-for-static-sites.md`
because Git automation can be documented after the manual static workflow is already complete.


## Plan of Work

Milestone 1 creates or finalizes the example. Ensure `cluster/examples/static-site/` contains:

```text
cluster/examples/static-site/
  public/
    index.html
    404.html
    assets/
      app.css
  nagare/
    Config.hs
  README.md
```

The example config should use the static-site DSL from EP-13. It should include one custom domain
placeholder, one redirect rule, at least one header rule, and a no-build configuration pointing at
`public/`. The README should show both dry-run and deploy commands.

Milestone 2 writes the user guide. Add `docs/user/static-hosting.md`. The guide should explain:

Static hosting is for projects that produce files such as HTML, CSS, JavaScript, images, and fonts.
Nagare packages those files into an Nginx image and deploys it through Knative. Users do not need to
write Dockerfiles or Kubernetes YAML. The guide should cover config shape, build/output directories,
redirects, headers, cache policy, custom domains, previews, releases, rollback, and troubleshooting.

Milestone 3 updates reference docs. Add links from `docs/user/README.md` and `docs/user/reference.md`.
If `docs/user/config-reference.md` remains focused on dynamic `Deployment`, either add a static
section or link to the static hosting guide and keep detailed static constructors there.

Milestone 4 records validation. Run the dry-run command from the example and capture concise output
excerpts: the heading for generated Nginx config, the Knative Service kind/name, the DomainMapping
kind/name, and the printed URL. If live cluster validation is possible, run a deploy, releases list,
preview deploy, preview delete, and rollback. If it is not possible because the VM is down, Docker is
unavailable, or the domain is still a placeholder, state that clearly in the guide and in this plan's
Outcomes section.


## Concrete Steps

Start at the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Read the docs that this guide should align with:

```bash
sed -n '1,220p' docs/user/deploying-apps.md
sed -n '1,220p' docs/user/config-reference.md
sed -n '1,180p' docs/user/README.md
```

Run the static example dry-run:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cluster/examples/static-site
nagarectl site deploy --dry-run
```

If the standalone binary cannot resolve `nagare-dsl`, repeat with the documented package environment
flag:

```bash
nagarectl site deploy --dry-run --ghc-env /path/to/.ghc.environment
```

After editing docs, check for accidental bare code fences:

```bash
rg '^```$' docs/user docs/plans docs/masterplans
```

This command should print nothing for files touched by this plan.


## Validation and Acceptance

This plan is accepted when `docs/user/static-hosting.md` exists, is linked from the user docs index,
and describes a complete manual workflow: configure, dry-run, deploy, list releases, roll back, deploy
a preview, and delete a preview. The static example must be present and runnable through dry-run. The
guide must state the exact current status of Git webhook automation: either complete with setup steps,
or not yet implemented with a pointer to `docs/plans/16-git-webhook-automation-for-static-sites.md`.

The dry-run command should produce output that matches the guide's excerpts. If live validation is
available, the guide should include the successful URL shape and any domain/TLS caveats inherited
from `docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`.


## Idempotence and Recovery

Documentation edits are safe to repeat. The dry-run validation has no side effects. Live deploy
validation creates or updates Kubernetes resources for the example static site; repeat runs are safe
because `kubectl apply` updates the same resources and image tags are timestamped. Preview delete is
the cleanup path for preview resources. Do not delete unrelated cluster resources during docs
validation.


## Interfaces and Dependencies

This plan consumes the final CLI surface from EP-14 and EP-15:

```text
nagarectl site deploy
nagarectl site releases
nagarectl site rollback RELEASE_ID
nagarectl site preview deploy --name NAME
nagarectl site preview list
nagarectl site preview delete NAME
```

If EP-16 is complete, it also documents the webhook endpoint and any setup commands. No new code
interfaces are introduced by this plan unless small example or docs fixes reveal missing user-facing
labels.
