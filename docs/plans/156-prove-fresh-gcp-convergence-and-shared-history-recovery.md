---
id: 156
slug: prove-fresh-gcp-convergence-and-shared-history-recovery
title: "Prove fresh GCP convergence and shared history recovery"
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
---

# Prove fresh GCP convergence and shared history recovery

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


A production-shaped disposable GCP context proves reviewed cloud/host/cluster/application convergence, shared GCS ownership history, recovery, and exact cleanup while preserving standing project resources. This supplies cloud behavior that neither local Kubernetes nor recording adapters can establish.


## Progress


- [ ] M1: An exact disposable fixture has complete reviewed creation/cleanup membership, then converges through the public installed operator using GCS inventory history.
- [ ] M2: No-op replay, interruption/host recovery, two-state-root history recovery, data preservation, and exact owned cleanup pass and produce redacted evidence.

Inherited baseline: EP-150 prepared a 27-create, zero-update/delete/import Pulumi preview and unique names in tan-ng-labs. That preview is historical and never applied. The separate state bucket and parent-zone delegation were not covered by those 27 creates. Regenerate current native plans; do not replay a stale /tmp artifact.


## Surprises & Discoveries


No new implementation findings in this successor plan. Inherited evidence and known gaps are identified below.


## Decision Log

2026-09-26: Redirect unfinished EP-148 dependencies to EP-158–161 and preserve this plan’s assigned integration, package, or release obligations. EP-148 is superseded history, not a pending completion gate.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.


## Outcomes & Retrospective


Remaining-work plan created; no new acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator requested decomposition without reduced functionality or validation; temporary refusal of promised behavior is not completion.

scripts/rehearse-gcp-bootstrap.sh, scripts/rehearse-managed-resources.sh, infra/pulumi/index.ts, infra/pulumi/src/components/NagarePerimeter.ts, cli/nagarectl/src/Nagare/Inventory/Cloud.hs, Host.hs, and Store/Open.hs provide existing integration surfaces. The standing tan-ng-labs project contains nagare-01, nagare-node, the nagare registry, standing state/data/cache buckets, and labs.topagentnetwork.net. The prior proposed fixture used nagare-ep150 and ep150.labs.topagentnetwork.net with separate ep150-pmkjjpp bucket names. These are discovery leads, not authorization to reuse names without checking current state. The operator selected tan-ng-labs but required standing resources preserved.


## Plan of Work


M1 finishes the fixture under fixtures/inventory-release/gcp/ and supplies scripts/rehearse-gcp-inventory-release.sh as a thin composition of existing public commands and the generic phase protocol. Bind exact project, region/zone, VM/service-account/registry/bucket names, state backend, domain, and native cluster identity. The runner separates pre-cluster preparation from the generic Kubernetes-backed rehearsal; it must not require a reachable API before the reviewed host/cluster stage creates one. Fresh bootstrap must review the state bucket before migrating from local history to the context GCS prefix. Include the exact parent-zone NS delegation and its cleanup decision; suppress duplicate ownership of enabled project APIs using the existing manageProjectApis option. Prepare and inspect current plans for zero unintended standing-resource changes. Inherit prior authorization where it covers the exact resources, and request only any genuinely missing bounded mutation authorization after concrete creation/cleanup reviews exist.

Run the installed candidate through actual cloud foundation, guarded NixOS activation, cluster bootstrap/auth/cache, and the application/data scenario established by EP-155. Include live Google DNS/CDN host ownership against the accepted platform backend and preserve shared routing. The existing approved offline-only Cloudflare proof remains sufficient for that provider; do not ask again for a nonexistent disposable zone.

M2 exercises a safely injected acknowledgement interruption at real provider boundaries with retained reviews and receipts. Proven work is skipped; ambiguous outcomes use explicit recovery. Verify the guarded host's post-activation readiness and rollback/self-reversion contract, not only SSH exit. A second isolated operator state root reads shared history and cannot steal an active writer; explicit takeover/recovery follows the existing contract. Prove cloud registry publication with accepted Build input pins, scheduled backup receipt ingestion and exact GCS pruning, database/volume restore integrity with shared fencing, maintenance recovery across state roots, private history export/restore, app-only isolation, and final no-op behavior. Reuse EP-155 engine-specific native checks where the same candidate and transport behavior suffice; cloud-specific GCS/registry/shared-writer assertions still require this cloud run. Cleanup is a separate exact review that removes only disposable owned objects and the matching delegation, leaving standing neighbors untouched.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
bash scripts/test-rehearse-managed-resources.sh
bash scripts/rehearse-managed-resources.sh --help
# Required new runner interface; plan first, apply only its reviewed fixture:
: "${NAGARE_TEST_CONTEXT:?exact disposable cloud context}"
: "${NAGARE_TEST_CLUSTER:?exact disposable cluster}"
: "${NAGARE_TEST_PROJECT:?exact authorized project}"
: "${NAGARE_TEST_EVIDENCE:?new public evidence directory}"
bash scripts/rehearse-gcp-inventory-release.sh --phase plan --context "$NAGARE_TEST_CONTEXT" --expected-project "$NAGARE_TEST_PROJECT" --expected-cluster "$NAGARE_TEST_CLUSTER" --evidence-dir "$NAGARE_TEST_EVIDENCE"
```

Expected result: relevant checks exit zero; refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance


The original and post-apply reviews, real receipts, final status, and before/after standing-resource identities prove convergence, no unintended writes, and isolation. The cloud phase reports actual provider proof, never a successful recording substitute. GCS history is authoritative from the second workstation; lost local files do not reconstruct ownership from labels. Restored data hashes/rows and exact retained identities match. Cleanup has evidence of selected-only deletion and cannot broadly destroy the project or current labs context. Publish redacted evidence to EP-157; keep native plans/credentials/private exports private.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Completed EP-146/147/149/151 provide executors/store. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) supplies working fresh bootstrap, [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) the scenario/receipt contract, [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md) native packages, and the delivered EP-148 baseline plus [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md), and [EP-161](161-provide-scoped-interactive-maintenance-with-durable-recovery.md) required commands. Plan/fixture preparation can start before they close; a successful live local run and working cloud prerequisites gate cloud apply. [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes this evidence. Initial estimate: 8–16 active hours excluding approvals, provider queues, and unfinished feature implementation, low confidence; reforecast after the first complete read-only cloud preview including state bucket and delegation.
