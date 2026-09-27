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
---

# Make managed resources first-class through typed scoped inventories

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable decisions into docs/adr/ in the same change.


## Vision & Scope

**MANDATORY OPERATOR BOUNDARY — NO GKE (2026-09-27).** Nagare supports local k3d/k3s and k3s on a NixOS VM in GCP Compute Engine. Do not create, start, use, authenticate to, select, or request access to a GKE cluster for this initiative. Existing workstation GKE contexts are unrelated. No child may add GKE credentials, probes, compatibility, or access as a completion gate. EP-156 owns actual GCP/NixOS/k3s and GCS integration; GCP does not mean GKE.

Address [IR-24](../improvement-requests/make-managed-resources-first-class.md): an operator can obtain one complete, typed, revision-bound account of Nagare-managed cloud, host, Kubernetes, data, credential, artifact, and release/control resources. Compilation rejects conflicting ownership before mutation. Review exposes creation, adoption, update, replacement, migration, retention, and deletion. Apply executes dependency-aware native operations with durable evidence; resume skips proven completed work. Status explains identity, ownership, dependencies, drift, health, and retirement decisions.

Platform components and applications retain independent desired-state ownership and release cadence. Each scope is one owner's complete declaration with its own revision. The context inventory composes these declarations and validates their shared claims; it is not another independently editable desired-state document. Updating one selected scope preserves every unselected scope. Application deployments can submit authorized contributions to platform-owned routing/configuration, but cannot seize the entire shared object or advance the platform release.

The architectural objective is to reduce policy scripting through a shared Haskell model. Smart constructors, explicit alternatives, typed capability references, and opaque validated/reviewed values enforce structural guarantees. Pure functions validate whole-graph properties. Adapters observe live facts and execute native provider operations. The same declarations produce inventory, review, rendering, and execution inputs. A separate handwritten inventory mirroring existing scripts is not acceptable. Acceptance includes removing superseded orchestration and duplicated guards after their replacement is proven.

Desired state, observed state, and execution history remain separate. Logical IDs survive names and ownership transfers; physical identities identify individual incarnations. Resource membership and policy are known before external mutation. Generated values are constrained typed references, not permission to introduce new resources. Data defaults to retention; unknown observations never imply absence. Credentials are private adapter inputs, absent from public review/evidence representations.

The first implementation runs in the operator CLI with private context-owned state, one writer, immutable snapshots, and a durable journal. Its release claim begins with fresh inventory-backed contexts; existing contexts and their data are disposable for this first release. Pulumi, NixOS, Kubernetes, Helm, storage, and registry tools retain their native responsibilities. This does not add a daemon, distributed coordinator, new provider engine, automatic foreign-resource adoption, generic schema rollback, in-place platform version upgrade of an admitted context, or production rollout. It does not complete the separate replacement-upgrade initiative. A later controller can implement the same store/adapter protocol; multi-workstation exclusion requires shared coordination and is not claimed by the filesystem implementation. A cloud context may instead keep that state in its state bucket, beside its Pulumi state. That store refuses a second writer from another machine through conditional writes and needs an explicit operator takeover to resume someone else's work; it still has no lease or liveness detection and is not a distributed coordinator.


## Decomposition Strategy

The foundation and adapter children EP-144–147, EP-149, and EP-151 are complete. EP-148 is now superseded implementation history: EP-158 owns access/CDN operations, EP-159 scheduled backup receipts/pruning, EP-160 fenced database/volume restore, and EP-161 interactive maintenance. EP-148’s remaining command cutover, packages, and provider proof transfer to EP-153–157. Completed behavior and all acceptance obligations remain intact. EP-150 is now a historical record, Cancelled because its remaining scope is redistributed rather than abandoned. Six replacement children own independently testable outcomes: EP-152 fresh platform bootstrap; EP-153 complete command coverage; EP-154 installed native packages; EP-155 local integrated recovery; EP-156 GCP integrated recovery; and EP-157 mandatory immutable release evidence. Completed EP-150 publication, store restoration, compatibility, and test infrastructure are inherited, not reimplemented.

This is a decomposition change only. The operator explicitly requires a working, fully validated version, not a reduced feature subset. Local success is an engineering checkpoint, not adoption readiness. No feature or existing acceptance criterion is dropped by the split; EP-157 closes only after EP-152–156 and EP-158–161 are complete. EP-148 and EP-150 are Cancelled/superseded records, not pending dependencies or claims of complete implementation. The existing fresh-context release boundary and offline-only Cloudflare proof remain as previously agreed.

