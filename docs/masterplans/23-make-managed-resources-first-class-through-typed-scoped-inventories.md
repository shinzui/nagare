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
---

# Make managed resources first-class through typed scoped inventories

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable decisions into docs/adr/ in the same change.


## Vision & Scope

Address [IR-24](../improvement-requests/make-managed-resources-first-class.md): an operator can obtain one complete, typed, revision-bound account of Nagare-managed cloud, host, Kubernetes, data, credential, artifact, and release/control resources. Compilation rejects conflicting ownership before mutation. Review exposes creation, adoption, update, replacement, migration, retention, and deletion. Apply executes dependency-aware native operations with durable evidence; resume skips proven completed work. Status explains identity, ownership, dependencies, drift, health, and retirement decisions.

Platform components and applications retain independent desired-state ownership and release cadence. Each scope is one owner's complete declaration with its own revision. The context inventory composes these declarations and validates their shared claims; it is not another independently editable desired-state document. Updating one selected scope preserves every unselected scope. Application deployments can submit authorized contributions to platform-owned routing/configuration, but cannot seize the entire shared object or advance the platform release.

The architectural objective is to reduce policy scripting through a shared Haskell model. Smart constructors, explicit alternatives, typed capability references, and opaque validated/reviewed values enforce structural guarantees. Pure functions validate whole-graph properties. Adapters observe live facts and execute native provider operations. The same declarations produce inventory, review, rendering, and execution inputs. A separate handwritten inventory mirroring existing scripts is not acceptable. Acceptance includes removing superseded orchestration and duplicated guards after their replacement is proven.

Desired state, observed state, and execution history remain separate. Logical IDs survive names and ownership transfers; physical identities identify individual incarnations. Resource membership and policy are known before external mutation. Generated values are constrained typed references, not permission to introduce new resources. Data defaults to retention; unknown observations never imply absence. Credentials are private adapter inputs, absent from public review/evidence representations.

The first implementation runs in the operator CLI with private context-owned state, one writer, immutable snapshots, and a durable journal. Pulumi, NixOS, Kubernetes, Helm, storage, and registry tools retain their native responsibilities. This does not add a daemon, distributed coordinator, new provider engine, automatic foreign-resource adoption, generic schema rollback, or production rollout. It does not complete the separate replacement-upgrade initiative. A later controller can implement the same store/adapter protocol; multi-workstation exclusion requires shared coordination and is not claimed by the filesystem implementation. A cloud context may instead keep that state in its state bucket, beside its Pulumi state. That store refuses a second writer from another machine through conditional writes and needs an explicit operator takeover to resume someone else's work; it still has no lease or liveness detection and is not a distributed coordinator.


## Decomposition Strategy

Eight children separate independently demonstrable concerns, grouped into four phases because the count exceeds seven. Phase 1, the foundation: EP-144 proves declaration and graph correctness without provider access, and EP-145 proves durable review/execution and crash recovery against recording adapters. Phase 2, executors, policy, and the shared store: EP-146 supplies cloud/host/artifact executors; EP-147 supplies cluster composition and executors; EP-149 supplies pure lifecycle policy and explanation; EP-151 implements EP-145's store contract over the context's state bucket so that history and deletion authority are not tied to one workstation. These four can proceed independently after the foundation. Phase 3, application migration: EP-148 combines those interfaces to migrate independent application/data commands. Phase 4, integration: EP-150 proves the shipped platform-wide contract, removes remaining bypasses, and archives release evidence.

This avoids a single large rewrite while preventing a types-only delivery with no behavioral migration. Each adapter plan removes its own duplicate policy paths. The final child owns cross-provider integration, compatibility, and real acceptance, not all feature implementation.

The local ADR corpus was scanned by filename/title and relevant records were read. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates payloads/private workspaces; [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) preserves operator host identity; [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) defines release/version transaction semantics; [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) binds immutable release evidence; [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) confines cloud writes; [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) preserves self-reversion; [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) protects forward-only storage growth; [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) protects private operator/state material; [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) guards protected replacements; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) governs Haskell style; [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds native review and receipts; [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) protects irreversible cutover; [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) separates route/TLS ownership; and [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) defines cache retention and trust boundaries.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) records the accepted architecture from this discussion; it is a design decision, not a claim of implementation. Mori searches found no relevant cross-repository ADR to import. The local mori.dhall and mori show --full do not declare docs/adr as a profiled bundle, so the existing ADR filename/frontmatter convention is preserved. Dependency APIs must be researched through Mori during implementation and current upstream releases checked before changing bounds; this plan prescribes no dependency upgrades.

Rejected alternatives were isolated platform/application inventories without shared conflict checks; one global release coupling all applications to platform upgrades; a manually maintained resource list beside imperative scripts; replacing native reconcilers; and an always-on control plane before the operator-driven protocol is proven.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 144 | Define typed resource scopes and validate composed inventories | docs/plans/144-define-typed-resource-scopes-and-validate-composed-inventories.md | None | None | Complete |
| 145 | Persist reviewed resource plans and resumable execution receipts | docs/plans/145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md | EP-144 | None | Complete |
| 146 | Reconcile cloud host and artifact resources through inventory adapters | docs/plans/146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md | EP-144, EP-145 | EP-149 | Complete |
| 147 | Compile cluster bootstrap into owned resource components | docs/plans/147-compile-cluster-bootstrap-into-owned-resource-components.md | EP-144, EP-145 | EP-146, EP-149 | Complete |
| 148 | Route application and data lifecycles through independent resource scopes | docs/plans/148-route-application-and-data-lifecycles-through-independent-resource-scopes.md | EP-146, EP-147, EP-149 | EP-151 | In Progress |
| 149 | Explain drift and execute reviewed adoption migration and retirement | docs/plans/149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md | EP-144, EP-145 | EP-146, EP-147 | Complete |
| 150 | Integrate resource inventories into upgrades and release verification | docs/plans/150-integrate-resource-inventories-into-upgrades-and-release-verification.md | EP-146, EP-147, EP-148, EP-149, EP-151 | None | Not Started |
| 151 | Store inventory history in the context state bucket with conditional writes | docs/plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md | EP-145 | EP-146 | Complete |

Hard dependencies must be Complete before starting the dependent child; soft dependencies supply additional real-adapter coverage but allow independent fixture-backed work. Registry status values are Not Started, In Progress, Complete, or Cancelled.


## Dependency Graph

EP-144 must complete first because all later work consumes its identity, declaration, wire, and validation contracts. EP-145 then defines the one authoritative store, review boundary, journal, and adapter protocol.

EP-146, EP-147, EP-149, and EP-151 may proceed after EP-145. EP-151 needs only EP-145's store contract, conformance suite, and head format; its soft dependency on EP-146 is the handoff of a new context's first bootstrap transaction, which necessarily runs on the local store because the state bucket does not exist yet. Cloud and cluster builders test against declared typed outputs without needing each other's live executors. Lifecycle policy tests against recording adapters without claiming native behavior. Their integration dependency is that every adapter exposes identity/precondition/verification capabilities required by lifecycle policy; reconcile that contract before any real adoption/migration/retirement is enabled. Until then these actions refuse explicitly, while fresh-resource/convergent operations remain independently verifiable.

EP-148 requires the native publication/cloud and cluster adapters plus lifecycle policy because application deploys cross all three: they publish artifacts, create cluster/data resources, contribute to shared configuration, and retire owned objects. EP-151 is a soft dependency of EP-148 with one hard edge inside it: EP-148 may build and test everything without the shared store, but its final milestone must not remove the last legacy application-deploy path until EP-151 is Complete, because from then on a deploy needs the inventory store and a local store exists on one machine only. EP-150 needs the complete migrated command set, all real adapters, and the shared store to prove context-wide completeness and release recovery.

