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
---

# Qualify Application workload controls through the inventory journal and recovery


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. Record implementation friction through the repository's exec-plan workflow.

## Purpose / Big Picture


Confirm once, on a live cluster and from a native ARM64 Linux consumer, that the new workload controls behave as ordinary Nagare Application declarations, and give the consumer a released version to adopt. Also state which file-delivery and retained-content needs are already supported.

## Progress


- [ ] M1: A source-backed delivery audit states what existing mechanisms support and records an explicit IR-42 AC-5 disposition.
- [ ] M2: One native run confirms the controls on live Pods through a saved review, apply and resume; the release is published with upgrade instructions and an IR-42 acceptance map.

## Surprises & Discoveries


None during implementation yet.

## Decision Log


- Decision: Treat journal/recovery evidence as required acceptance and delivery claims as a bounded audit, because the user asked for native Nagare integration rather than a second deployment mechanism. Date: 2026-11-09.
- Decision: Remove the integrated fault matrix and fold native confirmation and release into one milestone. Rationale: the three interpreter tests in EP-254 M2 cover what the new fields change; the remaining cases are properties of unchanged journal and recovery code with existing suites. One native run replaces three (operator, 2026-11-09). Date: 2026-11-09.

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
