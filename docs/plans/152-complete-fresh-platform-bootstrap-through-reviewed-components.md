---
id: 152
slug: complete-fresh-platform-bootstrap-through-reviewed-components
title: "Complete fresh platform bootstrap through reviewed components"
kind: exec-plan
created_at: 2026-09-26T20:29:54Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T20:29:54Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-26T22:23:39Z
      mode: "update"
      note: "Cascade EP-148 decomposition: assign remaining feature, cutover, and proof ownership without weakening release acceptance"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T23:30:57Z
      mode: "implement"
      note: "Bind reviewed bootstrap marker to selected immutable payload during execution"
---

# Complete fresh platform bootstrap through reviewed components

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


A fresh context selected from one immutable payload can be planned, applied, resumed, and reported as converged through the reviewed component engine. The final cluster marker appears only after all required receipts and readiness checks. This completes production bootstrap wiring; the full application/data and provider rehearsals are separate mandatory release gates.


## Progress


- [ ] M1: Fresh local/cloud bootstrap produces complete platform-only reviewed stages, including foundation and host prerequisites, without requiring an already-created target cluster.
- [ ] M2: Public bootstrap apply/resume preserves completed receipts, emits the final inventory-bound marker only after convergence, and rejects changed payload intent after admission.

Inherited baseline: commits `9c308390`, `28e05b72`, and `09d83188` supplied explicit payload/workspace composition, fresh-context policy, and eleven legacy entrypoint refusals. These are not new work. Remaining production cloud/host assembly and final-marker proof are the acceptance gap.

2026-09-26 handoff: The reviewed marker now includes the immutable payload ID and the execution factory checks its retained native bytes against the selected payload identity and context pin before constructing provider adapters. This covers the marker-bearing review on apply and resume. Focused inventory tests, the CLI build, Haskell style check, and entrypoint guards passed. Both milestones remain open: fresh prerequisite stages, complete cloud/host composition, public-command interruption fixtures, and native marker smoke have not been proved.

2026-09-26 handoff: The marker also binds the exact desired platform scope generations and canonical digests, excluding its own scope so the value is stable. Unrelated application scopes cannot change its vector or dependencies. Pulumi preview, saved-plan apply, and convergence checks now target the reviewed resource URN; a preview containing another mutating resource is refused. Focused inventory tests and the CLI build passed. M1 still needs the actual cloud, artifact, host, and local prerequisite declarations and public stage dispatch; M2 still needs public interruption fixtures and native marker proof.

2026-09-26 handoff: Bootstrap reviews now record `nagare-bootstrap:<payloadId>` in the immutable review document. Public bootstrap apply requires that review class, and generic inventory resume/recovery also checks a bootstrap review against the currently selected payload and context pin before adapters are created. This protects prerequisite-only stages that have no final marker. The public planning path still needs real prerequisite stages before the Kubernetes version read.

2026-09-26 handoff: A cloud foundation stage now compiles the seven required project APIs and the deduplicated GCS state buckets as platform resources with a dedicated executor. The public bootstrap planner uses the local inventory journal for that first stage, before a Pulumi backend or Kubernetes API exists. Apply retains its review and receipts and migrates the local history to the configured GCS inventory store after convergence. Named initialization and context selection defer their API and state-bucket effects to this review. A recording public-command fixture planned eight resources from an empty cloud context, applied the local-store variant, verified the accepted/converged head, and refused a changed backend URL without a provider write. M1 remains open for the Pulumi, artifact, host, cluster, and local stage builders; M2 remains open for public interruption/resume and native final-marker proof.

2026-09-26 evidence for candidate source revision `b8b43a6a`: `bash scripts/test-bootstrap-foundation-public.sh <built nagarectl>` used isolated contexts `fresh` (GCS inventory, no cloud objects) and `freshlocal` (local journal, recording gcloud). It observed eight foundation operations, no provider write during planning, a converged apply with one accepted/converged scope, and changed-backend refusal before effects. The fixture and assertions live in `scripts/test-bootstrap-foundation-public.sh`; transient logs were intentionally removed with the fixture. `cabal test nagarectl-test --test-show-details=failures`, focused inventory tests, `cabal build exe:nagarectl`, `bash scripts/test-inventory-entrypoint-guards.sh <built nagarectl>`, and `bash scripts/check-haskell-style.sh` passed. The public fixture does not emulate GCS history migration or prove later stages.

