# Nagare Project Status and Remaining Implementation Order

Status date: 2026-08-23 (America/Los_Angeles)

Input baseline: `master` at `d76557f`, matching `origin/master`, with no pre-existing worktree changes before this report was added.


## Executive Summary

Nagare is substantially implemented. The repository contains 19 MasterPlans and 103 ExecPlans. Of the 103 ExecPlans, 95 have delivered their intended behavior, or 92.2 percent. One additional plan, EP-6, is formally Cancelled after its intended capability was delivered through a successor. Seventeen MasterPlans have no active child work: sixteen are fully delivered and MP-1 is resolved with six Complete children plus the cancelled EP-6. Two completed standalone plans, EP-71 and EP-81, are now explicitly indexed in [the plan registry](plan-registry.md) and are included in the 95-plan implemented total.

Seven plans remain active:

- one genuinely in-progress plan: EP-99; and
- six genuinely not-started plans: EP-94, EP-96, and EP-100 through EP-103.

EP-6 has been retired as Cancelled rather than implemented or falsely marked Complete. The most rewrite-resistant order is to finish EP-99 first, land EP-94/EP-100/EP-102 before their consumers, then implement EP-101 and EP-96, and leave the broad host-and-documentation synchronization in EP-103 until last.

This is a source-and-plan status review, not a fresh release qualification. No full `nix flake check`, live cluster test, Pulumi preview, or GCP apply was run for this report. Existing plan transcripts are treated as historical evidence; current source was inspected to confirm the open gaps.


## Project State

The implemented platform already covers the original personal-PaaS foundation and most later product work:

- GCP/Pulumi infrastructure, NixOS/k3s host management, Knative/Kourier ingress, cert-manager, and the Victoria observability stack;
- the typed Haskell deployment DSL and `nagarectl`, with Dockerfile, prebuilt-image, and Nixpacks build modes;
- static and full-stack sites, application lifecycle/history, environment and secret management, volumes and backups, managed databases, scheduled tasks, workers, multi-workload application rollouts, brokers, CDN configuration, and identity-aware access;
- bring-your-own-project onboarding, first-class cloud/local target contexts, a local k3d/registry/MinIO path, CI/live-smoke scaffolding, and hardened target guardrails; and
- the first-class one-shot Job workload from [EP-95](plans/95-a-one-shot-job-workload-kind-in-nagare-dsl.md).

The plan-level state is:

| Area | State | Interpretation |
|---|---:|---|
| ExecPlans | 95 implemented, 1 cancelled, 7 active | 92.2 percent delivered; 93.2 percent resolved |
| MasterPlans | 17 of 19 have no active child work | MP-1 is resolved by EP-6's cancellation; MP-18 and MP-19 contain real remaining work |
| [MP-18](masterplans/18-platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md) | 1 of 3 complete | EP-95 complete; EP-94 and EP-96 not started |
| [MP-19](masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md) | 2 complete, 1 in progress, 4 not started | EP-97 and EP-98 complete; EP-99 in progress; EP-100 through EP-103 not started |
| Standalone plans | EP-71 and EP-81 implemented and registered | Both are indexed without being assigned to an unrelated MasterPlan; EP-71 has only optional live validation deferred and EP-81 contains live end-to-end evidence |

The count uses delivered behavior rather than blindly counting unchecked boxes. Several older plans were marked Complete while retaining explicit, environment-gated validation items. Those deferrals are discussed separately below and are not reclassified as unimplemented features.


## Unimplemented and Retired Plans

Checklist ratios below are item counts, not estimates of effort.

