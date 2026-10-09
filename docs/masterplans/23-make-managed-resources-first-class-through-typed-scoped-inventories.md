---
id: 23
slug: make-managed-resources-first-class-through-typed-scoped-inventories
title: "Make managed resources first-class through typed scoped inventories"
kind: master-plan
created_at: 2026-09-16T17:23:44Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-16T17:23:44Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T04:04:49Z
      mode: "update"
      note: "Pre-implementation API validation: amended shared contract, recorded findings and open store question"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-22T03:21:48Z
      mode: "implement"
      note: "Implement EP-144 typed inventory foundation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-22T04:27:14Z
      mode: "implement"
      note: "Begin EP-145 reviewed plan persistence and resumable execution"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-22T13:49:36Z
      mode: "implement"
      note: "Begin EP-146 cloud host and artifact adapters"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T18:29:14Z
      mode: "implement"
      note: "Begin EP-147 cluster bootstrap inventory migration"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T20:05:31Z
      mode: "implement"
      note: "Record partial EP-147 Kubernetes List expansion"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T20:48:56Z
      mode: "implement"
      note: "Compile direct database objects into stable typed declarations"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-23T17:24:05Z
      mode: "implement"
      note: "Start lifecycle policy child after cluster ownership proofs"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T17:51:23Z
      mode: "implement"
      note: "Record current model contribution to accepted inventory status and shared store progress"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T20:05:12Z
      mode: "implement"
      note: "Advance child plans and complete EP-151"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T21:30:29Z
      mode: "implement"
      note: "Close EP147 registry status and synchronize cross-plan boundaries"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T22:07:28Z
      mode: "implement"
      note: "Track EP-149 recovery status, adoption proof, and dependency explanation"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T23:54:34Z
      mode: "implement"
      note: "Track EP-149 collection screening transport boundary"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T01:53:11Z
      mode: "implement"
      note: "Classify immutable Kubernetes Deployment selector changes"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T04:46:40Z
      mode: "implement"
      note: "Track EP-149 StatefulSet immutable classification"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T14:21:55Z
      mode: "implement"
      note: "Complete EP-149 provider-independent lifecycle and update dependent plan gates"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T15:13:26Z
      mode: "implement"
      note: "Begin EP-148 application and data scope migration"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T16:33:40Z
      mode: "implement"
      note: "Track EP-148 renderer membership guard"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T22:38:00Z
      mode: "implement"
      note: "Track accepted database native evidence required by EP-150"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:29:37Z
      mode: "implement"
      note: "Track accepted broker topic bindings and saved-plan verification"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:41:53Z
      mode: "implement"
      note: "Track reviewed access owner contributions and central routes"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:47:34Z
      mode: "implement"
      note: "Track retained access DomainMapping collection capability"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:22:40Z
      mode: "implement"
      note: "Track reviewed stateless server preview scopes"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:28:16Z
      mode: "implement"
      note: "Track server preview PVC ownership and recovery"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:34:17Z
      mode: "implement"
      note: "Track guarded delete-policy PVC collection"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:36:41Z
      mode: "implement"
      note: "Track retained site PVC direct-write guard"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:42:55Z
      mode: "implement"
      note: "Track full companion-address guards for direct data commands"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:45:56Z
      mode: "implement"
      note: "Unify direct data create address guards"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T03:02:59Z
      mode: "implement"
      note: "Track EP-148 reviewed one-off Job scope and conditional collection"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T03:21:06Z
      mode: "implement"
      note: "Track active EP-150 integration and remaining full-release dependency gates"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-26T20:36:32Z
      mode: "update"
      note: "Replace EP-150 with six bounded remaining-work plans, preserve all release gates, and expose dependencies and forecast"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T03:47:41Z
      mode: "update"
      note: "Mark EP-152 complete and retain full local and GCP acceptance gates"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T14:00:52Z
      mode: "implement"
      note: "Credit EP-160 M1 and EP-153 registration checkpoint; select EP-154 installed smoke"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T22:09:47Z
      mode: "implement"
      note: "Record first public PostgreSQL maintenance review, fenced terminal, and converged recovery fixture"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:10Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T15:26:04Z
      mode: "implement"
      note: "Track deferred-admission and coverage schema checkpoint"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T18:26:14Z
      mode: "update"
      note: "Prioritize K8up backup evaluation and assess the operator concern about Velero project direction"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-29T04:19:41Z
      mode: "update"
      note: "Prioritize replay repair and require bounded autonomous diagnosis when execution stalls"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-29T15:00:50Z
      mode: "update"
      note: "Revise command-boundary repair work from retained append, history, recovery, and public CLI experiments"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-29T20:16:53Z
      mode: "implement"
      note: "Record authentication failure repair and retained cold/warm replay checkpoint"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-09-30T01:33:03Z
      mode: "implement"
      note: "Record EP-156 cluster-plan scan repair and remaining installed acceptance boundary"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-30T04:43:09Z
      mode: "update"
      note: "Prioritize cloud integration and safe ongoing operation ahead of full local integration; retain final release gates"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-09-30T13:13:47Z
      mode: "implement"
      note: "Reconcile installed cloud prerequisites and registration proof; retain explicit login-blocked cluster apply boundary"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T02:42:30Z
      mode: "update"
      note: "Record independent review: gate table, IR-24 evidence map, EP-157 status, store module names, digest-ownership discrepancy"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T03:07:03Z
      mode: "implement"
      note: "Verify installed initial GCS foundation recovery and preserve the pre-VM checkpoint"
    - model: "gpt-5.6-terra"
      harness: "codex-cli"
      at: 2026-10-01T04:02:25Z
      mode: "implement"
      note: "Advance entrypoint after EP-153 driver-consolidation checkpoint"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T05:44:42Z
      mode: "implement"
      note: "Record installed local candidate gate and advance single entrypoint to bounded F15 cloud rehearsal"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T13:57:32Z
      mode: "implement"
      note: "Begin reviewed access scope implementation and approved fresh F15 cloud sequence"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T03:47:55Z
      mode: "implement"
      note: "Record the completed CLI responsibility refactor and source-level registration boundary checks"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-10-02T05:04:18Z
      mode: "implement"
      note: "Record accepted-workspace preflight and cleanup dependency boundary"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-02T12:44:23Z
      mode: "implement"
      note: "Resume bounded step 3 after exact frozen-candidate and retained-backup identity checks"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T14:57:48Z
      mode: "implement"
      note: "Validate Effectful restore pilot and adopt incremental interpreter-first validation"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T16:53:06Z
      mode: "implement"
      note: "Record EP-156 native metadata interpreter agreement without changing frozen cloud authority"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:36:10Z
      mode: "update"
      note: "Remove disposable prerelease transaction and candidate freezes from acceptance; continue release work through the former step-four stop"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:53:10Z
      mode: "update"
      note: "Record critical intranet upgrade readiness and backup recovery acceptance with a one-hour recovery-point objective"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:53:17Z
      mode: "implement"
      note: "Execute supported completion with independent technical runbook verification and non-publishing release acceptance"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:09Z
      mode: "update"
      note: "Consolidate into a current-state plan: ordered Phases A-D, decisions D1-D5, three gates; archive superseded audits, closed findings and plan history"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T04:05:29Z
      mode: "implement"
      note: "Phase A: style gate, F31-F33 source fixes, A5 producers; A4 blocked by new F34"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T13:56:58Z
      mode: "implement"
      note: "Record operator decisions D1-D3, D5, D6; B1 unattended freshness, signing-key escrow and configurable objective"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T16:03:44Z
      mode: "implement"
      note: "B5 checkpoint, IR-24 case 3 evidence, review-reader surprise, collection scope proposal"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T22:30:17Z
      mode: "implement"
      note: "Teardown decision: perimeter-only exact cleanup; full-context collection moves to MP-25"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-04T13:53:51Z
      mode: "update"
      note: "Finish line: canonical MP-23 completion checklist agreed with nagare-f3"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T03:50:52Z
      mode: "update"
      note: "Operator decisions on the retrospective: native work waits for EP-173 M1-M2; F51/F52 un-deferred; ADR 25 accepted"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T14:39:49Z
      mode: "implement"
      note: "Resume after session loss: finish F58 absence proofs, refresh finding register and candidate supersession"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T19:59:39Z
      mode: "update"
      note: "Independent verification: F51, F54 closed; F59 reopened Partial; F61-F63 opened"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T20:40:33Z
      mode: "update"
      note: "Exhaustive review and structural proposal; F51 reopened"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T21:55:41Z
      mode: "update"
      note: "Add EP-175/176/177 for release line (b) steps 1-4"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T00:40:39Z
      mode: "implement"
      note: "Release line (b) step 1 done (EP-175 M3)"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-06T22:02:14Z
      mode: "update"
      note: "Operator redirect: RES-4 first-principles plan; EP-180-182 added; fidelity freeze"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-07T16:45:07Z
      mode: "update"
      note: "Operator: ship v1 with the single-fault guarantee; deep tier becomes monitoring"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T19:30:00Z
      mode: "update"
      note: "Close-out: final candidate 83124396, checklist complete, v0.4.0 published; registry, IR-24, Outcomes; pre-close Progress archived"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T02:42:30Z
      verdict: "changes-requested"
      note: "Direction confirmed at cf269e72; fix red fourmolu gate, Main.hs policy accumulation, unverified findings, and IR-24 evidence map before EP-157"
