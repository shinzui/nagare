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
---

# Make managed resources first-class through typed scoped inventories

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable decisions into docs/adr/ in the same change.


## Vision & Scope

Address [IR-24](../improvement-requests/make-managed-resources-first-class.md): an operator can obtain one complete, typed, revision-bound account of Nagare-managed cloud, host, Kubernetes, data, credential, artifact, and release/control resources. Compilation rejects conflicting ownership before mutation. Review exposes creation, adoption, update, replacement, migration, retention, and deletion. Apply executes dependency-aware native operations with durable evidence; resume skips proven completed work. Status explains identity, ownership, dependencies, drift, health, and retirement decisions.

Platform components and applications retain independent desired-state ownership and release cadence. Each scope is one owner's complete declaration with its own revision. The context inventory composes these declarations and validates their shared claims; it is not another independently editable desired-state document. Updating one selected scope preserves every unselected scope. Application deployments can submit authorized contributions to platform-owned routing/configuration, but cannot seize the entire shared object or advance the platform release.

The architectural objective is to reduce policy scripting through a shared Haskell model. Smart constructors, explicit alternatives, typed capability references, and opaque validated/reviewed values enforce structural guarantees. Pure functions validate whole-graph properties. Adapters observe live facts and execute native provider operations. The same declarations produce inventory, review, rendering, and execution inputs. A separate handwritten inventory mirroring existing scripts is not acceptable. Acceptance includes removing superseded orchestration and duplicated guards after their replacement is proven.

Desired state, observed state, and execution history remain separate. Logical IDs survive names and ownership transfers; physical identities identify individual incarnations. Resource membership and policy are known before external mutation. Generated values are constrained typed references, not permission to introduce new resources. Data defaults to retention; unknown observations never imply absence. Credentials are private adapter inputs, absent from public review/evidence representations.

The first implementation runs in the operator CLI with private context-owned state, one writer, immutable snapshots, and a durable journal. Pulumi, NixOS, Kubernetes, Helm, storage, and registry tools retain their native responsibilities. This does not add a daemon, distributed coordinator, new provider engine, automatic foreign-resource adoption, generic schema rollback, or production rollout. It does not complete the separate replacement-upgrade initiative. A later controller can implement the same store/adapter protocol; multi-workstation exclusion requires shared coordination and is not claimed by the filesystem implementation.


## Decomposition Strategy

Seven children separate independently demonstrable concerns. EP-144 proves declaration and graph correctness without provider access. EP-145 proves durable review/execution and crash recovery against recording adapters. EP-146 supplies cloud/host/artifact executors; EP-147 supplies cluster composition and executors; EP-149 supplies pure lifecycle policy and explanation. These three can proceed independently after the foundation. EP-148 combines those interfaces to migrate independent application/data commands. EP-150 proves the shipped platform-wide contract, removes remaining bypasses, and archives release evidence.

This avoids a single large rewrite while preventing a types-only delivery with no behavioral migration. Each adapter plan removes its own duplicate policy paths. The final child owns cross-provider integration, compatibility, and real acceptance, not all feature implementation.

The local ADR corpus was scanned by filename/title and relevant records were read. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates payloads/private workspaces; [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) preserves operator host identity; [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) defines release/version transaction semantics; [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) binds immutable release evidence; [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) confines cloud writes; [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) preserves self-reversion; [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) protects forward-only storage growth; [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) protects private operator/state material; [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) guards protected replacements; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) governs Haskell style; [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds native review and receipts; [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) protects irreversible cutover; [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) separates route/TLS ownership; and [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) defines cache retention and trust boundaries.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) records the accepted architecture from this discussion; it is a design decision, not a claim of implementation. Mori searches found no relevant cross-repository ADR to import. The local mori.dhall and mori show --full do not declare docs/adr as a profiled bundle, so the existing ADR filename/frontmatter convention is preserved. Dependency APIs must be researched through Mori during implementation and current upstream releases checked before changing bounds; this plan prescribes no dependency upgrades.

Rejected alternatives were isolated platform/application inventories without shared conflict checks; one global release coupling all applications to platform upgrades; a manually maintained resource list beside imperative scripts; replacing native reconcilers; and an always-on control plane before the operator-driven protocol is proven.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 144 | Define typed resource scopes and validate composed inventories | docs/plans/144-define-typed-resource-scopes-and-validate-composed-inventories.md | None | None | Not Started |
| 145 | Persist reviewed resource plans and resumable execution receipts | docs/plans/145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md | EP-144 | None | Not Started |
| 146 | Reconcile cloud host and artifact resources through inventory adapters | docs/plans/146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md | EP-144, EP-145 | EP-149 | Not Started |
| 147 | Compile cluster bootstrap into owned resource components | docs/plans/147-compile-cluster-bootstrap-into-owned-resource-components.md | EP-144, EP-145 | EP-146, EP-149 | Not Started |
| 148 | Route application and data lifecycles through independent resource scopes | docs/plans/148-route-application-and-data-lifecycles-through-independent-resource-scopes.md | EP-146, EP-147, EP-149 | None | Not Started |
| 149 | Explain drift and execute reviewed adoption migration and retirement | docs/plans/149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md | EP-144, EP-145 | EP-146, EP-147 | Not Started |
| 150 | Integrate resource inventories into upgrades and release verification | docs/plans/150-integrate-resource-inventories-into-upgrades-and-release-verification.md | EP-146, EP-147, EP-148, EP-149 | None | Not Started |

