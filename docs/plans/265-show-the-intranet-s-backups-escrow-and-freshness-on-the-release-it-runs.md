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

- [ ] Inventory: the list of every intranet store that holds data, with its kind and namespace. It
  comes from `nagarectl server status` and the context's En tenant list (`NAGARE_EN_TENANTS`). It
  covers `en-db`, `shomei-db`, each `en-<name>-db`, each standalone database, each shared server
  and app database, and any PVC that holds application data. Pass: the list is in the record. Any
  PVC holding application data outside a schedule is reported to the operator as a data-loss risk,
  because volumes are outside the objective by decision D2 (ADR 28).
- [ ] Freshness: `server status` and `doctor` on the intranet show `objective=hourly`, and every
  database's recovery point is graded healthy and younger than one hour. Pass: both outputs are
  saved, and `doctor` exits 0, or every non-OK row is explained.
- [ ] Schedule image: every `nagare-dbbackup-*` and `nagare-appdb-*` CronJob names the pinned
  `google/cloud-sdk` digest (F143), not the tag. Pass: a `kubectl get cronjob` listing with the
  image of each schedule. A schedule still on the tag gets its own database review (F143's row).
  That is a reviewed apply, so it needs the operator's go-ahead.
- [ ] Escrow: each database in the inventory has an escrow file under
  `cluster-secrets/<context>/backup-signing/` in the operator root. `shomei-db` also has its
  key-encryption key file. Each escrow verifies that database's newest scheduled backup with
  `db verify-escrowed-backup` or `db app-database verify-escrowed-backup`. A missing escrow is
  created with `db escrow-signing-key` or `db app-database escrow-signing-key`, then verified.
  Pass: one verify output per database, each naming its recovery point.
- [ ] The record is committed to `mori://tan/tan-ng-labs`, and its commit and path are handed to
  `docs/plans/267-bring-the-readiness-checklist-s-evidence-gate-rules-and-ledger-rows-up-to-the-current-release.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Run it once, from the operator shell, and add no step to the release.
  Rationale: what recurs before node upgrades is decision D2 in the MasterPlan.
  Date: 2026-11-17


## Outcomes & Retrospective

(To be filled at completion.)


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
