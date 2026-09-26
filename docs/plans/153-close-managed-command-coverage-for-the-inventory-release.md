---
id: 153
slug: close-managed-command-coverage-for-the-inventory-release
title: "Close managed command coverage for the inventory release"
kind: exec-plan
created_at: 2026-09-26T20:29:54Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T20:29:54Z
---

# Close managed command coverage for the inventory release

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


Every supported mutation command and shipped recipe is mapped to its owner, reviewed execution path, and behavioral proof. The audit closes platform-side bypasses and documents the actual supported behavior without hiding promised app/data features behind permanent refusals.


## Progress


- [ ] M1: An executable command-registration audit accounts for every mutation family, including library and recipe entry points, and catches an injected unregistered mutation.
- [ ] M2: Remaining platform-side mutations have reviewed behavior, obsolete duplicate effects are removed, and the coverage result and user documentation agree with implemented commands.

Inherited baseline: legacy upgrade/Pulumi/context/cleanup/host-credential guards, eleven CLI refusal assertions, and the coverage catalogue already exist. Several guarded operations remain unavailable after admission; their guards are not evidence of a working replacement.


## Surprises & Discoveries


No new implementation findings in this successor plan. Inherited evidence and known gaps are identified below.


## Decision Log


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.


## Outcomes & Retrospective


Remaining-work plan created; no new acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator requested decomposition without reduced functionality or validation; temporary refusal of promised behavior is not completion.

docs/architecture/managed-resource-coverage.md is the existing traceability catalogue, not an authority that grants effects. cli/nagarectl/app/Main.hs, cli/nagarectl/nagared/Main.hs, justfile, nix/checks/scripts.nix, scripts/test-inventory-entrypoint-guards.sh, and scripts/test-application-entrypoint-guards.sh identify public and packaged routes. InventorySpec.hs and the command-family tests in cli/nagarectl/test provide behavioral checks. Inventory store export/restore and wire compatibility are implemented and should be reused.


## Plan of Work


M1 enumerates init/context/profile replacement/deletion, platform/infra/host/builder, auth/observability/cache/bootstrap, application/site/worker/preview, env/Secret, storage and database backup/restore/pruning, broker/topics, task/jobs, domain/CDN/access, maintenance, image publication, and release/control paths. Tie the executable registry to typed command dispatch and recipe/library entrypoints. Each record identifies declaration compiler, executor or bounded delegation, test evidence, and legacy disposition. A grep can discover candidates but cannot be the acceptance test. Include a test-only mutation entry that makes the audit fail when omitted. Update the existing catalogue from this same registration evidence; do not invent another resource inventory.

M2 owns remaining platform-side behavior: admitted-context profile changes, reviewed cleanup, host credential placement, and any non-application mutation found by the finite M1 audit. Classify profile changes by the authority they affect: a change of store/project cannot silently abandon existing history. Bind cleanup to exact accepted preview/history members and credential placement to an owned host/revision/private input. Preserve supported functionality and reject unsafe requests before effects. [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md) remains the implementation owner for application/data/access/CDN behavior; record exact failures against that owner rather than reimplement it here. Only already-agreed exclusions, such as in-place platform version transitions, may remain unavailable at release. A new proposed exclusion needs an explicit product decision and cannot satisfy M2 merely through documentation.

Finish user docs and remove proven-obsolete policy wrappers. Preserve provider transports that perform unique work. The finite registration manifest freezes this plan's audit boundary; a newly discovered entry maps to that manifest and an owner, with an explicit impact on the estimate.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p inventory' --test-show-details=failures)
bash scripts/test-inventory-entrypoint-guards.sh
bash scripts/test-application-entrypoint-guards.sh
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
```

Expected result: relevant checks exit zero; refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance


Every registered live command has an implemented owner/executor or previously accepted non-live disposition. Newly named resources and fresh contexts cannot evade review. Library calls and webhook/recipe routes cannot reach removed imperative effects. The injected missing registration fails the audit. Verified examples show reviewed platform cleanup and credential/profile operations working, not only old routes refusing. Complete coverage is generated for the exact candidate revision; a missing EP-148 implementation keeps it incomplete. Documentation states exact supported commands and recovery limitations.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Completed EP-146/147/149/151 provide underlying contracts. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) owns bootstrap, [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md) owns application/data commands, and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes the revision-bound coverage result. Agree its schema with the existing `--coverage-result` reader in scripts/assemble-managed-resource-evidence.sh; extend producer and consumer together if needed. Implementation can begin now; final full coverage requires all promised command implementations. Initial estimate: 4–8 active hours excluding EP-148 feature work, low confidence. Reforecast immediately if the M1 audit reveals another substantial platform operation protocol; do not absorb it as an invisible extra gate.