| Plan | Declared state | Summary and current evidence |
|---|---|---|
| [EP-6 — nagarectl deploy CLI in Haskell](plans/6-nagarectl-deploy-cli-in-haskell.md) | Cancelled; retirement verified | Retired on 2026-08-23, not missing product work. It specified the abandoned `nagare.yaml` design. MP-2 EP-9 through EP-12 built `cli/nagarectl/` and replaced YAML with typed `nagare/Config.hs`; the plan and MP-1 now record the successor and no longer expose EP-6 as active work. |
| [EP-99 — protect stateful infrastructure and make secrets and state recoverable](plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md) | In Progress; 4/10 | The code half is present: Pulumi deletion protection, bucket hardening/versioning, snapshot policy, scoped DNS IAM, VM deletion protection, and boot-disk configuration. Remaining work requires an operator-controlled cloud context and credentials: preview/apply and live verification; creation and vaulting of the offline recovery age key; re-keying encrypted files, including the host-only secret through the running VM; disaster-recovery documentation; and migration of the real Pulumi state to versioned GCS. |
| [EP-94 — rotating GitHub App installation-token credentials](plans/94-rotating-github-app-installation-token-credentials-for-runtime-pods.md) | Not Started; 0/5 | Create separately scoped read/write GitHub Apps, store their bootstrap material through host sops-nix, add independent systemd refresh timers, publish stable `nagare-forge-read` and `nagare-forge-write` Kubernetes Secrets, document consumption and recovery, and prove rotation plus least privilege live. No forge module or Secret publisher exists yet. |
| [EP-96 — in-cluster Attic Nix binary cache](plans/96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md) | Not Started; 0/7 | Pin and review Attic; provision a protected GCS cache bucket, HMAC credentials, and Pulumi outputs; deploy Attic with managed Postgres, migrations, GC, policies, and a stable client ConfigMap; then prove laptop push, in-cluster substitution, signature rejection, durability, and key rotation. No Attic input, Pulumi cache resources, or `cluster/bootstrap/nix-cache/` component exists yet. |
| [EP-100 — bound and harden cluster workloads](plans/100-bound-and-harden-cluster-workloads.md) | Not Started; 0/20 | Add resource bounds, probes, and security contexts to the auth plane; move Grafana credentials to a sops-managed Secret; single-source Grafana datasources; cap VictoriaLogs/Traces disk use; fix auth migrations so new migrations actually run; use immutable auth-image tags by default; and pin MinIO. Current source still has the placeholder Grafana password and lacks the planned resource bounds. |
| [EP-101 — alerting and backup freshness monitoring](plans/101-alerting-and-backup-freshness-monitoring.md) | Not Started; 0/16 | Enable vmalert and Alertmanager with a Pushover receiver, add five actionable alert families, fix `nagarectl server status` to inspect `databases/<name>` rather than the removed `postgres/` backup prefix, add a local managed-Postgres backup/restore round trip, and schedule a monthly cloud smoke drill. Current Helm values still disable both alerting components. |
| [EP-102 — nagarectl correctness and robustness fixes](plans/102-nagarectl-correctness-and-robustness-fixes.md) | Not Started; 0/14 | Fix database credential URL safety, total UTF-8 decoding, readiness-wait failure reporting, and verified application-label stamping, then perform a small style cleanup. Current source still uses `openssl rand -base64 24`, partial `decodeUtf8`, throwing `IO ()` waits, and unchecked byte-level label insertion. |
| [EP-103 — host tuning, upgrade story, and documentation reality sync](plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md) | Not Started; 0/19 | Restrict the host kubeconfig, enable k3s Secret encryption, add small-node tuning, replace 45-minute k3s restarts with a refreshed image-pull Secret, correct the net-certmanager source/version story, add an upgrade guide, and reconcile the disaster-recovery and secret documentation with reality. Current source still uses kubeconfig mode `0644`, the restart timer, stale target-profile wording, and a “Planned” cluster-secret section. |


## Rewrite and Integration Risks

The remaining plans are not independent in practice even where their MasterPlans declare only soft dependencies.

1. **EP-99 owns the final encryption and Pulumi baseline.** EP-94 edits the host sops file; EP-100 and EP-101 create new encrypted cluster Secrets; EP-96 extends the same Pulumi component files. Doing any of those first would force re-keying new Secrets or reconciling Pulumi edits against a moving hardening baseline.

2. **EP-100 owns the observability structure that EP-101 consumes.** Both edit `cluster/observability/victoria-metrics/values.yaml` and `cluster/observability/install.sh`. EP-100 establishes the sops-managed Secret pattern, Grafana ownership, datasource mechanism, and resource conventions. EP-101 should then add only the vmalert/Alertmanager blocks and alert artifacts.

3. **EP-102 should precede the database-based acceptance work.** EP-101's local restore drill and EP-96's Attic metadata database both exercise `nagarectl db create`. Landing URL-safe credentials and total decoding first means both later plans validate the final database path instead of baking tests around known-broken behavior.

4. **EP-101 should precede EP-96's capacity alerts.** EP-96 currently describes enabling a minimal alerting path itself because alerting did not exist when it was authored. Once EP-101 lands, EP-96 should be revised to add only its cache-specific rules to the established alerting substrate. This avoids implementing and then replacing a second vmalert/Alertmanager setup.

5. **EP-103 should be the final convergence pass.** EP-99, EP-101, EP-94, and EP-96 all alter facts that broad operator documentation may describe: recovery keys, backup prefixes, Secret workflows, new host timers, bootstrap components, upgrade procedures, and `justfile` recipes. Writing the “reality sync” before those plans would make its new documentation stale immediately.

6. **MP-18 needs a cross-repository reconciliation before more implementation.** Its originating Kikan authoring plan is canonically `mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`. The project is registered in Mori, but current Mori artifact coverage does not yet resolve that plan URI. The plan exists in the Kikan source and still reports Not Started even though Nagare MP-18 and EP-95 exist; its promised Nagare conformance fixtures are also absent. Before EP-94 or EP-96 starts, update the Nagare plans against the current Kikan C16 boundary and either provide those fixtures or explicitly record the remaining cross-repository acceptance gap. This is plan reconciliation, not a new Nagare feature.


