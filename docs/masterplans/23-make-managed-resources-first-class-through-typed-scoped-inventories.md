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
| 147 | Compile cluster bootstrap into owned resource components | docs/plans/147-compile-cluster-bootstrap-into-owned-resource-components.md | EP-144, EP-145 | EP-146, EP-149 | In Progress |
| 148 | Route application and data lifecycles through independent resource scopes | docs/plans/148-route-application-and-data-lifecycles-through-independent-resource-scopes.md | EP-146, EP-147, EP-149 | EP-151 | Not Started |
| 149 | Explain drift and execute reviewed adoption migration and retirement | docs/plans/149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md | EP-144, EP-145 | EP-146, EP-147 | Not Started |
| 150 | Integrate resource inventories into upgrades and release verification | docs/plans/150-integrate-resource-inventories-into-upgrades-and-release-verification.md | EP-146, EP-147, EP-148, EP-149, EP-151 | None | Not Started |
| 151 | Store inventory history in the context state bucket with conditional writes | docs/plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md | EP-145 | EP-146 | Not Started |

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
- [ ] EP-147 M1b: Production observation and API-server-conditional mutation, then command registration.
- [x] (2026-09-22) EP-147 M2a: Database Secret read distinguishes confirmed absence from failure/malformed data.
- [x] (2026-09-22) EP-147 M2b: Database config carries an optional stable logical key across rename and wire round-trip.
- [ ] EP-147 M2c: Complete cache/database composition and inventory execution.
- [ ] EP-147 M3: Remaining bootstrap, contributions, and delegation.
- [ ] EP-147 M4: Removed orchestration and component resume.
- [ ] EP-149 M1: Read-only drift/status/explanation.
- [ ] EP-149 M2: Reviewed adoption and transfer.
- [ ] EP-149 M3: Data-preserving migration and retention/collection.
- [ ] EP-149 M4: Commands and recovery decision fixtures.
- [ ] EP-151 M1: Prototype proving the bucket's conditional writes and choosing the transport.
- [ ] EP-151 M2: Object-backed store passing the shared transaction suite.
- [ ] EP-151 M3: Context selection, guarded opening, and resumable migration.
- [ ] EP-151 M4: Live two-state-root evidence, documentation, and ADR 13/22 amendments.
- [ ] EP-148 M1: Complete application/data scopes.
- [ ] EP-148 M2: Shared contributions, env/secret intent, and publication.
- [ ] EP-148 M3: Operational/data command coverage.
- [ ] EP-148 M4: Removed alternate paths and scope isolation.
- [ ] EP-150 M1: Platform/legacy transaction integration.
- [ ] EP-150 M2: Packaging and complete mutation audit.
- [ ] EP-150 M3: Deterministic and real disposable-context proof.
- [ ] EP-150 M4: Immutable release evidence, docs, and ADR distillation.


## Surprises & Discoveries

2026-09-22: EP-147 found that a Kubernetes `List` could pass the structured compiler as one opaque resource, hiding the claims of its children. YAML stream and List expansion, plus an explicit refusal of unexpanded Lists, now close that pure validation gap.

2026-09-22: EP-147 found that the Kubernetes declaration compiler trusted a supplied digest. The CLI binding function checks it against canonical JSON and returns the same bytes for later native execution.

2026-09-22: EP-147's Kubernetes adapter now records canonical native bytes and observed UID/resourceVersion in private review evidence, rebinds native membership to the declaration, and refuses changed or foreign objects in recording tests. The production transport remains absent because it must enforce the condition at the API server; a local recheck alone cannot authorize apply.

2026-09-22: Apply adapter construction previously received a public review bundle with no native members, while resume received the private stored bundle. Both now receive the verified store-backed bundle. Public scope and document matching still occurs first; a private accessor exposes native members only within the command service for later Kubernetes adapter reconstruction.

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


## Decision Log

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

EP-144, EP-145, and EP-146 are complete as of 2026-09-22; five children remain. Cloud, host, and supported artifact scopes now have production adapters behind the typed composition, digest-bound review, lock-scoped admission, durable receipt, and recovery protocol. EP-147, EP-149, and EP-151 remain independently implementable, while EP-148 and EP-150 retain their dependency gates. Completion still requires all eight child outcomes, IR-24's full verification set, independent-scope isolation, complete declaration/execution parity, removed compatibility paths, legacy recovery compatibility, shared inventory-history evidence, and production-shaped disposable-context convergence/no-op/removal evidence. Deterministic provider mocks are recorded as parity evidence, not a substitute for EP-150's live disposable-context proof.

At completion, compare these outcomes with IR-24, update its status only with evidence, and distill durable lessons into ADR 22 and affected existing ADRs. Do not publish a release or modify existing operator deployments as a side effect of updating plan status.


## Revision Notes

2026-09-16: Updated before any implementation, at the operator's request to validate the proposed API. No child plan was added, cancelled, split, or reordered, and the registry and dependency graph are unchanged. Integration Points now state the amended shared contract; Surprises & Discoveries records the findings and the compiler evidence; the Decision Log records the amendments and one open question about a shared inventory store and ADR 13. EP-144, EP-145, and EP-149 carry the interface changes; EP-146, EP-147, EP-148, and EP-150 carry the consequences that reach them. ADR 22 gained an amendment for the decisions that outlive these plans.

2026-09-16: Added EP-151, "Store inventory history in the context state bucket with conditional writes", at the operator's decision, resolving the open question from the validation pass. The registry, dependency graph, waves, Integration Points, Progress, Vision & Scope, and Outcomes now reflect eight children in four phases. EP-151 hard-depends on EP-145 only; it became a soft dependency of EP-148 (gating only the removal of the last legacy deploy path) and a hard dependency of EP-150. EP-145 gained the executor claim in its head manifest; EP-146, EP-148, and EP-150 gained the references that reach them. ADR 22's amendment was updated to record the decision; ADR 13 is amended by EP-151 when the store exists.

2026-09-22: Marked EP-144 complete and recorded its compiler, typed-boundary, schema, and command evidence. EP-145 is now the next implementable child. The decomposition and dependency graph are unchanged; ADRs 16 and 22 describe the implemented foundation and the remaining admission boundary.

2026-09-22: Marked EP-145 complete after the conditional-store, review/admission, journal/recovery, process-lock, backup, negative-type, and CLI acceptance suites passed. Four children in phase 2 are now implementable; no dependency edge or child scope changed. ADR 22 now distinguishes the implemented generic authority boundary from the still-refusing manifest-only CLI adapter.
