---
type: Research Document
title: Managed-resource inventory scope and overlap with established tooling
description: Assess which parts of MasterPlan 23's typed inventory are unique to Nagare and which re-implement established infrastructure, Kubernetes, backup, and database tooling, now that Nagare also serves as a workplace intranet PaaS.
generated:
  by: process:claude-code
  at: "2026-09-28T14:23:24Z"
researchId: RES-3
status: superseded
supersededBy: RES-6
scope: >-
  MasterPlan 23, IR-24, ADR 22, and EP-151 as of repository revision 7824fbd6 on 2026-09-28, plus
  source-size and commit measurements. Candidate external tools were identified from their official
  documentation landing pages only; no candidate was installed, prototyped, benchmarked, or compared
  in depth. No live context was read or changed.
relatedPlans:
  - mori://shinzui/nagare/masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas
  - mori://shinzui/nagare/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories
  - mori://shinzui/nagare/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare
  - mori://shinzui/nagare/plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes
relatedDecisions:
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
sources:
  - id: mp23
    resource: mori://shinzui/nagare/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories
    title: MasterPlan 23, typed scoped inventories
  - id: ep151
    resource: mori://shinzui/nagare/plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes
    title: EP-151 shared inventory store in the context state bucket
  - id: pulumi-state
    resource: https://www.pulumi.com/docs/iac/concepts/state-and-backends/
    title: Pulumi state and backends
  - id: pulumi-update-plans
    resource: https://www.pulumi.com/docs/iac/concepts/update-plans/
    title: Pulumi update plans
  - id: pulumi-kubernetes
    resource: https://www.pulumi.com/registry/packages/kubernetes/
    title: Pulumi Kubernetes provider
  - id: kapp
    resource: https://carvel.dev/kapp/
    title: Carvel kapp
  - id: server-side-apply
    resource: https://kubernetes.io/docs/reference/using-api/server-side-apply/
    title: Kubernetes server-side apply and field management
  - id: flux
    resource: https://fluxcd.io/flux/
    title: Flux documentation
  - id: argocd
    resource: https://argo-cd.readthedocs.io/en/stable/
    title: Argo CD documentation
  - id: cloudnative-pg
    resource: https://cloudnative-pg.io/documentation/current/
    title: CloudNativePG documentation
  - id: cloudnative-pg-fencing
    resource: https://cloudnative-pg.io/documentation/current/fencing/
    title: CloudNativePG fencing
  - id: velero
    resource: https://velero.io/docs/main/
    title: Velero documentation
  - id: k8up
    resource: https://k8up.io/
    title: K8up backup operator
  - id: restic-forget
    resource: https://restic.readthedocs.io/en/stable/060_forget.html
    title: restic snapshot retention policies
  - id: gcs-lifecycle
    resource: https://cloud.google.com/storage/docs/lifecycle
    title: Cloud Storage object lifecycle management
  - id: github-attestations
    resource: https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds
    title: GitHub artifact attestations
---

# Managed-resource inventory scope and overlap with established tooling

Evidence checked: 2026-09-28. This record captures a first-pass assessment made during one review
session. It informs a later decision; it does not amend MasterPlan 23, and it selects no tool.

> **The tooling comparison is not yet a real evaluation.** Every external tool named here was
> identified as a *candidate* from its purpose and official landing page. None was installed,
> prototyped on Nagare's single-node k3s or local k3d targets, measured for memory, or compared
> against Nagare's restore, review, and ownership semantics. The overlap table below says where a
> tool *appears* to cover the same job; it does not claim the tool is better, sufficient, or even
> compatible. The pros and cons of each candidate, and whether the best choice is an established
> tool or Nagare's own implementation, remain open questions for the follow-up evaluation.

## Question

Does [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md)
make Nagare better, or does it duplicate functionality that belongs to other tools and should not
live in Nagare? How does the answer change now that Nagare is not only a personal PaaS?

## Context change: Nagare is also a workplace intranet PaaS