The local ADR corpus was scanned by filename/title and relevant records were read. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates payloads/private workspaces; [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) preserves operator host identity; [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) defines release/version transaction semantics; [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) binds immutable release evidence; [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) confines cloud writes; [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) preserves self-reversion; [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) protects forward-only storage growth; [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) protects private operator/state material; [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) guards protected replacements; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) governs Haskell style; [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds native review and receipts; [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) protects irreversible cutover; [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) separates route/TLS ownership; and [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) defines cache retention and trust boundaries.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) records the accepted architecture from this discussion; it is a design decision, not a claim of implementation. Mori searches found no relevant cross-repository ADR to import. The local mori.dhall and mori show --full do not declare docs/adr as a profiled bundle, so the existing ADR filename/frontmatter convention is preserved. Dependency APIs must be researched through Mori during implementation and current upstream releases checked before changing bounds; this plan prescribes no dependency upgrades.

Rejected alternatives were isolated platform/application inventories without shared conflict checks; one global release coupling all applications to platform upgrades; a manually maintained resource list beside imperative scripts; replacing native reconcilers; and an always-on control plane before the operator-driven protocol is proven.


## Exec-Plan Registry

**Implementation entrypoint.** `$master-plan implement docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md` resumes the ordered checkpoints in Progress. For this initiative, the operator-requested producer/consumer sequence overrides the skill's default of selecting the first eligible registry child and finishing that entire child before switching. The registry records ownership and whole-child status; it does not express the checkpoint schedule. Hard dependencies still apply.

On every resume, read the current child Progress and recorded acceptance evidence for the next checkpoint. Skip accepted checkpoints whose evidence remains applicable; reconcile a stale parent snapshot instead of repeating their implementation. EP-160 M1 completion leaves EP-160 In Progress because M2/M3 remain. Preserve work owned by any still-active implementation session.

**Handoff after EP-160 M1:** select order 2 below, starting with EP-153's named registration regression if it remains present. Then run the bounded EP-154 installed smoke, establish EP-155's local fixture/health checks, and confirm EP-157's evidence inputs. These preparations finish when their stated outputs exist; they do not require complete command coverage, all native systems, full recovery, or final release acceptance. Continue with the PostgreSQL producer/restore/maintenance path in order 3. Do not finish all of EP-153, EP-159, or EP-160 before exercising those consumers.

At each checkpoint handoff, record the accepted output/evidence and next checkpoint in the owning child's living sections and keep the parent's brief Progress snapshot current. Switch children and continue within the authorized MP scope; a partial checkpoint does not mark its whole milestone or child Complete. If blocked, name the missing input and select ready independent work from order 5 or bounded provider preparation. Do not repeat an unchanged failed gate or restart a broad audit. Final acceptance remains order 6 and every child's existing criteria remain required.

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
| 153 | Close managed command coverage for the inventory release | docs/plans/153-close-managed-command-coverage-for-the-inventory-release.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-158, EP-159, EP-160, EP-161 | In Progress |
| 154 | Validate installed inventory packages on every supported system | docs/plans/154-validate-installed-inventory-packages-on-every-supported-system.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-158, EP-159, EP-160, EP-161 | In Progress |
| 155 | Prove local application and data recovery end to end | docs/plans/155-prove-local-application-and-data-recovery-end-to-end.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-158, EP-159, EP-160, EP-161 | In Progress |
| 156 | Prove fresh GCP convergence and shared history recovery | docs/plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-155, EP-158, EP-159, EP-160, EP-161 | Not Started |
| 157 | Gate the inventory release on complete immutable evidence | docs/plans/157-gate-the-inventory-release-on-complete-immutable-evidence.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-155, EP-156, EP-158, EP-159, EP-160, EP-161 | Not Started |
| 158 | Complete reviewed access and CDN operations | docs/plans/158-complete-reviewed-access-and-cdn-operations.md | EP-146, EP-147, EP-149, EP-151 | None | Not Started |
| 159 | Complete scheduled backup receipts and exact retention pruning | docs/plans/159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md | EP-146, EP-147, EP-149, EP-151 | None | Not Started |
| 160 | Complete fenced live data restore across supported engines and volumes | docs/plans/160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md | EP-146, EP-147, EP-149, EP-151 | EP-159 | In Progress |
| 161 | Provide scoped interactive maintenance with durable recovery | docs/plans/161-provide-scoped-interactive-maintenance-with-durable-recovery.md | EP-146, EP-147, EP-149, EP-151 | EP-159, EP-160 | Not Started |

Hard dependencies must be Complete before starting the dependent child; soft dependencies supply additional real-adapter coverage but allow independent fixture-backed work. Registry status values are Not Started, In Progress, Complete, or Cancelled.


## Dependency Graph

EP-144 must complete first because all later work consumes its identity, declaration, wire, and validation contracts. EP-145 then defines the one authoritative store, review boundary, journal, and adapter protocol.

EP-146, EP-147, EP-149, and EP-151 may proceed after EP-145. EP-151 needs only EP-145's store contract, conformance suite, and head format; its soft dependency on EP-146 is the handoff of a new context's first bootstrap transaction, which necessarily runs on the local store because the state bucket does not exist yet. Cloud and cluster builders test against declared typed outputs without needing each other's live executors. Lifecycle policy tests against recording adapters without claiming native behavior. Their integration dependency is that every adapter exposes identity/precondition/verification capabilities required by lifecycle policy; reconcile that contract before any real adoption/migration/retirement is enabled. Until then these actions refuse explicitly, while fresh-resource/convergent operations remain independently verifiable.

