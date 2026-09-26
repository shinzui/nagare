---
id: 155
slug: prove-local-application-and-data-recovery-end-to-end
title: "Prove local application and data recovery end to end"
kind: exec-plan
created_at: 2026-09-26T20:29:54Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T20:29:54Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-26T22:23:39Z
      mode: "update"
      note: "Cascade EP-148 decomposition: assign remaining feature, cutover, and proof ownership without weakening release acceptance"
---

# Prove local application and data recovery end to end

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


One reproducible disposable local run proves that the installed Nagare candidate bootstraps its components, deploys independent applications, preserves data, and recovers interrupted work using the public commands. This owns the outstanding combined native application membership proof transferred from EP-148 and consumes EP-158–161, while cloud and final release checks remain mandatory.


## Progress


- [ ] M1: A checked-in local fixture reaches full platform/application/data convergence with exact review/execution membership and an unchanged rerun without unintended writes.
- [ ] M2: The same fixture proves interruption/resume, adoption refusal, data-preserving migration, backup/restore, retained removal, and history restoration with reusable evidence.

Inherited baseline: InventoryIntegrationSpec covers a recording platform/two-app/cache scenario; scripts/rehearse-managed-resources.sh already has plan/apply/verify and refusal tests. EP-147 has a prior local bootstrap proof. EP-148 has worker-only and task-deletion native probes, plus recording webhook proofs. None alone proves this combined scenario.


## Surprises & Discoveries


No new implementation findings in this successor plan. Inherited evidence and known gaps are identified below.


## Decision Log

2026-09-26: Redirect unfinished EP-148 dependencies to EP-158–161 and preserve this plan’s assigned integration, package, or release obligations. EP-148 is superseded history, not a pending completion gate.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.


## Outcomes & Retrospective


Remaining-work plan created; no new acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator requested decomposition without reduced functionality or validation; temporary refusal of promised behavior is not completion.

cli/nagarectl/test/InventoryIntegrationSpec.hs currently injects loss at each operation in a synthetic multi-scope fixture. scripts/rehearse-managed-resources.sh checks explicit context/cluster and records candidate, review, final observation, and a fresh no-op review; scripts/test-rehearse-managed-resources.sh tests its protocol. scripts/test-inventory-scope-isolation.py and scripts/test-nagared-inventory-guard.py contain reusable command probes. Place the consolidated source fixture under fixtures/inventory-release/local/ and its public acceptance runner at scripts/rehearse-local-inventory-release.sh; retain the generic launcher as the authoritative phase protocol.


## Plan of Work


M1 checks fixture health once before publishing reviews: reachable Kubernetes API, ready Knative admission, working registry/image access, and a ready object store. The earlier local cluster had a crash-looping Knative webhook and an unavailable pinned MinIO image; resolve those specific fixture failures rather than loop on failed deployment. Use Mori and upstream sources before changing any dependency/image version. Create one platform plus app A and app B, protected routing/auth, database and backup, broker topic, scheduled task and one-off/hook Job, preview, Runtime/Preview/Secret channels, and image publication. Use the existing offline Cloudflare transport proof for that provider; local recording CDN checks must never be described as live DNS proof. EP-156 supplies the live Google path. Expose public-command assertions for app-only updates, preserved other-owner revisions, environment survival, and exact native membership.

M2 extends fault injection to the actual stage roles: cloud/host stand-ins only in deterministic tests, database readiness, migration completion, cluster completion, and final marker. The native local run exercises actual local stages and proves no duplicate effects after acknowledgement loss. Put known rows/files into the fixture, take a reviewed backup, restore and compare content, reject wrong data incarnation, migrate a named durable fixture while preserving rows/signing identity, and collect only exact eligible members while retaining protected neighbors. Restore a private history export into isolated state and prove the same accepted identities. This plan owns the outstanding native migration/collection adapter bindings transferred from EP-148 under EP-149's existing lifecycle contract, including exact eligible database/broker companion, topic, schedule, and preview cleanup promised by the command coverage audit. Preserve supported topic-operation bounds and retained data; do not silently narrow them to the easiest fixture. [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) owns scheduled backups/pruning, [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) restore and fencing, [EP-161](161-provide-scoped-interactive-maintenance-with-durable-recovery.md) maintenance, and [EP-158](158-complete-reviewed-access-and-cdn-operations.md) access/CDN command behavior. Use one retained PostgreSQL fixture with a stable logical identity and known rows for the rename, while verifying unrelated auth signing-key identity remains fixed. A missing binding is implementation work here, not permission to replace the assertion with a recording test or wait for an already-complete EP-149. Also exercise the inherited Build/Secret input and local registry publication path, Knative stop/restart and preview behavior, and the reviewed in-cluster webhook consumer delivered by EP-153. Include scheduled receipt survival and exact pruning, all supported database-engine/live-volume restore assertions from EP-160, and maintenance interruption/re-observation from EP-161. Targeted native runs may be referenced with exact candidate/fixture identity instead of repeated; missing assertions remain open. Cleanup follows reviewed ownership and retains recovery evidence after a failed run.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p "inventory integration"' --test-show-details=failures)
bash scripts/test-rehearse-managed-resources.sh
bash scripts/rehearse-managed-resources.sh --help
# Required new runner interface; implement before invoking:
: "${NAGARE_TEST_CONTEXT:?exact disposable local context}"
: "${NAGARE_TEST_CLUSTER:?exact disposable cluster}"
: "${NAGARE_TEST_EVIDENCE:?new public evidence directory}"
bash scripts/rehearse-local-inventory-release.sh --phase plan --context "$NAGARE_TEST_CONTEXT" --expected-cluster "$NAGARE_TEST_CLUSTER" --evidence-dir "$NAGARE_TEST_EVIDENCE"
```

Expected result: relevant checks exit zero; refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance


The new runner follows the existing separate plan/apply/verify protocol: plan only saves the concrete review, apply requires that saved evidence and explicit --yes, and verify recompiles unchanged intent against the new accepted snapshot. It does not combine planning and mutation by default. The fixture records all specified assertions as pass/fail with command and resource identities. Review membership equals executor effects, app B/platform generations survive app A updates, the fresh unchanged candidate has no unintended writes, and a failed run never prints success. Data and signing identity survive the selected migration/recovery paths; foreign identity and missing receipt tests refuse. Public evidence contains only safe digests and observations, with a separate private export. An unhealthy fixture stops before mutation with a named blocker. Cloud-specific assertions remain explicitly assigned to EP-156, never claimed from this local run.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Completed EP-146/147/149/151 are hard prerequisites. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) supplies bootstrap, [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md) installed candidates, and the delivered EP-148 baseline plus [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md), and [EP-161](161-provide-scoped-interactive-maintenance-with-durable-recovery.md) actual operational commands. Fixture and fault-test development starts now. Shared provider assertions require working command paths, not administrative closure of their feature plan, so feature plans can cite these results without a cycle. Accept this plan only when its full scenario and transferred native binding obligations pass. [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) reuses the fixture contract and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes the evidence. Initial estimate: 4–12 active hours excluding EP-158–161 implementation and fixture outages, low confidence; revise after the first health preflight and whole-scenario run.