2026-09-26 continuation: The optional Pulumi backend IAM member is now stored in named contexts and bound to the foundation bucket declaration and retained execution target. The grant applies only to the Pulumi state bucket when the inventory journal uses another bucket. The public recording fixture exercises its grant and refuses a changed stored member before writes. Pulumi's seeded config disables its duplicate ownership of the seven foundation-managed APIs. The inventory Pulumi adapter now supplies the complete registration set to the TypeScript guard while targeting individual operations. The later cloud stage still needs to seed that config, construct its complete typed candidate, and prove native targeted previews.

2026-09-26 evidence for candidate source revision `443a1b15`: `cabal test nagarectl-test --test-show-details=failures -v0`, focused inventory tests, `cabal build exe:nagarectl -v0`, `bash scripts/test-bootstrap-foundation-public.sh <built nagarectl>`, `bash scripts/test-inventory-entrypoint-guards.sh <built nagarectl>`, `bash scripts/check-haskell-style.sh`, and `git diff --check` passed. The public fixture recorded a grant to the Pulumi bucket and refused changed stored member and backend URL before provider writes. The two-bucket focused test proved that the inventory bucket received no grant. This is foundation and registration-contract evidence, not a complete cloud stage.

2026-09-26 continuation: The foundation scope now owns the Pulumi stack and its exact plain-text seed config as a ninth reviewed resource. Its target binds the selected context, backend URL, workspace, home, backend bucket, and seed values. The public context-selection path requires that reviewed stack rather than creating or reseeding it. Foundation readiness inspects physical services, buckets, stack, and config, so observed drift returns to a focused review. The Pulumi backend selection is pinned from the stored context even if the shell names another backend. M1 still needs the cloud, artifact, host, cluster, and local stage builders; M2 still needs public interruption/resume and native final-marker proof.

2026-09-26 evidence for candidate source revision `1c4e7723`: `cabal test nagare-dsl-test --test-show-details=failures -v0`, `cabal test nagarectl-test --test-show-details=failures -v0`, `cabal build exe:nagarectl -v0`, `bash scripts/test-bootstrap-foundation-public.sh <built nagarectl>`, `bash scripts/test-inventory-entrypoint-guards.sh <built nagarectl>`, `bash scripts/check-haskell-style.sh`, and `git diff --check` passed. The isolated public fixture planned nine resources before a Pulumi call or Kubernetes read, applied all foundation operations with a recording cloud provider, planned one reviewed service repair after an observed API drift, and initialized a separate real local Pulumi stack with the seeded config. This is not native GCS stack or complete cloud-stage evidence.

2026-09-26 continuation: Cloud infrastructure preparation now selects the reviewed stack without creating a missing stack outside the foundation review. The Pulumi inventory runtime passes its retained backend URL explicitly to every subprocess. The TypeScript program parity fixture covers the foundation-managed configuration and confirms that disabling Pulumi API ownership removes exactly seven API registrations, leaving 24 other cloud registrations to declare in ordered stages. Candidate source revision `0444fc12` passed `npm test` in `infra/pulumi`, `cabal test nagarectl-test --test-show-details=failures -v0`, `cabal build exe:nagarectl -v0`, the public foundation and entrypoint-guard shell fixtures, Haskell style, and `git diff --check`. The 24-resource cloud candidate and stage dispatch remain unimplemented.

2026-09-26 continuation: The public bootstrap planner now admits the foundation-managed Pulumi program through dependency layers before it reads Kubernetes. A catalog in the immutable Pulumi program names the 24 base registrations, their parents, and their review layers; the TypeScript fixture checks its membership against the actual program, including the optional three-resource Nix cache delta. Resources outside the admitted layer receive explicit native bookkeeping registrations while every admitted resource has its own reviewed inventory operation. The planner checks accepted Pulumi URNs against read-only stack export before advancing, so a missing resource returns to a focused repair review. Named contexts pin the Nix cache choice and bucket against inherited shell values. M1 remains open for the registered image/VM/CDN variants, exact cloud resource policies, artifact and host prerequisites, local staging, and cluster dispatch. M2 remains open for interruption/resume and final-marker proof.

