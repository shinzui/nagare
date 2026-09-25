---
id: 150
slug: integrate-resource-inventories-into-upgrades-and-release-verification
title: "Integrate resource inventories into upgrades and release verification"
kind: exec-plan
created_at: 2026-09-16T17:23:45Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-16T17:23:45Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T04:04:49Z
      mode: "update"
      note: "Cascaded consequences of MasterPlan 23 API validation"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T20:16:27Z
      mode: "implement"
      note: "Started integration audit and guarded legacy upgrades for inventoried contexts"
---

# Integrate resource inventories into upgrades and release verification

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

The shipped Nagare operator can render a complete context inventory, review a change, apply it, recover interruption, and explain final ownership across cloud, host, cluster, data, credentials, artifacts, and control metadata. Application and platform scopes remain independently deployable. A disposable-context rehearsal proves convergence, a no-op rerun, and policy-correct component removal.

Release evidence archives the inventory, review, receipts, and final observations under one immutable payload identity. Complete coverage and removal of obsolete policy paths are release acceptance conditions.


## Progress

- [ ] M1: Integrate component transactions into platform upgrades and legacy recovery.
- [ ] M2: Package contracts and audit all supported mutation paths.
- [ ] M3: Run deterministic and disposable-context convergence/recovery scenarios.
- [ ] M4: Archive release evidence, document recovery, and finish ADR distillation.

2026-09-25: Integration audit found that `runPlatformUpgrade` still applies the
coarse Pulumi, host, and whole-cluster phases, while EP-148 still has direct
application/data mutation paths. As an interim M1 safety boundary, the legacy
upgrade command now reads the selected context's inventory history before
planning or applying and refuses if accepted, retained, collected, or active
transaction evidence exists. The `nagarectl` executable builds. This does not
complete M1: a component-backed upgrade path and legacy recovery compatibility
are still required. The 818-test `nagarectl` suite, Haskell style check,
strict user-documentation validation, and diff check passed.


## Surprises & Discoveries

2026-09-25: The current release workflow still creates a published release
through `softprops/action-gh-release` after treating any failed `gh release
view` call as absence. It has no provider-durable draft binding or recovery
from partial asset uploads. The publication adapter must replace that path
before release evidence can be claimed complete.

2026-09-25: EP-148 remains open on full application membership, operational
and data command cutover, and direct-path removal. This is a hard input to M2
coverage completion, not evidence that EP-150 can exclude those commands.

2026-09-25: The operator selected `tan-ng-labs` for later live rehearsal, but
a read-only GCP check found a running `nagare-01` VM there and the saved `labs`
context targets that name. Do not use that existing context or VM as a
disposable fixture. A live scenario needs a separate, uniquely named context
and exact resource identities before any write.


## Decision Log

2026-09-16: Do not advertise a complete authoritative inventory while supported commands or installer scripts bypass its protocol. Partial migration is an explicit development state.

2026-09-16: Preserve the old context version until all required target components verify. An application change never advances that platform pin.

2026-09-16: Validate release integration without publishing a release or upgrading a live operator context as an incidental implementation step.

2026-09-25: Until upgrade phases use reviewed component receipts, refuse the
legacy upgrade command for a context with substantive inventory history. A
guarded refusal preserves the old context pin and prevents the coarse replay
from bypassing accepted scope ownership; it does not migrate an existing
transaction or claim M1 completion.


## Outcomes & Retrospective

Not implemented. Completion requires recorded disposable-context evidence and no unaccounted supported mutation path; passing mocked tests alone is insufficient.


## Context and Orientation

Hard dependencies are [the shared inventory store](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md), [cloud/host/artifact adapters](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [cluster components](147-compile-cluster-bootstrap-into-owned-resource-components.md), [independent application/data commands](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md), and [lifecycle/status](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md). Their foundation is the shared typed model and immutable store/executor from EP-144/145. Each scope has accepted and converged revisions; resource history survives retirement; a native executor group may cover many declarations.

cli/nagarectl/src/Nagare/Platform/Upgrade.hs and app/Main.hs:upgradeOps currently use fixed Pulumi/host/Kubernetes/stamp/context phases. KubernetesApply replays the whole bootstrap. Platform/Status.hs reports five release identities. Platform/PulumiReceipt.hs skips proven cloud work without provider access. Platform/Paths.hs and Workspace.hs package/materialize payloads. nix/platform-package.nix, nix/nagare-packages.nix, nix/checks/{haskell,infra,platform,scripts}.nix, release.json, scripts/check-release.sh, scripts/test-release.sh, scripts/assemble-release.sh, and scripts/rehearse-clone-free-release.sh own distribution/verification. Inspect the actual release workflow under .github/workflows before editing its artifacts; this plan does not authorize publication.

.github/workflows/release.yml currently assembles deterministic attachments, compares existing complete releases, and publishes through softprops/action-gh-release. Its Actions artifacts expire after 14 days, and its retry path cannot recover a partially uploaded release. This plan owns migration of that actual publisher as well as evidence assembly; merely inventorying its resulting artifacts leaves a mutation bypass.

[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates private state and payloads. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) governs final context commit. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable tag/native evidence and separates publication from context mutation. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds review/receipts. [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) keeps replacement cutover separately gated. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) is the agreed inventory architecture.


