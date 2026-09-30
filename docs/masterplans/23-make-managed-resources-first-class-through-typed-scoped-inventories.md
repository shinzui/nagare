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
---

# Make managed resources first-class through typed scoped inventories

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable decisions into docs/adr/ in the same change.


## Vision & Scope

**Current release boundary — operator-approved reduction (2026-09-28).** Keep the typed inventory, independent ownership scopes, cross-tool review/journal, and filesystem/GCS state. Narrow the unfinished lifecycle behavior as specified below. This decision supersedes earlier instructions to preserve every feature of the original decomposition; it does not waive proof for the behavior still supported. Historical implementation evidence remains credited. A plan edit does not itself disable a command or establish release readiness.

| Area | Required for MP-23 | Deferred from this release |
|---|---|---|
| Ownership and coordination | Typed composition, collision checks, reviewed native effects, resumable cross-tool journal, conditional state, independent releases | Replacing the journal/state with another tool; an always-on coordinator |
| Databases and messaging | Existing PostgreSQL, Redis, ClickHouse, and existing Redpanda/topic operations | New database or messaging engines; a generalized provider/plugin framework |
| Backups | Existing native backup formats; exact verified manual and scheduled receipts; survival after Job cleanup; local MinIO and cloud GCS proof | Generalized scheduled keep-N selection/pruning and automatic backup expiry |
| Restore | Verified isolated database destinations for all three existing engines; volume restore to a new PVC; source preservation | General live database/PVC overwrite and automatic recovery promotion/cutover |
| Maintenance | Existing statically declared reviewed hooks and read-only inspection; recovery of already-recorded sessions/fences | New custom interactive mutating maintenance and unrestricted exec/migration sessions (EP-161 cancelled) |
| Validation | Complete coverage of the declared supported contract, explicit guarded exclusions, every supported native system, actual local/GCP runs, immutable evidence | No reduction of these validation gates |

Backups are retained by default. Deferred scheduled keep-N/expiry must be visible as unenforced in review, status, and user documentation; operators must account for storage growth. Existing exact reviewed manual pruning is retained only where its current proof applies. EP-153 must prevent new admission through deferred command, library, recipe, and saved-review paths. Recovery of already-admitted transactions remains available under the original identity and evidence checks; scope reduction must never strand partial deletions, live fences, or sessions. Do not delete that recovery code or its history merely because new admissions are deferred.

[EP-163](../plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md) evaluates external tools beneath this boundary. K8up/restic is the primary volume/application-backup candidate, CloudNativePG/Barman is the separate PostgreSQL comparison, and Velero is a secondary desk comparison because of the operator's concern about its project direction. EP-163 assesses project direction and maintenance continuity alongside recovery behavior; no candidate is a selected dependency. No Flux, implicit replacement GitOps platform, or additional messaging engine is part of this work. Tool evaluation does not gate MP-23, and adoption needs a subsequent decision supported by evidence.

**MANDATORY OPERATOR BOUNDARY — NO GKE (2026-09-27).** Nagare supports local k3d/k3s and k3s on a NixOS VM in GCP Compute Engine. Do not create, start, use, authenticate to, select, or request access to a GKE cluster for this initiative. Existing workstation GKE contexts are unrelated. No child may add GKE credentials, probes, compatibility, or access as a completion gate. EP-156 owns actual GCP/NixOS/k3s and GCS integration; GCP does not mean GKE.

Address [IR-24](../improvement-requests/make-managed-resources-first-class.md): an operator can obtain one complete, typed, revision-bound account of Nagare-managed cloud, host, Kubernetes, data, credential, artifact, and release/control resources. Compilation rejects conflicting ownership before mutation. Review exposes creation, adoption, update, replacement, migration, retention, and deletion. Apply executes dependency-aware native operations with durable evidence; resume skips proven completed work. Status explains identity, ownership, dependencies, drift, health, and retirement decisions.

Platform components and applications retain independent desired-state ownership and release cadence. Each scope is one owner's complete declaration with its own revision. The context inventory composes these declarations and validates their shared claims; it is not another independently editable desired-state document. Updating one selected scope preserves every unselected scope. Application deployments can submit authorized contributions to platform-owned routing/configuration, but cannot seize the entire shared object or advance the platform release.

The architectural objective is to reduce policy scripting through a shared Haskell model. Smart constructors, explicit alternatives, typed capability references, and opaque validated/reviewed values enforce structural guarantees. Pure functions validate whole-graph properties. Adapters observe live facts and execute native provider operations. The same declarations produce inventory, review, rendering, and execution inputs. A separate handwritten inventory mirroring existing scripts is not acceptable. Acceptance includes removing superseded orchestration and duplicated guards after their replacement is proven.

Desired state, observed state, and execution history remain separate. Logical IDs survive names and ownership transfers; physical identities identify individual incarnations. Resource membership and policy are known before external mutation. Generated values are constrained typed references, not permission to introduce new resources. Data defaults to retention; unknown observations never imply absence. Credentials are private adapter inputs, absent from public review/evidence representations.

The first implementation runs in the operator CLI with private context-owned state, one writer, immutable snapshots, and a durable journal. Its release claim begins with fresh inventory-backed contexts; existing contexts and their data are disposable for this first release. Pulumi, NixOS, Kubernetes, Helm, storage, and registry tools retain their native responsibilities. This does not add a daemon, distributed coordinator, new provider engine, automatic foreign-resource adoption, generic schema rollback, in-place platform version upgrade of an admitted context, or production rollout. It does not complete the separate replacement-upgrade initiative. A later controller can implement the same store/adapter protocol; multi-workstation exclusion requires shared coordination and is not claimed by the filesystem implementation. A cloud context may instead keep that state in its state bucket, beside its Pulumi state. That store refuses a second writer from another machine through conditional writes and needs an explicit operator takeover to resume someone else's work; it still has no lease or liveness detection and is not a distributed coordinator.


## Decomposition Strategy

The foundation and adapter children EP-144–147, EP-149, and EP-151 are complete. EP-148 is superseded implementation history: EP-158 owns access/CDN, EP-159 scheduled backup receipts and the retention boundary, and EP-160 verified isolated database/volume restore with its accepted shared fence preserved. EP-161 is Cancelled under the 2026-09-28 decision; its delivered code and recovery evidence remain historical inputs. EP-153 owns supported command coverage and enforcing the deferred-operation boundary; EP-154 installed native packages; EP-155 local integrated recovery; EP-156 GCP integrated recovery; and EP-157 immutable release evidence. EP-152 fresh bootstrap is Complete. EP-150 is superseded history; its publication, store restoration, compatibility, and test infrastructure are inherited, not reimplemented.

This update reduces product scope by the operator's explicit decision. Local success remains an engineering checkpoint, not adoption readiness. EP-157 closes only after EP-152–156 and EP-158–160 satisfy their revised acceptance and the deferred routes have proven admission guards. EP-148, EP-150, and EP-161 are Cancelled records, not pending dependencies or claims of completed implementation. The fresh-context release boundary, no-GKE rule, and offline-only Cloudflare proof remain unchanged. Preserve IR-24's seven verification cases, including the bounded retained PostgreSQL rename in EP-155; this does not require universal live overwrite or automatic recovery cutover.

The local ADR corpus was scanned by filename/title and relevant records were read. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates payloads/private workspaces; [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) preserves operator host identity; [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) defines release/version transaction semantics; [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) binds immutable release evidence; [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) confines cloud writes; [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) preserves self-reversion; [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) protects forward-only storage growth; [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) protects private operator/state material; [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) guards protected replacements; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) governs Haskell style; [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds native review and receipts; [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) protects irreversible cutover; [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) separates route/TLS ownership; and [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) defines cache retention and trust boundaries.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) records the accepted architecture from this discussion; it is a design decision, not a claim of implementation. Mori searches found no relevant cross-repository ADR to import. The local mori.dhall and mori show --full do not declare docs/adr as a profiled bundle, so the existing ADR filename/frontmatter convention is preserved. Dependency APIs must be researched through Mori during implementation and current upstream releases checked before changing bounds; this plan prescribes no dependency upgrades.

Rejected alternatives were isolated platform/application inventories without shared conflict checks; one global release coupling all applications to platform upgrades; a manually maintained resource list beside imperative scripts; replacing native reconcilers; and an always-on control plane before the operator-driven protocol is proven.


## Exec-Plan Registry

**Operator priority — cloud integration first (2026-09-29).** The operator urgently needs a cloud cluster that can be maintained safely after bootstrap. Prioritize EP-156's installed Compute Engine/NixOS/k3s/GCS convergence and recovery ahead of completing EP-155's local integration scenario. Pull EP-153 command repairs, EP-154 installed-package checks, and EP-158–160 features forward only as the selected cloud assertion needs them. Local focused regressions still prove a repair before native mutation; completing the local k3d/MinIO scenario is not a cloud prerequisite. Preserve existing local evidence and finish full local integration and both native-system gates before EP-157 release acceptance. This changes execution order, not supported scope, child completion, or the fresh-context/no-GKE boundary.

**Implementation entrypoint.** `$master-plan implement docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md` resumes the ordered checkpoints in Progress. For this initiative, the operator-requested producer/consumer sequence overrides the skill's default of selecting the first eligible registry child and finishing that entire child before switching. The registry records ownership and whole-child status; it does not express the checkpoint schedule. Hard dependencies still apply.

**Open implementation findings.** Read [the MP-23 audit tracker](../audits/mp23-findings.md) before selecting affected work. It owns stable finding IDs, fix evidence, independent verification, and unresolved handoffs. Record repairs there; an acknowledged message or source edit does not close a finding. Reconcile affected P1 findings before another native rehearsal and include unresolved IDs in every implementation handoff.

**Current implementation entrypoint — converged original-review cloud bootstrap, 2026-09-30.** [Installed recovery evidence](../audits/mp23-native-bootstrap-results-2026-09-30/registry-recovery.json) proves revision `39842f8058bdaaf94819365b1f2511a3a7147246` recovers the original private-controller operation through a saved accepted-host/unit capsule. Read-only preparation preserves generation 469. Journaled recovery takes 101.552 seconds; the original Deployment and pod UIDs remain exact and Ready. Public resume of the original 210-operation transaction converges in 230.454 seconds at generation 549/sequence 492, with no active transaction, claim, fence or migration. All 22 accepted revisions and six prerequisite converged revisions are unchanged; all 22 scopes converge. The live platform has 31 Running/Ready Pods and two Succeeded migrations. The payload remains `nagare-0.4.0-6082dbd6aac0`. Continue ordered checkpoint 4's reviewed two-application/database and GCS backup-to-isolated-restore assertions. Steady private platform credential expiry/re-pull coverage, independent F14/F15 closure, M1/M2, and full local/native/release gates remain open. Platform upgrades follow initial feature completion and safe-use acceptance.

The earlier single-operation experiment did not establish executor correctness. E10 exposed the dependent preflight and missing terminal branch, and the production replacement now handles them. The earlier 8/11-subprocess append and 501-read empty native lookup were repaired by the selected-read/store checkpoint. Active-command and native acceptance gates remain prerequisites of release readiness.

**Execution control for every remaining checkpoint.** The implementing agent owns detection and diagnosis of stalled work; the operator must not have to ask why progress stopped.

- Before a costly run, name the user-visible assertion, expected observable progress, elapsed-time budget, and safe interruption/recovery boundary. Use an existing measured budget where available. For an unmeasured path, allow at most 15 minutes before a mandatory diagnostic checkpoint; this is not an automatic process-kill timeout. Known replay failures already trigger diagnosis and must not consume that allowance again.
- At the budget breach, or the second attempt with the same failure and no new evidence, stop launching dependent work. Inspect the process/provider state and identify where time is spent. Distinguish journal loading, provider work, and verification. Report the evidence, current hypothesis, and one bounded check that can confirm or reject it. Change the approach when that check rejects the hypothesis.
- A long build or provider operation may continue only with observed useful progress, a revised finite checkpoint, and a reason waiting is preferable to safe interruption. Process liveness, repeated polls, and an advancing replay counter on a known unusable path are insufficient. Preserve ambiguous transactions; never reset history to get past a delay.
- Retry only after a relevant input, implementation, or observed external condition changes, or for an explicitly bounded transient-failure diagnostic. After the fix, prove the previously failing public path and retain the measurements before resuming dependent work. Report accepted behavior and remaining blockers; command count, patch count, and passing unrelated tests are not progress evidence.

Reviews of remaining checkpoints must test the riskiest operational assumption against code and representative evidence, including aggregate command cost and recovery after interruption. A completed prerequisite can contain a newly discovered blocking defect. Assign that defect and prevent affected execution immediately rather than deferring it to final release assembly. Do not require a new broad audit before fixing the known blocker.