Hard dependencies must be Complete before starting the dependent child; soft dependencies supply additional real-adapter coverage but allow independent fixture-backed work. Registry status values are Not Started, In Progress, Complete, or Cancelled.


## Dependency Graph

EP-144 must complete first because all later work consumes its identity, declaration, wire, and validation contracts. EP-145 then defines the one authoritative store, review boundary, journal, and adapter protocol.

EP-146, EP-147, and EP-149 may proceed after EP-145. Cloud and cluster builders test against declared typed outputs without needing each other's live executors. Lifecycle policy tests against recording adapters without claiming native behavior. Their integration dependency is that every adapter exposes identity/precondition/verification capabilities required by lifecycle policy; reconcile that contract before any real adoption/migration/retirement is enabled. Until then these actions refuse explicitly, while fresh-resource/convergent operations remain independently verifiable.

EP-148 requires the native publication/cloud and cluster adapters plus lifecycle policy because application deploys cross all three: they publish artifacts, create cluster/data resources, contribute to shared configuration, and retire owned objects. EP-150 needs the complete migrated command set and all real adapters to prove context-wide completeness and release recovery.

The implementation waves are therefore EP-144; EP-145; EP-146/147/149; EP-148; EP-150. Numerical order is not execution order. The earlier replacement MasterPlan 21 remains independent: preserve its safety core and add bindings, but do not silently change its registry, assume unfinished adapters exist, or make this initiative depend on completing its live cutover project.


## Integration Points

**Typed domain contract — owned by EP-144, consumed by every child.** cli/nagare-dsl/src/Nagare/Resource/{Types,Reference,Policy,Inventory,Compile,Wire}.hs and schemas/resource-inventory-v1.json define stable ContextId/ScopeId/ResourceId, provider claims/aliases, physical identity, typed exports, owner contributions/delegation, lifecycle/data/sensitivity policy, and deterministic serialization. New provider kinds extend this contract explicitly. Do not derive Generic, public setters, unchecked FromJSON, or coercible phantom roles for opaque evidence values.

**State, review, and operation protocol — owned by EP-145, consumed by EP-146–150.** cli/nagarectl/src/Nagare/Inventory/{Store,Plan,Journal,Execute,Adapter}.hs owns desired/converged heads, complete scope revision vectors, historical/retained incarnations, review bundles, operation identity, adapter capabilities, completion/recovery states, and writer locking. All persistent state stays outside payload workspaces. EP-149 adds lifecycle decisions through this interface; adapters cannot write their own scope heads.

**Declaration versus native execution — owned by EP-146 for cloud/host/artifact, EP-147 for cluster, consumed by EP-148/150.** One provider operation may cover multiple declared resources. Pulumi native plans and TypeScript registration mapping remain authoritative for native semantics but must agree with validated membership. Kubernetes/Helm rendering is expanded and retained before mutation. Native plan/config/output changes require a new review, including bounded preparation when a provider cannot preview before a prerequisite exists.

**Shared cluster resources and data builders — owned by EP-147, consumed by EP-148.** Resource/Database.hs emits the entire database bundle, including credentials and backup operations, from the full typed Database value. Namespace/auth/shared configuration owners compose validated consumer contributions. Their effective desired resource digest includes contribution revisions without changing the owner's base scope revision or platform release. Owner authorization and complete contribution-vector checks prevent arbitrary app writes and lost updates. Credential refreshers and controller children have explicit bounded delegation.

**Lifecycle and observation semantics — owned by EP-149, consumed by EP-146–148/150.** Lifecycle.hs, Migration.hs, Status.hs, and Explain.hs own drift categories, adoption/transfer proofs, retained resources, incarnation-aware migration, and collection decisions. A stable ResourceId can have active/candidate/retained physical incarnations. Every deletion is bound to exact identity/history; restore/schema migration/write admission have explicit data recovery contracts. Existing Replacement/Cutover semantics remain specialized.

**CLI routing and compatibility — initial compile command owned by EP-144, generic command service by EP-145, domain registrations by EP-146–149, final upgrade integration by EP-150.** app/Main.hs and justfile remain shared registration surfaces. Move behavior into named modules, coordinate registrations, and do not reintroduce separate orchestration in these files. Existing version/context/project/cluster guards remain until their authoritative replacements are proven. Preserve old receipts without converting unproven success into new proof.

