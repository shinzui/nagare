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

**Production readiness is a separate, later gate.** The operator intends Nagare to host critical developer tooling on a company intranet. Completing MP-23 does not by itself make that safe: production use additionally requires (a) the data-protection gate in Progress — off-cluster backups meeting a one-hour recovery-point objective after total cluster loss, verified restored content, and a documented recovery procedure — and (b) a supported, rehearsed platform upgrade on an inventory-backed context with rollback or data-preserving forward recovery, which [MP-21](21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md) owns. EP-157 must report any unmet production target explicitly rather than implying readiness.

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
| 153 | Close managed command coverage for the inventory release | docs/plans/153-close-managed-command-coverage-for-the-inventory-release.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-158, EP-159, EP-160 | In Progress |
| 154 | Validate installed inventory packages on every supported system | docs/plans/154-validate-installed-inventory-packages-on-every-supported-system.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-158, EP-159, EP-160 | In Progress |
| 155 | Prove local application and data recovery end to end | docs/plans/155-prove-local-application-and-data-recovery-end-to-end.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-158, EP-159, EP-160 | In Progress |
| 156 | Prove fresh GCP convergence and shared history recovery | docs/plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-155, EP-158, EP-159, EP-160 | In Progress |
| 157 | Gate the inventory release on complete immutable evidence | docs/plans/157-gate-the-inventory-release-on-complete-immutable-evidence.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-155, EP-156, EP-158, EP-159, EP-160 | In Progress |
| 158 | Complete reviewed access and CDN operations | docs/plans/158-complete-reviewed-access-and-cdn-operations.md | EP-146, EP-147, EP-149, EP-151 | None | In Progress |
| 159 | Complete scheduled receipts and explicit retention limits | docs/plans/159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md | EP-146, EP-147, EP-149, EP-151 | None | In Progress |
| 160 | Complete verified isolated database and volume restore | docs/plans/160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md | EP-146, EP-147, EP-149, EP-151 | EP-159 | In Progress |
| 161 | Interactive maintenance deferred; delivered recovery history retained | docs/plans/161-provide-scoped-interactive-maintenance-with-durable-recovery.md | None | None | Cancelled |

Hard dependencies must be Complete before starting the dependent child; soft dependencies supply real-adapter coverage but allow fixture-backed work to proceed. EP-157's gate code is already implemented; its final assembly additionally needs every other active child's accepted outcome (see Dependency Graph). File slugs for EP-159 and EP-160 predate their current titles and are kept so existing links stay valid.


## Dependency Graph

All hard prerequisites of the eight active children are complete, so every active child can be worked now. The remaining order is set by producer/consumer flow rather than by plan number:

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

**Snapshot (2026-10-02, consolidation assessment at `c57f1638`).** Seven foundation children are complete; eight remain In Progress. The architecture is implemented and holds up under independent review: typed composition, reviewed plans, the shared serial driver, conditional filesystem/GCS history, deferred-admission guards and the registration-only entrypoint all have evidence. Independent verification on 2026-10-02 additionally proved native F20 collection with interrupted-delete recovery, clean-root recovery, VM power transitions, CDN disable and purge, and isolated restores with checked content for PostgreSQL, Redis, ClickHouse and a volume on GCS. Access grant/revoke has only the implementer's native run on the retired fixture and must be re-proven in C3. That evidence spans roughly ten different candidates and partly the retired fixture, so none of it is yet final-candidate acceptance.

**Phase A checkpoint (2026-10-02, claude-opus-5-5, `d4aa7168`–`7e26a1bb`).** A6 is done: the full style gate passes. A1 (F33), A2 (F32) and A3 (F31) have source fixes with regressions that fail on the old code, and await independent closure and their native proofs (C3, or a cp3 image-cleanup run for F32). A5 is source-complete for the clone-free `typed-config` check (new read-only `nagarectl app check`) and the cloud fixture/health producer. The scenario-assertion names in health records still have no producer (see Surprises). A4 reached its terminal state later the same day. F34 was traced to reviewed DomainMapping collection using Orphan propagation and fixed in `beca6886` (ADR 22 amendment); cp3 was repaired under the gated EP-155 recovery, and the F30 transaction converged with identities, data and a zero-operation replan intact. F30, F16 and F34 await independent verification.