The implementation waves are therefore EP-144; EP-145; EP-146/147/149/151; EP-148; EP-150. Numerical order is not execution order. The earlier replacement MasterPlan 21 remains independent: preserve its safety core and add bindings, but do not silently change its registry, assume unfinished adapters exist, or make this initiative depend on completing its live cutover project.


## Integration Points

**Typed domain contract — owned by EP-144, consumed by every child.** cli/nagare-dsl/src/Nagare/Resource/{Types,Reference,Policy,Inventory,Compile,Wire}.hs and schemas/resource-inventory-v1.json define stable ContextId/ScopeId/ResourceId, provider claims/aliases, physical identity, typed exports, owner contributions/delegation, lifecycle/data/sensitivity policy, and deterministic serialization. New provider kinds extend this contract explicitly. Do not derive Generic, public setters, unchecked FromJSON, or coercible phantom roles for any type whose constructor is hidden, identity newtypes included.

EP-144 also owns the types the builders return and the planner consumes: ScopeDeclaration, ResourceBundle, DeclaredOperation, RetirementIntent, the closed contribution-kind dispatch, and the per-kind claim function. They live in nagare-dsl because nagarectl depends on it and not the reverse. composeInventory is the only route to a ValidatedInventory and returns a CompositionCandidate: the desired inventory, the base generation vector, and the explicit replace/retire changes. There is no decoder from bytes to a validated inventory; the wire form is one canonical document per scope plus a manifest, and a loader composes again. A ScopeSnapshot carries every accepted scope's full declaration and the claims still reserved by retained incarnations, candidate incarnations, and unresolved transactions. A claim set includes derived reservations for the deterministically named children of a controller. ResourceId is minted from a stable logical key, never from the provider name.

Digests identify content; revisions identify history. nagare-dsl neither computes nor stores a digest of inline content, and nagarectl derives every digest in one module. A scope revision is a purely derived generation plus that digest. No revision enters a desired digest or provider metadata, including the effective digest of a shared resource, which follows its composed content.

**State, review, and operation protocol — owned by EP-145, consumed by EP-146–150.** cli/nagarectl/src/Nagare/Inventory/{Store,Plan,Journal,Execute,Adapter}.hs owns desired/converged heads, complete scope revision vectors, historical/retained incarnations, review bundles, operation identity, adapter capabilities, completion/recovery states, and writer locking. All persistent state stays outside payload workspaces. EP-149 adds lifecycle decisions through this interface; adapters cannot write their own scope heads.

The pipeline is compile, observationRequirements, observe, planChanges, prepareReview, publish the bundle by digest, verifyReview, then admit and execute under the process lock. planChanges is the single pure planner and takes opaque LifecycleDecisions; EP-145 exports only the empty value and EP-149 builds the rest. prepareReview calls each adapter's prepare method to produce the retained native bundle, so adapters implement observe, prepare, preflight, execute, verify, and recover. A ReviewedPlan is evidence against a snapshot read outside the lock; only admit, under the lock, yields the ExecutablePlan that authorizes effects, and its type is scoped to that lock. Refusal is an error; every admitted outcome is a TransactionResult naming its transaction. The store is specified as conditional writes (publish-if-absent, append-at-sequence, replace-head-if-generation-matches) and the transaction suite runs against an in-memory store with only those semantics, so the filesystem implementation is replaceable. Adapters never call back into a command that takes the context lock.

**Store selection and the state bucket — owned by EP-151, with the contract owned by EP-145; touches EP-146 and EP-150.** EP-151 adds cli/nagarectl/src/Nagare/Inventory/Store/{ObjectOps,Object,Open}.hs, the `NAGARE_INVENTORY_STORE` and `NAGARE_INVENTORY_STORE_URL` context fields in Target.hs and scripts/lib/target.sh, and `nagarectl inventory store status|migrate`. It implements EP-145's InventoryStore unchanged and passes EP-145's transaction suite; it does not alter the head, journal, or member formats. EP-145 defines the executor claim in the head manifest that EP-151 uses to refuse a second machine. The store defaults to a sibling prefix of the Pulumi state in the same bucket and reuses Nagare.Ops.PulumiBackend's bucket bootstrap and ownership assertion and Nagare.Ops.ContextGuard's project guard rather than adding new ones. A local-mode context always uses the filesystem store. EP-146's first bootstrap transaction runs locally and moves with EP-151's migrate command. EP-150 runs its production-shaped rehearsal with the GCS store selected.

**Declaration versus native execution — owned by EP-146 for cloud/host/artifact, EP-147 for cluster, consumed by EP-148/150.** One provider operation may cover multiple declared resources. Pulumi native plans and TypeScript registration mapping remain authoritative for native semantics but must agree with validated membership. Kubernetes/Helm rendering is expanded and retained before mutation. Native plan/config/output changes require a new review, including bounded preparation when a provider cannot preview before a prerequisite exists.

**Shared cluster resources and data builders — owned by EP-147, consumed by EP-148.** Resource/Database.hs emits the entire database bundle, including credentials and backup operations, from the full typed Database value. Namespace/auth/shared configuration owners compose validated consumer contributions. Their effective desired resource digest is the digest of the composed content, so it changes when a contribution's content changes and not when a contributing scope is merely redeployed; neither case changes the owner's base scope revision or platform release. The contribution composers are pure and are dispatched from EP-144's composition phase, because contribution-made declarations such as a registered Namespace must exist before claims are validated. Owner authorization and complete contribution-vector checks prevent arbitrary app writes and lost updates. Credential refreshers and controller children have explicit bounded delegation.

**Lifecycle and observation semantics — owned by EP-149, consumed by EP-146–148/150.** Lifecycle.hs, Migration.hs, Status.hs, and Explain.hs own drift categories, adoption/transfer proofs, retained resources, incarnation-aware migration, and collection decisions. EP-149 validates proposals into LifecycleDecisions against the same CompositionCandidate the planner sees; it does not plan on its own, does not redefine RetirementIntent, and its proposals do not restate what a declaration already fixes. A stable ResourceId can have active/candidate/retained physical incarnations. Every deletion is bound to exact identity/history; restore/schema migration/write admission have explicit data recovery contracts. Existing Replacement/Cutover semantics remain specialized.

**CLI routing and compatibility — initial compile command owned by EP-144, generic command service by EP-145, domain registrations by EP-146–149, final upgrade integration by EP-150.** app/Main.hs and justfile remain shared registration surfaces. Move behavior into named modules, coordinate registrations, and do not reintroduce separate orchestration in these files. Existing version/context/project/cluster guards remain until their authoritative replacements are proven. Preserve old receipts without converting unproven success into new proof.

**Coverage and tests — format owned by EP-146, contributions by EP-147/148, completeness owned by EP-150.** docs/architecture/managed-resource-coverage.md records each supported mutation family, owner scope, declaration compiler, executor, test evidence, delegation, and legacy disposition. A child running earlier may create the file using that format; later children preserve its entries. This is a traceability aid, not a second resource authority. Shared Cabal/Spec.hs/Nix test registrations must preserve each other's modules. Pure cases use existing Haskell tests; provider behavior retains focused integration checks.

**Release evidence — owned by EP-150, supplied by all earlier children.** Native tool identities, inventory/review digests, scope revisions, receipts, coverage status, and final observed state are archived under a payload identity and distinct run identity. Global release publication has a dedicated publication owner/context, not whichever deployment first consumes it. Published artifacts are references in consuming contexts. Private secrets/native bundles do not enter public evidence.