## Plan of Work

### M1 — Platform transaction integration

Refactor upgradeOps to submit target platform scope replacements against the full stored context snapshot. Keep application declarations and revisions unchanged, but validate their capability dependencies against the target platform. If the platform changes an incompatible exported capability, refuse or require an explicit coordinated multi-scope migration. Do not silently upgrade applications.

Retain the public upgrade transaction identity and reporting surface while representing work as EP-145 component operations. Preserve native Pulumi review binding and proven-success skips. Replace the unconditional Kubernetes bootstrap replay with per-component receipts and specific readiness conditions. A completed host phase must use EP-146 committed-closure evidence rather than matching a local version string. Apply the cluster version marker only after required components verify, then advance the context pin as the final commit. Stamp inventory digest/revision bindings alongside the release identity.

Define wire-format migration explicitly. Old transactions remain readable. Where existing Pulumi review/receipt evidence can be verified, bridge it without rerunning the provider. Legacy success text without adequate proof still requires existing guarded recovery or a new review. Never fabricate component receipts for historical coarse bootstrap success. If a pending legacy transaction cannot be safely resumed with the new protocol, preserve its bundle and explain use of the original payload/recovery path; do not convert it in place.

Record minimum supported inventory/wire versions in compatibility metadata. Unsupported newer schemas refuse mutation but remain discoverable as unsupported state. Older CLIs cannot be assumed to honor a new lock; the migration boundary must explicitly require upgrading supported operator entry points and identify old/raw tools as outside enforcement. Context adoption writes no optimistic success marker.

### M2 — Packaging, coverage, and obsolete-path removal

Ship pure models, schemas, component declarations, exact external manifest/chart bytes, and required adapters in the correct existing packages. The app-developer package remains free of unnecessary operator tools; the full operator package supplies native platform tools and clone-free behavior. Extend Nix packaging/checks for any new source/schema paths and negative public-API tests. Test Darwin and Linux filesystem locking/durability where supported.

Finish docs/architecture/managed-resource-coverage.md. Audit every supported mutating command and recipe, including init/context projections, platform/infra/host/builder operations, auth/observability/cache/local bootstrap, app/site/server/worker/preview deploys, env/secrets, storage backups/restores/pruning, database/broker/topics, jobs/tasks, domain/CDN/access, maintenance sessions, image publication, and release/control state. A coverage row names its scope owner, declaration builder, executor, evidence tests, delegated authority, and legacy entry point disposition. Unaccounted behavior must be migrated or explicitly made unavailable; it cannot be silently excluded from the completion claim.

Verify that removed installers/guards have equivalent tests at the new authoritative boundary. Keep narrow native transport and remote safe-switch protocols. Remove wrappers/tests that only reconstruct policy now represented by types and pure validators. Reject new provider writes outside adapter modules in review and add a focused mutation-registration test over the command registry; a grep-only policy check is not sufficient assurance.

Update docs/user/upgrades.md, contexts.md, cluster-bootstrap.md, app-lifecycle.md, managed-databases.md, backups-and-disaster-recovery.md, env-and-secrets.md, nix-binary-cache.md, and reference.md as needed, following their profile/log contract. Explain independent scopes, adoption, partial state, secret-safe evidence, writer limitations, and history restoration. Reconcile the documentation and [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) with the inventory store: that ADR says a new machine needs two clones and credentials, which stops being true once ownership history and every application deploy depend on a workstation-local store. The MasterPlan resolved this by adding EP-151, which keeps a cloud context's store in its state bucket and amends ADR 13 itself. Here, confirm that the documents and ADR 13 agree with what EP-151 delivered, that export/restore remains documented for local-store contexts, and run the production-shaped rehearsal of M3 with the GCS store selected. Do not promise distributed exclusion or automatic data rollback.

