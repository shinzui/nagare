---
type: Improvement Request
title: Declare release migration hooks without periodic execution
description: Let an application declare a migration that runs only as a reviewed release prerequisite, without also authorizing scheduled database maintenance.
timestamp: "2026-11-13T00:36:39Z"
generated:
  by: process:codex
  at: "2026-11-12T23:40:00Z"
requestId: IR-46
status: proposed
origin: mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application
acceptanceCriteria:
  - id: AC-1
    statement: An aggregate Application can explicitly declare a release-only migration hook whose application deployment runs the hook before serving workloads and whose native resources cannot launch it periodically.
    verification: Render and apply a typed fixture with a maintenance-only Secret reference and inspect the accepted native resources and live cluster; no active CronJob or other periodic trigger may execute the hook.
  - id: AC-2
    statement: Hook failure still prevents serving promotion, successful identical reviewed retries retain the original hook proof, and release-only behavior does not change ordinary scheduled tasks.
    verification: Effect-interpreter tests cover a failed hook, successful release, identical accepted retry and an ordinary scheduled Task; assert workload ordering, execution counts and unchanged scheduled-task behavior.
  - id: AC-3
    statement: Changing an already accepted scheduled migration to release-only retires or suspends its periodic trigger through reviewed inventory ownership, and subsequent application deployment preserves that release-only lifecycle.
    verification: Apply a scheduled fixture, save and apply its release-only transition, and inspect the accepted trigger state; the consumer must not patch or delete an inventory-owned CronJob out of band.
  - id: AC-4
    statement: Typed and rendered application inputs, public review evidence and documentation describe the release-only lifecycle and preserve workload-specific environment isolation.
    verification: Round-trip the declaration through app render and app deploy --rendered, check the public preview and saved review, and prove the hook alone receives its maintenance key with NoManagedEnv.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-12T23:40:00Z"
    document_timestamp: "2026-11-12T23:40:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: Author review against a314e7a9 live native ARM64 inspection and 18a15e93 Task and application rendering; no implementation or independent review is claimed.
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-13T00:36:39Z"
    document_timestamp: "2026-11-13T00:36:39Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: Consumer qualification confirms reviewed task suspension works but the next identical app review restores the original unsuspended CronJob; the restoring review was not applied.
---

# Declare release migration hooks without periodic execution

Requested by `mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`
under `mori://shinzui/kotei/masterplans/26-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare`.

## Consumer evidence

Kotei qualified IR-44's immutable `a314e7a9f9ca4d74b631601d26a8d6cb1675af00`
candidate on its task-owned native ARM64 local context. The migration hook
completed before the server and worker were created, and only the hook received
the maintenance database URL. That consumer proof remains valid.

The same application apply also installed `nagare-task-migrate` as an unsuspended
CronJob with schedule `0 0 * * *` and the maintenance credential. Kotei's repeated
live inspection on 2026-11-12 therefore refuses the hook-only hosting row. A
scheduled migration can modify the database independently of a reviewed release
and its promotion gate.

At Nagare `18a15e93`, `cli/nagare-dsl/src/Nagare/Dsl/Task.hs` requires a schedule
and exposes no release-only or suspended lifecycle. The application driver uses
aggregate tasks as hooks and also retains their scheduled resource. These source
paths are local to this repository. Kotei's sanitized live evidence belongs to
`mori://shinzui/kotei`, project-relative
`docs/plans/evidence/135/live-hosting-matrix.json` (artifact-level URI pending).
The harness is in that project at `scripts/test-kotei-nagare-hosting.py`
(artifact-level URI pending).

## Existing operational suspension and the remaining gap

Nagare already supports reviewed suspension through the first `task delete APP TASK
--save-plan DIR` stage. Kotei qualified that existing path on 2026-11-13 UTC instead
of assuming an upstream feature was necessary. The review updated only
`application:kotei/migrate/cronjob`; transaction
`tx-4878d8c889e0b3575c9c29011d7734a192dd33c684a714633249716e450d0d4a`
converged, and the live CronJob has `suspend=true`. Kotei's current baseline
inspection passes with that operational suspension.

The next app preview and saved review, using the same accepted release inputs,
plan `UpdateResource` on that CronJob and replace the suspended native object
`08cc873ed4bb81aaf5f59f1638d6c579f08e3967893ff7b0069bcb80e7aae18b`
with the original unsuspended object
`9440efdc58544e2e467845cce17acaa53540d12a230720e36e6a306674932ee5`.
The operational suspension override disappears from the next desired application
scope. The consumer did not apply that restoring review; its fixture remains
suspended. Operational suspension exists; the demonstrated gap is preserving
release-only lifecycle through application deployment.

The full sanitized proof belongs to `mori://shinzui/kotei`, project-relative
`docs/plans/evidence/135/reviewed-migration-suspension.json` (artifact-level URI pending).

## Requested outcome and boundary

Provide a supported declaration for a migration that runs only as a release
prerequisite. Either a dedicated hook lifecycle or an explicitly suspended
scheduled resource can meet the outcome if its typed contract, rendering and
reviewed transition make periodic execution impossible. Preserve existing
scheduled task semantics; an impossible cron date or an untracked kubectl patch
is not a consumer workaround.

Kotei owns consuming and qualifying the resulting immutable candidate, its own
migration/provisioning stages, retained-content handoff and upgrade/recovery
rehearsals. This request does not implement Kotei hosting or reopen IR-44's
accepted secret isolation. Static-site contract work remains independent in
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-45`.
