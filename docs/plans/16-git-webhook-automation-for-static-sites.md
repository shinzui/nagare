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


## Context and Orientation

The manual static hosting path is defined by `docs/plans/14-static-build-packaging-and-deploy-pipeline.md`
and `docs/plans/15-static-release-rollback-and-preview-deployments.md`. This plan assumes those are
complete. The webhook service should call shared Haskell functions from `cli/nagarectl/` or a new
library package factored out of it. If `nagarectl` is currently executable-only, this plan may need
to split reusable deployment code into exposed modules without changing the CLI behavior.

A "webhook" is an HTTP request sent by a Git provider when something happens in a repository. GitHub
signs webhook bodies with an HMAC digest in the `X-Hub-Signature-256` header. The service must
compute the HMAC with the configured secret and reject requests whose signature does not match. This
prevents arbitrary internet clients from triggering deploys.

The service needs credentials for Docker push, Kubernetes apply, and repository access. On the
Nagare VM, the existing GCP service account can authenticate to Artifact Registry, and in-cluster
Kubernetes credentials can be represented by a ServiceAccount with the minimum RBAC needed to manage
static site resources in the application namespace. Private Git repository access should use a
Kubernetes Secret containing a deploy key or token.


## Plan of Work

Milestone 1 factors reusable deploy code. Inspect the static deploy implementation from EP-14. If
the deployment logic lives only in `Main.hs`, move it into an importable module such as
`cli/nagarectl/src/Nagare/Static/Deploy.hs` while keeping the CLI parser in `Main.hs`. The module
should expose functions for production deploy and preview deploy that accept explicit options rather
than reading CLI flags directly.

Milestone 2 implements webhook parsing and verification. Add a module such as
`cli/nagarectl/src/Nagare/Static/Webhook.hs` with pure functions to parse GitHub events and verify
signatures. The important GitHub headers are `X-GitHub-Event`, `X-GitHub-Delivery`, and
`X-Hub-Signature-256`. Push events should extract repository clone URL, branch ref, commit SHA, and
repository full name. Pull request events should extract pull request number, head ref, head SHA, and
clone URL.

Milestone 3 adds the service executable. Add a small executable target, probably `nagared`, in
`cli/nagarectl/nagarectl.cabal` or a new sibling package if that is cleaner. It should expose:

```text
POST /webhooks/github/static/<site>
GET /healthz
```

The POST route verifies the signature, maps the event to either production deploy or preview deploy,
checks out the repository into a workspace under `/var/lib/nagare/webhook-workspaces` or a mounted
volume, and invokes the static deploy function. `GET /healthz` returns 200 for readiness checks.

Milestone 4 adds Kubernetes deployment manifests. Create manifests under
`cluster/bootstrap/nagared/` or `cluster/examples/nagared/` for a Knative Service or Kubernetes
Deployment, depending on whether long-running request processing works cleanly with scale-to-zero.
Start with a Knative Service if requests can complete within normal webhook timeout windows; use a
plain Deployment if background job processing is needed. Include a Secret template for the webhook
secret and any Git token, and RBAC scoped to static site resources.

Milestone 5 adds tests and a dry validation path. Unit tests should cover signature verification,
event parsing, production branch routing, preview routing, and rejected events. Add documentation
snippets that show how to configure a GitHub webhook URL and secret, but the full user docs are owned
by EP-17.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Inspect existing CLI package layout:

```bash
sed -n '1,260p' cli/nagarectl/nagarectl.cabal
sed -n '1,360p' cli/nagarectl/app/Main.hs
rg "Static" cli/nagarectl/src cli/nagarectl/app
```

After edits, run:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build all
cabal test
```

For local service validation, run the daemon on a high port and send a signed fixture webhook body.
The exact command depends on the executable name chosen during implementation, but the expected flow
is:

```bash
cabal run nagared -- --port 8088 --config path/to/local/config
```

Then use a fixture request in the tests rather than manually crafting signatures in shell.


## Validation and Acceptance

This plan is accepted when unsigned or incorrectly signed webhook requests return 401 or 403, valid
GitHub push events to the configured production branch invoke the production static deploy function,
and valid pull request events invoke the preview deploy function with a deterministic preview name.
The service must expose `/healthz` returning HTTP 200. The test suite must prove signature
verification and event routing without requiring a live GitHub webhook.

Cluster validation is accepted when the service manifest applies successfully, the service is
reachable through a configured URL, and a signed local request sent to that URL reaches the service.
Actual GitHub configuration can be documented as an operator step if live provider credentials are
not available during implementation.


## Idempotence and Recovery

Webhook handling must be idempotent for repeated delivery ids. GitHub retries webhooks, so a repeated
push event for the same commit should not create duplicate release records. Checkout workspaces
should be safe to delete and recreate. If a deploy fails, the service should log the error and return
a non-2xx response so the provider marks delivery as failed.

Secrets must never be logged. Signature comparison must be constant-time or use a library function
that avoids early-exit string comparison.


## Interfaces and Dependencies

Use local source and docs for Haskell dependencies. If adding an HTTP server library or crypto/HMAC
library, first use `mori registry search <package>` and inspect the registered source/docs before
guessing APIs. Candidate existing registry entries include `snoyberg/http-client` for HTTP client
work, but an HTTP server package may need to be added if none is already present.

The service consumes the deploy functions from EP-14 and preview/release functions from EP-15. It
should expose no new user-facing CLI commands unless setup or status requires them.
