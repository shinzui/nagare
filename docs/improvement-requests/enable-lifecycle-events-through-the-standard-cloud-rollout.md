---
type: Improvement Request
title: Enable lifecycle events through the standard cloud rollout
description: Let existing GCP contexts publish lifecycle events and serve them through the protected admin API using released Nagare packages and reviewed bootstrap.
timestamp: "2026-11-23T05:07:33Z"
generated:
  by: process:codex
  at: "2026-11-23T05:07:33Z"
requestId: IR-52
status: proposed
origin: mori://tan/tan-ng-labs/plans/24-show-nagare-change-events-in-the-portal-admin
originPlan: mori://tan/tan-ng-labs/plans/24-show-nagare-change-events-in-the-portal-admin
acceptanceCriteria:
  - id: AC-1
    statement: A saved lifecycle opt-in review round-trips a populated En tenant profile and changes only the requested lifecycle settings.
    verification: Review and apply opt-in on an existing fixture with tenant declarations and both schema fields. Compare the profile fields before and after, and verify arbitrary unknown keys still fail review.
  - id: AC-2
    statement: The reviewed cloud plan uses the same feed prefix as the worker and API, and supplies the runtime permissions required by both identities.
    verification: Check prefix parity for bare and nested inventory roots. On GCP, verify the worker can read inventory and write feed objects, and the API reader can get the feed head, segments and indexes. Verify the worker cannot write inventory or backups, and the API reader cannot list or write state objects. If the runtime sends a billing project, authenticate as the actual worker and confirm it can use the context project without broadening its Storage grants.
  - id: AC-3
    statement: The worker can list and batch-read its source journal using its own read-only inventory transport, and its startup work fits the rollout readiness budget on a journal with realistic history.
    verification: Start and restart the released image on a fixture with at least 12,478 journal entries and multiple historical backup schedules. Measure startup against the reviewed rollout deadline, verify activation keeps its journal checkpoint, and confirm a subsequent inventory transaction produces one event per stable ID.
  - id: AC-4
    statement: An operator can activate the feed on an existing cloud context through the standard reviewed workflow and read a new event with the existing protected API identity.
    verification: Enable publication with delivery off in a disposable cloud context using the released CLI and images. Inspect the reviewed changes, apply them, and deploy an application. Compare the published app.deployed event from the protected list and detail endpoints by ID, transaction, resource and release.
---

# Enable lifecycle events through the standard cloud rollout

The Labs portal successfully read its own deployment event on Nagare v0.27.0. Getting there required a patched operator CLI, a corrected Pulumi payload, two manual IAM changes and a dedicated worker image. An existing GCP context should be able to run the same rollout using the released CLI and images, the reviewed bootstrap workflow and the documented worker key procedure.

## What happened in Labs

- The context review rejected recognized En tenant settings. Its allowlist came from `renderTargetEnv`, which omitted `NAGARE_EN_TENANTS` and both tenant schema declarations. The patched renderer preserved them through review and apply.
- The cloud plan granted writes on `inventory-lifecycle/v1/` for the bare `inventory` root. The worker and API used `lifecycle/v1/`. The worker's GCS requests also supplied a billing project, so they failed with 403 until its service account could use the context project. Labs used a custom role with only `serviceusage.services.use`.
- The protected API returned `503 store_unavailable` until its storage identity received conditional object-read access to the feed. Labs used `storage.objects.get` scoped to the feed head, segments, position indexes and ID indexes. The portal kept its existing API credentials.
- The worker reused the admin API's inventory transport, which refuses journal listing and batch reads. Once the worker used its own read-only inventory transport, startup still exceeded the probe budget while repeatedly loading historical reviews and scope members for backup schedules. The final image started liveness before activation, held readiness until activation finished and reused verified review documents and relevant schedule revisions. It became ready in under three minutes on a journal with 12,478 entries.

## Rollout evidence

The originating plan records the failed stages, approved changes and live comparison. Its compatibility patch is in `mori://tan/tan-ng-labs/repos/tan-ng-labs`, project-relative `operator/intranet/nagare-lifecycle-v0.27.0.patch` (file-level URI pending). Use it as evidence for the fixes. Verify the reviewed cloud rollout with the standard packages, including the native IAM denials tracked as F154 in [the audit findings](../audits/mp23-findings.md). The Labs rollout kept webhook delivery off.