EP-148's delivered application/data code now supplies the baseline to EP-158–161; the original plan is superseded, so no active child depends on its completion. EP-146/147/149/151 are complete prerequisites for all active successors. EP-158 access/CDN and EP-159 backup receipts can proceed independently. EP-160 implements and proves the shared data fence at M1; EP-161 can prepare session fixtures against that contract, but native maintenance admission waits for its exclusion/recovery proof. EP-159 receipt extensions feed EP-160 restore and EP-161 recovery, while existing manual receipts allow development to begin without that integration.

EP-152 bootstrap is complete. The remaining integration chain is EP-155 local evidence, EP-156 cloud evidence, and EP-157 final release acceptance. EP-153 command coverage, EP-154 packaging, and EP-158–161 features proceed alongside it. Fixture and schema work can start before all features finish; final evidence must include their working implementations. Shared native proofs do not require administrative closure of the feature plan that will cite them. EP-157 requires every active predecessor's full accepted outcome. Numerical order is not execution order. MasterPlan 21's separate replacement-upgrade initiative remains independent; reuse its safety principles without silently adding its unfinished live cutover to this release.


## Integration Points

**EP-160 M1 closure correction (2026-09-27).** Its finite gates are production saved-review fence integration, observed local k3s exclusion, scoped guard authority, durable interruption/recovery, real fixture verification before release, and recorded acceptance. Full engine restore/content belongs to EP-160 M2; live-volume recovery to M3; real cloud k3s/GCS proof to EP-156. These remain required for the full release but must not become circular M1 prerequisites. EP-161 consumes the accepted shared contract. Reuse proven controls; do not expand this milestone into generalized cluster security or additional providers.

**Fence consumer handoff (2026-09-27).** The shared durable protocol does not imply one native exclusion policy fits every operation. Current Kubernetes exclusion stops the database and drains its PVC. EP-160 M2/M3 must admit and verify their exact recovery process; EP-161 must admit a usable engine/client while ordinary writers remain excluded. Required consumer-specific extensions preserve the shared state machine and are owned by those consumers. They do not reopen M1 or require a second lock/store. See ADR 22's recovery-authority amendment.

**Replacement-plan ownership (2026-09-26).** Active ownership after the EP-150 split is EP-152 for platform candidate/marker behavior in cli/nagarectl/app/Main.hs and cli/nagarectl/src/Nagare/Inventory/Bootstrap.hs; EP-153 for command registration/coverage, remaining platform-side entry points, application/library cutover, smoke/in-cluster webhook consumers, and user docs; EP-154 for Nix packaging and native output manifests; EP-155 for outstanding promised native migration/collection bindings, the common scenario fixture, and local evidence; EP-156 for the GCP fixture and shared-store evidence; EP-157 for scripts/assemble-managed-resource-evidence.sh, scripts/assemble-release.sh, release workflow enforcement, and the existing GitHubRelease adapter. EP-155 owns scripts/rehearse-managed-resources.sh; EP-156 consumes its protocol and contributes cloud cases without forking it. Shared Main.hs, Spec.hs, and workflow edits must preserve concurrent changes.

EP-158 owns reviewed access/CDN compilers and operations. EP-159 owns scheduled backup receipt/delegation/ingestion and retention-pruning contracts, including compatible reuse by restore. EP-160 owns cli/nagarectl/src/Nagare/Inventory/DataFence.hs and the shared durable exclusion/recovery protocol plus database/volume restore. EP-161 owns cli/nagarectl/src/Nagare/Inventory/Maintenance.hs and terminal/client lifecycle, consuming DataFence instead of defining a second lock. EP-153 integrates admission checks into every registered command. EP-155/156 provide combined native evidence and may execute implemented feature paths before their owner plans close. EP-157 requires both feature acceptance and full native evidence; no cycle or reduced provider gate is introduced.


**Typed domain contract — owned by EP-144, consumed by every child.** cli/nagare-dsl/src/Nagare/Resource/{Types,Reference,Policy,Inventory,Compile,Wire}.hs and schemas/resource-inventory-v1.json define stable ContextId/ScopeId/ResourceId, provider claims/aliases, physical identity, typed exports, owner contributions/delegation, lifecycle/data/sensitivity policy, and deterministic serialization. New provider kinds extend this contract explicitly. Do not derive Generic, public setters, unchecked FromJSON, or coercible phantom roles for any type whose constructor is hidden, identity newtypes included.

