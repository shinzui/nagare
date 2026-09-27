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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T14:29:12Z
      mode: "implement"
      note: "Start local health fixture and repair observed k3d registry provider binding"
---

# Prove local application and data recovery end to end

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


One reproducible disposable local run proves that the installed Nagare candidate bootstraps its components, deploys independent applications, preserves data, and recovers interrupted work using the public commands. This owns the outstanding combined native application membership proof transferred from EP-148 and consumes EP-158–161, while cloud and final release checks remain mandatory.


## Progress


- [ ] M1: A checked-in local fixture reaches full platform/application/data convergence with exact review/execution membership and an unchanged rerun without unintended writes.
- [ ] M2: The same fixture proves interruption/resume, adoption refusal, data-preserving migration, backup/restore, retained removal, and history restoration with reusable evidence.

Inherited baseline: InventoryIntegrationSpec covers a recording platform/two-app/cache scenario; scripts/rehearse-managed-resources.sh already has plan/apply/verify and refusal tests. EP-147 has a prior local bootstrap proof. EP-148 has worker-only and task-deletion native probes, plus recording webhook proofs. None alone proves this combined scenario.

Early fixture handoff (2026-09-27): `fixtures/inventory-release/local/health.json` and `scripts/rehearse-local-inventory-release.sh` now bind an exact local k3d target to the existing saved-review plan/apply/verify runner. Before review publication, the runner checks the confined local profile, kubeconfig cluster identity, Kubernetes API, ready Knative webhook endpoint, registry API, and ready MinIO endpoint/bucket Job. Shell syntax and `--help` passed. A run against the absent `ep155-local` profile refused before Kubernetes access; no healthy native fixture or application/data candidate has yet passed. M1/M2 remain open.

The first installed platform path used revision `2717b386f3529e24ad09245f9236e9f2fa972914`, isolated state at `/tmp/nagare-mp23-ep155-2717`, and the fresh `local` profile. It first exposed EP-153's existing-output review-path bug, which was fixed. The next review reached native registry creation but stopped at ambiguous operation `op-9796d85bb45a73e5d1b55082` in transaction `tx-701b4772dc756d5767fe007e33acc69c00fb75aff2be6b695dcaea39f7d1e8e2`; the review remains at `/tmp/nagare-bootstrap-review.QWERYl/review`. k3d reported the exact newly created `k3d-registry.localhost` with a `5000/tcp` port mapping, but the installed observer could not parse that shape. `inventory recover` with the saved-review decision refused `unsupported-recovery`, so this run is not accepted and its old transaction must not be blindly replayed. The source observer now reads k3d 5.9 `portMappings` while preserving the older fixture shape; `bash scripts/test-bootstrap-local-public.sh <built nagarectl>` passed. Next: use a new exact candidate and disposable target after exact cleanup of this test-only registry, then continue the platform → application/database → unchanged replay assertion. No whole milestone is complete.

The next exact installed candidate, revision `4cfb35609e8de981fa4352fcf6c05ee64c4a818b`, advanced past registry observation and created the `nagare-local` cluster from isolated state `/tmp/nagare-mp23-ep155-4cfb`. Its saved review is `/tmp/nagare-bootstrap-review.fS4Rbi/review`; transaction `tx-b54727f1405964a881c20ab5352e2dd9282f7cf0a90b793f6c43f44e4795a1f2` stopped ambiguously at cluster operation `op-66dc2a4caa9c83d224b53403`. k3d's listing reports the exact running server and 80/443 mappings but omits user runtime labels; Docker's exact server container has the reviewed `nagare.bootstrap.digest` label. The source observer now cross-checks that container identity and label. The focused public bootstrap test and both filtered native JSON predicates passed. This second run also remains unaccepted and must not be blindly replayed. Preserve both private journals; after exact disposal of only these test resources, build a new candidate and continue the same assertion. Neither attempt proves local M1.

Revision `45bbc571323b2f2a153a0dc043a6b5ff1c324a4e` then converged the disposable registry and cluster in transaction `tx-6713584ba0d117baec16c429a0dcbdc4ad023511d4b6ef1983dcfa62c949ae2f` and installed its context kubeconfig in transaction `tx-e74c133b017b6aed0b9de2dcd4c6e77b4c3e6fc76a59fbb9e853a5974c387191`. Cluster planning first required the context-owned encrypted Grafana Secret and three immutable auth image references. A disposable age identity/Secret and three previously built arm64 auth images published to the new local registry satisfied those inputs. Host-side `skopeo` then received AirTunes' 403 on port 5000 while Docker and the cluster reached the registry. The source transport now observes the exact registry manifest inside its container and accepts an operator-owned loopback forward for controller publication, checking the actual registry digest after publication. A native forwarded controller archive probe preserved its reviewed manifest; Docker load/push did not, so that route was rejected. Revision `2fa6ba87b409f0eeb53cd293740994cb94a1383d` correctly refused to plan against the already accepted earlier substrate, because the selected payload digest changed. Preserve that journal; the next installed attempt needs fresh isolated state and exact disposal of only this test's fixed-name k3d resources. No cluster review or application/data proof has passed yet.

