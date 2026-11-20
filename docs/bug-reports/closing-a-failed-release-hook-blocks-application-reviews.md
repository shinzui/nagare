---
type: Bug Report
title: Closing a failed release hook blocks subsequent application reviews
description: After a failed migration hook is closed as terminal partial, Nagare refuses subsequent application reviews because a never-started operation from the closed review has no bound Job.
generated:
  by: process:codex
  at: "2026-11-18T22:00:00Z"
bugId: BUG-10
status: fixed
fixedVersion: 0.24.0
resolution: >-
  Fixed on master by commit a20a5203. The planner's scopeDeclared
  (cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs) walked every scope and
  planned each unproven declared operation that named any selected member, so
  the data a closed release's hook declared, shared with every later hook,
  re-planned that hook in an unrelated review, whose Job the review never
  bound. A PreDeployHook operation is now planned only through a selected
  member its own scope owns (its Job). Close and the adapter are unchanged. The
  model-world test "a closed failed hook does not block later reviews (BUG-10)"
  in cli/nagarectl/test/ReleaseOnlyHookWorldSpec.hs fails without the fix with
  the reported PrepareRefused for all three follow-ups (corrected release,
  rollback, another application) and with it converges each, keeps the failed
  Job and leaves the prior converged revision unchanged until the successor
  converges. Kotei confirms natively by rerunning its rehearsal on kotei-mp26
  against a20a5203; a context holding a closed hook scope needs no repair.
severity: unusable
origin: mori://shinzui/kotei/okf/friction-log/concepts/FRIC-80
affects: mori://shinzui/nagare/packages/nagarectl
affectedVersion: "0.23.0"
environment: >-
  nagarectl v0.23.0 at 2e8801a49ab27658d72f12805a18cfbfdd62ce86 on Darwin ARM64,
  targeting the disposable kotei-mp26 k3d context on ARM64 Linux. Its installed
  platform reported v0.18.0. The Kotei application had a ready release and a
  ReleaseOnly migration hook with an accepted PostgreSQL PVC as its declared effect.
observed: >-
  A candidate hook exited nonzero after queue provisioning. Apply returned
  ambiguous. Inventory close released the transaction, kept the desired app
  scope, and preserved the prior converged revision. Saving reviews for a
  corrected release, the prior retained image, and a fresh app in the same
  context all returned PrepareRefused for operation op-5064c6f9360d407c57be48e7
  with "Kubernetes declared operation must name exactly one bound Job".
expected: >-
  Once the failed release is closed and the context is idle, a new review can
  replace the unconverged desired application with a corrected release or the
  retained prior release. A fresh application's review can proceed without
  binding the previous application's failed hook. The failed release remains
  in history and its hook effects stay unaccepted.
reproduction:
  - On an initialized local context, converge an application with a ReleaseOnly pre-deploy task and an explicit hook-affects database binding.
  - Save and apply a second release whose migration hook exits nonzero after a successful provisioning stage. Observe the named Job reach Failed and inventory apply return ambiguous.
  - Close that transaction with the exact review digest. Verify the prior workloads remain ready and inventory status has no active transaction.
  - Request a saved app deploy review for a corrected release with a new hook identity. Repeat with the prior retained image and with a fresh application in the context.
  - All three requests refuse the same never-started operation from the closed review. The corrected preview names a different hook scope.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-18T22:00:00Z"
    document_timestamp: "2026-11-18T22:00:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.2-sol
    effort: unspecified
    context: >-
      Author review matched the retained native Job, close transcript, subsequent
      contract refusals and previous release observation from the Kotei fixture.
---

# Closing a failed release hook blocks subsequent application reviews

## Reproduction details

Kotei's Plan 135 rehearsal first converged an additive schema upgrade. The
next release completed migration and queue provisioning, then intentionally
failed privilege apply. A fixture PostgreSQL event trigger raised on
`ALTER SCHEMA`. The release hook Job `nagare-task-migrate-hook-a7bb40ad209c`
failed and the candidate server and worker changes never started. The healthy
release continued serving.

Close used the digest from the stopped review.

```bash
review=ed6b4437d4814f590601071790c0055c581956d989acfe1ab0d02281d9b4d635
nagarectl --context kotei-mp26 inventory close "tx-$review" --review "$review"
nagarectl --context kotei-mp26 inventory status --scope application:kotei --contract 1
```

Close classified the Job as terminal partial and kept the desired application
scope unconverged. The previous converged revision remained generation 10 at
`d9087ddd3ca93700315b470d6e995b6cdfb39ef47462e5a022fd74f22fa501bd`.
`activeTransaction` was null.

The next corrected `app deploy --dry-run --json --contract 1` named
`standalone:app-hook-aebb0d978947cd40e5c76dba4759ae10de459fe5`. Saving a review
from the same inputs returned this error.

```text
PrepareRefused op-5064c6f9360d407c57be48e7:
Kubernetes declared operation must name exactly one bound Job
```

The operation ID belongs to the closed release's never-started
`RunDeclaredOperation` for
`standalone:app-hook-0016057314454435e6f7bf8e719818841633a199/run/job`
and the affected database PVC. Reviews for the prior retained image and a fresh
application in the same context returned the identical operation ID and error.
Image publication and a separate runtime Secret review still converged.

## Acceptance evidence

A regression should close a failed per-release application hook, then prepare
both a corrected release and a rollback to the previous image. A review of a
fresh application in the context should prepare too. Verify the prior healthy
release retains its converged revision until an eligible successor converges.
Retain the failed Job and its transaction history.

The preserved rehearsal belongs to
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`.
Its sanitized transcript is in `mori://shinzui/kotei`, project-relative
`docs/plans/evidence/135/additive-migration-and-recovery-v023.json`
(artifact-level URI pending). The consumer tracks the blocker in
`mori://shinzui/kotei/okf/friction-log/concepts/FRIC-80`.