---

# Make managed resources first-class through typed scoped inventories

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current, and promote durable decisions into `docs/adr/` in the same change. It was consolidated on 2026-10-02: the previous text (dated entrypoints, finish sequences, gate tables and the full decision and revision history) is preserved verbatim in [the pre-consolidation snapshot](../audits/mp23-archive/plan-history/mp23-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file.


## Vision & Scope

[IR-24](../improvement-requests/make-managed-resources-first-class.md) asks that an operator can obtain one complete, typed, revision-bound account of every Nagare-managed resource — cloud, host, Kubernetes, data, credential, artifact and release/control — and change it safely. Compilation rejects conflicting ownership before any mutation. Review shows creation, adoption, update, replacement, migration, retention and deletion. Apply runs dependency-ordered native operations with durable evidence, and resume skips work already proven complete. Status explains identity, ownership, dependencies, drift, health and retirement decisions.

Platform components and applications keep independent desired state and release cadence. Each *scope* is one owner's complete declaration with its own revision; the context inventory composes all scopes and validates their shared claims, but is not itself independently editable. Updating one scope preserves every other scope. Applications may contribute to platform-owned routing and configuration through authorized contributions, without taking over the shared object or advancing the platform release.

The same typed Haskell declarations produce the inventory, the review, the native rendering and the execution inputs; there is no handwritten resource list beside the scripts. Smart constructors and opaque validated/reviewed values enforce structure, pure functions validate the whole graph, and adapters observe and execute through the native tools (Pulumi, NixOS, Kubernetes, Helm, storage, registry), which keep their own responsibilities. Desired state, observations and execution history stay separate. Logical IDs survive renames and ownership transfers; physical identities name individual incarnations. Data is retained by default, an unknown observation never implies absence, and credentials never appear in public review or evidence.

State lives in a private, context-owned store with one writer, immutable snapshots and a durable journal: the filesystem for local contexts, or the context's GCS state bucket beside the Pulumi state for cloud contexts. The GCS store refuses a second writer from another machine through conditional writes and requires an explicit takeover; it has no lease and is not a distributed coordinator.

**Supported release contract (operator-approved reduction, 2026-09-28).** This table is the scope that must be complete and proven. Deferred items must refuse new admission at every entrypoint, while recovery of operations admitted before the reduction stays available.

| Area | Required for MP-23 | Deferred |
|---|---|---|
| Ownership and coordination | Typed composition, collision checks, reviewed native effects, resumable cross-tool journal, conditional state, independent releases | Replacing the journal/state; an always-on coordinator |
| Databases and messaging | Existing PostgreSQL, Redis, ClickHouse and Redpanda/topic operations | New engines; a provider/plugin framework |
| Backups | Native backup formats; exact verified manual and scheduled receipts; survival after Job cleanup; MinIO (local) and GCS (cloud) proof | Scheduled keep-N pruning and automatic expiry (retention is visibly unenforced) |
| Restore | Verified isolated restore for all three engines; volume restore to a new PVC; source preserved | Live database/PVC overwrite; automatic promotion/cutover |
| Maintenance | Statically declared reviewed hooks; read-only inspection; recovery of already-recorded sessions and fences | New interactive mutating maintenance (EP-161 cancelled) |
| Validation | Full coverage of the supported contract with explicit guarded exclusions, every supported native system, real local and GCP runs, immutable evidence | No reduction |

**Release boundary.** The first release claim covers fresh inventory-backed contexts only. It excludes in-place platform-version upgrade of an admitted context, automatic adoption of foreign resources, generic schema rollback, a daemon or distributed coordinator, and production rollout. Existing pre-inventory contexts are disposable. The failed development fixture `f15-preview` is retired from acceptance by [the fixture disposition](../audits/mp23-prerelease-fixture-disposition.md); its history is preserved, but it is not revived or counted as success.

**Production readiness follows the current checklist.** On 2026-10-07 the operator made safe production use MP-23's goal (Decision Log), so checklist sections 2–4 became MP-23 scope. The operator's fixed goal and accepted
upgrade/data-protection evidence are in [the production readiness checklist](../releases/production-readiness-checklist.md).
The October 8–9 drills prove reviewed self-reverting NixOS/k3s upgrades and a documented side-by-side
PostgreSQL major upgrade with reviewed switch-over and pre-write recovery. These supersede the
October 2 requirement to complete [MP-21](21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md)
before ordinary safe node/database upgrades. MP-21 now owns optional fresh-machine/cluster rehearsal
and bounded replacement cutover. The node drills do not establish arbitrary Nagare payload/context-pin
or inventory-schema transitions, and scratch backup restore does not establish complete live-service
rebuild. EP-157 reports actual supported paths and remaining limits; final production go/no-go remains
the operator's. Volumes remain outside the hourly recovery-point objective by D2.


**Standing operator constraints.** No GKE: Nagare targets local k3d/k3s and k3s on a NixOS VM in Compute Engine, and no child may create, select or depend on a GKE cluster. Local checks use only the `nagare-mp23-cp3` Colima profile and run sequentially. Cloud work uses the active context's guardrails (ADR 9) and the repository's host and cloud mutation rules in `CLAUDE.md`. External tool evaluation (K8up/restic first, CloudNativePG/Barman for PostgreSQL, Velero as a secondary comparison) lives in MP-24/[EP-163](../plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md) and does not gate MP-23.


## Decomposition Strategy

The foundation children (EP-144 typed scopes, EP-145 reviewed plans and journal, EP-146 cloud/host/artifact adapters, EP-147 cluster components, EP-149 lifecycle and drift, EP-151 GCS store, EP-152 fresh bootstrap) are complete. The remaining work is split by outcome: EP-153 command coverage and the deferred-operation boundary; EP-158 access and CDN; EP-159 scheduled backup receipts and freshness; EP-160 isolated restore; EP-154 installed packages on every supported system; EP-155 local end-to-end recovery; EP-156 GCP end-to-end recovery; and EP-157 the immutable, non-publishing release evidence gate. EP-148 and EP-150 were superseded by these children and EP-161 was cancelled by the scope reduction; their delivered code is retained and credited, and none of them is a pending dependency.

Relevant ADRs: [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) records this architecture and its durable constraints. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) (payloads vs private workspaces), [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) (version transactions), [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) (immutable release evidence), [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) (cloud guardrail), [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) (self-reverting host activation), [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) (forward-only data disk), [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) (private operator material), [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) (VM shape), [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) (Haskell style), [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) (guarded native review), [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) (cutover rollback), [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) (route/TLS ownership) and [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) (cache provider) constrain the children that touch those areas. No cross-repository ADR applies.