The README, initial spec, and project metadata describe Nagare as a cheap, single-node **personal**
PaaS. As of 2026-09-28 the operator intends to also run it as a PaaS for an intranet at work. The
first pass of this review judged MasterPlan 23 against the personal-tool framing. Its conclusions
about proportionality were revised once the operator stated the workplace use (see
[Reassessment for team use](#reassessment-for-team-use)); its conclusions about overlap with
established tools were strengthened rather than weakened.

## Provisional findings

1. **The typed inventory core is Nagare-specific and worth keeping.** Typed declarations with stable
   logical IDs, explicit owners, cross-scope claim composition that rejects conflicts before any
   mutation, one compile path for render and review, and the separation of desired, observed, and
   historical state address the [IR-24](../improvement-requests/make-managed-resources-first-class.md)
   incident directly: the managed PostgreSQL helper and the Attic runtime both claimed
   `Service/nagare-system/nix-cache`, and Kubernetes accepted the second apply. No single candidate
   tool sees claims across Pulumi, NixOS, Kubernetes, and Nagare's data helpers at once. With several
   teams deploying, this cross-owner check becomes more valuable.
2. **A large share of the later work appears to re-implement established tools.** The plan states
   that it does not reproduce Pulumi state, NixOS activation, Kubernetes controllers, or Helm
   reconciliation. In practice it added its own state store, journal, planner, executor, recovery
   protocol, backup receipts, retention pruning, data fencing, live restore, and fenced interactive
   maintenance above those tools. None of the plan's documents (MasterPlan 23, ADR 22, IR-24,
   EP-144–161) names or evaluates an established alternative for these jobs. A text search found no
   mention of kapp, Flux, Argo CD, Velero, K8up, CloudNativePG, pgBackRest, or Barman. The
   "rejected alternatives" in MasterPlan 23 compare only different ways of building it in-house.
3. **Workplace use makes maintainability and audit by colleagues a first-order requirement.**
   Custom backup, restore, and fencing code has one maintainer and, so far, evidence from one local
   k3d fixture. Established operators come with public documentation, many production restores, and
   prior security review. That favours established tools *if* they fit, which is exactly what has not
   been tested.
4. **The plan does not address the requirements that team operation adds.** See
   [Team-operation gaps](#team-operation-gaps).

## Method and limits

- Read the whole of MasterPlan 23 and the opening of IR-24, and searched ADR 22, EP-151, and the
  EP-144–161 plans for named alternatives and for lease/takeover wording.
- Measured Haskell source size with `wc -l` over `cli/**.hs` at the last commit before 2026-09-16
  and at the current tree, and counted the `Nagare/Inventory` and `Nagare/Resource` modules.
- Counted repository commits since 2026-09-16. This counts all repository commits, not only
  MasterPlan 23 work.
- Checked that each external source URL resolves. Nothing beyond that was verified about the
  candidate tools.
- Did not read every child ExecPlan, audit implementation correctness, or run any live command.

## What MasterPlan 23 contributes that the candidates do not

| Contribution | Why it is Nagare-specific |
|---|---|
| Typed scope declarations with stable `ResourceId`s and owners | Nagare's domain vocabulary (apps, databases, brokers, sites, platform components) spans several native tools. |
| Cross-scope claim composition before mutation | Catches collisions between owners that use different native tools, such as the IR-24 Service. |
| One compile path for render, review, and execution | Replaces guards that had been copied across scripts; keeps the reviewed plan and what runs identical. |
| Independent scopes with authorized contributions to shared platform objects | Lets application owners change shared routing and configuration without owning the whole object or advancing the platform release. |
| Data retained by default; deletion bound to exact physical identity | A safety policy that applies across providers. |

These parts could sit *in front of* native tools as a validation and review gate, whether or not
Nagare keeps its own executor.

## Apparent overlap with established tools (candidates only, not evaluated)

| Nagare component (child plan) | Candidate tool(s) that appear to cover the job | What a real evaluation must establish |
|---|---|---|
| Store, journal, plan, apply, resume, conditional writes, executor claims (EP-145, EP-151) | Pulumi state backends and update plans; Pulumi's Kubernetes provider if cluster resources moved under Pulumi | Whether one state system can replace two. Today the inventory store sits beside Pulumi state in the same bucket, and the two records can disagree. Cost of putting Knative/Helm resources under Pulumi. |
| Cluster ownership, review diffs, adoption, pruning (EP-147, EP-149) | kapp (app-scoped ownership, diff review, label-based pruning); server-side-apply field managers; Helm ownership annotations; Flux or Argo CD for GitOps | Whether the candidate's ownership model can express Nagare's shared-object contributions; how it composes with the inventory's claim check; local k3d parity. |
| Scheduled backup receipts, exact-version retention pruning, receipt ingestion (EP-159) | CloudNativePG with barman-cloud; K8up or restic retention (`forget --keep-*`); Velero; object-store lifecycle rules | Coverage for all three engines (PostgreSQL, Redis, ClickHouse) and volumes; MinIO and GCS support; how retention interacts with restore references. |
| Data fence, fenced live restore, recovery after terminal loss (EP-160) | CloudNativePG fencing, hibernation, and recovery bootstrap; database-operator restore procedures generally | Whether operator restore semantics meet Nagare's safety bar; what happens for Redis and ClickHouse, which have no equivalent operator in this list. |
| Reviewed, fenced interactive `db shell` with NetworkPolicy isolation (EP-161) | A pre-shell backup plus `kubectl exec` with a database client; operator-provided maintenance modes | Whether a workplace audit requirement justifies the reviewed session model, or whether logging and RBAC suffice. |
| Mandatory immutable release evidence (EP-157) | Nix-pinned release tags plus GitHub artifact attestations or SLSA provenance | Which evidence items attestations cannot express (native-system rehearsals, coverage) and whether those need a custom index. |

Pros and cons that the evaluation should score for every candidate:

- memory and CPU footprint on a single node, and on the local k3d profile;
- restore behaviour and how much recovery evidence it provides;
- support for both GCS and MinIO backends;
- how it composes with the inventory's typed declarations and claim check, rather than duplicating
  ownership records;
- learning curve and documentation available to colleagues;
- licence, release cadence, and upgrade burden;
- what existing Nagare code and evidence would be retired, and at what migration cost.

## Proportionality evidence

| Measure | Value |
|---|---|
| Haskell lines under `cli/`, last commit before 2026-09-16 | about 49,800 |
| Haskell lines under `cli/`, 2026-09-28 | about 113,800 |
| Lines in `Nagare/Inventory` and `Nagare/Resource` modules | about 36,000 |
| Repository commits since 2026-09-16 (all work) | 637 |
| MasterPlan 23 children still active | 9, with the plan's own forecast withdrawn |

MasterPlan 23's own diagnosis records a nine-hour data-fence session with 2,451 tool requests and
repeated interface rework. Recent checkpoints include HMAC-signed Redis receipts and recovery of
ClickHouse maintenance sessions after terminal loss. Opening a database shell now needs a saved
review, a data fence, and a recovery backup, and the integration fixtures needed a six-CPU Colima
profile.

## Reassessment for team use

For a workplace intranet holding shared data, the plan's data-safety and audit rigor is justified:
saved reviews bound to a content digest plus an execution journal give an audit trail, and cautious
retention and exact-identity deletion are appropriate when the data is not the operator's alone. The
first-pass criticism that the rigor was disproportionate is withdrawn.

The overlap concern is stronger in this setting. Colleagues must be able to run, audit, and recover
the platform. Established tools can be learned from public documentation and hired for; tens of
thousands of lines of custom recovery code cannot. Whether the established tools actually fit
Nagare's semantics is still untested.

## Team-operation gaps

These are not covered by MasterPlan 23's nine active children:

1. **One writer at a time, without a lease.** EP-151 deliberately implements a single-writer store
   with no lease, heartbeat, or liveness detection; a stuck run needs an explicit operator takeover,
   and MasterPlan 23 does not claim multi-workstation exclusion. Acceptable for one operator; routine
   friction with several.
2. **Review approval is local to one workstation.** A saved review is published by the operator who
   runs it. Nothing records who may approve a review or binds approval to a named reviewer, whereas
   GitOps tools get multi-person review from pull requests.
3. **No path for existing contexts to take a new platform version.** MasterPlan 23's first release
   covers fresh contexts and treats existing data as disposable; in-place upgrade is deferred and
   the separate replacement-upgrade initiative (MasterPlan 21) is independent. Once work data
   exists, that deferral blocks upgrades.
4. **Access control for several operators.** Operator credentials, sops recipients, and context
   access are modelled for one operator's private repository (ADR 13); how a team shares and revokes
   that access is undefined.
5. **Availability is single-node by default, not by decision.** Databases and brokers are
   documented as non-HA and single-replica. That may be acceptable for an intranet, but it should be
   an explicit decision with stated recovery objectives.

## Implications and next steps

- MasterPlan 23 is unchanged by this record. The operator will research further before amending it.
- The team-operation requirements and the tooling evaluation are captured as a follow-up initiative,
  [MasterPlan 24](../masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas.md), which
  begins with the evaluation this record says has not happened.
- A later research record should supersede this one with measured evaluations of the candidates.

## Decision summary

Keep the typed inventory core. Treat the executor, backup, restore, fencing, maintenance, and release
evidence layers as open questions: they overlap established tools on paper, but no candidate has
been evaluated, so neither keeping nor replacing them is justified by this record alone.