## Recommended Implementation Order

The strict integration order below minimizes repeated edits. Steps 2 through 4 can be developed concurrently after EP-99, but should be merged before their downstream consumers.

### 0. Reconcile the remaining cross-project baseline

EP-6 retirement and Nagare-side plan registration are complete. Before implementing MP-18's open children, reconcile MP-18, EP-94, and EP-96 with the canonical Kikan authoring plan and the current state of its C16/conformance artifacts. This prevents work from starting against a stale provider/consumer boundary.

### 1. Finish EP-99

Restore/select the real cloud context, reauthenticate GCP/Pulumi, run the required no-replacement preview, apply and verify the protection changes, establish the offline recovery recipient, re-key both encrypted files, migrate the actual cloud context's Pulumi state, and finish the runbook and plan bookkeeping. This freezes the secret-recipient and Pulumi foundations every later infrastructure plan should inherit.

### 2. Implement EP-94

Add the GitHub App roles and host refreshers only after the host secret has its final recovery recipients. Doing this now avoids editing and re-keying the same encrypted host file twice. Its live external-App setup can proceed independently of cluster observability work.

### 3. Implement EP-100

Establish resource/security defaults, the Grafana Secret pattern, datasource ownership, retention caps, and correct migration/image behavior. This plan should land before anything else changes the observability Helm values or install script.

### 4. Implement EP-102

Fix the database, decoding, wait, and label-stamping correctness issues before new end-to-end database consumers are added. It is largely disjoint from EP-94 and EP-100, so these three plans form a safe implementation wave after EP-99.

### 5. Implement EP-101

Build alerting on EP-100's finalized observability structure and exercise the corrected database path from EP-102 in the local backup/restore drill. Let EP-101 own the backup-prefix correction in both code and the disaster-recovery runbook.

### 6. Revise and implement EP-96

Rebase the plan before coding: consume EP-101's alerting substrate instead of enabling a parallel one, inherit EP-99's hardened Pulumi conventions, and use EP-102's corrected database creation path. EP-95 already supplies the optional Job-side cache mount integration. Then deliver the Attic cache and its full push/substitute/durability proof.

### 7. Implement EP-103 as the convergence pass

Apply host tuning and registry-credential changes, then make the upgrade, recovery, secret, reference, README, and `justfile` documentation describe the final state after EP-94, EP-96, EP-99, and EP-101. Before starting, update EP-103's documentation scope to include the newly delivered forge refresher and Attic component where operator upgrades or recovery require it.

The rewrite-minimizing dependency shape is:

```text
EP-99 -> EP-94 -------------------------------> EP-103
EP-99 -> EP-100 -> EP-101 -> EP-96 -----------> EP-103
EP-99 -----------------------------> EP-96
EP-102 -> EP-101
EP-102 -------------> EP-96
EP-101 ----------------------------> EP-103
```

EP-94 does not technically block EP-100 or EP-102; all three simply become safe once EP-99 establishes the final secret and infrastructure baseline. EP-102 can start earlier, but merging it before EP-101 and EP-96 prevents those plans from validating against known-broken database behavior. EP-103 depends on the observable final state of every branch, not merely on EP-96.


## Deferred Validation Debt That Is Not New Implementation

Some completed plans retain explicit live or environment-gated checks. The main examples are wildcard TLS against a real delegated domain, portions of CDN/static-site live validation, a clean-room disaster-recovery drill, and optional live worker validation. These are real operational confidence gaps, but the associated feature code is present and the MasterPlans deliberately marked the plans complete with the deferrals recorded.

Treat this as a separate verification backlog rather than reopening completed or cancelled plans indiscriminately. Once EP-99 and EP-103 make recovery practical and truthful, the highest-value follow-up is a scratch-context clean-room disaster-recovery exercise. It would validate several existing deferrals at once without reimplementing their features.


## Bookkeeping State

The local bookkeeping recommendations from this review are complete:

- EP-6 is formally Cancelled, with MP-1 dependencies and successor lineage updated;
- standalone EP-71 and EP-81 are explicitly indexed in [the plan registry](plan-registry.md);
- MP-18's canonical Kikan origin and local EP-94 through EP-96 lineage are registered; and
- Mori now advertises the plan index plus both plan directories as Nagare documentation.

One cross-repository action remains before EP-94 or EP-96 implementation: reconcile the Kikan-owned plan and conformance artifacts with Nagare's current MP-18/EP-95 state. Nagare records that dependency but does not claim ownership of the Kikan files.
