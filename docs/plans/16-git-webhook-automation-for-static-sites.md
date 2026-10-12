---
id: 16
slug: git-webhook-automation-for-static-sites
title: "Git webhook automation for static sites"
kind: exec-plan
created_at: 2026-06-07T19:49:33Z
intention: "intention_01ktht1bdme019jxs38yjsebxq"
master_plan: "docs/masterplans/3-static-hosting-for-nagare.md"
---

# Git webhook automation for static sites

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [16-git-webhook-automation-for-static-sites.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/16-git-webhook-automation-for-static-sites.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan is complete, static sites can deploy automatically from Git events. A push to the
configured production branch triggers a production static deploy. A pull request or branch event
triggers a preview deploy. The operator configures a webhook secret once, points GitHub or GitLab at
Nagare's webhook URL, and Nagare uses the same static deploy pipeline and release metadata path as
manual CLI deploys.

This plan adds a small control service, tentatively named `nagared`, that receives webhook HTTP
requests, verifies their signatures, clones or updates the repository, and invokes the static deploy
library path. It does not invent a second deploy engine.

## Progress

- [x] Define the webhook service scope, configuration, and secret layout. (2026-06-09: `nagared` executable with `--port/--secret-file/--production-branch/--base-domain/--workspace/--ghc-env`; secret via file or `NAGARE_WEBHOOK_SECRET`.)
- [x] Implement signature verification for GitHub push and pull request events. (2026-06-09: `Nagare.Static.Webhook.verifySignature` — HMAC-SHA256 via crypton, constant-time compare; matches the canonical test vector and openssl.)
- [x] Implement repository checkout/update into a safe workspace. (2026-06-09: `Nagare.Static.Checkout.checkoutRepo` — idempotent clone/fetch + `reset --hard <sha>`; path is slug-derived so it cannot escape the workspace root.)
- [x] Trigger production deploys for configured production branch pushes. (2026-06-09: `routeEvent`/`decideWebhook` → `DeployProduction`; `nagared` runs `deployStaticProduction` from the factored `Nagare.Static.Deploy`.)
- [x] Trigger preview deploys for pull request or branch preview events. (2026-06-09: PR opened/synchronize/reopened → `DeployPreview "pr-<n>"` → `deployStaticPreview`.)
- [x] Render and document Kubernetes manifests for the webhook service. (2026-06-09: `cluster/bootstrap/nagared/` — rbac, secret template, always-on Knative Service + DomainMapping, README with runtime caveats.)
- [x] Add tests for signature verification, event parsing, branch routing, and rejected requests. (2026-06-09: 12 `nagarectl-test` cases; live `/healthz` + signed/unsigned/wrong-sig/non-prod-branch checks against a running `nagared`.)

## Surprises & Discoveries

- 2026-06-09: Milestone 1 (factor reusable deploy code) was a real prerequisite —
  the EP-14/EP-15 deploy logic lived only in `app/Main.hs`. It is now
  `Nagare.Static.Deploy` (`DeployInputs`, `productionManifests`/`previewManifests`
  for rendering, `deployStaticProduction`/`deployStaticPreview` for the effect).
  The CLI and `nagared` both call it, so there is genuinely one deploy engine. The
  CLI is now a thin wrapper; its dry-run and the real deploy share the same
  `*Manifests` renderers.
- 2026-06-09: crypton's `Digest SHA256` did not satisfy `ByteArrayAccess` for
  `convertToBase Base16` in this build, so `verifySignature` hex-encodes via
  `show (hmacGetDigest mac)` (crypton's `Show (Digest a)` is exactly the lowercase
  hex GitHub uses). The unit test pins this to the canonical HMAC-SHA256 vector,
  and a live check confirmed it matches `openssl dgst -sha256 -hmac`.
- 2026-06-09: `decideWebhook` is a single pure function returning
  `Rejected | Ignored | Triggered`, so the entire security decision (verify →
  parse → route) is unit-testable with no IO. `nagared` only performs IO
  (checkout + deploy) on `Triggered`; an unsigned/mis-signed request is 401 before
  the body is even parsed.
- 2026-06-09: warp/wai and crypton/memory were not prior dependencies but their
  full source trees are cached locally, so the server builds offline. `nagared`
  runs as an always-on Knative Service (`min-scale: 1`) so a slow docker build is
  never scaled away mid-deploy; its real runtime needs docker/git/kubectl/a GHC
  env, documented as operator setup rather than a turnkey image.

## Decision Log

- Decision: Add a small Nagare-owned service instead of relying only on local CLI automation.
  Rationale: Git-triggered deploys require a public HTTP endpoint to receive webhooks. A local CLI
  cannot receive provider events unless the user keeps a machine online. A service inside the Nagare
  cluster fits the self-hosted platform model.
  Date: 2026-06-07

- Decision: Support GitHub first.
  Rationale: GitHub webhooks are the most likely initial source for personal projects and have
  straightforward HMAC signature verification. GitLab can be added later behind the same event
  interface.
  Date: 2026-06-07

- Decision: Use the same deploy library path as `nagarectl site deploy`.
  Rationale: Manual and automated deploys must produce identical releases, previews, manifests, and
  metadata. A second deploy implementation would drift quickly.
  Date: 2026-06-07

## Outcomes & Retrospective

Completed 2026-06-09 (pure logic + live HTTP behavior validated; full in-cluster
GitHub round-trip documented as operator setup, since it needs docker/git/a GHC
env and a public endpoint).

What exists now that did not before:

- `Nagare.Static.Deploy` — the deploy engine factored out of the CLI, so
  `nagarectl site deploy` and `nagared` share one code path (Milestone 1).
- `Nagare.Static.Webhook` — pure HMAC-SHA256 verification, GitHub push/PR event
  parsing, branch/PR routing, and the top-level `decideWebhook`.
- `Nagare.Static.Checkout` — idempotent git checkout into a slug-safe workspace.
- `nagared` — a warp HTTP server: `GET /healthz` and
  `POST /webhooks/github/static/<site>`, verifying the signature, checking out the
  commit, and running the shared deploy path.
- `cluster/bootstrap/nagared/` — RBAC, a webhook-secret template, an always-on
  Knative Service + DomainMapping, and a README covering the webhook setup and the
  runtime caveats.

Validation: 12 unit tests (canonical HMAC vector, push/PR/ping parsing, routing,
rejections) plus a live run — `/healthz` → 200; a signed ping → 200 "pong"; a
wrong/missing signature → 401; a push to a non-production branch → 200 ignored.
The HMAC matches `openssl dgst -sha256 -hmac`, so real GitHub deliveries verify.

Handoffs:

- EP-17 documents the webhook setup (payload URL, secret, events) using
  `cluster/bootstrap/nagared/README.md`.
- EP-18: because `nagared` drives `Nagare.Static.Deploy`, once that module learns
  the `SiteServer` kind (via the same `loadSite` seam EP-14/EP-18 share), webhook
  deploys of a TanStack Start app work with no webhook-side change.

