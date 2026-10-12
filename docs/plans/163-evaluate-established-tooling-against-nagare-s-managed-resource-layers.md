---
id: 163
slug: evaluate-established-tooling-against-nagare-s-managed-resource-layers
title: "Evaluate established tooling against Nagare's managed-resource layers"
kind: exec-plan
created_at: 2026-09-28T14:26:34Z
intention: "intention_01m3m6hh7temkvtd7cgzkb3r15"
master_plan: "docs/masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-28T14:26:34Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Constrain tool evaluation to retained journal/state and current engines; add bounded Velero backup assessment without selecting a tool"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T18:26:14Z
      mode: "update"
      note: "Prioritize K8up backup evaluation and assess the operator concern about Velero project direction"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-10T02:57:51Z
      mode: "update"
      note: "Volume backups extend the DB producer (EP-183); K8up is the fallback"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-10T03:52:45Z
      mode: "implement"
      note: "M1 desk evaluation, M2 closed with partial K8up evidence (run outside cp3 claim), M3 record RES-6 supersedes RES-3"
---

# Evaluate established tooling against Nagare's managed-resource layers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Evaluate whether established database and Kubernetes/volume backup tools would reduce Nagare's long-term maintenance while preserving its developer experience, reliability, and ownership contract. [RES-3](../research/managed-resource-inventory-scope-and-tooling-overlap.md) is a preliminary overlap survey; it does not establish that another tool replaces the guarantees Nagare needs.

