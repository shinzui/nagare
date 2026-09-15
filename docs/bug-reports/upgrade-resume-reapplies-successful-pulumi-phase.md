---
type: Bug Report
title: Resume reapplies an already successful Pulumi phase
description: >-
  Resuming a 0.3.0 transaction after a later host or Kubernetes failure invokes
  Pulumi again even though the reviewed infrastructure phase is recorded as successful.
generated:
  by: process:openai-codex
  at: "2026-09-15T13:52:11Z"
bugId: BUG-4
status: confirmed
severity: degraded
origin: mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use
affects: mori://shinzui/nagare/packages/nagarectl
capability: mori://shinzui/nagare/okf/capabilities/concepts/CAP-19
affectedVersion: 0.3.0
environment: live cloud transaction with Pulumi success followed by host and Kubernetes failures
observed: >-
  Each --apply --resume invocation re-enters Pulumi and performs a preview/update
  cycle over 33 unchanged resources before continuing to the failed later phase.
expected: >-
  The documented resume workflow should recheck and skip a proven successful phase,
  preserving the reviewed plan boundary unless the operator explicitly requests recovery.
reproduction:
  - Apply a reviewed 0.3.0 transaction and let Pulumi complete successfully.
  - Cause the subsequent host or Kubernetes phase to fail.
  - Correct the later failure and invoke platform upgrade --apply --resume for the same transaction.
  - Observe a second Pulumi preview/update despite the recorded pulumi-apply success.
workaround: >-
  Keep Pulumi credentials and the release toolchain available for every resume,
  and verify that the retained reviewed plan and unchanged provider result still match before continuing.
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-15T13:52:11Z"
    document_timestamp: "2026-09-15T13:52:11Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: unspecified
    context: >-
      Reviewed against the transaction journal, two live resume attempts, and the
      implementation postcondition that always marks Pulumi apply unsatisfied.
---

# Resume reapplies an already successful Pulumi phase

The live transaction completed its reviewed Pulumi apply, then failed first in host apply and later
in Kubernetes apply. Both resumes reran a full Pulumi cycle, reporting 33 unchanged resources. The
journal records success, but the resume postcondition for this phase is always false. This extends
recovery time, repeats cloud API exposure, and makes a completed phase depend on provider health and
credentials again.

The fix should persist enough evidence to prove consumption of the exact reviewed plan and skip the
phase when that postcondition holds. Tests should fail independently after Pulumi in host apply,
Kubernetes apply, cluster stamp, and context commit; every resume should make zero further Pulumi
calls. A crash between provider success and journal persistence needs an explicit audited path.
