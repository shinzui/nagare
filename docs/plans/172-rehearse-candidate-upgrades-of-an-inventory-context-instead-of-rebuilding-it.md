---
id: 172
slug: rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it
title: "Rehearse candidate upgrades of an inventory context instead of rebuilding it"
kind: exec-plan
created_at: 2026-10-04T04:49:45Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-04T04:49:45Z
---

# Rehearse candidate upgrades of an inventory context instead of rebuilding it

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

In MasterPlan 23 every new candidate was verified on a freshly built local context: the old cluster was torn down, a new one bootstrapped with the new payload, and the whole scenario re-created. That proves a fresh install, but not what a running installation experiences when it moves to a new candidate, and it costs a rebuild per candidate. After this plan, a converged inventory context on candidate N can be moved to candidate N+1 through Nagare's reviewed upgrade path and then re-verified, with its data intact and its accepted history continuous. A maintainer can see it by running the upgrade rehearsal on two consecutive candidates and finding the seeded rows still present, the scope revisions advanced only where the payload changed, and an unchanged replan with zero operations afterwards.


## Progress

- [ ] M1 (prototype): Upgrade a disposable converged local context from one MasterPlan 23-era candidate to the next with the existing `platform upgrade` command, and record exactly what works and what refuses. Acceptance: a written gap list with evidence; promote to M2 if the path exists, otherwise record the missing pieces as findings.
- [ ] M2: The upgrade rehearsal is scripted on top of [EP-168](168-script-the-local-acceptance-run-as-one-command.md): converge on N, upgrade to N+1 through reviewed transactions, then run the data checks and the runner verify. Acceptance: a green rehearsal across two real consecutive candidates, with seeded content intact and a zero-operation replan after the upgrade.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Prove upgrade mechanics only on disposable rehearsal contexts; leave work-data upgrade policy to MasterPlan 24 and MasterPlan 21.
  Rationale: The mechanics can be proven now and remove the rebuild-per-candidate cost; policy for installations holding work data depends on MasterPlan 24's evaluation.
  Date: 2026-10-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Platform versions are tracked across the CLI, the payload, the context, the host and the cluster ([ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md), implemented by `docs/plans/108-add-per-context-platform-versions-and-safe-upgrades.md`); the final bootstrap step writes ConfigMap `nagare-platform-version` in namespace `nagare-system`. `nagarectl platform upgrade` exists (`cli/nagarectl/app/Nagare/Cli/Platform/Upgrade.hs`), and its transaction must carry every guard of the recipes it replaces ([ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)). Replacement upgrades with bounded downtime are [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md). MasterPlan 23 explicitly excluded upgrades of inventory contexts; `docs/runbooks/native-verification-harness.md` records this.

What MasterPlan 23 learned that bears on upgrades. A candidate CLI pointed at an older payload workspace can refuse at planning: after F41 the CLI pins the digest of the local MinIO manifest, so the 14071e58 CLI on the 44ff0fd7 payload refused with "pinned MinIO manifest digest changed". So an upgrade must move the context's payload workspace together with the CLI, through a reviewed transaction, rather than running a new CLI against an old workspace. Re-accepting platform scopes (even with zero operations) advances their generations and makes the bootstrap stamp (`nagare-platform-version`) stale, so the next bootstrap plan proposes one stamp update; an upgrade must account for that. Local MinIO now keeps backups on a local-path volume (F41), so backup objects survive pod restarts during an upgrade.

The scenario, its seeded content and its checks are produced by EP-168; this plan reuses its stages against an upgraded context instead of a fresh one.


## Plan of Work

M1 (prototype): on the cp3 Colima profile, use EP-168's first milestone to converge a context on candidate N, then run `nagarectl platform upgrade` with candidate N+1's package, reviewing each saved plan. Record which scopes change, whether the payload workspace moves, how the bootstrap stamp behaves, whether data survives, and any refusal. Discard criterion: if the upgrade path cannot move an inventory context without a teardown, record that as a finding against the upgrade code and stop; do not work around it.

M2: script the rehearsal (`scripts/run-local-upgrade-rehearsal.sh`) reusing EP-168's stages: bootstrap and scenario on N, upgrade to N+1, then the backup and restore checks against the seeded content, independent scope preservation, and the runner verify with an unchanged candidate. Produce evidence that [EP-170](170-size-the-release-gate-to-the-change.md) can accept for change classes where an upgrade rehearsal is sufficient, and hand the results to MasterPlan 24's upgrade-path stream.


## Concrete Steps

```bash
scripts/run-local-upgrade-rehearsal.sh \
  --from /path/to/result-<N>-nagare --to /path/to/result-<N+1>-nagare \
  --images /path/to/oci-layout --operator-root /private/tmp/nagare-upgrade-<N>-<N+1>.XXXXXX \
  --replace-cluster   # only with the operator's approval
```

Expected ending:

```text
upgrade: converged <transaction>
data checks: postgresql, redis, clickhouse, volume rows intact
verify: zero-operation replan
```


## Validation and Acceptance

A green rehearsal across two real consecutive candidates: the upgrade converges through reviewed transactions, seeded rows and files read back unchanged, scope revisions change only for scopes whose payload content changed, the store is idle with accepted equal to converged, and an unchanged replan has zero operations. A refusal at any step stops the rehearsal and is recorded, never worked around.


## Idempotence and Recovery

The rehearsal uses a disposable local context. If the upgrade stops ambiguous, the supported paths are `inventory resume` and the recorded recovery decisions; anything else stops the rehearsal. The cluster can always be rebuilt with EP-168.


## Interfaces and Dependencies

Hard dependency: EP-168 M1 (a scripted bootstrap and scenario that leaves a converged context). Soft dependency: EP-170 (the gate decides when an upgrade rehearsal can replace a fresh-context C2). Produces upgrade evidence for MasterPlan 24 and MasterPlan 21.