Rejected alternatives: isolated platform/application inventories without shared conflict checks; one global release coupling applications to platform upgrades; a handwritten resource list beside imperative scripts; replacing native reconcilers; and an always-on control plane before the operator-driven protocol is proven.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 144 | Define typed resource scopes and validate composed inventories | docs/plans/144-define-typed-resource-scopes-and-validate-composed-inventories.md | None | None | Complete |
| 145 | Persist reviewed resource plans and resumable execution receipts | docs/plans/145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md | EP-144 | None | Complete |
| 146 | Reconcile cloud host and artifact resources through inventory adapters | docs/plans/146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md | EP-144, EP-145 | EP-149 | Complete |
| 147 | Compile cluster bootstrap into owned resource components | docs/plans/147-compile-cluster-bootstrap-into-owned-resource-components.md | EP-144, EP-145 | EP-146, EP-149 | Complete |
| 148 | Application/data history — superseded by EP-153–161; delivered work retained | docs/plans/148-route-application-and-data-lifecycles-through-independent-resource-scopes.md | None | None | Cancelled |
| 149 | Explain drift and execute reviewed adoption migration and retirement | docs/plans/149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md | EP-144, EP-145 | EP-146, EP-147 | Complete |
| 150 | Integration history — superseded by EP-152–157; delivered work retained | docs/plans/150-integrate-resource-inventories-into-upgrades-and-release-verification.md | None | None | Cancelled |
| 151 | Store inventory history in the context state bucket with conditional writes | docs/plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md | EP-145 | EP-146 | Complete |
| 152 | Complete fresh platform bootstrap through reviewed components | docs/plans/152-complete-fresh-platform-bootstrap-through-reviewed-components.md | EP-146, EP-147, EP-149, EP-151 | None | Complete |
| 153 | Close managed command coverage for the inventory release | docs/plans/153-close-managed-command-coverage-for-the-inventory-release.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-158, EP-159, EP-160 | Complete |
| 154 | Validate installed inventory packages on every supported system | docs/plans/154-validate-installed-inventory-packages-on-every-supported-system.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-158, EP-159, EP-160 | Complete |
| 155 | Prove local application and data recovery end to end | docs/plans/155-prove-local-application-and-data-recovery-end-to-end.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-158, EP-159, EP-160 | Complete |
| 156 | Prove fresh GCP convergence and shared history recovery | docs/plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-155, EP-158, EP-159, EP-160 | Complete |
| 157 | Gate the inventory release on complete immutable evidence | docs/plans/157-gate-the-inventory-release-on-complete-immutable-evidence.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-155, EP-156, EP-158, EP-159, EP-160 | Complete |
| 158 | Complete reviewed access and CDN operations | docs/plans/158-complete-reviewed-access-and-cdn-operations.md | EP-146, EP-147, EP-149, EP-151 | None | Complete |
| 159 | Complete scheduled receipts and explicit retention limits | docs/plans/159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md | EP-146, EP-147, EP-149, EP-151 | None | Complete |
| 160 | Complete verified isolated database and volume restore | docs/plans/160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md | EP-146, EP-147, EP-149, EP-151 | EP-159 | Complete |
| 161 | Interactive maintenance deferred; delivered recovery history retained | docs/plans/161-provide-scoped-interactive-maintenance-with-durable-recovery.md | None | None | Cancelled |
| 175 | Close stopped inventory transactions by per-operation proof (ADR 26; line (b) steps 1 and 4) | docs/plans/175-close-stopped-inventory-transactions-by-per-operation-proof.md | None | None | Complete |
| 176 | Record physical identity at creation and read it through one checked accessor (ADR 27; step 2) | docs/plans/176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md | EP-175 M2 | None | Complete |
| 177 | Generate recovery model coverage from a resource kind table (ADR 25 amendment; step 3) | docs/plans/177-generate-recovery-model-coverage-from-a-resource-kind-table.md | EP-175, EP-176 (M2–M3 only) | None | Complete (v1; deep-tier coverage of generated scenarios is monitoring) |
| 179 | Bring the recovery model deep tier within an hour (ADR 25 amendment) | docs/plans/179-bring-the-recovery-model-deep-tier-within-an-hour.md | EP-177 M3 | None | Complete (v1; one-hour budget moved to a later MasterPlan) |
| 180 | Derive the Kubernetes adapter's proof rules from validated API semantics (RES-4 G1, G2, G4–G7, F67 stamp proof; step 3a) | docs/plans/180-derive-the-kubernetes-adapter-s-proof-rules-from-validated-api-semantics.md | EP-177 M3 | EP-182 | Complete |
| 181 | Replace a stuck StatefulSet pod through a reviewed operation (RES-4 G3; step 3b) | docs/plans/181-replace-a-stuck-statefulset-pod-through-a-reviewed-operation.md | EP-180 (settlement rules) | EP-182 | Complete |
| 182 | Derive the recovery model's Kubernetes world from validated API semantics (RES-4 G11; step 3c) | docs/plans/182-derive-the-recovery-model-s-kubernetes-world-from-validated-api-semantics.md | EP-179 | EP-180 | Complete |

Hard dependencies must be Complete before starting the dependent child; soft dependencies supply real-adapter coverage but allow fixture-backed work to proceed. EP-157's gate code is already implemented; its final assembly additionally needs every other active child's accepted outcome (see Dependency Graph). File slugs for EP-159 and EP-160 predate their current titles and are kept so existing links stay valid.


## Dependency Graph

**Complete (2026-10-09):** every child's outcome is accepted on final candidate `83124396` (Progress). The rest of this section is the order the work followed. All hard prerequisites of the eight active children are complete, so every active child can be worked now. The remaining order is set by producer/consumer flow rather than by plan number:

```text
feature + blocker work           one frozen candidate                 release
EP-153 (commands, F30–F33) ─┐
EP-158 (access, CDN)        ├─► local gate ─► EP-155 local scenario ─┐
EP-159 (receipts, RPO)      │                 EP-156 cloud scenario ─┼─► EP-157 assembly
EP-160 (restore)            ┘                 EP-154 both systems  ─┘
```

Feature children produce code and focused local proof; the native children (EP-154/155/156) then prove one frozen candidate that contains all of it; EP-157 assembles only that candidate's evidence. A native child may pull a feature fix forward when its scenario needs it, but evidence recorded against an earlier candidate counts toward final acceptance only where its recorded inputs still match the final candidate. Cloud integration (EP-156) keeps scheduling priority over the full local scenario (EP-155) because the operator needs a maintainable cloud cluster first; both remain required for release.


## Integration Points

