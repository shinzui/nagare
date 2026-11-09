---
id: 254
slug: add-independent-application-worker-and-web-health-checks
title: "Add independent Application worker and web health checks"
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

# Add independent Application worker and web health checks


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. Record implementation friction through the repository's exec-plan workflow.

## Purpose / Big Picture


Applications can declare worker readiness independently of liveness, and web startup, readiness and liveness independently of each other. Deployments remain unready while initialization or a required database is unavailable, without restarting a healthy process solely because readiness fails. A worker can request a 60-second termination allowance. Web, worker and task Pods run without a Kubernetes API token unless the workload names a service account.

This plan also carries the shutdown and token policy work that was planned as [EP-255](255-declare-application-workload-shutdown-and-service-account-token-policy.md), now cancelled: both changes edit the same types, codecs, renderers and compilers, so they are made in one pass.

## Progress


- [ ] M1: Typed probes, worker shutdown duration and token policy load, validate and render; one real `Config.hs` is carried from load to native render and admitted by the local context's Knative in a server-side dry run.
- [ ] M2: The saved review carries the controls, and production-interpreter tests prove them through the existing journal and readiness observation.

## Surprises & Discoveries


None during implementation yet.

## Decision Log


- Decision: Preserve the old probe form when new controls are omitted, but refuse conflicting forms and unsupported non-default settings; silent downgrade would make readiness guarantees false. Date: 2026-11-09.
- Decision: Replace `HealthCheck` with one web probe type holding independent readiness, liveness and startup checks; no legacy form and no conflict rule. This supersedes the decision above for web probes. Rationale: the repository keeps no compatibility shims; consumers change their `Config.hs` at the release (operator, 2026-11-09). Date: 2026-11-09.
- Decision: Web, worker and task Pods are tokenless by default; API access requires naming a service account. Rationale: no workload should hold a credential it did not ask for; the cost is that every existing workload's rendered bytes change on its next deploy, visible in the saved review (operator, 2026-11-09). Date: 2026-11-09.
- Decision: Absorb EP-255 and drop this plan's own native run. Rationale: the two plans edited the same files in a forced sequence, and under ADR 25 a native run only confirms, so EP-256 M2 confirms all controls once (operator, 2026-11-09). Date: 2026-11-09.
- Decision: Add three interpreter tests, not a fault matrix. Rationale: the new fields only change desired bytes; crash points, lost responses, replaced objects and stale generations are properties of the journal, settlement and readiness code this plan does not change, covered by `InventorySettleSpec.hs`, `InventoryKubernetesReadinessSpec.hs`, `InventoryRecoveryModelSpec.hs` and `AppDeployPhaseSpec.hs`. Date: 2026-11-09.

## Outcomes & Retrospective


Implementation has not started. Before completion, retain acceptance evidence and distill durable compatibility decisions into the relevant ADR.

## Context and Orientation


Nagare configuration is a Haskell program. `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` already combines a web service, workers, databases and tasks. `Config.hs` encodes it; `Load/Application.hs` and per-workload loaders decode it. Paths below are repository-relative. `cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs` composes owned declarations, including `Service.hs`, `Worker.hs` and `Tasks.hs` in that directory. `Inventory/Adapters/KubernetesApplication.hs` composes production execution; `KubernetesReadiness.hs` evaluates current readiness. A saved review is the exact proposed change; the journal records what that change attempted and proved.

The governing decisions are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (one lifecycle owner and reviewed native effects), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) (intent before effects, proof-based recovery, effect-free verification), and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) (record provider identity at mutation and refuse replacements). [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), including its amendments, requires production-interpreter fault tests before native confirmation. A journal is durable execution evidence, not a continuous health monitor.

`Nagare.Dsl.Worker` has optional `liveness :: Maybe WorkerProbe` and no termination-grace or service-account field; `Dsl/Worker/Render.hs` emits liveness and optional startup, explicitly no readiness. `Nagare.Dsl.Types.HealthCheck` contains one path/timing set with `asLiveness`/`asStartup` flags; `Dsl/Render.hs` duplicates that one probe. `Dsl/Job/Render.hs` already emits a service account and disables token automount for one-shot Jobs; `Dsl/Task/Render.hs` sets no token policy, so an Application's pre-deploy task Pod mounts the default service-account token.

The web renderer targets Knative Serving 1.22. Its vendored schema (`cluster/bootstrap/vendor/serving-crds-v1.22.0.yaml`) admits `startupProbe`, `automountServiceAccountToken` and `serviceAccountName` without a feature gate and has no `terminationGracePeriodSeconds`; a web Pod's termination allowance comes from the revision's `timeoutSeconds`, which also bounds request duration. Knative is not in the Mori registry; read the upstream v1.22.0 tag before relying on its behavior.