The operator has decided to retain typed scopes and the cross-tool journal/state, and has separately reduced [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Evaluate tools beneath that boundary. No Flux, implicit substitute GitOps system, additional messaging engine, or new general provider framework. Existing PostgreSQL, Redis, and ClickHouse are the database scope; likely future database engines inform extension cost only.

K8up/restic is the primary candidate for volume and application-aware backup evaluation. Velero is a secondary desk comparison because the operator is concerned about the project's direction; that concern is a selection preference to investigate, not a verified claim of abandonment or technical unreliability. CloudNativePG/Barman remains the separate PostgreSQL comparison. No candidate is selected for adoption. The result is a bounded, evidence-backed comparison of keeping native tools versus delegating specific responsibilities, with exact code/tests that could be retired and new integration/operational costs. This plan changes no production code, does not gate MP-23, and does not reactivate its deferred live overwrite, maintenance, or generalized pruning work.

## Progress

2026-09-28 candidate reprioritization: evaluate K8up/restic first and retain Velero as a secondary desk comparison. Add project direction and maintenance continuity to M1/M3. This planning change accepts no candidate or milestone and starts no prototype.

- [x] M1 (2026-10-10): Evaluate the finite candidate boundaries below using current authoritative releases/docs; record coverage, limitations, and eliminations without requiring a replacement for every Nagare layer. Done in [RES-6](../research/established-backup-tooling-beneath-nagare-s-journal.md), sections "Candidate facts", "Project direction" and "Boundary findings". Sources are upstream tags and governance files read on 2026-10-09.
- [x] M2 (closed 2026-10-10 by operator decision, partial): Run bounded local prototypes for credible PostgreSQL and Kubernetes/volume-backup candidates, or record a decisive documented incompatibility; measure operational footprint and recovered content.
  - The K8up/restic prototype ran partly on a disposable k3d cluster on cp3, **outside the cp3 claim protocol**. That was a process error; see Surprises & Discoveries. Proven:
    - a pinned restore into a new PVC;
    - refusal of a wrong ID or path;
    - silent implicit-latest restores;
    - restore into an in-use PVC not refused;
    - a pinned pg_dump into an isolated database;
    - interruption with an object-store outage;
    - footprint.
  - The retention prune never ran, so `keepTags` protection is unproven.
  - The cluster was deleted. The operator then decided to skip the K8up prototype: K8up gets one only if EP-183 M3's slice checkpoint stops.
  - CloudNativePG was not prototyped: its drivers are prepared but unrun, and no cluster was allowed.
  - Record: [`docs/spikes/mp24-tooling-evaluation/README.md`](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/spikes/mp24-tooling-evaluation/README.md).
- [x] M3 (2026-10-10): Score the surviving choices against EP-162 M1 requirements in a validated research record, distinguish recommendation from adoption, and record the operator's decision.
  - Done (2026-10-10): scored against UC-3's features and ADR 28 in RES-6, which validates and supersedes RES-3. The recommendation is to keep the native path for every boundary in scope, with K8up as the volume fallback and CloudNativePG as the candidate if the PostgreSQL objective tightens.
  - (2026-10-10) The operator accepted the recommendation; recorded in MasterPlan 24's Decision Log.

2026-09-28: This scope update records preliminary Velero desk findings and evaluation criteria only. No candidate has been installed, benchmarked, selected, or accepted; all milestones remain open.

## Surprises & Discoveries

2026-10-10, from M1–M2:

- **The prototype ran outside the cp3 claim protocol.**
  - The k3d cluster `mp24-eval` ran on the `nagare-mp23-cp3` Colima daemon from 03:01 to 03:48
    UTC. No cp3 claim was taken (`docs/runbooks/native-verification-harness.md` section 3), and
    cp3 was under a `nagare-verify` claim at the time.
  - The session also raised the VM's runtime-only `fs.inotify.max_user_instances` from 128 to
    1024, after the first create failed with `too many open files`: `nagare-local` had used up all
    128.
  - `nagare-local`, its context and the retained root were not touched.
  - The coordinator stopped the run and the cluster was deleted by exact name.
  - `env.sh` now refuses to run without an explicit operator-approved `EVAL_DOCKER_HOST`.
- **Nagare's local MinIO images are no longer pullable.** The digests pinned in
  `cluster/local/minio/minio.yaml` and `Nagare/Inventory/Components/LocalObjectStore.hs` return
  401 from quay.io, and `docker.io/minio/*` reports that the repository does not exist. A fresh
  local context without cached images cannot start its object store. The coordinator routes this
  to EP-183. The prototype used RustFS 1.0.1.
- K8up restores silently pick the latest snapshot when `snapshot` is omitted or when
  `restoreTimeFilter` matches nothing. K8up also restores into a PVC a running pod is using,
  merging into the live data. Pinning by ID together with `paths` refuses the wrong source.
- A force-killed K8up backup left a restic lock that blocked `restic check` for at least 11
  minutes. An object-store outage left the Backup `Progressing`, with crash-looping pods and no
  failure condition.
- Velero moved from VMware-Tanzu to the CNCF Sandbox (accepted 2026-03-11, now `velero-io`, with
  maintainers from Broadcom, Red Hat and Microsoft). The evidence found does not support a decline
  in direction. The concrete direction change is that restic backups and restores are disabled
  from Velero 1.19.
- K8up's continuity evidence is the weakest of the candidates:
  - one maintainer wrote 26 of 47 commits in six months;
  - GOVERNANCE.md says governance is still being set up;
  - its CNCF health score is "Critical (19)".
- On k3s v1.32.5 the local-path provisioner created `spec.local` PVs, not `hostPath`.

2026-09-28 preliminary K8up findings, not prototype evidence:

- [Backup methods](https://docs.k8up.io/k8up/2.16/explanations/backup.html) describe Jobs mounting PVCs, application backup commands, and dedicated `PreBackupPod`s. RWO volumes require compatible same-node scheduling. Raw live database files do not establish a consistent backup; retain engine-native procedures and verify recovered content for each claimed engine.
- [Restore documentation](https://docs.k8up.io/k8up/2.16/how-tos/restore.html) describes restore to a new PVC and recovery through Restic. Streamed backup-command/`PreBackupPod` output cannot use the ordinary PVC restore path; evaluate explicit Restic retrieval followed by the engine's restore procedure. Pin the exact snapshot and validate its source paths; do not depend on an implicit latest snapshot or a time filter that can fall back to latest.
- [Backup configuration](https://docs.k8up.io/k8up/2.16/how-tos/backup.html) backs up all PVCs by default and supports requiring annotations. Evaluate explicit inclusion aligned with Nagare's owned resources, actual PVC permissions, and command-execution RBAC. A simpler volume access model does not by itself prove safer permissions or recovery.

The operator's concern about Velero is project direction. The precise upstream developments behind that concern have not been supplied. Compare both projects using primary evidence for governance and maintainer continuity, releases and support policy, roadmap/deprecations, security response, and migration or exit costs. Separate documented facts, operator preferences, and unresolved questions; do not assume K8up is safer from this preference alone.

2026-09-28 preliminary Velero backup assessment, not prototype evidence:

- [Filesystem backup documentation](https://velero.io/docs/v1.18/file-system-backup/) describes a beta filesystem path that reads live data rather than a single point-in-time image. It needs node-agent access to the node filesystem, normally as root. It supports `local` volumes but excludes `hostPath`. Nagare configures local-path storage in `nixos/hosts/nagare-01/k3s.nix`; inspect actual PVs and provisioner settings before concluding compatibility from the storage-class name. Do not assume CSI snapshots exist.
- [Backup hooks](https://velero.io/docs/v1.18/backup-hooks/) can run before/after backup, including filesystem freezing. Inference: hook completion alone is not proof of application-consistent PostgreSQL/Redis/ClickHouse recovery. Compare the current engine-native dump formats and a bounded quiescing procedure; measure required downtime and failure/unfreeze behavior.
- [Restore reference](https://velero.io/docs/v1.18/restore-reference/) documents skipping existing resources by default, with ServiceAccount handling as an exception. Updating an existing PVC object does not restore its underlying data. Evaluate recovery into a distinct namespace/new PVC and explicit ownership boundaries, not general in-place live restoration.
- [GCP plugin](https://github.com/velero-io/velero-plugin-for-gcp) and [AWS/S3 plugin](https://github.com/velero-io/velero-plugin-for-aws) are candidate transport integrations for GCS and local MinIO. Verify compatible released versions and credential requirements before a prototype. This establishes a path to investigate, not proved Nagare transport support.

Initial judgment: Velero may simplify Kubernetes resource/volume backup and recovery. Its value for the current local-path installation and database correctness is unresolved. It would not replace Pulumi/NixOS recovery or Nagare's cross-tool state/journal. If compatibility needs a new storage platform or a large custom database-consistency layer, record the added cost and prefer a narrower or rejected role rather than expanding MP-23.

## Decision Log

- Decision: The operator accepted RES-6's recommendation on 2026-10-10: no established tool is adopted. K8up/restic stays EP-183 M3's fallback, and CloudNativePG/Barman is reconsidered only if ADR 28's PostgreSQL recovery point tightens below one hour. Velero is not recommended, on technical fit.
  Rationale: recorded as the operator's decision in MasterPlan 24; this plan's evaluation is complete.
  Date: 2026-10-10

- Decision: Close M2 with the partial K8up evidence already gathered, and run no CloudNativePG
  prototype.
  Rationale: on 2026-10-10 the operator decided to skip the K8up prototype. It runs only if EP-183
  M3's slice checkpoint stops. No Colima profile other than cp3 may be started, and cp3 was under
  another session's claim. CloudNativePG is not needed under ADR 28's objectives, and RES-6 names
  the condition that would make it worth running.
  Date: 2026-10-10

- Decision: Score against UC-3 and ADR 28, and record the result as RES-6, superseding RES-3.
  Rationale: EP-162 completed on 2026-10-10 with UC-3 confirmed and ADR 28 accepted, which
  satisfies M3's hard dependency. RES-3's status changes to superseded; its findings stay as they
  are.
  Date: 2026-10-10

- Decision: Volume backups for the intranet extend Nagare's scheduled database producer (EP-183 M3,
  MasterPlan 24 Decision Log). K8up stays the volume candidate here as research and as EP-183's
  fallback if its slice checkpoint stops. This plan no longer gates EP-183.
  Rationale: the operator accepted EP-183's recommendation, conditional on the extension staying
  small.
  Date: 2026-10-09

- Decision: Promote K8up/restic to the primary volume/application-backup candidate; retain Velero as a secondary desk comparison and CloudNativePG/Barman as the PostgreSQL comparison. Supersede the earlier Velero-first prototype order. A Velero prototype is conditional on a concrete gap in the primary comparisons and acceptable project-direction evidence.
  Rationale: The operator prefers K8up and identifies Velero's project direction as the concern. Evaluate long-term maintenance and recovery fit before any adoption decision; this does not change MP-23's release scope or gates.
  Date: 2026-09-28

- Decision: Keep the cross-tool journal/state and typed ownership as fixed inputs. Exclude Flux and new messaging engines. Prioritize existing native backups, CloudNativePG/Barman for PostgreSQL, and Velero for Kubernetes/volume backups; do not choose a tool before evidence.
  Rationale: The operator approved reducing MP-23 and explicitly clarified that the Velero question is evaluation only.
  Date: 2026-09-28

- Decision: Prototype only on a dedicated, disposable local k3d cluster; never on a cloud context
  or on the Nagare local context's own cluster.
  Rationale: MasterPlan 23 sessions keep retained local fixtures, and cloud mutation needs the
  operator's go-ahead. Evaluation must not disturb either.
  Date: 2026-09-28

## Outcomes & Retrospective

2026-10-10, after M1–M3's record:

- **Recommendation (RES-6): keep Nagare's native backup path for every boundary in scope.** No
  candidate meets a UC-3 requirement that native code plus EP-183 does not already meet. Each one
  that fits adds a second repository format, a second retention engine (whose scheduled form
  breaks ADR 28 decision 4) and a second recovery-point catalogue beneath the journal. Nagare would
  still need to build the refusals the intranet depends on.
- K8up/restic is the volume fallback, with named gaps: implicit latest, no destination guard, no
  keep-within retention, lock recovery after a hard kill, and the weakest continuity evidence.
- CloudNativePG is the PostgreSQL candidate if the objective tightens below one hour.
- Velero is not recommended, for technical-fit reasons. Its direction evidence is healthy.
- Still open: the operator's decision on the recommendation, and the unproven K8up retention and
  CloudNativePG steps listed in RES-6.
- Lesson: before running anything that needs a Docker daemon, check the shared-host claim rules,
  not only which daemon is running. The prototype session read the running Colima profile as
  available and missed the cp3 claim protocol.

