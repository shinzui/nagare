---
id: 256
slug: qualify-application-workload-controls-through-the-inventory-journal-and-recovery
title: "Qualify Application workload controls through the inventory journal and recovery"
kind: exec-plan
created_at: 2026-11-09T21:45:41Z
intention: "intention_01m714rsd7ecesc6rf1mczbzhx"
master_plan: "docs/masterplans/34-extend-application-workloads-with-independent-health-checks-explicit-pod-policy-and-a-native-arm64-sdk.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-09T21:45:41Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T21:52:55Z
      mode: "update"
      note: "Associate the initiative and child plans with the user-requested Mina intention."
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-09T23:20:14Z
      mode: "update"
      note: "Renumbered from EP-247-250 and aligned with the MasterPlan 34 review findings."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-10T05:51:00Z
      mode: "implement"
      note: "Recorded the M1 delivery audit; AC-5 remains open with named residuals."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-10T07:08:52Z
      mode: "implement"
      note: "Added the M2 fixture (smoke green); the live run stopped before any cluster mutation because gate verify refused the red b1fccafa record."
---

# Qualify Application workload controls through the inventory journal and recovery


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. Record implementation friction through the repository's exec-plan workflow.

## Purpose / Big Picture


Confirm once, on a live cluster and from a native ARM64 Linux consumer, that the new workload controls behave as ordinary Nagare Application declarations, and give the consumer a released version to adopt. Also state which file-delivery and retained-content needs are already supported.

## Progress


- [x] M1 (2026-11-09): The delivery audit is recorded in [IR-42](../improvement-requests/host-multi-role-applications-with-native-arm64-and-explicit-workload-contracts.md). AC-5 stays open with residuals AC5-R1 (private files), AC5-R2 (retained content) and AC5-R3 (role scoping).
- [ ] M2: One native run confirms the controls on live Pods through a saved review, apply and resume; the release is published with upgrade instructions and an IR-42 acceptance map.
  - [x] M2 live half (2026-11-10), run from the Mac with the CLI packaged from `22ab49b578a48a10c9b1de28d34f4eed2a72780b` on the disposable `transition` context; every value is observed unless marked. Checks 1, 2, 3 and 5 pass at that revision. Check 4's named-account half failed on an update there (see Surprises) and passes after the managed-field handover at `377fc06c15eaea985af546a4cc6f28c3fedb1fe9` (last sub-item).
    - Image: tags `v1`, `v2` and `sa1` at registry digest `sha256:4bf182ab62a64dd56614ff35add2819c5684289a39357a5a6a258947fcd8baf3`, published by `tx-7c44e1f0a0e43e0f9868e9a21cb95b8cdc2b4b6be4989d29431a5cd4ce30344b`, `tx-e0c43dbe21ae243f4e5b9f28c4d96686a1c6328951f7b00b51f565c89c64bd4b` and `tx-1e340a502b9a0d5c21ca6eb9eef6f0be87b3063909265c51f1b86b7f0dc69c1c`.
    - Transactions: `v1` create `tx-5edff994a94d857f1d665d9331cd5fa2e084a20d0e1a154fbcd1e1dd90153310` (10 operations); `v2` update `tx-f1ef39d46d7e661848d79bb1d067c89a1d7af7314cc01ca2efa04ef9b267999b` (interrupted and resumed); first-created named instance `tx-c247318c0851072949c65b715a53bf3aa87ba7b9e8caa750cbe24717b378ed9e`. Operations, input digests and completion digests are in the run's `operations.txt`, listed by operation ID in the report.
    - Parents: Knative Service UID `6473a06a-5fa2-4657-af51-56f6e02bacdb`, worker Deployment `61fe2f95-92ac-4f40-ac47-a00dbe89799b`, StatefulSet `a407aa84-fccc-41b7-9543-a4ba59d6adf5`, CronJob `e964b179-5139-48a6-9ebf-727aff818347`, hook Jobs `07f852e5-c3b2-4acf-8126-474eab6a4e5b` (`v1`) and `0f815671-fe56-4450-8912-e4603528c80b` (`v2`). Native stamps after `v2`: worker `f9cb4d0060a03d94109870cebf82cfc5ac7e8c5f36227104eb0748fc97d697b9`, web `3ffe7c5ce49e195e567f7fce4f08ad55c662833a17b6b229d13d1efe7f72cb7c`.
    - Check 1 pass: worker unready for 21 seconds after start, `/tmp/ready` appearing at 08:41:13.304 and Ready at 08:41:14; removal gave Ready=False after 27 seconds and it held another 20 seconds; restoring gave Ready=True after 10 seconds; restartCount 0 throughout.
    - Check 2 pass: a NetworkPolicy outage gave Pod Ready=False after 14 seconds, `/ready` 503 and `/healthz` 200 for over 45 seconds, restartCount 0 on both containers; removal gave Ready=True after 2 seconds.
    - Check 3 pass: worker `terminationGracePeriodSeconds` 60; SIGTERM 08:46:42.753 to exit 08:47:23.665, 40.9 seconds, exiting 0. Web `terminationGracePeriodSeconds` 300 with revision `timeoutSeconds` 300.
    - Check 4: tokenless pass, named account mixed. Web, worker and hook Pods at `v1`: `automountServiceAccountToken` false, no volumes, no service-account mount. First-created named instance: web, worker and hook Pods each mount `kube-api-access-*`, and web and worker tokens carry `sub=system:serviceaccount:personal:workload-controls-minimal`. Fail: web and worker updated from tokenless to named keep `automountServiceAccountToken: false` and mount no token; the `v2` hook Pod, a new object, does mount it.
    - Check 5 pass: `v2` apply SIGKILLed (exit 137) at 08:48:35 after its hook Job completed; the journal has Job create and hook operations completed before the kill and web and worker at intent. `inventory resume` converged by "adapter recovery proved completion" for web and worker and wrote no hook event. Hook Job 1 Pod, succeeded 1; `migration_runs` 2 rows, one per tag.
    - Secret absence: both database Secrets' `POSTGRES_PASSWORD` and `DATABASE_URL` values searched with zero matches in 159 saved-review public files, 44 plan, apply, resume and check transcripts, `inventory status --json`, and 76 journal events from sequence 504. Journal `detail` reads only the fixed progress strings and review digests.
    - Check 4 re-run at `377fc06c` pass. A, a new tokenless instance updated to a named account (`tx-ce4dfe272dd1e4745b68041ab7cc1dd7ea17533b3fc133af11f8ea229410af37` then `tx-b342697a6f7d32f160a4ca561e3a0beb3dc61fbdc0c98fcc25da47adca0005b3`). B, the stale `v2` objects healed at new tag `v3` (`tx-a6cd55f3b2941a680531b50b499b57d31a634272a4dce976925cee39ce69cb7b`). In both, the Knative Service, worker Deployment and CronJob no longer carry `automountServiceAccountToken`; web and worker Pods mount `kube-api-access-*` and their tokens carry `sub=system:serviceaccount:personal:workload-controls-minimal`. Nagare holds one `Apply` entry on each object and no `Update` entry; each generation moved by one (A 1 to 2, B 2 to 3); the `controller` and `k3s` entries are byte-identical before and after.