**Resume procedure after the 2026-09-28 scope reduction.** Follow this procedure before selecting implementation work:

1. Read the current Vision & Scope and Progress, then the selected child's current milestones and recorded acceptance evidence. The revised scope governs; historical notes are evidence, not instructions to resume deferred work. EP-161 is Cancelled. Do not continue new live-overwrite, interactive-maintenance, or scheduled-prune feature work from an older handoff.
2. Preserve concurrent edits and retained fixture/state identities. Before mutating a selected fixture, inspect its existing transaction/fence/session state through the supported read-only path. An already-admitted operation may need its existing evidence-bound recovery; do not reset its history or treat cancellation as completion.
3. After the command-boundary repairs above pass, reconcile EP-153's deferred-admission and retained-recovery checkpoint, which Progress already records as passing. Reuse that proof while its inputs remain applicable; do not repeat a full command audit. Continue any remaining boundary assertions only when current evidence identifies them.
4. Reconcile the EP-154 installed checks needed by the selected cloud command and the existing EP-157 evidence inputs. Skip accepted outputs whose evidence remains applicable. Continue orders 3–4 through EP-156: installed second-root recovery, cluster convergence, then a real cloud application/database and recovery path. Pull EP-153/158–160 implementation into that path as needed. Reuse existing local roundtrips and keep EP-160 M1 accepted; do not require EP-155 fixture completion or all-engine local expansion first.
5. After the representative cloud path, complete remaining cloud M1/M2 assertions and supported feature gaps, then the full local scenario in order 5 and the final-candidate gates in order 6. MP-24/EP-163 research, K8up/Velero evaluation, and tool adoption are not prerequisites. Record the exact next child/assertion at every handoff; do not end at a passing partial checkpoint when more authorized work is ready.

At each checkpoint handoff, record the accepted output/evidence and next checkpoint in the owning child's living sections and keep the parent's brief Progress snapshot current. Switch children and continue within the authorized MP scope; a partial checkpoint does not mark its whole milestone or child Complete. If blocked, name the missing input and first select a ready repair, feature, or package check that advances the cloud path. Select broader local integration only when no cloud-relevant work is ready. Do not repeat an unchanged failed gate or restart a broad audit. Final acceptance remains order 6 and every active child's revised criteria remain required.

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
| 156 | Prove fresh GCP convergence and shared history recovery | docs/plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md | EP-146, EP-147, EP-149, EP-151; native resumption additionally requires EP-153 M2 phase repair and EP-159 M2 public F09 fixture (order 0a) | EP-152, EP-153, EP-154, EP-155, EP-158, EP-159, EP-160 | In Progress |
| 157 | Gate the inventory release on complete immutable evidence | docs/plans/157-gate-the-inventory-release-on-complete-immutable-evidence.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-155, EP-156, EP-158, EP-159, EP-160 | Not Started |
| 158 | Complete reviewed access and CDN operations | docs/plans/158-complete-reviewed-access-and-cdn-operations.md | EP-146, EP-147, EP-149, EP-151 | None | Not Started |
| 159 | Complete scheduled receipts and explicit retention limits | docs/plans/159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md | EP-146, EP-147, EP-149, EP-151 | None | In Progress |
| 160 | Complete verified isolated database and volume restore | docs/plans/160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md | EP-146, EP-147, EP-149, EP-151 | EP-159 | In Progress |
| 161 | Interactive maintenance deferred; delivered recovery history retained | docs/plans/161-provide-scoped-interactive-maintenance-with-durable-recovery.md | None | None | Cancelled |

Hard dependencies must be Complete before starting the dependent child; soft dependencies supply additional real-adapter coverage but allow independent fixture-backed work. Registry status values are Not Started, In Progress, Complete, or Cancelled.


## Dependency Graph

For the current repair, order 0a is a hard prerequisite of EP-156 native resumption, not of its offline store diagnostics: EP-153 M2 supplies phase-correct factory construction and EP-159 M2 supplies the public retained-prune fixture before effect and after partial deletion. Neither whole child must close first. EP-153's selected-target work and EP-156's selected-native loader have an integration dependency at order 0b; their producer/consumer fixture is accepted together. Order 0c then proves the complete append/command path. These explicit checkpoint dependencies override the former broad replay-first handoff and create no whole-child closure cycle.

EP-144 must complete first because all later work consumes its identity, declaration, wire, and validation contracts. EP-145 then defines the one authoritative store, review boundary, journal, and adapter protocol.

EP-146, EP-147, EP-149, and EP-151 may proceed after EP-145. EP-151 needs only EP-145's store contract, conformance suite, and head format; its soft dependency on EP-146 is the handoff of a new context's first bootstrap transaction, which necessarily runs on the local store because the state bucket does not exist yet. Cloud and cluster builders test against declared typed outputs without needing each other's live executors. Lifecycle policy tests against recording adapters without claiming native behavior. Their integration dependency is that every adapter exposes identity/precondition/verification capabilities required by lifecycle policy; reconcile that contract before any real adoption/migration/retirement is enabled. Until then these actions refuse explicitly, while fresh-resource/convergent operations remain independently verifiable.

EP-148's delivered code supplies EP-158–160; no active child depends on the superseded EP-148 or cancelled EP-161. EP-146/147/149/151 are complete prerequisites. EP-158 access/CDN and EP-159 backup receipts can proceed independently. EP-160 M1's shared fence is accepted and retained; M2/M3 prove isolated recovery destinations. EP-159 receipts feed EP-160 restore; existing manual receipts allow independent development. EP-153 preserves recovery of already-admitted deferred operations and proves refusal of new admissions.

EP-152 bootstrap is complete. EP-156 cloud integration has scheduling priority over EP-155 local integration; there is no hard dependency from full EP-155 acceptance to EP-156. Reuse shared scenario definitions and applicable local evidence, but implement and verify missing shared bindings through the cloud consumer when needed. EP-155 and EP-156 both remain prerequisites of EP-157 final release acceptance. EP-153 command coverage, EP-154 packaging, and EP-158–160 features proceed alongside it. Fixture and schema work can start before all features finish; final evidence must include their working implementations. Shared native proofs do not require administrative closure of the feature plan that will cite them. EP-157 requires every active predecessor's full accepted outcome. Numerical order is not execution order. MasterPlan 21's separate replacement-upgrade initiative remains independent; reuse its safety principles without silently adding its unfinished live cutover to this release.


## Integration Points

**Command-boundary repair — EP-153 owns selection and factory construction, EP-156 owns store/evidence lookup, EP-159 owns the retained-prune consumer.** EP-153 must resolve an explain target before workspace/native/provider initialization and construct recovery adapters without running pre-effect eligibility checks. EP-156 supplies selected evidence loading and generation-bound append operations, without making an index or a cache a source of authority. EP-159 supplies actual saved-review CLI fixtures that cross both boundaries. The [2026-09-29 experiments](../audits/mp23-operational-experiments.md) are the initial reproductions. These owners change shared interfaces together before broadening the native scenario; the shared driver's production regression now establishes recovery-before-dependent-preflight for the fixed consumer.

**Reduced recovery contract (2026-09-28).** EP-160 M1 is accepted; retain its state machine, store integration, and existing recovery evidence without reopening its six closure criteria. EP-160 M2/M3 now prove isolated destinations and preserved sources. Deferred live overwrite and maintenance cannot gain new admission through generic apply/resume; EP-153 distinguishes new admission from observing and resolving an already-admitted operation. A recovery action remains bound to its original target, review, and observed effect; it cannot become a route for new unreviewed maintenance.

**Backup/tool boundary.** Native engines own backup/restore semantics. Nagare owns resource/source identity, declared membership, review, dependencies, and durable cross-tool outcomes. A future operator or backup tool must have one explicit lifecycle owner and bounded delegation; Nagare must not also reconcile its generated children. Tool evaluation under MP-24 is independent of this release and selects no dependency now.

**Typed domain contract — owned by EP-144, consumed by every child.** cli/nagare-dsl/src/Nagare/Resource/{Types,Reference,Policy,Inventory,Compile,Wire}.hs and schemas/resource-inventory-v1.json define stable ContextId/ScopeId/ResourceId, provider claims/aliases, physical identity, typed exports, owner contributions/delegation, lifecycle/data/sensitivity policy, and deterministic serialization. New provider kinds extend this contract explicitly. Do not derive Generic, public setters, unchecked FromJSON, or coercible phantom roles for any type whose constructor is hidden, identity newtypes included.

EP-144 also owns the types the builders return and the planner consumes: ScopeDeclaration, ResourceBundle, DeclaredOperation, RetirementIntent, the closed contribution-kind dispatch, and the per-kind claim function. They live in nagare-dsl because nagarectl depends on it and not the reverse. composeInventory is the only route to a ValidatedInventory and returns a CompositionCandidate: the desired inventory, the base generation vector, and the explicit replace/retire changes. There is no decoder from bytes to a validated inventory; the wire form is one canonical document per scope plus a manifest, and a loader composes again. A ScopeSnapshot carries every accepted scope's full declaration and the claims still reserved by retained incarnations, candidate incarnations, and unresolved transactions. A claim set includes derived reservations for the deterministically named children of a controller. ResourceId is minted from a stable logical key, never from the provider name.

Digests identify content; revisions identify history. nagare-dsl neither computes nor stores a digest of inline content, and nagarectl derives every digest in one module. A scope revision is a purely derived generation plus that digest. No revision enters a desired digest or provider metadata, including the effective digest of a shared resource, which follows its composed content.

**State, review, and operation protocol — owned by EP-145, consumed by the adapter, application, and integration children.** cli/nagarectl/src/Nagare/Inventory/{Store,Plan,Journal,Execute,Adapter}.hs owns desired/converged heads, complete scope revision vectors, historical/retained incarnations, review bundles, operation identity, adapter capabilities, completion/recovery states, and writer locking. All persistent state stays outside payload workspaces. EP-149 adds lifecycle decisions through this interface; adapters cannot write their own scope heads.

The pipeline is compile, observationRequirements, observe, planChanges, prepareReview, publish the bundle by digest, verifyReview, then admit and execute under the process lock. planChanges is the single pure planner and takes opaque LifecycleDecisions; EP-145 exports only the empty value and EP-149 builds the rest. prepareReview calls each adapter's prepare method to produce the retained native bundle, so adapters implement observe, prepare, preflight, execute, verify, and recover. A ReviewedPlan is evidence against a snapshot read outside the lock; only admit, under the lock, yields the ExecutablePlan that authorizes effects, and its type is scoped to that lock. Refusal is an error; every admitted outcome is a TransactionResult naming its transaction. The store is specified as conditional writes (publish-if-absent, append-at-sequence, replace-head-if-generation-matches) and the transaction suite runs against an in-memory store with only those semantics, so the filesystem implementation is replaceable. Adapters never call back into a command that takes the context lock.

**Store selection and the state bucket — owned by EP-151, with the contract owned by EP-145; touches EP-146, EP-152, and EP-156.** EP-151 adds cli/nagarectl/src/Nagare/Inventory/Store/{ObjectOps,Object,Open}.hs, the `NAGARE_INVENTORY_STORE` and `NAGARE_INVENTORY_STORE_URL` context fields in Target.hs and scripts/lib/target.sh, and `nagarectl inventory store status|migrate`. It implements EP-145's InventoryStore unchanged and passes EP-145's transaction suite; it does not alter the head, journal, or member formats. EP-145 defines the executor claim in the head manifest that EP-151 uses to refuse a second machine. The store defaults to a sibling prefix of the Pulumi state in the same bucket and reuses Nagare.Ops.PulumiBackend's bucket bootstrap and ownership assertion and Nagare.Ops.ContextGuard's project guard rather than adding new ones. A local-mode context always uses the filesystem store. EP-146's first bootstrap transaction runs locally and moves with EP-151's migrate command. EP-156 runs its production-shaped rehearsal with the GCS store selected.

**Declaration versus native execution — owned by EP-146 for cloud/host/artifact, EP-147 for cluster, consumed by the EP-148 baseline and EP-152–160.** One provider operation may cover multiple declared resources. Pulumi native plans and TypeScript registration mapping remain authoritative for native semantics but must agree with validated membership. Kubernetes/Helm rendering is expanded and retained before mutation. Native plan/config/output changes require a new review, including bounded preparation when a provider cannot preview before a prerequisite exists.

