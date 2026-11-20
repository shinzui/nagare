---
type: Improvement Request
title: Expose reviewed static-site preview deployment and retirement to CI
description: Let a delegated CI deployer review, apply, observe and retire an isolated static-site preview from retained data, with a versioned public identity and URL.
timestamp: "2026-11-20T18:57:23Z"
generated:
  by: process:codex
  at: "2026-11-20T18:57:23Z"
requestId: IR-50
status: proposed
origin: mori://shinzui/kotei/masterplans/30-preview-nagare-sites-from-pull-requests-and-promote-the-tested-release
acceptanceCriteria:
  - id: AC-1
    statement: A delegated dry run for a rendered StaticSite and an accepted image returns one versioned deploy-preview with the derived preview scope, resolved hostname or HTTPS URL, configuration digest and reviewed image and environment bindings.
    verification: Decode stdout with a public schema for nested and flat host fixtures. Compare the returned route with the reviewed protected route and assert zero provider writes and no production release.
  - id: AC-2
    statement: Saving the same candidate returns a versioned saved-review identifying its scope, directory and digest. The existing versioned apply and scoped status interfaces identify its transaction and convergence.
    verification: On a disposable context save and apply the returned review as its bounded deployer. Verify authenticated HTTPS serves the candidate, production still serves its previous release and source repository, revision and run are present in history.
  - id: AC-3
    statement: A delegated caller can save a scope-bound retirement review from retained data, obtain its public saved-review identity and apply it without executing a site configuration program.
    verification: Retire the exact accepted preview on nested and flat host configurations, including a protected route. Verify the scoped outcome, refusal for a foreign owner and survival of the production and sibling preview scopes. Leave collection to an operator.
  - id: AC-4
    statement: Contract calls use the established JSON, stderr and exit-status conventions, enforce delegation and input checks, and preserve existing human and production interfaces.
    verification: Exercise missing or mismatched stores, a disallowed destination, an unaccepted image, an invalid preview name and an unsupported contract version. Check structured refusals and absence of provider writes. Use failing compiler and build sentinels for create, update and retirement.
  - id: AC-5
    statement: A CLI consumer can implement the lifecycle using released public schemas, samples and documented commands.
    verification: Check generated OpenAPI and samples, decode them in a client fixture and document version availability, binding meanings, host shapes, readiness and the retirement-to-collection handoff in the site guide.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-20T19:00:52Z"
    document_timestamp: "2026-11-20T18:57:23Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.2-astra
    effort: unspecified
    context: Author checked the site parser, preview and retirement drivers, accepted scope ownership, delegation bounds and public contract sample for this request.
---

# Expose reviewed static-site preview deployment and retirement to CI

Requested by `mori://shinzui/kotei/masterplans/30-preview-nagare-sites-from-pull-requests-and-promote-the-tested-release`. A PR should receive a protected URL where a reviewer can exercise the built site. Kotei needs Nagare to identify the exact resource it reviewed and the URL Nagare assigned before Kotei can report the deployment.

## Evidence at v0.24.1

[The site parser](../../cli/nagarectl/app/Nagare/Cli/Parser/Site.hs) enables contract selection for production site deploy and passes `pure Nothing` for preview deploy. [The preview driver](../../cli/nagarectl/app/Nagare/Cli/Commands/SitePreview.hs) already accepts rendered input, checks the image and stores, and saves a reviewed candidate. Its dry run prints a canonical scope. Its delete command loads the site program and uses the nested hostname helper to identify the route. The earlier [production-site contract](expose-versioned-json-for-site-deployment-previews-and-saved-reviews.md) covered the production scope. The [site guide](../user/static-hosting.md) describes deployment, retirement and later collection.

## Requested public interface

Extend the existing command with contract 1 for both review stages. A representative invocation uses operator-provisioned Runtime and Preview ConfigMap and Secret resource IDs. Substitute `--save-plan DIR` for `--dry-run` to save the candidate.

```bash
nagarectl --context CONTEXT site preview deploy --name 42 --rendered rendered.json \
  --skip-build --tag TAG --image-resource IMAGE_ID \
  --preview-env-resource RUNTIME_CONFIG --preview-env-resource RUNTIME_SECRET \
  --preview-env-resource PREVIEW_CONFIG --preview-env-resource PREVIEW_SECRET \
  --source-repository REPO --source REVISION --source-run RUN_URL --dry-run --contract 1
nagarectl --context CONTEXT inventory apply DIR --yes --contract 1
```

Use the public deploy-preview, saved-review, transaction and inventory conventions. Bind the hostname to the reviewed route and expose enough information to compare preview, saved review and accepted state. Keep the existing distinction between a rendered file's byte hash and Nagare's configuration digest. Diagnostics may identify accepted store resources while keeping their contents private.

For retirement, accept the retained rendered site and name, or an exact accepted preview identity through a documented data-only command. Return a saved review which the deployer can verify and apply under its existing ownership bounds. Document how a caller recognizes a previously retired scope after a lost response. Keep physical collection under the existing operator workflow. Nagare owns route derivation, access and inventory. Kotei owns PR events, approval, tested-artifact selection and the separate reviewed production deployment.