2026-09-26 evidence for candidate source revision `733906e1`: `npm test` in `infra/pulumi`, `cabal test nagarectl-test --test-show-details=failures -v0`, `cabal build exe:nagarectl -v0`, `bash scripts/test-bootstrap-foundation-public.sh <built nagarectl>`, `bash scripts/test-inventory-entrypoint-guards.sh <built nagarectl>`, `bash scripts/check-haskell-style.sh`, and `git diff --check` passed. The isolated public fixture converged the nine-resource foundation, then four Pulumi reviews with 1, 9, 9, and 5 operations using a recording provider. It verified accepted/converged journal revisions, no repeated root operation in later reviews, and one reviewed repair after removing a physical URN. The same fixture initialized a separate real local Pulumi stack; cloud resource plans and effects were recorded, not native GCP execution. No host or final marker was reached.

2026-09-26 continuation: The public fixture now loses one acknowledgement after the recording Pulumi provider has written a layer-one resource, then resumes the retained bootstrap transaction through `inventory resume --yes`. The adapter's no-change preview proves that operation complete, the journal continues the remaining operations, and the fixture checks that the affected `pulumi up --plan` ran exactly once. Candidate source revision `d748b3fb` passed `bash scripts/test-bootstrap-foundation-public.sh <built nagarectl>`. This is a public cloud-layer recovery proof, not the required foundation, host, cluster, and pre-marker interruption matrix.

2026-09-26 continuation: The same public fixture now loses the acknowledgement after a foundation API enable has taken effect. `inventory resume --yes` observes that service, records its receipt, finishes the foundation, and the command log shows the affected enable ran once. Candidate source revision `494bfe31` passed `bash scripts/test-bootstrap-foundation-public.sh <built nagarectl>`. The foundation and cloud-layer portions of the interruption matrix have recording-provider evidence; host, cluster, and pre-marker interruption cases and native final-marker proof remain open.

2026-09-26 continuation: The cloud path now inserts reviewed image build and GCE publication stages after the 24 base Pulumi registrations. The first review binds the evaluated Nix output path before the build; the second binds the verified tarball digest and exact project-scoped image destination. The accepted image drives a focused reviewed Pulumi stack-config update and two further Pulumi registrations for the VM component and GCE instance. The public fixture reaches all these stages without an existing Kubernetes API. It loses the GCE registration acknowledgement after the provider write, then resumes from the image digest stamp without repeating registration. A separate host scope depends on the VM, compiles the context's flake and lock digests, and produces guarded creation and activation operations. The fixture commits a host closure while hiding the commit acknowledgement; `inventory resume --yes` verifies the committed closure and finishes without activating twice. M1 remains open for bounded IP/registry/credential preparation, local-mode stages, and full cluster dispatch. M2 remains open for cluster and pre-marker interruption, changed context/payload proof across these new stages, unchanged idempotent bootstrap, and native final-marker proof. Host drift observation currently confirms VM identity and relies on activation receipts; it does not yet compare the accepted closure on a later plan.

2026-09-26 continuation: The public fixture changes the named context's platform-version pin after saving the reviewed image build, then confirms apply refuses before Nix starts. It restores the pin and applies the retained review. The host transport now checks the reviewed flake/module and lock digests before preparation or activation, while still allowing recovery inspection after a completed effect. The changed-payload case is proved for this build stage; changed context/payload coverage across cluster and marker stages remains open.

2026-09-26 continuation: After the host receipt, bootstrap now fetches the remote k3s kubeconfig through the project-confined IAP reader into a private prepared copy. The public plan binds its normalized content digest and host dependency; only the reviewed artifact operation atomically installs the context kubeconfig with mode 0600. The recording fixture proves the final file is absent during planning, its credential fields are absent from the public review JSON, and the installed bytes match the review. It hides the acknowledgement after the final file rename; `inventory resume --yes` observes the digest and completes without a second write. The six accepted platform scopes are converged. This reaches the first cluster-dependent planning boundary only after the image, VM, host, and kubeconfig receipts. Cluster compilation, local-mode stages, and the final marker are still open.


## Surprises & Discoveries


