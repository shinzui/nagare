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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-30T04:43:10Z
      mode: "update"
      note: "Prioritize cloud integration and safe ongoing operation ahead of full local integration; retain final release gates"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T05:44:42Z
      mode: "implement"
      note: "Accept installed full native local platform-bootstrap candidate gate and repair stale recording-fixture membership"
---

# Prove local application and data recovery end to end

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


One reproducible disposable local run proves that the installed Nagare candidate bootstraps its components, deploys independent applications, preserves data, and recovers interrupted work using the public commands. This owns the outstanding combined native application membership proof transferred from EP-148 and consumes EP-158–160 under the revised supported contract, while cloud and final release checks remain mandatory.


## Progress

**Installed candidate platform gate (2026-09-30).** CLI `705716b7bdb74849442f1c38aa8557eee3944def` and its installed payload `nagare-0.4.0-705716b7bdb7` converge a fresh native platform in isolated Colima profile `nagare-mp23-cp3` (six CPUs, 12 GiB) and private root `/tmp/nagare-mp23-cp3.1EQ78L`. Registry/cluster and kubeconfig reviews converge, followed by the 217-operation platform review; its journal spans 496 seconds including certificate-readiness recovery through the original transaction. Autoscaler is Ready before activator. All 19 scopes converge at generation 456/sequence 447, with no transaction, claim, fence or migration, and the final marker names the installed candidate. An unchanged replan has 213 verification-only operations and zero barriers. The recording fixture now requires the eight exact backup companion members that explain its obsolete 209-operation expectation; it passes. [Retained evidence](../audits/mp23-native-bootstrap-results-2026-09-30/local-platform-candidate-705716b7.json) distinguishes native bootstrap from recording fixture proof. This satisfies the candidate's local platform-bootstrap gate, not M1/M2 or safe-use acceptance. The isolated native fixture remains retained for exact cleanup; continue the parent entrypoint's F15 cloud review before expanding the full local scenario.

**Cloud-first scheduling (operator request, 2026-09-29).** Full local integration follows EP-156 cloud convergence and recovery. Preserve the existing platform/two-application/no-op and recovery evidence. Run focused local regressions or repair a shared binding when a concrete cloud assertion needs them; do not expand the complete k3d/MinIO scenario as a prerequisite of cloud progress. EP-155 retains ownership of its local scenario, bounded PostgreSQL rename and collection obligations, and both milestones remain required before EP-157 release acceptance.

2026-09-28 scope update: no milestone is newly accepted by this edit. Use the revised MP-23 support boundary; historical findings retain their observations but do not reinstate deferred live overwrite, maintenance, or scheduled-pruning requirements.


- [ ] M1: A checked-in local fixture reaches full platform/application/data convergence with exact review/execution membership and an unchanged rerun without unintended writes.
- [ ] M2: The same fixture proves interruption/resume, adoption refusal, data-preserving migration, backup/restore, retained removal, and history restoration with reusable evidence.

Inherited baseline: InventoryIntegrationSpec covers a recording platform/two-app/cache scenario; scripts/rehearse-managed-resources.sh already has plan/apply/verify and refusal tests. EP-147 has a prior local bootstrap proof. EP-148 has worker-only and task-deletion native probes, plus recording webhook proofs. None alone proves this combined scenario.

Early fixture handoff (2026-09-27): `fixtures/inventory-release/local/health.json` and `scripts/rehearse-local-inventory-release.sh` now bind an exact local k3d target to the existing saved-review plan/apply/verify runner. Before review publication, the runner checks the confined local profile, kubeconfig cluster identity, Kubernetes API, ready Knative webhook endpoint, registry API, and ready MinIO endpoint/bucket Job. Shell syntax and `--help` passed. A run against the absent `ep155-local` profile refused before Kubernetes access; no healthy native fixture or application/data candidate has yet passed. M1/M2 remain open.