The loaders read optional keys with `.:?` and ignore unknown ones, and the CLI ships the DSL and loader as one package, so there is no contract version and no older-loader case to test.

Existing tests this plan relies on rather than repeats: `InventoryKubernetesReadinessSpec.hs` (a Deployment is ready only when its rollout is complete; a Knative Service only at the observed generation), `InventorySettleSpec.hs` (lost answers, refused writes and replaced targets), `AppDeployPhaseSpec.hs` and `InventoryTransactionSpec.hs` (a failed hook aborts later phases; a hook gates its workload), and `InventoryRecoveryModelSpec.hs`.

## Plan of Work


M1 changes the types, codecs and renderers in one pass.

- Probes. Add optional readiness to `Worker` beside its existing `liveness`. Replace `Nagare.Dsl.Types.HealthCheck` with one web probe type whose readiness, liveness and startup checks each have their own path, port and timings; liveness and startup are optional. Remove `HealthCheck`, its flags and every use in fixtures and documentation; keep no legacy form. Reuse the current probe validation primitives.
- Shutdown. Add a validated optional shutdown duration to `Worker`, rendered as `terminationGracePeriodSeconds`. For web, read the Knative default revision timeout at the upstream v1.22.0 tag and document it as the termination allowance; add a typed request timeout only if that default is below 60 seconds.
- Token policy. Add an optional service-account reference to web, worker and task types. Omitted, the Pod renders `automountServiceAccountToken: false`; the only way to mount a token is to name a service account, and there is no boolean to re-enable the default account's token. Reuse the accepted service-account ownership and reference rules; no RBAC authoring is included. Leave the existing Job behavior unchanged.
- Round-trip every new field through `Config` and `Load`, including Application nesting, with missing-field defaults and malformed values tested. Do not add an untyped Pod fragment.
- Add one representative Application fixture (service, worker with a readiness marker, migration task) and carry it from `Config.hs` load to native render. Apply the rendered web Service and worker Deployment to the local context (`mode=local`) with `kubectl apply --dry-run=server`, so Knative and Kubernetes admission of the new fields is known before M2. EP-256 M2 reuses this fixture.

M2 carries the fields through the existing Application compiler into the retained native review, then adds three tests against the production kubectl interpreter and the existing fake API server:

1. Changing only a readiness path, the shutdown duration or the service account changes the reviewed desired bytes and that operation's input digest, and no other scope.
2. A Deployment write that landed while its readiness probe fails is not converged, and the transaction stays resumable.
3. After a successful migration hook and a failed readiness wait, resume does not run the hook again.

Do not change `Inventory/Journal.hs`, `Inventory/Execute/` or the Kubernetes adapters. If one of the three tests cannot pass without such a change, stop and record it in Surprises & Discoveries: that widens the plan and brings in the recovery model's deep tier. Update the worker, web and task documentation with the new types, the source changes a consumer must make, and the tokenless default.

## Concrete Steps


Run from the repository root, using the pinned development environment. The focused suites must pass before the revision-bound gate and native confirmation:

```bash
nix develop --no-write-lock-file -c bash -c 'cd cli/nagarectl && cabal test nagare-dsl-test nagarectl-test'
just gate-fast
git diff --check
```

Do not waive a failed gate. The server-side dry run uses a local context only and mutates nothing. Live Pod confirmation is EP-256 M2, not this plan.

## Validation and Acceptance


At the interpreter level, IR-42 AC-2, AC-3 and AC-4 pass when: a worker with readiness renders a `readinessProbe` distinct from its liveness probe; a web service renders three independent probes; a worker with a 60-second shutdown duration renders that grace period; web, worker and task Pods render no token automount unless a service account is named; and the three M2 tests pass. The local server-side dry run admits the rendered objects unchanged.

A worker configuration without readiness or shutdown duration renders as before apart from the token setting. A web configuration migrated to the new probe type with unchanged checks renders the same probes. Malformed controls fail before effects. Live behavior (readiness withdrawal, drain within the allowance, no credential volume in a running Pod) is confirmed once, in EP-256 M2.

## Idempotence and Recovery


All changes go through saved reviews and the existing journal. Resume a failed rollout only through the saved inventory transaction; a completed migration hook is not repeated because a worker is unready. Relaxing token policy is a new reviewed desired-state change. Never patch inventory-owned resources or controller-generated Pods by hand to get acceptance.

## Interfaces and Dependencies


No hard prerequisites. This plan owns the workload types, codecs and renderers for probes, shutdown and token policy, and the representative Application fixture. [EP-256](256-qualify-application-workload-controls-through-the-inventory-journal-and-recovery.md) M2 needs this plan Complete. No new library dependency is chosen.
