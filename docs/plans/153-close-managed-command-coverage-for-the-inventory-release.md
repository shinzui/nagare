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
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-26T22:23:39Z
      mode: "update"
      note: "Cascade EP-148 decomposition: assign remaining feature, cutover, and proof ownership without weakening release acceptance"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T22:44:03Z
      mode: "implement"
      note: "Implement finite command registration audit and record remaining release gaps"
---

# Close managed command coverage for the inventory release

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


Every supported mutation command and shipped recipe is mapped to its owner, reviewed execution path, and behavioral proof. The audit closes remaining platform and application command/library bypasses and documents the actual supported behavior without hiding promised app/data features behind permanent refusals.


## Progress


- [x] M1 (2026-09-26): The finite audit registers 135 typed CLI routes, 34 recipes, 25 production inventory-service calls, and their detailed coverage families. `bash scripts/test-managed-command-audit.sh` passed and rejected an injected `Command.AuditInjectedMutation`; the generated catalogue snapshot matches the registry. The coverage result correctly remains incomplete while M2 and dependent feature rows are open.
- [ ] M2: Remaining platform mutations and application command/consumer cutovers have reviewed behavior, obsolete duplicate effects are removed, and coverage and user documentation agree with implemented commands.

M2 handoff (2026-09-26): `just deploy-hello` now uses the typed `nagarectl deploy` path and requires an accepted image resource and explicit tag; historical direct `kubectl apply` effects were removed from that recipe. The example config now names `hello` under the selected context registry, and the example/user instructions describe reviewed publication and retirement. `just --dry-run deploy-hello ...`, the command audit, the focused inventory Cabal suite, both entrypoint guard scripts, and strict `docs/user` validation passed. The remaining seven pending recipes and eleven pending CLI routes are still open, as are platform cleanup/profile/credential protocols and native smoke/consumer proof.

Inherited baseline: legacy upgrade/Pulumi/context/cleanup/host-credential guards, eleven CLI refusal assertions, and the coverage catalogue already exist. Several guarded operations remain unavailable after admission; their guards are not evidence of a working replacement.


## Surprises & Discoveries


The registration audit found eight packaged recipes still classified as pending, including direct VM power, image publication, host switch, raw hello deployment, both smoke scripts, and infra destroy. The existing catalogue also still has 30 incomplete rows, some owned by EP-155/158–161. A passing registration audit therefore cannot be treated as a complete release coverage result.

The release evidence assembler formerly accepted a bare `{schemaVersion: 1, complete: true}` coverage stub. It now checks a non-dirty audit with registered route/recipe/library counts, empty pending and error lists, a candidate source digest, and a `sourceRevision` equal to the release manifest revision. `bash scripts/test-managed-resource-evidence.sh` proves a mismatched revision is refused.


## Decision Log

2026-09-26: Absorb EP-148 M4 command/library cutover, smoke and webhook consumer wiring, and user docs. Feature protocols move to EP-158–161, installed packages to EP-154, and native migration/collection/integration proof to EP-155/156. The finite registry determines ownership without hiding new substantial protocols inside this audit.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.

2026-09-26: Bind the generated coverage result to the release source revision and require concrete registration counts and zero unresolved rows. A manually written complete flag cannot serve as command-coverage proof. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) now records this durable release-evidence boundary.

2026-09-26: Reforecast M2 after the finite audit exposed separate VM power, builder lifecycle, host credential, profile migration, and cleanup protocols. These require reviewed operation identities and recovery behavior; a transport child marker alone does not make their public recipes inventory-backed. Keep them in this plan's platform cutover boundary and do not count refusal tests as working replacements.


## Outcomes & Retrospective


Remaining-work plan created; no new acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator requested decomposition without reduced functionality or validation; temporary refusal of promised behavior is not completion.

docs/architecture/managed-resource-coverage.md is the existing traceability catalogue, not an authority that grants effects. cli/nagarectl/app/Main.hs, cli/nagarectl/nagared/Main.hs, justfile, nix/checks/scripts.nix, scripts/test-inventory-entrypoint-guards.sh, and scripts/test-application-entrypoint-guards.sh identify public and packaged routes. InventorySpec.hs and the command-family tests in cli/nagarectl/test provide behavioral checks. Inventory store export/restore and wire compatibility are implemented and should be reused.


## Plan of Work