The first installed platform path used revision `2717b386f3529e24ad09245f9236e9f2fa972914`, isolated state at `/tmp/nagare-mp23-ep155-2717`, and the fresh `local` profile. It first exposed EP-153's existing-output review-path bug, which was fixed. The next review reached native registry creation but stopped at ambiguous operation `op-9796d85bb45a73e5d1b55082` in transaction `tx-701b4772dc756d5767fe007e33acc69c00fb75aff2be6b695dcaea39f7d1e8e2`; the review remains at `/tmp/nagare-bootstrap-review.QWERYl/review`. k3d reported the exact newly created `k3d-registry.localhost` with a `5000/tcp` port mapping, but the installed observer could not parse that shape. `inventory recover` with the saved-review decision refused `unsupported-recovery`, so this run is not accepted and its old transaction must not be blindly replayed. The source observer now reads k3d 5.9 `portMappings` while preserving the older fixture shape; `bash scripts/test-bootstrap-local-public.sh <built nagarectl>` passed. Next: use a new exact candidate and disposable target after exact cleanup of this test-only registry, then continue the platform → application/database → unchanged replay assertion. No whole milestone is complete.

The next exact installed candidate, revision `4cfb35609e8de981fa4352fcf6c05ee64c4a818b`, advanced past registry observation and created the `nagare-local` cluster from isolated state `/tmp/nagare-mp23-ep155-4cfb`. Its saved review is `/tmp/nagare-bootstrap-review.fS4Rbi/review`; transaction `tx-b54727f1405964a881c20ab5352e2dd9282f7cf0a90b793f6c43f44e4795a1f2` stopped ambiguously at cluster operation `op-66dc2a4caa9c83d224b53403`. k3d's listing reports the exact running server and 80/443 mappings but omits user runtime labels; Docker's exact server container has the reviewed `nagare.bootstrap.digest` label. The source observer now cross-checks that container identity and label. The focused public bootstrap test and both filtered native JSON predicates passed. This second run also remains unaccepted and must not be blindly replayed. Preserve both private journals; after exact disposal of only these test resources, build a new candidate and continue the same assertion. Neither attempt proves local M1.

Revision `45bbc571323b2f2a153a0dc043a6b5ff1c324a4e` then converged the disposable registry and cluster in transaction `tx-6713584ba0d117baec16c429a0dcbdc4ad023511d4b6ef1983dcfa62c949ae2f` and installed its context kubeconfig in transaction `tx-e74c133b017b6aed0b9de2dcd4c6e77b4c3e6fc76a59fbb9e853a5974c387191`. Cluster planning first required the context-owned encrypted Grafana Secret and three immutable auth image references. A disposable age identity/Secret and three previously built arm64 auth images published to the new local registry satisfied those inputs. Host-side `skopeo` then received AirTunes' 403 on port 5000 while Docker and the cluster reached the registry. The source transport now observes the exact registry manifest inside its container and accepts an operator-owned loopback forward for controller publication, checking the actual registry digest after publication. A native forwarded controller archive probe preserved its reviewed manifest; Docker load/push did not, so that route was rejected. Revision `2fa6ba87b409f0eeb53cd293740994cb94a1383d` correctly refused to plan against the already accepted earlier substrate, because the selected payload digest changed. Preserve that journal; the next installed attempt needs fresh isolated state and exact disposal of only this test's fixed-name k3d resources. No cluster review or application/data proof has passed yet.

Revision `fe048bde952aa3103776f7ebc09b50c2f3660eab` converged a fresh exact local registry, cluster, and context kubeconfig in isolated state `/tmp/nagare-mp23-ep155-03c584`. The full 209-operation cluster review at `/tmp/nagare-bootstrap-review.OqMsgS/review` reached the MinIO Deployment. Its first lost-acknowledgement stop on an already created CRD resumed from the retained journal, then transaction `tx-4597a8bfb95a025d6aa5514d9f23589df4e322f6a90c335582972e5af4476b79` stopped ambiguously at MinIO readiness operation `op-3ecd14f5ac0269e12484dd94`. The exact Deployment exists, but its pod is `ImagePullBackOff`: the pinned `quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e` returned 401. The pinned `quay.io/minio/mc` client is likewise unavailable. Mori has no registered MinIO project; upstream GitHub tags and current registries were checked before considering a new pin. Both upstream release tags exist, but Docker Hub's legacy repositories refuse access, Quay refuses the tested server/client manifests, and the legacy binary download endpoint returns 410. Do not retry or credit this ambiguous transaction until a reproducible, verified source/image route is selected. The runner now handles the context-owned Kubernetes alias `local` by matching its endpoint and CA to physical `k3d-nagare-local`; its saved target binds both identities. The generic runner's alias/refusal test passes. No EP-155 milestone is complete.