**Shared cluster resources and data builders — owned by EP-147, consumed by the EP-148 baseline and EP-158–160.** Resource/Database.hs emits the entire database bundle, including credentials and backup operations, from the full typed Database value. Namespace/auth/shared configuration owners compose validated consumer contributions. Their effective desired resource digest is the digest of the composed content, so it changes when a contribution's content changes and not when a contributing scope is merely redeployed; neither case changes the owner's base scope revision or platform release. The contribution composers are pure and are dispatched from EP-144's composition phase, because contribution-made declarations such as a registered Namespace must exist before claims are validated. Owner authorization and complete contribution-vector checks prevent arbitrary app writes and lost updates. Credential refreshers and controller children have explicit bounded delegation.

**Lifecycle and observation semantics — owned by EP-149, consumed by EP-146–148 and EP-152–160.** Lifecycle.hs, Migration.hs, Status.hs, and Explain.hs own drift categories, adoption/transfer proofs, retained resources, incarnation-aware migration, and collection decisions. EP-149 validates proposals into LifecycleDecisions against the same CompositionCandidate the planner sees; it does not plan on its own, does not redefine RetirementIntent, and its proposals do not restate what a declaration already fixes. A stable ResourceId can have active/candidate/retained physical incarnations. Every deletion is bound to exact identity/history; restore/schema migration/write admission have explicit data recovery contracts. Existing Replacement/Cutover semantics remain specialized.

**CLI routing and compatibility — initial compile command owned by EP-144, generic command service by EP-145, domain registrations by EP-146–149, fresh platform bootstrap and legacy-upgrade confinement by EP-152; remaining command audit by EP-153.** app/Main.hs and justfile remain shared registration surfaces. Move behavior into named modules, coordinate registrations, and do not reintroduce separate orchestration in these files. Existing version/context/project/cluster guards remain until their authoritative replacements are proven. Preserve old receipts without converting unproven success into new proof. No admitted context may change platform payload version through the coarse upgrade runner.

**Coverage and tests — format owned by EP-146, contributions by EP-147/148 and EP-158–160, completeness owned by EP-153.** docs/architecture/managed-resource-coverage.md records each supported mutation family, owner scope, declaration compiler, executor, test evidence, delegation, and legacy disposition. A child running earlier may create the file using that format; later children preserve its entries. This is a traceability aid, not a second resource authority. Shared Cabal/Spec.hs/Nix test registrations must preserve each other's modules. Pure cases use existing Haskell tests; provider behavior retains focused integration checks.

**Release evidence — owned by EP-157, supplied by all earlier children.** Native tool identities, inventory/review digests, scope revisions, receipts, coverage status, and final observed state are archived under a payload identity and distinct run identity. Global release publication has a dedicated publication owner/context, not whichever deployment first consumes it. Published artifacts are references in consuming contexts. Private secrets/native bundles do not enter public evidence.

EP-157 maintains the already-implemented .github/workflows/release.yml publisher and Nagare.Inventory.Adapters.GitHubRelease. Its narrowly scoped durable publication record lives in the provider draft release: atomically bound intent/review, exact declared assets, a pre-publication verification receipt, and observed publication completion. Ephemeral Actions artifacts are not authoritative history. All authorized same-tag publishers share workflow serialization. This provider protocol does not expand the initial context store into a remote multi-writer service; ordinary context history stays in its private context-selected filesystem or GCS store.

These ownership, identity, review, storage, migration, and controller-delegation decisions belong in ADR 22 and relevant amendments. Each child updates durable decisions when implementation evidence changes them rather than leaving contradictory prose in separate plans.


## Progress

**Cloud operational acceptance.** A healthy newly booted cluster is only the first checkpoint. Before describing the selected cloud configuration as usable, EP-156 must demonstrate the existing supported day-two contract: a reviewed application/configuration change with owner isolation and unchanged replay; verified GCS backup and isolated restore of known data; interrupted-operation recovery without duplicate effects; credential and history recovery from a clean operator root; shared-writer refusal/takeover; and exact retirement/cleanup that preserves retained data and neighboring resources. EP-153 and EP-158–160 own missing command/feature implementations and are pulled forward when these checks need them. Record executable operator procedures, evidence and remaining restrictions against the candidate. Keep unproved procedures visibly unavailable rather than treating bootstrap success as maintainability.

Platform-version upgrades remain excluded for admitted contexts in MP-23; isolated restore also does not establish automatic application promotion/cutover. On 2026-09-30 the operator confirmed that upgrade work follows completion of the initial supported feature set and its safe-use acceptance. Finish the existing cloud/local operational and release gates before starting that next phase. This sequencing does not waive any current maintenance or recovery proof and does not authorize an in-place payload-version change now.

**Operator priority — cloud integration first (2026-09-29).** The operator urgently needs a cloud cluster that can be maintained safely after bootstrap. Prioritize EP-156's installed Compute Engine/NixOS/k3s/GCS convergence and recovery ahead of completing EP-155's local integration scenario. Pull EP-153 command repairs, EP-154 installed-package checks, and EP-158–160 features forward only as the selected cloud assertion needs them. Local focused regressions still prove a repair before native mutation; completing the local k3d/MinIO scenario is not a cloud prerequisite. Preserve existing local evidence and finish full local integration and both native-system gates before EP-157 release acceptance. This changes execution order, not supported scope, child completion, or the fresh-context/no-GKE boundary.

EP-156's [GCS scaling checkpoint](../audits/mp23-gcs-scale-proof.md) now proves
500-event and retained 61-event cold/warm no-op budgets on one repaired binary.
The local slow-response regression drove the worker scheduling fix; all 977 tests
pass and both benchmark prefixes are cleaned. Active append/finalization timing,
host recovery, independent verification and final-candidate gates remain open.

**Current direction — design reassessment, 2026-09-29.** [The reassessment](../audits/mp23-design-reassessment.md) replaces patch-by-patch orchestration repair as the implementation strategy. Retain typed ownership, native adapters, immutable review/history, and conditional storage. EP-153 owns one serial operation driver shared by apply/resume, total recovery outcomes, and immutable registry construction; EP-159 supplies the fixed two-operation consumer fixture. EP-156 now separates status/explain native reads from execution history and carries a validated provider head through append; command-wide cursor work remains bounded by measured active-command costs. The proposed evidence-index publication/rebuild rollout is no longer a mandatory prerequisite of historical recovery. E8/E9 remain prototype evidence, not an architectural obligation.

Seven children remain Complete and eight active. [The first production repair now passes](../audits/mp23-rescue-proof.md): one shared driver, the same saved public transaction through terminal/completed/interrupted/changed-source cases, zero provider mutations in the recorders, and 935 regression tests. This establishes the execution boundary; it does not finish immutable source selection, retained-source/receipt-only native cases, or command-cost gates. F09/F12/F13 remain Verifying for independent closure. The selected-read and append repairs now have [their own bounded proof](../audits/mp23-selected-read-proof.md). Continue active-command cost and the recorded host/native recovery prerequisites before feature expansion or long native rehearsals. No supported feature, release requirement, or old transaction is silently dropped. Earlier dated next-step instructions are superseded by this direction and the implementation table.

### Earlier accepted and partial evidence

2026-09-28 coordination snapshot: seven children are Complete; EP-148 and EP-150 remain Cancelled/superseded, and EP-161 is now Cancelled/deferred. Eight active children remain (EP-153–160). No additional child or milestone is declared complete by this scope decision. EP-160 M1 remains accepted. Recorded PostgreSQL/Redis/ClickHouse producer/receipt/scratch-restore proofs and local scheduled-prune experiments remain credited where their exact inputs apply. Final packages, complete supported coverage, local/GCP evidence, and immutable assembly are still open.

EP-153's first reduced-scope checkpoint now passes: new deferred CLI routes and saved-review admission refuse before effects, while original transaction recovery paths remain available. The audit registers the newer receipt/prune routes and emits the exact deferred/recovery set consumed by EP-157's evidence assembler; its injected-mutation and incomplete-coverage checks pass. This does not close EP-153 or EP-157. The next ordered checkpoint is reconciliation of EP-154's installed smoke, EP-155's local fixture health, and EP-157's evidence inputs before the EP-159/160 receipt-to-isolated-restore handoff. Current coverage still has ten pending routes, seven pending recipes, and 29 incomplete catalogue rows.

That bounded preparation now has a fresh installed Darwin smoke for committed revision `699ae909e5e0c01cce8be5000af382cbb6a566c8`; its report is `/tmp/nagare-mp23-installed-smoke-699ae909.json` and explicitly remains smoke-only. EP-155's recorded local platform/app/database and unchanged replay fixture is applicable as an earlier production-path checkpoint; it is not final-candidate evidence. EP-157's exact deferred-set evidence fixture passes. The next unmet supported producer/consumer assertion is EP-159's source/schedule-history and interrupted-upload handling through a saved receipt, followed by EP-160's source-preserving isolated restore checks. All active child milestones and final candidate gates remain open except EP-160 M1.

EP-159's public scheduled receipt listing on the retained Redis fixture now reports configured keep=7 and expiry as unenforced and states that backups are retained by default. Its review confirmation and inventory status report the same policy; full status could not be run on that older workspace with the changed payload, so matching-candidate status proof remains open. This is a bounded M2 reporting increment, while EP-159 M1 source/schedule-history and cloud receipt cases still need acceptance.

EP-159's read-only listing now requires current exact object and receipt evidence to match every accepted ingestion pin before reporting a run as accepted. A focused changed-pin test and the retained Redis public listing pass. Historical schedule revisions, interrupted uploads, cloud exact generations, and final candidate evidence remain open.

EP-160's retained local k3s fixture was reread under the revised isolated-restore contract. PostgreSQL, Redis, and ClickHouse source data remain distinguishable from earlier scratch destinations; Redis's source and scratch StatefulSets and PVCs also have distinct UIDs. A focused adapter test refuses a foreign Redis scratch UID before any provider write. Native destination-interruption recovery, M3 new-PVC proof, and final candidate integration remain open.

EP-159's scheduled producer fixture now demonstrates a create-only object surviving a failed readback without a receipt: retry refuses overwrite and cannot claim completion. A clean run after explicit orphan removal publishes the signed receipt. Public reviewed orphan resolution and historical schedule/source treatment are still open.

EP-154's exact-revision installed Darwin smoke passed again for `7f3e2eac22cf01e8555ca4cc9b6e29805d674e27`, covering the retention and listing changes in the installed payload. The report is `/tmp/nagare-mp23-installed-smoke-7f3e2eac.json` and remains smoke-only; both native-system and complete clone-free gates await a final candidate.

EP-159's accepted-run listing now falls back to immutable provider version and digest pins when a receipt belongs to an earlier reviewed schedule revision. A focused fixture accepts the exact old pair and rejects changed bytes or a foreign listed address; new unaccepted runs still require the current signed expectation. Native schedule replacement and restore, cloud generations, and final candidate evidence remain open.

EP-160's reviewed new-PVC adapter fixture now refuses a foreign scratch PVC that appears after preparation, with zero provider writes. Native archive content, destination UID, and interrupted extraction recovery still need the public saved-review path before M3 can close.

EP-160's public local k3s volume path now has an authenticated new-PVC roundtrip, safe resume after destination creation, and recovery after a lost completed-Job acknowledgement. A 192 MiB extraction fault then left a failed owned Job and a truncated scratch file; the exact `abandon-partial-volume-restore` decision closed only that unaccepted transaction, and a fresh restore ID converged into a different PVC with complete content while the source PVC stayed unchanged. The saved reviews, transactions, UIDs, and byte counts are recorded in EP-160. Its 920-test suite, executable build, style gate, and command audit pass. M3 remains open for full refusal cases and final candidate integration; EP-156 cloud proof and EP-157 release evidence remain separate.

EP-160 also proved native PostgreSQL partial scratch recovery on a 1,500,000-row backup. A test-only kill during the reviewed restore Job's bulk `COPY` left a distinct scratch database with an empty table while the source retained every row. `abandon-partial-database-restore` closed only that terminal failed two-operation review; a new restore ID converged into a separate scratch database with the full row count. The exact journal, Job UIDs, and source PVC identity are in EP-160. M2 remains open for Redis/ClickHouse interruption and final candidate integration.

The same terminal Job recovery action also handled a ClickHouse lost acknowledgement: its restore client died during a native `RESTORE DATABASE`, but the server finished the first scratch database. The failed review was abandoned without accepting those bytes; a fresh restore ID converged with 3,000,000 rows in a separate database, and the source kept its content and UIDs. The first Job's exact staged ZIP remains on the source PVC for separately reviewed cleanup. Redis interruption, a genuinely partial ClickHouse effect, orphan cleanup, and final candidate integration still keep EP-160 M2 open.