**Typed domain contract — EP-144, consumed by every child.** `cli/nagare-dsl/src/Nagare/Resource/{Types,Reference,Policy,Inventory,Compile,Wire}.hs` and `schemas/resource-inventory-v1.json` define ContextId/ScopeId/ResourceId, provider claims, physical identity, typed exports, owner contributions and delegation, lifecycle/data/sensitivity policy, and canonical serialization. `composeInventory` is the only route to a validated inventory; there is no decoder from bytes to a validated inventory. Types with hidden constructors never derive Generic, public setters, unchecked FromJSON or coercible roles. Content digests follow composed content and never scope revisions. The canonical SHA-256 digest lives in nagare-dsl (`Nagare/Resource/Canonical.hs`, re-exported by nagarectl's `Nagare/Inventory/Digest.hs`); the operator confirmed this on 2026-10-03 (D5, ADR 22 amendment), and it remains the only inventory digest function.

**State, review and operation protocol — EP-145.** `cli/nagarectl/src/Nagare/Inventory/{Store,Plan,Journal,Execute,Adapter}.hs` own heads, scope revision vectors, incarnations, review bundles, operation identity, adapter capabilities and recovery states. The pipeline is compile → observe → plan → prepare review (adapter-native bundles) → publish by digest → verify → admit under the store lock → execute. Only admission yields executable authority. The store contract is three conditional writes (publish-if-absent, append-at-sequence, replace-head-if-generation-matches), tested against an in-memory store. Apply and resume share one serial operation driver (EP-153). Adapters never call a command that takes the context lock.

**GCS store — EP-151.** `cli/nagarectl/src/Nagare/Inventory/Store/{ObjectOps,Remote,Discovery,Gogol,GcloudAuth}.hs` and `nagarectl inventory store status|migrate` implement the EP-145 store unchanged in the context state bucket, selected by `NAGARE_INVENTORY_STORE`/`NAGARE_INVENTORY_STORE_URL`. Local contexts always use the filesystem store.

**Native execution — EP-146 (cloud/host/artifact) and EP-147 (cluster).** Pulumi saved plans, rendered Kubernetes/Helm objects and host closures are retained before mutation and must agree with validated membership; any native plan, config or output change requires a new review. Shared owners (namespace, auth, shared configuration) compose validated consumer contributions; database builders emit the whole database bundle including credentials and backup operations.

**Lifecycle and observation — EP-149.** `cli/nagarectl/src/Nagare/Inventory/{Lifecycle,Migration,Status}.hs` own drift categories, adoption/transfer proofs, retained incarnations, migration and collection decisions. Every deletion is bound to exact identity and history. An adapter may report that a change requires replacement; the planner then refuses an ordinary update.

**Command surface and coverage — EP-153.** `cli/nagarectl/app/Main.hs` is a 16-line entrypoint and the dispatcher only routes; behavior lives in named modules. `docs/architecture/managed-resource-coverage.md` lists every supported mutation family with owner, compiler, executor, evidence and legacy disposition; it is a traceability aid, not a second authority. `scripts/audit-managed-commands.py` enforces that deferred routes refuse and recovery-only routes stay available. Shared Cabal, `Spec.hs` and Nix test registrations preserve every child's modules.

**Backup, restore and tool boundary — EP-159 and EP-160.** Native engines own backup/restore semantics; Nagare owns source identity, declared membership, review and durable outcomes. EP-159's receipts (v5: signed timestamp taken before the dump) feed EP-160's restores; only accepted receipts authorize restore. Freshness is computed by `cli/nagarectl/src/Nagare/Inventory/BackupFreshness.hs` against the accepted schedule's objective (`hourly`: warning at 30 minutes, breach at one hour; `daily`: 25 and 26 hours), counting accepted receipts and verified pending uploads. `DatabaseBackupTarget` (`Nagare/Inventory/Database.hs`) carries the store backend and objective to every database compiler; the escrow format lives in `Nagare/Inventory/SigningKeyEscrow.hs`.

**Release evidence — EP-157, supplied by EP-153/154/155/156.** `scripts/assemble-release.sh`, `scripts/assemble-inventory-release-index.py`, `cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs` and `.github/workflows/release.yml` require, for one candidate: native build outputs and clone-free rehearsals for both supported systems (EP-154), `coverage.json` (EP-153), and local and cloud `fixture`, `target`, health and inventory-evidence files (EP-155, EP-156) under `docs/release-evidence/<revision>/`. Producers must emit exactly the check names the gate requires (see Surprises, 2026-10-02). Private secrets and native bundles never enter public evidence; publication itself is outside this initiative's authorization.

**Findings tracker — shared.** [`docs/audits/mp23-findings.md`](../audits/mp23-findings.md) owns finding IDs and status. Implementers record fixes there; only an independent verifier closes a finding. New evidence goes into the owning child plan and, for raw native output, the existing dated results directory — not into new standalone audit documents.


## Progress

**Release goal tracker:** [the production readiness checklist](../releases/production-readiness-checklist.md) records the operator's goal and the evidence-backed boxes that reach it. It is the reference for "how far are we".

**Status: Complete (2026-10-09).** Every box of the [production readiness checklist](../releases/production-readiness-checklist.md) is ticked with linked evidence on master `8a37a42f`, and Nagare **v0.4.0** is published from the final candidate.

### Final status (2026-10-09)

- **Final candidate `83124396`** (`831243962c6b80f91da1028cdab8238ae6acdabd`). It was cut after the defects found on earlier candidates `3ae20f8c`, `3b78d905` and `3b59bcb7` were fixed.
- **Gates on it:**

  | Gate | Result | Evidence |
  |---|---|---|
  | `just gate` and `just gate-verify` | green, 36/36 x86_64-linux and 37/37 aarch64-darwin | [gate](../audits/mp23-independent-results-2026-10-07/gate-83124396.json) |
  | `just mutation-sweep` | 149 of 149 killed | [sweep](../audits/mp23-independent-results-2026-10-07/mutation-sweep-83124396.tsv) |
  | C1 | 214 `VerifyResource`, zero provider mutations | [proof](../audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396/c1-proof.json) |
  | C2 (EP-155) | fresh local context, 16/16, assembler accepted | [C2](../audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396/) |
  | C3 (EP-156) | fresh cloud context `mp23-c3m`, 17/17, assembler accepted | [C3](../audits/mp23-independent-results-2026-10-07/c3-acceptance-83124396/) |
  | C4 (EP-154) | clone-free installed rehearsal on both systems, 11/11 checks each; `check-release.sh` consistent | [C4](../audits/mp23-independent-results-2026-10-07/c4-83124396/) |
  | C5 (EP-157) | non-publishing assembly, twice, byte-identical; IR-24 cases mapped | [C5](../audits/mp23-independent-results-2026-10-07/c5-83124396/), [release evidence](../release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/) |

- **The operator's goal sections** (checklist §2–§4, added to MP-23 on 2026-10-07):
  - **Data protection:** the destroy-and-restore drill passed ([drill](../audits/mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/)).
  - **Node upgrades on `83124396`:** NixOS with a reboot, and k3s 1.35 → 1.36.4 with a reboot, committed with the data hash unchanged. An induced failed upgrade reverted ([drills](../audits/mp23-independent-results-2026-10-07/section3-83124396/)). On `3b59bcb7`, a real failed k3s upgrade reverted with no data loss ([earlier](../audits/mp23-independent-results-2026-10-07/section3-3b59bcb7/)).
  - **PostgreSQL 17 → 18:** a side-by-side upgrade with both failure drills passed on `3b59bcb7` ([drill](../audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/)). It counts for `83124396` because the final candidate changes no Haskell ([diff stat](../audits/mp23-independent-results-2026-10-07/diffstat-3b59bcb7-83124396.txt)).
- **Independent verification** was done by session nagare-verify, which implemented none of the work ([record](../audits/mp23-independent-results-2026-10-07/README.md)). It also executed [the operations runbook](../audits/mp23-independent-results-2026-10-07/runbook-execution-3ae20f8c/) end to end.
- **Findings at close** ([tracker](../audits/mp23-findings.md)), F01–F95:
  - 84 Closed.
  - F33, F84, F85 and F88 are Verifying. Their fixes ship in 0.4.0:
    - F33's and F84's native proof needs a staged teardown;
    - F85's is C4 on x86_64-linux;
    - F88 needs a native run that coincides with its CronJob window.
  - F40 is Partial; full-context VM collection is [MasterPlan 25](25-reviewed-full-context-teardown-with-vm-workload-collection.md).
  - F48 is Open; its code fix is EP-168 in [MasterPlan 26](26-make-platform-changes-and-releases-routine-after-the-inventory-release.md).
  - Deferred to the next release: F89, F91 and F94.
  - F77 and F78 are ledgered limits with runbooks.
- **Release:** v0.4.0 has a signed annotated tag at `83124396` and a [GitHub release](https://github.com/shinzui/nagare/releases/tag/v0.4.0) with 18 attachments (2026-10-09). GitHub Actions is disabled by operator decision, so no tag workflow ran. The release was published from the C5 assembly, its checksums were verified from the download, and `nix run github:shinzui/nagare/v0.4.0#nagarectl -- version --json` reports 0.4.0 at `83124396`.
- **Unmet production targets**, as stated in [the 0.4.0 notes](../releases/v0.4.0.md):
  - D2: volumes are outside the recovery-point objective.
  - D4: no recovery-time or retention targets have been agreed.
  - D3: there are no HTTPS routes or protected browser login.
  - MP-21's replacement upgrades remain a later improvement.

### Release line (b) and the structural plan (operator decision, 2026-10-05)

The operator approved all six decisions of [the exhaustive review's proposal](../audits/mp23-exhaustive-review-2026-10-05/PROPOSAL.md) and chose **release line (b)**. It superseded the 2026-10-04 finish line (now in History below), whose gates C1–C5 still applied, on a **new** candidate.

**In the release line.** MP-23 guarantees reviewed, recoverable changes with a supported exit from every stopped state (ADR 26) and identity respect (ADR 27) for:
- Kubernetes application scopes: Knative Service, worker Deployment, scheduled tasks (CronJob), DomainMapping, release history, application databases and attached volumes;
- standalone databases (PostgreSQL, Redis) with their backups, receipts, restores and the reviewed PostgreSQL rename;
- static sites and previews;
- for each of these: create, update, verify, retire, collect, adopt and migrate, under every provider fault in the kind table (ADR 25 amendment).

**Documented limits for this release.** Each one has ADR 26's attested close-and-accept-nothing exit, and each is recorded on the deferral ledger, not in MP-23:
- the rare-fault paths of the Pulumi/foundation, host, CDN, Cloudflare, broker, Helm, cache and artifact executors, including F57's non-Kubernetes verifies and F59's broker gap;
- identity for non-Kubernetes kinds without provider identities (ADR 27 §4);
- F77: an owned PVC deleted outside review while its database pod mounts it stays Terminating (pvc-protection) and every plan refuses. The exit is the runbook in `docs/runbooks/inventory-operations.md` (set the PV to Retain, back up through the pod, release and rebind); a reviewed exit is deferred to the next MasterPlan (operator decision, 2026-10-07).
- E's U4–U7 (local cache publication, unlocked plan seeding, export/restore consistency, takeover liveness) unless they fall out of the work below.

**Work, in order.** nagare (implementer) owns steps 1–4. The final verification is by a reviewer that did not implement the work.
- [x] 1. ([EP-175](../plans/175-close-stopped-inventory-transactions-by-per-operation-proof.md)) ADR 26: `adapterSettle` for every adapter in the line; `close-transaction` replacing the stop and abandon allowlists; scope-local, re-enterable abort; F61's forward wipe exit; verify never executes. Covers F16, F35–F37, F54–F59, F61, F63–F65, and A's in-line cells and E's U1 and U3. Done through EP-175 M3 (2026-10-05): settlement, close and its aliases are in, and the allowlists and both old terminal releases are deleted. The findings' statuses await the verifier (see the tracker's exit-change note).
- [x] 2. ([EP-176](../plans/176-record-physical-identity-at-creation-and-read-it-through-one-checked-accessor.md)) ADR 27: create-identity recorded in the journal, binding from it at convergence, one checked identity accessor for every consumer in C, and a reviewed rebind. Covers F51 (reopened, N1), F52's convergence half, F60, F62 and C's N2–N13.
- [x] 3. ([EP-177](../plans/177-generate-recovery-model-coverage-from-a-resource-kind-table.md)) ADR 25 amendment: the kind table and generated product for every kind in the line, the totality test, and the harness fixes (no refusal counted as done, `LandsFailed` effective, no `ForeignObject` exemption, the corrected-review exit explored); deletion, crash-at-store and claim-loss faults. Done for v1 as redefined on 2026-10-07: the fast tier and harness self-test over every scenario on the validated world, through 3a–3d.
  - **Redirect (operator decision, 2026-10-06): first principles before the deep tier.** Step 3 is no longer closed by repeated deep-tier runs. The adapter's proof rules and the model's world are derived from Kubernetes semantics validated against a real API server ([RES-4](../research/kubernetes-api-semantics-for-inventory-proofs.md)), and the deep tier only confirms. The must-fix list is fixed at RES-4 §4's eight items:
    - [x] 3a. ([EP-180](../plans/180-derive-the-kubernetes-adapter-s-proof-rules-from-validated-api-semantics.md)) G1 Deployment readiness (rollout-status rule; F70), G2 Knative stale Ready (F69), the F67 spec-digest stamp proof (not configuration digest v4), G4 4xx refusals as no effect, G6 one conditional-write discipline for updates and retires, G5 terminating objects, G7 canonical quantities; plus F68 and F63's worker half. G1–G7 and F66–F76 landed `c3755ad7` (2026-10-07); M9 (untested recovery guards, F30 narrowing) landed through `aaa96eaf` (2026-10-07).
    - [x] 3b. ([EP-181](../plans/181-replace-a-stuck-statefulset-pod-through-a-reviewed-operation.md)) G3: a reviewed, precondition-guarded stuck-pod replacement, so a StatefulSet correction actually rolls. Closed in `341b01bc` (2026-10-07).
    - [x] 3c. ([EP-182](../plans/182-derive-the-recovery-model-s-kubernetes-world-from-validated-api-semantics.md)) G11: the world renders realistic objects classified by the production parser, from RES-4's per-kind table, with a conformance test against the recorded traces and "every scheduled fault took effect". Landed `356e7f18` (2026-10-07): the world is a fake API server behind the production kubectl interpreter, conformant with 298 recorded real-cluster steps; deep-tier acceptance is pending 3d.
    - [x] 3d. ([EP-179](../plans/179-bring-the-recovery-model-deep-tier-within-an-hour.md)) the confirming deep tier, under an hour, after 3a–3c, with no new defect class. **Redefined (operator, 2026-10-07): for v1 the deep tier is monitoring, not a gate.** Its 3d run at `341b01bc` found one product defect, F79, fixed in the 3d batch, plus harness classes B1, B2 and B6–B8, all fixed, and the ledgered F77 and F78. The fix batch landed as `8824f469` (sweep 117 of 117).
  - **Fidelity freeze after 3c.** No further world-fidelity work inside MP-23 unless it exposes a P0 for a line (b) kind, and then only with the operator's approval. RES-4's ledger items (G8, G10, G12, G13) go to the deferral ledger.
- [x] 4. (EP-175 M4) ADR 26 §5: the attested close-and-accept-nothing exit; E's U2 (CDN purge, VM power) routed to it.
- [x] 5. One final verification against this line, then a new candidate (the revision is reported by the shipped wrapper while compile-time stamping is off, [EP-178](../plans/178-make-the-flake-check-build-each-haskell-package-once.md)), with a green `just gate` record and `gate verify`, then C1–C5. Done (2026-10-09): the verification by nagare-verify, then final candidate `83124396` with every gate green (Final status above). The cloud contexts were disposed by exact-name deletes from their own stack exports, because VM collection is MasterPlan 25 and F84's fix landed after the `mp23-c3i` teardown attempt.

### History

The 2026-10-04 finish line (candidate `b74b7e49`), the dated phase checkpoints from 2026-10-02 to 2026-10-05, the Phase A–D work list and the cross-plan gates are kept verbatim in [the pre-close snapshot](../audits/mp23-archive/plan-history/mp23-progress-before-close-2026-10-09.md). The final status above supersedes them.

**IR-24 verification cases** (final, 2026-10-09). Each case is proven by named assertions in the 0.4.0 inventory evidence, which binds C2 and C3 to one source revision and payload digest ([release evidence](../release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/)).

| Case | Evidence (assertion, scenario) |
|---|---|
| 1. Collisions refused before mutation | `collision-refusal` (local, cloud) |
| 2. Foreign or absent owner reported as an adoption decision | `adoption` (local, cloud) |
| 3. Rename creates, migrates, verifies, retires with data preserved | `retained-postgresql-rename` (local) |
| 4. Interrupted multi-component operation resumes without replaying effects | `interrupted-recovery` (local, cloud); `shared-history-takeover` (cloud) |
| 5. Drift categories distinguished | `drift-classification` (local, cloud) |
| 6. Disposable context renders, applies, converges, no-ops, removes per policy | `convergence-noop-removal`, `retained-data`, `independent-scope-preservation` (local, cloud) |
| 7. Release evidence under one immutable payload identity | the 0.4.0 release manifest and both scenarios' `inventory-evidence.json`, assembled in C5 |

**Native harness.** Before any native run, read [the native verification harness runbook](../runbooks/native-verification-harness.md). It covers pinned candidate builds, isolated operator roots and wrappers, the cp3 claim protocol, the C1 gate script, object-store drills, fresh cloud context inputs and shared-tree commit hygiene.

**Working rules for remaining work.** Name the assertion, expected progress and time budget before any costly run; an unmeasured path gets a diagnostic checkpoint after 15 minutes, and a second identical failure stops dependent work until the cause is identified. Retry only after an input, implementation or observed condition changes. Never reset history or patch a provider to manufacture a result; recover already-admitted transactions through their recorded identity. Batch cloud mutations into one rehearsed, bounded sequence approved once. Record outcomes in the owning child plan and the tracker; do not create new standalone audit documents, competing entrypoint paragraphs or dated finish sequences in this file.


## Surprises & Discoveries

2026-10-09 (F95, drill C on `3b59bcb7`): A node upgrade that restarts `tailscaled` or the network kills the SSH session that started its activation. Piped through `systemd-run --pipe --wait`, the Rust `switch-to-configuration` exited 101 when its stdout went away. A client on a dead network never saw the session end, so the apply hung until the rollback timer reverted the host. In the milder case of drill B, a cut-off activation was committed. The fix is in `83124396`, and an [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) amendment records it:
- the activation runs as a detached transient unit that records its rc under `/run/nagare-switch`;
- the client polls the result over fresh logins and verifies before committing;
- `commit` refuses while the activation runs;
- every switch SSH has a keepalive.
On `mp23-c3m`, k3s 1.35 → 1.36.4 then committed in 5 minutes.

2026-10-09 (F95's VM test): The NixOS VM test caught two defects in the fix itself before any cloud run:
- A transient systemd unit's PATH has no coreutils. The first version wrote the rc with `mv`, so no activation could ever have committed. It now writes with the shell's builtin `printf`.
- `switch-to-configuration` restarts changed units but does not start a unit that is new under an already-active target, so the test's network-cutting unit never ran until it existed in every generation.

2026-10-09 (C3 on `mp23-c3m`): The tailnet's default SSH rule is `check` for `autogroup:self`. Test hosts joined with untagged auth keys, so the host transport's mandatory fresh login waited for a browser approval, and the overnight run stalled for 3 h 40 m. Test-context keys now carry `tag:nagare-test`, and the tailnet policy has an `accept` rule for it ([C3](../audits/mp23-independent-results-2026-10-07/c3-acceptance-83124396/)).

2026-10-08 (checklist §3): A k3s minor upgrade is a lock-only re-pin of nixpkgs. sops-nix must be re-pinned with it, because its pinned nixpkgs input had rotted (`buildGo125Module` was removed). The upgrade is finished only by a reboot through reviewed VM power. Each of these surfaced only when a drill reached it.

2026-10-08 (F86, F88): An in-place PostgreSQL major change was admitted, and no reviewed stuck-pod replacement could ever be applied, because the CLI review loader decoded it as a mutation. A controller's status write between plan and apply refused an in-sync reviewed update, with no reason given. Each test passed through a test registry rather than the real CLI loader.

2026-10-05 (EP-176 complete): Data operations on any store written before ADR 27 now refuse until each member is rebound through review, because such stores carry no incarnation records. This includes backups, restores, scheduled ingestion, fences and renames. The C-phase candidate starts from a fresh context, where every write records its identity, so step 5 is unaffected. Long-lived contexts such as `tan-nb-exp` need a rebind pass before their first data operation on the new release. EP-177's kind table should list each kind's identity source, which is the journalled write response for Kubernetes and an ADR 27 §4 limit elsewhere.

2026-10-05 (EP-175 complete): Close's safety rests entirely on each adapter's settlement. A scope reverts when every operation in it classes as no effect, so an adapter that settles a real effect as no-effect would drop ownership of live objects. Adapter wrappers must delegate settlement for the operations they do not own; the CDN purge and VM power wrappers did not until M4. For EP-177 this means the kind table should state and test each kind's settlement, not only its recovery. For EP-176: `RecoveryLandedUnready` and `RecoveryTargetReplaced` remain `RecoveryDecision` constructors that the Kubernetes settle maps. Fold them into `Settlement` there, when the checked identity accessor rewrites that code.

2026-10-03 (B5): Migration bundles keep the base Kubernetes adapter identity. Review readers that decode Kubernetes members therefore have to branch on `MigrateResource`. Two did not: execution's spec reconstruction refused the review before admission, and observation publication left the accepted members without evidence, so `inventory status` failed context-wide until `inventory store materialize-native` ran. Both are fixed. Any future reader of review members (EP-157 evidence projection included) must follow the same rule (ADR 22 amendment).

2026-10-03 (B5): Companion collection is bounded by the lifecycle policy already in force. A retired database's stateless companions now collect natively, in dependency order. Its PVC and Secrets, and every broker topic, are `Retain`/`Durable`. Retained topics also block their broker's StatefulSet as consumers. Releasing durable data or deleting topics would be a new operation with a typed release policy. EP-155 records this as a scope proposal for the operator. It is not implemented and not assumed to be required.

2026-10-02 (Phase A): The release gate's health records require every scenario assertion name, but both scenario runners write only infrastructure health checks at plan time. A complete local or cloud run would still be refused at assembly until EP-155 (B5/C2) and EP-156 (C3) record each assertion as it passes, bound to its evidence, in a shape agreed with EP-157. A5 deliberately does not emit those names. Resolved in source on 2026-10-03: `scripts/scenario-assertions.py` records bound assertions and finalizes health, and both gates require the bound records (EP-157 Decision Log).

2026-10-02 (Phase A): F34. On cp3, Kourier rejects every gateway snapshot (`listener_8443`/`listener_9443`: overlapping filter chains) once a second Service in `personal` terminates TLS with the namespace wildcard secret, so no new local route becomes Ready. It blocks A4 and would block C2. Diagnosis showed a product defect in collection rather than route/TLS rendering: Orphan DELETE of a preview DomainMapping strands its KIngress (Knative blocks this only for Services). Fixed in `beca6886`.

2026-10-02 (Phase A): Making the style gate pass required rebasing the architecture size ratchet (`scripts/haskell-size-allowances.json`), because its counts predated Fourmolu formatting. The `typed-config` rehearsal check had been removed, not renamed, because reviewed deploy commands need an accepted platform; `nagarectl app check` is the offline replacement.

2026-10-02 (consolidation assessment): The release path has defects that no child had recorded. The clone-free rehearsal (`scripts/rehearse-clone-free-release.sh`) emits a check named `inventory-compile`, while `scripts/assemble-inventory-release-index.py` and `Nagare/Inventory/ReleaseEvidence.hs` require `typed-config`, so every real rehearsal would be refused at assembly. No cloud fixture or cloud-health producer exists, `docs/release-evidence/` does not exist, and x86_64-linux has never been exercised. These are now A5 and C4.

2026-10-02 (consolidation assessment): The one-hour recovery-point objective is computed correctly but does not hold without an operator. Only manually accepted receipts count, nothing runs the freshness check on an operational surface, and volumes have no scheduled producer. All source-unavailable drills were manual restores with Kubernetes access denied, not public commands after a real outage, and recorded no recovery time. These feed D1, D2, D4 and B1.

2026-10-02 (consolidation assessment): Plan and audit sprawl became a delivery risk. The MasterPlan reached 760 lines with several contradictory dated entrypoints, the audit directory held 46 entries, and child plans kept stating closed findings as open and deferred features as remaining. Status claims in tables drifted from the tracker (for example, expired-credential re-pull counted as accepted while F31 is open). Consolidation moved history to `docs/audits/mp23-archive/` and the working rules now forbid new standalone audit documents.

2026-10-02: F30 was first observed on the local `cp3` cluster, so it affects EP-155 as well as EP-156; and independent evidence drawn from about ten candidates means final acceptance needs rebinding to one candidate rather than accumulation.

2026-09-30: The nagare-dsl config-as-program loader tests read the ignored `.ghc.environment.*` file and fail spuriously when another cabal build runs in the same store; run the two Haskell suites serially.

2026-09-30: Three of five P1 findings that day were Kubernetes-level defects found only after multi-hour cloud runs, yet reproducible in minutes on local k3d. This is why every candidate passes the local platform bootstrap before a cloud rehearsal.

Earlier discoveries (derived controller claims, explicit candidate changes, native preparation before review, admission under lock, recovery before obsolete preflight, exact incarnations, conditional shared history) are recorded in ADR 22 and the snapshot.


## Decision Log


Decisions still in force, condensed. Full verbatim entries are in [the snapshot](../audits/mp23-archive/plan-history/mp23-before-consolidation-2026-10-02.md).

2026-10-09 (sessions nagare-fix and nagare-verify, under the operator's delegation): **section 4 counts from the `3b59bcb7` cloud pass for `83124396`.** The final candidate changes no Haskell, only host-switch scripts, their tests and docs, and the section 4 driver runs no host activation ([diff stat](../audits/mp23-independent-results-2026-10-07/diffstat-3b59bcb7-83124396.txt)). C3 and section 3, which go through the changed code, ran in full on `83124396`.

2026-10-09 (operator): **publish v0.4.0.** GitHub Actions stays disabled (2026-10-04), so the release was published from the local C5 assembly with `gh release create`, after a signed annotated tag at `83124396`. Moving the release runbook to this local path belongs to [MasterPlan 26](26-make-platform-changes-and-releases-routine-after-the-inventory-release.md).

2026-10-09 (operator): **test contexts use `tag:nagare-test`.** The tailnet policy gives that tag a Tailscale SSH `accept` rule, and untagged devices such as nagare-01 stay on `check`.

2026-10-07 and 2026-10-08 (operator): **only critical breaks delay the release.** A finding that neither loses data nor makes the release unusable goes to the next release, and the candidate stands:
- F84 and F85 were first deferred; their fixes then landed on master the same day (`b171712a`, `1d8fd1f5`) and ship in 0.4.0. F89 and F91 were deferred.
- That night the operator let the sessions defer non-critical findings themselves and report in the morning (F94).
- Critical F95 was fixed and re-cut.
- A standing go-ahead covered every cloud mutation, drill and landing needed to finish the checklist.

2026-10-07 (operator): **MP-23's goal is safe production use, tracked in one evidence-backed checklist** ([checklist](../releases/production-readiness-checklist.md), `3671b780`). Its scope is fixed: a new finding goes to the deferral ledger unless it risks data loss. Sections 2–4 (data protection, node upgrades, database upgrades) joined MP-23 by the shortest safe route (Vision amendment).

2026-10-07 (operator, session nagare, `3eddabae`): **ship v1 with the guarantee already proved, and widen it per release.** Every deep-tier run kept widening the problem and the estimate. The operator: "i would like to use nagare during my lifetime. A good plan figures out how to do that and improve it over time safely."
- v1's guarantee (release line (b)): every in-line kind has a proved, supported exit under any single fault. That's the fast tier and harness self-test over every scenario on the validated world (EP-182). Every other stopped state has ADR 26 §5's attested close, and the documented limits F77 and F78 have runbooks.
- Release gates: a green `just gate` on the exact candidate, `just mutation-sweep` with zero survivors, and the fast tier on the validated world.
- The deep tier (fault pairs) is monitoring for v1, not a release gate. It runs per release on the builder; its classes are triaged and either fixed or ledgered, and its findings feed the next release. Step 3d is redefined accordingly. The builder resize approved earlier the same day is not needed.
- Each later MasterPlan widens the guarantee under the same gates: fault pairs within a time budget, reviewed exits for F77 and F78, and anything else on the deferral ledger.

2026-10-06 (operator, session nagare, `3eddabae`): **first principles, not brute force.** After the deep tier kept surfacing one Kubernetes-semantics defect per run (F63, F66–F69), the operator asked why there was no technical analysis with quick validation. A separate session (nagare-first-principle) validated the API semantics of every line (b) kind with 16 experiments against k3s 1.34.6 and Knative 1.22 ([RES-4](../research/kubernetes-api-semantics-for-inventory-proofs.md), evidence in `docs/audits/k8s-semantics-2026-10-06/`). The operator approved its recommendations ("yes, let's do that"):
- MP-23's must-fix list for step 3 is RES-4 §4's eight items (G1–G7, G11), as children EP-180, EP-181 and EP-182; the deep tier (EP-179) confirms only after them.
- F67 uses the spec-digest stamp proof; the configuration-digest mutation version 4 is not landed.
- A world-fidelity freeze after EP-182; RES-4's ledger items are deferred.
- Heavy runs go to the remote builder (`just test-remote`), and master moves only through `just land` with a green full-gate record (operator decisions, same day).

2026-10-05 (operator, three answers to implementer questions in Claude Code sessions):
- **F58: fix now.** Session nagare-f3 (`6f744255`), answered 13:40:21Z (asked 06:05Z). Question: "F58 (P2, not a wedge): an app whose first deploy stopped unready can't be retired … Fix now or defer?" Answer: "Fix now in MP-23 (Recommended)". Fixed in `b244b125`.
- **F59: fix now.** The continuation session (`3eddabae`), answered 16:32:54Z. Question: "a standalone database whose StatefulSet is created but never becomes Ready … no supported command ends the transaction … Fix now or defer?" Answer: "Fix now in MP-23 (Recommended)".
- **F60: keep as a documented limit.** Same session, same answer time. Question: "With one out-of-band replacement in the seconds between creating a database PVC or StatefulSet and convergence, convergence records the replacement … What should happen?" Answer: "Keep as documented limit (Recommended)".
  - It is the F49 fail-open-recording item already on the retrospective's deferral ledger.
  - The question recommended the deferral and did not show the ledger. That departs from ADR 25 §7, which says only the operator proposes a deferral, with the ledger shown. Recorded here so the operator can revisit it.

2026-10-04 (operator, on [the engineering retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md)): The operator made four decisions:
- **No native runs until the model exists.** The remaining native work waits for [EP-173](../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md) M1–M2: the Kubernetes application world and the stuck-state invariant model, extended with incarnation, store and transient faults. Until then there is no cp3 or cloud run. That covers phase 3b, the native F54 verification and any new candidate.
- **The F54 fix is verified in the model first.** It is checked at source and interpreter level and must pass the model before it goes native.
- **F51 and F52 are un-deferred.** Both are fixed in MP-23, and the release no longer ships them as known limitations.
- **ADR 25 is accepted.** [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) applies to all remaining MP-23 work: native runs only confirm, and every native finding needs a class-level interpreter regression that fails on the pre-fix source.

Gating is local; GitHub Actions is not used.

2026-10-03 (operator): Teardown acceptance is perimeter-only exact cleanup plus full-context retirement. The first native full-context teardown (C3 checkpoint `mp23-c3`) showed something by design: retained workload consumers pin the VM, and host and artifact members have no collection. So a full context cannot be collected through reviews. Implementing that collection is a new capability, so it moves to the follow-up [MasterPlan 25](25-reviewed-full-context-teardown-with-vm-workload-collection.md). C3 S9 therefore proves policy, retirement of every scope including the cloud scope, and exact collection on a perimeter-only context. A disposable full context is removed with operator-approved, bounded provider commands; the C3 checkpoint was removed that way on 2026-10-03, after its history was exported.

2026-10-03 (implementer, under the operator's instruction to decide defaults and keep going): The B5 collection scope proposal is deferred. That covers releasing durable PVCs and credential Secrets, deleting broker topics, and collecting migrated-away incarnations. None is in the supported release contract; it matches the 2026-09-28 retain-by-default reduction; and retained members stay visible in status, with renamed databases' old writers fenced. Revisit with MP-21 or a later data-lifecycle plan.

2026-10-03 (implementer): Manual cloud receipts for Redis and ClickHouse (B2) will be proven inside the bounded C3 cloud sequence rather than narrowing the contract to scheduled-only. The cost is two extra manual backup and isolated restore pairs in a run that already happens.

2026-10-03 (implementer): F35's repair is the reviewed `abandon-refused-operation` decision. The optional admission-time absence check was not added: the decision covers every refusal point, including objects appearing after admission, while an admission check covers only the window before admission.

2026-10-03 (operator): Orphaned scheduled uploads (an archive without a receipt, a receipt without an archive, an unrecognized key) stay permanently unresolved and documented. Nagare never ingests, counts, restores or deletes them; storage is the operator's responsibility. No reviewed resolution command is added. This is consistent with deferred pruning.

2026-10-03 (operator, D1): The recovery-point objective holds unattended by counting verified-but-unaccepted v5 uploads toward freshness, and status says so. A pending upload counts only after the operator side has re-read its exact stored bytes, checked the HMAC with the current signing key, and matched the current source StatefulSet/PVC UIDs. Reviewed acceptance remains the only route to restore authority. The per-database signing key is escrowed off-cluster in operator material, so pending receipts stay verifiable after total cluster loss. Rationale: no daemon and no second writer to the single-writer store (rejected: automatic ingestion).

2026-10-03 (operator, D2): Volumes are outside the recovery-point objective in MP-23. Docs and status state it, and EP-157 reports it as an unmet production target. Manual volume backup and isolated restore to a new PVC remain supported.

2026-10-03 (operator, D3): HTTPS routes and protected browser login are a stated restriction of this release (the fixture is HTTP-only) and an unmet production target. They are not acceptance criteria.

2026-10-03 (operator, D5): Canonical SHA-256 digests stay in nagare-dsl beside canonical serialization; ADR 22 is amended. There is still exactly one inventory digest function.

2026-10-03 (operator, D6): The recovery-point objective is a per-context setting, `NAGARE_BACKUP_RECOVERY_POINT`, with two presets. `hourly` (the default) keeps today's 15-minute schedule with a warning at 30 minutes and a breach at one hour. `daily` runs once a day with a warning at 25 hours and a breach at 26 hours, leaving margin for dump and upload time. The preset is written into the signed schedule metadata, so freshness is graded against the accepted CronJob, never against an editable environment value. Changing it is a reviewed CronJob update. The data-protection and safe-use gates still require `hourly` for the critical intranet context. Rationale: some clusters accept daily backups. Two proven presets keep test and native-proof cost bounded (rejected: arbitrary durations, per-database overrides).

2026-10-02 (consolidation): Rewrite this MasterPlan as a single current-state document, archive superseded audits and closed findings unchanged under `docs/audits/mp23-archive/`, and clean each active child's living sections the same way. Rationale: accumulated dated paragraphs and audit documents made the next step unclear and let status drift. No scope, dependency or acceptance criterion changes.

2026-10-02: The operator authorizes implementation through the supported contract and non-publishing release acceptance. An independent reviewer, not the operator, performs technical verification including the runbook and findings closure. Operator input is needed only for unavailable access, product-scope changes, actions beyond this authorization, and the final production go/no-go.

2026-10-02 (historical; MP-21 prerequisite superseded by the October 8–9 drills and 2026-10-09
MP-21 refresh): Production use requires the data-protection gate (one-hour recovery-point objective after total cluster loss, including upload/verification lag and retry margin) and MP-21's upgrade/recovery gate. MP-23 completion alone does not establish production readiness.

2026-10-02: Retire failed prerelease fixtures (`f15-preview`) from acceptance instead of preserving their transactions indefinitely; keep their history honest and prove recovery on the supported candidate. EP-156 owns non-blocking scoped teardown.

2026-10-02: Knative collection uses a distinct opt-in reviewed adapter rather than changing old Orphan reviews; graph observations are evidence, not atomic deletion bounds (ADR 22).

2026-10-02: Adopt Effectful interpreters incrementally below native rendering, parsing and recovery, one failing workflow at a time; no wholesale rewrite (ADR 22).

2026-09-30: Separate the safe-use gate from release acceptance; require the local platform bootstrap before every cloud candidate; start EP-158 access work immediately. Platform upgrades are the phase after the initial feature set and safe-use acceptance.

2026-09-29: One serial operation driver shared by apply and resume; resource reads are separate from mutation evidence. Cloud integration (EP-156) has scheduling priority over the full local scenario (EP-155); both remain required.

2026-09-28: Operator-approved scope reduction (the Supported release contract table). Keep the journal/state; defer live overwrite, interactive maintenance (cancel EP-161) and scheduled pruning; guard new admission of deferred operations while preserving recovery of admitted ones. External tool evaluation stays independent in MP-24/EP-163; no Flux and no new messaging engine.

2026-09-27: No GKE anywhere in this initiative.

2026-09-26: The first release claim targets fresh inventory-backed contexts; existing contexts are disposable and admitted contexts cannot change platform version. Split EP-148 into EP-158–161 and EP-150 into EP-152–157 without waiving acceptance.

2026-09-24: Immutable replacement is distinct from configuration drift; the planner refuses an ordinary update when an adapter reports replacement required (ADR 22).

2026-09-16: Foundational architecture — compose independent scopes in one validated inventory; one typed declaration path for render, review and execution; separate desired, observed and historical state; keep native executors; constrained late-bound outputs behind review barriers; single-writer store specified as conditional writes; shared history in the context state bucket (EP-151); provider-durable draft-release evidence for publication.

- Decision (operator, 2026-10-05): fix F60 in MasterPlan 23 "unless it's going to take hours", superseding the same day's deferral. That deferral had been recommended without the deferral ledger ADR 25 requires. Shown the ledger (F40 remainder and F48 deferred; limits inside closed F35, F37, F38, F49 and F50), the operator un-deferred F60. The fix binds incarnations from the create's own completion identity instead of a fresh observation at convergence. If the estimate exceeds about two hours, the implementer reports back first.
  Rationale: F60 is the last open item of the F49/F51 incarnation class, and the recovery model already reproduces it with one fault, so a fix can be proven quickly.
  Date: 2026-10-05

- Decision (operator's condition applied, 2026-10-05): F60 stays deferred. The implementer estimated 4–6 hours (journal schema change, adapter result type, create-identity binding), above the operator's "unless it's going to take hours" limit. The design is recorded in the tracker's F60 entry, and the model's tolerance remains.
  Date: 2026-10-05

- Decision request (2026-10-05, pending operator): replace finding-by-finding work with the structural plan in [the exhaustive review's proposal](../audits/mp23-exhaustive-review-2026-10-05/PROPOSAL.md): one proof-based close rule (ADR 26), identity through one checked accessor plus a create-identity record, coverage generated from a kind table, one release line, an operator-attested last-resort exit, and no new review rounds until a final verification. Seven review rounds produced 65 findings at about ten a day without converging, and the review enumerated 266 untracked wedge or stuck cells. Implementation holds after nagare's current checkpoint until the operator decides.

- Decision (operator, 2026-10-05): "approve all six, go with release line b". The structural plan replaces finding-by-finding work:
  - [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): a proof-based close rule and the attested last-resort exit;
  - [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md): identity recorded at creation and read through one checked accessor (this un-defers F60);
  - the [ADR 25 amendment](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): generated coverage and review against a line;
  - release line (b), defined at the top of Progress.

  Rationale: the exhaustive review enumerated 266 untracked wedge or stuck cells, 22 untracked identity paths and 17% model coverage. All of them trace to three structural causes that one change each removes.
  Date: 2026-10-05

## Outcomes & Retrospective

**Outcome (2026-10-09): complete.** Nagare 0.4.0 shipped what IR-24 asked for:
- One typed, revision-bound inventory for every managed resource, composed from independent scopes.
- Reviewed plans with a durable cross-tool journal, a supported exit from every stopped state (ADR 26), and identity respect (ADR 27).
- Cloud, host, artifact and cluster adapters, with a GCS-backed store for cloud contexts.
- Backups with receipts and verified isolated restore for PostgreSQL, Redis, ClickHouse and volumes.
- All seven IR-24 cases, proven by named assertions under one payload identity.

The operator's production goal (checklist sections 2–4) was also met on the final candidate: data restored after cluster loss, node upgrades (NixOS and k3s minor) that commit or revert by themselves, and a side-by-side PostgreSQL major upgrade whose failures return to the old instance. Ninety-five findings were recorded; 84 are Closed, and the rest are Verifying, deferred with a named home, or ledgered (Final status).

**What moved:**
- Full-context VM collection and the F40 remainder → [MasterPlan 25](25-reviewed-full-context-teardown-with-vm-workload-collection.md).
- F48's code fix, release tooling, proportional gates and the release runbook → [MasterPlan 26](26-make-platform-changes-and-releases-routine-after-the-inventory-release.md).
- Replacement upgrades → [MasterPlan 21](21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md).
- Team operation → [MasterPlan 24](24-operate-nagare-as-a-team-run-workplace-intranet-paas.md).
- F89, F91 and F94 → the next release; F77 and F78 → the deferral ledger.
- Also to the next release: the D6 sentence in the release notes, and `storage snapshot`/`storage restore` accepting `Application` configs (EP-160).
- The deep tier is per-release monitoring.

**Lessons**, distilled into [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)'s 2026-10-09 amendment:
- **Find defects with interpreters and models, and let native runs only confirm** (ADR 25). Brute-force deep-tier runs found one Kubernetes-semantics defect per run until the proof rules were derived from validated API semantics (2026-10-06).
- **Every feature needs its failure exits tested through the real CLI loaders.** F86's stuck-pod exit and F88's status churn passed test registries but failed the real path.
- **Upgrade paths rot unless exercised.** The section 3 procedure needed a sops-nix re-pin, a reboot step and F95's session-loss fix, and each surfaced only when a drill reached it. Execute every documented operator procedure once before a candidate is cut.
- **Bind acceptance to one frozen candidate and one checklist.** Evidence spread across about ten candidates and many audit documents hid progress and new defects (2026-10-02). The checklist and per-candidate result directories fixed that.
- **Rehearse release mechanics early.** The notes are bound to the candidate, so the x86_64 C4 harness, the evidence assembler and the publication path without Actions each cost a re-cut or a late detour.
- **Unattended native runs need their human dependencies settled first,** such as the Tailscale check approval and gcloud re-authentication, or they stall overnight.


## Revision Notes

2026-10-09: Reconciled production-readiness wording with the current accepted node/database drills
and MP-21's optional replacement scope. Preserved the distinction between node configuration and
unsupported general payload/schema transitions; no child status or acceptance evidence changed.

2026-10-09: Closed out the plan:
- recorded the final status (candidate `83124396`, gates, checklist sections 2–4, findings at close, v0.4.0 publication);
- ticked steps 3, 3a, 3b, 3d and 5;
- marked the registry;
- finalized the IR-24 table;
- added the 2026-10-07 goal amendment, the 2026-10-07 to 2026-10-09 decisions and surprises, and the Outcomes & Retrospective.
The superseded 2026-10-04 finish line and the dated checkpoints moved verbatim to [the pre-close snapshot](../audits/mp23-archive/plan-history/mp23-progress-before-close-2026-10-09.md).

2026-10-02: Consolidated the plan into a single current-state document after an implementation assessment: replaced dated entrypoints and finish sequences with one ordered remaining-work list (Phases A–D), pending operator decisions D1–D5 and three explicit gates; recorded newly found release-path and recovery-point gaps; archived history unchanged. Earlier revision notes are in the snapshot.
