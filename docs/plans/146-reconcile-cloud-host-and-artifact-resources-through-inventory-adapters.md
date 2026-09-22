---
id: 146
slug: reconcile-cloud-host-and-artifact-resources-through-inventory-adapters
title: "Reconcile cloud host and artifact resources through inventory adapters"
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
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-22T13:49:36Z
      mode: "implement"
      note: "Begin EP-146 cloud host and artifact adapters"
---

# Reconcile cloud host and artifact resources through inventory adapters

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

Cloud provisioning, guarded host activation, and artifact publication become visible in the same inventory and reviewed operation protocol. A cloud bucket cannot be independently claimed by an image publisher and Pulumi. A resumed upgrade skips proven infrastructure and host work while still reporting current health honestly.

This plan implements native adapters, not a replacement provider engine. Pulumi keeps its saved-plan semantics, NixOS keeps its self-reverting activation, and publishers verify immutable content.


## Progress

- [x] (2026-09-22) M1: Compiled cloud declarations, enforced TypeScript native-registration parity, and bound exact Pulumi saved-plan bytes to review.
- [x] (2026-09-22) M2: Bound guarded host activation, physical identity, committed closure, and fresh-login acknowledgement to durable receipts.
- [ ] M3: Declare artifact publication, bootstrap prerequisites, and control metadata.
- [ ] M4: Route cloud/host/publication entry points through adapters and remove duplicate policy.


## Surprises & Discoveries

2026-09-22: EP-145 plans one common operation per changed declaration, while a Pulumi preview and saved plan cover the whole stack. The Pulumi adapter therefore validates every mutating preview URN against the complete declaration bundle and binds each common operation to the same exact native bytes; apply may verify an already-converged later operation rather than replaying a changed native plan. This preserves one Pulumi saved-plan authority without introducing per-resource cloud mutations.

2026-09-22: The existing safe-switch protocol already distinguished arm, test activation, commit, and automatic reversion, but its successful client output was only human-readable. It now emits one machine-readable receipt after both a fresh SSH login and the on-host `COMMITTED` response. The adapter hashes that exact record and refuses local flake/version evidence as completion.


## Decision Log

2026-09-16: Give the cloud foundation sole lifecycle ownership of the image bucket. Image publication consumes it. Existing upload-created buckets require explicit adoption/import, not implicit reassignment.

2026-09-16: Preserve native execution groups. The common inventory lists individual resources, but a Pulumi saved plan remains one constrained executor operation.

2026-09-16: Publication must not silently change Pulumi configuration after review. Resolve inputs first where possible; otherwise use a bounded preparation transaction followed by a new native-plan review.

2026-09-16: Stamp identity and the resource's own spec digest, never the scope revision, and produce saved plans through the shared prepare method. A scope revision in provider metadata would make every deploy rewrite every resource in the scope.

2026-09-22: Use a canonical Haskell cloud bundle as the ownership source and a Pulumi stack transformation as the TypeScript consumption boundary. The transformation sees component and provider registrations before creation, rejects undeclared `gcp:` or `nagare:` registrations, and requires every declared registration to be consumed. The retained adapter bundle is a canonical redacted header followed by the exact opaque Pulumi plan bytes.

2026-09-22: Add `ActivateHost` to the closed declared-operation vocabulary rather than treating host switching as an arbitrary shell action. Recovery is automatic only before activation or after a proven reversion; a timer-armed, unreachable, wrong-instance, or wrong-closure host remains unresolved. The adapter never cancels a rollback timer to satisfy inventory execution.


## Outcomes & Retrospective

Not implemented. Record adapter parity and recovery evidence at completion.


## Context and Orientation

Hard dependencies are [typed scopes and inventory](144-define-typed-resource-scopes-and-validate-composed-inventories.md) and [reviewed execution](145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md). They supply independent scope revisions, canonical claims, typed outputs, private state, reviewed operation groups, and journal/recovery interfaces. All adapters implement Nagare.Inventory.Adapter; do not add another transaction engine.

[Lifecycle policy](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md) is a soft integration dependency. This plan can prove fresh provisioning and unchanged owned-resource convergence independently; real legacy adoption, ownership transfer, and retirement remain unavailable until that policy and adapter preconditions are integrated.

Cloud membership is constructed in infra/pulumi/index.ts and src/components/NagareNetwork.ts, NagarePerimeter.ts, NagareInstance.ts, NagareCdn.ts, and NagareNixCache.ts. cli/nagarectl/src/Nagare/Infra/Plan.hs retains native plans; Platform/PulumiReceipt.hs binds successful applies to them. scripts/upload-images.sh currently creates the image bucket if absent, publishes a GCS object/GCE image, and changes nagareImageSelfLink in Pulumi configuration. NagarePerimeter also declares that bucket. These paths need one declaration source.