EP-156 began real `tan-ng-labs` preparation after GCP credentials refreshed. Its isolated `ep150-preview` foundation review contained only the dedicated state bucket and Pulumi stack. The first review exposed shared project APIs incorrectly claimed by the foundation inventory; the corrected compiler excludes enabled unowned APIs while verifying they remain available, and the public fresh/shared-project fixture passes. An ambient `labs` shell profile also contaminated an initial disposable review, so the fixture runner isolates its child environment. The foundation bucket and empty stack are now created, and its local history has migrated to GCS. Complete perimeter creation and cleanup reviews, DNS delegation, Compute Engine/NixOS/k3s, and second-state-root proof keep both EP-156 milestones open.

The current 27-create Pulumi preview then exposed a missing node service-account context field: its first version targeted the standing `nagare-node` despite distinct VM, buckets, domain, and registry. The profile and reviewed foundation seed now pin `--service-account-id nagare-ep150`; a regenerated isolated preview retains 27 creates and zero updates/deletes with that distinct account. At that checkpoint neither review had been applied. EP-156 records private digests and still needs a composed creation/cleanup boundary before the Compute Engine perimeter is created.

EP-156's two-operation foundation review created only the dedicated state bucket and empty GCS Pulumi stack. Stack initialization first failed ambiguously because a preview-only encryption salt had entered the disposable config; the original transaction was resumed after proving the stack absent and clearing that temporary salt. The completed local foundation history migrated to the new GCS inventory prefix. A source-workspace path in the stack's desired digest then caused a spurious follow-on update plan; the digest now excludes local execution paths and its one-time transition converged. Two separate Pulumi component-root saved plans returned ambiguous after creating only bookkeeping resources; exact export and same-transaction recovery proved completion. Pulumi plans bind a stack snapshot, so the cloud planner now groups new registrations for one scope into one saved plan. A fresh grouped review applied 22 disposable perimeter creates with no update/delete, and its no-change verification converged. The new child DNS zone's four exact name servers were added to the standing parent by a one-record NS delegation; the automatic SOA serial increment was the only other parent change. Image publication and the VM remain for later reviewed stages. EP-156 M1/M2 remain open.

A second isolated operator root read that GCS history without copying the first root's journal, exported the complete private store, and restored it into an empty local third root. The restored head exactly matched GCS generation 48 and digest `da1d593da4b12d3a8e631c694cae6815c662ab7cc8fce86969e314e315f8cadc`, with no active transaction. This proves portable history and the context/project binding at that checkpoint; active-writer conflict, takeover, and host recovery remain unproven. The isolated NixOS host flake and encrypted secret source are prepared, and its image-build review must be regenerated after a real disposable Tailscale key replaces the placeholder.

EP-160's Redis path now has a native destination-created interruption as well. The public saved review stopped after creating its scratch PVC and Service but before the StatefulSet write; fresh-process resume converged the same transaction, retained both original UIDs, loaded the signed RDB once, and completed the verifier Job. The scratch key retained its backup value while the source key had changed. Mid-load interruption, orphan cleanup, final candidate integration, and the other child gates remain open.

EP-160 now also has a public local new-PVC roundtrip in `/tmp/nagare-mp23-ep155-23001-6cpu-v2`: reviewed snapshot `tx-c92141447852dd87a3e31e79389c0bbb704036ea8c6d6748840237dc572ff72d` and restore `tx-9658c3601f9dc84120383df35e1c3bd36fb7d97dbde241617546f425993a14ff` converged. The scratch PVC has a distinct UID and contains the pre-change marker, while the original PVC retains the changed marker. Two native blockers were fixed: Knative omits default `readOnly: false`, and volume Job apply must load the exact accepted PVC/Secret/backup Job native bindings. Interruption recovery and final candidate/cloud proof remain open; M3 and the parent stay In Progress.

A second EP-160 restore review was interrupted after the new PVC was created and before its Job write. The journal kept the original transaction ambiguous; an unwrapped fresh-process `inventory resume` converged it against the same PVC UID and one completed Job. The recovered scratch file matches the saved backup and the source still has its later value. Interruptions during extraction and before verification, plus final candidate/cloud integration, remain M3 work.

EP-160's next local review lost the operator's read of an already completed restore Job. The journal retained the exact ambiguous operation; fresh-process resume proved the same completed Job and scratch PVC without a second extraction, and content readback again matched the backup while the source stayed changed. Interruption during extraction and final candidate/cloud integration remain open, so M3 is still unchecked.

EP-154's complete clone-free rehearsal passed on installed `aarch64-darwin` for committed revision `ba2161606275c3c0585e5a20bb76a7fbd4207f30`; `/tmp/nagare-mp23-clone-free-ba216160.json` reports the upgrade dry run planned with one preview and no apply. Negative package checks, native Linux, and final candidate gates remain open.

EP-154's two installed negative package checks now pass on `aarch64-darwin` from exact revision `c7fdb132a22e62b853f666a57714c8ff93553215`. The clone-free platform fixture excludes packaged secrets, resolves context-owned secret paths, refuses an invalid explicit payload root, and checks guarded reviewed recipes. The external typed-config fixture loads a valid config outside the checkout and refuses both an invalid config and construction of a private DSL type. The invalid-root check exposed and fixed an installed wrapper that had overwritten caller intent. M1 still needs the complete supported command payload matrix; M2 still needs native Linux and final-candidate evidence.

The full clone-free Darwin rehearsal also passed on that exact committed revision. `/tmp/nagare-mp23-clone-free-c7fdb132.json` reports `cloneFree: true`, all ten installed checks, and a planned platform upgrade with one preview and no apply. The retained local Redis receipt listing still reports nine accepted and four pruned runs, but its source scope has not been replaced; it is not native historical-schedule evidence. EP-159's historical producer/consumer case remains open.

EP-159's accepted listing now recognizes an older object format by the accepted exact object/receipt addresses, while keeping an unexpected second current-format key unresolved. The focused inspection test, executable build, style check, and unchanged local Redis listing pass at `b7019335e71773dc2e66a7a298974fe50966962e`. Historical unaccepted ingestion, native schedule replacement plus restore, interrupted-upload resolution, and cloud exact generations remain open.

**Implementation order.** Check current child evidence before rerunning a checkpoint. Preserve concurrent work and already-admitted recovery records. The registry states whole-child ownership, not numerical execution order.

| Order | Work and owner | Required handoff |
|---|---|---|
| 0a — replace operation dispatch | EP-153 M2 single serial driver + immutable registry; EP-159 M2 existing two-operation prune fixture | Apply/resume share dependency-ready dispatch; all recovery outcomes are explicit; historical identity and conditional effects remain protected. Remove the duplicate live-preflight route. Preserve deferred-admission guards and explicit recovery. |
| 0b — separate resource reads | EP-153 M2 target selection + EP-156 M2 selected observation evidence; no mandatory new index prerequisite for old recovery | Unknown target needs no workspace/native/provider initialization; fixed selected state costs no additional evidence reads when unrelated reviews grow from 0 to 500; selected corrupt evidence still refuses. |
| 0c — append boundary | EP-156 M2 complete append protocol | Measure full append and public resume; remove duplicate head discovery with generation-bound compare-and-swap, preserve race/lost-ack/takeover behavior, then satisfy the existing real GCS latency gate. |
| 1 — accepted | EP-160 M1 shared fence | Retain accepted proof and recovery interfaces; do not reopen this milestone for deferred consumers. |
| 2 — cloud prerequisites | EP-153 affected registrations/guards; EP-154 installed cloud-command checks; EP-157 existing evidence schema | Reconcile accepted repairs and affected findings. Complete only the package/command checks needed for the next cloud assertion; full EP-155 acceptance is not a prerequisite. |
| 3 — cloud platform convergence | EP-156 M1/M2 installed fresh-root recovery → reviewed cluster apply/convergence | Use a never-used root without copied history, preserve accepted prerequisites, and reach healthy cloud platform services through the installed operator. Keep existing timing and identity guards. |
| 4 — cloud application and recovery | EP-156 real application/database, app-only isolation, unchanged replay, GCS receipt → isolated restore, interruption and second-root recovery; EP-153/158–160 supply needed bindings | First prove one representative cloud application/data path, then the cloud operational acceptance checks above, with verified content and preserved sources. Then expand to remaining supported cloud assertions, engines/volumes, writer conflict/takeover and exact cleanup. Report this checkpoint separately from full child/release acceptance. |
| 5 — remaining supported work and local integration | Remaining EP-153/158–160 obligations; EP-155 full local scenario and retained PostgreSQL rename/collection | Finish the full supported matrix and local k3d/MinIO evidence after cloud integration. Pull a shared binding forward when order 3 or 4 needs it; add no engine or generic lifecycle framework. |
| 6 — final candidate | EP-154 every native system; EP-155 local; EP-156 actual Compute Engine/NixOS/k3s/GCS; EP-157 non-publishing assembly | Same candidate, complete supported coverage plus guarded exclusions, all required native assertions. Reuse applicable evidence only with exact input bindings. Full local and cloud acceptance remain required. No GKE. |

EP-157's evidence inputs grow with cloud work. EP-155 retains existing evidence and receives shared fixes, but broad local scenario expansion follows cloud integration. External-tool evaluation is not a prerequisite. Final native proof may be reused only when recorded inputs and assertions remain applicable; relevant implementation changes invalidate affected proof. A documentation-only scope edit does not itself invalidate unchanged native behavior, but final manifests must identify the final candidate and support contract.

**Historical replay blocker (later scaling evidence above supersedes the timings).** The 2026-09-28 disposable GCS run exposed a multi-minute journal replay at only 54 events, including repeated per-object `gcloud` subprocess reads. Treat this as a release blocker owned by EP-156, with the cold/warm 50/500-event timing, remote-command-count, integrity, and same-transaction recovery checks specified there. A functional convergence receipt alone does not close the GCS acceptance gate.

The first bulk-read candidate did converge the retained host transaction, but its full `inventory resume` still took 382.16 seconds at 61 events. That candidate remained blocked on end-to-end latency, including repeated history/object-store calls, workspace initialization, and host IAP probes; use the later accepted measurements and current remaining command/provider checks when selecting work. Recheck physical identity and reviewed old closure at effect time. Record separate warm and second-root timings before claiming operational acceptance; do not use the convergence receipt as a substitute.

**Focused regression proof before affected cloud mutation.** This is the command-boundary safety check, not a requirement to complete EP-155 local integration. Orders 0a–0c supersede the earlier advice to rerun general replay suites and then try the cloud again. Reuse the five passing replay checks while their inputs remain unchanged. First prove the failing command boundaries with isolated recording providers, including the actual F09 CLI route. The source probes and head-snapshot counterfactual in the experiment report are diagnostic evidence, not production acceptance. Only after those repairs and existing F05/F07 host checks pass, freeze the candidate and use EP-156's original cold/warm and second-root GCS limits. A failed local assertion returns to its owning repair; it cannot be deferred to a long integration run. Retain the existing 41.04-second measurement as historical failed evidence, not as a command to replay unchanged.

**Finite remaining outcomes.** EP-159 must finish scheduled receipts, source/schedule history, interrupted uploads, and GCS binding, while making deferred scheduled retention explicit. EP-160 must close all three isolated engine restores and new-PVC recovery. EP-153 must close existing platform/consumer gaps and prevent new deferred operations at all entrypoints. EP-154–157 retain their complete package/local/cloud/evidence obligations for that supported set. EP-158 is unchanged. Recovery of pre-existing partial prunes, fences, and sessions cannot be removed or relabelled successful.

Earlier hour ranges are uncalibrated historical estimates, not a forecast for this revised scope. Report the selected assertion, last newly passing production-path check, and next concrete blocker. Before adding helpers, connect compile → saved review → native execution → verification/recovery in the corresponding fixture. Apply the timed execution-control procedure at the implementation entrypoint whenever progress stalls. Findings must map to a supported assertion, a missing binding, or an explicit new scope proposal; do not turn missing evidence into an exclusion. No new provider, generalized security framework, or child plan enters implicitly.

Historical implementation findings below describe the contract in force at their date. Their former live-restore, maintenance, and scheduled-prune completion requirements are superseded by the 2026-09-28 decision; their observations and recovery records remain evidence.

## Surprises & Discoveries

2026-09-30: The installed cloud apply exposed an undeclared readiness edge: activator waits for the autoscaler websocket while the serial executor waits for activator before creating autoscaler. F14 records the native failure. Add the edge to future typed Serving declarations and preserve the old immutable review through narrowly guarded readiness continuation; never manufacture a completion proof or reset history.