EP-150 also owns the actual .github/workflows/release.yml publisher and Nagare.Inventory.Adapters.GitHubRelease. Its narrowly scoped durable publication record lives in the provider draft release: atomically bound intent/review, exact declared assets, a pre-publication verification receipt, and observed publication completion. Ephemeral Actions artifacts are not authoritative history. All authorized same-tag publishers share workflow serialization. This provider protocol does not expand the initial context store into a remote multi-writer service; ordinary context history remains private filesystem state.

These ownership, identity, review, storage, migration, and controller-delegation decisions belong in ADR 22 and relevant amendments. Each child updates durable decisions when implementation evidence changes them rather than leaving contradictory prose in separate plans.


## Progress

- [x] (2026-09-22) EP-144 M1: Typed identities, policies, references, and opaque boundaries.
- [x] (2026-09-22) EP-144 M2: Deterministic composition and wire validation.
- [x] (2026-09-22) EP-144 M3: Read-only compiler and structural/collision fixtures; 424 DSL tests, 580 CLI tests, 23 negative API fixtures, schema/style checks, and provider-free CLI acceptance pass.
- [x] (2026-09-22) EP-145 M1: Durable independent scope state and identity.
- [x] (2026-09-22) EP-145 M2: Reviewed operation plans and exact binding.
- [x] (2026-09-22) EP-145 M3: Journal, recovery, locking, and head consistency.
- [x] (2026-09-22) EP-145 M4: Commands, backup/restore, and crash tests.
- [x] (2026-09-22) EP-146 M1: Cloud declarations/native registration parity and exact Pulumi saved-plan binding.
- [x] (2026-09-22) EP-146 M2: Guarded host receipts, physical identity, committed closure, and fresh-login acknowledgement.
- [x] (2026-09-22) EP-146 M3: Artifact/bootstrap/control resources, digest verification, and bounded publication review barriers.
- [x] (2026-09-22) EP-146 M4: Production domain registration, confined transports, and compatibility handoff to EP-150.
- [x] (2026-09-22) EP-147 M1a: Structured Kubernetes objects compile to typed declarations; rendered database/Knative collision fixture passes.
- [x] (2026-09-22) EP-147 M1b partial: Multi-document YAML and Kubernetes List items expand before claim validation with source-member diagnostics; 430 DSL tests pass.
- [x] (2026-09-22) EP-147 M1b partial: Canonical native JSON bytes are checked against declaration digests; 610 CLI tests pass.
- [x] (2026-09-22) EP-147 M1b partial: Private adapter plans retain native bytes and observation preconditions; recording transport tests pass (614 CLI tests).
- [x] (2026-09-22) EP-147 M1b partial: Apply constructs adapters from the verified store-backed review rather than the public directory; private native members remain absent from public output.
- [x] (2026-09-22) EP-147 M1b transport probe: Disposable k3d ConfigMap checks ruled out server-side apply with resourceVersion zero as create-only and proved atomic stale-write refusal with JSON Patch UID/resourceVersion tests.
- [x] (2026-09-22) EP-147 M1b partial: Packaged source binding, immutable private review reconstruction, explicit-context kubectl runtime, and CLI registration; a disposable ConfigMap create completed and verified.
- [x] (2026-09-22) EP-147 M1b partial: A disposable ConfigMap completed reviewed create and update; update checks live field managers before a UID/resourceVersion-bound write.
- [x] (2026-09-22) EP-147 M1b partial: The disposable native transport refused both stale-version and foreign-manager update attempts after a concurrent annotation write.
- [x] (2026-09-22) EP-147 M1b partial: A disposable Service selector update succeeded; an unnamed Service port change exposed a per-kind server-side apply validation case, addressed by the guarded patch below.
- [x] (2026-09-22) EP-147 M1b partial: An atomic UID/resourceVersion-tested JSON Patch now handles the isolated unnamed Service port change; disposable create, selector update, and port update pass.
- [x] (2026-09-23) EP-147 M1b: The registered bootstrap command refuses stale resource versions and foreign owners before mutation; disposable per-kind update fixtures and replaced-UID refusal cover the admitted Kubernetes kinds.
- [x] (2026-09-22) EP-147 M2a: Database Secret read distinguishes confirmed absence from failure/malformed data.
- [x] (2026-09-22) EP-147 M2b: Database config carries an optional stable logical key across rename and wire round-trip.
- [x] (2026-09-22) EP-147 M2c partial: Direct database renderer objects compile into stable typed PVC/Service/StatefulSet/optional ConfigMap declarations and canonical native bytes; 431 DSL and 616 CLI tests pass.
- [x] (2026-09-22) EP-147 M2c partial: The database bundle includes a password-free credential Secret template, created only after guarded execution; a disposable PostgreSQL Secret create and verification pass.
- [x] (2026-09-22) EP-147 M2c partial: Backend-specific backup CronJob rendering is bound into the same database bundle with stable identity and dependencies; real renderer parity and wrong-address refusal pass.
- [x] (2026-09-22) EP-147 M2c partial: Explicit throwaway database retention compiles to collectable stateless resources with no scheduled backup; retained PVC and credential keep recovery intent.
- [x] (2026-09-22) EP-147 M2c partial: Disposable Kubernetes execution creates and verifies the generated Secret and backend-rendered backup CronJob as reviewed native members.
- [x] (2026-09-22) EP-147 M2c partial: A disposable five-member database bundle converges in one reviewed transaction; after a simulated lost StatefulSet acknowledgement, resume proves completion and creates the backup without recreating the credential or StatefulSet. Shared transaction preflight now defers ambiguous effects to adapter recovery.
- [x] (2026-09-22) EP-147 M2c partial: Apply/resume reconstructs the complete database native map from private review evidence before executing the disposable transaction.
- [x] (2026-09-22) EP-147 M2c partial: Cache signing keys now have a distinct typed capability and scope-wire witness; logical cache execution remains open.
- [x] (2026-09-22) EP-147 M2c partial: Logical Attic caches have a distinct provider address, desired spec, and executor; the command registry refuses native execution until the cache adapter is installed.
- [x] (2026-09-22) EP-147 M3 partial: Pinned upstream direct members have ordered CRD, workload, and inter-release prerequisites; reviewed Kubernetes execution waits for CRD establishment and current-generation Deployment availability. CLI regression suite passes.
- [x] (2026-09-22) EP-147 M3 partial: A single production pinned-upstream constructor composes the full foundation and four release scopes with exact native membership; the public bootstrap route and context-specific components remain open.
- [x] (2026-09-22) EP-147 M3 partial: The pinned foundation/cache/four-release candidate composes as six scopes without direct claim conflicts.
- [x] (2026-09-22) EP-147 M3 partial: Packaged Knative cloud/local ConfigMap policy and resolved domain/registry settings bind into owned upstream native bytes before review; source and overlay refusal fixtures pass.
- [x] (2026-09-22) EP-147 M3 partial: Pinned cloud DNS-01 and local CA issuer resources compile as a sixth foundation/upstream scope with certificate-chain ordering and Ready-condition verification.
- [x] (2026-09-22) EP-147 M3 partial: Auth manifests, generated-key Secret templates, revision-named migration proofs, and both typed databases compose as one auth scope after the pinned cluster scopes; the public auth installers and shared backend-map routing remain open.
- [x] (2026-09-22) EP-147 M3/M4 partial: Public bootstrap planning includes digest-addressed auth and both databases; local mode adds the pinned MinIO scope and orders auth after bucket preparation. Full CLI tests pass. Image publication, shared contributions, and live convergence remain open.
- [x] (2026-09-22) EP-147 M4 partial: Complete cloud and local bootstrap fixtures compose issuer/upstream, auth, observability, and cache publication or MinIO without claim conflicts; production command and resume parity remain open.
- [x] (2026-09-22) EP-147 M1b partial: A disposable shared transaction refuses a foreign ConfigMap created after review publication and leaves it untouched; broad update admission remains open.
- [x] (2026-09-22) EP-147 M3 partial: The patched net-certmanager controller Deployment binds a required immutable image reference into reviewed native bytes; archive publication and provenance proof remain open.
- [x] (2026-09-22) EP-147 M3/M4 partial: The released patched-controller archive and OCI digest now compile to an owned publication scope that gates the reviewed Deployment; guarded cloud/local transport checks both digests. Live publication remains open.
- [x] (2026-09-22) EP-147 M3 transport proof: A disposable local registry received a synthetic reviewed controller image; changed archive bytes refused before mutation. Released-archive and cloud publication evidence remain open.
- [x] (2026-09-22) EP-147 M3/M4 partial: Observability's direct VM scrape/rule and Grafana ConfigMaps join the reviewed candidate; context-owned encrypted Grafana/Alertmanager Secrets are decrypted and validated before review, with the metrics release ordered after them. Live convergence remains open.
- [x] (2026-09-22) EP-147 M3 partial: Reviewed local MinIO Secrets use a generated primary and guarded namespace copy; fixed legacy manifest credentials are excluded from the inventory review. Legacy recipe replacement and live convergence remain open.
- [x] (2026-09-22) EP-147 M1b partial: Kubernetes updates now refuse unproved kinds before a write; the conditional runtime admits seven kinds with disposable update evidence, including Deployment with an exact controller annotation exception. Broader native update coverage remains open.
- [x] (2026-09-22) EP-147 M1b partial: A disposable shared transaction refused a reviewed ConfigMap update after its resourceVersion changed, preserving the concurrent live fields. CLI subprocess coverage remains open.
- [x] (2026-09-22) EP-147 M1b/M3 partial: Private observability Secret input is normalized for Kubernetes verification; disposable create/update evidence admits plain Secret updates while generated credential templates remain data-preserving and update-refusing.
- [x] (2026-09-22) EP-147 M3 partial: A disposable Helm create and upgrade verify an actual changed rendered ConfigMap through the reviewed postrenderer boundary.
- [x] (2026-09-22) EP-147 M1b partial: Disposable ResourceQuota and NetworkPolicy updates extend the conditional Kubernetes update allowlist to ten proved direct kinds.
- [x] (2026-09-22) EP-147 M3 partial: Helm 4 capture/verify post-renderer plugins prove exact native render binding and reject a nondeterministic chart before resource changes; release declarations and chart pinning remain open.
- [x] (2026-09-22) EP-147 M3/M4 partial: The public bootstrap planner published a 17-scope, 209-operation review against an isolated k3d context with real installed Attic/controller archives and fixture credentials/images. The released controller image published through the typed transport to a disposable registry; changed archive bytes refused. Cloud and local full-composition fixtures gate the platform marker on every operation, and the cloud recording transaction resumes after a lost migration acknowledgement. Native full-bootstrap apply, shared contributions, and recipe retirement remain open.
- [x] (2026-09-22) EP-147 M2/M4 partial: Planning now refuses a new review over an unresolved transaction, retains unchanged migration proof after Job TTL expiry, repairs confirmed missing accepted stateless resources, and refuses automatic recreation of missing durable data. Kubernetes and Helm observations report drift and foreign ownership. Complete bootstrap replay schedules read-only native checks of accepted cluster resources and gates the unchanged marker on them; 688 CLI tests pass. Database-specific ambiguous migration recovery, native full-bootstrap apply, and legacy entry-point retirement remain open.
- [x] (2026-09-23) EP-147 M3/M4 disposable proof: The full local bootstrap converged in an isolated k3d context from a 17-scope, 208-operation immutable review, using the installed 0.4.0 payload archives and the selected local auth images. A subsequent 205-operation accepted-state review scheduled zero resource updates and converged with 204 read-only checks plus idempotent controller-image publication. Certificate/issuer, webhook, Shomei key, and status-only HPA replay failures exposed by this run are corrected with focused regressions.
- [x] (2026-09-23) EP-147 M4 partial: The last direct public Attic image publication recipe now uses the reviewed bootstrap runner. Its low-level publisher requires the artifact-child marker and exact reviewed destination and archive digests; the transport guard test passes.
- [x] (2026-09-23) EP-149 M1 partial: Read-only inventory status reconstructs accepted native evidence and observes all six registered executors. The disposable 17-scope bootstrap reports all 205 accepted resources converged, zero unavailable providers, and no active transaction; an absent store is never initialized by status. Historical retention and separate health remain open.
- [x] (2026-09-23) EP-151 M1/M2 partial: Generation-conditional GCS object operations and a context-bound object-store backend pass the existing store condition fixture over a shared fake, including stale cross-client head refusal and unreadable-list refusal. The `labs` probe dry run is prepared; live GCS semantics and full transaction conformance remain open.
- [x] (2026-09-23) EP-151 M2/M3/M4 partial: Context fields and guarded GCS opening, a per-state-root client identity and local process lock, explicit takeover with a pre-effect claim check, and two-way verified migration with source tombstones pass the focused object-store fixtures. Status, the bounded live probe, a gated real-bucket test, and a two-state-root rehearsal have dry-run or fixture coverage; the live cloud steps await the plan's operator go-ahead.
- [x] (2026-09-23) EP-151 M1 live probe: The operator approved a one-object GCS probe under the `labs` inventory-probe prefix. Generation-zero create and observed-generation replacement succeeded; duplicate create and stale replacement failed; listing and read-back confirmed `second`. Conditional copies took 2.699–2.893 seconds. The object and versions remain at the unique review prefix recorded in EP-151. The `gcloud storage` transport decision is recorded there; the gated conformance and two-root rehearsal remain open.
- [x] (2026-09-23) EP-149 M2/M4 disposable transfer: A reviewed cross-scope ConfigMap handoff emitted only `VerifyResource` and resumed to a converged destination with its UID, data, and ResourceId intact. The rehearsal exposed and fixed an active-head decoding invariant that rejected the old converged scope while the new scope was accepted. The exact disposable ConfigMap was removed after verification.
- [x] (2026-09-23) EP-151 M4 live: The gated real-bucket store contract passed in 73.43 seconds under a unique `labs` inventory child. An isolated, reviewed empty-scope history then migrated to another unique child; after a duplicate-name listing fix, interrupted migration resumed and a fresh second state/cache root matched head digest `5fa2e88e3f22c83ece53f81b2eb32ad41c8dfac47fe8f0a928068d9b1f7a8417` and exact exported members. The ordinary `labs` state and context config were untouched. Both cloud prefixes remain for review; EP-151 records them.
- [x] (2026-09-23) EP-147 M3/M4 partial: Admission now has a regression fixture for concurrent no-op Namespace contributor reviews; the later one refuses on a stale accepted vector. The standalone `platform stamp` mutation bypass now refuses and directs operators to reviewed bootstrap plan/apply; its built CLI refusal was checked. Explicit legacy adoption and upgrade paths remain to be migrated.
- [x] (2026-09-23) EP-149 M2 transfer hardening: A scope handoff now requires the Kubernetes provider and an unchanged native resource contract, including address, specification, policy, and dependencies. A changed spec refuses before review; provider-specific transfer capability remains required for other executors.
- [x] (2026-09-23) EP-149 M1/M2 partial: Status validates the committed journal and reports sanitized active-operation recovery state; explain traces transitive dependencies to declarations and owners. Generic adoption validation refuses a stamped object without accepted history even for direct planner callers. The 735-test CLI suite, executable build, and Haskell style checks pass. Retained history, provider-specific health, and remaining lifecycle commands remain open.
- [x] (2026-09-23) EP-149 M3/M4 partial: Reviewed `inventory retire` now retains directly declared Kubernetes incarnations under their old immutable scope revision. Admission reobserves exact UIDs under the writer lock, then atomically records retained history and reserves its claims. Status and explain expose the retained catalogue; a changed UID, forged reservation-free candidate, and silent reactivation refuse. The 736-test CLI suite and 443-test DSL suite pass. Collection, migration, other-provider retirement, and generic recovery remain open.
- [x] (2026-09-23) EP-149 M1/M3 partial: Status now observes retained Kubernetes objects using native bytes from their original immutable accepted review, distinguishing the retained UID from a replacement, absence, or unknown provider response. These read-only findings do not authorize collection.
- [x] (2026-09-23) EP-149 M3 guard: Planning and admission refuse retirement that would drop an observed controller child's claim. A focused fixture proves the refusal; retained child history remains open.
- [x] (2026-09-23) EP-149 M1/M3 evidence: A recording Kubernetes adapter proves that an applied retirement preserves the original immutable review's native member for later read-only observation, without another provider mutation.
- [x] (2026-09-23) EP-149 M1 partial: Explain reports consumers from active and retained declarations and traces retained prerequisites to their historical owner/source; a two-resource fixture proves dependency visibility after both resources leave the accepted scope vector.
- [x] (2026-09-23) EP-149 M3/M4 partial: Read-only `inventory gc --plan` screens retained entries for collection blockers and labels candidates without authorizing deletion. The retained-consumer fixture passes; execution and tombstones remain open.
- [x] (2026-09-23) EP-149 M3/M4 narrow collection route: A reviewed `CollectRetained` transaction conditionally deletes only stateless namespaced ConfigMaps with exact UID/resourceVersion preconditions, verifies absence, records a review-bound tombstone, and blocks logical-ID reuse. Recording and disposable native tests pass; durable and broader-provider collection and migration remain open.
- [x] (2026-09-24) EP-149/148 collection extension: Stateless namespaced Services and CronJobs share the reviewed exact-UID deletion and tombstone protocol. Disposable cluster create/collect and stale-resourceVersion refusal checks pass for both. StatefulSet and durable data collection remain unsupported.
- [x] (2026-09-24) EP-149 collection review accepts several distinct retained resource IDs in one immutable candidate, preserving each member's independent preconditions and tombstone.
- [x] (2026-09-23) EP-149 M4 partial: `inventory recover` records an operator-selected action only after the issued adapter proves completion or safe retry for the active uncertain operation. Strict decision input, review binding, and journal replay tests pass; unresolved effects remain blocked.
- [x] (2026-09-23) EP-149 M1 partial: Status reports controller-condition health for supported Kubernetes kinds after a second read confirms the observed UID. The full 743-test CLI suite passes; other provider condition probes remain open.
- [x] (2026-09-23) EP-149 M3 collection screening: GC assessment, lifecycle validation, and native preparation now share the proved conditional-delete kind rule, so unsupported resources receive a blocker before review. The 150 focused inventory tests and style check pass; broader collection and migration remain open.
- [x] (2026-09-24) EP-149 M1 partial: Status exposes read-only collection assessments and retained explain exposes aliases, required conditions, delegation, policies, and source; the CLI builds. Replacement classification and broader provider coverage remain open.
- [x] (2026-09-24) EP-149 M1 replacement boundary: Shared observations distinguish immutable replacement from ordinary drift, and planning refuses an ordinary update. The 150 focused inventory tests pass; adapters do not yet classify concrete immutable provider changes.
- [x] (2026-09-24) EP-149 M1 Kubernetes replacement classification: The production observer identifies an explicit changed Deployment selector as immutable and reports replacement required while preserving ownership categories. Focused Deployment tests and style checks pass. Other provider fields and reviewed migration remain open.
- [x] (2026-09-24) EP-149 M1 StatefulSet replacement classification: The production observer identifies changes to four explicit immutable StatefulSet fields and refuses an ordinary update. Focused tests and style checks pass; reviewed migration remains open.
- [x] (2026-09-24) EP-149 M1 condition separation: Existing Kubernetes objects with unready controller conditions retain ownership and configuration findings in status, while execution verification continues to require readiness. A focused Job fixture passes; EP-149 remains in progress.
- [x] (2026-09-24) EP-149 M1 StatefulSet health: UID-bound status probes report readiness from current generation and ready/updated replica counts; execution waits for rollout and verifies again. Other provider health remains open.
- [x] (2026-09-24) EP-149 M3 Helm retention: Reviewed scope retirement now retains an exact stamped Helm release UID without mutating the provider. Planning and admission use historical native evidence; the recording fixture and executable build pass.
- [x] (2026-09-23) EP-147/149 follow-up: Bootstrap component guides now use reviewed plan/apply and pinned inputs. Status reports health independently of configuration and refuses a report when the accepted head changes during provider observation.
- [x] (2026-09-23) EP-147 M2c: Complete cache/database bundles execute through reviewed bootstrap; EP-148 owns standalone and application database command migration.
- [x] (2026-09-23) EP-147 M3: Cloud/local components, owner-composed auth settings, foundation Namespace/certificate policy, and bounded host timer credential delegation are recorded and validated.
- [x] (2026-09-23) EP-147 M4: Supported bootstrap orchestration enters reviewed inventory; the disposable full bootstrap and accepted replay converged.
- [x] (2026-09-24) EP-149 M1: Read-only drift, status, explanation, retained findings, provider coverage, controller health, and recovery visibility; the full 750-test CLI suite and executable build pass.
- [x] (2026-09-24) EP-149 M2: Versioned per-resource adoption, known-owner Kubernetes/Helm transfer, and explicit legacy platform-version adoption boundary.
- [x] (2026-09-24) EP-149 M3: Provider-independent reviewed dual-incarnation migration graph, retained history and claims, conservative collection, and recording data/recovery proofs. Native migration stages and broader deletion remain for provider/integration work.
- [x] (2026-09-24) EP-149 M4: Lifecycle commands, normal recording-adapter migration review publication, status/explain and recovery fixtures, and operator examples. All 762 nagarectl tests pass.
- [x] (2026-09-23) EP-151 M1: Bounded live GCS conditional-write probe and transport decision.
- [x] (2026-09-23) EP-151 M2: Object-backed store passed the shared conformance suite against fake and real GCS operations.
- [x] (2026-09-23) EP-151 M3: Context selection, guarded opening, and resumable migration.
- [x] (2026-09-23) EP-151 M4: Live two-state-root migration, documentation, and ADR 13/22 amendments.
EP-148 implementation evidence is in its child plan and commits. Its four milestones remain open; partial slices are not counted as completed milestones.
- [ ] EP-148 M1: Complete application/data scopes.
- [ ] EP-148 M2: Shared contributions, env/secret intent, and publication.
- [ ] EP-148 M3: Operational/data command coverage.
- [ ] EP-148 M4: Removed alternate paths and scope isolation.
- [ ] EP-150 M1: Platform/legacy transaction integration.
- [ ] EP-150 M2: Packaging and complete mutation audit.
- [ ] EP-150 M3: Deterministic and real disposable-context proof.
- [ ] EP-150 M4: Immutable release evidence, docs, and ADR distillation.