A local-only replacement route is now verified but has not yet run through a new installed candidate: `scripts/publish-local-minio-images.sh` downloads the September 2025 server and August 2025 client Linux binaries from the upstream GitHub releases, checks the release asset SHA-256 digests, builds arm64 or amd64 images, publishes them to the fixed k3d registry, and prints exact registry-digest inputs. A disposable Docker-network probe served `/minio/health/ready`, and the client created and listed `nagare-backups`. The local-object-store compiler accepts both images only together at exact `k3d-registry.localhost:5000/nagare-{minio,mc}@sha256:...` references and binds them into the immutable native review. A focused MinIO component test with both overrides passed. This does not settle multi-system package evidence or the old ambiguous journal; the next acceptance attempt needs a fresh candidate, isolated state, and exact disposal of only this fixture's fixed-name cluster/registry.

Installed revision `e2afeaaaaee5747f34719d2cae429839cf3d89d3` did converge that fresh local platform from isolated state `/tmp/nagare-mp23-ep155-e2afe`: registry/cluster transaction `tx-207e11d9e2401025633d6231cb7a1147e6367719242519246256172af327a3fc`, context kubeconfig transaction `tx-1a296d9b61738fe7eb383ddee5eed244b6edb483f0e74486470fb82f140f7a54`, and 209-operation cluster review `/tmp/nagare-bootstrap-review.l5T4rU/review` transaction `tx-ed1c36d788b98fa206d75fac6e8f61b5cbd153fa15844ea152b82a5960d1c5c3`. Two CRDs and one Knative certificate needed exact observed-ID/digest/ready checks before resume; the complete review then converged. The reviewed MinIO server and Knative webhook were ready, and the MinIO bucket Job succeeded with the reviewed client digest. The first application image archive review `/tmp/nagare-mp23-ep155-e2afe/app/image-review` then stopped ambiguously at artifact operation `op-7ace28c2ee9bf069056e5b15` in transaction `tx-9dc61aca62fe0eabc0a8fb95130463e235079dc4586d667b8b8058a638135352`; the exact registry tag was absent. The generic OCI transport lacked the controller publisher's loopback-forward binding, so it still reached macOS AirTunes on host port 5000. Its source now validates and uses the same local forward as a wire endpoint while observing the logical reviewed registry through the container. Preserve the old image journal; a changed installed candidate cannot reuse this accepted substrate. The next first-path attempt needs fresh isolated state. Application/database convergence and unchanged replay remain unproved, so M1/M2 stay open.

Installed revision `453eebc24a6ddfcea3df90019a4f949d888887b1` converged the fresh local platform from `/tmp/nagare-mp23-ep155-453e`, including the 209-operation review `/tmp/nagare-bootstrap-review.UwnQbf/review` (`tx-7c1fa7c8a9da910e119d8ab72161f53afec5aa056d0563de9ab480e3bb260cf2`). The CRD and Knative certificate acknowledgement pauses were resumed only after exact resource-ID, digest, and ready observations. The reviewed image archive transaction `tx-911ef539d3f7ce5e165094a73a0276bcb71e5fd314c0d25530f9af515460577e` converged, and the registry returned the exact source manifest digest `sha256:2359c0b64bc7f61bec28606de318d5b0665ffa236a9573149bef9725ecbbb82c`. The first typed application dry run exposed an accepted-foundation Namespace resolver mismatch: bootstrap addresses `personal` through `platform:cluster/cluster/cluster`, but the resolver minted the cluster in the foundation scope. The source and focused test now use the actual platform cluster identity; a new installed candidate and isolated target are needed for the app/database assertion. M1/M2 remain open.