**2026-09-27 — Installed local producer exposed consumer bindings.** EP-154's first installed rehearsal stopped at an obsolete unqualified `deploy --dry-run` fixture, so its bounded smoke now uses the read-only inventory compiler and cannot count as full release evidence. EP-155's first `local-up` found EP-153's wrapper passing an existing directory to review publication; after that fix, a real k3d 5.9 registry create became ambiguous because the artifact observer did not recognize `portMappings["5000/tcp"]`. The next exact candidate advanced through registry observation and created a cluster, then found that k3d's JSON omits the custom digest label present on the exact Docker server container. Both source observations now match the native provider shapes and the focused public test passes. The two old immutable candidates remain deliberately unaccepted test runs; EP-153, EP-154, and EP-155 still need fresh final-candidate proof. No feature requirement changed.

EP-155's third candidate converged its local registry/cluster and context kubeconfig, then exposed the existing encrypted observability Secret and immutable auth image fixture inputs. After those were supplied, host `skopeo` reached macOS AirTunes instead of the fixed k3d registry on port 5000. A native loopback forward into Colima preserved the reviewed controller manifest where Docker load/push did not. The local registry observer and health probe now read the exact registry container, and the saved-review runner binds Nagare's profile name separately from the k3d Kubernetes context. A changed installed candidate correctly refused to reuse the earlier accepted substrate; the next native attempt needs fresh isolated state. No EP-155 milestone or final package gate is credited by these partial results.

The next installed candidate converged a fresh registry, cluster, and context kubeconfig, then advanced the 209-operation cluster review through a retained CRD acknowledgement to MinIO Deployment readiness. The exact MinIO pod is `ImagePullBackOff`: the pinned Quay digest returns 401, as does the checked legacy client image. Upstream release tags exist, but the tested legacy image registries refuse access and the binary download endpoint returns 410. EP-155 retains the ambiguous transaction and needs a reproducible source/image route before local health and the first application/data assertion can pass. The local runner now compares its `local` kubeconfig endpoint and CA to physical `k3d-nagare-local` and binds both names in saved evidence. No new provider or acceptance gate was added; no EP-155 milestone is complete.

EP-155 now has a bounded local replacement route: a script verifies upstream GitHub release asset SHA-256 values for MinIO server/client Linux binaries, builds disposable local images, and observes their exact k3d registry digests. A Docker-network readiness and bucket-creation probe passed, and the component compiler binds only paired exact local image overrides into a fresh review. The old ambiguous transaction remains untouched; the next native attempt must use a new installed candidate and isolated state. EP-159's first producer correction also binds reviewed scheduled backup keys to the Job UID and uses conditional create-only upload; its backup test group passed. Neither child milestone is complete.

The next installed local candidate completed registry, cluster, context kubeconfig, and the 209-operation platform review. Its reviewed MinIO server, bucket Job, and Knative webhook passed readiness. The first application image archive review then stopped ambiguously with the exact registry tag absent: generic OCI publication still addressed macOS AirTunes on port 5000. The source transport now validates the same loopback forward used by the controller publisher and observes the logical registry digest after publication. The old image journal remains retained. EP-155's first application/database and unchanged-replay assertions still require a fresh installed candidate; M1/M2 remain open.

Installed revision `453eebc24a6ddfcea3df90019a4f949d888887b1` then converged a fresh local platform and the reviewed application image publication at the exact source manifest digest. The typed app dry run exposed a real cluster-identity mismatch in accepted foundation Namespace lookup; bootstrap uses `platform:cluster/cluster/cluster`, while the app resolver assumed the foundation scope. The resolver and focused test are corrected. EP-155 must repeat from a new installed candidate and isolated target to prove application/database convergence and unchanged replay; no M1/M2 credit is taken from the platform/image-only result.

Installed revision `23001da4` converged a new six-CPU local platform, an exact reviewed application image, and two independently owned Knative apps with ready retained PostgreSQL StatefulSets. This used an isolated Colima profile because the default four-GiB VM could not schedule the first app; the earlier failed journals remain retained. The corrected disposable HTTP image was run successfully before publication. An unchanged app A replan then exposed a release-history timestamp rewrite despite identical accepted tag and metadata. The compiler now preserves that accepted release record, and its focused native-byte regression passes. EP-155 still needs its full checked-in scenario, so M1/M2 remain open. Continue the ordered EP-159 producer/EP-160 restore/EP-161 maintenance handoff after the bounded first-path check.

Installed revision `e97d65e1` then read-only replanned both accepted app scopes in that six-CPU fixture. Each saved review had seven VerifyResource operations, no writes, and no barriers; both live Knative Services retained their UID, generation, and Ready revision. This finishes the bounded first-path check and permits the ordered EP-159 producer, EP-160 restore, and EP-161 maintenance handoff. EP-155's full checked-in recovery scenario and both milestones remain open.

EP-159's first native PostgreSQL producer probe triggered a disposable Job from the accepted schedule template. Its UID-keyed backup object had an exact MinIO version and remained at the same version after Job cleanup. The test proves upload/readback and object survival, but no delegated receipt or public ingestion exists yet; EP-159 M1 and the EP-160 restore consumer remain open.

EP-159's reviewed schedule renderer now produces a version-2 UID/object/checksum receipt after stored-byte verification and create-only upload, leaving manual receipts unchanged. A direct shell test proves receipt bytes, readback, termination evidence, and duplicate refusal. The receipt is still untrusted producer output until source incarnation/delegation attestation and reviewed public ingestion exist; M1/M2 remain open.

Installed revision `70bab28c` applied a reviewed update to app B's backup CronJob as the only write in its app review. A disposable Job from that template produced a version-2 receipt whose UID, object address, and SHA-256 matched the live MinIO backup. Both object and receipt retained their exact version IDs and bytes after Job deletion. This closes the bounded producer and cleanup probe, while schedule-controller firing, trusted receipt ingestion, restore, and retention pruning remain open under EP-159/160.

EP-159's next reviewed update added a schedule-specific ServiceAccount, name-scoped source-read Role and binding, and a version-3 receipt carrying the StatefulSet/PVC UIDs observed before and after the dump. The local RBAC probe allowed app B's exact resources and denied app A's. A first native Job left a UID-keyed backup object without a receipt when the upload image lacked `cmp`; the code now uses SHA-256 for the second source check and leaves that orphan as interrupted-upload evidence. A corrected Job produced a source-bound receipt and stored-byte checksum that stayed at the same exact MinIO versions after Job deletion. This advances the producer proof but does not authenticate a receipt against accepted schedule/source revisions or ingest it into inventory; EP-159 M1/M2 and EP-160 M2 remain open.

The next local review created a retained signing Secret and updated app B's schedule to produce version-4 HMAC receipts containing a schedule-template revision. A completed Job's stored receipt matched its termination copy and accepted CronJob metadata, and its HMAC verified against the private Secret. The exact backup/receipt MinIO versions and backup checksum survived Job deletion. EP-159 still needs reviewed ingestion and provider-version binding before this producer evidence can become accepted history; restore and retention consumers remain open.

The first ingestion guard now derives the object key space, format, signing reference, and receipt metadata digest from accepted native CronJob bytes. A separate read-only SigV4 fetch proved both exact MinIO versions and stored bytes remain available after Job cleanup. This prepares the reviewed ingestion path but leaves EP-159 M1/M2, EP-160's scheduled restore consumer, and EP-161's maintenance handoff open.

The Haskell candidate reader now reproduces that post-cleanup check: exact MinIO version IDs, lengths, stored-byte digest, HMAC, and accepted source/schedule metadata all match. It refuses the retained object-without-receipt orphan and a wrong signing key; the focused backup tests cover exact-version byte changes. A public reviewed ingestion operation and accepted history record are still required before restore or pruning may use this evidence.

The first public `db backup-receipts` review then accepted that PostgreSQL receipt into an independent scope after a verification Job reread the fixed MinIO versions and HMAC. The producer Job was already gone. A missing-receipt orphan refused review; an unchanged replan and apply retained the ingestion Job UID without another run after canonical ordering was fixed. This closes the representative local ingestion step, while EP-160's real scheduled restore/content consumer, EP-161's maintenance handoff, provider-unresolved listing, historical schedule handling, cloud exact-generation reads, other engines, and EP-159 retention pruning remain open.

EP-160 then selected that accepted receipt in a public reviewed scratch restore. The Job downloaded both fixed MinIO versions, verified their returned IDs and hashes, and restored app B's PostgreSQL `mp23_fixture` row `(1, scheduled-v2)` into a scratch database. This completes order 3's scheduled PostgreSQL producer → ingestion → real restore/content handoff. EP-161's first maintenance session is next; the broader engine, live-target, cloud, pruning, and release obligations remain open.

The public read-only scheduled receipt listing now observes the current MinIO prefix completely and reports accepted, verified pending, and unresolved entries. It exposed the retained receipt-missing upload and two old invalid envelopes alongside the accepted v4 run. Provider listing refuses truncated or malformed results; historical schedule revisions and cloud listing remain open. EP-161 still needs an operation-specific access policy because EP-160's proven offline fence stops the database engine and removes its Service endpoints.

EP-159's local Redis retention boundary now has ten accepted signed runs. Two older runs remain protected by accepted scratch restores, while one eligible run was selected for exact pruning. Its immutable Job failed after deleting the data version and before deleting the receipt; the published failed transaction was explicitly abandoned without asserting cleanup. A separate reviewed receipt-only recovery, pinned to that original failure and a complete MinIO version listing, converged as `tx-fe23f9c1dcd27d57da258f749603a8704160b242ec9ed52f6fc9ed61a7fcf4c4`. Public listing shows the run pruned and nine others accepted; the retention selector finds no next candidate. EP-159 M2 still requires apply-time provider/in-flight revalidation, an ordinary successful eligible prune, and cloud exact-generation evidence. The other children and final native/package gates remain open.

Two more signed local Redis runs supplied eligible ordinary prune candidates. Public ingestion and separate one-run reviews converged both deletions while preserving the two older restore-referenced runs and their provider objects. The second apply reobserved the accepted CronJob, checked for unfinished producer Jobs, compared the complete current-key listing with all accepted unpruned pairs, and required exactly the selected object and receipt versions with no hidden versions or markers. Three runs now list as pruned, nine as accepted, and no further candidate is outside keep=7; the local inventory head is converged at generation 1291. EP-159 still needs negative apply-preflight fixtures, historical schedule treatment, and cloud exact-generation evidence before M2 can close.

An isolated EP-161 k3s probe proved a candidate access primitive: a deny-ingress NetworkPolicy blocked a second PostgreSQL Pod while the selected server Pod's Unix socket remained usable. A checked-in disposable probe reproduces this assertion. The session still lacks a reviewed interactive operation, accepted writer/Pod binding, durable client identity, and parent-death recovery; the network result alone does not advance its milestones.

The inherited PostgreSQL consumer control passed in the same fixture: a known row was backed up through the installed public manual command, restored to a reviewed scratch database, and read back exactly. This establishes the existing receipt/restore baseline; EP-160 M2 still requires scheduled-receipt consumption and fenced live restore for every supported engine.

EP-157's early index now requires one local and one cloud projected inventory run, their exact target/health identities, complete command coverage, and native output plus clone-free rehearsal for every system in `release.json`, all bound to one release revision. Representative missing/stale/secret-canary tests pass. This is the prescribed early schema handoff; assembly and publication remain ungated until the final matching evidence is available. The current full clone-free runner still lacks EP-154's typed-config check and is intentionally rejected by the new index.

**2026-09-27 — Execution-log diagnosis and why the previous audit failed.** The original September 16 EP-148 at `686a39d8` already required almost all application/data commands, write-fenced restore, maintenance, publication, and legacy-path removal in four milestones. Most remaining functionality was hidden original scope. The September 26 split (`9b36e3a4`, `dd231541`) improved ownership but did not resolve the native recovery algorithms or make the remaining integration small. The implementation sessions repeatedly stopped after small commits despite explicit instructions to finish. The log confirms this behavior directly; it cannot be explained solely by waiting for approval.

The local Codex sessions below were inspected as evidence, including user instructions, assistant replies, tool requests, and model turn metadata. Times are UTC; IDs identify the local session records without copying private transcripts into the repository.

