---
id: 34
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
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-09T23:20:14Z
      mode: "update"
      note: "Renumber to MasterPlan 34 and EP-253-256; apply review findings on loader compatibility, Knative shutdown, task token policy, ARM64 gate placement and release proofs."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-10T06:12:20Z
      mode: "implement"
      note: "EP-254 and EP-256 M1 complete; recorded Knative findings and audit defects."
  reviews:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-09T23:20:14Z
      verdict: "changes-requested"
      note: "Number collision with the delegated-deployer MasterPlan 33; older-loader refusal and web termination grace contradict the code and Knative 1.22; release step omitted the intranet proof."
---

# Extend Application workloads with independent health checks, explicit pod policy, and a native ARM64 SDK


## Vision & Scope


Nagare already supports multi-workload applications. Extend that existing model so an application can declare when each worker is ready, distinguish web readiness from liveness, request a 60-second shutdown allowance and explicit Kubernetes API token policy, and load its typed configuration with a released native ARM64 Linux SDK. Every deployed change must use Nagare's existing saved review, inventory ownership, operation journal and recovery path.

This is the narrowed implementation of [IR-42](../improvement-requests/host-multi-role-applications-with-native-arm64-and-explicit-workload-contracts.md), requested on 2026-11-09. The motivating consumer is mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application. The existing aggregate in `cli/nagare-dsl/src/Nagare/Dsl/Application.hs` already holds a service, workers, databases and tasks with shared identity, image and environment. [MasterPlan 14](14-multi-workload-applications-for-nagare.md) delivered that composition. The current inventory compiler already owns deployment sequencing and hooks. Neither is rebuilt here.

Scope is native SDK packaging, independent probes, explicit Pod policy, and their complete integration into existing review and execution. Role-specific file delivery and shared retained content receive a bounded compatibility audit in EP-256 M1. Existing supported mechanisms should be documented. If they cannot meet the consumer requirement, record a precise residual request; this plan does not silently authorize a shared-storage subsystem, a new secret distribution API, or arbitrary Pod overrides. IR-42 AC-5 remains open for any unmet requirement even if this narrower initiative completes.

Production ARM64 hosts, platform service images on ARM64, Kotei self-upgrade, delegated deployment authority, database privilege expansion and a new application abstraction are excluded. A native Linux SDK is a tooling support promise, not a production-host support promise.

## Decomposition Strategy


Three children: SDK packaging (EP-253), the workload controls (EP-254), and one audit-and-confirmation plan (EP-256). Probes, shutdown and token policy are one child because they edit the same types, codecs, renderers and compilers; EP-255 was cancelled into EP-254. EP-254 proves its own journaling integration with three production-interpreter tests. EP-256 then confirms everything once on a live cluster and publishes the release; it does not retest journal and recovery code the initiative leaves unchanged.

The governing decisions are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (one lifecycle owner and reviewed native effects), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) (intent before effects, proof-based recovery, effect-free verification), and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) (record provider identity at mutation and refuse replacements). [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), including its amendments, requires production-interpreter tests before native confirmation. A journal is durable execution evidence, not a continuous health monitor.

[ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) makes the installed compiler and DSL part of the CLI distribution. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) governs release provenance. These decisions are preserved. Children amend the appropriate ADR when implementation establishes new public probe, token or SDK contracts; this planning change makes no claim of implemented support.

## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| EP-253 | Native ARM64 Linux SDK and CLI | [253](../plans/253-package-a-native-arm64-linux-configuration-sdk-and-cli.md) | None | None | Complete |
| EP-254 | Workload controls: independent health checks, worker shutdown and token policy | [254](../plans/254-add-independent-application-worker-and-web-health-checks.md) | None | EP-256 M1 findings | Complete |
| EP-255 | Shutdown and service-account token policy | [255](../plans/255-declare-application-workload-shutdown-and-service-account-token-policy.md) | — | — | Cancelled: merged into EP-254 |
| EP-256 | Delivery audit, native confirmation and release | [256](../plans/256-qualify-application-workload-controls-through-the-inventory-journal-and-recovery.md) | M1: none; M2: EP-253 and EP-254 Complete | None | In Progress (M1 Complete) |