EP-144 also owns the types the builders return and the planner consumes: ScopeDeclaration, ResourceBundle, DeclaredOperation, RetirementIntent, the closed contribution-kind dispatch, and the per-kind claim function. They live in nagare-dsl because nagarectl depends on it and not the reverse. composeInventory is the only route to a ValidatedInventory and returns a CompositionCandidate: the desired inventory, the base generation vector, and the explicit replace/retire changes. There is no decoder from bytes to a validated inventory; the wire form is one canonical document per scope plus a manifest, and a loader composes again. A ScopeSnapshot carries every accepted scope's full declaration and the claims still reserved by retained incarnations, candidate incarnations, and unresolved transactions. A claim set includes derived reservations for the deterministically named children of a controller. ResourceId is minted from a stable logical key, never from the provider name.

Digests identify content; revisions identify history. nagare-dsl neither computes nor stores a digest of inline content, and nagarectl derives every digest in one module. A scope revision is a purely derived generation plus that digest. No revision enters a desired digest or provider metadata, including the effective digest of a shared resource, which follows its composed content.

**State, review, and operation protocol — owned by EP-145, consumed by the adapter, application, and integration children.** cli/nagarectl/src/Nagare/Inventory/{Store,Plan,Journal,Execute,Adapter}.hs owns desired/converged heads, complete scope revision vectors, historical/retained incarnations, review bundles, operation identity, adapter capabilities, completion/recovery states, and writer locking. All persistent state stays outside payload workspaces. EP-149 adds lifecycle decisions through this interface; adapters cannot write their own scope heads.

The pipeline is compile, observationRequirements, observe, planChanges, prepareReview, publish the bundle by digest, verifyReview, then admit and execute under the process lock. planChanges is the single pure planner and takes opaque LifecycleDecisions; EP-145 exports only the empty value and EP-149 builds the rest. prepareReview calls each adapter's prepare method to produce the retained native bundle, so adapters implement observe, prepare, preflight, execute, verify, and recover. A ReviewedPlan is evidence against a snapshot read outside the lock; only admit, under the lock, yields the ExecutablePlan that authorizes effects, and its type is scoped to that lock. Refusal is an error; every admitted outcome is a TransactionResult naming its transaction. The store is specified as conditional writes (publish-if-absent, append-at-sequence, replace-head-if-generation-matches) and the transaction suite runs against an in-memory store with only those semantics, so the filesystem implementation is replaceable. Adapters never call back into a command that takes the context lock.

**Store selection and the state bucket — owned by EP-151, with the contract owned by EP-145; touches EP-146, EP-152, and EP-156.** EP-151 adds cli/nagarectl/src/Nagare/Inventory/Store/{ObjectOps,Object,Open}.hs, the `NAGARE_INVENTORY_STORE` and `NAGARE_INVENTORY_STORE_URL` context fields in Target.hs and scripts/lib/target.sh, and `nagarectl inventory store status|migrate`. It implements EP-145's InventoryStore unchanged and passes EP-145's transaction suite; it does not alter the head, journal, or member formats. EP-145 defines the executor claim in the head manifest that EP-151 uses to refuse a second machine. The store defaults to a sibling prefix of the Pulumi state in the same bucket and reuses Nagare.Ops.PulumiBackend's bucket bootstrap and ownership assertion and Nagare.Ops.ContextGuard's project guard rather than adding new ones. A local-mode context always uses the filesystem store. EP-146's first bootstrap transaction runs locally and moves with EP-151's migrate command. EP-156 runs its production-shaped rehearsal with the GCS store selected.

**Declaration versus native execution — owned by EP-146 for cloud/host/artifact, EP-147 for cluster, consumed by the EP-148 baseline and EP-152–161.** One provider operation may cover multiple declared resources. Pulumi native plans and TypeScript registration mapping remain authoritative for native semantics but must agree with validated membership. Kubernetes/Helm rendering is expanded and retained before mutation. Native plan/config/output changes require a new review, including bounded preparation when a provider cannot preview before a prerequisite exists.

**Shared cluster resources and data builders — owned by EP-147, consumed by the EP-148 baseline and EP-158–161.** Resource/Database.hs emits the entire database bundle, including credentials and backup operations, from the full typed Database value. Namespace/auth/shared configuration owners compose validated consumer contributions. Their effective desired resource digest is the digest of the composed content, so it changes when a contribution's content changes and not when a contributing scope is merely redeployed; neither case changes the owner's base scope revision or platform release. The contribution composers are pure and are dispatched from EP-144's composition phase, because contribution-made declarations such as a registered Namespace must exist before claims are validated. Owner authorization and complete contribution-vector checks prevent arbitrary app writes and lost updates. Credential refreshers and controller children have explicit bounded delegation.

**Lifecycle and observation semantics — owned by EP-149, consumed by EP-146–148 and EP-152–161.** Lifecycle.hs, Migration.hs, Status.hs, and Explain.hs own drift categories, adoption/transfer proofs, retained resources, incarnation-aware migration, and collection decisions. EP-149 validates proposals into LifecycleDecisions against the same CompositionCandidate the planner sees; it does not plan on its own, does not redefine RetirementIntent, and its proposals do not restate what a declaration already fixes. A stable ResourceId can have active/candidate/retained physical incarnations. Every deletion is bound to exact identity/history; restore/schema migration/write admission have explicit data recovery contracts. Existing Replacement/Cutover semantics remain specialized.