Host inputs and selection live in Host/Config.hs, Host/AgeKey.hs, scripts/host-switch.sh, and scripts/upload-images.sh. nixos/lib/nagare-safe-switch-client.sh and nagare-safe-activate.sh implement the remote rollback timer and fresh-login commit protocol. Current upgrade host resume checks the local flake version, which does not prove the remote committed system closure.

[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) separates host and GCE names and protects operator files. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) confines each cloud write and checks actual bucket ownership. [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) requires self-reverting activation. [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) makes growth forward-only. [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) protects replacement. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) preserves reviewed native plans. [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) prevents generic rollback after candidate writes. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) supplies inventory authority.


## Plan of Work

### M1 — Cloud declarations and native plan parity

Add cli/nagarectl/src/Nagare/Inventory/Cloud.hs and Adapters/Pulumi.hs. Introduce infra/pulumi/src/resourceDeclarations.ts and a versioned wire contract under schemas/ deriving resource registration inputs from the validated declaration bundle. Haskell owns common identities/policies; TypeScript owns provider constructor mappings. Do not maintain a second Haskell list independently mirroring the constructors.

Make Pulumi component constructors consume those inputs. Every native registration, including IAM members, API enablement, CDN/DNS objects, HMAC credentials, disks, and provider/component bookkeeping, is either a declared managed resource or explicitly classified native bookkeeping covered by its executor group. Registration parity tests reject unaccounted creates/updates/deletes and owner/address disagreement. Existing Pulumi logical names, parents, aliases, and protections must remain stable during adoption to avoid accidental replacements.

Inventory aliases include native URN and provider address. Bind actual generated IPs/IDs to declared typed outputs. Credentials remain secret references. Stamp logical ID, context, and owning component where native metadata supports them; use private digest-verified state plus physical identity where it does not. If a desired revision is stamped, it is that resource's own spec digest, computed over the spec without the stamps. Never stamp the scope revision: it changes on every deploy of the scope, so every label-bearing cloud resource would show an update in each Pulumi preview and the unchanged-rerun acceptance could not hold. Project guard, ADC checks, backend/stack binding, protected replacement decisions, and --plan execution remain mandatory per mutation.

Expose duplicate-cloud-claim fixtures before Pulumi execution. Producing the saved plan is the Pulumi adapter's prepare method, which EP-145's prepareReview calls during planning; preflight under the lock only re-checks that the retained plan, stack, backend, and project still match. Verify the saved plan covers only declared resources and its native preview agrees with the common review. If the provider reports an unknown operation or unaccounted native resource, refuse rather than guessing.

### M2 — Host receipts

Add Inventory/Adapters/Host.hs. Represent host configuration as the desired evaluated system closure and explicit activation operation, plus separately managed durable mounts, identity inputs, credentials, and delegated services. Do not inventory every Nix derivation/file as independently deletable infrastructure.

Bind the operation to context, generated host attribute, GCE physical instance, connection destination, configuration/lock digests, expected old closure, new closure, and activation transaction identity. Preserve host.nix and encrypted secrets. Keep the existing remote safe-activation scripts as narrow transport/protocol adapters; move local ownership, planning, and resume decisions into Haskell.

Capture committed closure and the on-host acknowledgement after fresh-login verification. A matching local flake version is not sufficient completion. Distinguish interrupted-before-activation, timer-armed/test-active, committed, reverted, and unreachable observations. Never cancel a rollback timer merely to make an inventory transaction succeed. Receipt verification can prove a completed operation; current remote health is separate and checked when a dependent operation needs it.

Include age-key delivery, host configuration generation, VM power, and image-builder lifecycle in the mutation coverage catalogue. Private-key bytes stay out of arguments, inventories, reviews, and receipt logs. For a deliberate shared builder, retain the exact project acknowledgement required by existing guards.

### M3 — Artifacts and bootstrap ordering

Add Inventory/Adapters/Artifact.hs and the typed artifact specification. Cover context-published OCI images, GCS image objects, GCE images, build jobs/temporary builders, and their retention relationships. Model global immutable release payloads as externally consumed references in deployment contexts; release publication has its own owner scope. Consumers protect artifacts from premature collection across known contexts; unknown consumer completeness blocks automatic global collection.

This child owns artifact types and context publication executors. The actual GitHub release publisher, its workflow migration, and draft-release recovery envelope are owned by [the final integration plan](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); do not claim they are migrated by adding artifact types alone.

Make image bucket/state bucket/API bootstrap explicit operations in the cloud foundation. Where creating them is needed before the main stack can run, record the exact adoption/import handoff into Pulumi; do not let both helpers own them. Initial bootstrap can use a reviewed local transaction before the remote state backend exists, then retain/migrate that history. The move is `nagarectl inventory store migrate --to gcs` from [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md): the first transaction of a new context necessarily runs on the local inventory store because the state bucket it would live in is one of the resources that transaction creates. Until EP-151 is complete the history simply stays local.