**Phase B checkpoint (2026-10-02, `cf3cd7fd`).** Two B1 pieces are done: `server status`/`doctor` grade each accepted database's recovery point from verified receipts, and the stale GCS statement in the backups guide is corrected. On cp3 the new rows show breaches without operator ingestion, which is the D1 gap now visible on the operational surface. B2–B6 need native local or cloud runs, and B3/B6 need operator approval for cloud mutation.

**Operator decisions and B1 checkpoint (2026-10-03, claude-opus-5-5).** The operator decided D1, D2, D3, D5 and the new D6 (Decision Log). D1 and D6 are source-complete. Freshness counts verified pending uploads. `db escrow-signing-key` and `db verify-escrowed-backup` escrow the signing key and verify receipts without the cluster. `NAGARE_BACKUP_RECOVERY_POINT=hourly|daily` sets the schedule and is bound into the signed metadata. 1,138 tests and the style gate pass. On cp3 (read-only, development binary), all five recovery-point rows turned healthy without ingestion, and escrow plus offline verification succeeded with refusals intact. D2 and D3 are recorded in docs and EP-157/158. D5 is recorded in an ADR 22 amendment. The public `scheduledRetention` check exposed a status bug: the signing Secret was matched on API group `v1` instead of the core group. It is fixed in `6bb275e7`, and on cp3 all five schedules are now listed. Orphan uploads are documented as permanently unresolved (operator decision). B1 still needs source-replacement ingestion, which is a native run.