## Dependency Graph


Three things start at once and share no files: EP-253 in its own worktree session (its first ARM64 Linux build is the longest unattended wait, so start it first), EP-254, and the EP-256 M1 audit, which is a reading task. EP-256 M2 waits for EP-253 and EP-254 to be Complete, then does the single native run and the release. EP-253 completes on a tested candidate revision, not on publication, so there is no cycle.

## Integration Points


**Application and codecs.** Keep `Application` as the aggregate. EP-254 owns the workload types and codecs in `Nagare.Dsl.Types`, `Worker`, `Task`, `Config` and `Load`, and the representative Application fixture that EP-256 M2 reuses. Web probes use one type with independent readiness, liveness and startup checks that replaces `HealthCheck`; there is no second form. Web, worker and task Pods are tokenless unless the workload names a service account. A worker without readiness or a shutdown duration renders as before, apart from the token setting. The loaders in `Nagare/Dsl/Load/` read optional keys with `.:?` and ignore unknown ones, and the configuration carries no contract version, so a released loader cannot be made to refuse a new control. That case does not arise in supported use: the CLI ships the DSL and the loader as one package (ADR 3), so a configuration is always encoded and loaded by the same release. Do not add a contract version or an older-loader test. The release notes state the Haskell source changes a consumer must make and that every existing workload's rendered bytes change on its next deploy, where the saved review shows the token setting. EP-256 M2 checks before the release that no application on the intranet context reads the Kubernetes API with the default token.

**Native declarations and observation.** EP-254 carries its fields through `cli/nagarectl/src/Nagare/Inventory/Application/` into retained native bytes, desired digests and review diffs. Kubernetes controllers own generated Pods and Knative children. Nagare observes those through the reviewed parent and its physical identity, without adopting them as extra owners. EP-254 M1 checks admission of the new fields with a server-side dry run against the local context. The vendored Knative Serving 1.22 schema (`cluster/bootstrap/vendor/serving-crds-v1.22.0.yaml`) admits `automountServiceAccountToken`, `serviceAccountName` and `startupProbe` without a feature gate, and has no `terminationGracePeriodSeconds`: a web Pod's termination allowance comes from the revision's `timeoutSeconds`, which also bounds request duration. The 60-second field therefore applies to workers; for web, EP-254 M1 confirms the Knative default against the pinned source and documents it, and adds a typed request timeout only if that default is below 60 seconds. Platform feature changes need a separately reviewed platform scope before an application can depend on them.

**Journal contract.** Reuse `Nagare.Inventory.Journal`, `Inventory.Execute` and the existing Kubernetes adapters. Bind execution to context, payload, accepted base, saved native bytes, transaction, operation and input digest. Persist intent before mutation and provider-returned physical identity with completion evidence. Preserve the distinction between a landed write and a ready workload: a successful write must not falsely converge the application release. Failure or a lost response remains incomplete or ambiguous until settlement proves its result. Resume must not rerun a completed migration merely because a worker is unready. A replacement UID, stale generation, changed input or unavailable provider is never evidence of success.

Journal changes are not assumed necessary. Reuse current events and retained evidence first; add a versioned, backward-readable representation only if a test demonstrates missing proof. Preserve digest chains and conditional head writes. Verification performs no provider mutation; unchanged retries are effect-free where current evidence permits them. Keep secret values, private key files and bearer tokens out of public review and journal details. Continuous probe transitions remain live observations; do not turn the journal into health telemetry. The initiative does not change `Inventory/Journal.hs`, `Inventory/Execute/` or the Kubernetes adapters, so it adds no fault matrix over them: EP-254 M2 adds three tests (a control change alters reviewed bytes and the input digest; a landed write with a failing probe is not converged; a completed hook is not rerun on resume) and relies on `InventorySettleSpec.hs`, `InventoryKubernetesReadinessSpec.hs`, `AppDeployPhaseSpec.hs` and `InventoryRecoveryModelSpec.hs` for the rest. A needed change to that code is a scope change to record here first.