## Surprises & Discoveries

2026-09-24: EP-148 can wrap EP-147's complete database builder directly for standalone and application-owned database members: the canonical credential and backup already exist and need no second renderer. Application preview now shows those two missing members without secret data, while live deploy remains outside inventory admission. EP-148 M1 therefore stays open, and EP-150 remains gated.

2026-09-24: EP-148's supported application declaration now composes database, service, worker, and task members from exact native bytes, but access/CDN contributions, broker topics/bindings, supplied TLS, hook effects, and command routing remain open. The compiler refuses unsupported intent; legacy public commands remain active. EP-148 M1 and EP-150 remain open.

2026-09-24: EP-149's single-valued ordinary observation and adapter registries cannot represent a migrated source and destination under one ResourceId. Separate paired observations, a canonical migration review marker, and disjoint retained claims now carry the generic contract. EP-148 and EP-150 must use the two-incarnation path for address/executor changes and must not infer adoption or deletion from a provider stamp or missing declaration. Production migration stage verification remains their adapter/integration responsibility.

2026-09-23: EP-149 found that the operator adoption DTO required an unowned observation but the lower-level lifecycle validator still accepted stamped present/drifted resources without accepted history. The validator and planner now refuse those resources. EP-148 must use the versioned proposal path and cannot treat provider stamps as recovered ownership authority.

