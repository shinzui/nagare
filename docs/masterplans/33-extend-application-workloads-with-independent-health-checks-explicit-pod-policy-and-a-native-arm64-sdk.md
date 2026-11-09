---
id: 33
slug: extend-application-workloads-with-independent-health-checks-explicit-pod-policy-and-a-native-arm64-sdk
title: "Extend Application workloads with independent health checks, explicit pod policy, and a native ARM64 SDK"
kind: master-plan
created_at: 2026-11-09T21:45:25Z
intention: "intention_01m714rsd7ecesc6rf1mczbzhx"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-09T21:45:25Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T21:52:55Z
      mode: "update"
      note: "Associate the initiative and child plans with the user-requested Mina intention."
---

# Extend Application workloads with independent health checks, explicit pod policy, and a native ARM64 SDK


## Vision & Scope


Nagare already supports multi-workload applications. Extend that existing model so an application can declare when each worker is ready, distinguish web readiness from liveness, request a 60-second shutdown allowance and explicit Kubernetes API token policy, and load its typed configuration with a released native ARM64 Linux SDK. Every deployed change must use Nagare's existing saved review, inventory ownership, operation journal and recovery path.

This is the narrowed implementation of [IR-42](../improvement-requests/host-multi-role-applications-with-native-arm64-and-explicit-workload-contracts.md), requested on 2026-11-09. The motivating consumer is mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application. The existing aggregate in `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` already holds a service, workers, databases and tasks with shared identity, image and environment. [MasterPlan 14](14-multi-workload-applications-for-nagare.md) delivered that composition. The current inventory compiler already owns deployment sequencing and hooks. Neither is rebuilt here.

Scope is native SDK packaging, independent probes, explicit Pod policy, and their complete integration into existing review and execution. Role-specific file delivery and shared retained content receive a bounded compatibility audit in EP-250 M1. Existing supported mechanisms should be documented and tested. If they cannot meet the consumer requirement, record a precise residual request; this plan does not silently authorize a shared-storage subsystem, a new secret distribution API, or arbitrary Pod overrides. IR-42 AC-5 remains open for any unmet requirement even if this narrower initiative completes.

Production ARM64 hosts, platform service images on ARM64, Kotei self-upgrade, delegated deployment authority, database privilege expansion and a new application abstraction are excluded. A native Linux SDK is a tooling support promise, not a production-host support promise.

## Decomposition Strategy


Four children separate packaging, probe behavior, Pod policy, and integrated evidence. EP-248 owns the health model and its wire compatibility; EP-249 extends the same workload types after that contract is settled. EP-250 first checks the actual application delivery boundary, then integrates the completed controls through production inventory execution and qualifies an immutable release. Each feature child proves its own journaling integration; EP-250 cannot be used to defer that obligation.

The governing decisions are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (one lifecycle owner and reviewed native effects), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) (intent before effects, proof-based recovery, effect-free verification), and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) (record provider identity at mutation and refuse replacements). [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), including its amendments, requires production-interpreter fault tests before native confirmation. A journal is durable execution evidence, not a continuous health monitor.

[ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) makes the installed compiler and DSL part of the CLI distribution. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) governs release provenance. These decisions are preserved. Children amend the appropriate ADR when implementation establishes new public probe, token or SDK compatibility contracts; this planning change makes no claim of implemented support.

## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| EP-247 | Native ARM64 Linux SDK and CLI | [247](../plans/247-package-a-native-arm64-linux-configuration-sdk-and-cli.md) | None | None | Not Started |
| EP-248 | Independent worker and web health checks | [248](../plans/248-add-independent-application-worker-and-web-health-checks.md) | None | EP-250 M1 findings | Not Started |
| EP-249 | Shutdown and service-account token policy | [249](../plans/249-declare-application-workload-shutdown-and-service-account-token-policy.md) | EP-248 M1: accepted workload wire/compatibility contract | EP-250 M1 findings | Not Started |
| EP-250 | Delivery audit, journal/recovery and release qualification | [250](../plans/250-qualify-application-workload-controls-through-the-inventory-journal-and-recovery.md) | M1: none; M2: EP-248 and EP-249 Complete; M3: EP-247 Complete and M2 accepted | None | Not Started |

## Dependency Graph