2026-09-26: A published inventory review preserves exact native bytes, but the generic apply/resume route did not compare a bootstrap marker's retained payload identity with the operator's current selection. The marker previously omitted `payloadId`, so distinct immutable payloads with the same version and source revision could not be distinguished at execution. The marker now records that ID and the execution factory refuses a mismatch before adapter construction. This does not yet bind prerequisite-only reviews; their stage contract remains to be built in M1.

2026-09-26: The Pulumi adapter previously prepared a whole-stack saved plan for each resource operation. A single operation could therefore execute changes assigned to several journal operations before those operations had receipts. Targeted Pulumi preview and apply are supported by the registered CLI source; the adapter now targets each operation's declared URN and refuses additional mutations. Cloud stage assembly must still order prerequisite resources so every targeted preview can be prepared from the current physical state.

2026-09-26: Generic inventory reviews used a constant `operator-cli` payload identity, which left prerequisite-only bootstrap stages without a payload binding. The planner now accepts a bootstrap-specific identity, and execution checks it before loading provider contracts. No prerequisite-only stage is yet publicly plannable because cloud/local foundation assembly remains outstanding.

2026-09-26: A new cloud context can still create its GCS Pulumi state bucket through `bootstrapGcsIfNeeded` during `init` or `context create`, before any inventory review. `ensurePulumiForContext` then selects the configured backend. M1 must move that first bucket effect into an explicit reviewed stage or a reviewed adoption handoff; merely adding later cloud declarations would leave the fresh-bootstrap acceptance gap open.

2026-09-26: Pulumi and inventory backend URLs can name the same global GCS bucket. The first foundation candidate initially minted two resource IDs for that one address; it now deduplicates by bucket name. The runtime distinguishes a successful project-scoped list showing absence from a failed list, asserts the target project number before any bucket update or IAM grant, and treats an uncertain write as unresolved. A changed backend URL is checked against the retained foundation declaration before an execution adapter is used.

2026-09-26: The selected shell can carry a Pulumi backend URL from another context even while the inventory store URL is pinned by the context file. The first public fixture found two different bucket candidates because of this inherited environment value. The foundation review now binds the selected bucket set and the execution adapter checks it again; the fixture clears inherited URLs explicitly. The next cloud stage must account for both foundation API ownership and Pulumi's existing `manageProjectApis` registrations so one provider does not claim the same API twice.

2026-09-26: The named initialization and context-selection paths now defer first cloud writes, but unnamed legacy `init` still uses its old direct API and bucket setup. Its admitted-context guard remains intact. Resolve that remaining fresh legacy path before claiming every bootstrap entrypoint is reviewed. The optional backend IAM member is now retained in the context and reviewed with the Pulumi bucket; a distinct inventory bucket does not receive that grant.

2026-09-26: The Pulumi program requires declarations for every registered provider or component resource, even when a saved preview targets one URN. Filtering the runtime bundle to only selected operations makes the guard fail before a review can be prepared. The adapter now receives all composed registrations; a later native fixture must confirm the complete cloud topology and per-operation mutation boundary.

2026-09-26: An isolated native Pulumi experiment applied two saved plans for independent component targets in sequence from one initial stack snapshot. A parent-child variant refused a child-only targeted preview before its parent existed: the diagnostic named the missing dependency target. The cloud builder therefore has to stage dependent provider resources in order; same-stage independent targets still need topology and convergence proof in Nagare's actual program.

2026-09-26: The image upload script already built the Nix output inside publication, so the tarball digest was unavailable to a prior immutable review. A reviewed build-job artifact now binds the evaluated output path; the later publication review derives the tarball digest without building. The GCE transport originally passed a bare digest to a script expecting `sha256:<digest>`, exposed by the public apply fixture and corrected. The host transport likewise emitted a prefixed proof that its typed decoder rejected; the lost-acknowledgement fixture exposed and corrected that mismatch.

2026-09-26: The first cloud-layer fixture exposed duplicate primary/alias claims when a Pulumi URN was both the resource address and its native alias. The cloud compiler now omits an alias equal to its primary address. The same fixture exposed an inherited Nix cache flag that changed a named context's registration count from 24 to 27; the selected profile now pins that choice and its bucket to the stored context.


## Decision Log

2026-09-26: Redirect unfinished EP-148 dependencies to EP-158–161 and preserve this plan’s assigned integration, package, or release obligations. EP-148 is superseded history, not a pending completion gate.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.

