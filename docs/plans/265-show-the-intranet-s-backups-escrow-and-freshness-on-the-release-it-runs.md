---
id: 265
slug: show-the-intranet-s-backups-escrow-and-freshness-on-the-release-it-runs
title: "Show the intranet's backups, escrow and freshness on the release it runs"
kind: exec-plan
created_at: 2026-11-18T02:09:52Z
master_plan: "docs/masterplans/36-finish-and-keep-current-the-production-readiness-checklist.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-18T02:09:52Z
---

# Show the intranet's backups, escrow and freshness on the release it runs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

The production readiness checklist's data-protection boxes were proven on the disposable context
`mp23-c3j` in October. This plan shows the same boxes on the real intranet, on the release it runs
(v0.21.0 as of 2026-11-17). Every database runs at the `hourly` objective with a fresh off-cluster
backup. Every backup signing key is escrowed, and the escrow verifies that database's newest backup
with only the key file and the bucket. Every schedule runs the pinned backup image. Afterwards the
operator can point at one dated record, not at a drill on another context.

Needs the operator's go-ahead before any step, because it reads the intranet (decision D1 in
`docs/masterplans/36-finish-and-keep-current-the-production-readiness-checklist.md`).


## Progress

Evidence for every item: `mori://tan/tan-ng-labs` commit `936b66f`, `docs/evidence/2026-11-18-data-protection/`.

- [x] (2026-11-18) Inventory: there are eight active databases. The platform has `en-db`, `en-mori-db`
  (the only declared En tenant) and `shomei-db`. The servers are `labs-postgres` and
  `labs-clickhouse`. The app databases are `kansoku-pg`, `kansoku-ch` and `mori-registry-pg`. Two
  retired isolation probes have suspended schedules. There are no application PVCs; the only
  non-database PVCs hold logs, metrics and traces (`pvcs.txt`). No data sits outside the objective.
- [x] (2026-11-18) Freshness: `server status` exits 0, and `doctor` exits 0 with 0 failed and 3
  warnings. Every active database is `healthy; objective=hourly`, aged 60–940 s. The warnings:
  - `kansoku-pg` and `kansoku-ch` each have one accepted point past policy;
  - `backup litestream` is UNKNOWN, which is expected because no Litestream app runs.
- [x] (2026-11-18) Schedule image: every active `nagare-dbbackup-*` and `nagare-appdb-*` CronJob names
  `google/cloud-sdk:slim@sha256:c70885ba…`. Only the two suspended probes name the tag
  (`cronjobs.txt`). F143 holds on the intranet.
- [x] (2026-11-18) Escrow: `en-mori-db` and `mori-registry-pg` had no escrow, and both were escrowed.
  Every active database's escrow then verified its newest scheduled backup (02:30 UTC runs) with
  only the key file and the bucket, 8 of 8 exit 0 (`verify.txt`). `shomei-db`'s key-encryption key
  file is present.
- [x] (2026-11-18) The record is committed to `mori://tan/tan-ng-labs` (`936b66f`) and handed to EP-267.


## Surprises & Discoveries

- Two databases created after the last escrow pass had no escrow: the En tenant `en-mori-db`
  (v0.21.0, 2026-11-14) and the app database `mori-registry-pg`. Losing the cluster would have left
  their backups unverifiable through review. This is F145's "no check enforces it", seen again.
  Both are escrowed and verified. Evidence: `verify.txt`.


## Decision Log

- Decision: Run it once, from the operator shell, and add no step to the release.
  Rationale: what recurs before node upgrades is decision D2 in the MasterPlan.
  Date: 2026-11-17


## Outcomes & Retrospective

On v0.21.0 the intranet meets section 2's objective, escrow and one-hour boxes. Every active
database is hourly, fresh and on the pinned backup image. Every escrow verifies the newest backup
from the bucket alone. No application data is outside a schedule. Two databases were unescrowed
until this check. That argues for the enforcement left open in MasterPlan 36's decision D4. Left
for the operator: F132's first prune of `kansoku-pg` and `kansoku-ch`. It needs their pending runs
ingested first (`db app-database backup-receipts NAME --all`), and the prune itself is a reviewed
deletion of backup objects. Nothing moves to an ADR.


## Context and Orientation

- The checklist: `docs/releases/production-readiness-checklist.md`, section 2.
- The objective: [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md).
  It sets hourly recovery points and a four-hour rebuild, with backups every 15 minutes to a
  regional GCS bucket.
- App databases on a shared server: [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md).
- Escrow: `docs/user/backups-and-disaster-recovery.md`, "Escrow the signing key off the cluster".
  The escrow reads the live key, binds it to the Secret, StatefulSet and PVC UIDs, and writes a
  sops file. It refuses to overwrite a different key. `verify-escrowed-backup` needs only the
  escrow and the bucket.
- Findings: F143, F145, F146 and F132 in `docs/audits/mp23-findings.md`.
- The operator shell: commands run under `direnv exec` in the operator repository
  `mori://tan/tan-ng-labs`, whose `.envrc` loads the intranet context. That repository's
  `operations.md` is its runbook.
- No ADR beyond those above applies.


## Plan of Work

Do the five Progress items in order, from the operator shell. Nothing here changes the cluster
except an F143 schedule review, if one is needed, and that waits for its own go-ahead.


## Concrete Steps

Run each command from the operator repository's shell (`direnv exec <operator-repo> <command>`):

```bash
nagarectl server status
nagarectl doctor; echo "doctor exit $?"
kubectl get cronjob -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IMAGE:.spec.jobTemplate.spec.template.spec.initContainers[*].image'
nagarectl db verify-escrowed-backup en-db -n nagare-system --backup-id JOB_UID
nagarectl db app-database verify-escrowed-backup kansoku-pg --backup-id JOB_UID
```

Take `JOB_UID` for each database from its newest receipt, which `nagarectl db backup-receipts NAME`
lists, or `nagarectl db app-database backup-receipts NAME` for an app database (F109: platform
databases need `-n nagare-system`). If the CronJob image path
differs, read one CronJob's YAML and adjust the column.


## Validation and Acceptance

Accepted when every Progress item passes and the record in the operator repository holds every
command's output. If a database cannot be verified, it is a data-loss risk: fix it in place and say
so in the record.


## Idempotence and Recovery

Every read can be repeated. `escrow-signing-key` refuses to overwrite a different key, and running
it again on the same key is a no-op.


## Interfaces and Dependencies

Uses the released v0.21.0 `nagarectl` the intranet runs. It has no prerequisite plan.
