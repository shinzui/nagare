---
type: Improvement Request
title: Review an existing application image by registry digest
description: Admit an authorized registry manifest into Nagare inventory through a saved review and deploy a rendered application using the accepted digest.
timestamp: "2026-11-23T05:46:41Z"
generated:
  by: process:codex
  at: "2026-11-23T05:46:41Z"
requestId: IR-53
status: proposed
origin: mori://shinzui/kotei
originPlan: mori://shinzui/kotei/plans/185-deploy-a-verified-oci-image-by-digest
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-23T05:46:41Z"
    document_timestamp: "2026-11-23T05:46:41Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.2-astra
    effort: unspecified
    context: Checked the archive requirement in v0.24.5 and v0.27.0 and the reviewed application's accepted image resource against the requested digest path.
acceptanceCriteria:
  - id: AC-1
    statement: A scoped operator can save and apply a review of an existing repository@sha256 reference and retrieve the exact context, resource, repository and digest through versioned inventory output.
    verification: Use an isolated registry and read-only registry credentials. Verify manifest bytes against the requested digest, observe no mutation during preview, then apply the saved review with no archive, push or blob upload.
  - id: AC-2
    statement: Rendered application review, apply and readiness preserve the accepted immutable image identity.
    verification: Move a display tag between review and apply. Inspect the saved review, healthy workload and serving revision, then redeploy the prior accepted digest through a fresh review.
  - id: AC-3
    statement: The provider enforces target authority and refuses unverifiable image inputs before workload mutation.
    verification: Attempt a tag-only input, unauthorized repository, missing manifest and inconsistent digest. Inspect inventory and the workload for unintended changes.
---

# Review an existing application image by registry digest

Kotei's authorized publisher can verify an image already in the target registry. Its separate deployment runner needs to admit that image to Nagare inventory and bind a rendered application review to it. Kotei owns the producer and publication receipts. Nagare owns the saved review, target authorization, inventory transaction and observed deployment. [Consumer request](mori://shinzui/kotei/okf/improvement-requests/concepts/IR-61) and [consumer plan](mori://shinzui/kotei/plans/185-deploy-a-verified-oci-image-by-digest).

In both the consumer pin v0.24.5 and release v0.27.0, `appImagePlanOptsParser` requires a Docker archive and a destination tag. Reviewed app deployment takes a previously accepted image resource. Provide a released, machine-readable path from an external digest to that resource and document how consumers can detect support. [Image-plan parser](../../cli/nagarectl/app/Nagare/Cli/Parser/Application.hs) and [reviewed application deployment](../../cli/nagarectl/app/Nagare/Cli/Commands/Application.hs).
