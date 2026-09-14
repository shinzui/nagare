---
type: Improvement Request
title: Check the Application Default Credentials account and quota project against the context
description: Pulumi authenticates with ADC, whose quota project can name a different, even production, project; neither init's preflight nor the context guard looks at ADC at all.
timestamp: "2026-09-14T13:11:22Z"
generated:
  by: process:claude-code
  at: "2026-09-13T23:42:08Z"
requestId: IR-12
status: completed
acceptedAt: "2026-09-14T04:26:09Z"
completedAt: "2026-09-14T13:11:22Z"
resolution: "ExecPlan 135 added token-safe ADC discovery with explicit environment precedence to initialization and every cloud project guard before Pulumi. Missing, invalid, unreadable, or foreign-quota credentials refuse with safe structured evidence and the exact quota-project repair; absent or mismatched principal evidence is visible as a warning. GCP onboarding and context documentation now explains ADC login, quota attribution, and context switching. Fixture, policy, redaction, command-order, and clone-free packaged tests pass as part of the 505-test focused gate. ADR 9 records the durable credential boundary."
targetPlan: docs/plans/135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md
origin: mori://shinzui/nagare
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-14T14:45:36Z"
    document_timestamp: "2026-09-14T13:11:22Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: high
    context: >-
      Audited the request against ExecPlan 135 and MasterPlan 22 completion evidence
      plus the current ADC discovery, quota policy, command ordering, redaction,
      fixtures, documentation, and ADR surfaces; the completed status and Nagare fit remain accurate.
verified:
  by: process:openai-codex
  at: "2026-09-14T14:45:36Z"
---

# Improvement Request: check the ADC account and quota project against the context

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.1`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by
[ExecPlan 135](../plans/135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md); the durable
credential boundary is recorded in
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md).
**Created:** 2026-09-13.


## Why

IR-2 confined nagare to the context's project by checking three project sources: the stack's
`gcp:project`, the ambient `CLOUDSDK_CORE_PROJECT`, and gcloud's configured project. A fourth
source was left out, and it is the one Pulumi actually uses. Pulumi's Google provider authenticates
with Application Default Credentials, and client libraries send the ADC file's `quota_project_id`
as the quota and billing project on API calls.

On the `tan-ng-labs` rollout, `~/.config/gcloud/application_default_credentials.json` carried
`quota_project_id: tan-ng`, a production project, left over from earlier work. Every check nagare runs
passed. The labs stack's API usage would have been charged against `tan-ng`'s quotas, and the call
would have failed outright on a machine whose ADC account lacks `serviceusage.services.use` there. It
does not mutate the other project, but it is a foreign project in the request path of every Pulumi
call. Following nagare's documented order (ADC login, then `gcloud config set project`) does not
change it, because `application-default login` picks its quota project at login time. The ADC
*account* is likewise never compared with the gcloud account the IAM preflight checked.


## What is missing

- `runPreflight` (`cli/nagarectl/src/Nagare/Init.hs:263-300`) checks only `gcloud auth list` and
  the project IAM policy of that account.
- `projectGuardVerdict` (`cli/nagarectl/src/Nagare/Ops/ContextGuard.hs:63`) takes the stack, ambient
  and configured projects only.
- `docs/user/gcp-prerequisites.md:30-45` explains ADC login but not its quota project.


## Requested change

- In `init`'s preflight and in `nagarectl context guard`, read the ADC file (respecting
  `GOOGLE_APPLICATION_CREDENTIALS` and `CLOUDSDK_CONFIG`). Refuse, or at minimum warn loudly, when
  `quota_project_id` is set and differs from the context's project, with the fix
  `gcloud auth application-default set-quota-project <project>`.
- Report the ADC account and warn when it differs from gcloud's active account, since the IAM
  preflight validated the latter.
- Document the quota-project step in `docs/user/gcp-prerequisites.md` and the multi-cluster guide,
  since switching contexts does not switch ADC.


## Required verification

- Unit tests of the verdict with a matching, a differing and an absent ADC quota project.
- A hermetic test with a fixture ADC file proving the guard names the fix.


## Acceptance

No Pulumi operation runs while ADC attributes it to a project other than the active context's without
the operator being told, and the documented setup leaves ADC pointed at the context's project.


## Non-goals

Managing credentials for the operator, or supporting service-account impersonation flows.
