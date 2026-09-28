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
---

# Evaluate established tooling against Nagare's managed-resource layers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare's managed-resource initiative (MasterPlan 23) has built its own state store, planner,
Kubernetes executor, backup receipts, retention pruning, data fencing, live restore, fenced
maintenance sessions, and release evidence. A first-pass review,
[RES-3](../research/managed-resource-inventory-scope-and-tooling-overlap.md), found that these
layers appear to overlap established tools, but it evaluated none of them. Nagare will now also be
run by a team as a workplace intranet PaaS, where colleagues must be able to maintain and audit
the platform, which raises the stakes of that choice.

After this plan, the operator has a measured, evidence-backed comparison for each layer: the best
established candidate (or candidates), what it does and does not cover relative to Nagare's own
implementation, its footprint on a single node, how it would compose with Nagare's typed inventory,
and what adopting it would retire or cost. The result is a new research record that supersedes
RES-3 and a recommendation per layer (adopt a tool, keep Nagare's implementation, or combine them)
that the operator can accept or reject. This plan decides nothing on the operator's behalf and
changes no production code.


## Progress

- [ ] M1: Desk evaluation. For each layer, the current release of every candidate is identified
  from its authoritative registry or release tags, its documented behavior is summarized against
  the evaluation questions, and candidates that clearly cannot fit are eliminated with a stated
  reason.
- [ ] M2: Local prototypes. Each surviving candidate that would replace a data-safety or ownership
  layer has a bounded prototype on an isolated k3d cluster with a recorded pass/fail result and
  measured memory use, and the cluster is removed afterwards.
- [ ] M3: Scored comparison and recommendation. A research record superseding RES-3 scores every
  surviving candidate against the team requirements from EP-162 M1, and the recommendation is
  presented to the operator.


## Surprises & Discoveries

(None yet.)


## Decision Log

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
layers under evaluation are in `cli/nagarectl/src/Nagare/Inventory/`:

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
backups go to GCS in the cloud and MinIO locally. Any candidate must support both object stores and
the three engines, or state which it covers.

RES-3's candidate list, which this plan starts from and may extend: Pulumi state backends, update
plans, and the Pulumi Kubernetes provider; kapp (Carvel); Kubernetes server-side apply field
management; Helm ownership annotations; Flux and Argo CD (GitOps tools, where the desired state is a
git repository and changes are approved as pull requests); CloudNativePG (a PostgreSQL operator with
barman-cloud backups, fencing, hibernation, and recovery); K8up and restic retention; Velero;
object-store lifecycle rules; and GitHub artifact attestations. Redis and ClickHouse have no
candidate in RES-3; M1 must look for them.

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

Milestone 1 is desk research. For each layer listed above, answer these questions for every
candidate: what exactly it does for the job Nagare's layer does; what it does not do; the current
release and licence (verify against the authoritative registry or release tags, per the repository
owner's instructions, and use `mori registry search` to find local source for any candidate that is
registered); memory and CPU requirements on one node; support for GCS and MinIO; how it records
ownership and history, and whether that would duplicate or replace Nagare's store and journal; how
it could sit beneath Nagare's typed declarations (for example, Nagare compiles and validates claims,
then the tool applies); what multi-operator coordination and approval it offers; and what Nagare
code, tests, and evidence adopting it would retire. Record results in this plan's Surprises &
Discoveries as short findings with source links. Eliminate candidates that clearly cannot fit, with
the reason.

Milestone 2 is prototyping. For each surviving candidate that would replace a data-safety or
ownership layer, run a bounded prototype on a disposable k3d cluster named `mp24-eval` with its own
MinIO. Each prototype states its promote/discard criterion before it runs. At minimum: for
PostgreSQL, back up a known row to MinIO, change it, restore, and read the original back, measuring
the operator's memory; for Kubernetes ownership, deploy two independently owned applications that
both try to claim one Service and record whether the tool refuses the second, and whether it can
represent Nagare's authorized contributions to a shared object; for volume backup, back up and
restore a PVC's contents. Record each result and measurement. Delete the cluster when done. Do not
change Nagare's source; prototypes live under `docs/spikes/mp24-tooling-evaluation/` as scripts and
notes.

Milestone 3 is the comparison. It may begin only after EP-162 M1 is accepted. Write the next
research record in `docs/research/` using the research-documents profile (`docs/research/profile.dhall`),
scoring each surviving candidate per layer against EP-162's requirements (cite each by its use-case
handle) and the questions above, with a recommendation per layer: adopt, keep Nagare's
implementation, or combine. State the pros and cons plainly, including where Nagare's own
implementation is stronger. Mark RES-3 `status: superseded` with `supersededBy` naming the new
handle, and add both changes to the bundle's `log.md` and `index.md`. Then present the
recommendation to the operator and record the outcome in MasterPlan 24's Decision Log. Do not edit
MasterPlan 23.


## Concrete Steps

All commands run from the repository root unless stated.

```bash
k3d cluster create mp24-eval --agents 0
kubectl config use-context k3d-mp24-eval
# ... prototype scripts under docs/spikes/mp24-tooling-evaluation/ ...
k3d cluster delete mp24-eval
```

```bash
okf id next docs/research --profile docs/research/profile.dhall RES
okf validate docs/research --profile docs/research/profile.dhall
```

Before every prototype command, confirm the current kube context is `k3d-mp24-eval`. Stage only the
files this plan changes, by explicit path.


## Validation and Acceptance

M1 is accepted when every layer has at least one candidate evaluated against every question, with
current release versions and sources, and every elimination has a reason. M2 is accepted when every
prototype has a recorded pass/fail against its stated criterion, measured memory use, and the
cluster has been deleted. M3 is accepted when the new research record validates, RES-3 is marked
superseded, every score cites an EP-162 requirement, and the operator's decision on the
recommendation is recorded in MasterPlan 24.


## Idempotence and Recovery

Prototypes are disposable: deleting and recreating `mp24-eval` resets them. If a prototype leaves the
cluster in a bad state, delete it and start again. Documentation steps can be repeated safely.


## Interfaces and Dependencies

M1 and M2 have no prerequisites. M3 has a hard dependency on EP-162 M1, the accepted requirements
use case in `docs/use-cases/` from
`docs/plans/162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md`;
EP-162 M2's availability ADR is a soft input, and without it candidates are scored under the
single-node assumption, stated explicitly. Tools needed locally: k3d, kubectl, Docker (or Colima),
and the candidate tools' own CLIs.