**Qualification owner.** EP-256 M2 runs EP-254's representative Application once through real loading, rendering, saved review, apply and resume on a live cluster. It preserves the existing pre-deploy hook/data-effect declarations, image ownership and successful hook proof. Its evidence names source revision, artifact identity, transaction and operation IDs, retained native digests, parent UIDs and observed readiness. Status and recovery use existing public inventory commands.

**SDK/release.** EP-253 owns package exports. `release.json` `supportedSystems` is unchanged and keeps meaning systems the platform release is gated on; ARM64 Linux tooling is listed in `flake.nix` only. EP-256 consumes its documented package attributes; it does not find a compiler by inspecting the CLI wrapper. Prefer native Apple containers for Linux qualification. The ARM64 Linux build and consumer check run per release candidate in a native Apple container; they are not part of `just gate-fast` or the per-landing full gate, whose Linux builder is x86_64. Publication uses the existing release workflow and its three proofs (green full gate, upgrade rehearsal, the intranet context upgraded and passing deploy-and-login), with explicit consumer upgrade instructions. The intranet upgrade needs the operator's go-ahead like any cloud mutation.

## Progress


EP-253 and EP-254 are Complete and EP-256 M1 is Complete, leaving IR-42 AC-5 open with named residuals. EP-255 is Cancelled. EP-256 M2's live run confirmed worker readiness, web readiness during a database outage, shutdown allowances, tokenless Pods, a first-created named account, and resume without re-running a migration. It is blocked on the defect below, and no release is claimed.

## Surprises & Discoveries


The request's broad wording obscured existing support. Worker liveness/startup already exists, but `Worker/Render.hs` deliberately emits no readiness probe. Web `HealthCheck` emits one check under multiple probe kinds. `Job/Render.hs` already disables service-account token automount for one-shot Jobs; that does not establish the web/worker policy. `release.json` currently exports x86_64-linux and aarch64-darwin. These are current-tree observations, not fresh upstream release verification.

Review on 2026-11-09 found three facts that changed the plan. The loaders ignore unknown keys, so older-loader refusal was removed (Integration Points). Knative 1.22 does not admit a Pod termination grace field, so the web half of the 60-second control was reduced to confirming the revision timeout. `Nagare/Dsl/Task/Render.hs` sets no token policy, so an Application's pre-deploy task Pod, which holds the maintenance database login, mounts the default service-account token; EP-254 covers it.

EP-254 read the Knative v1.22.0 source and changed the shape of two controls. Knative admits `automountServiceAccountToken` only when `false`, so a named account renders `serviceAccountName` alone. It also rewrites a single-container revision's probe port to the serving port without error, so the loader refuses any other port. The default revision timeout is 300 seconds, so a web Pod needs no typed request timeout. [ADR 36](../adr/0036-application-pods-hold-no-kubernetes-api-token-unless-they-name-an-account.md) records these.

The EP-256 M1 audit found no supported way to deliver private regular files or identical retained bytes to Application roles. It also found three defects outside this initiative: `appDatabaseReaders` on Application workloads are silently dropped (`Compile.hs` refuses only `appDatabases`); `docs/user/workers.md` claims `nagarectl env` and `secret` work for a worker although `resolveAppOrDie` accepts no Worker config; and no test asserts Secret absence from journal detail, which EP-256's acceptance claims. The Kotei plan's assumption that the web role selects its binary by command does not hold, because a `Deployment` has no `command` field.