**Coverage and tests — format owned by EP-146, contributions by EP-147/148, completeness owned by EP-150.** docs/architecture/managed-resource-coverage.md records each supported mutation family, owner scope, declaration compiler, executor, test evidence, delegation, and legacy disposition. A child running earlier may create the file using that format; later children preserve its entries. This is a traceability aid, not a second resource authority. Shared Cabal/Spec.hs/Nix test registrations must preserve each other's modules. Pure cases use existing Haskell tests; provider behavior retains focused integration checks.

**Release evidence — owned by EP-150, supplied by all earlier children.** Native tool identities, inventory/review digests, scope revisions, receipts, coverage status, and final observed state are archived under a payload identity and distinct run identity. Global release publication has a dedicated publication owner/context, not whichever deployment first consumes it. Published artifacts are references in consuming contexts. Private secrets/native bundles do not enter public evidence.

EP-150 also owns the actual .github/workflows/release.yml publisher and Nagare.Inventory.Adapters.GitHubRelease. Its narrowly scoped durable publication record lives in the provider draft release: atomically bound intent/review, exact declared assets, a pre-publication verification receipt, and observed publication completion. Ephemeral Actions artifacts are not authoritative history. All authorized same-tag publishers share workflow serialization. This provider protocol does not expand the initial context store into a remote multi-writer service; ordinary context history remains private filesystem state.

These ownership, identity, review, storage, migration, and controller-delegation decisions belong in ADR 22 and relevant amendments. Each child updates durable decisions when implementation evidence changes them rather than leaving contradictory prose in separate plans.


## Progress

- [ ] EP-144 M1: Typed identities, policies, references, and opaque boundaries.
- [ ] EP-144 M2: Deterministic composition and wire validation.
- [ ] EP-144 M3: Read-only compiler and structural/collision fixtures.
- [ ] EP-145 M1: Durable independent scope state and identity.
- [ ] EP-145 M2: Reviewed operation plans and exact binding.
- [ ] EP-145 M3: Journal, recovery, locking, and head consistency.
- [ ] EP-145 M4: Commands, backup/restore, and crash tests.
- [ ] EP-146 M1: Cloud declarations/native registration parity.
- [ ] EP-146 M2: Guarded host receipts and committed identity.
- [ ] EP-146 M3: Artifact/bootstrap/control resources.
- [ ] EP-146 M4: Migrated entry points and duplicate-policy removal.
- [ ] EP-147 M1: Typed cluster adapter and observation/preconditions.
- [ ] EP-147 M2: Complete cache/database composition.
- [ ] EP-147 M3: Remaining bootstrap, contributions, and delegation.
- [ ] EP-147 M4: Removed orchestration and component resume.
- [ ] EP-149 M1: Read-only drift/status/explanation.
- [ ] EP-149 M2: Reviewed adoption and transfer.
- [ ] EP-149 M3: Data-preserving migration and retention/collection.
- [ ] EP-149 M4: Commands and recovery decision fixtures.
- [ ] EP-148 M1: Complete application/data scopes.
- [ ] EP-148 M2: Shared contributions, env/secret intent, and publication.
- [ ] EP-148 M3: Operational/data command coverage.
- [ ] EP-148 M4: Removed alternate paths and scope isolation.
- [ ] EP-150 M1: Platform/legacy transaction integration.
- [ ] EP-150 M2: Packaging and complete mutation audit.
- [ ] EP-150 M3: Deterministic and real disposable-context proof.
- [ ] EP-150 M4: Immutable release evidence, docs, and ADR distillation.


## Surprises & Discoveries

None during implementation yet. Research observations that determine the design are incorporated in child Context and Orientation and work sections; this section will record subsequent cross-plan discoveries.


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

2026-09-16: Assign GitHub publication recovery to EP-150 with provider-durable draft evidence and serialized workflow ownership. Rationale: a complete platform resource model includes the actual publisher, and temporary CI files cannot establish recovery after a runner disappears. App stop and nondeterministic Helm rendering also receive explicit compatibility/parity tests.


## Outcomes & Retrospective

Not implemented. Completion requires all seven child outcomes, IR-24's full verification set, independent-scope isolation, typed public-boundary tests, complete declaration/execution parity, removed duplicate policy paths, legacy recovery compatibility, inventory-history restore evidence, and production-shaped disposable-context convergence/no-op/removal evidence. Record any unavailable live/native evidence as remaining work rather than treating deterministic tests as a substitute.

At completion, compare these outcomes with IR-24, update its status only with evidence, and distill durable lessons into ADR 22 and affected existing ADRs. Do not publish a release or modify existing operator deployments as a side effect of updating plan status.
