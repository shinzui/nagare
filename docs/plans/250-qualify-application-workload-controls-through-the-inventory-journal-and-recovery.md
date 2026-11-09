---
id: 250
slug: qualify-application-workload-controls-through-the-inventory-journal-and-recovery
title: "Qualify Application workload controls through the inventory journal and recovery"
kind: exec-plan
created_at: 2026-11-09T21:45:41Z
intention: "intention_01m714rsd7ecesc6rf1mczbzhx"
master_plan: "docs/masterplans/33-extend-application-workloads-with-independent-health-checks-explicit-pod-policy-and-a-native-arm64-sdk.md"
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
---

# Qualify Application workload controls through the inventory journal and recovery


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. Record implementation friction through the repository's exec-plan workflow.

## Purpose / Big Picture


Prove the narrow controls work as ordinary Nagare Application declarations with the same ownership, saved reviews, durable journal and recovery guarantees as existing features. Also clarify which file-delivery and retained-content needs are already supported, and give the consumer a tested immutable release to adopt.

## Progress


- [ ] M1: A source-backed delivery audit and representative Application fixture distinguish existing support from residual gaps.
- [ ] M2: Production execution and fault tests prove reviewed controls, migration gating, journal evidence and safe resume together.
- [ ] M3: A native ARM64 consumer and live workloads qualify an immutable release with upgrade instructions and an honest IR-42 acceptance map.

## Surprises & Discoveries


None during implementation yet.

## Decision Log


- Decision: Treat journal/recovery evidence as required acceptance and delivery claims as a bounded audit, because the user asked for native Nagare integration rather than a second deployment mechanism. Date: 2026-11-09.

## Outcomes & Retrospective


Implementation has not started. Before completion, retain acceptance evidence and distill durable compatibility decisions into the relevant ADR.

## Context and Orientation


Nagare configuration is a Haskell program. `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` already combines a web service, workers, databases and tasks. `Config.hs` encodes it; `Load/Application.hs` and per-workload loaders decode it. Paths below are repository-relative. `cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` composes owned declarations, including `Service.hs`, `Worker.hs` and `Tasks.hs` in that directory. `Inventory/Adapters/KubernetesApplication.hs` composes production execution; `KubernetesReadiness.hs` evaluates current readiness. A saved review is the exact proposed change; the journal records what that change attempted and proved.

The governing decisions are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (one lifecycle owner and reviewed native effects), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) (intent before effects, proof-based recovery, effect-free verification), and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) (record provider identity at mutation and refuse replacements). [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), including its amendments, requires production-interpreter fault tests before native confirmation. A journal is durable execution evidence, not a continuous health monitor.

`Inventory/Journal.hs` defines digest-linked JournalEvent records with transaction, operation, state, timestamp, detail and optional physical identity. `Inventory/Execute/Journal.hs`, `Driver.hs`, `Recovery.hs`, `Settle.hs` and `Close.hs` own execution/recovery. `Inventory/Application/Tasks.hs` compiles hook dependencies and data effects. `Inventory/Application/Release.hs` compiles the release record. `docs/user/resource-inventory.md` describes saved review and status commands. `Dsl/Render.hs` currently renders secret references as environment values and names PVCs by workload plus volume; neither fact proves a general file delivery or cross-role storage API.

## Plan of Work


M1 audits actual delivery using Application environment merging, per-workload env, build/runtime secret separation, hook bindings, volume rendering and supported external foundations. Add a representative fixture with service, worker and a migration/provisioning task. Keep role-private credentials on the relevant role, not shared app env. Prove an existing supported way to materialize private regular files from role-scoped credentials, if available, with no credential bytes in public review or evidence. For shared retained content, either demonstrate a supported single-owner mechanism with identical writer/reader bytes or record the exact missing contract. Never use duplicate PVC names or untracked patches as an ownership workaround. Produce a short capability/limitation record and explicit AC-5 disposition. A residual new API becomes a separate scoped request rather than automatic implementation in this child.

