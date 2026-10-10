---
type: Research Document
title: Established backup tooling beneath Nagare's journal, scored for the workplace intranet
description: Desk evaluation of K8up/restic, Velero and CloudNativePG/Barman beneath Nagare's retained inventory and journal, with partial K8up prototype evidence, scored against UC-3 and ADR 28; recommends keeping Nagare's native backup path for every boundary in scope.
generated:
  by: claude-code/claude-opus-5-5
  at: "2026-10-10T03:50:00Z"
researchId: RES-6
status: complete
supersedes: RES-3
scope: >-
  The finite boundaries of EP-163 (cross-tool identity/review/history, PostgreSQL backup and recovery, volume and
  application backups, Redis/ClickHouse backups, project direction, Kubernetes apply, release evidence) at repository
  revision d8ebc7f4, scored against UC-3's features and ADR 28. Candidate facts come from upstream release tags,
  repository metadata and documentation read on 2026-10-09. K8up v2.16.0 was partially prototyped on a disposable k3d
  cluster that ran outside the cp3 claim protocol and was deleted; its retention step did not complete. No
  CloudNativePG, Velero or kapp prototype ran. No cloud context, GCS bucket or Nagare context was read or changed.
relatedPlans:
  - mori://shinzui/nagare/plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers
  - mori://shinzui/nagare/masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas
  - mori://shinzui/nagare/plans/183-close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild
relatedDecisions:
  - docs/adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md
sources:
  - id: uc3
    resource: ../use-cases/003-operate-nagare-as-a-team-run-intranet-paas.md
    title: UC-3, operate Nagare as a workplace intranet PaaS
  - id: adr28
    resource: ../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md
    title: ADR 28, single node, hourly recovery points, four-hour rebuild
  - id: res3
    resource: managed-resource-inventory-scope-and-tooling-overlap.md
    title: RES-3, first-pass overlap survey (superseded by this record)
  - id: spike
    resource: ../spikes/mp24-tooling-evaluation/README.md
    title: EP-163 prototype record, drivers and evidence (K8up partial, CloudNativePG unrun)
  - id: k8up-releases
    resource: https://github.com/k8up-io/k8up/releases
    title: K8up releases (v2.16.0 and chart 4.10.0, 2026-07-17)
  - id: k8up-governance
    resource: https://github.com/k8up-io/k8up/blob/master/GOVERNANCE.md
    title: K8up governance
  - id: k8up-security
    resource: https://github.com/k8up-io/k8up/blob/master/SECURITY.md
    title: K8up security policy (fixes on the latest release only)
  - id: k8up-cncf
    resource: https://www.cncf.io/projects/k8up/
    title: CNCF project page for K8up (Sandbox since 2021-11-16)
  - id: k8up-restore
    resource: https://docs.k8up.io/k8up/2.16/how-tos/restore.html
    title: K8up 2.16 restore how-to
  - id: k8up-backup
    resource: https://docs.k8up.io/k8up/2.16/how-tos/backup.html
    title: K8up 2.16 backup how-to
  - id: restic-releases
    resource: https://github.com/restic/restic/releases
    title: restic releases (v0.19.1, 2026-07-05)
  - id: velero-releases
    resource: https://github.com/velero-io/velero/releases
    title: Velero releases (v1.18.4, 2026-09-28)
  - id: velero-maintainers
    resource: https://github.com/velero-io/velero/blob/main/MAINTAINERS.md
    title: Velero maintainers and affiliations
  - id: velero-cncf-blog
    resource: https://velero.io/blog/velero-joins-cncf-sandbox/
    title: Velero joins the CNCF Sandbox
  - id: velero-sandbox-issue
    resource: https://github.com/cncf/sandbox/issues/457
    title: CNCF Sandbox application for Velero (accepted 2026-03-11)
  - id: velero-fsb
    resource: https://velero.io/docs/v1.18/file-system-backup/
    title: Velero 1.18 file system backup (beta; restic path removed in 1.19)
  - id: velero-hooks
    resource: https://velero.io/docs/v1.18/backup-hooks/
    title: Velero backup hooks
  - id: velero-restore
    resource: https://velero.io/docs/v1.18/restore-reference/
    title: Velero restore reference
  - id: cnpg-releases
    resource: https://github.com/cloudnative-pg/cloudnative-pg/releases
    title: CloudNativePG releases (v1.30.1, 2026-09-23)
  - id: cnpg-supported
    resource: https://cloudnative-pg.io/docs/devel/supported_releases
    title: CloudNativePG supported releases policy
  - id: cnpg-cncf
    resource: https://www.cncf.io/projects/cloudnativepg/
    title: CNCF project page for CloudNativePG
  - id: barman-plugin-releases
    resource: https://github.com/cloudnative-pg/plugin-barman-cloud/releases
    title: barman-cloud plugin releases (v0.15.1, 2026-09-30)
  - id: barman-plugin-install
    resource: https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/
    title: barman-cloud plugin installation (requires cert-manager, CNPG 1.26+)
  - id: barman-plugin-retention
    resource: https://cloudnative-pg.io/plugin-barman-cloud/docs/retention/
    title: barman-cloud plugin retention policies
  - id: barman-plugin-migration
    resource: https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/
    title: Migrating from in-tree Barman Cloud (deprecated since CNPG 1.26)