## Surprises & Discoveries


- Every `--hook-affects` hook refuses at review publication. `app deploy --hook-affects workload-controls-migrate=database:workload-controls-db --save-plan` stops with `StoreInvalidObject "reviews/ffe0ef7a…json" "observation Kubernetes envelope differs from reviewed operation"` (observed). The hook's completion operation lists the Job and the database StatefulSet (observed in `--dry-run --json`). `observationBytesFromMutation` requires `[mutationResource] == plannedResources` for `RunDeclaredOperation`, and the adapter's prepare selects only the Job from that list (inferred from `ObservationNative.hs` and `Adapters/Kubernetes.hs`). `WorkloadControlsInventorySpec.hs` proves its hook with one resource, so no test reaches this. `--hook-no-data-effects` would pass and is ruled out by this plan.
- After that fix (`42af11d3`) the same review publishes but `inventory apply` refuses before any effect: `reviewed Kubernetes operation does not name exactly one resource` (observed). `kubernetesSpecsFromReview` (`KubernetesReview.hs`, line 66) has the same single-resource assumption, and the CLI calls it before execution while the interpreter suite applies through its own adapter. A focused test calling it on a hook review with an affected resource returns exactly that `Left` (observed, not committed because it is red).
- A reviewed update cannot remove a field the first write set. The first write is `kubectl create --field-manager=nagare-inventory`, recorded as an `Update` entry; later updates are server-side `Apply`, which only drops fields its own `Apply` entry owns. Live, the `v2` update left `automountServiceAccountToken: false` under the 08:40 `Update` entry on the Deployment and the Knative Service, and the transaction converged with the reviewed `spec-digest` stamped (observed). So a tokenless workload that later names an account mounts no token, and any dropped field persists (the general case is inferred). A test through the production adapter and fake API server fails the same way (observed, not committed because it is red).
- That defect is fixed by a managed-field handover (`9a574163`, confirmed live at `377fc06c`). Re-planning the accepted `v2` tag with the same config is refused with `operation-revision-required` on the hook's completion operation (observed; cause not investigated), so healing used a new tag.
- `webWorker` defaults to `PrebuiltImage latest`, so an Application whose Service uses a Dockerfile build refuses `app deploy --tag` with "application workloads resolve to different prepublished image tags" (observed). The fixture's worker now shares the Service's build. `cluster/examples/workload-controls` and `multi-workload-app` have the same shape (inferred, not deployed).