EP-253 found that `nix flake check --all-systems` cannot leave out a system, and the landing gate has no ARM64 Linux builder. The tooling-system list became a relative-path flake input that the full gate overrides ([FRIC-7](../friction-log/7-nix-flake-check-all-systems-cannot-leave-out-one-system.md)). The ARM64 consumer check is not wired into the candidate flow, so EP-256 runs it by hand from EP-253's Concrete Steps.

EP-256's first live attempt found that an Application hook declared with `--hook-affects` could not publish its review: `ObservationNative.hs` required a mutation's one resource to equal the whole operation resource list, which for a hook is the Job plus the data it affects. The same defect would have stopped any such deploy. EP-254's hook test used a one-element list, so it now declares an affected resource, and the check accepts the Job the adapter selects. This is a change to review publication, outside the journal, `Inventory/Execute/` and the adapters.

EP-256 M2 found a defect in the Kubernetes adapter (evidence in EP-256 Progress): a reviewed update cannot remove a field the first write set. The first write is `kubectl create --field-manager=nagare-inventory`, recorded as an `Update` managed-fields entry, and later server-side `Apply` writes only drop fields their own `Apply` entry owns. A web or worker updated from tokenless to a named account keeps `automountServiceAccountToken: false` and mounts no token, while the transaction converges with the reviewed digest stamped. The same applies to any field a later review removes (inferred). Fixing it changes the adapters this plan held fixed, so it needs a scope decision before implementation. The failing interpreter test is the EP-256 worktree's `repro-update-retains-dropped-field.diff`.

## Decision Log


- Decision: Extend the existing Application and inventory execution contract. Rationale: the user explicitly asked that the narrowed requests fit Nagare and receive the same journaling as existing work. Date: 2026-11-09.
- Decision: Separate SDK tooling support from host support, and audit delivery rather than presume new storage and secret APIs. Rationale: keep implementation proportional to verified gaps; preserve unresolved IR-42 acceptance rather than claim it away. Date: 2026-11-09.
- Decision: Make journaling a feature-level obligation with an integrated recovery gate. Rationale: rendered YAML and healthy Pods alone do not prove reviewed, resumable deployment. Date: 2026-11-09.

- Decision: Renumber this initiative from MasterPlan 33 and EP-247–250 to MasterPlan 34 and EP-253–256. Rationale: those numbers already belonged to the delegated-deployer initiative created on 2026-11-07 and cited by ADR 35 and MasterPlan 24. Date: 2026-11-09.
- Decision: No contract version and no older-loader refusal; ARM64 Linux checks run per release candidate, not per landing. Rationale: the DSL and loader ship together, and the landing gate has no ARM64 Linux builder. Date: 2026-11-09.
- Decision: Replace `HealthCheck` with one web probe type instead of keeping two forms, and make Pods tokenless by default with a named service account required for API access. Rationale: the repository keeps no compatibility shims, and a default that mounts a credential nobody asked for is the wrong default; the cost is a consumer source change and a reviewed byte change on each workload's next deploy (operator, 2026-11-09). Date: 2026-11-09.
- Decision: Shorten the initiative: merge EP-255 into EP-254, one native run in EP-256 instead of one per child, three interpreter tests instead of an integrated fault matrix, no `release.json` change for ARM64 tooling, and the delivery audit as a parallel reading task. Rationale: the code change is a few fields carried through unchanged review and recovery machinery; the earlier decision that each feature proves its journaling integration stands, at the size the change warrants (operator, 2026-11-09). Date: 2026-11-09.
- Decision: Fix the dropped-field defect in this initiative, widening it into the Kubernetes adapter. An update first hands Nagare's own `Update` managed-fields entry to `Apply`, and the recovery model's deep tier runs before release. Rationale: a reviewed removal that silently does nothing is a false convergence on every workload, and check 4 cannot pass without it (operator, 2026-11-10). Date: 2026-11-10.

## Outcomes & Retrospective


Implementation pending. Completion requires EP-253, EP-254 and EP-256 and the published release in use on the intranet. Report any remaining IR-42 AC-5 gap separately; do not mark the whole request implemented while it remains unresolved.
