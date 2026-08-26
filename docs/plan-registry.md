# Nagare Plan Registry

Last reconciled: 2026-08-23

This index closes the discovery gaps that are not represented by a MasterPlan child table. A
MasterPlan's own Exec-Plan Registry remains authoritative for its children; this file registers
standalone plans, cross-project lineage, and retired-plan successors without inventing ownership
relationships.

## Corpus Summary

Nagare contains 19 MasterPlans and 103 ExecPlans. The MasterPlan registries account for 101
ExecPlans; the two completed standalone plans below account for the remaining two. Current semantic
status is 95 implemented, one cancelled, one in progress, and six not started.

The current status review and rewrite-minimizing implementation order are in
[Nagare Project Status and Remaining Implementation Order](project-status-and-implementation-order-2026-08-23.md).

## Standalone ExecPlans

These plans are intentionally standalone. Do not add them to an unrelated MasterPlan solely to make
the count balance.

| Plan | Intention | Status | Relationship |
|---|---|---|---|
| [EP-71 — Kubernetes Deployment workloads for long-running workers](plans/71-kubernetes-deployment-workloads-for-long-running-workers.md) | `intention_01kvce00njestav4ejj7dbfwea` | Complete | Independent extension of the typed workload model. |
| [EP-81 — identity-aware access for Nagare sites](plans/81-identity-aware-access-for-nagare-sites-via-a-shared-shomei-en-forward-auth-enforcer.md) | `intention_01kvxg3mdke08s9pk87a3dqj1b` | Complete | Independent integration of the shared Shomei/En forward-auth path. |

## Cross-Project Plan Lineage

Cross-project lineage uses canonical Mori URIs. The consuming repository keeps its own MasterPlan
and ExecPlans authoritative for local implementation; the originating plan remains authoritative
for the external contract.

| Origin | Nagare coordination | Local plans | State and integration rule |
|---|---|---|---|
| `mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache` | [MP-18 — platform prerequisites for the agent content plane](masterplans/18-platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md) | [EP-94](plans/94-rotating-github-app-installation-token-credentials-for-runtime-pods.md), [EP-95](plans/95-a-one-shot-job-workload-kind-in-nagare-dsl.md), [EP-96](plans/96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md) | EP-95 is Complete; EP-94 is In Progress with the optional forge module and user playbook implemented; EP-96 is Not Started. Live EP-94 acceptance belongs to each enabling operator context. |

The Kikan project is registered as `mori://shinzui/kikan`. As of this reconciliation, the current
Mori release resolves the project but not the artifact-level plan URI above. The intended canonical
URI is retained because registry lag is not a reason to replace it with an ambiguous path.

## Retired Plans and Successors

| Retired plan | Final status | Successor and outcome |
|---|---|---|
| [EP-6 — `nagarectl deploy` CLI in Haskell](plans/6-nagarectl-deploy-cli-in-haskell.md) | Cancelled on 2026-08-23 | [MP-2](masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md) and [EP-12](plans/12-nagarectl-integration-and-full-yaml-cutover.md) replaced the abandoned `nagare.yaml` parser/renderer with typed `nagare/Config.hs` and delivered the intended deploy capability. |

## Mori Discovery

The project manifest registers this index plus both plan directories as internal documentation:

| Mori document URI | Contents |
|---|---|
| `mori://shinzui/nagare/docs/plan-registry` | This curated registry and lineage index. |
| `mori://shinzui/nagare/docs/masterplans` | The MasterPlan corpus. |
| `mori://shinzui/nagare/docs/execplans` | The ExecPlan corpus. |

Use `mori registry docs shinzui/nagare` to discover the registered locations. Artifact-level plan
URIs remain the durable reference form even if the installed Mori version cannot yet resolve every
plan file within a registered directory.

## Maintenance Rules

- Update the owning MasterPlan registry first when a coordinated child changes status or dependency.
- Update this file when a standalone plan is created, a plan is retired, or a cross-project lineage
  is introduced or changed.
- Preserve separate provider and consumer plans across repositories; connect them with canonical
  `mori://` URIs and explicit acceptance boundaries.
- Never mark a superseded plan Complete unless its original milestones were actually delivered.
