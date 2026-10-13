---
type: Improvement Request
title: Preflight private access credentials and preserve actionable observation errors
description: Name missing access credentials before starting a reviewed transaction and retain safe adapter causes in planning diagnostics.
generated:
  by: process:openai-codex
  at: "2026-10-13T13:08:02Z"
requestId: IR-27
status: accepted
targetPlan: docs/plans/190-refuse-a-missing-access-key-before-admission-and-keep-observation-causes-in-plan-errors.md
origin: mori://shinzui/keiro-runtime-docs/plans/49-deploy-the-docs-to-the-labs-intranet-with-local-bun-builds
acceptanceCriteria:
  - id: AC-1
    statement: Missing private access credentials produce a specific actionable refusal before a transaction or executor claim is created.
    verification: Exercise reviewed access planning and applying with no key, and assert unchanged inventory plus a message naming NAGARE_EN_API_KEY.
  - id: AC-2
    statement: Safe observation failure causes remain visible in human and JSON diagnostics.
    verification: Cover missing credentials, private transport failure, and provider refusal with bounded diagnostics and distinct causes.
  - id: AC-3
    statement: Recovery guidance preserves the saved review and never exposes or persists the private key.
    verification: Resume a saved access transaction after supplying the key, with sentinel-secret redaction checks on outputs, reviews, and journal evidence.
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-10-13T13:08:02Z"
    document_timestamp: "2026-10-13T13:08:02Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Author review of classification, source evidence, reproduction or acceptance,
      and safety boundaries; no independent verification attestation is claimed.
---

# Preflight private access credentials and preserve actionable observation errors

The protected docs deployment used Nagare v0.6.2. Planning without the private
credential returned `observation-unavailable`, with the generic message
`required resource observation is unavailable`. After planning with the key,
an apply outside that environment created a transaction and stopped safely:

```text
KnownNoEffect "adapter preflight refused: reviewed access requires private NAGARE_EN_API_KEY"
```

Supplying the key and resuming the same transaction converged. The operator's
missing environment was the trigger; authorization correctly failed closed.
The requested improvement is earlier, more actionable feedback.

`cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs` requires the private key
while opening its own context-scoped port-forward. The planner's
`cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs` discards the
`ObservationUnavailable` reason when constructing its generic PlanError;
that behavior remains in the current source. [The access guide](../user/access.md)
already documents carrying the key across planning, apply, recovery, and status.

Preflight the explicit private credential requirement before transaction
acceptance and retain bounded, redacted provider causes. Give an exact safe
setup or recovery hint. Do not silently load a cluster admin credential, weaken
the guard, include bearer material in saved reviews, or serialize credentials
into public configuration. Existing reviews must remain resumable after the
environment is repaired.