Installed revision `23001da4` proved the corrected Namespace resolver on the real local target. The four-GiB default Colima VM could not schedule the app beside the full platform; adding a temporary k3d agent overloaded that VM, so the test-created agent was removed and its unresolved journal retained at `/tmp/nagare-mp23-ep155-23001`. A separate six-CPU, 12-GiB Colima profile left the three other default-profile k3d clusters untouched. Its first app attempt exposed that the disposable Alpine BusyBox image lacked `httpd`; that journal remains at `/tmp/nagare-mp23-ep155-23001-6cpu`. A pinned Alpine `busybox-extras` image was then run in a disposable container and returned `nagare-mp23-hello` before publication to a fresh isolated target. In `/tmp/nagare-mp23-ep155-23001-6cpu-v2`, the 209-operation platform transaction `tx-4ade533b00a6f68b9f7381bda92c23e9044d258e0e47c7b51e80f8c5940c6aa1`, corrected image publication `tx-7b3b6661a4784bbbd6cf43f1b13ad4e949695b2ff5ed6324dc7d9cba561adbc6` at registry digest `sha256:1e65fd07a210957fac0214861da60288258275fc385e7f6ed82f401a853e8930`, app A `tx-31f53facbc55567b6d9ba73b87034bb95cad8c609ed6fe1a61fdb882e5f741f6`, and app B `tx-d227e823681f7bff057b0451a5ef3d18940e085f05acf6e9f90f5fb9fa24f941` all converged. Both Knative Services were Ready at revision `00001`; both separately owned retained PostgreSQL StatefulSets had one ready replica. An unchanged app A replan then correctly produced six VerifyResource operations but incorrectly proposed an UpdateResource to its release-history ConfigMap because the planner regenerated `createdAt` for the same accepted tag. The source now reuses the accepted release record when all other metadata matches; its focused native-byte regression passes. The full checked-in M1/M2 scenario remains open.

Installed revision `e97d65e1` read-only replanned both accepted apps in the six-CPU v2 fixture. Saved reviews `/tmp/nagare-mp23-ep155-23001-6cpu-v2/app/app-a-e97-replay-review` and `/tmp/nagare-mp23-ep155-23001-6cpu-v2/app/app-b-e97-replay-review` each contained seven VerifyResource operations, zero writes, and zero barriers. Both live Knative Services kept their exact UID, generation 1, and Ready revision `00001`. This completes the bounded first production-path checkpoint from platform to two app/database owners and unchanged replay, using the same accepted fixture for read-only planning by the corrected installed binary. The checked-in full M1/M2 scenario, migration, backup/restore, and recovery assertions remain open.

## Surprises & Discoveries


2026-09-27: The installed local bootstrap discovered a k3d registry observation mismatch: current `k3d registry list -o json` exposes `portMappings["5000/tcp"]`, not the observer's expected `expose.binding`. The operation may have succeeded while its acknowledgement was lost, so the old candidate's recovery correctly stays unresolved. This is an EP-155 native provider binding under the existing real-convergence assertion, not a new provider or feature requirement.

2026-09-27: Current k3d omits custom runtime labels from `cluster list -o json` even though the exact server container's Docker labels contain the reviewed digest. Native observation now requires both the k3d running/port identity and Docker's exact container/digest identity. This is the same local provider contract, not another release target.

2026-09-27: On this macOS host AirPlay intercepts port 5000 for host CLI traffic, although Docker's daemon and the k3d node reach the fixed local registry. A loopback SSH forward into Colima lets `skopeo` publish the exact reviewed archive without changing its manifest digest; Docker load/push rewrites that digest. The local rehearsal health probe therefore checks the registry inside its container, and the generic saved-review runner binds a separately named Kubernetes context to the exact expected cluster. These are fixture/provider bindings for the existing local acceptance assertion.

2026-09-27: The installed context kubeconfig uses `local` as both context and Kubernetes cluster alias, while k3d's physical cluster is `k3d-nagare-local`. The local runner verifies the API server and CA against k3d's kubeconfig and saves the alias separately from the physical target. The native platform path then exposed obsolete MinIO image pins. A verified new image source is required before local health can pass; no alternative provider or release gate has been added.