### M3 — Integrated acceptance

Add cli/nagarectl/test/InventoryIntegrationSpec.hs using recording/fault-injection adapters. Begin with platform plus two applications and a cache. Compile once, plan, apply, verify, rerun as no-op, then remove one component under retention policy. Interrupt after cloud success, host success, database readiness, migration completion, cluster completion, and just before context commit. Verify exact resumed operation counts and unchanged completed receipts.

Add scripts/rehearse-managed-resources.sh as a thin launcher for the real typed commands, with explicit context, expected provider project/cluster, and evidence destination. It contains no separate inventory or lifecycle policy. First run a disposable local context with registry, auth, storage, applications, and database. Then run a production-shaped disposable GCP context including cloud foundation, guarded host, cache, secrets, artifact publication, and recovery evidence. The operator supplies the target and authorizes its bounded creation/cleanup; no production context is inferred from ambient state. Failure to obtain live evidence leaves this milestone incomplete.

The real scenario renders the complete declared inventory before external mutation; apply reaches convergence; an unchanged rerun records zero unintended writes; an intentionally removed component is retained or deleted according to its reviewed policy. Include adoption refusal of an unowned same-name object, a migration/rename preserving database rows and signing identity where relevant, and deletion of an ephemeral owned fixture without touching retained/unmanaged neighbors. Archive backup/restore proof and test restoring the private inventory history into an isolated operator state root. Cleanup itself must use exact reviewed owned resources.

### M4 — Release evidence and completion

Extend clone-free rehearsal and release checks to archive a versioned evidence manifest containing payload/version/source identity, context fixture identity, canonical inventory digest, scope revision vector, reviewed change-set digest, component receipt references/digests, final observed summary, tool identities, and coverage result. Public evidence is structurally redacted. Private native plans/secrets/recovery archives stay private and are referenced only through safe digests/opaque identifiers. No release archive contains live operator credentials or operator-specific ciphertext.

Evidence attachments remain immutable and byte-identical on retry under ADR 7. A release payload identity and per-context run identity are separate; do not claim one context owns the globally shared release artifact. Global publication operations use EP-146's publication owner, while consuming contexts record references.

Implement Nagare.Inventory.Adapters.GitHubRelease in cli/nagarectl/src/Nagare/Inventory/Adapters/GitHubRelease.hs and a checked release-publication command, consuming EP-146 artifact types. The publication owner is bound to repository identity and tag, independent of a deployment context. Replace the direct release-action mutation orchestration in .github/workflows/release.yml; preserve its native build, exact-tag checks, deterministic assembly, minimal permissions, and same-tag writer serialization. This is a narrow provider recovery protocol, not a general remote implementation of the context store.

Compile a deterministic publication declaration/review from repository, tag-object/commit identity, payload identities, exact pre-generated notes, and the complete asset names/digests. A workflow run ID is provenance, not immutable content identity. The first provider write creates a draft with a machine-readable intent/review envelope in its body, atomically establishing the binding needed to recover an ambiguous create response. The envelope includes all upload and eventual publication intents; keep it and the notes unchanged. Prototype and verify provider body/asset limits and immutable-release behavior before finalizing the wire shape. Query errors are unknown, never absence.

Recover by finding exactly one draft/published release with matching repository/tag/transaction binding. Upload only missing declared assets, verify existing assets by physical ID/state and downloaded bytes, and refuse different bytes. A failed upload placeholder needs an explicitly reviewed cleanup of its exact draft asset ID. After all product assets verify, upload an append-only digest-addressed verification receipt containing their provider identities. Classify journal/receipt bookkeeping separately from the product manifest so it does not need to hash itself. Verify the full set again, then publish the same draft ID.

Completion after runner loss is reconstructed from the pre-publication receipt, unchanged envelope/assets, and authoritative published state. Do not append a final receipt to an immutable published release; export the reconstructed completion observation locally. Retry with an empty runner filesystem must work using the provider record and the exact reviewed candidate bytes. Expired Actions artifacts are not recovery authority: missing candidate bytes require reproducible reconstruction or a retained archive, never acceptance of different bytes. Existing published legacy releases may be verified read-only and left unchanged; unbound drafts require explicit adoption/recovery. Same-tag workflow serialization excludes authorized overlapping publishers, not administrators or raw API clients; unexpected changes cause refusal.