**CLI routing and compatibility — initial compile command owned by EP-144, generic command service by EP-145, domain registrations by EP-146–149, fresh platform bootstrap and legacy-upgrade confinement by EP-152; remaining command audit by EP-153.** app/Main.hs and justfile remain shared registration surfaces. Move behavior into named modules, coordinate registrations, and do not reintroduce separate orchestration in these files. Existing version/context/project/cluster guards remain until their authoritative replacements are proven. Preserve old receipts without converting unproven success into new proof. No admitted context may change platform payload version through the coarse upgrade runner.

**Coverage and tests — format owned by EP-146, contributions by EP-147/148 and EP-158–161, completeness owned by EP-153.** docs/architecture/managed-resource-coverage.md records each supported mutation family, owner scope, declaration compiler, executor, test evidence, delegation, and legacy disposition. A child running earlier may create the file using that format; later children preserve its entries. This is a traceability aid, not a second resource authority. Shared Cabal/Spec.hs/Nix test registrations must preserve each other's modules. Pure cases use existing Haskell tests; provider behavior retains focused integration checks.

**Release evidence — owned by EP-157, supplied by all earlier children.** Native tool identities, inventory/review digests, scope revisions, receipts, coverage status, and final observed state are archived under a payload identity and distinct run identity. Global release publication has a dedicated publication owner/context, not whichever deployment first consumes it. Published artifacts are references in consuming contexts. Private secrets/native bundles do not enter public evidence.

EP-157 maintains the already-implemented .github/workflows/release.yml publisher and Nagare.Inventory.Adapters.GitHubRelease. Its narrowly scoped durable publication record lives in the provider draft release: atomically bound intent/review, exact declared assets, a pre-publication verification receipt, and observed publication completion. Ephemeral Actions artifacts are not authoritative history. All authorized same-tag publishers share workflow serialization. This provider protocol does not expand the initial context store into a remote multi-writer service; ordinary context history stays in its private context-selected filesystem or GCS store.

These ownership, identity, review, storage, migration, and controller-delegation decisions belong in ADR 22 and relevant amendments. Each child updates durable decisions when implementation evidence changes them rather than leaving contradictory prose in separate plans.


## Progress

2026-09-27 coordination snapshot: seven children are Complete; EP-148 and EP-150 are Cancelled/superseded with their delivered work preserved. EP-160 M1 is accepted on local k3s, while M2/M3 remain open. EP-153's registration audit passes with 26 library calls, and its installed bootstrap wrapper now publishes a review correctly; M2 and pending coverage remain open. EP-154's bounded installed smoke passed on aarch64 Darwin for revision `2717b386`; its full native/package gates remain open. EP-155's local health fixture is checked in. Its installed producer path advanced through registry creation to a running local cluster, exposing two k3d 5.9 observation mismatches now fixed in source with a passing public bootstrap test and filtered native predicates. Both old candidate transactions remain ambiguous and unaccepted; the next ordered work is a fresh exact local candidate/fixture run, then EP-157 evidence-input agreement. EP-154–159 and EP-161 have no accepted whole milestone recorded. Nine active children remain, with substantial feature work as well as final integration. This is not evidence of 90% release readiness.

**Implementation order, corrected after tracing producer/consumer code (2026-09-27).** Select the next existing milestone/checkpoint from this order; the numerical registry is an ownership list, not an instruction to finish each whole plan in number order. EP-160 M1 is accepted; begin order 2. These checkpoints order existing acceptance work and do not add milestones or waive the rest of a child.