2026-09-23: Closing EP-147 required distinguishing its reviewed bootstrap path from standalone and application data commands. The latter still call direct `db create` and are recorded as legacy in the mutation coverage audit; EP-148 explicitly consumes EP-147's completed database builder and owns those command paths. Host registry and forge timers remain the narrow authority for rotating values. Their guarded refresh now refuses foreign or unmarked Secrets, which means operators must verify and annotate preexisting timer-created Secrets before the first updated host activation.

2026-09-23: The installed Nagare release payload supplied the Attic and patched net-certmanager archives missing from the source checkout. Full disposable local bootstrap and accepted-state replay now converge. The same run showed why read-only verification must bind physical identity, owner, and desired digest without treating controller-only resourceVersion churn as a desired change. EP-147 still owns legacy entry-point retirement, remaining shared contributions, and broad per-kind update proof; this evidence does not complete EP-147 or the MasterPlan.

2026-09-22: The first complete database-bundle transaction exposed a shared resume bug in EP-145: preflight rejected an ambiguous create because the old reviewed absence no longer held, before adapter recovery could prove the effect. Resume now skips that old preflight for ambiguous/intent/partial effects, while still preflighting known-no-effect retries. Deterministic and disposable Kubernetes tests cover this order.

2026-09-22: EP-147 registered a first Kubernetes runtime for packaged manifest declarations. It binds source at plan time, reconstructs native objects from the private review for apply/resume, and verified create and update on a disposable ConfigMap. Update permits forced transfer from its own create manager only after a live managed-fields check excludes foreign non-status owners, with UID/resourceVersion in the write. M1b remains open for per-kind projection and broader live command proof. Generated namespace contributions still need the M3 native composer.