Add InventoryPublicationSpec.hs with failures after create, each asset upload, verification receipt upload, and publish, then restart from an empty local state. Verify no duplicate release, changed attachment, unreviewed cleanup, or publication before complete verification. Validate the provider protocol in a separately authorized disposable repository/draft rehearsal before claiming publication recovery support; ordinary plan implementation does not publish a real Nagare release.

Run the existing release validation in rehearsal mode. Do not pick a release version, tag, publish, or upgrade existing live contexts merely to complete this plan. Record results in this plan and the parent registry. Review all child Decision Logs/Surprises/Outcomes and update ADR 22 and the affected existing ADRs with durable lessons. Mark IR-24 addressed only after its full acceptance has evidence.


## Concrete Steps

Run the deterministic checks from repository root in the existing development environment:

```bash
(cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=direct)
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
(cd infra/pulumi && npm run build && npm test)
bash scripts/test-release.sh
nix flake check
```

Use the established native-system release checks for each supported system in release.json; a Darwin run does not substitute for Linux host activation. Never manually search/read /nix/store even when Nix reports an output there.

The new live launcher has the following required interface. Set these task-specific variables to a separately authorized disposable context and its expected project; the launcher refuses missing values or mismatch.

```bash
: "${NAGARE_TEST_CONTEXT:?set an explicitly disposable context}"
: "${NAGARE_TEST_PROJECT:?set its exact GCP project}"
bash scripts/rehearse-managed-resources.sh \
  --context "$NAGARE_TEST_CONTEXT" \
  --expected-project "$NAGARE_TEST_PROJECT" \
  --evidence-dir .tmp/managed-resource-rehearsal
```

The launcher must print the reviewed identities and evidence location, fail nonzero on any mismatch, and refuse to overwrite different completed evidence. Define a local-mode variant with explicit expected cluster identity and no GCP calls. Document its exact invocation when implementing the launcher.


## Validation and Acceptance

The seven verification cases in IR-24 are all covered: cross-provider/logical collisions before mutation; reviewed adoption; ordered data-preserving rename; component resume; distinct drift categories; real disposable convergence/no-op/removal; and immutable release evidence. Additionally prove app-only revisions preserve platform/other apps, shared contributions do not clobber peers, unknown secret reads never rotate credentials, and compiled resource membership equals actual executor coverage.

All supported entry points are accounted for and superseded policy scripts are removed. Both installed clone-free packages and source workflows use the same model. No schema decoder or public constructor can bypass the reviewed execution boundary. Inventory store backup/restore, journal corruption, concurrent writer, stale review, and secret redaction tests pass. Do not report complete if live rehearsals, native-system evidence, or legacy recovery compatibility remain missing.


## Idempotence and Recovery

Never mutate immutable release attachments or old transaction evidence. A failed rehearsal retains its private journal and reviewed resources for resume or explicit cleanup. Cleanup uses the same inventory policy and cannot target a context root/provider project broadly. A failed upgrade leaves the old context pin with truthful partial component progress. Return to an old release only where existing compatibility and data policy permit it; otherwise use planned forward recovery.


## Interfaces and Dependencies

This plan integrates, rather than redefines, the EP-144 resource schema, EP-145 journal, EP-146 native adapters, EP-147 cluster declarations, EP-148 scope commands, and EP-149 lifecycle decisions. It owns upgrade compatibility glue, coverage completion, packaged evidence manifests, and final release checks. The shared review/evidence format includes an explicit schemaVersion and immutable member digests; release metadata references it without duplicating its fields as a second authority.

It also owns the GitHubRelease adapter and publication-only durable provider envelope. That envelope consumes the same review/receipt types but has explicit draft-to-published recovery semantics; it is not permission to put ordinary context inventory history in release assets. EP-145 remains the owner of general transaction types.

The older replacement initiative in docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md remains independent and partially implemented. This work preserves its existing safety core and exposes inventory bindings; it does not claim its pending live replacement adapters are delivered. Consult Mori for dependency APIs and authoritative releases before compatibility changes. No library/tool upgrade or external release publication is prescribed by this plan.


## Revision Notes

2026-09-16: EP-151 became a hard dependency and the ADR 13 question in M2 was replaced by a check of what EP-151 delivered, after the operator added the shared store as the eighth child.

2026-09-16: Cascaded from the MasterPlan's pre-implementation API validation. M2 now requires reconciling ADR 13's new-machine consequence with the workstation-local inventory store.