| Order | Work and owner | Prerequisite / handoff that prevents rework |
|---|---|---|
| 1 — active | Finish EP-160 M1 under its six criteria. | Production planning capture, private saved-review replay, real verification, and interruption/release run together. Later restore/maintenance/cloud behavior does not gate this milestone. |
| 2 — before extending features | EP-153 repairs its known registration regression; EP-154 exercises one installed candidate outside the checkout; EP-155 establishes the existing local fixture and health checks; EP-157 agrees the existing scenario/evidence index with EP-155/156. | Use existing scripts and manifests. Prove consumers can load installed resources and record the required identities before lengthy native runs. This is bounded preparation of existing plans, not their final acceptance. |
| 3 — representative recovery path | EP-159 M1 supplies one PostgreSQL scheduled receipt after Job cleanup; EP-160 M2 consumes it in a real restore/content check and proves the authorized engine/process handoff. EP-161 then proves its first PostgreSQL session and surviving-client recovery against that shared contract. | Manual receipts remain usable for initial fence/access work. Confirm the scheduled receipt adapter actually satisfies restore selection and recovery references. Do not finish all backup engines or all restore variants before proving these consumers. |
| 4 — complete recovery outcomes | Complete the remaining EP-159/160/161 assertions by engine: producer format → receipt → real restore/content/recovery → maintenance where applicable. Finish EP-159 pruning with restore/session dependency protection. Finish EP-160 M3's volume path after M1; it need not wait for all database variants. | Before extending each engine, settle its actual producer/consumer format and authorized-process access with a bounded roundtrip. Reuse common state and compatible receipts; preserve separate engine semantics. Partial engine proof does not close a whole milestone. |
| 5 — independent command work | EP-158 access/CDN and EP-153 platform/consumer cutovers. | These may move earlier whenever their inputs are ready, including during a genuine recovery blocker. Update registration and user-facing command proof as each family lands. Full EP-153 coverage waits for feature/native-proof evidence, not the other way around. |
| 6 — final candidate | Finish EP-154 native package gates, EP-155 full local acceptance, EP-156 actual GCP/k3s/GCS acceptance, then EP-157 full non-publishing assembly. | Prepare EP-156's exact resources/access/cleanup review earlier so an unavailable prerequisite is discovered before this stage. Final manifests bind the same candidate. Feature implementation, packaging, and evidence-format changes must precede final proof capture; relevant late fixes invalidate and rerun affected proof. |

EP-155's local assertions grow alongside the feature checkpoints rather than beginning after all implementation. EP-157's schema/negative tests are early; its final acceptance is last. Reuse targeted native evidence only where its recorded inputs and assertions remain applicable. Preserve all final local/cloud/native-system requirements. A commit or test pass is not a stopping boundary when further authorized work is possible.

**Finite remaining outcomes.** These rows coordinate the existing child acceptance; they are not new milestones or units of estimated effort.

| Owner | Remaining accepted outcome | First evidence that resolves the main uncertainty |
|---|---|---|
| EP-160, currently active | M1 shared fence; M2 three-engine scratch/live restore; M3 live-volume restore | Finish M1's saved-review fixture under its six existing criteria. M2 must then demonstrate an authorized recovery process can use the fenced data and verify content. |
| EP-159 | Scheduled receipts survive Job cleanup; exact retention pruning | One scheduled backup → durable receipt → ingestion → actual restore consumer; validate pruning dependencies, then extend by engine. |
| EP-161 | Usable reviewed maintenance and recovery after client/process loss | A real PostgreSQL session can access the fenced engine while a competing client is excluded; prove surviving-client recovery before extending to Redis/ClickHouse. |
| EP-158 | Grant/revoke/portal synchronization and existing CDN purge/disable/retirement | Public saved-review access roundtrip with lost-response recovery; provider proofs retain the agreed Google/Cloudflare division. |
| EP-153 | Platform operations, consumer cutover, and complete command coverage | Repair the named registration regression, then close the exact pending families recorded in EP-153; refusal-only rows remain incomplete. |
| EP-154 | Installed packages on every system in release.json | First installed-package smoke outside the source checkout; later validate every supported system for the candidate. |
| EP-155 | Local convergence/isolation/recovery plus inherited native migration/collection bindings | Run the production scenario early, expose its first failed assertion, and finish that path. Existing feature evidence is reused only for matching assertions and identity. |
| EP-156 | Fresh Compute Engine/NixOS/k3s convergence and GCS recovery | Complete exact cloud preview and prerequisites, then the real supported cloud run. No GKE. |
| EP-157 | Mandatory immutable evidence and full non-publishing release rehearsal | Reject a candidate missing any required evidence input; accept only the final matching package/local/cloud/coverage set. |

**Forecast correction.** Withdraw the parent's 64–132-hour aggregate as a current forecast. It used EP-153's obsolete 6–12-hour range after that child had already revised remaining work to 16–30, and included an EP-160 estimate superseded by its corrected milestone boundary. Other initial child ranges are uncalibrated planning history, not additive delivery promises. The logs do not separate active engineering, compilation, provider waits, and approvals reliably enough for a replacement total. Report the selected acceptance criterion, last newly passing assertion, exact next failure/blocker, and any changed requirement. A new forecast requires measured completion of the above production-path checkpoints; repeating a rolling range is not evidence.

**Execution contract following the failed audit.** Before changing a remaining family, select its existing acceptance assertion and the public command or saved-review fixture that demonstrates it. Connect compilation, private review publication/reload, native execution, verification, and recovery in that fixture first; use focused tests to develop the pieces required by its failures. Batch cohesive changes through that path. Run the affected full acceptance gates at the coherent boundary and repeat them for relevant changes/failures. A documentation-only edit does not invalidate native behavior proof, although final release manifests still need the exact final candidate identity.