M2 begins after EP-248 and EP-249 are Complete. Run the representative fixture through the real loader, Application compiler, retained saved review and production execution adapter before expanding fault variants. Reuse existing hook-affects declarations and accepted image resources. Assert intent is durable before each mutation; retained bytes/input digest bind the effect; returned physical identity and proof are recorded; a write landing is distinct from readiness and application convergence. Exercise failed SQL/provisioning so service/worker promotion is blocked, and successful hooks followed by failed readiness so resume preserves completed hook proof. Distinguish an input change requiring new review from an unchanged retry.

Use the production interpreter and fake API server for crashes before intent, after intent before mutation, after mutation before response/completion persistence, and after completion before transaction-head advancement. Include conditional-store append conflicts, unavailable providers, stale generation, same-address replacement UID and terminating objects. Observe or settle ambiguous effects before replay; refuse or expose the existing reviewed recovery route when proof is unavailable. Verify effect-free verification, valid digest chains, no duplicate successful hook and no unowned resources. Reuse current event types unless a concrete failing proof test requires a versioned extension; old journals must remain readable. Do not add an application-specific ledger or report raw credentials in events.

M3 begins after M2 and EP-247 are accepted. Run native confirmation using a disposable supported cluster and native ARM64 Linux consumer, preferably Apple containers. Use a real SQL fixture, distinct web health endpoints and worker readiness marker; inspect live Pods as well as retained declarations. Capture source/package/image identity, transaction and operation IDs, parent UIDs, native digests, fault/resume results and release version. Follow the established Nagare release workflow to publish and qualify an immutable tag; this plan does not authorize an unrelated intranet deployment. Update SDK and workload docs with an existing Application example, explicit migration steps and support limits. Map IR-42 AC-1 through AC-7 to evidence or a named residual. No whole-request completion while AC-5 or any other criterion remains unmet.

## Concrete Steps


Run from the repository root, using the pinned development environment. The focused suites must pass before the revision-bound gate and native confirmation:

```bash
nix develop --no-write-lock-file -c bash -c 'cd cli/nagarectl && cabal test nagare-dsl-test nagarectl-test'
just gate-fast
git diff --check
```

Use the gate's current changed-path policy for recovery tests; retain required model evidence when changing adapters or recovery code. Do not waive a failed gate. Prefer a local native Apple Linux container where it can satisfy the test, using a remote builder only when unsuitable. Follow `docs/runbooks/before-a-native-run.md` for native admission. Record actual commands, revision, results and evidence locations in this plan as implementation proceeds.

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


AC-6 passes only when the same typed controls survive load, saved review, native render, apply, interruption, resume and observation. A malformed or stale review must refuse before effects. A failed migration must block promotion, a successful migration must not rerun on readiness retry, and unready resources must not mark the application converged. Secret values are absent from public review/journal output. Native ARM64 SDK execution plus the feature children's live checks satisfy AC-1 through AC-4; immutable release identity and migration documentation satisfy AC-7. AC-5 is either evidenced or explicitly left open with a scoped follow-up. Audit findings cannot be reclassified as implemented merely to close the plan.

## Idempotence and Recovery


Use isolated fixtures and disposable contexts. Recover through inventory resume or existing proof-based close/reviewed correction, never edit the store or delete a Job to force replay. Journal append or head-write failures must permit re-entry without losing earlier evidence. Do not assume exactly-once SQL under an ambiguous job outcome; the existing hook/data-effect contract and application migration idempotency remain authoritative. Preserve accepted ownership and retirement/retention policy during cleanup. Local compilation checks create no provider effects and need no synthetic inventory events.

## Interfaces and Dependencies


M1 has no prerequisite. M2 requires [EP-248](248-add-independent-application-worker-and-web-health-checks.md) and [EP-249](249-declare-application-workload-shutdown-and-service-account-token-policy.md) Complete. M3 requires M2 accepted and [EP-247](247-package-a-native-arm64-linux-configuration-sdk-and-cli.md) Complete. This child owns integrated qualification and residual-request accounting, not new workload types, a second scheduler, a new storage platform or a separate journal.
