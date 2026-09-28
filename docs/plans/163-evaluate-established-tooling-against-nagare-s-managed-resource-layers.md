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
---

# Evaluate established tooling against Nagare's managed-resource layers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Evaluate whether established database and Kubernetes/volume backup tools would reduce Nagare's long-term maintenance while preserving its developer experience, reliability, and ownership contract. [RES-3](../research/managed-resource-inventory-scope-and-tooling-overlap.md) is a preliminary overlap survey; it does not establish that another tool replaces the guarantees Nagare needs.

The operator has decided to retain typed scopes and the cross-tool journal/state, and has separately reduced [MP-23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Evaluate tools beneath that boundary. No Flux, implicit substitute GitOps system, additional messaging engine, or new general provider framework. Existing PostgreSQL, Redis, and ClickHouse are the database scope; likely future database engines inform extension cost only.

K8up/restic is the primary candidate for volume and application-aware backup evaluation. Velero is a secondary desk comparison because the operator is concerned about the project's direction; that concern is a selection preference to investigate, not a verified claim of abandonment or technical unreliability. CloudNativePG/Barman remains the separate PostgreSQL comparison. No candidate is selected for adoption. The result is a bounded, evidence-backed comparison of keeping native tools versus delegating specific responsibilities, with exact code/tests that could be retired and new integration/operational costs. This plan changes no production code, does not gate MP-23, and does not reactivate its deferred live overwrite, maintenance, or generalized pruning work.

## Progress

2026-09-28 candidate reprioritization: evaluate K8up/restic first and retain Velero as a secondary desk comparison. Add project direction and maintenance continuity to M1/M3. This planning change accepts no candidate or milestone and starts no prototype.

- [ ] M1: Evaluate the finite candidate boundaries below using current authoritative releases/docs; record coverage, limitations, and eliminations without requiring a replacement for every Nagare layer.
- [ ] M2: Run bounded local prototypes for credible PostgreSQL and Kubernetes/volume-backup candidates, or record a decisive documented incompatibility; measure operational footprint and recovered content.
- [ ] M3: Score the surviving choices against EP-162 M1 requirements in a validated research record, distinguish recommendation from adoption, and record the operator's decision.

2026-09-28: This scope update records preliminary Velero desk findings and evaluation criteria only. No candidate has been installed, benchmarked, selected, or accepted; all milestones remain open.

## Surprises & Discoveries

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

(To be filled during and after implementation.)


## Context and Orientation

Nagare is a platform-as-a-service that runs on one GCP Compute Engine virtual machine with NixOS
and k3s (a small Kubernetes distribution), or locally on k3d (k3s in Docker). Pulumi (an
infrastructure-as-code tool) provisions the cloud resources in `infra/pulumi/`; NixOS configures the
host; `nagarectl` (Haskell, `cli/nagarectl/`) deploys applications and platform components.

MasterPlan 23 (`docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md`)
adds a *typed inventory*: every managed resource is declared in Haskell with a stable identifier
and an owner, owners' declarations are composed, and conflicting claims are refused before any
change. That core lives in `cli/nagare-dsl/src/Nagare/Resource/` and is not in question here. The
implementation surfaces to account for are in `cli/nagarectl/src/Nagare/Inventory/`; listing a
surface does not authorize replacing it:

- State, review, and execution: `Store.hs`, `Store/` (including the GCS store from EP-151),
  `Plan.hs`, `Journal.hs`, `Execute.hs`, `Adapter.hs`. A *journal* is the durable log of which
  reviewed operations ran and how they ended, so an interrupted change can be resumed.
- Kubernetes execution, ownership, adoption, and pruning: `Adapters/Kubernetes.hs`,
  `Adapters/KubernetesRuntime.hs`, `KubernetesReview.hs`, `Lifecycle.hs`, `Migration.hs`.
- Backup receipts and retention: `Backup.hs`, `ScheduledReceipt.hs`, `ScheduledIngest.hs`,
  `ScheduledPrune.hs`, `Prune.hs`, `VolumePrune.hs`. A *receipt* is a signed record that a specific
  backup object was produced from a specific database.
- Data fencing and restore: `DataFence.hs`, `DataFence/`, `Restore.hs`, `LiveRestore*.hs`. A *fence*
  blocks ordinary writers from a database while a restore or maintenance session has exclusive
  access.
- Fenced interactive maintenance: `Maintenance.hs`, `MaintenanceAdapter.hs`, `MaintenanceFence.hs`.
- Release evidence: `scripts/assemble-managed-resource-evidence.sh`, `scripts/assemble-release.sh`,
  `.github/workflows/release.yml`.

The managed databases are PostgreSQL, Redis, and ClickHouse, run as single-replica StatefulSets;
backups go to GCS in the cloud and MinIO locally. A candidate must identify the exact engines and
object stores it covers. A PostgreSQL-only tool can be useful; it need not become a universal
backup framework. Every adoption proposal must state the remaining native paths.

The finite candidate set and questions are:

| Boundary | Candidate comparison | Scope of decision |
|---|---|---|
| Cross-tool identity/review/history | Existing Nagare plus native Pulumi/NixOS/Kubernetes state | Retain; examine adapter interfaces and coordination cost, not wholesale replacement. |
| PostgreSQL backup/recovery | Current native dump/restore versus CloudNativePG with Barman Cloud | Source consistency, separate-target recovery, GCS/MinIO, controller lifecycle, single-node overhead, and code retired. No HA mandate. |
| Volume and application backups | Current native/archive paths versus K8up/restic (primary); Velero as a secondary desk comparison | Actual local-path PVC access and scheduling, native dump integration, isolated restore, exact snapshot identity, retention, permissions, and footprint. Nagare retains resource declarations and ownership. |
| Redis/ClickHouse backups | Current native engine formats and existing reviewed transport | Keep as baseline; assess only concrete backup deficiencies. No exhaustive operator search or additional engine. |
| Project direction and maintenance continuity | K8up/restic and Velero, with the same criteria applied to CloudNativePG/Barman | Primary evidence for governance, maintainer continuity, release/support policy, roadmap/deprecations, security response, and exit cost. Record uncertainties and the operator's concern separately from verified findings. |
| Kubernetes apply | Existing native executor; optional kapp comparison if a concrete retirement case emerges | Lower priority; not a mandatory migration or prototype. No GitOps-platform substitution. |
| Release evidence | Existing native/local/cloud proof and immutable evidence | Retain. Artifact attestations may complement provenance; they do not replace behavior proof or create a new project. |

Preserve the single lifecycle-owner rule. A prospective operator owns its generated children through explicit delegation; Nagare declares the parent/interface and records external operation identities and verified results without reproducing a second tool's internal scheduler or backup catalogue. Evaluate whether this actually removes maintenance rather than merely adding another layer.

Relevant ADRs:
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (the inventory
design and its single-writer store);
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
(remote Pulumi state in the context bucket);
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) (any tool that
mutates cloud resources must be confined to the active context's project);
[ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) (host changes only through the
guarded switch); [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) (immutable
Nix releases, relevant to release evidence).


## Plan of Work

M1 evaluates the finite boundaries in Context and Orientation. Use Mori first for local dependency sources, then current authoritative release tags/registries and documentation. Record versions/licences, covered data/provider modes, ownership and recovery semantics, single-node footprint, credential needs, and exact Nagare code/test obligations removed versus retained. Existing journal/state is a fixed constraint. A partial tool match is acceptable if its narrower role has value. Do not require every layer to acquire a new tool or expand the candidate list without a concrete question.

For K8up/restic, answer these bounded backup questions before selecting a prototype. Use the same applicable criteria for the secondary Velero desk comparison:

1. Can a K8up Job mount the actual local-path PVC with its access mode, node affinity, and permissions? Verify explicit backup inclusion, required RBAC (including backup-command execution), and security contexts. For Velero, inspect actual PV type and kubelet/node-agent requirements. Do not install CSI or change the storage platform merely to make a trial pass; report that as a separate cost/decision.
2. Does the backup capture recoverable application data? Distinguish PVC file copies from engine-native dumps. For each claimed engine, state the consistency mechanism, command or PreBackupPod integration, and any pause required. Account for streamed dumps needing Restic retrieval and engine-specific restore instead of the ordinary PVC restore path. A successful upload or Backup status is insufficient.
3. Can restoration use a separate destination/new PVC, recover known files/rows, preserve the source, and avoid two controllers owning the same object? Pin the exact repository/snapshot and source paths, reject mismatches, and prove a missing selection cannot silently restore latest. Nagare recreates its declared resources; identify any remaining configuration or credential recovery obligation. For Velero, also explain replay of Kubernetes objects and generated resources.
4. How are backup completion, external IDs, interruption, and deletion represented in Nagare's existing journal? Can retention avoid deleting objects still needed by accepted or unresolved recovery without a second custom retention engine? Distinguish Restic snapshot/repository retention from Nagare recovery references and native backup objects; object-store expiry must not erase referenced recovery data.
5. What resource and maintenance costs remain: idle/backup/restore CPU, memory, temporary disk, object-store traffic, controller/plugin upgrades, credentials, and a fresh-operator recovery procedure? Compare with today's native commands on the same bounded dataset.
6. Does current upstream evidence support relying on the project over Nagare's expected lifetime? Compare governance and maintainers, recent releases and support policy, announced roadmap/deprecations, security response, and backup-format portability/exit cost. Record dated primary sources and unknowns. The operator's concern about Velero's direction is not itself evidence of a specific upstream change.

M2 prototypes only candidates that survive those questions, on a dedicated disposable local k3d cluster with its own MinIO. Prioritize at most two primary prototypes: K8up/restic for volume/application backups, and CloudNativePG/Barman for PostgreSQL. A documented hard incompatibility may eliminate a candidate before installation; record the exact reason rather than designing a new platform to satisfy it. State pass/fail criteria and fixture identity before each run. PostgreSQL must recover known rows into a separate destination after source changes. K8up must recover known files into a new PVC and at least one native database dump into an isolated database, preserve sources, reject a wrong snapshot/source or foreign destination, exercise an interrupted backup/restore, and make any incomplete result visible. Record exact external operation and snapshot identities for Nagare's journal and demonstrate that recovery references can be protected from pruning. Prove any additional claimed engine separately. Claim database backup coverage only after an engine-native content/consistency test; a PVC-file test is not database proof. Measure idle and active memory/CPU/disk for both the tool and required agents/operators. Capture deletion/retention semantics on disposable backups without enabling production expiry.

Check GCS plugin/configuration and credential support against upstream docs during M1; this local prototype is not GCS proof. A future adoption requires actual Compute Engine/NixOS/k3s/GCS validation under a separately reviewed implementation plan. Never use GKE or touch MP-23's retained local fixtures. Keep prototype scripts/notes under `docs/spikes/mp24-tooling-evaluation/`; remove only this plan's proven-owned disposable resources when finished. An optional kapp or secondary Velero prototype needs a concrete unresolved question; Velero must also pass the project-direction assessment before a prototype is justified. Neither is a prerequisite for reporting the two primary results.

M3 begins after EP-162 M1 is accepted. Create the next research record using `docs/research/profile.dhall`, scoring survivors against canonical use-case handles, current single-node constraints, DX, recovery reliability, and net maintenance. Include a responsibility map, retained code, retired code, adoption/migration cost, unresolved provider evidence, project-direction and maintenance-continuity findings, and promote/reject criteria. Recommend keep, combine, or adopt only for each tested boundary; no tool is selected by this plan update. Mark RES-3 superseded and update the research bundle log/index only when the validated replacement exists. Present the recommendation and record the operator's decision in MP-24; production adoption and any further MP-23 change require a separate decision.

## Concrete Steps

All future prototype commands run with an explicit isolated cluster identity. First list local clusters and refuse to reuse an existing `mp24-eval` without proof it belongs to this plan. Verify current k3d options before creation; do not switch the operator's global kube context. Use an isolated kubeconfig and explicit context in prototype scripts.

```bash
k3d cluster list
mori registry search k8up
mori registry search restic
mori registry search cloudnative
mori registry search velero
```

Record exact create, install, backup, restore, inspection, and cleanup commands with versions under `docs/spikes/mp24-tooling-evaluation/` before accepting M2. No cluster creation or installation is performed by this planning update. Validate the eventual research record through its existing profile:

```bash
okf id next docs/research --profile docs/research/profile.dhall RES
okf validate docs/research --profile docs/research/profile.dhall
```

Stage only this plan's files by explicit path; preserve concurrent MP-23 implementation and private provider material.

## Validation and Acceptance

M1 requires a sourced comparison for each finite boundary above, current release/licence checks for concrete candidates, clear fixed/optional/deferred responsibilities, and documented eliminations. It does not require replacing the journal or finding a new tool for every layer. The K8up result must explicitly state backup scope, actual PVC compatibility/permissions, native dump retrieval and restore responsibilities, exact snapshot selection, retention integration, GCS evidence level, and whether it reduces net maintenance. Compare project direction and maintenance continuity using dated primary evidence for K8up/restic and Velero; the secondary Velero result can remain a desk comparison with unresolved claims clearly marked.

M2 requires pass/fail against predeclared criteria, observed restored content/source preservation, recorded failure behavior and measured footprint for each primary survivor; a decisive incompatibility can be accepted as elimination evidence instead of forcing installation. Account for and remove only the disposable resources created by this evaluation. Kubernetes object success alone is neither volume recovery nor database consistency proof.

M3 requires a validating research record with EP-162 requirement references, justified keep/combine/adopt recommendations, RES-3 supersession metadata/log/index, and a recorded operator decision. No production adoption, new MP-23 release dependency, or unperformed cloud proof may be implied. A recommendation to retain current native tools is a valid outcome.

## Idempotence and Recovery

Keep prototypes in their own kubeconfig/cluster/object-store identities. Record ownership before creation and verify it before cleanup; a pre-existing cluster with the same name is not disposable by assumption. Preserve failed-run evidence privately before removing this plan's resources. Do not reset MP-23 fixtures, cloud contexts, inventory state, or existing backups. Documentation steps are repeatable; candidate versions must be rechecked before any later installation.

## Interfaces and Dependencies

M1 and M2 have no prerequisites. M3 has a hard dependency on EP-162 M1, the accepted requirements
use case in `docs/use-cases/` from
`docs/plans/162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md`;
EP-162 M2's availability ADR is a soft input, and without it candidates are scored under the
single-node assumption, stated explicitly. Tools needed locally: k3d, kubectl, Docker (or Colima),
and the candidate tools' own CLIs.

## Revision Notes

2026-09-28: Promote K8up/restic to the primary backup evaluation and prototype, move Velero to a conditional secondary comparison because of the operator's project-direction concern, and align research, recovery criteria, and maintenance assessment. No adoption or MP-23 gate is added.

2026-09-28: Bound tool research beneath the retained journal/state; prioritize existing database backup and Velero backup evaluation, exclude Flux/new messaging, and separate preliminary findings from prototypes and adoption.