Every new finding must name either (a) a failing existing assertion and its owning plan, (b) a missing integration binding under an existing assertion, or (c) a proposed new requirement. Fix (a) and (b) within their owners; obtain an explicit product decision before adding (c). A missing case within a promised engine or command family remains required. Do not silently add providers, command families, generalized security guarantees, or new child plans. Two successive implementation/verification cycles without advancing the selected production path require revisiting that path and the approach before another component-only hardening pass. Report the concrete obstruction; continue other authorized work when possible. Do not replace this rule with another broad audit, repeated reassurance, or an automatic stop after a small commit.

Historical action-by-action parent checkboxes and routine revision notes have been removed from the active coordination document. Their exact record remains in this file at git revision `f79329f0` and in the owning child plans. Completed child milestones, their evidence, and all provenance entries remain credited. The registry and child acceptance outcomes govern status; checkbox ratios must not be used as effort or readiness estimates.


## Surprises & Discoveries

**2026-09-27 — Installed local producer exposed consumer bindings.** EP-154's first installed rehearsal stopped at an obsolete unqualified `deploy --dry-run` fixture, so its bounded smoke now uses the read-only inventory compiler and cannot count as full release evidence. EP-155's first `local-up` found EP-153's wrapper passing an existing directory to review publication; after that fix, a real k3d 5.9 registry create became ambiguous because the artifact observer did not recognize `portMappings["5000/tcp"]`. The next exact candidate advanced through registry observation and created a cluster, then found that k3d's JSON omits the custom digest label present on the exact Docker server container. Both source observations now match the native provider shapes and the focused public test passes. The two old immutable candidates remain deliberately unaccepted test runs; EP-153, EP-154, and EP-155 still need fresh final-candidate proof. No feature requirement changed.

EP-155's third candidate converged its local registry/cluster and context kubeconfig, then exposed the existing encrypted observability Secret and immutable auth image fixture inputs. After those were supplied, host `skopeo` reached macOS AirTunes instead of the fixed k3d registry on port 5000. A native loopback forward into Colima preserved the reviewed controller manifest where Docker load/push did not. The local registry observer and health probe now read the exact registry container, and the saved-review runner binds Nagare's profile name separately from the k3d Kubernetes context. A changed installed candidate correctly refused to reuse the earlier accepted substrate; the next native attempt needs fresh isolated state. No EP-155 milestone or final package gate is credited by these partial results.

The next installed candidate converged a fresh registry, cluster, and context kubeconfig, then advanced the 209-operation cluster review through a retained CRD acknowledgement to MinIO Deployment readiness. The exact MinIO pod is `ImagePullBackOff`: the pinned Quay digest returns 401, as does the checked legacy client image. Upstream release tags exist, but the tested legacy image registries refuse access and the binary download endpoint returns 410. EP-155 retains the ambiguous transaction and needs a reproducible source/image route before local health and the first application/data assertion can pass. The local runner now compares its `local` kubeconfig endpoint and CA to physical `k3d-nagare-local` and binds both names in saved evidence. No new provider or acceptance gate was added; no EP-155 milestone is complete.

EP-155 now has a bounded local replacement route: a script verifies upstream GitHub release asset SHA-256 values for MinIO server/client Linux binaries, builds disposable local images, and observes their exact k3d registry digests. A Docker-network readiness and bucket-creation probe passed, and the component compiler binds only paired exact local image overrides into a fresh review. The old ambiguous transaction remains untouched; the next native attempt must use a new installed candidate and isolated state. EP-159's first producer correction also binds reviewed scheduled backup keys to the Job UID and uses conditional create-only upload; its backup test group passed. Neither child milestone is complete.

The next installed local candidate completed registry, cluster, context kubeconfig, and the 209-operation platform review. Its reviewed MinIO server, bucket Job, and Knative webhook passed readiness. The first application image archive review then stopped ambiguously with the exact registry tag absent: generic OCI publication still addressed macOS AirTunes on port 5000. The source transport now validates the same loopback forward used by the controller publisher and observes the logical registry digest after publication. The old image journal remains retained. EP-155's first application/database and unchanged-replay assertions still require a fresh installed candidate; M1/M2 remain open.

Installed revision `453eebc24a6ddfcea3df90019a4f949d888887b1` then converged a fresh local platform and the reviewed application image publication at the exact source manifest digest. The typed app dry run exposed a real cluster-identity mismatch in accepted foundation Namespace lookup; bootstrap uses `platform:cluster/cluster/cluster`, while the app resolver assumed the foundation scope. The resolver and focused test are corrected. EP-155 must repeat from a new installed candidate and isolated target to prove application/database convergence and unchanged replay; no M1/M2 credit is taken from the platform/image-only result.

Installed revision `23001da4` converged a new six-CPU local platform, an exact reviewed application image, and two independently owned Knative apps with ready retained PostgreSQL StatefulSets. This used an isolated Colima profile because the default four-GiB VM could not schedule the first app; the earlier failed journals remain retained. The corrected disposable HTTP image was run successfully before publication. An unchanged app A replan then exposed a release-history timestamp rewrite despite identical accepted tag and metadata. The compiler now preserves that accepted release record, and its focused native-byte regression passes. EP-155 still needs its full checked-in scenario, so M1/M2 remain open. Continue the ordered EP-159 producer/EP-160 restore/EP-161 maintenance handoff after the bounded first-path check.

