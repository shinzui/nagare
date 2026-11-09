---
id: 249
slug: declare-application-workload-shutdown-and-service-account-token-policy
title: "Declare Application workload shutdown and service account token policy"
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

# Declare Application workload shutdown and service account token policy


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. Record implementation friction through the repository's exec-plan workflow.

## Purpose / Big Picture


An Application's web and worker workloads can request a 60-second termination allowance and a tokenless Pod through typed, reviewed configuration. A workload needing Kubernetes API access must identify its scoped service account explicitly. Existing one-shot Job policy remains intact.

## Progress


- [ ] M1: Typed lifecycle/token controls load, validate and render with explicit compatibility behavior.
- [ ] M2: Reviewed application execution retains policy, detects drift and journals changes through existing operations.
- [ ] M3: Native Pods and shutdown behavior prove the policy survives admission and controller generation.

## Surprises & Discoveries


None during implementation yet.

## Decision Log


- Decision: Keep omission backward-compatible and make tokenless policy explicit in the new consumer configuration; service-account access must be scoped and reviewed rather than enabled by a blanket boolean. Date: 2026-11-09.

## Outcomes & Retrospective


Implementation has not started. Before completion, retain acceptance evidence and distill durable compatibility decisions into the relevant ADR.

## Context and Orientation


Nagare configuration is a Haskell program. `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` already combines a web service, workers, databases and tasks. `Config.hs` encodes it; `Load/Application.hs` and per-workload loaders decode it. Paths below are repository-relative. `cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` composes owned declarations, including `Service.hs`, `Worker.hs` and `Tasks.hs` in that directory. `Inventory/Adapters/KubernetesApplication.hs` composes production execution; `KubernetesReadiness.hs` evaluates current readiness. A saved review is the exact proposed change; the journal records what that change attempted and proved.

The governing decisions are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (one lifecycle owner and reviewed native effects), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) (intent before effects, proof-based recovery, effect-free verification), and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) (record provider identity at mutation and refuse replacements). [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), including its amendments, requires production-interpreter fault tests before native confirmation. A journal is durable execution evidence, not a continuous health monitor.

The current Worker has no termination-grace or service-account fields. `Dsl/Worker/Render.hs` builds a Pod template from containers and volumes. The web renderer targets Knative, whose admitted template support must be checked. `Dsl/Job/Render.hs` already emits a service account and disables token automount for its one-shot Jobs. Do not erase that established behavior or infer all task renderers share it.

## Plan of Work


M1 adds validated optional shutdown duration and explicit service-account/token policy to web and worker types, then Config, Load and the per-kind renderers. Reuse EP-248 M1's codec rules. Omitted fields preserve legacy behavior; the documented ordinary-application example explicitly selects tokenless mode. Represent tokenless versus named-account API access so an enabled token cannot accidentally use the default account. Reject negative/unsupported durations and contradictory token settings. Reuse accepted service-account ownership/reference rules, or add the smallest typed reference check needed; no generic RBAC authoring or delegated-deployer authority is included.

M2 carries policy into the existing application scope, native review, desired digests and execution inputs. A policy-only change must be a visible reviewed operation, with intent, returned object identity and completion proof in the existing journal. Preserve unrelated workloads and scopes. Changes to required platform admission features are a separate reviewed platform change; refuse an unsupported requested setting before applying workloads. Inspect drift against the controlled fields. Neither hidden post-deploy patches nor direct changes to controller-generated Pods are acceptable.

M3 confirms on a native cluster that web and worker Pods have the requested 60-second grace, expected service account and token automount behavior. Use a fixture that withdraws readiness on termination and records completed work before exit; prove the observed allowance is effective, including Knative behavior, rather than merely present in a desired manifest. An ordinary Pod must have no Kubernetes API credential volume. Test the explicit named-account case only with a minimal disposable permission and verify it cannot broaden ordinary workloads. Use Mori to inspect the pinned Knative implementation before selecting feature gates or annotations. Update user docs and record the supported Pod policy and compatibility boundary in ADRs.

## Concrete Steps


Run from the repository root, using the pinned development environment. The focused suites must pass before the revision-bound gate and native confirmation:

```bash
nix develop --no-write-lock-file -c bash -c 'cd cli/nagarectl && cabal test nagare-dsl-test nagarectl-test'
just gate-fast
git diff --check
```

Use the gate's current changed-path policy for recovery tests; retain required model evidence when changing adapters or recovery code. Do not waive a failed gate. Prefer a local native Apple Linux container where it can satisfy the test, using a remote builder only when unsuitable. Follow `docs/runbooks/before-a-native-run.md` for native admission. Record actual commands, revision, results and evidence locations in this plan as implementation proceeds.

## Validation and Acceptance


IR-42 AC-4 passes for supported web and worker roles when both retained native objects and controller-generated live Pods enforce the declared settings. The fixture drains within 60 seconds and no runner credential reaches an ordinary role. Old configs remain valid; malformed or unsupported policy fails before writes. Production-interpreter tests prove a changed policy updates the review, a lost response settles against the correct UID, and a retry neither loses the policy nor creates a second owner. Test refusal on foreign/replaced service accounts and preserve existing Job tokenlessness.

## Idempotence and Recovery


All updates use saved reviews and the existing journal. Retry after interruption uses recorded operation/input identity and live settlement. Relaxing token policy is a new reviewed desired-state change. A controller rewriting or rejecting a setting leaves acceptance failed; do not compensate by patching its children. Do not revoke or replace a shared service account owned elsewhere.

## Interfaces and Dependencies


Hard prerequisite: M1 of [EP-248](248-add-independent-application-worker-and-web-health-checks.md) is accepted with codecs and compatibility tests. This child owns lifecycle/account fields and any minimum reference validation; it does not redesign application composition. EP-250 M2 requires this child Complete.