Start EP-250 M1 to establish the delivery baseline and EP-247 independently. Implement EP-248 M1, then complete EP-248 and EP-249 in sequence to avoid overlapping ownership of the workload encoders and renderers. EP-250 M2 consumes both complete behavior changes. Its M3 consumes M2 and EP-247's native artifact. No release qualification is required for EP-247's completion: that child proves a revision-bound candidate, and EP-250 M3 closes the immutable release gate, avoiding a cycle.

## Integration Points


**Application and codecs.** Keep `Application` as the aggregate. EP-248 owns the initial compatibility contract in `Nagare.Dsl.Types`, `Worker`, `Config` and `Load`; EP-249 extends it. Omitted new settings preserve legacy rendering. Unsupported non-default controls must be refused by an older loader, not silently dropped; explicitly test this boundary and document any required contract version change. Typed Haskell source compatibility needs a migration note even if old JSON still loads.

**Native declarations and observation.** Each feature owner carries its fields through `cli/nagarectl/src/Nagare/Inventory/Application/` into retained native bytes, desired digests and review diffs. Kubernetes controllers own generated Pods and Knative children. Nagare observes those through the reviewed parent and its physical identity, without adopting them as extra owners. EP-248 owns current-generation readiness checks; EP-249 owns admitted Pod policy fidelity, including Knative feature gates when required. Platform feature changes need a separately reviewed platform scope before an application can depend on them.

**Journal contract.** Reuse `Nagare.Inventory.Journal`, `Inventory.Execute` and the existing Kubernetes adapters. Bind execution to context, payload, accepted base, saved native bytes, transaction, operation and input digest. Persist intent before mutation and provider-returned physical identity with completion evidence. Preserve the distinction between a landed write and a ready workload: a successful write must not falsely converge the application release. Failure or a lost response remains incomplete or ambiguous until settlement proves its result. Resume must not rerun a completed migration merely because a worker is unready. A replacement UID, stale generation, changed input or unavailable provider is never evidence of success.

Journal changes are not assumed necessary. Reuse current events and retained evidence first; add a versioned, backward-readable representation only if a test demonstrates missing proof. Preserve digest chains and conditional head writes. Verification performs no provider mutation; unchanged retries are effect-free where current evidence permits them. Keep secret values, private key files and bearer tokens out of public review and journal details. Continuous probe transitions remain live observations; do not turn the journal into health telemetry.

**Qualification owner.** EP-250 runs one representative Application through real loading, rendering, saved review, apply and resume before expanding test variants. It preserves the existing pre-deploy hook/data-effect declarations, image ownership and successful hook proof. Its evidence names source revision, artifact identity, transaction and operation IDs, retained native digests, parent UIDs and observed readiness. Status and recovery use existing public inventory commands.

**SDK/release.** EP-247 owns package exports and separates tooling-system support from platform-host support. EP-250 consumes its documented package attributes; it does not find a compiler by inspecting the CLI wrapper. Prefer native Apple containers for Linux qualification. Publication uses the existing release workflow, with evidence for the released source and explicit consumer upgrade instructions.

## Progress


Planning complete; all implementation children are Not Started. No runtime feature, release or live qualification is claimed. Begin with EP-250 M1 and EP-247; there are no known prerequisite blockers.

## Surprises & Discoveries


The request's broad wording obscured existing support. Worker liveness/startup already exists, but `Worker/Render.hs` deliberately emits no readiness probe. Web `HealthCheck` emits one check under multiple probe kinds. `Job/Render.hs` already disables service-account token automount for one-shot Jobs; that does not establish the web/worker policy. `release.json` currently exports x86_64-linux and aarch64-darwin. These are current-tree observations, not fresh upstream release verification.

## Decision Log


- Decision: Extend the existing Application and inventory execution contract. Rationale: the user explicitly asked that the narrowed requests fit Nagare and receive the same journaling as existing work. Date: 2026-11-09.
- Decision: Separate SDK tooling support from host support, and audit delivery rather than presume new storage and secret APIs. Rationale: keep implementation proportional to verified gaps; preserve unresolved IR-42 acceptance rather than claim it away. Date: 2026-11-09.
- Decision: Make journaling a feature-level obligation with an integrated recovery gate. Rationale: rendered YAML and healthy Pods alone do not prove reviewed, resumable deployment. Date: 2026-11-09.

## Outcomes & Retrospective


Implementation pending. Completion requires all four children and immutable release evidence. Report any remaining IR-42 AC-5 gap separately; do not mark the whole request implemented while it remains unresolved.
