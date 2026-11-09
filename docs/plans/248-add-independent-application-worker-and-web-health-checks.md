---
id: 248
slug: add-independent-application-worker-and-web-health-checks
title: "Add independent Application worker and web health checks"
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

# Add independent Application worker and web health checks


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. Record implementation friction through the repository's exec-plan workflow.

## Purpose / Big Picture


Applications can declare worker readiness independently of liveness, and web startup, readiness and liveness independently of each other. Deployments remain unready while initialization or a required database is unavailable, without restarting a healthy process solely because readiness fails.

## Progress


- [ ] M1: Typed probe model, compatibility rules and one loaded/rendered consumer establish independent checks.
- [ ] M2: Saved reviews, current-generation observation and journaled deployment preserve the new probe semantics.
- [ ] M3: Production-interpreter tests and native workload checks prove readiness withdrawal, recovery and bounded failure.

## Surprises & Discoveries


None during implementation yet.

## Decision Log


- Decision: Preserve the old probe form when new controls are omitted, but refuse conflicting forms and unsupported non-default settings; silent downgrade would make readiness guarantees false. Date: 2026-11-09.

## Outcomes & Retrospective


Implementation has not started. Before completion, retain acceptance evidence and distill durable compatibility decisions into the relevant ADR.

## Context and Orientation


Nagare configuration is a Haskell program. `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` already combines a web service, workers, databases and tasks. `Config.hs` encodes it; `Load/Application.hs` and per-workload loaders decode it. Paths below are repository-relative. `cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` composes owned declarations, including `Service.hs`, `Worker.hs` and `Tasks.hs` in that directory. `Inventory/Adapters/KubernetesApplication.hs` composes production execution; `KubernetesReadiness.hs` evaluates current readiness. A saved review is the exact proposed change; the journal records what that change attempted and proved.

The governing decisions are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (one lifecycle owner and reviewed native effects), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) (intent before effects, proof-based recovery, effect-free verification), and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) (record provider identity at mutation and refuse replacements). [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), including its amendments, requires production-interpreter fault tests before native confirmation. A journal is durable execution evidence, not a continuous health monitor.

`Nagare.Dsl.Worker` has optional `liveness :: Maybe WorkerProbe`; its renderer emits liveness and optional startup, explicitly no readiness. `Nagare.Dsl.Types.HealthCheck` contains one path/timing set with asLiveness/asStartup flags; `Dsl/Render.hs` duplicates that one probe. Existing `InventoryKubernetesReadinessSpec.hs`, `InventoryApplicationSpec.hs` and `InventoryApplicationUpdateRecoverySpec.hs` are the relevant CLI tests.

## Plan of Work


M1 extends the existing workload types with optional independent worker readiness and an explicit web probe configuration. Reuse current probe validation primitives; do not add an untyped Pod fragment. Preserve legacy HealthCheck behavior when the new web form is absent, and reject simultaneous legacy and explicit forms with an actionable error. Absent worker readiness renders exactly as before. Round-trip all new fields through Config and Load, including Application nesting. Define and test missing-field defaults, malformed checks and older-loader refusal of new semantics. Record Haskell constructor migration requirements. Prove one real Config.hs load to native render before extending the full probe matrix. This accepted codec/compatibility contract is M1's handoff to EP-249.

M2 carries fields into the existing Application compiler and retained native review. Changing only a readiness path must change the reviewed desired bytes and appropriate operation input, without unrelated scope changes. Verify Kubernetes observation waits for the current parent generation and updated ready replicas; Knative observation must reflect the intended revision rather than stale Ready status. Bind write identity and journal evidence through existing adapters. Do not duplicate readiness completion in a second application controller. A landed Deployment write can remain not converged while the probe fails.

M3 exercises the production kubectl interpreter behind the existing fake API server, then confirms on a native disposable cluster. Test a worker whose readiness marker is absent during initialization, present while usable, and removed on dependency failure/shutdown. Web readiness depends on a database while liveness checks the process and startup bounds initialization. Confirm Knative admission and probe rewriting against the repository's pinned version using Mori source lookup; if a platform feature gate is required, declare it in the reviewed platform scope and reject unsupported contexts before application mutation. A rejected or ignored probe is not successful support. Update worker/web docs and durable probe compatibility decisions.

## Concrete Steps


Run from the repository root, using the pinned development environment. The focused suites must pass before the revision-bound gate and native confirmation:

```bash
nix develop --no-write-lock-file -c bash -c 'cd cli/nagarectl && cabal test nagare-dsl-test nagarectl-test'
just gate-fast
git diff --check
```

Use the gate's current changed-path policy for recovery tests; retain required model evidence when changing adapters or recovery code. Do not waive a failed gate. Prefer a local native Apple Linux container where it can satisfy the test, using a remote builder only when unsuitable. Follow `docs/runbooks/before-a-native-run.md` for native admission. Record actual commands, revision, results and evidence locations in this plan as implementation proceeds.

## Validation and Acceptance


IR-42 AC-2 and AC-3 pass when workers remain unready until their readiness check succeeds; readiness loss withdraws web traffic without inducing a liveness restart; startup failure and permanently unready rollouts stop by a declared timeout with a recoverable transaction ID. Retained native bytes and live generated Pods agree on the supported semantics. Fault tests cover stale generation, lost apply response, provider unavailability and replacement UID. Existing configs retain their behavior and malformed or unsupported controls fail before effects.

## Idempotence and Recovery


Resume a failed rollout only through the saved inventory transaction. A completed migration hook is not repeated because a worker is unready. After readiness recovers, current observations permit convergence without recreating the workload unnecessarily. Lost mutation responses require settlement, not blind replay. Test unchanged retries and changed probe input separately; never patch inventory-owned resources by hand to get acceptance.

## Interfaces and Dependencies


No hard prerequisites. Own the initial workload wire/compatibility contract in M1. EP-249 begins after that milestone; EP-250 M2 needs this entire child Complete. Reuse existing Application ownership and Kubernetes readiness adapters. No new library dependency is chosen.