| Session / evidence | Finding |
|---|---|
| `01a0d440-c553-7393-b5c8-52e5d2150b59`, September 24 16:45 and 20:09–20:10 | The agent explicitly said it was not blocked and had treated a passing suite/commit as a stopping point. It acknowledged adding partial checklist items behind the 93% display. |
| `01a0d583-5351-7bb2-800d-39aac12aec78`, September 25 03:43 and 05:19 | The user reported 200/208 and 96%; the agent later acknowledged unfounded estimates. Completed microtasks and large remaining outcomes were being counted as equivalent. |
| `01a0df57-0d3c-73f1-aed2-245795205bf0`, September 26 20:17–23:23 | The previous audit identified oversized scope, underspecified protocols, repeated validation, and drift. It split the plans and verified EP-153 M1, but the parent registry/forecast later remained stale. The audit itself temporarily broke displayed child progress through a heading change. |
| `01a0e0fa-0b48-74f0-985e-169156d11a44`, September 27 04:31–12:44 | M1 estimates changed from 8–16 to 12–24 more hours and repeated while production wiring stayed unfinished. GKE was introduced as a blocker despite being absent from the original plan. Tool-request text contains 178 occurrences of `cabal test`, 56 of `cabal build`, and 64 of the style script, with 11 compactions. These are request occurrences, including retries, not successful runs or measured test time. |

The last session's native probes did expose real defects: guard release could reopen access early, Deployment release needed the correct ReplicaSet, and admission controls interfered with Job draining. Fixing those defects was required. Treating unrelated GKE availability or full later restore semantics as an M1 prerequisite was scope drift. The prior audit failed to stop the cycle because it primarily reorganized descriptions; a production-path acceptance fixture still did not drive implementation, the shared provider handoff remained underspecified, and completed component probes were followed by further component work while the usable path remained absent. The active EP-160 session is now implementing that missing path; this update does not rewrite its file or implementation.

**2026-09-27 — Complete 24-hour change inventory.** The fixed review window is September 26 13:34:17 UTC through September 27 13:34:17 UTC, ending at `f79329f0`; its base is `0d49ea7a`. Every commit and changed-file inventory in that range was inspected, with deeper diff inspection of shared interfaces, recovery ordering, backup/restore consumers, and integration. This is a workflow/change-accounting review, not a correctness certification of every changed line. Concurrent uncommitted EP-160 work and this plan edit are excluded from the counts.

| Chronological commit range (inclusive) | Commits | Substantive work / observed outcome |
|---|---:|---|
| `be09ac0f`–`dd231541` | 31 | Manual backups/checksum receipts/scratch restore/pruning; reviewed application and webhook cutover; volume snapshots/scratch restore; Build inputs/Dockerfile publication; plan splits. Delivered behavior, with remaining variants and integrated acceptance open. |
| `914b0e9b`–`491657ed` | 5 | Finite command audit, reviewed hello and smoke consumers. EP-153 M1 accepted; M2 open. |
| `cd76908f`–`0f2e784c` | 27 | Reviewed fresh foundation, cloud/local stages, kubeconfig, stable marker, and recovery fixtures. EP-152 accepted within its boundary. |
| `41f910e4`–`f79329f0` | 58 | Shared/native data fence, component probes, corrective recovery/authority work, and removal of the invented GKE gate. EP-160 M1 still open at the endpoint. |

Together these are 121 commits across 158 files, with a net diff of 22,967 inserted and 4,041 deleted lines. This was substantial implementation, not a few tiny changes taking a day. Line/commit counts do not establish usefulness or acceptable elapsed time. The concentration of unfinished fence work is the concern: its plan changed in 54 of those 58 commits; native intent changed in 16 commits and exclusion in 15. The sequence corrected transaction/fence ownership (`8001250d`), replay admission (`60c80d1a`), premature remount/release (`f2d6dc82`, `7035271b`), saved-intent replay (`cd1a3f23`), and finally IO planning capture (`d03df8f7`). Saved immutable replay and live observation were known requirements; integrating them late caused avoidable interface rework. Real provider bugs still required fixes.

The fence session from 03:59 to 12:59 UTC contains 2,451 tool requests. A reproducible text classification finds 515 poll/wait requests, 514 edit requests, and 469 read/search requests. Summed recorded tool request-to-response spans are about 187 minutes, about 102 of them in poll/wait requests. Classification is approximate and background processes can overlap model activity; these figures are neither CPU time nor a complete wall-time attribution. They do not support blaming the entire nine-hour span on compilation. The only asynchronous access question in that session concerned the invented GKE probe; execution continued afterward. Repeated model/tool cycles, component-by-component design, and context reconstruction are material contributors; the logs cannot yield a defensible exact number of wasted hours.

The ordering inspection found another concrete coupling: `compileManualRestoreScope` currently expects an accepted backup scope containing one Job; scheduled receipts after Job cleanup need an explicit compatible consumer path. The verified restore renderer supports PostgreSQL and exits for other engines. The legacy Redis scratch path only prints guidance, while the legacy ClickHouse path creates a database without restoring the data stream. Therefore do not mass-produce three-engine receipt infrastructure under the assumption that all restore consumers already work. Prove producer/consumer compatibility per engine, and exercise maintenance's shared handoff before completing every restore variant. These are existing unfinished requirements, not new feature scope.

**A concrete design gap remains at the next handoff.** `DataFence/KubernetesExclusion.hs` shuts down the database, scales its StatefulSet to zero, and requires no PVC consumers and no Service endpoints. EP-161 requires a running engine reachable by one authorized interactive client. Likewise, the inherited logical restore renderer takes a Service host. These consumers cannot simply wrap that offline exclusion callback and assume they work. Reuse the durable DataFence state machine and store, but distinguish acquisition of exclusive data access from admission/observation of the selected recovery or maintenance process. EP-160 M2 owns engine-specific restore execution; EP-161 owns maintenance process admission. Their respective content/client proofs establish these policies; neither becomes a new EP-160 M1 gate. ADR 22 records the boundary.

EP-161's first public PostgreSQL maintenance checkpoint now uses the accepted `mp23-pg-a` database and manual recovery backup in the isolated local fixture. `db shell --session-id mp23-maint-1 --recovery-backup mp23-a-seed-1 --save-plan` issued review `460beebfb1fe10e8b22bbaf412f8e8d94e1e6259118666de7256acb728916997` with an exact online DataFence. The reviewed terminal ran a read-only SQL probe returning `mp23_pg_a | 1`; journal sequence 606 recorded completion, the policy and fence were removed, and `inventory resume --yes` converged the transaction. The run also exercised explicit recovery from an unreserved fence-start failure and continuation of a durable `acquiring` fence. That initial shell checkpoint alone did not close EP-161 M1/M2. No GKE path was introduced.

EP-161 then exercised the same public path under process death and nonzero exit. Review `94cf3840e719a84d206c13a16c721b609389b70cde82af33cd6c4a490b1573f8` retained a `changing` fence while a marked remote PostgreSQL client survived its killed operator; ordinary resume refused, and explicit recovery terminated the remote client before journal completion at sequence 612 and convergence. Review `8dae4328596621c254ae9d619320f47b4a4cfdd11832bb7a6ff8ead016a1be60` committed a known row, recorded terminal exit 143 and an `unresolved` fence at sequence 618, then explicitly recovered at sequence 619; the row survived release and the transaction converged. These are local PostgreSQL producer/consumer checkpoints, not full EP-161 acceptance. At this checkpoint, independent terminal loss, remaining engines and exec/migration routes, concurrency and replacement refusal, and the later MasterPlan gates were still open.

The next EP-161 local fixture saved review `f85efb1af0cab4a9161c9e8fc0e0ba5f7b8be7bac2682e43b5d224494f1ec263` and kept its PostgreSQL terminal active while a second reviewed shell refused on both `active-transaction` and `active-data-fence`. A separate PostgreSQL Pod received no Service response, while the admitted client returned `SELECT 1`; public status named the `changing` session. Normal exit converged the transaction and removed the policy. A second saved review, `28d96882061d513162a22853f59d98ce62253a501cc6b5b66b78cdda305f5aed`, pinned Pod UID `c544f72c-6492-4cc9-92b9-9c551129e312`; after a disposable Pod replacement gave UID `654cbd9c-c343-400b-8b40-a3d92fd03c66`, apply refused before an effect and left no fence or transaction. At this checkpoint, remaining PostgreSQL routes, credential drift, independent terminal loss, other engines, and all later gates were still open.

EP-161 next proved independent terminal transport loss on candidate `5348d9e0`: review `0f4965d99d6bcdb7e03588892efdbe8d03706af911081759b031ff8db771203e` kept the operator alive while its `kubectl exec` child received HUP during `pg_sleep`. The marked PostgreSQL backend survived; journal sequence 631 recorded ambiguous exit 1, and ordinary resume refused the `unresolved` fence. Exact reviewed recovery terminated and observed the remote client, completed at sequence 632, and resume converged at sequence 633. The network policy and fence were removed. EP-161 still needs its other engines, credential and remaining route proofs; EP-159/160 and final acceptance remain open.

Order 4's second PostgreSQL producer/consumer run then triggered an independent Job from the accepted app B CronJob. Job UID `59b73fe4-6989-43c9-8ecc-b5ea066b67df` was deleted before reviewed receipt ingestion `b69762444690eac36c84425b4130e38e1d4ebe48bd81f2a7815ce6b6f477f8bc`. Public listing shows it and the first v4 receipt accepted separately while older incomplete runs remain unresolved. Review `1f11890a1bdf47848aac186b11921778da34d67648aaffb8304473cd9bcb3857` consumed the new exact MinIO versions in a second scratch restore and read back `1|scheduled-v2`. EP-159's automatic schedule, retention, historical and cloud cases, EP-160's live/other-engine/volume cases, and EP-161's remaining engine/route cases stay open.

Order 4's Redis checkpoint used an accepted standalone `redis:8` source in the same local k3s fixture. A scheduled Job with UID `f33bdc7d-3b46-4cf8-8f17-1b7ec425ec05` was deleted before signed receipt ingestion `b0547392810523a92a3290e81257974484312387a4430fd35d915a6d4f979b62`; the public listing retained the accepted `.rdb.gz` object and exact versions. EP-160 review `81774dfb8662eeb08dc9ebcd5c8f1929bc1e87f264fdc817583b3b64e226d8ef` then loaded that RDB into a separate PVC-backed scratch StatefulSet and completed a verification Job. The scratch key returned `redis-scheduled-v1` while the changed live source returned `redis-source-after-backup`. Its StatefulSet carries source UID pins checked before the init load; a changed-UID adapter test refuses. An earlier scratch review exercised explicit adapter recovery for Kubernetes-omitted null/empty pod fields, then survived Pod replacement from its retained PVC. Canonically ordered declarations made the corrected review replay converge without replacing the verifier Job. The 905-test suite, build, and style gate passed. This advances Redis scratch producer/consumer compatibility, not Redis live restore or maintenance; ClickHouse, volume restore, scheduled pruning, and the later final acceptance gates remain open.

Order 4's ClickHouse checkpoint on revision `06c2e3e9` replaced the table-identity-free Native stream with a database backup ZIP. The isolated ClickHouse 25.8 format probe restored its original row after source change and was removed. In the retained local k3s fixture, accepted `mp23-clickhouse` produced a reviewed manual ZIP backup and a signed scheduled backup Job UID `d3bdb23c-ca7f-4779-a712-4364aeebcc49`. The Job was deleted before receipt ingestion `dac9191042487a479928f179cc8ec5e4c199849af3b72168fa6cc08908168bbe` pinned the exact `.zip.gz` object and receipt versions. EP-160 review `03784f231b665632fa17ce7d76039eb924fdef6c8826134f66d37be7b5b2e592` restored the accepted archive into `mp23-clickhouse_restore_zipone`: the live source had two rows, while scratch retained only `(1, clickhouse-zip-v1)`. Replay verified the same completed restore Job UID without another data operation. The 907-test suite, executable build, style gate, and strict user-doc validation passed. The three engines now have local scheduled producer/receipt/scratch-content evidence. Engine-specific fenced live restore/recovery and maintenance, scheduled pruning, EP-160 M3 volume recovery, cloud integration, and final release gates remain open; no child milestone is closed by these partial engine proofs.

Order 4's Redis maintenance checkpoint on candidate `98d00da9` reused the accepted `mp23-redis` source and its exact reviewed fence controls. A completed manual recovery backup, Job UID `38464e5a-31c6-4d8b-9942-b6027e78d142`, preceded the session. Review `57a99ef6d4745c0b7e4d0b28345b1933d8f265016b909f60a69fa18fe09efba0` opened a pinned `redis-cli`, wrote and read `mp23:maintenance=redis-reviewed-v1`, and converged on normal exit with no policy or fence left active. A second review `d9cb7f4f4d4e8b007f8556cfb0738441ebfc70e076b10cd611126c5790016e36` wrote `mp23:maintenance-loss=redis-loss-v1`; loss of only the local terminal left its named remote client alive and the transaction ambiguous. Ordinary resume refused `active-data-fence`; exact `verify-fenced-effect` recovery terminated the marked Redis process, re-observed client drain, released the fence, and converged on reviewed resume. The key persisted, the policy disappeared, and the backup schedule was unsuspended. This extends EP-161's usable session and lost-terminal recovery to Redis without closing its remaining modes, ClickHouse, or the live-target restore and release gates.