## Decision Log


- Decision: Treat journal/recovery evidence as required acceptance and delivery claims as a bounded audit, because the user asked for native Nagare integration rather than a second deployment mechanism. Date: 2026-11-09.
- Decision: Remove the integrated fault matrix and fold native confirmation and release into one milestone. Rationale: the three interpreter tests in EP-254 M2 cover what the new fields change; the remaining cases are properties of unchanged journal and recovery code with existing suites. One native run replaces three (operator, 2026-11-09). Date: 2026-11-09.
- Decision: Deploy from the Mac rather than an ARM64 Apple container; a deviation from the plan's native ARM64 consumer. Rationale: the inventory store is a local file path on the Mac and the kubeconfig server is `0.0.0.0:59724`, so a container could reach them only through hand rewrites. EP-253 already proved ARM64 Linux `app check` and compilation. Date: 2026-11-09.
- Decision: The fixture's migration task names the database's owned Secret for `DATABASE_URL`. Rationale: an Application hook receives the app and task environment only; workload database bindings are per workload (`Compile.hs`, `Tasks.hs`). Date: 2026-11-09.
- Decision: The fixture fixes web scale at one replica and shortens readiness to a 5-second period, 3-second timeout and 3 failures. Rationale: a scaled-to-zero Pod cannot be observed, and a withdrawal must be seen within the check's window. Date: 2026-11-09.
- Decision: The fixture worker drains for 40 seconds. Rationale: longer than the Kubernetes default of 30, so a clean exit proves the 60-second allowance took effect. Date: 2026-11-09.
- Decision: The database outage is a hand-applied NetworkPolicy, outside the inventory, removed after the check. Rationale: it makes the database unreachable without patching the inventory-owned StatefulSet, which AC-6 forbids. Date: 2026-11-09.
- Decision: Interrupt the `v2` update rather than the `v1` create, and deploy a second instance (`WORKLOAD_CONTROLS_NAME`) for the first-created named account. Rationale: the `v1` watcher matched the wrong Job name and that apply converged uninterrupted; a separate first-created instance separates the account's own behavior from the update defect. Date: 2026-11-10.
- Decision: Heal the `v2` objects through a new image tag `v3`. Rationale: the same tag cannot be re-planned, and a new tag is the smallest reviewed change that forces an update; it also runs the migration hook once more. Date: 2026-11-10.

## Outcomes & Retrospective


Implementation has not started. Before completion, retain acceptance evidence and distill durable compatibility decisions into the relevant ADR.

## Context and Orientation


Nagare configuration is a Haskell program. `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` already combines a web service, workers, databases and tasks. `Config.hs` encodes it; `Load/Application.hs` and per-workload loaders decode it. Paths below are repository-relative. `cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` composes owned declarations, including `Service.hs`, `Worker.hs` and `Tasks.hs` in that directory. `Inventory/Adapters/KubernetesApplication.hs` composes production execution; `KubernetesReadiness.hs` evaluates current readiness. A saved review is the exact proposed change; the journal records what that change attempted and proved.

The governing decisions are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (one lifecycle owner and reviewed native effects), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) (intent before effects, proof-based recovery, effect-free verification), and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) (record provider identity at mutation and refuse replacements). [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), including its amendments, requires production-interpreter fault tests before native confirmation. A journal is durable execution evidence, not a continuous health monitor.

`Inventory/Journal.hs` defines digest-linked JournalEvent records with transaction, operation, state, timestamp, detail and optional physical identity. `Inventory/Execute/Journal.hs`, `Driver.hs`, `Recovery.hs`, `Settle.hs` and `Close.hs` own execution/recovery. `Inventory/Application/Tasks.hs` compiles hook dependencies and data effects. `Inventory/Application/Release.hs` compiles the release record. `docs/user/resource-inventory.md` describes saved review and status commands. `Dsl/Render.hs` currently renders secret references as environment values and names PVCs by workload plus volume; neither fact proves a general file delivery or cross-role storage API.

## Plan of Work