Revision `fe048bde952aa3103776f7ebc09b50c2f3660eab` converged a fresh exact local registry, cluster, and context kubeconfig in isolated state `/tmp/nagare-mp23-ep155-03c584`. The full 209-operation cluster review at `/tmp/nagare-bootstrap-review.OqMsgS/review` reached the MinIO Deployment. Its first lost-acknowledgement stop on an already created CRD resumed from the retained journal, then transaction `tx-4597a8bfb95a025d6aa5514d9f23589df4e322f6a90c335582972e5af4476b79` stopped ambiguously at MinIO readiness operation `op-3ecd14f5ac0269e12484dd94`. The exact Deployment exists, but its pod is `ImagePullBackOff`: the pinned `quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e` returned 401. The pinned `quay.io/minio/mc` client is likewise unavailable. Mori has no registered MinIO project; upstream GitHub tags and current registries were checked before considering a new pin. Both upstream release tags exist, but Docker Hub's legacy repositories refuse access, Quay refuses the tested server/client manifests, and the legacy binary download endpoint returns 410. Do not retry or credit this ambiguous transaction until a reproducible, verified source/image route is selected. The runner now handles the context-owned Kubernetes alias `local` by matching its endpoint and CA to physical `k3d-nagare-local`; its saved target binds both identities. The generic runner's alias/refusal test passes. No EP-155 milestone is complete.


## Surprises & Discoveries


2026-09-27: The installed local bootstrap discovered a k3d registry observation mismatch: current `k3d registry list -o json` exposes `portMappings["5000/tcp"]`, not the observer's expected `expose.binding`. The operation may have succeeded while its acknowledgement was lost, so the old candidate's recovery correctly stays unresolved. This is an EP-155 native provider binding under the existing real-convergence assertion, not a new provider or feature requirement.

2026-09-27: Current k3d omits custom runtime labels from `cluster list -o json` even though the exact server container's Docker labels contain the reviewed digest. Native observation now requires both the k3d running/port identity and Docker's exact container/digest identity. This is the same local provider contract, not another release target.

2026-09-27: On this macOS host AirPlay intercepts port 5000 for host CLI traffic, although Docker's daemon and the k3d node reach the fixed local registry. A loopback SSH forward into Colima lets `skopeo` publish the exact reviewed archive without changing its manifest digest; Docker load/push rewrites that digest. The local rehearsal health probe therefore checks the registry inside its container, and the generic saved-review runner binds a separately named Kubernetes context to the exact expected cluster. These are fixture/provider bindings for the existing local acceptance assertion.

2026-09-27: The installed context kubeconfig uses `local` as both context and Kubernetes cluster alias, while k3d's physical cluster is `k3d-nagare-local`. The local runner verifies the API server and CA against k3d's kubeconfig and saves the alias separately from the physical target. The native platform path then exposed obsolete MinIO image pins. A verified new image source is required before local health can pass; no alternative provider or release gate has been added.


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

**Early fixture handoff.** Prepare the existing scenario health checks and first installed platform/application path before broad recovery implementation. Add each new feature assertion to that same scenario as its command becomes usable. Agree its run identity and evidence shape with EP-157 before collecting expensive native results. Finish transferred native bindings and the complete final-candidate scenario later; beginning fixture work does not require all feature plans to be Complete.

**Execution order within the existing milestones (2026-09-27).** Build/run the smallest production path of the already specified fixture first: accepted platform → application with database → unchanged replay with app/owner isolation. Record the exact failing assertion, then wire or fix that path before adding every scenario variant. Grow this same fixture through the remaining M1/M2 assertions; this intermediate result never closes either full milestone. Native lifecycle work transferred here is real implementation, not a short final smoke: bind one retained PostgreSQL rename to create/migrate/content verification/retire, and enumerate the existing catalogue's eligible database/broker companions, topic, schedule, and preview cleanup cases before implementing their native bindings. A missing binding maps to one of those obligations; a new provider or operation is a scope proposal. Consume EP-160/161's accepted recovery-process policies and evidence rather than inventing a second fence or pulling their unresolved protocols into this fixture.


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


Completed EP-146/147/149/151 are hard prerequisites. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) supplies bootstrap, [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md) installed candidates, and the delivered EP-148 baseline plus [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md), and [EP-161](161-provide-scoped-interactive-maintenance-with-durable-recovery.md) actual operational commands. Fixture and fault-test development starts now. Shared provider assertions require working command paths, not administrative closure of their feature plan, so feature plans can cite these results without a cycle. Accept this plan only when its full scenario and transferred native binding obligations pass. [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) reuses the fixture contract and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes the evidence. The initial 4–12-hour range is historical and does not establish an estimate for the inherited native migration/collection implementation. Re-estimate only after the first production scenario and the enumerated binding gaps are known.


## Revision Notes

2026-09-27: Apply the execution-log diagnosis to the existing outcome: drive implementation through its production command/recovery fixture, make handoffs and known ownership explicit, and prevent new requirements from entering through an open-ended audit. Existing functionality and final release acceptance remain required.