2026-09-27: Upstream's legacy download host returns 410, but the September server release and August client release still provide Linux binaries as GitHub release assets. Their published SHA-256 digests match the downloaded arm64 binaries; both are statically linked and work together in a disposable local network probe. The source compiler now permits exact reviewed local-registry image overrides, while the checked-in Quay manifest remains digest-pinned as the legacy baseline. This is a fixture transport repair under M1, not evidence that the whole platform or application/data path converged.

2026-09-27: The first full installed platform review passed with those overrides. The next public `app image-plan` path exposed that generic OCI archive publication did not use the loopback forward already needed by the controller publisher on this macOS host. The source transport now changes only the Skopeo wire endpoint and leaves the reviewed destination and exact registry observation intact. The old image transaction remains ambiguous and is not retried with changed code.


## Decision Log

2026-09-29: Full local integration follows EP-156 cloud convergence and recovery. Preserve the existing platform/two-application/no-op and recovery evidence. Run focused local regressions or repair a shared binding when a concrete cloud assertion needs them; do not expand the complete k3d/MinIO scenario as a prerequisite of cloud progress. EP-155 retains ownership of its local scenario, bounded PostgreSQL rename and collection obligations, and both milestones remain required before EP-157 release acceptance.

2026-09-28: Align with the operator-approved MP-23 reduction and ADR 22 amendment. Keep complete evidence for supported behavior and explicit guards/recovery compatibility for deferred routes. EP-161 is Cancelled and no longer a completion dependency; earlier full-feature decomposition instructions are superseded.

2026-09-26: Redirect unfinished EP-148 dependencies to EP-158–161 and preserve this plan’s assigned integration, package, or release obligations. EP-148 is superseded history, not a pending completion gate.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.


## Outcomes & Retrospective


Remaining-work plan created; no new acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator's 2026-09-28 MP-23 decision reduces the supported feature set while retaining full validation, typed ownership, and cross-tool journal/state. General live overwrite, new custom interactive mutating maintenance, and generalized scheduled pruning are explicitly deferred. Refusal does not complete a retained feature; deferred routes need tested admission guards and recovery compatibility. Earlier no-reduction instructions are superseded.

cli/nagarectl/test/InventoryIntegrationSpec.hs currently injects loss at each operation in a synthetic multi-scope fixture. scripts/rehearse-managed-resources.sh checks explicit context/cluster and records candidate, review, final observation, and a fresh no-op review; scripts/test-rehearse-managed-resources.sh tests its protocol. scripts/test-inventory-scope-isolation.py and scripts/test-nagared-inventory-guard.py contain reusable command probes. Place the consolidated source fixture under fixtures/inventory-release/local/ and its public acceptance runner at scripts/rehearse-local-inventory-release.sh; retain the generic launcher as the authoritative phase protocol.


## Plan of Work

**Cloud-first scheduling (operator request, 2026-09-29).** Full local integration follows EP-156 cloud convergence and recovery. Preserve the existing platform/two-application/no-op and recovery evidence. Run focused local regressions or repair a shared binding when a concrete cloud assertion needs them; do not expand the complete k3d/MinIO scenario as a prerequisite of cloud progress. EP-155 retains ownership of its local scenario, bounded PostgreSQL rename and collection obligations, and both milestones remain required before EP-157 release acceptance.

**Early fixture handoff (historical preparation; cloud-first scheduling above governs).** The existing scenario health checks and first installed platform/application path remain reusable inputs to recovery implementation. Add each new feature assertion to that same scenario as its command becomes usable. Agree its run identity and evidence shape with EP-157 before collecting expensive native results. Finish transferred native bindings and the complete final-candidate scenario later; beginning fixture work does not require all feature plans to be Complete.

**Execution order within the existing milestones (2026-09-27).** Build/run the smallest production path of the already specified fixture first: accepted platform → application with database → unchanged replay with app/owner isolation. Record the exact failing assertion, then wire or fix that path before adding every scenario variant. Grow this same fixture through the remaining M1/M2 assertions; this intermediate result never closes either full milestone. Native lifecycle work transferred here is real implementation, not a short final smoke: bind one retained PostgreSQL rename to create/migrate/content verification/retire, and enumerate the existing catalogue's eligible database/broker companions, topic, schedule, and preview cleanup cases before implementing their native bindings. A missing binding maps to one of those obligations; a new provider or operation is a scope proposal. Consume EP-160's accepted recovery contracts and EP-153's deferred-admission/recovery boundary. Do not add a second fence or continue EP-161's cancelled session expansion.


