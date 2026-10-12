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

Full plan before trimming: [146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Cloud provisioning, guarded host activation, and artifact publication become visible in the same inventory and reviewed operation protocol. A cloud bucket cannot be independently claimed by an image publisher and Pulumi. A resumed upgrade skips proven infrastructure and host work while still reporting current health honestly.

This plan implements native adapters, not a replacement provider engine. Pulumi keeps its saved-plan semantics, NixOS keeps its self-reverting activation, and publishers verify immutable content.

## Progress

- [x] (2026-09-22) M1: Compiled cloud declarations, enforced TypeScript native-registration parity, and bound exact Pulumi saved-plan bytes to review.
- [x] (2026-09-22) M2: Bound guarded host activation, physical identity, committed closure, and fresh-login acknowledgement to durable receipts.
- [x] (2026-09-22) M3: Declared owned/external artifacts, bootstrap dependencies, control metadata, digest-bound publication, and consumer-completeness gates.
- [x] (2026-09-22) M4: Registered production cloud, host, and artifact runtimes for shared plan/apply/resume, confined retained transports, and recorded compatibility entry points for EP-150's final removal.

## Surprises & Discoveries

2026-09-22: EP-145 plans one common operation per changed declaration, while a Pulumi preview and saved plan cover the whole stack. The Pulumi adapter therefore validates every mutating preview URN against the complete declaration bundle and binds each common operation to the same exact native bytes; apply may verify an already-converged later operation rather than replaying a changed native plan. This preserves one Pulumi saved-plan authority without introducing per-resource cloud mutations.

2026-09-22: The existing safe-switch protocol already distinguished arm, test activation, commit, and automatic reversion, but its successful client output was only human-readable. It now emits one machine-readable receipt after both a fresh SSH login and the on-host `COMMITTED` response. The adapter hashes that exact record and refuses local flake/version evidence as completion.

2026-09-22: `scripts/upload-images.sh` was a second lifecycle owner for the Pulumi-declared image bucket. It now refuses a missing bucket instead of creating one. When invoked as an inventory artifact child it publishes a bounded result and does not rewrite `nagareImageSelfLink`; the resolved value requires a subsequent Pulumi review. The legacy direct invocation retains its config write until M4 routes the entry point.

2026-09-22: EP-145's initial `adapterVerify` shape omitted the retained native bundle. Host and artifact verification therefore had no sound choice except re-running preparation against mutable inputs. The shared interface now passes `PreparedNative` into verification, and all three adapters decode the exact reviewed bytes. This also preserves offline recovery: already completed operations remain journal proofs and do not require a provider executable merely to be skipped.

2026-09-22: A transaction marker alone cannot safely authorize a retained shell transport. Without an executor-specific child marker, a host adapter could accidentally invoke an artifact publisher (or a nested public wrapper) while holding the same context lock. Execution, verification, and recovery now scope both variables and restore their prior values; every retained EP-146 transport checks its closed child token before resolving context or invoking a provider.

2026-09-22: Separating registry injection from `Inventory.Command` exposed the remaining M4 boundary precisely. The common planner/executor can now accept real domain adapters without provider orchestration in `app/Main.hs`, but the shipped CLI still selects the refusing registry. `docs/architecture/managed-resource-coverage.md` records those public entry points as `adapter-ready`, not migrated; M4 remains open until production registry construction replaces the old infra/host/publication paths.

2026-09-22: The prior Pulumi adapter stopped at an injected interface. A production subprocess runtime now derives native registrations back from compiled declarations, installs the TypeScript declaration guard for every provider invocation, creates a saved plan only during preparation, applies the exact retained bytes, observes physical IDs from stack export, and verifies with `preview --expect-no-changes`. A recording test proves only one `--save-plan` call and checks the retained plan reaches `pulumi up`. The runtime identity also now includes payload ID and digest, which the first header had accidentally omitted.

2026-09-22: Cloud command registration is now live without changing the existing reviewed-plan format in place. `nagarectl infra preview --inventory COMPILED_DIRECTORY --save-plan REVIEW` selects the shared planner and Pulumi adapter; `infra apply --plan REVIEW --yes` recognizes an inventory review by its checksum member; and `inventory resume` reconstructs the same runtime from the private retained review. The old Pulumi-only preview path remains for compatibility and must be removed only after all generated production declarations and upgrade callers have migrated.

2026-09-22: Generic artifact scopes initially discarded publication kind, destination, spec digest, and consumer completeness. That made a same-process adapter test pass while clean-process apply/resume could not reconstruct its authority. `ArtifactPublication` now retains those fields in the canonical scope wire, and both artifact and host runtimes are rebuilt from reviewed scopes rather than mutable in-memory bundles.

2026-09-22: Real Pulumi component children have parent-qualified URN types (`parent$type`), while the first flat bucket fixture did not. Registration recovery and the TypeScript decoder now compare the leaf provider type. The actual resource program is executed under Pulumi mocks for base, image, cache, and all three CDN certificate modes; 31 base registrations and each exact conditional delta are duplicate-free and are replayed through the declaration guard.

2026-09-22: The master plan assigns final upgrade integration and removal of remaining public compatibility paths to EP-150. M4 therefore completes the domain-registration responsibility here: any reviewed cloud, host, or supported artifact scope selects a real runtime for plan, apply, and clean-process resume. The old upgrade/Just entry points remain visibly classified as compatibility paths, not as migrated inventory authority; EP-150 must remove them before the initiative can complete.

## Decision Log

2026-09-16: Give the cloud foundation sole lifecycle ownership of the image bucket. Image publication consumes it. Existing upload-created buckets require explicit adoption/import, not implicit reassignment.

2026-09-16: Preserve native execution groups. The common inventory lists individual resources, but a Pulumi saved plan remains one constrained executor operation.

2026-09-16: Publication must not silently change Pulumi configuration after review. Resolve inputs first where possible; otherwise use a bounded preparation transaction followed by a new native-plan review.

2026-09-16: Stamp identity and the resource's own spec digest, never the scope revision, and produce saved plans through the shared prepare method. A scope revision in provider metadata would make every deploy rewrite every resource in the scope.

2026-09-22: Use a canonical Haskell cloud bundle as the ownership source and a Pulumi stack transformation as the TypeScript consumption boundary. The transformation sees component and provider registrations before creation, rejects undeclared `gcp:` or `nagare:` registrations, and requires every declared registration to be consumed. The retained adapter bundle is a canonical redacted header followed by the exact opaque Pulumi plan bytes.

2026-09-22: Add `ActivateHost` to the closed declared-operation vocabulary rather than treating host switching as an arbitrary shell action. Recovery is automatic only before activation or after a proven reversion; a timer-armed, unreachable, wrong-instance, or wrong-closure host remains unresolved. The adapter never cancels a rollback timer to satisfy inventory execution.

2026-09-22: Model deployment-context release payloads as external artifact references, while context-built OCI/GCS/GCE outputs, builders, build jobs, and control markers can be owned resources. Publication verifies exact remote content and ownership. Automatic collection refuses when global consumer completeness is unknown; EP-149 remains responsible for the eventual lifecycle decision rather than this adapter inventing deletion authority.

2026-09-22: Treat the retained native bundle as an input to verification, not only to preflight, execution, and recovery. Regenerating a host, artifact, or Pulumi preparation after an effect would sever the completion proof from the operator-reviewed bytes.

2026-09-22: Export a closed executor token (`kubernetes`, `pulumi`, `host`, or `artifact`) beside the transaction identity for adapter child processes. A transport accepts inventory-scoped execution only for its owning token and refuses all others before side effects. Public command routing still goes through a separately injected adapter registry.

2026-09-22: Treat Pulumi's subprocess runtime as part of the adapter, not `Main.hs` orchestration. Preparation alone may use `--save-plan`; execution consumes retained plan bytes; verification may observe a no-change preview but cannot create new authority. Bind payload identity/digest alongside context, project, stack, backend, program, config, and tool version.

2026-09-22: Treat typed scope bytes as the only restart contract. Artifact execution specifications and host operation inputs must be recoverable from retained scope declarations; no adapter may rely on the process that compiled the candidate still holding a richer domain bundle.

2026-09-22: Complete EP-146 at the domain adapter boundary defined by the master plan. EP-150 owns final upgrade integration and removal of compatibility entry points, while EP-151 owns first-context store bootstrap/migration. Those paths stay explicit in the coverage catalogue and are not counted as migrated here.

## Outcomes & Retrospective

Completed on 2026-09-22. Cloud preparation creates exactly one saved plan and applies those retained bytes; the real TypeScript program's base/image/cache/CDN variants pass complete registration consumption. Host preparation retains the evaluated closure, physical GCE identity, expected old closure, and activation inputs; execution uses that exact closure and verification requires committed boot/running state after a fresh connection. Artifact scopes retain enough typed data for clean-process reconstruction, and OCI/GCE publication transports require the reviewed destination and digest before mutation.

Focused Haskell, TypeScript, and shell suites cover wrong digests, ownership mismatch, timer-armed recovery, child-token confinement, nested Pulumi URNs, and exact subprocess inputs. No live cloud project was mutated; disposable-context provider evidence remains correctly assigned to EP-150. The coverage catalogue preserves the old upgrade, Just, VM-power, builder, and init/bootstrap paths as compatibility or planned work rather than overstating migration.

