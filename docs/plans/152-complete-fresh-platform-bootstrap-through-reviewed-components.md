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


## Surprises & Discoveries


2026-09-26: A published inventory review preserves exact native bytes, but the generic apply/resume route did not compare a bootstrap marker's retained payload identity with the operator's current selection. The marker previously omitted `payloadId`, so distinct immutable payloads with the same version and source revision could not be distinguished at execution. The marker now records that ID and the execution factory refuses a mismatch before adapter construction. This does not yet bind prerequisite-only reviews; their stage contract remains to be built in M1.

2026-09-26: The Pulumi adapter previously prepared a whole-stack saved plan for each resource operation. A single operation could therefore execute changes assigned to several journal operations before those operations had receipts. Targeted Pulumi preview and apply are supported by the registered CLI source; the adapter now targets each operation's declared URN and refuses additional mutations. Cloud stage assembly must still order prerequisite resources so every targeted preview can be prepared from the current physical state.

2026-09-26: Generic inventory reviews used a constant `operator-cli` payload identity, which left prerequisite-only bootstrap stages without a payload binding. The planner now accepts a bootstrap-specific identity, and execution checks it before loading provider contracts. No prerequisite-only stage is yet publicly plannable because cloud/local foundation assembly remains outstanding.

2026-09-26: A new cloud context can still create its GCS Pulumi state bucket through `bootstrapGcsIfNeeded` during `init` or `context create`, before any inventory review. `ensurePulumiForContext` then selects the configured backend. M1 must move that first bucket effect into an explicit reviewed stage or a reviewed adoption handoff; merely adding later cloud declarations would leave the fresh-bootstrap acceptance gap open.


## Decision Log

2026-09-26: Redirect unfinished EP-148 dependencies to EP-158–161 and preserve this plan’s assigned integration, package, or release obligations. EP-148 is superseded history, not a pending completion gate.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.

2026-09-26: Bind the final marker to platform scope revisions and payload identity. Application, standalone, and publication revisions remain independently owned; changing one does not alter platform bootstrap completion. The marker scope is excluded from its own digest to avoid a self-reference.


## Outcomes & Retrospective


Implementation remains partial. Marker identity and scope-vector checks and targeted Pulumi operations have focused test and build evidence; no public fresh-bootstrap or native marker acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


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