M1 checks fixture health once before publishing reviews: reachable Kubernetes API, ready Knative admission, working registry/image access, and a ready object store. The earlier local cluster had a crash-looping Knative webhook and an unavailable pinned MinIO image; resolve those specific fixture failures rather than loop on failed deployment. Use Mori and upstream sources before changing any dependency/image version. Create one platform plus app A and app B, protected routing/auth, database and backup, broker topic, scheduled task and one-off/hook Job, preview, Runtime/Preview/Secret channels, and image publication. Use the existing offline Cloudflare transport proof for that provider; local recording CDN checks must never be described as live DNS proof. EP-156 supplies the live Google path. Expose public-command assertions for app-only updates, preserved other-owner revisions, environment survival, and exact native membership.

M2 extends fault injection to the actual stage roles: cloud/host stand-ins only in deterministic tests, database readiness, migration completion, cluster completion, and final marker. The native local run exercises actual local stages and proves no duplicate effects after acknowledgement loss. Put known rows/files into the fixture, take a reviewed backup, restore and compare content, reject wrong data incarnation, migrate a named durable fixture while preserving rows/signing identity, and collect only exact eligible members while retaining protected neighbors. Restore a private history export into isolated state and prove the same accepted identities. This plan owns the outstanding native migration/collection adapter bindings transferred from EP-148 under EP-149's existing lifecycle contract, including exact eligible database/broker companion, topic, schedule, and preview cleanup promised by the command coverage audit. Preserve supported topic-operation bounds and retained data; do not silently narrow them to the easiest fixture. [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) owns scheduled receipts and retention reporting, [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) isolated restore and retained fencing, and [EP-158](158-complete-reviewed-access-and-cdn-operations.md) access/CDN. EP-153 owns deferred-route guards and compatibility for already-admitted recovery. Use one retained PostgreSQL fixture with a stable logical identity and known rows for the rename, while verifying unrelated auth signing-key identity remains fixed. A missing binding is implementation work here, not permission to replace the assertion with a recording test or wait for an already-complete EP-149. Also exercise the inherited Build/Secret input and local registry publication path, Knative stop/restart and preview behavior, and the reviewed in-cluster webhook consumer delivered by EP-153. Include scheduled receipt survival, retain-by-default reporting, existing supported exact manual-prune regressions, all three isolated database restores and new-PVC recovery from EP-160, and EP-153 refusal/recovery compatibility. Use retained records to prove existing sessions, live fences, and partial prunes remain resolvable; do not add a new all-engine maintenance/live-overwrite matrix. The one retained PostgreSQL rename remains a bounded lifecycle proof under EP-149, not an obligation to build automatic backup-recovery promotion for every engine. Targeted native runs may be referenced with exact candidate/fixture identity instead of repeated; missing assertions remain open. Cleanup follows reviewed ownership and retains recovery evidence after a failed run.


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


Completed EP-146/147/149/151 are hard prerequisites. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) supplies bootstrap, [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md) installed candidates, and the delivered EP-148 baseline plus [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), and [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) actual operational commands. Fixture and fault-test development starts now. Shared provider assertions require working command paths, not administrative closure of their feature plan, so feature plans can cite these results without a cycle. Accept this plan only when its full scenario and transferred native binding obligations pass. [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) reuses the fixture contract and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes the evidence. The initial 4–12-hour range is historical and does not establish an estimate for the inherited native migration/collection implementation. Re-estimate only after the first production scenario and the enumerated binding gaps are known.


## Revision Notes

2026-09-28: Align current implementation and acceptance with the reduced MP-23 contract while preserving native evidence requirements and existing transaction recovery.

2026-09-27: Apply the execution-log diagnosis to the existing outcome: drive implementation through its production command/recovery fixture, make handoffs and known ownership explicit, and prevent new requirements from entering through an open-ended audit. Existing functionality and final release acceptance remain required.