2026-09-22: EP-147 closed an immediate credential race in the legacy database create path: a create-only Secret write now rereads a concurrent winner, and dry-run omits generated Secret data. This does not complete the reviewed inventory migration. A further disposable Kubernetes probe showed that no-op server-side apply after create does not transfer Update field ownership; subsequent changed apply still conflicts, so production update transport remains gated on per-kind ownership and atomic UID/resourceVersion handling.

2026-09-22: EP-147 now compiles direct database objects from the renderer's structured values, with stable IDs and a retained PVC recovery policy. EP-148 can consume this pure bundle once EP-147 adds credential, backup, and native-byte binding; the old create path remains active until then.

2026-09-22: EP-147 found that a Kubernetes `List` could pass the structured compiler as one opaque resource, hiding the claims of its children. YAML stream and List expansion, plus an explicit refusal of unexpanded Lists, now close that pure validation gap.

2026-09-22: EP-147 found that the Kubernetes declaration compiler trusted a supplied digest. The CLI binding function checks it against canonical JSON and returns the same bytes for later native execution.

2026-09-22: EP-147's Kubernetes adapter now records canonical native bytes and observed UID/resourceVersion in private review evidence, rebinds native membership to the declaration, and refuses changed or foreign objects in recording tests. The production transport remains absent because it must enforce the condition at the API server; a local recheck alone cannot authorize apply.

2026-09-22: Apply adapter construction previously received a public review bundle with no native members, while resume received the private stored bundle. Both now receive the verified store-backed bundle. Public scope and document matching still occurs first; a private accessor exposes native members only within the command service for later Kubernetes adapter reconstruction.

2026-09-22: A disposable k3d ConfigMap probe found that server-side apply with `resourceVersion: "0"` can update an existing object, so it cannot prove create-time absence. `kubectl create` provides create-only semantics but records Update field ownership; a later server-side apply with the same manager conflicts on the changed field. JSON Patch with UID and resourceVersion tests rejected a stale update atomically. EP-147 and EP-148 must select a per-kind create/update strategy that preserves both ownership conflicts and server-enforced preconditions; a generic check-then-apply is not enough. This is provider behavior observed on the disposable local cluster, not proof for all resource kinds.

2026-09-22: EP-147 found that controller reservations were already present in EP-144's inventory validator, while structured Kubernetes objects still lacked a compiler path into those declarations. The new pure compiler connects those boundaries and proves the database/Knative collision against the database renderer's golden manifest. It does not yet authorize Kubernetes mutation.

2026-09-22: EP-147 found the legacy database create path generated a fresh password after any failed or malformed Secret read. It now requires confirmed absence, closing that immediate credential risk while the inventory adapter is built.

2026-09-22: EP-147 added an optional logical key to the existing Database config and an identity builder that mints the same resource ID across provider renames. Existing configs omit the key and remain wire-compatible; a rename-safe database must supply one explicitly. The DSL and CLI suites pass.

2026-09-22: EP-145 is complete. Consumers use Nagare.Inventory.Adapter, Plan, Journal, Store, and Execute; only lock-scoped admission can create execution authority. Native evidence stays in the private store while the operator-facing review directory contains the canonical public document and scopes. The CLI currently installs a deterministic manifest-only adapter whose preflight always refuses; EP-146 and EP-147 replace it with real provider adapters. The store suite now covers both conditional backends, re-entry, backup integrity, actual independent-process exclusion, and lock release after process death. Filesystem export excludes the lock and atomic-write temporaries. ADR 22 records this implemented boundary.

2026-09-22: EP-146 adapter integration found that transaction identity alone is insufficient for child-process confinement and that verification must retain the reviewed native bytes. The executor now scopes a closed executor child token during execution, verification, and recovery, and the shared verification callback receives `PreparedNative`. Cloud, host, and artifact transports fail before side effects for a foreign token. The command service accepts domain registry construction at plan/apply/resume; EP-146 subsequently installed all three production domain runtimes while retaining explicit compatibility classifications for EP-150.

2026-09-22: EP-146 is complete at the domain-adapter boundary. Shared plan/apply/resume now reconstruct production Pulumi, guarded-host, and artifact runtimes from composed or retained scopes. Artifact publication specifications survive the generic wire boundary; host apply consumes the exact closure retained at preparation; and the real Pulumi program's base, image, cache, legacy-CDN, certificate-preparation, and certificate-map variants pass exhaustive declaration-guard consumption. Remaining upgrade/Just/bootstrap compatibility paths stay explicit for EP-150/151 and are not claimed as migrated.