Order 4's ClickHouse maintenance checkpoint used the accepted local 25.8 source, completed manual backup `zipone`, and completed scratch-restore Job. Those Jobs retain terminal Pods naming the source PVC, so the shared fence now pins their UIDs and specs and admits only their exact terminal Pod identities alongside the running ClickHouse Pod. Review `e9eb48fb34c1c9fc4b1254efea06c1ee2e5b5d10f46d53b0eeb77cb4c37a95c4` initially stopped at ambiguous acquisition when the volume observer reported those historical consumers. Exact reviewed continuation opened the ClickHouse terminal after the consumer check was corrected; it wrote and read `(230161, clickhouse-maintenance-reviewed-v1)` and converged with no fence left active. A second review `81687470c44b6c975e3ded0ab7141e2434e2df14caff86334d21d13059198ce5` wrote `(230162, clickhouse-maintenance-loss-v1)` before only its local `kubectl exec` child was lost. The marked remote client survived, ordinary resume refused `active-data-fence`, and exact `verify-fenced-effect` recovery terminated it, released the fence, and converged. Both rows persisted; the backup schedule was unsuspended. The 908-test suite, build, style gate, and strict user-documentation validation passed. All three engines now have local normal and terminal-loss maintenance evidence, but EP-161's remaining recovery modes, exec/migration entrypoints and conflict checks, EP-160 live restore/volume cases, pruning, cloud integration, and final release gates remain open.

The next EP-160 M2 procedure probe used a separate PostgreSQL database on the accepted local `mp23-pg-b-0` server. A transactional schema reset plus the saved plain dump restored the known row and, after restoring the default `public` schema metadata, produced a normalized `pg_dump` identical to the source. Injecting a SQL error at the end rolled back the reset and preserved the changed row. The disposable probe database was removed. This verifies the candidate PostgreSQL effect and content comparison only; reviewed source/recovery binding, exclusive writer fence, durable unknown-outcome handling, and all public `--into-live` variants remain open.

EP-160 M2 now also consumes an accepted scheduled PostgreSQL receipt in the public local fenced live-restore path, with a distinct manual pre-change recovery backup. Review `eebe0dea9f7a2ada4263cfd3996a257a2542858d7940f920240ce9298ebfc10d` pinned the accepted CronJob/signing Secret, completed ingestion Job readback, exact MinIO versions, and target identities after the producer Job had been deleted. Apply restored `mp23-pg-b` from `(1, before-scheduled-live-v1)` to `(1, scheduled-v2)` and released the fence with the same StatefulSet/PVC UIDs and one ready replica. A fresh review `108304f98a8be6c3a790d8cc77fc86b580d2ecc50f6dbec4643f1c0021bfc3a0` selected only verification and applied without data replay. Redis/ClickHouse live procedures, cloud integration, scheduled pruning, and M3 volume recovery still prevent EP-160 and the parent from closing.

The next EP-160 M2 Redis probe used a separate disposable PVC and Redis 8 server, never mutating the accepted `mp23-redis` source. An offline Job replaced `dump.rdb` with a verified source RDB; a second offline Job applied an independently saved recovery RDB. Each Job loaded the file in a loopback-only server and checked a known key, and each restarted server read the expected value and exact RDB hash from the same PVC. The namespace was deleted. This settles the native file procedure while the reviewed suspended-Job/fence handoff, provider-bound receipt checks, unknown-outcome recovery, and public Redis live command remain open.

The automatic `03:17:00Z` local CronJob firing produced signed PostgreSQL B, Redis, and ClickHouse receipts with controller-owned Job identities. Each was ingested through a saved review and consumed by a separate reviewed scratch restore that read the expected database content. A fourth, legacy PostgreSQL A schedule fired but still lacks an accepted signing Secret, so it is not counted as migrated. EP-159 now has a public `db prune-scheduled-backups` review compiler with exact accepted receipts, retention-policy and provider-version pins. Its first local command checks correctly refused Redis with no run beyond keep=7 and PostgreSQL B with unexplained older objects. An eligible native deletion, partial-delete recovery, historical schedule treatment, and cloud generations remain open; EP-159 M1/M2 and EP-160 M2/M3 stay In Progress.

The next local Redis retention fixture admitted eight further signed runs, then saved a review selecting the first unreferenced run outside keep=7 while preserving two older restore-referenced backups. Apply deleted the selected backup version but stopped before deleting its receipt because a prefix-list check matched the sibling receipt key. The transaction remains ambiguous and the public receipt listing reports that exact incomplete pair. The equality check and fixture are corrected at `41a2845a`; the immutable failed review is not replayed. EP-159 M2 still requires reviewed exact remaining-member recovery, a fully converged native prune, and apply-time provider-list validation.

The failed scheduled-prune transaction was then explicitly abandoned through a new terminal-Job-only inventory recovery action. It checked the original published review's single scheduled prune resource, observed the exact owned Job in `Failed` state, and restored the previously converged accepted scope map; the local head has no active transaction. This does not mark the selected backup pruned: its receipt remains in MinIO and public listing still reports the incomplete pair. EP-159 M2 remains open until a reviewed operation deletes that pinned receipt version and records the recovered outcome.

EP-160 M2's next production handoff requires a restore fence alongside the already registered maintenance fence. The adapter registry now allows multiple named capabilities on one executor, rejects a review if more than one selects an operation, and replays and recovers only the capability saved in that review. A focused fixture passed with one unselected and one selected fence. This is shared routing groundwork; no live restore was admitted by it.

EP-160 M2 now has a separate live-restore operation and review compiler for PostgreSQL manual backups. The private canonical proof fixes the accepted target revision, StatefulSet/PVC/Pod identities, and distinct source and recovery backup Jobs, receipt digests, object addresses, and checksums. A focused two-backup fixture reached the `RestoreLiveDatabase` planner action and refused changed target incarnation, duplicate recovery, missing private Job evidence, and altered proof shape. Native execution, exclusive fence, post-restore content verification, and public `--into-live` command remain open; the new action is not yet exposed for live mutation.

The live-restore proof now also pins exact object/receipt versions and its store reference. A separate `RestoreLiveDatabase` fence capability checks the accepted target and both backup revisions during selection, then replays the saved target/PVC identities, recovery digest, and Pod pin through the existing online exclusion controls. It remains library-only until the command service, native PostgreSQL effect, content verifier, and uncertain-effect resolver are connected; M2 remains open.

The candidate PostgreSQL native effect now streams the dump into one transaction in the pinned Pod, resets non-system schemas, and compares a fresh full logical dump after removing only paired randomized psql guard tokens. A disposable database on accepted local `mp23-pg-b-0` contained an extra schema and changed row; the probe removed the extra schema, restored `(1, scheduled-v2)`, and matched the saved normalized dump byte for byte. The probe database was dropped. This is still library/procedure evidence, not a public fenced live restore or M2 closure.

EP-160 M2 has its first public fenced live PostgreSQL roundtrip in the local fixture. A separate accepted manual backup of `mp23-pg-a`'s changed row was scratch-restored and read back as the pre-change recovery position. Review `fd2ef960569b16b86c1619b20dbd9f2927f46461bc81542c70e3d365c2f3246d` then pinned that recovery backup, the older manual source, both exact MinIO versions, and the live StatefulSet/PVC/Pod UIDs under `kubernetes-native-live-restore-fence-v1`. Apply converged; the live row returned to `(1, nagare-mp23-hello)`, the target UIDs and one ready replica remained, and the durable fence and NetworkPolicy were absent. A new review selected only verification and applied without replaying the data change. This proves the local manual PostgreSQL normal path and no-repeat behavior; failed-effect forward recovery, terminal-loss, scheduled live selection, Redis/ClickHouse, cloud storage, and live volume cases still block EP-160 M2/M3 and the parent.

The same reviewed PostgreSQL path now has an explicit `recover-fenced-backup` operator decision for a failed or uncertain source effect. It proves the pre-change content under the active fence, journals that proof before writer release, and abandons the original transaction after release without accepting the attempted change. Recording-provider tests cover the rollback and a partial writer release that requires `forward-fenced-release`. Native failed-effect and terminal-loss evidence remains open, as do the other M2/M3 cases.

The local fixture now also proves terminal loss during the reviewed restore invocation. The CLI was stopped after its fence reached `FenceChanging`; a fresh process refused ordinary resume, recovered the previously scratch-verified pre-change backup through the public decision command, and observed the original row and target UIDs with one ready replica, no NetworkPolicy, no data fence, and an inactive original transaction. Native partial-effect proof and the remaining M2/M3 engines and volumes stay open.

The first terminal-loss run uncovered an accepted-revision rollback bug: the abandoned restore scope remained accepted and a new plan selected it again. The rollback now restores `headAccepted` to the prior converged revision map and requires a review with no other mutating operations. After a checked repair of only that stale scope in the disposable fixture, a second scoped CLI termination and public backup recovery left 51 accepted/converged scopes equal, no active transaction or fence, the pre-change row intact, and a fresh review with only its new restore plus verification. This corrected run is the native terminal-loss evidence; the failed-SQL case follows below.

The local PostgreSQL failed-effect fixture now passes too. A wrapper appended a deliberate SQL error after the reviewed restore stream inside `psql -1`; PostgreSQL logged the error, the transaction left the pre-change row intact, and the inventory kept `FenceUnresolved`. The public recovery decision proved the pinned backup and released writers. The accepted and converged sets again matched, and a fresh review did not select the abandoned restore. Scheduled live selection, Redis/ClickHouse, cloud storage, and M3 volumes remain open.

**Current registration evidence.** At `f79329f0`, running `python3 scripts/audit-managed-commands.py --coverage-result /tmp/nagare-mp23-command-coverage.json` reports 135 registered CLI routes, 34 recipes, 25 registered library calls, 11 pending routes, seven pending recipes, and 30 incomplete catalogue rows. It exits 1 for the unregistered existing `Inventory.planInventoryCandidateWithPayloadIdentity` call in `app/Main.hs`. That file was clean during this inspection, so this is a committed integration regression, not the concurrent EP-160 edit. EP-153 owns the correction and matching audit fixture. Counts overlap command families and proof obligations; they are not 48 independent missing features. The dirty candidate is not release evidence.

**Architecture assessment.** Typed scopes, independent ownership, exact native identity, retained private reviews, and durable recovery have working compiler/store/bootstrap evidence. This inspection found no basis for discarding those foundations. It also cannot certify the whole design from unit or component proof. The weak point was treating native data exclusion and every remaining operation as routine adapter wiring: their lifecycle and authority semantics required concrete design and early end-to-end probes. The failure involves both planning and observed execution behavior. Session metadata identifies repeated `gpt-6-sol` execution, while plan provenance includes multiple authoring models; this is not a controlled model comparison and does not establish that changing a model alone fixes the problem.

Earlier architecture discoveries remain relevant: derived controller claims must participate in collision checks; candidates carry explicit changes and their base revisions; native preparation precedes immutable review; admission grants authority under the store lock; ambiguous effects recover before obsolete preflight checks; lifecycle operations retain exact incarnations; and shared history uses conditional writes. Their decisions remain in Integration Points, the child plans, ADR 22, and this file's history at `f79329f0`. Routine historical “still open” lists are not the current backlog.


## Decision Log

2026-09-30: The operator schedules platform upgrades after the initial feature set is complete and Nagare is verified safe to start using. Keep MP-23's current supported contract and full operational/release gates; upgrade implementation is the following phase, rather than a new prerequisite of initial safe use.

2026-09-29: Prioritize EP-156 cloud convergence and application/data recovery because the operator urgently needs that deployment path. Pull shared implementation and installed-package prerequisites into the selected cloud assertion; schedule full EP-155 local integration afterward. Keep both native systems, complete local/cloud evidence, supported scope and release acceptance unchanged. This is execution scheduling, not an architectural change.

2026-09-29 (design reassessment): Replace distributed phase decisions with one serial operation driver; separate resource read inputs from mutation evidence. Retain models, native adapters, wire history, and conditional storage. Supersede mandatory index rollout before recovery; preserve release scope. See the linked reassessment for alternatives, ownership, compatibility, and the stopping rule.

2026-09-29 (E8–E10): Publication and restored-history experiments validate the local protocol direction. The actual partial-prune CLI and paired executor counterfactuals add F12/F13 to order 0a; factory-only repair is insufficient. No production fix, audit closure, or new child is declared.