M1 is a reading task with no prerequisite and no code; run it in parallel with the other plans. Audit actual delivery using Application environment merging, per-workload env, build/runtime secret separation, hook bindings, volume rendering and supported external foundations. State whether an existing supported way materializes private regular files from role-scoped credentials with no credential bytes in public review or evidence, and whether a supported single-owner mechanism gives a writer and a reader identical retained bytes. Never propose duplicate PVC names or untracked patches as an ownership workaround. Write a short capability and limitation record into IR-42 with an explicit AC-5 disposition. A residual new API becomes a separate scoped request, not work in this plan.

M2 begins after [EP-254](254-add-independent-application-worker-and-web-health-checks.md) and [EP-253](253-package-a-native-arm64-linux-configuration-sdk-and-cli.md) are Complete. Complete `docs/runbooks/before-a-native-run.md` first. Using a disposable supported cluster and the native ARM64 Linux consumer (an Apple container), deploy EP-254's representative fixture with a real SQL migration through a saved review, and confirm on live Pods:

- the worker is unready until its readiness marker exists and becomes unready when it is removed, without a liveness restart;
- web readiness is withdrawn during a database outage while liveness succeeds;
- the worker drains within its 60-second allowance, and the web Pod's allowance matches the documented Knative value;
- web, worker and task Pods have no Kubernetes API credential volume, and a workload naming a minimal disposable service account mounts only that account's token;
- interrupting the apply after the migration and running `inventory resume` converges without running the migration again.

Capture source, package and image identity, transaction and operation IDs, parent UIDs and retained native digests. Before the release, confirm that no application on the intranet context reads the Kubernetes API with the default service-account token, since every workload becomes tokenless on its next deploy. Then follow the established Nagare release workflow (`just gate-release REV`, the upgrade rehearsal, the intranet context upgraded and passing deploy-and-login) and run EP-253's ARM64 Linux check on the candidate. Prefer a release that is already due over cutting one for this initiative. The intranet upgrade needs the operator's go-ahead; this plan deploys nothing else there. Update SDK and workload docs with an Application example, the consumer's source changes and support limits. Map IR-42 AC-1 through AC-7 to evidence or a named residual; the request is not complete while AC-5 or any other criterion is unmet.

## Concrete Steps


After publishing the fixture image through the existing reviewed image workflow, use a disposable context and fresh private review directory. Set CONTEXT, TAG, IMAGE_RESOURCE_ID and REVIEW to those accepted values. The fixture migration task is named migrate; set HOOK_EFFECT to its declared database/resource target as required by `docs/user/deploying-apps.md` (do not label SQL effects as no-data-effects).

```bash
nagarectl --context "$CONTEXT" app deploy -f nagare/Config.hs \
  --tag "$TAG" --image-resource "$IMAGE_RESOURCE_ID" \
  --hook-affects "migrate=$HOOK_EFFECT" --save-plan "$REVIEW"
nagarectl --context "$CONTEXT" inventory apply "$REVIEW" --yes
nagarectl --context "$CONTEXT" inventory status --json
```

For an interrupted transaction, use the ID reported by apply:

```bash
nagarectl --context "$CONTEXT" inventory resume "$TRANSACTION" --yes
```

Retain the entire saved review and supported inventory evidence. A public summary alone cannot replay private native members. Document any additional existing database/backup binding options the fixture requires before its native run.

## Validation and Acceptance


AC-6 passes when the same typed controls survive load, saved review, native render, apply, interruption, resume and live observation, with the five live checks above passing and no hand patch to an inventory-owned workload. Secret values are absent from public review and journal output. Native ARM64 SDK execution plus the live checks satisfy AC-1 through AC-4; the published release and its upgrade notes satisfy AC-7. AC-5 is either evidenced or explicitly left open with a scoped follow-up. Audit findings cannot be reclassified as implemented merely to close the plan.

## Idempotence and Recovery


Use isolated fixtures and disposable contexts. Recover through inventory resume or existing proof-based close/reviewed correction, never edit the store or delete a Job to force replay. Journal append or head-write failures must permit re-entry without losing earlier evidence. Do not assume exactly-once SQL under an ambiguous job outcome; the existing hook/data-effect contract and application migration idempotency remain authoritative. Preserve accepted ownership and retirement/retention policy during cleanup. Local compilation checks create no provider effects and need no synthetic inventory events.

## Interfaces and Dependencies


M1 has no prerequisite. M2 requires [EP-254](254-add-independent-application-worker-and-web-health-checks.md) and [EP-253](253-package-a-native-arm64-linux-configuration-sdk-and-cli.md) Complete. This plan owns the one native confirmation, the release and residual-request accounting; it adds no workload types, tests of unchanged recovery code, storage platform or journal.