M1 enumerates init/context/profile replacement/deletion, platform/infra/host/builder, auth/observability/cache/bootstrap, application/site/worker/preview, env/Secret, storage and database backup/restore/pruning, broker/topics, task/jobs, domain/CDN/access, maintenance, image publication, and release/control paths. Tie the executable registry to typed command dispatch and recipe/library entrypoints. Each record identifies declaration compiler, executor or bounded delegation, test evidence, and legacy disposition. A grep can discover candidates but cannot be the acceptance test. Include a test-only mutation entry that makes the audit fail when omitted. Update the existing catalogue from this same registration evidence; do not invent another resource inventory.

M2 owns remaining platform-side behavior: admitted-context profile changes, reviewed cleanup, host credential placement, and any non-application mutation found by the finite M1 audit. Classify profile changes by the authority they affect: a change of store/project cannot silently abandon existing history. Bind cleanup to exact accepted preview/history members and credential placement to an owned host/revision/private input. Preserve supported functionality and reject unsafe requests before effects. EP-148 is superseded. Its remaining feature owners are [EP-158](158-complete-reviewed-access-and-cdn-operations.md) for access/CDN, [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) for scheduled backups/pruning, [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) for restore and shared data fencing, and [EP-161](161-provide-scoped-interactive-maintenance-with-durable-recovery.md) for interactive maintenance. Do not reimplement those protocols in this audit. This plan now also owns EP-148 M4's remaining application/library entrypoint cutover and consumer wiring, including scripts/local-smoke.sh, scripts/live-smoke.sh, cli/nagarectl/nagared/Main.hs and its in-cluster launch/configuration, scripts/test-nagared-inventory-guard.py, and scripts/test-nagared-reviewed-deploy.py. Connect consumers to the existing reviewed compilers and accepted image/input channels, remove proven-obsolete live functions, and preserve selected-scope credential isolation. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) owns outstanding promised native collection/migration bindings under EP-149's lifecycle contract; record gaps there. Public command variants already promised by EP-148 remain covered even when a coverage row still says partial. Only already-agreed exclusions, such as in-place platform version transitions, may remain unavailable at release. A new proposed exclusion needs an explicit product decision and cannot satisfy M2 merely through documentation.

Finish user docs and remove proven-obsolete policy wrappers. Preserve provider transports that perform unique work. The finite registration manifest freezes this plan's audit boundary; a newly discovered entry maps to that manifest and an owner, with an explicit impact on the estimate.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
(python3 scripts/audit-managed-commands.py --coverage-result /tmp/nagare-command-coverage.json)
bash scripts/test-managed-command-audit.sh
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p inventory' --test-show-details=failures)
bash scripts/test-inventory-entrypoint-guards.sh
bash scripts/test-application-entrypoint-guards.sh
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
```

Expected result: the audit and relevant checks exit zero; the injected mutation fails inside the audit test and the current coverage JSON has `complete: false` with explicit pending routes and catalogue rows. Refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance


Every registered live command has an implemented owner/executor or previously accepted non-live disposition. Newly named resources and fresh contexts cannot evade review. Library calls and webhook/recipe routes cannot reach removed imperative effects. The injected missing registration fails the audit. Verified examples show reviewed platform cleanup and credential/profile operations working, not only old routes refusing. Complete coverage is generated for the exact candidate revision; a missing promised implementation in EP-158–161 or an unresolved consumer cutover keeps it incomplete. Documentation states exact supported commands and recovery limitations.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Completed EP-146/147/149/151 provide underlying contracts. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) owns bootstrap, [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md), and [EP-161](161-provide-scoped-interactive-maintenance-with-durable-recovery.md) own the remaining feature protocols, and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes the revision-bound coverage result. The coverage producer in scripts/audit-managed-commands.py emits schema version 1 with `sourceRevision`, `candidateDigest`, `dirty`, registration counts, and exact pending/error lists. The `--coverage-result` reader in scripts/assemble-managed-resource-evidence.sh requires the release revision and complete zero-gap result; extend both together if the schema changes. Final full coverage requires all promised command implementations. After the M1 audit, the remaining estimate is 16–30 active hours excluding EP-158–161 feature protocols and EP-155/156 native runs, low confidence; VM power, builder lifecycle, profile change, host credentials, and cleanup need distinct reviewed recovery behavior.