2026-09-22: EP-144 is complete. Consumers use the six Nagare.Resource modules, Nagare.Inventory.Digest.contentDigest, and Inventory.Command.loadCandidate. Compiled requests retain full base generations/reservations and explicit replacements/retirements through immutable scope-member references. Loading verifies and recomposes, but does not authenticate ownership history; EP-145 must compare the supplied base against its store during admission. Namespace contribution dependents are exposed separately for retention policy. API-version normalization, duplicate JSON-key rejection, and bounded controller reservation expansion are now part of the shared wire/claim boundary. ADRs 16 and 22 and docs/architecture/resource-inventory.md record the durable contract.

2026-09-16, pre-implementation API validation. The operator asked for the proposed interface to be validated before any code was written. It was read against the working tree and the child plans, and its type-level claims were compiled under GHC 9.10.3. The architecture held. The interface as written did not, in the ways below; each is now corrected in the owning child plan.

The claim model would have passed the bug class that started this initiative. Nagare.Dsl.Database.Render names a database's Service after the database (`dbServiceName n = n`) and applications render as Knative Services, whose controller creates a core Service of the same name. An application and a database sharing a name in one namespace therefore contend for one core Service, while a comparison of declared group/kind/namespace/name sees two different addresses. Claims now include derived reservations, and a snapshot carries claims held by retained incarnations and unresolved transactions.

The omission rule stopped at a file boundary. composeInventory enforced "omission never means deletion", but the compiled inventory was then written to disk and decoded straight into a ValidatedInventory for planning, where a missing scope is indistinguishable from a retirement. The candidate now carries its base vector and explicit changes, and the only way to obtain a validated inventory is to compose.

Several consumed types had no owner, and one required field could not be built. EP-147 and EP-148 return ResourceBundle and ScopeDeclaration "from the EP-144 contract", which EP-144 never defined. Every declaration required a desired-spec digest while nagare-dsl has no hashing dependency and the plan preferred to keep it that way, so the pure builders could not have constructed a declaration.

The execution interface had no way to produce a review. The planner is pure, the verifier consumes a finished bundle, and the adapter methods were observe, preflight, execute, verify, and recover: nothing could run a Pulumi preview or a Helm render to create the native evidence that ADR 18 requires a review to bind. ReviewedPlan and ExecutablePlan were both named and neither defined, and a plan verified against a snapshot read outside the lock was handed to apply as if it were current. The lifecycle planners took no inventory and duplicated retirement intent.

Two smaller facts came from the compiler. Deriving Generic on a type with a hidden constructor, the pattern in Nagare.Dsl.Types today, lets a caller forge a value through GHC.Generics.to; coerce retags a phantom index even with the constructor out of scope, while a nominal role or a GADT witness stops it. A record field with a higher-rank type cannot be used as a selector or through a generic-lens label, so lock-scoped operations must be top-level functions.

```text
T1 forge via Generic, hidden constructor + deriving Generic   COMPILES  (leak)
T2 forge via Generic, hidden constructor, no Generic          REJECTED  GHC-83865
T3 coerce PhantomRef 'OciImage -> 'DatabaseConnection         COMPILES  (leak)
T4 same, type role nominal                                    REJECTED  GHC-18872
T5 same, GADT witness                                         REJECTED  GHC-18872
T7 return ExecutablePlan s out of the lock scope              REJECTED  GHC-25897
T8 import GHC.IO.Handle.Lock (hTryLock)                       COMPILES
amended EP-144/145/149 signatures as one stub module set      TYPECHECKS
```

Two dependency facts were checked on disk through Mori rather than recalled. aeson 2.3.1.0 orders object keys only because of its manual `ordered-keymap` Cabal flag, so the canonical encoder must sort keys itself and pin golden bytes. unix offers fcntl record locks, which are lost when the process closes any descriptor for the file; base's GHC.IO.Handle.Lock has the release-on-death semantics the plan wants and needs no new dependency.

One question is open and is the operator's to decide. ADR 13 moved tan-nb-exp's Pulumi state to GCS so that a new machine needs two clones and credentials. The inventory store will hold ownership history and deletion authority, and after EP-148 every application deploy needs it, yet it is a private directory on one workstation. The amended store contract keeps both answers available at no protocol cost: it is specified as conditional writes that GCS can also provide. Whether to add a shared store as an eighth child, or to accept export/restore as the way to move a context and amend ADR 13's consequence, was not decided in the validation pass. The operator decided it the same day in favor of the shared store; see the Decision Log and EP-151.


2026-09-24: EP-148's reviewed standalone workload paths require the accepted database's private native credential template to derive its engine, and check the saved Service and StatefulSet labels against it. EP-150's application coverage and recovery rehearsal must carry this evidence through the context store; live names or labels do not reconstruct the dependency after a new workstation resumes.


## Decision Log

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

EP-144, EP-145, EP-146, EP-147, EP-149, and EP-151 are complete as of 2026-09-24; EP-148/EP-150 remain. Cloud, host, artifact, and cluster bootstrap scopes have production adapters behind typed composition, digest-bound review, lock-scoped admission, durable receipt, and recovery. EP-148 can now consume EP-147's database/shared-owner interfaces and EP-149's lifecycle decisions. Completion still requires all eight child outcomes, IR-24's full verification set, independent-scope isolation, complete declaration/execution parity, removed compatibility paths, legacy recovery compatibility, and EP-150's integrated release evidence. The disposable EP-147 bootstrap proves local component convergence; it does not substitute for EP-150's cloud and upgrade rehearsal. EP-149's recording migration proof does not authorize a native provider migration.

At completion, compare these outcomes with IR-24, update its status only with evidence, and distill durable lessons into ADR 22 and affected existing ADRs. Do not publish a release or modify existing operator deployments as a side effect of updating plan status.


## Revision Notes

2026-09-16: Updated before any implementation, at the operator's request to validate the proposed API. No child plan was added, cancelled, split, or reordered, and the registry and dependency graph are unchanged. Integration Points now state the amended shared contract; Surprises & Discoveries records the findings and the compiler evidence; the Decision Log records the amendments and one open question about a shared inventory store and ADR 13. EP-144, EP-145, and EP-149 carry the interface changes; EP-146, EP-147, EP-148, and EP-150 carry the consequences that reach them. ADR 22 gained an amendment for the decisions that outlive these plans.

2026-09-16: Added EP-151, "Store inventory history in the context state bucket with conditional writes", at the operator's decision, resolving the open question from the validation pass. The registry, dependency graph, waves, Integration Points, Progress, Vision & Scope, and Outcomes now reflect eight children in four phases. EP-151 hard-depends on EP-145 only; it became a soft dependency of EP-148 (gating only the removal of the last legacy deploy path) and a hard dependency of EP-150. EP-145 gained the executor claim in its head manifest; EP-146, EP-148, and EP-150 gained the references that reach them. ADR 22's amendment was updated to record the decision; ADR 13 is amended by EP-151 when the store exists.

2026-09-22: Marked EP-144 complete and recorded its compiler, typed-boundary, schema, and command evidence. EP-145 is now the next implementable child. The decomposition and dependency graph are unchanged; ADRs 16 and 22 describe the implemented foundation and the remaining admission boundary.

