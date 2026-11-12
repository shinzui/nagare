---
type: Improvement Request
title: Expose versioned JSON for site deployment previews and saved reviews
description: Let a deployment client verify a rendered static site's preview and saved review through the public contract before applying it, without parsing human output or Nagare's private review files.
timestamp: "2026-11-12T22:40:00Z"
generated:
  by: process:codex
  at: "2026-11-12T22:40:00Z"
requestId: IR-45
status: proposed
origin: mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer
acceptanceCriteria:
  - id: AC-1
    statement: site deploy accepts --contract 1 with --rendered, --skip-build, an accepted --image-resource and --dry-run, emitting exactly one public DeployPreview document whose target scopes and configuration digest identify the proposed site deployment.
    verification: An interpreter fixture previews a rendered StaticSite using a prepublished image; validate stdout against docs/api/openapi.json and assert document deploy-preview, contractVersion 1, the expected scopes and configuration digest, and no provider mutation.
  - id: AC-2
    statement: The corresponding --save-plan DIR invocation with --contract 1 emits exactly one public SavedReview document, including the saved review directory and digest, and inventory apply can consume that exact review through its existing contract.
    verification: Save the same fixture's review, validate stdout as SavedReview, and apply the returned review directory with inventory apply --contract 1; the accepted digest, scopes and config digest must agree with the public response and the prior preview.
  - id: AC-3
    statement: The rendered path evaluates no repository program and builds or packages no image, and preserves the existing delegation and source repository, commit and run attribution.
    verification: Use a sentinel config program and build command that fail if executed, preview and save with --rendered and --skip-build under a bounded deployer, and confirm the apply journal retains --source-repository, --source and --source-run; an out-of-delegation target must be refused before mutation.
  - id: AC-4
    statement: Contract mode follows the existing app deployment JSON, stderr and exit-status conventions, including structured refusals and unsupported contract versions, while invocations without --contract retain their human behavior.
    verification: Parser and effect-interpreter tests cover success, refusal, unsupported versions and the legacy invocation, assert one JSON document on contract stdout with progress on stderr, and prove no mutation on rejected requests.
  - id: AC-5
    statement: The public API schemas, golden samples and CLI documentation describe the site preview and saved-review producers so a consumer can use the existing DeployPreview and SavedReview types without reading private review storage.
    verification: Regenerate and check docs/api/openapi.json and samples, update docs/api/README.md and the static hosting guide, and run a small client fixture that decodes both responses and passes the selected review to inventory apply using only public fields.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-12T22:40:00Z"
    document_timestamp: "2026-11-12T22:40:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: Author review against v0.20.0 and Nagare 85b7b492's site parser, option record and reviewed site driver, plus Kotei Plan 148 D2; this does not attest implementation or independent review.
---

# Expose versioned JSON for site deployment previews and saved reviews

Requested by `mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer`
under `mori://shinzui/kotei/masterplans/26-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare`.

## Problem and evidence

Kotei's credential-free build renders configuration and publishes an image archive.
Its isolated deploy runner publishes the image, obtains a deployment preview,
verifies the saved review identity and applies that review. For applications,
Nagare already exposes `DeployPreview` and `SavedReview` through contract 1.
Those responses let Kotei bind context, scopes and configuration digest to its
own operation receipt before mutation.

At released v0.20.0 (`f336bf6ce0d854a59a74ad6d8a3b34873f32c9e6`), and at
`85b7b492`, the site command accepts rendered input and a prepublished image, but
cannot produce these two public contract responses:

- `cli/nagarectl/app/Nagare/Cli/Parser/Site.hs`, `siteDeployOptsParser`, has no
  contract option. The contract options elsewhere in that module belong to
  other site commands.
- `cli/nagarectl/app/Nagare/Cli/Options/Site.hs`, `SiteDeployOpts`, has no contract
  selection field.
- `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs` prints the canonical resource
  scope for the production dry run. A saved site review already applies through
  `inventory apply --contract 1`, but the client lacks a public typed response
  describing the review it is about to apply.

Kotei's static-site deliverable D2 is therefore incomplete even though Nagare's
[rendered deployment plan](../plans/249-deploy-apps-and-static-sites-from-a-rendered-configuration-without-running-the-repository-s-program.md)
is complete. The rendered-input capability and the structured review-output
capability are separate contracts.

## Requested interface

Support these two stages with the existing public document types and conventions:

```bash
nagarectl --context CONTEXT site deploy --rendered rendered.json --skip-build \
  --tag TAG --image-resource RESOURCE --dry-run --contract 1

nagarectl --context CONTEXT site deploy --rendered rendered.json --skip-build \
  --tag TAG --image-resource RESOURCE --save-plan REVIEW_DIR --contract 1

nagarectl --context CONTEXT inventory apply REVIEW_DIR --yes --contract 1
```

Use the same source attribution flags and delegation checks the command already
supports. Preview and saving a review must not deploy the workload; applying the
selected saved review remains the mutation boundary. Save-plan may write its
review artifacts, as it does for an application.

Reuse `DeployPreview`, `SavedReview`, their contract discriminators and their
digest meanings where applicable. If a site needs an additional public field,
document and test it under the existing contract's versioning rules. A client
must not need to parse human progress or inspect the review directory's private
layout to establish review identity.

## Scope and handoff

The required consumer case is a rendered StaticSite with an already accepted
image. Preserve the existing human command and other site's deployment behavior.
This request adds no image builder, credential issuance, site kind, access model,
preview-environment command or rollback interface. It does not reopen the
rendered-input implementation or require a hosted Kotei for Nagare's acceptance
fixture.

Kotei owns consuming the contract in its site adapter and proving the complete
hosted workflow. Kotei's baseline server/worker/migration hosting is separately
tracked by [IR-44](scope-app-secrets-to-the-workloads-that-reference-them.md) and
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`;
this site request must not hold up that baseline work.