---

# Established backup tooling beneath Nagare's journal, scored for the workplace intranet

Evidence checked: 2026-10-09. This record answers EP-163. It supersedes
[RES-3](managed-resource-inventory-scope-and-tooling-overlap.md), whose overlap list named
candidates without evaluating them. RES-3's findings stand as written; this record replaces only
its open question with an evaluation.

> **This is a recommendation, not an adoption.** The operator accepts or rejects it, and the
> decision is recorded in [MasterPlan 24](../masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas.md).
> Nothing here selects a dependency or changes MasterPlan 23, EP-183 or any production code.

## Question

Beneath Nagare's retained typed inventory and cross-tool journal, would an established tool reduce
Nagare's long-term maintenance for any backup or recovery boundary? The test is whether it does
so while meeting the workplace intranet's stated requirements.

## Answer in brief

For every boundary in scope, the recommendation is to **keep Nagare's native path**:

- No candidate meets a UC-3 requirement that the native path does not already meet or that EP-183
  will not meet.
- Each candidate that fits would add a second repository format, a second retention engine and a
  second source of recovery-point identity beneath the journal.
- Nagare would still have to build the refusals the intranet relies on: exact recovery-point
  selection, no restore into a live volume, and grading against the objective.

The two candidates with standing value:

- **K8up/restic** stays the documented fallback for volume backups if EP-183 M3's slice checkpoint
  stops. Its mechanics work. Its gaps are listed in [Volume and application backups](#volume-and-application-backups).
- **CloudNativePG with the barman-cloud plugin** is the candidate to evaluate first if ADR 28's
  recovery-point objective is ever tightened below one hour or to near-zero loss for PostgreSQL. It
  is not justified by the current objectives.

The operator's concern about Velero's direction is **not supported by current primary evidence**.
Velero is still not recommended, for technical-fit reasons unrelated to its direction (see
[Project direction](#project-direction-and-maintenance-continuity)).

## Requirements scored against

The canonical requirements are the features of [UC-3](../use-cases/003-operate-nagare-as-a-team-run-intranet-paas.md),
cited by feature name, and the decisions of [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md).
The backup-relevant ones are:

| UC-3 feature | Requirement in short | ADR 28 |
|---|---|---|
| `hourly-recovery-point` | Every database and backup-included volume has an off-cluster point no older than one hour, graded in `server status`. | decision 2 |
| `bounded-backup-retention` | Every point kept 48 h, newest per day kept 30 days, newest verified point always kept; removal only by a reviewed prune. | decision 4: nothing deletes backups in the background |
| `four-hour-service-rebuild` | After VM loss, the same installation is back with its data within 4 h of starting the rebuild. | decisions 3 and 5 |
| `protect-personal-data` | Backups reachable only by the operator; copies age out by retention. | decision 6: backups stay in-region |
| `journal-is-the-audit-record` | Every applied change is in the inventory journal for the installation's life. | — |
| `single-operator-administration`, `self-approved-reviewed-changes` | One operator, reviewed plans, no second approver. | decision 1: single node |

`public-https-with-nagare-login` and `revoke-an-app-user` are outside every candidate's scope and
score neutral. ADR 28 decision 1 keeps a single node, so no candidate is credited with high
availability.

## Method and evidence levels

- **Desk (M1).** Read upstream release tags and repository metadata through the GitHub API, the
  governance, maintainer and security files, CNCF project pages, and versioned documentation, all
  on 2026-10-09. Commit counts cover 2026-04-09 to 2026-10-09 on the default branch.
- **Prototype (M2), K8up only, partial.** The run is described in the
  [prototype record](../spikes/mp24-tooling-evaluation/README.md). It ran on a disposable k3d
  cluster on the cp3 Colima daemon **outside the cp3 claim protocol**, which was a process error.
  It was stopped and the cluster deleted. The operator then decided to skip the K8up prototype, so
  its retention step never ran.
- **Not prototyped.** CloudNativePG was not prototyped: its drivers were written but never run, and
  no cluster was allowed. Velero and kapp were desk only, as EP-163 planned.
- **GCS.** No candidate was exercised against GCS; plugin support is taken from documentation only.

## Candidate facts (M1)

| Candidate | Current release (tag date) | Licence | Governance | Six-month activity | Support policy |
|---|---|---|---|---|---|
| K8up | operator v2.16.0, chart 4.10.0 (2026-07-17); v2.15.0 2026-03-25 | Apache-2.0 | CNCF Sandbox since 2021-11-16, sponsored by VSHN. GOVERNANCE.md calls it "a young Open Source project … in the process of setting up a proper project governance". CODEOWNERS is one team. The CNCF page shows health "Critical (19)". | 47 commits by 10 authors; 26 by one maintainer. 24 merged PRs, 87 open issues. | "Security fixes are applied to the latest release." |
| restic (inside K8up) | v0.19.1 (2026-07-05) | BSD-2-Clause | Independent project with GOVERNANCE.md | 419 commits by 33 authors; 327 by one maintainer | Repository format documented and readable by the stock CLI |
| Velero | v1.18.4 (2026-09-28); monthly patch releases | Apache-2.0 | CNCF Sandbox since 2026-03-11, moved from `vmware-tanzu` to `velero-io`. 8 maintainers: Broadcom 4, Red Hat 3, Microsoft 1. | 880 commits by 58 authors; 494 merged PRs, 626 open issues | Not stated in the sources read |
| Velero GCP/AWS plugins | v1.14.4 (2026-09-28) | Apache-2.0 | Same org | — | Released with Velero |
| CloudNativePG | v1.30.1 (2026-09-23) | Apache-2.0 | CNCF Sandbox since 2025-01-21; CNCF health "Healthy (83)" | 466 commits by 52 authors | Latest minor, plus the previous one for ~3 months after the next minor. 1.30 supports PostgreSQL 14–18 and Kubernetes 1.34–1.36, EOL ~Dec 2026. |
| barman-cloud plugin | v0.15.1 (2026-09-30), pre-1.0 | Apache-2.0 | Same maintainers as CloudNativePG | 239 commits by 15 authors | Requires CNPG ≥ 1.26 and cert-manager. In-tree `barmanObjectStore` is deprecated since 1.26 and is still functional in 1.30. |

## Project direction and maintenance continuity

The three categories are kept apart below: documented facts, the operator's stated preference,
and unknowns.

**Velero.**
- Facts:
  - In 2026, stewardship moved from a single vendor (VMware, then Broadcom) to vendor-neutral CNCF
    governance. The Sandbox application states that Velero "has outgrown single-vendor
    stewardship".
  - The maintainer table spans three companies.
  - Activity and release cadence are the highest of the candidates.
  - One concrete direction change affects exit cost. The restic uploader is disabled for new
    backups in 1.17–1.18, and from 1.19 restic backups *and restores* are disabled. Kopia is the
    only path.
- Operator preference: concern about Velero's direction. No specific upstream development behind
  the concern was supplied, and none was found that indicates decline.
- Unknowns:
  - Broadcom still employs half the maintainers, and its long-term staffing is not public.
  - The CNCF health score was not shown on Velero's project page.

**K8up.**
- Facts:
  - Released three times in 2026.
  - One maintainer wrote over half of the recent commits.
  - The governance file describes governance as not yet set up after nearly five years in the
    Sandbox.
  - The CNCF health score is "Critical (19)".
  - Exit cost is low because the repository is plain restic. The prototype read K8up snapshots
    with the stock restic 0.19.0 CLI and no K8up involvement.
- Operator preference: K8up is preferred over Velero.
- Unknowns:
  - VSHN's continued funding.
  - Whether the CNCF health score reflects the default-branch activity measured here.

**CloudNativePG.**
- Facts: the broadest contributor base of the PostgreSQL options, a published support window, and
  an active migration from in-tree Barman to the plugin.
- Unknown: when the in-tree path will be removed. The 1.26 notes named 1.28; 1.30 still ships it.

On continuity alone, current evidence ranks CloudNativePG first, then Velero, then K8up. The
operator's preference for K8up over Velero is not supported by continuity evidence. It is
supported by K8up's lower exit cost (plain restic) and smaller footprint.

## Boundary findings

### Cross-tool identity, review and history

Kept, as a fixed input (MasterPlan 24 Decision Log). No candidate records reviewed intent,
physical identity (ADR 27) or the cross-tool journal. Each candidate would add a native catalogue
(Snapshot objects, Velero Backup objects, CNPG Backup objects) that Nagare would have to ingest as
external operation identities. That ingestion is new work, not retired work.

### Volume and application backups

This boundary was already decided for the intranet. On 2026-10-09 the operator chose EP-183 M3:
extend the scheduled database producer. K8up is the fallback. EP-163's answers to its six K8up
questions follow.

1. **PVC access.**
   - A K8up Job mounted the local-path RWO PVC and ran as uid 1000.
   - Opt-in is explicit with `skipWithoutAnnotation=true` plus `k8up.io/backup=true`.
   - The operator ClusterRole creates Jobs, Deployments, ServiceAccounts and RoleBindings in any
     namespace. It binds `pods/exec` into each backup namespace for backup commands. That is
     broader than Nagare's per-database backup ServiceAccount.
   - On k3s v1.32.5, local-path PVs were `spec.local`, not `hostPath`. The `nagare-01` PV type is
     unverified.
2. **Recoverable application data.**
   - File volumes: yes, as a per-file copy of a live filesystem. This is the same consistency
     contract as Nagare's `storage snapshot`.
   - Databases: only through `k8up.io/backupcommand` streaming `pg_dump`. K8up's `Restore` cannot
     restore stdin backups. Recovery is `restic dump` of a pinned snapshot plus the engine's own
     restore, which was proven for PostgreSQL 18 into an isolated database.
   - No engine is covered by K8up itself.
3. **Restore safety.**
   - A restore pinned by snapshot ID and path into a new PVC recovered G1 exactly, and the source
     was untouched.
   - A wrong ID or a path mismatch was refused, though a missing ID surfaced as `Failed` only after
     about 6.5 minutes of Job backoff.
   - **Two unsafe defaults.** A Restore with no `snapshot` silently restored the latest snapshot. A
     `restoreTimeFilter` matching nothing silently fell back to the latest.
   - **No destination guard.** A Restore into a PVC a running pod was using succeeded and merged
     into the live data. Nagare would have to refuse these cases itself before ever creating a
     Restore. That matches its current refusal of `storage restore --into-live`.
4. **Journal integration and retention.**
   - K8up exposes restic snapshot IDs as `Snapshot` objects. These live in the cluster, so after
     VM loss the repository itself is the only catalogue.
   - Grading `hourly-recovery-point` from them is new ingestion. EP-183 M3's checkpoint names
     exactly that as the condition to stop.
   - Retention is restic `forget`. K8up's policy has `keepLast/Hourly/Daily/…` and `keepTags`, but
     no keep-within duration, so "every point for 48 hours" can only be approximated (for example
     `keepLast` = 192 at a 15-minute schedule).
   - A scheduled `Prune` deletes in the background, which ADR 28 decision 4 rules out. Only
     one-shot `Prune` objects created by a reviewed apply would comply.
   - Protecting a journal-referenced snapshot with `keepTags` was **not proven**, because the prune
     step did not run.
5. **Costs.**
   - The operator idled at 2–3 mCPU and 12–18 MiB.
   - Backup jobs finished in seconds: 21 s for 128 MiB.
   - Robustness costs observed:
     - an object-store outage left the Backup `Progressing` while its pods crash-looped, with no
       failure condition;
     - a force-killed backup left a restic lock that blocked `restic check` for at least 11
       minutes, consistent with restic's 30-minute stale-lock rule.
   - Operational additions: a restic repository password to escrow (in place of, or alongside,
     Nagare's HMAC signing keys), a chart, CRDs and an operator upgrade cadence.
6. **Continuity.** See [Project direction](#project-direction-and-maintenance-continuity).

### PostgreSQL backup and recovery

CloudNativePG with the barman-cloud plugin is a desk result only.
- What it offers:
  - continuous WAL archiving, which gives point-in-time recovery and a recovery point well inside
    one hour;
  - recovery into a separate new Cluster;
  - documented S3 and GCS object stores.
- Its costs here:
  - CloudNativePG becomes the lifecycle owner of the PostgreSQL pods and PVCs, replacing Nagare's
    StatefulSet. ADR 22's single-lifecycle-owner rule needs explicit delegation, and every existing
    database migrates through a logical import.
  - It adds cert-manager-dependent plugin TLS.
  - Its retention (`retentionPolicy` on the ObjectStore) deletes obsolete backups after each new
    backup, which is background deletion that ADR 28 decision 4 rules out unless it is left unset.
  - It covers PostgreSQL only, so Redis and ClickHouse keep the native path. Because Nagare's
    backup code is multi-engine, this retires little: the PostgreSQL branches of
    `Nagare/Database/Backup.hs`, not the receipt, freshness, prune or restore machinery.
- Footprint and recovery were not measured.

### Velero

Desk only. Velero is not credited for this installation, for these reasons:
- File-system backup is beta.
- It needs a node agent with root access to `/var/lib/kubelet/pods`.
- It reads live data without consistency.
- Snapshot-based data movement assumes CSI snapshots, which local-path does not provide.
- Its main strength, replaying Kubernetes objects, overlaps Nagare's own declared recreation and
  would create a second owner for those objects.

### Redis and ClickHouse

Keep the native engine formats. No concrete backup deficiency was found that a candidate would fix.

### Kubernetes apply and release evidence

Not evaluated. No concrete retirement case arose, and EP-163 planned neither as a prototype.

## Scoring (M3)

Scores are relative to Nagare's native path once EP-183 lands:

- `+` better;
- `=` equivalent or neutral;
- `−` worse, or extra Nagare work needed to stay equivalent;
- `?` unproven.

| UC-3 feature / ADR 28 | Native + EP-183 | K8up/restic (volumes) | CloudNativePG/Barman (PostgreSQL) | Velero (volumes/objects) |
|---|---|---|---|---|
| `hourly-recovery-point` / ADR 28 §2 | Met for databases on v0.4.0. Volumes in EP-183 M3, graded by `BackupFreshness`. | `−`: hourly schedules work, but grading needs new ingestion of restic snapshots | `+`: continuous WAL gives a tighter point than required. `−`: grading needs ingestion of CNPG backup status. `?` | `−`: same ingestion; FSB is beta |
| `bounded-backup-retention` / ADR 28 §4 | EP-183 M2: graded target plus reviewed prune, never the newest verified point | `−`: no keep-within, and scheduled prune is background deletion. `?` for keepTags protection | `−`: window retention deletes after each backup, which is background deletion | `−`: TTL-based expiry is background deletion |
| `four-hour-service-rebuild` / ADR 28 §3, §5 | EP-183 M4 lineage decision plus timed drill | `=` for files (restore to a new PVC proven). `−` for databases (manual `restic dump`). `−` for silent latest and no destination guard. | `=`: recovery into a new Cluster, but every database must first migrate to CNPG. `?` | `−`: object replay conflicts with Nagare's declared recreation |
| `protect-personal-data` / ADR 28 §6 | Private regional bucket with public access prevention enforced; escrowed HMAC keys | `+`: restic encrypts at rest. `−`: one repository password becomes a second secret to escrow. | `=` | `=` |
| `journal-is-the-audit-record` | Native receipts and journal | `−`: the snapshot catalogue lives in cluster objects and the repository; external IDs must be journaled | `−`: same, for CNPG Backup objects | `−`: same |
| `single-operator-administration`, `self-approved-reviewed-changes` | Met | `=`, though the operator RBAC is broader | `=` | `−`: privileged node agent |
| Net maintenance | Baseline | `−`: adds a format, an operator and refusal shims, and retires only part of `Storage/Snapshot.hs` and `VolumePrune.hs` | `−` now; possibly `+` only if the PostgreSQL objective tightens | `−` |
| Continuity | Nagare-owned | Weakest (one main maintainer, CNCF health critical) | Strongest | Strong, vendor-neutral since 2026 |

### Responsibility map if K8up were adopted as the volume fallback

| Responsibility | Owner |
|---|---|
| Declaring which volumes are backed up, and refusing undeclared ones | Nagare (typed inventory, `k8up.io/backup` annotations rendered from it) |
| Scheduling and uploading | K8up `Schedule`/`Backup`, restic |
| Recovery-point identity in the journal | Nagare, ingesting restic snapshot IDs and paths |
| Freshness grading against `hourly` | Nagare, from that ingestion |
| Retention decision | Nagare (reviewed plan). Execution by a one-shot K8up `Prune`, with protected points tagged. |
| Restore target selection and refusals (pinned ID, never the live PVC, never implicit latest) | Nagare, before creating any `Restore` |
| Database dumps | Native engine commands (backup command), with restore through `restic dump` plus the engine restore |
| Repository password custody | Nagare escrow, in place of or beside HMAC signing keys |

Adoption cost: a chart and CRDs per installation, an operator upgrade cadence, the ingestion and
refusal code above, and an EP-172 compatibility row for the new receipt source. Code retired: part
of `cli/nagarectl/src/Nagare/Storage/Snapshot.hs` (332 lines) and
`cli/nagarectl/src/Nagare/Inventory/VolumePrune.hs` (357 lines). Code retained:
`Nagare/Inventory/BackupFreshness.hs`, `ScheduledReceipt.hs`, `ScheduledIngest.hs`,
`ScheduledPrune.hs`, `Restore.hs` and the whole database path.

## Recommendation

For each tested boundary; the operator decides.

| Boundary | Recommendation | Promote if | Reject or stay if |
|---|---|---|---|
| Cross-tool identity/review/history | Keep (fixed input) | — | — |
| Volume backups | Keep native (EP-183 M3). K8up/restic is the fallback. | EP-183 M3's slice needs new ingestion or restore-authority semantics, as its checkpoint says. Then prototype K8up retention with `keepTags`, lock recovery, and ingestion of snapshot IDs into the journal on an operator-approved daemon before adopting. | EP-183 M3 lands within its slice |
| PostgreSQL backups | Keep native | ADR 28's recovery-point objective tightens below one hour, or to near-zero loss, for PostgreSQL. Then run the prepared CloudNativePG drivers (`docs/spikes/mp24-tooling-evaluation/30-*`, `31-*`) and design the lifecycle delegation. | Objectives unchanged |
| Redis/ClickHouse backups | Keep native | A concrete backup deficiency is found | — |
| Velero | Do not adopt | A need arises for whole-namespace object replay that Nagare's declared recreation cannot meet | Default |
| Kubernetes apply (kapp), release evidence | Not evaluated; keep | A concrete retirement case | — |

A recommendation to keep the current native tools is a valid outcome of EP-163.

## What this record does not establish

- That any candidate works against GCS, on `nagare-01`, or on NixOS k3s. None was run there.
- That K8up's `keepTags` protects referenced snapshots, or how long its stale locks block
  maintenance. Both steps were interrupted.
- CloudNativePG footprint, recovery time or migration effort. It was not prototyped.
- Anything about Velero beyond its documentation and project metadata.
- The `nagare-01` PersistentVolume type.