Open findings ([tracker](../audits/mp23-findings.md)): F35 (preflight refusal after admission strands the transaction; found by the 2026-10-03 cp3 drills; fixed in `570467f0` with the `abandon-refused-operation` decision and proven natively, Verifying), F34 (DomainMapping Orphan collection broke the Kourier gateway; source fix and cp3 repair done, verification pending), F30 (status-only churn strands an admitted Service correction; source fix in `95b58a24`/`52432400`, native correction interrupted at the operator's instruction with its transaction preserved, per `c57f1638`), F31 (registry credential refresh can lag expiry), F32 (image cleanup can select a sandbox image in use), F33 (cloud collection does not recheck the reviewed physical incarnation; unfinished guard checkpointed in `27bb0cd4`). F15 and F16 are Verifying.

**cp3 data drills (2026-10-03, implementer, under the cp3 claim protocol agreed with session nagare-phase-b).** B2 database-tamper refusal and wrong-destination refusal at planning are proven natively. A foreign object created between plan and apply wedged the store (new P1 F35), and the store was recovered. Volume tamper detection happens only inside the Job, after the scratch PVC exists (EP-160 Surprises). The B1 source-replacement premise conflicts with the design; no supported replacement exists (EP-159 analysis). [Raw record](../audits/mp23-implementer-results-2026-10-03/cp3-data-drills.json).

**Scenario assertion checkpoint (2026-10-03).** The record shape is agreed and implemented across EP-155, EP-156 and EP-157. C2 and C3 now produce gate-ready health by recording each assertion as it passes and finalizing after verify. A name without a bound record refuses at assembly and in the CLI validator.

**B5 checkpoint (2026-10-03, claude-opus-5-5, `dc53beb3`–`6ed92e61`).** B5 is source-complete with bounded cp3 proof on development binaries.
- **Companion collection.** Retained collection now admits StatefulSets (Background propagation), ServiceAccounts, Roles and RoleBindings. On cp3 a retired PostgreSQL lost exactly its six stateless companions in three dependency-ordered reviews, while its PVC and Secrets kept their UIDs.
- **Rename.** `db rename` is the first native binding of EP-149's migration contract. On cp3 it moved a seeded database through 72 reviewed stages. The rows survived, all nine old incarnations stayed retained and fenced, and the auth signing key kept its identity.
- **Fixture.** `fixtures/inventory-release/local/scenario.json` defines the full C2 run and is validated against the gate's check names.

The native run exposed two review readers that assumed base mutations; both are fixed in `bc2fd90e` (Surprises). 1,148 tests, the style gate, the command audit and the CLI architecture check pass. The four Haskell architecture size overages came from `9fef284a`; they were fixed in `2124ce2a`. Collection of durable members, topics and migrated-away incarnations is the scope proposal below.

**Remaining work.** Each item is owned by the named child, whose plan holds the detail. Work proceeds in this order; items within a phase can run in parallel.

Phase A — blockers (code and local regressions; no cloud mutation):

- A1 (EP-153): finish F33 — bind the selected stack entry, physical ID and protection into collection evidence and recheck them at preflight and immediately before execution; regression for a change between the two.
- A2 (EP-153): fix F32 — protect images referenced by Ready and retained sandboxes and the configured sandbox image; fail closed on missing sandbox observations.
- A3 (EP-154/156): fix F31 — align refresh cadence and the token-lifetime check with metadata-token caching so a refresh always lands before expiry.
- A4 (EP-153/156, executed on local `cp3`): bring the interrupted F30 correction transaction, which lives in the local `nagare-mp23-cp3` store, to a terminal state through the supported resume path, then verify F30 and F16 independently with the known row and identities preserved. Do not dispose of `cp3` before this transaction is terminal.
- A5 (EP-157/154): make the clone-free rehearsal emit the check names the release gate requires (`typed-config`; it currently emits `inventory-compile`), add the missing cloud `fixture.json` and `cloud-health.json` producer, and correct `docs/user/upgrades.md`, which still calls inventory evidence an optional attachment.
- A6 (EP-153): make the repository-wide `just haskell-style-check` (including fourmolu over all tracked Haskell files) pass and keep it passing.

Phase B — finish the supported features (code plus focused local proof):

- B1 (EP-159): make the recovery-point objective hold unattended by counting verified pending uploads and escrowing the signing key off-cluster (D1); make the objective a per-context `hourly`/`daily` preset bound into the signed schedule (D6); surface freshness in `server status`/doctor rather than only `--check-freshness`; state volumes as outside the objective (D2); prove source-replacement ingestion; give orphaned uploads (objects without a receipt) a public disposition, show `scheduledRetention` as unenforced in `inventory status`, and correct the stale GCS-acceptance statement in `docs/user/backups-and-disaster-recovery.md`.
- B2 (EP-160): native refusal of a tampered accepted backup (database and volume) and of a wrong-incarnation destination; interruption during Redis load and a partial ClickHouse restore, or a recorded argument that existing runs cover them; manual cloud receipts for Redis and ClickHouse or an explicit scheduled-only statement.
- B3 (EP-158): native Google DNS/CDN create, disable, retire and collect; record the HTTPS/browser-login disposition (decision D3).
- B4 (EP-153): promote the `Cleanup` and `InfraDestroy` routes and the `infra-destroy`, `smoke` and `local-smoke` recipes; bring every gap row in the coverage catalogue to migrated or an explicit guarded exclusion.
- B5 (EP-155): check in the full local scenario fixture; implement the bounded retained PostgreSQL rename (IR-24 case 3) and companion collection bindings. Source-complete with cp3 proof (2026-10-03 checkpoint); final-candidate proof is C2.
- B6 (EP-156): prove takeover from a genuinely different client.

Phase C — one frozen candidate, proven natively:

- C1: installed local platform bootstrap on `nagare-mp23-cp3` (candidate gate).
- C2 (EP-155): the full local scenario including interruption, wrong-incarnation refusal, history export/restore and the PostgreSQL rename.
- C3 (EP-156): a fresh cloud context with typed host credential delegation; the six operational checks (application change with owner isolation and unchanged replay; GCS backup and isolated restore; interrupted-operation recovery; clean-root recovery; writer refusal/takeover; exact cleanup including cloud teardown); a genuine automatic credential refresh and expired-credential pull (F15); independent runbook execution for the safe-use gate.
- C4 (EP-154): clone-free installed rehearsal on aarch64-darwin and x86_64-linux at the candidate revision, with `nix flake check` green.
- C5 (EP-157): non-publishing assembly of `docs/release-evidence/<revision>/`, IR-24 cases 1–7 mapped to that evidence, release notes stating unmet production targets.

Phase D — close-out: finalize each child's living sections, mark the registry, distill durable lessons into ADR 22, update IR-24's status from evidence.

**Operator decisions.** D1, D2, D3, D5 and D6 were decided on 2026-10-03 (see Decision Log). One remains pending and is not the implementer's to make:

- D4 — Recovery-time and retention targets for production use (no values have been agreed). It gates production use, not MP-23 completion; EP-157 reports it as an unmet production target.

Scope proposal from B5, decided 2026-10-03 as deferred (Decision Log). Three collections would each need a new operation, not a missing binding:
- releasing durable PVCs and credential Secrets;
- deleting broker topics, which also keep a retired broker's StatefulSet blocked;
- collecting a migrated-away incarnation that shares a live ResourceId.

None is required by the supported release contract. Retained members stay visible in status, and a renamed database's old writers are fenced.

**Cross-plan gates.**

- *Safe-use gate* (before any real low-risk workload): on one candidate that first passed C1 — the six cloud operational checks and F15 on a fresh context; EP-158 access grant/revoke; [the operations runbook](../runbooks/inventory-operations.md) executed end to end by an independent reviewer with F14–F18 recorded in the tracker; driver consolidation present. Final production go/no-go remains the operator's.
- *Data-protection gate* (before real company data): the context uses the `hourly` objective; every signing key is escrowed; every authoritative store backed up off-cluster within the one-hour objective measured from the latest usable recovery point (including upload, verification and retry delays); freshness deterioration visible before breach and a breach reported unhealthy; backups and recovery credentials retrievable with the cluster and operator root gone; verified restored content; corruption and incomplete-upload refusal; documented, timed recovery procedure.
- *Production gate* (outside MP-23 completion): the MP-21 supported upgrade/recovery rehearsal on an inventory-backed context.

**IR-24 verification cases** (update only with evidence):

| Case | Evidence today |
|---|---|
| 1. Collisions refused before mutation | EP-144 unit coverage only |
| 2. Foreign or absent owner reported as an adoption decision | Foreign-UID refusal at retirement (installed); no adoption-decision report |
| 3. Rename creates, migrates, verifies, retires with data preserved | Native `db rename` on cp3 (implementer, development binary): known rows preserved, old incarnations retained; final-candidate proof is C2 |
| 4. Interrupted multi-component operation resumes without replaying effects | Installed cloud resume and takeover; independent native F20 interrupted delete |
| 5. Drift categories distinguished | Foreign, missing, retained orphan and policy-bound collection proven; repairable configuration drift and immutable replacement not |
| 6. Disposable context renders, applies, converges, no-ops, removes per policy | Installed cloud convergence and unchanged replay; full-platform no-op and local scenario open |
| 7. Release evidence under one immutable payload identity | Gate code independently tested; no real evidence directory exists |

**Working rules for remaining work.** Name the assertion, expected progress and time budget before any costly run; an unmeasured path gets a diagnostic checkpoint after 15 minutes, and a second identical failure stops dependent work until the cause is identified. Retry only after an input, implementation or observed condition changes. Never reset history or patch a provider to manufacture a result; recover already-admitted transactions through their recorded identity. Batch cloud mutations into one rehearsed, bounded sequence approved once. Record outcomes in the owning child plan and the tracker; do not create new standalone audit documents, competing entrypoint paragraphs or dated finish sequences in this file.


## Surprises & Discoveries

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

2026-10-02: Production use requires the data-protection gate (one-hour recovery-point objective after total cluster loss, including upload/verification lag and retry margin) and MP-21's upgrade/recovery gate. MP-23 completion alone does not establish production readiness.

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


## Outcomes & Retrospective

Phase A (2026-10-02) delivered the style gate, source fixes for F31–F33 and the clone-free/cloud evidence producers; it surfaced F34 and the missing scenario-assertion producer.

Delivered so far: the typed inventory foundation, reviewed plans and durable journal, cloud/host/artifact and cluster adapters, lifecycle policy, the GCS store and fresh bootstrap (EP-144–147, 149, 151, 152), plus substantial command, access, CDN, backup and restore implementation with independent checkpoint evidence. Remaining: the Phase A–D items in Progress, and the pending operator decisions D1–D5.

Lessons so far: plans accumulated dated narrative faster than they were reconciled, and evidence was spread across many candidates and standalone audit documents, which hid both progress and newly introduced defects. Keep one current snapshot per plan, record evidence where its owner reads it, and bind acceptance to one frozen candidate.

At completion, compare outcomes with IR-24, update its status only with evidence, and distill durable lessons into ADR 22 and affected ADRs. Do not publish a release or modify operator deployments as a side effect of plan updates.


## Revision Notes

2026-10-02: Consolidated the plan into a single current-state document after an implementation assessment: replaced dated entrypoints and finish sequences with one ordered remaining-work list (Phases A–D), pending operator decisions D1–D5 and three explicit gates; recorded newly found release-path and recovery-point gaps; archived history unchanged. Earlier revision notes are in the snapshot.