2026-09-29: Replace the generic replay-repair priority with three command-boundary repairs demonstrated by local experiments: phase-correct registry construction, selected target/native evidence, and observed-generation append cost. Retain passing batch replay and warm-cache behavior. Make F04/F10 prerequisite defects for affected commands despite their lower audit priority; primitive/foundation acceptance does not establish command acceptance. No product scope or release requirement changes.

2026-09-28: Synchronize external evaluation priority with MP-24/EP-163: K8up/restic first for volume/application backups, Velero as a secondary desk comparison because the operator is concerned about its project direction, and CloudNativePG/Barman retained for PostgreSQL. This supersedes the earlier Velero-first evaluation emphasis, selects no dependency, and changes no MP-23 feature or release gate.

2026-09-28: The operator authorizes a scope reduction while explicitly retaining the cross-tool journal and state. Keep typed ownership, reviews, conditional filesystem/GCS history, existing engines, verified backups, isolated restores, and full validation of that contract. Defer general live overwrite/automatic recovery cutover, custom interactive maintenance (cancel EP-161), and generalized scheduled retention pruning. EP-153 guards new admission and preserves existing recovery; EP-159 makes retention limits visible; EP-160 retains accepted M1 and narrows M2/M3. This supersedes earlier no-feature-reduction instructions and producer/maintenance scheduling. Historical work is preserved, not declared complete or erased.

2026-09-28: Keep external-tool evaluation independent in MP-24/EP-163. No Flux and no additional messaging engines. Keep the cross-tool journal/state as an architectural constraint. Evaluate CloudNativePG/Barman for PostgreSQL and Velero specifically for backup/recovery fit; the operator's Velero question is an evaluation request, not selection or adoption authorization. Do not make a prototype, tool migration, or new controller a release gate for MP-23.

2026-09-27: Order remaining implementation by producer/consumer checkpoints: early package/fixture/evidence preparation, representative scheduled receipt and restore, early maintenance handoff, then remaining engine/volume cases and final candidate evidence. The full 24-hour history exposes late planning/replay interface changes; avoid completing one entire producer plan before testing its consumers. EP-160 M1 stays unchanged.

2026-09-27: Keep the existing nine remaining children and full release contract. Replace microtask tracking with a current outcome registry and production-path execution order; withdraw stale aggregate estimates. Require findings to map to existing acceptance or an explicit scope decision. Distinguish the shared fence state machine from operation-specific access to fenced data, assigning restore to EP-160 M2/M3 and maintenance to EP-161 without reopening EP-160 M1. Preserve the concurrent implementation and all earlier evidence.

2026-09-27: Enforce the operator’s explicit no-GKE instruction and correct EP-160’s milestone ownership. Its prior rolling estimates included an invented provider gate and are not a current M1 forecast. All required behavior and actual local/cloud release proof remain required in their assigned plans.

2026-09-26: Recompose unfinished EP-148 work into EP-158–161 and transfer its cross-cutting M4/native proof obligations to EP-153–157. Keep completed evidence; supersede the original without waiving acceptance. EP-160 alone owns shared data fencing, EP-161 consumes it, and provider proof remains reusable without a plan-closure cycle. Extend the effort forecast to include the previously excluded feature work.

2026-09-26: Split EP-150 into EP-152–157 at the operator’s request because four oversized milestones hid substantial delivered work and the remaining release path. Preserve every existing requirement, credit implemented baseline once, and separate preparation from native acceptance. No reduced or knowingly broken version is an acceptable outcome. EP-157 owns the final all-gates decision; partial local evidence is not release readiness.

2026-09-26: The first full release claim targets fresh inventory-backed
contexts because the operator confirmed every existing context and its data
can be discarded. EP-150 proves a complete reviewed first bootstrap and
legacy mutation refusal; it does not need a dedicated in-place upgrade
command or translation of old coarse transaction evidence. Old bundles stay
inspectable. A future platform version transition requires a separately
reviewed design before an admitted context changes payload version. EP-148's
scope command migration and all local/GCP, coverage, and immutable evidence
gates remain in force. This narrows the first release claim without weakening
its ownership and recovery protocol.

2026-09-24: Mark EP-149 Complete at its explicitly provider-independent boundary: exact adoption and retirement routes have native proof where implemented, and migration is proved by command-path and stage-aware recording adapters while production provider stages still refuse. EP-148 and EP-150 remain responsible for application command migration and real provider/integrated coverage; completion of this child does not authorize unproved migration or collection. ADR 22 records the durable two-incarnation and recovery constraints.

2026-09-24: Keep immutable replacement distinct from configuration drift at the shared observation boundary. An adapter may report replacement required, but the generic planner must refuse an ordinary update until EP-149 provides a reviewed replacement or migration contract. ADR 22 records this durable rule.

2026-09-23: Keep adoption authority consistent at the operator DTO, generic lifecycle validator, and planner boundaries. A matching provider stamp without accepted history is not proof of ownership; the current route requires an unowned physical incarnation. Rationale: direct callers of the shared validator must not bypass the reviewed proposal's ownership check.

2026-09-23: Mark EP-147 Complete when its supported bootstrap path, reusable database/cache builders, cluster executors, shared owner composition, and host timer delegation have evidence. Keep EP-148's standalone/application database command migration and EP-149/150's lifecycle and integrated cloud work visible as separate children; completion of this child does not imply complete mutation coverage for the MasterPlan.


2026-09-16: Preserve deliberate platform/application ownership boundaries while composing their claims and dependencies in one context inventory. Rationale: independent deployments should not erase unrelated resources, but isolated inventories cannot detect cross-boundary collisions.

2026-09-16: Use one typed declaration path for render, review, and execution, with removal of superseded policy scripts as acceptance. Rationale: a handwritten inventory beside scripts would duplicate and drift from the behavior it is meant to govern.

2026-09-16: Separate desired state, observations, and execution history. Rationale: partial failures must remain explainable without advancing a false converged or release marker.

2026-09-16: Keep native executors and their safety boundaries. Rationale: the common model coordinates identity/lifecycle; it does not reproduce Pulumi state, NixOS activation, Kubernetes controllers, or Helm reconciliation.

2026-09-16: Model complete declarations plus constrained late-bound outputs and explicit review barriers. Rationale: generated IPs/credentials/keys exist only after some effects, but that cannot authorize unreviewed resources or changed native plans.

2026-09-16: Initially serialize mutations in one private operator state store and bind revisions with compare-and-swap. Rationale: local concurrency/crash safety is required now; shared remote coordination is a later implementation, not an assumed property.

2026-09-16: Seven children with three parallel adapter/policy streams after two foundation plans. Rationale: this balances concerns and independent tests without assigning all executable behavior to the final integration plan.

2026-09-16: Link every plan to intention_01m2nkkn0deaht66kevpmkjjpp, created through mina ci --json. Rationale: this is one initiative even though its resource ownership and work streams are separate.

2026-09-16: Adoption, migration, retirement, global artifact retention, and delegated maintenance are explicit model elements. Rationale: labels/names cannot prove authority, generated children must not compete with controllers, and retained data needs recovery credentials and dependency history.

2026-09-16: Amend the shared interface before implementation, following the validation recorded in Surprises & Discoveries. composeInventory returns a CompositionCandidate and is the only route to a validated inventory; claims include derived and reserved claims; EP-144 owns ScopeDeclaration, ResourceBundle, DeclaredOperation, RetirementIntent, and the contribution dispatch; digests follow content and never revisions; nagare-dsl stays free of hashing; ResourceId comes from a stable logical key. Rationale: each change removes a contradiction, an unowned type, or a path by which the compiler would have accepted a collision or a silent deletion.

2026-09-16: One planner, explicit native preparation, and lock-scoped execution authority. planChanges takes LifecycleDecisions that only EP-149 can build; prepareReview and an adapter prepare method create native evidence; admit under the process lock is the only source of an ExecutablePlan; admitted outcomes are TransactionResults that name their transaction. Rationale: the earlier interface could not produce a review bundle, could not express a mixed adopt-and-update change, and treated a proof about a stale snapshot as permission to mutate.

2026-09-16: Specify the store as conditional writes and keep the filesystem as the only shipped implementation for now. Rationale: it costs nothing today and keeps a shared store possible without a protocol change. Whether a shared store joins this initiative is left open for the operator because it changes scope and touches ADR 13.

2026-09-16: Add EP-151, a shared inventory store in the context's state bucket, as the eighth child, and group the children into four phases. This settles the question the previous entry left open. Rationale: replication or export/restore lets two machines restore the same history and both apply, after which each may believe it can retire what the other created, and the state at risk is deletion authority; ADR 13 moved the less critical Pulumi state off the workstation days earlier for the same reason; and because the store contract is already conditional writes, a real shared store costs about what replication would. It is deliberately narrow: single writer, no lease, explicit operator takeover, filesystem store retained for local mode, tests, and a new context's first transaction. EP-151 depends only on EP-145; it gates EP-148's removal of the last legacy deploy path and is a hard dependency of EP-150.

2026-09-16: Assign GitHub publication recovery to EP-150 with provider-durable draft evidence and serialized workflow ownership. Rationale: a complete platform resource model includes the actual publisher, and temporary CI files cannot establish recovery after a runner disappears. App stop and nondeterministic Helm rendering also receive explicit compatibility/parity tests.


## Outcomes & Retrospective

EP-144, EP-145, EP-146, EP-147, EP-149, EP-151, and EP-152 are complete. Eight active outcomes EP-153–160 remain required under the revised scope; EP-148 and EP-150 are superseded history, and EP-161 is deferred/Cancelled with delivered recovery work preserved. EP-150 delivered a recoverable release publisher, deterministic integration tests, history restoration, evidence projection, and compatibility safeguards; cancelling its umbrella does not erase those implementations. EP-152 adds reviewed fresh platform stages, public recovery, and a focused native marker smoke. Final acceptance still requires IR-24's full verification set, native local/GCP behavior, independent-scope isolation, complete command coverage, clone-free native packages, and immutable evidence. EP-152's focused marker proof is an input to that acceptance, not a substitute for full local and GCP recovery evidence.

At completion, compare these outcomes with IR-24, update its status only with evidence, and distill durable lessons into ADR 22 and affected existing ADRs. Do not publish a release or modify existing operator deployments as a side effect of updating plan status.


## Revision Notes

2026-09-29: Apply the operator's cloud-first priority to the entrypoint, dependency narrative, resume procedure and checkpoint schedule; align EP-154–156 without waiving final local/native/release gates.

2026-09-29: Revise implementation order and shared ownership from measured append/history costs, a controlled recovery-order experiment, and the built CLI's unknown-target failure. Keep passing replay/cache behavior credited and add no new child. See the retained experiment report for limits and counterexamples.

2026-09-28: Make the observed GCS replay defect the immediate implementation priority, reconcile the stale EP-153 entrypoint, and replace vague stalled-work advice with timed diagnosis, evidence-based waiting/retry decisions, and representative operational review. This changes execution order and responsibility; it does not claim the replay defect is fixed.

2026-09-28: Align the external-tool reference with the operator's K8up-first evaluation preference and Velero project-direction concern; release scope and gates remain as previously agreed.

2026-09-28: Apply the operator-approved reduction to active scope, dependencies, execution order, and release acceptance; keep the cross-tool journal/state and all required proof for retained features. Coordinate affected children and ADR 22. Velero remains a backup evaluation candidate only.

2026-09-27: Extend diagnosis to every commit/file in the fixed last-24-hour window and correct the whole-plan ordering to exercise producer/consumer contracts before broadening engine coverage; make early package/fixture/evidence preparation explicit.

2026-09-27: Diagnose the stalled execution from original plans, commits, Codex logs, and the current audit. Correct EP-153/160 registry status, withdraw stale forecasts, remove duplicate historical microtask tracking, and require existing production-path assertions to drive work. Make the restore/maintenance handoff explicit in ADR 22 and affected successor plans. EP-160 is concurrently implemented and its file is unchanged by this pass. No feature, supported target, or release evidence requirement is removed; no child is added.

2026-09-27: Prohibit GKE across all children and fix the finite EP-160 M1 boundary without weakening M2/M3 or EP-156 acceptance.

2026-09-26: Split remaining EP-148 and EP-150 obligations into EP-152–161, preserve delivered work and full acceptance, and redirect ownership and dependencies. The initial estimates are historical and are superseded by the forecast correction in Progress.

2026-09-16: Validate and amend the shared API before implementation, then add EP-151 at the operator's decision for conditional shared history. Detailed earlier revision and implementation entries are retained in this file at git revision `f79329f0`; their durable decisions remain above and in ADR 22.
