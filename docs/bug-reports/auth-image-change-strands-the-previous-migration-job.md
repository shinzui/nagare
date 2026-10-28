---
type: Bug Report
title: Changing the Shomei or En image strands the previous migration Job and blocks every platform plan
description: The auth component names each migration Job after a digest of its image, so a new Shomei or En image pin drops the accepted Job from the desired inventory, and the platform planner refuses with retirement-required because no lifecycle decision can retire one member of the auth scope.
generated:
  by: process:claude-code
  at: "2026-10-28T19:20:00Z"
bugId: BUG-9
status: fixed
fixedVersion: 0.11.0
resolution: >-
  Fixed on master by commit 1db2be79. The planner's supersededMigrationJobs
  (cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs) selects a stateless
  member that an accepted SchemaMigration operation affected and that a
  ReplaceScope no longer declares; such a member needs no lifecycle decision and
  receives a retention proof, so it is retained, never deleted. Any other
  removed member still refuses with retirement-required. Regression tests in
  cli/nagarectl/test/InventoryContributionRetirementSpec.hs fail without the fix
  with the intranet's exact error. Released in 0.11.0 (signed tag on
  5ccf0026). On the intranet the 0.11.0 transition then rolled Shomei to a new
  image: shomei-migrate-77aee8be3bf4 ran migration 0037, and the superseded
  shomei-migrate-319565fb220f was retained, not deleted.
severity: unusable
origin: mori://tan/tan-ng-labs/plans/12-keep-labs-sign-ins-alive-and-add-a-remember-me-option
affects: mori://shinzui/nagare/packages/nagarectl
affectedVersion: 0.11.0
environment: >-
  tan-ng-labs intranet context during the 0.10.0 to 0.11.0 candidate transition
  (candidate f9f4503e), with operator/intranet/images.env pinning a newly built
  Shomei image (shomei@sha256:94e65408...) in place of the bootstrap image
  (shomei@sha256:0b88cb6b...) that the context had used since 2026-10-11.
observed: >-
  `just release-candidate 0.11.0` applied transition stage 1 (the host
  activation), then release-intranet refused plan 2 with `retirement-required:
  accepted resource is absent from desired inventory without a lifecycle decision
  (platform:auth/auth/object-c3341b7d10375572f67d63a59147d6c6ff6da160)`. That
  resource is the Job nagare-system/shomei-migrate-319565fb220f. The context is
  left mid-transition (host 0.11.0, cluster 0.10.0) and no platform plan can be
  saved while the new Shomei image is pinned.
expected: >-
  Rebuilding and pinning a Shomei or En image is a supported operator step
  (cluster/bootstrap/nagare-access/README.md, the operator's upgrade runbook), so
  a platform plan with a new image creates the new migration Job, runs it before
  the Deployment rolls, and keeps the previous Job's record without refusing.
reproduction:
  - On any context whose auth component has converged, build a Shomei image whose digest differs from the pinned NAGARE_AUTH_SHOMEI_IMAGE (cluster/bootstrap/auth-images/build-local-image.sh shomei).
  - Pin the new digest in NAGARE_AUTH_SHOMEI_IMAGE.
  - Run `nagarectl platform bootstrap plan --out DIR` (or a transition plan).
  - "Observe `retirement-required` naming the platform:auth object of the old shomei-migrate-<suffix> Job."
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-28T19:20:00Z"
    document_timestamp: "2026-10-28T19:20:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against candidate f9f4503e (Inventory/Components/Auth.hs,
      reviseJob and job) and the live intranet refusal; reproduced once. No
      independent verification attestation is claimed.
---

# Changing the Shomei or En image strands the previous migration Job and blocks every platform plan

**Reported by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/12-keep-labs-sign-ins-alive-and-add-a-remember-me-option`
on the Nagare 0.11.0 candidate (`f9f4503eb4093f089f9bb88b07b0f14926b63999`).


## What happens

The auth component renames each migration Job after the image it runs, so that a new image
runs its migrations in a new Job (Jobs are immutable):

```haskell
-- cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs, reviseJob
let suffix = T.take 12 (digestText (contentDigest (TE.encodeUtf8 image)))
pure (Object (KM.insert "metadata" (Object (KM.insert "name" (String (name <> "-" <> suffix)) metadata)) root))
```

The Job's address, and so its resource ID, carries the same suffix (`job` in the same
module). When the operator pins a new Shomei image, the desired auth scope contains
`shomei-migrate-<new>` and no longer contains `shomei-migrate-<old>`. The planner treats the
missing member as a removal that needs a lifecycle decision, and refuses:

```text
release-intranet: plan 2 refused:
retirement-required: accepted resource is absent from desired inventory without a lifecycle
decision (platform:auth/auth/object-c3341b7d10375572f67d63a59147d6c6ff6da160)
```

```text
$ kubectl get job -n nagare-system -o json | jq ... # resource-id annotation
Job nagare-system/shomei-migrate-319565fb220f platform:auth/auth/object-c3341b7d10375572f67d63a59147d6c6ff6da160
```

No command can make that decision for one member: `inventory retire` retains whole scopes,
and retiring `platform:auth` would retire Shomei, En and nagare-access. The En migration Job
has the same shape.


## Consequences

- Every Shomei or En image change is blocked, including the rebuilds Nagare's own docs ask
  operators to make when a release moves the Shomei or En pin in
  `cli/nagare-access/cabal.project`. 0.11.0 is the first release whose feature depends on a
  new Shomei image, so it is the first to hit this on the intranet; the intranet had kept its
  2026-10-11 Shomei image until now.
- A release candidate stops after the host activation, leaving the context mid-transition
  until the image pin is reverted or Nagare is fixed.


## Expected

A new Shomei or En image yields a plan that creates and runs the new migration Job before the
Deployment rolls, and keeps the previous Job's history as retained (not deleted), with no
operator decision. A completed migration Job is an execution record, not a live dependency.


## Current state on the reporter's cluster

The intranet is healthy mid-transition: host 0.11.0, cluster 0.10.0, protected sites
redirect to the portal and sign-in works. The transition is resumed with the fixed candidate
at the same version, as the release runbook directs for a defect found on the intranet.