2026-09-22: Marked EP-145 complete after the conditional-store, review/admission, journal/recovery, process-lock, backup, negative-type, and CLI acceptance suites passed. Four children in phase 2 are now implementable; no dependency edge or child scope changed. ADR 22 now distinguishes the implemented generic authority boundary from the still-refusing manifest-only CLI adapter.

2026-09-23: Marked EP-147 complete after the full disposable local bootstrap and accepted replay, registered Kubernetes precondition proofs, complete database/cache bundle, owner-composed auth settings, and guarded host timer delegation. Synchronized the three remaining parent checklist items, documented EP-148's standalone/application database command boundary, and kept EP-149/150 lifecycle and integrated cloud evidence open.

2026-09-23: Recorded further EP-149 status and adoption evidence without changing dependencies or claiming a completed lifecycle milestone. EP-148 and EP-150 remain blocked on the existing hard edges.

2026-09-23: Recorded adapter-proved operator recovery and UID-bound Kubernetes health observation. EP-149 still requires migration, broader lifecycle coverage, and complete acceptance before dependent children can start.

2026-09-23: Kept EP-149 in progress while aligning read-only collection screening with the proved conditional-delete transport. No dependency edge or child scope changed.

2026-09-24: Recorded additional read-only EP-149 status and explain coverage. The registry and dependency graph are unchanged.

2026-09-24: Recorded EP-149's typed immutable-replacement observation and fail-closed planner rule. Provider classification and executable migration remain outstanding; dependencies are unchanged.

2026-09-24: Recorded the first production immutable-change classifier for Kubernetes Deployment selectors. This advances EP-149 M1 without changing its in-progress status or the hard dependencies of EP-148 and EP-150.

2026-09-24: Extended EP-149's production immutable-change classification to StatefulSet identity fields. The child remains in progress, and EP-148/150 retain their hard dependency.

2026-09-24: Preserved read-only Kubernetes object facts when controller conditions are unready without relaxing execution completion. Dependency edges and child status are unchanged.

2026-09-24: Added StatefulSet condition coverage to EP-149 M1 without changing its completion status or the dependent child gates.

2026-09-24: Closed EP-149 M1 after confirming the complete read-only report, bounded observation window, retained/history explanation, partial provider coverage, and independent health. M2-M4 and the child status remain open.

2026-09-24: Extended EP-149's no-delete retained-incarnation route to stamped Helm releases. The generic ownership model and dependency graph are unchanged; M3 remains open for migration and broader retention/collection.

2026-09-24: Bound opaque lifecycle decisions to their composed candidate and accepted history, then revalidated them at planning. This closes candidate/history/observation replay within EP-149 M2 while leaving migration and dependent child gates unchanged.

2026-09-24: Corrected EP-149 Helm status classification so a pending release with a valid inventory stamp retains its owner evidence and cannot pass mutation verification. Active and retained Helm health now uses a second read bound to the observed revision Secret UID. Migration and dependent child gates remain open.

2026-09-24: Exposed accepted source and desired destination declarations for changed resource addresses/executors in EP-149 observation requirements. The ordinary planner still refuses such changes pending the dual-incarnation review and execution contract; EP-148/150 remain gated.

2026-09-24: Marked EP-149 complete after its provider-independent migration graph, separate incarnation observations, retained history, command-path review, and recording data/recovery fixtures passed. EP-148 may consume its lifecycle contract; EP-150 retains real provider and integrated release acceptance. No dependency edge changed.

2026-09-24: Added a fail-closed renderer membership check to EP-148's existing database and standalone broker declaration paths. EP-148 remains in progress; M1 through M4 and the EP-150 gate are unchanged.

2026-09-24: Extended the database native adapter's parity proof to exact declaration IDs and private member cardinality. No dependency or registry status changed.

2026-09-24: EP-148 now submits namespace contributions through EP-147's owner composer with exact dependency identity. Offline composition proves granted application requests leave the platform scope revision unchanged and ungranted requests refuse; other EP-148 M2 channels remain open.

2026-09-24: EP-148 added a standalone Service scope through the same native binder as an application Service. This expands the M1 supported subset without changing adapter ownership or the EP-150 dependency gate.

2026-09-24: EP-148 added optional DomainMapping logical keys to config emission/loading and identity minting. The existing provider-address migration gate remains necessary; no dependency or registry status changed.

2026-09-24: EP-148's composed two-application fixture proves compiler-level scope isolation and cross-application claim refusal. Application command routing and legacy path removal still gate M4 and EP-150.

2026-09-24: EP-148 now exposes saved inventory reviews for standalone database and topic-free broker creation and retirement. The create paths share their typed input with legacy direct creation, and the renderers include metadata previously applied by separate annotation calls. Retirement selects only an accepted scope containing the requested StatefulSet and namespace and retains all provider resources without deleting them. Direct compatibility paths, reviewed native deletion, application deployment, logical topics, environment channels, and operational actions still gate EP-148 and EP-150.

2026-09-24: Standalone data create planning now verifies the accepted foundation Namespace's logical ID and native cluster/name address. Legacy delete, backup/restore, snapshot/restore, task run/delete, and database/broker restart functions reject inventory transaction re-entry before direct effects. These guards prevent nested bypasses while the reviewed operational contracts remain open; they do not count as completed M3 migration.

2026-09-24: EP-148's platform-database collision fixture exposed that the EP-144 graph validator omitted `External` declarations from its canonical claim map. The shared validator now reserves their addresses, and both the DSL collision fixture and full application composition refuse a platform/database overlap. Observed controller children still use the parent's derived reservation. The EP-148/150 completion gates are unchanged.

2026-09-24: EP-148's standalone broker scope now includes typed logical topic claims and a guarded Redpanda topic adapter for absent-topic creation and exact configuration verification. Existing unowned topics, in-place changes, and uncertain creation acknowledgements refuse. Retained topic claims remain visible after broker retirement. The installed `rpk` exposes no stable topic ID, so independent topic incarnation proof and topic-bearing workload dependencies remain open; EP-148's milestones and EP-150's hard gate are unchanged.

2026-09-24: EP-148 now binds reviewed application, Service, and worker consumers to exact accepted standalone broker topic claims, includes topic environment values, and adds a saved-plan topic verification before new consumers. Missing topic evidence refuses. Topic update/deletion and other M1/M3 work remain, so EP-150's hard gate is unchanged.

2026-09-24: EP-148 now composes accepted auth-owner backend contributions and central access DomainMappings for reviewed application and standalone Service scopes. The routes depend on the accepted enforcer, backend map, and portal settings where applicable. Direct Service/app deploy and app delete refuse the legacy resolver after auth-owner acceptance. Legacy route adoption, supplied TLS, CDN, operational commands, and other direct-path removal remain; EP-148 and EP-150 status are unchanged.

2026-09-24: EP-148 expanded exact-precondition Kubernetes collection to retained DomainMappings, allowing a separately reviewed central access route removal after scope retirement. Provider execution evidence and other M3 commands remain open; no child milestone or EP-150 gate changed.

2026-09-24: A disposable `k3d-nagare-inventory-ep147` DomainMapping refused collection with a stale resourceVersion and accepted deletion with the exact UID/resourceVersion through the namespaced serving API. Absence was confirmed and the temporary namespace was removed. This validates the EP-148 native transport form; the full retained inventory collection and EP-150 gate remain open.

2026-09-24: EP-148 corrected retained Kubernetes collection of unready central access DomainMappings. An owned route with exact native digest and UID may be deleted using its reviewed resourceVersion even when its origin has failed; a changed resourceVersion still refuses. The 782-test CLI suite passes. Other EP-148 milestones and EP-150 remain open.