2026-09-26: Bind the final marker to platform scope revisions and payload identity. Application, standalone, and publication revisions remain independently owned; changing one does not alter platform bootstrap completion. The marker scope is excluded from its own digest to avoid a self-reference.

2026-09-26: Put pre-Pulumi APIs and state buckets under a dedicated cloud-foundation executor. Publish that first review to the local context inventory store, then use the existing conditional history migration after the bucket receipt is accepted. The Pulumi backend cannot be opened to store the review that creates its own bucket.

2026-09-26: Use one public review per admitted Pulumi dependency layer. Keep the full native registration set visible to the TypeScript guard as managed or explicit bookkeeping, while journal operations target only resources in the admitted layer. Read-only stack export selects a repair layer when a previously accepted URN is absent.


## Outcomes & Retrospective


Implementation remains partial. Marker identity and scope-vector checks, targeted Pulumi operations, image publication, and host activation have focused test and public recording-fixture evidence. The recording fixture reaches the VM and host receipts; it is not a local bootstrap, native GCP/cloud-cluster convergence, or final-marker acceptance run. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator requested decomposition without reduced functionality or validation; temporary refusal of promised behavior is not completion.

cli/nagarectl/app/Main.hs contains runPlatformBootstrapPlan and buildPlatformCandidate. The builder currently reads a Kubernetes version before assembling cluster components, accepts immutable auth images, compiles local object store/auth/observability/cache resources, and calls composePlatformChanges. This is substantial cluster composition, not yet proof that a cloud context can create its foundation and host before Kubernetes exists. cli/nagarectl/src/Nagare/Inventory/Bootstrap.hs enforces platform-only composition; Cloud.hs, Host.hs, and their adapters supply existing provider contracts. compileBootstrapStamp in cli/nagarectl/src/Nagare/Inventory/Bootstrap.hs owns the final marker. Preserve the existing selected-payload and retained-workspace checks.


## Plan of Work


M1 connects existing cloud/host/artifact builders to fresh bootstrap, with the state bucket and other prerequisites represented explicitly. Separate bounded preparation reviews where an IP, registry, credential, or kubeconfig must exist before the next native plan can be prepared; each stage declares its full membership before mutation. Do not call cluster observations before the cluster exists. A source fixture for both modes must assert exact producer/consumer edges, platform-only scope changes, context binding, and preservation of unrelated app/standalone/publication generations. Keep the generic registry and journal; no bootstrap-specific second store.

M2 drives the existing public `platform bootstrap plan --out` and `platform bootstrap apply` routes through those stages. Test lost acknowledgement after foundation, host, cluster components, and just before the marker. Proven completed work is not reapplied, an unresolved write refuses, and a final marker binds the accepted scope vector and payload. A second unchanged bootstrap does not create updates merely because a timestamp changed. Changed context/payload version after admission refuses before provider effects. Retain inspection of old transactions and compatibility refusals; do not revive in-place platform upgrade work.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p inventory' --test-show-details=failures)
(cd cli/nagarectl && cabal build exe:nagarectl)
bash scripts/test-inventory-entrypoint-guards.sh
bash scripts/check-haskell-style.sh
```

Expected result: relevant checks exit zero; refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance


A recording public-command fixture begins with no cloud objects, host, or Kubernetes API, yet can plan only the prerequisite stage instead of failing on a premature Kubernetes read. Subsequent stages use exact accepted outputs. Every write has a reviewed resource and journal operation. Wrong project, changed pin, changed native bytes, and foreign scope mutations refuse without effects. Failure before the last dependency leaves no success marker; resume after a proven write does not repeat it. A disposable native bootstrap command smoke must exercise the final marker; its run can be shared with EP-155 rather than repeated. Full local/GCP application and recovery scenarios are not claimed by that smoke.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Hard prerequisites [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md), and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) are Complete. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) and [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) consume these bootstrap stages; they do not redefine them. Own bootstrap dispatch and the platform candidate, while [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) owns the complete command audit. Share Main.hs edits carefully. Neither superseded EP-148 closure nor completion of its feature successors EP-158–161 is required to implement bootstrap. Initial estimate: 8–16 active hours, low confidence; reforecast after the first fresh cloud preparation reaches a saved plan without an existing cluster.