Build locally without external publication when inputs permit; digest-bind build output and destination before review. Remote build submission, bucket creation, registry push, image registration, and Pulumi config changes are mutations and must appear in reviewed operations. If publication produces a required value unavailable during native preview, finish its bounded preparation transaction and request a subsequent review with resolved inputs. No later command may silently rewrite the retained config digest.

Refactor scripts/upload-images.sh, cluster/bootstrap/nix-cache/publish-image.sh, scripts/setup-nix-builder.sh, and image build helpers into typed inputs/results with only necessary transport remaining. Verify remote content and ownership before reusing a named artifact. Preserve previous images and secrets according to policy; a new tag is not proof of immutable identity.

Model cluster version markers, context pins, and generated workspace records as control resources. EP-150 will order their final writes after verified components; this plan supplies typed specifications and adapters, not early success stamping.

### M4 — Entry points and removal

Route infra preview/apply, host-image, host-switch, builder setup/power, image upload, init bootstrap, and standalone publication through the shared planner/executor. A native adapter is an internal implementation detail; invoking a retained shell wrapper directly must enter the same checked command path rather than bypass inventory. The reverse direction is forbidden: an adapter holds the context lock while it runs, so the scripts it calls must be narrow transport that never re-enters an inventory command. EP-145 exports the transaction identity to adapter children and entry points refuse when it is set; add a test that a wrapper invoked from inside an adapter refuses instead of hanging. Preserve explicit teardown/replacement gates until the lifecycle adapter supports their equivalent evidence.

Test existing scripts' behavioral guarantees against the new typed implementations before removing duplicated shell classification and orchestration. Keep transport and remote fail-safe scripts that perform unique work. Record each migrated entry point, owner, adapter, tests, and removed alternate path in docs/architecture/managed-resource-coverage.md, created here and extended by EP-147/148. This catalogue is an audit aid; executable declarations remain authoritative.


## Concrete Steps

Run from repository root. These existing test commands require the development toolchain and installed locked Node dependencies; use npm ci in infra/pulumi if needed.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
(cd infra/pulumi && npm run build && npm test)
bash scripts/test-upload-images.sh
bash scripts/test-bucket-ownership-guard.sh
bash nix/checks/scripts/test-host-switch-identity.sh
```

Add InventoryCloudSpec.hs, InventoryHostSpec.hs, InventoryArtifactSpec.hs to the Haskell test runner and test/resourceInventory.test.ts to the Node test script. Existing shell tests may be replaced when equivalent boundary coverage is demonstrated; update these commands at that point. No live project is used by unit/recording tests.


## Validation and Acceptance

Assert complete declaration/native-registration equality for fresh and existing cloud contexts, cache enabled/disabled, and CDN variants. The bucket double-owner fixture fails before mutation. Wrong physical owner, wrong project/backend, changed saved plan/config/payload/tool version, and unknown address resolution all refuse. Generated output resolution cannot introduce new resource membership.

A receipt-backed successful Pulumi phase resumes with no Pulumi executable or cloud credentials. A successful host phase requires committed-closure evidence, not local version text. Fault injection before and after host commit preserves rollback behavior. Publication refuses wrong remote digest and never silently invalidates a native review. Cache bucket/HMAC and durable disks remain protected. Local-mode fixtures invoke no gcloud.

Live provider validation belongs to the final disposable-context acceptance; do not claim mocks establish provider API correctness.


## Idempotence and Recovery

Retain native bundles unchanged. An interrupted publisher verifies content/ownership before retry; ambiguous host activation follows the remote safe-switch protocol. The common executor must not translate an immutable replacement into delete/create when a data migration or replacement-cutover contract is required. Existing replacement work remains gated; this plan does not activate unfinished candidate adapters.


## Interfaces and Dependencies

Cloud/host/artifact modules implement the shared Adapter interface and return typed observations and receipts. They may not write scope heads directly. Native versions and schema identifiers are part of evidence. Contract tests are the interoperability check between Haskell and TypeScript; JSON Schema alone is insufficient.

Use existing tool and dependency pins. Consult Mori for dependency sources and upstream registries/tags before any compatibility workaround or bound change. Never search/read /nix/store. EP-147 consumes artifact output references and native platform infrastructure; EP-148 consumes shared publication and Kubernetes-neutral cloud contracts. Their fixtures may use declared outputs without running this adapter. Coordinate changes to app/Main.hs and justfile through small registrations rather than competing orchestration engines.


## Revision Notes

2026-09-16: Named EP-151's store migration as the handoff for a new context's first, necessarily local, bootstrap transaction.

2026-09-16: Cascaded from the MasterPlan's pre-implementation API validation. Stamping now uses identity plus the resource's own spec digest and never the scope revision; native planning is the adapter's prepare method under EP-145's prepareReview; adapters may not call wrappers that re-enter inventory commands. The reasons are no-op convergence, a missing planning step in the shared interface, and self-deadlock under the held context lock.