Installed revision `e97d65e1` then read-only replanned both accepted app scopes in that six-CPU fixture. Each saved review had seven VerifyResource operations, no writes, and no barriers; both live Knative Services retained their UID, generation, and Ready revision. This finishes the bounded first-path check and permits the ordered EP-159 producer, EP-160 restore, and EP-161 maintenance handoff. EP-155's full checked-in recovery scenario and both milestones remain open.

EP-159's first native PostgreSQL producer probe triggered a disposable Job from the accepted schedule template. Its UID-keyed backup object had an exact MinIO version and remained at the same version after Job cleanup. The test proves upload/readback and object survival, but no delegated receipt or public ingestion exists yet; EP-159 M1 and the EP-160 restore consumer remain open.

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

**Current registration evidence.** At `f79329f0`, running `python3 scripts/audit-managed-commands.py --coverage-result /tmp/nagare-mp23-command-coverage.json` reports 135 registered CLI routes, 34 recipes, 25 registered library calls, 11 pending routes, seven pending recipes, and 30 incomplete catalogue rows. It exits 1 for the unregistered existing `Inventory.planInventoryCandidateWithPayloadIdentity` call in `app/Main.hs`. That file was clean during this inspection, so this is a committed integration regression, not the concurrent EP-160 edit. EP-153 owns the correction and matching audit fixture. Counts overlap command families and proof obligations; they are not 48 independent missing features. The dirty candidate is not release evidence.

**Architecture assessment.** Typed scopes, independent ownership, exact native identity, retained private reviews, and durable recovery have working compiler/store/bootstrap evidence. This inspection found no basis for discarding those foundations. It also cannot certify the whole design from unit or component proof. The weak point was treating native data exclusion and every remaining operation as routine adapter wiring: their lifecycle and authority semantics required concrete design and early end-to-end probes. The failure involves both planning and observed execution behavior. Session metadata identifies repeated `gpt-6-sol` execution, while plan provenance includes multiple authoring models; this is not a controlled model comparison and does not establish that changing a model alone fixes the problem.

Earlier architecture discoveries remain relevant: derived controller claims must participate in collision checks; candidates carry explicit changes and their base revisions; native preparation precedes immutable review; admission grants authority under the store lock; ambiguous effects recover before obsolete preflight checks; lifecycle operations retain exact incarnations; and shared history uses conditional writes. Their decisions remain in Integration Points, the child plans, ADR 22, and this file's history at `f79329f0`. Routine historical “still open” lists are not the current backlog.


## Decision Log

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

EP-144, EP-145, EP-146, EP-147, EP-149, EP-151, and EP-152 are complete. Nine active outcomes EP-153–161 remain required; EP-148 and EP-150 are superseded history with their delivered work preserved. EP-150 delivered a recoverable release publisher, deterministic integration tests, history restoration, evidence projection, and compatibility safeguards; cancelling its umbrella does not erase those implementations. EP-152 adds reviewed fresh platform stages, public recovery, and a focused native marker smoke. Final acceptance still requires IR-24's full verification set, native local/GCP behavior, independent-scope isolation, complete command coverage, clone-free native packages, and immutable evidence. EP-152's focused marker proof is an input to that acceptance, not a substitute for full local and GCP recovery evidence.

At completion, compare these outcomes with IR-24, update its status only with evidence, and distill durable lessons into ADR 22 and affected existing ADRs. Do not publish a release or modify existing operator deployments as a side effect of updating plan status.


## Revision Notes

2026-09-27: Extend diagnosis to every commit/file in the fixed last-24-hour window and correct the whole-plan ordering to exercise producer/consumer contracts before broadening engine coverage; make early package/fixture/evidence preparation explicit.

2026-09-27: Diagnose the stalled execution from original plans, commits, Codex logs, and the current audit. Correct EP-153/160 registry status, withdraw stale forecasts, remove duplicate historical microtask tracking, and require existing production-path assertions to drive work. Make the restore/maintenance handoff explicit in ADR 22 and affected successor plans. EP-160 is concurrently implemented and its file is unchanged by this pass. No feature, supported target, or release evidence requirement is removed; no child is added.

2026-09-27: Prohibit GKE across all children and fix the finite EP-160 M1 boundary without weakening M2/M3 or EP-156 acceptance.

2026-09-26: Split remaining EP-148 and EP-150 obligations into EP-152–161, preserve delivered work and full acceptance, and redirect ownership and dependencies. The initial estimates are historical and are superseded by the forecast correction in Progress.

2026-09-16: Validate and amend the shared API before implementation, then add EP-151 at the operator's decision for conditional shared history. Detailed earlier revision and implementation entries are retained in this file at git revision `f79329f0`; their durable decisions remain above and in ADR 22.
