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
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T23:17:08Z
      mode: "implement"
      note: "Cut over local and live smoke consumers to reviewed image, deploy, backup, and restore routes; retain recovery evidence"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T14:00:52Z
      mode: "implement"
      note: "Repair command-service registration regression and hand off installed smoke"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T15:26:04Z
      mode: "implement"
      note: "Implement deferred-admission guards and exact command registry boundary"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-29T15:00:50Z
      mode: "update"
      note: "Revise command-boundary repair work from retained append, history, recovery, and public CLI experiments"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-09-30T13:13:46Z
      mode: "implement"
      note: "Register accepted-history credential recovery and cloud authority consumers; preserve incomplete release coverage"
---

# Close managed command coverage for the inventory release

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


Every supported mutation command and shipped recipe is mapped to its owner, reviewed execution path, and behavioral proof. The audit closes remaining platform and application command/library bypasses, proves supported behavior, and verifies guards for the operator-approved exclusions.


## Progress

**Bounded bootstrap recovery registration (2026-09-30).** Registered `InventoryRegistryRecoveryPlan` and `prepareRegistryRecoveryWithFactory` under original-transaction review/recovery. The strict saved native pointer, journaled intent, same-proof replay and independent readiness requirement pass source regressions, including completed host-history binding and changed host/Deployment/node refusals. All 991 CLI tests and the public foundation/bootstrap fixture pass. The audit registers 141 routes, 34 recipes and 29 library calls with zero errors; its injected-mutation check passes. Coverage still has ten pending routes, seven pending recipes and 29 incomplete catalogue rows. EP-156 owns installed/private-registry recovery and steady credential coverage; M2 is not complete.

**Cloud prerequisite registration checkpoint (2026-09-30).** Registered `KubeconfigRecover` as bounded accepted-history credential materialization, added its exact coverage family, and registered the two production calls `loadTargetSnapshotReadOnly` and `selectFoundationStore`. The regenerated catalogue and `bash scripts/test-managed-command-audit.sh` pass with 140 routes, 34 recipes, 28 library calls, zero registration errors and injected mutation refusal. The deferred/recovery-only sets remain exact. Ten pending routes, seven recipes and 29 incomplete catalogue rows keep coverage incomplete. [The cloud continuation](../audits/mp23-cloud-continuation-2026-09-30.md) retains the installed consumer evidence and external login blocker; no runtime operation or M2 completion is claimed by this audit repair.

**Current M2 entrypoint — production read/driver repairs, 2026-09-29.** The shared serial operation driver and immutable registry have saved-transaction proof, and EP-156's opaque selected observation reader now serves public status/explain. Preserve both checkpoints below. The [active-startup proof](../audits/mp23-active-startup-proof.md) now covers the real execution factory with unrelated reviews/events and no workspace. Factories share the validated store, selected source bytes avoid unrelated archived reviews, and legacy envelope fallback remains available. The [claim/publication repair](../audits/mp23-head-claims-proof.md) additionally retains original provider generations at claim CAS and removes publication archive listing from apply/resume/recover while preserving uncached publication verification. Next, finish remaining command-wide transport and supported command/host recovery prerequisites; do not reinstate whole-context observation or make old transaction recovery depend on materialized observation bytes. M2 and independent finding closure remain open.

Production checkpoint (2026-09-29): `OperationStep.hs` and `Execute.hs` now share one apply/resume phase decision. The whole-review live-preflight sweep is removed; structural validation, retention observation, and explicit migration-source admission proof remain. Main.hs has one execution/recovery registry and runs prune eligibility only before Job creation. The same saved public transaction now stops cleanly on terminal failure, permits exact abandonment, rejects a changed source UID, and converges after completion/interruption without repeated provider mutations; a second resume makes no provider calls. The complete 935-test suite, command audit, entrypoint guards, and Haskell style pass. [Retained proof and commands](../audits/mp23-rescue-proof.md) bound this result: synthetic admitted history and recorded providers do not prove physical deletion, receipt-only cleanup, retained-source CLI behavior, or cloud latency. F09/F12/F13 are Verifying; M2 remains open. The following checkpoint implements selected target/read isolation with EP-156.

Selected-read production checkpoint (2026-09-29): status/explain resolves the
selected accepted, retained, or collected identity before native evidence,
workspace resolution, and provider setup. Kubernetes/Helm use opaque observation
inputs and their read-only runtime needs no payload workspace. Dependency and
consumer explanations still use the full validated declaration graph. Public
fixtures prove known/unknown IDs, retained selection, foreign context refusal,
unrelated malformed reviews and missing sibling payloads, selected corruption,
and explicit legacy materialization. [The retained proof](../audits/mp23-selected-read-proof.md)
records call counts, source identities, and the complete 943-test run. The command
audit now registers 139 routes, including bounded immutable materialization.
F10 is Verifying pending independent checks; F04's nonempty legacy execution
helper and active-registry costs remain Partial. M2 remains open.

2026-09-28 scope update: no milestone is newly accepted by this edit. Use the revised MP-23 support boundary; historical findings retain their observations but do not reinstate deferred live overwrite, maintenance, or scheduled-pruning requirements.


- [x] M1 (2026-09-26): The finite audit registers 135 typed CLI routes, 34 recipes, 25 production inventory-service calls, and their detailed coverage families. `bash scripts/test-managed-command-audit.sh` passed and rejected an injected `Command.AuditInjectedMutation`; the generated catalogue snapshot matches the registry. The coverage result correctly remains incomplete while M2 and dependent feature rows are open.
- [ ] M2: Remaining platform mutations and application command/consumer cutovers have reviewed behavior, obsolete duplicate effects are removed, and coverage and user documentation agree with implemented commands.

M2 handoff (2026-09-26): `just deploy-hello` now uses the typed `nagarectl deploy` path and requires an accepted image resource and explicit tag; historical direct `kubectl apply` effects were removed from that recipe. The example config now names `hello` under the selected context registry, and the example/user instructions describe reviewed publication and retirement. `just --dry-run deploy-hello ...`, the command audit, the focused inventory Cabal suite, both entrypoint guard scripts, and strict `docs/user` validation passed. The remaining seven pending recipes and eleven pending CLI routes are still open, as are platform cleanup/profile/credential protocols and native smoke/consumer proof.

M2 handoff (2026-09-26): `scripts/local-smoke.sh` and `scripts/live-smoke.sh` now publish a Docker archive through `app image-plan`, deploy with its accepted image resource and explicit tag, and save/apply volume snapshot and scratch restore reviews. The local database drill also saves/applies reviewed backup and restore Jobs and checks the scratch database sentinel. Both scripts retain accepted resources and private reviews for exact recovery instead of deleting PVCs or object keys by broad selectors. `bash -n` for both scripts, `bash scripts/test-managed-command-audit.sh`, and strict `docs/user` validation passed. These are source-level checks; native smoke execution and a scratch-volume sentinel readback remain open. The workstation's `local` profile is pinned to platform 0.1.0 while the current selected payload is 0.4.0, and the `nagare-local` k3d cluster is absent, so this session did not claim a native run against that stale target. The live harness still starts the VM directly, and all seven recipes remain pending in the audit.

M2 checkpoint (2026-09-27): Registered the production `planInventoryCandidateWithPayloadIdentity` call and regenerated the existing catalogue snapshot. `python3 scripts/audit-managed-commands.py --update-catalogue --coverage-result /tmp/nagare-command-coverage.json` reports zero registration errors; `bash scripts/test-managed-command-audit.sh` passes and still rejects an injected mutation (135 routes, 34 recipes, 26 library calls). Coverage remains incomplete with 11 pending routes, seven recipes, and 30 incomplete catalogue rows. The next ordered checkpoint is EP-154's installed-package smoke; this registration repair does not close M2.

M2 consumer checkpoint (2026-09-27): The first installed `local-up` on a fresh isolated context failed because `scripts/run-reviewed-bootstrap.sh` handed an existing `mktemp -d` directory to `platform bootstrap plan --out`; the planner requires a new output path. The wrapper now creates a private parent and uses its absent `review` child. The repeated command passed review publication and reached the native registry operation. `bash scripts/test-knative-bootstrap-readiness.sh` and shell syntax checks passed. EP-155 records the later artifact-observation failure; this consumer fix alone does not close M2.

M2 deferred-admission checkpoint (2026-09-28): New direct/reviewed `db shell`, scheduled prune, and live database/volume restore routes now refuse before provider access. The lock-scoped shared admission path rejects saved live restore and maintenance actions and detects a new scheduled-prune scope from its stored member. Existing transaction resume, fence recovery, and receipt-only partial-prune recovery remain separate paths. A published saved-prune review was refused before adapter effects in `InventoryTransactionSpec`; the public entrypoint fixture checked all four command families and left the inventory head unchanged. The full `nagarectl-test` suite, command audit with injected mutation, evidence assembler fixture, Haskell style, and strict `docs/user` validation passed. The audit now registers 138 routes, 34 recipes, and 26 library calls with zero registration errors and an exact four-variant deferred set plus one recovery-only route. It remains incomplete with ten pending routes, seven pending recipes, and 29 incomplete catalogue rows. Next in the parent order: reconcile EP-154 installed smoke, EP-155 local fixture health, and EP-157 evidence inputs before the representative scheduled receipt/isolated restore handoff. M2 is still open.

Inherited baseline: legacy upgrade/Pulumi/context/cleanup/host-credential guards, eleven CLI refusal assertions, and the coverage catalogue already exist. Several guarded operations remain unavailable after admission; their guards are not evidence of a working replacement.


## Surprises & Discoveries

2026-09-27: The read-only command audit at `f79329f0` exits 1 because `Inventory.planInventoryCandidateWithPayloadIdentity` in the committed `app/Main.hs` is absent from the registered library calls. The 11 pending routes, seven recipes, and 30 incomplete rows remain. M1's original accepted implementation is credited; repairing this later registration regression is the first M2 integration action. The parent status is corrected to In Progress.


The registration audit found eight packaged recipes still classified as pending, including direct VM power, image publication, host switch, raw hello deployment, both smoke scripts, and infra destroy. The existing catalogue also still has 30 incomplete rows, some owned by EP-155/158–161. A passing registration audit therefore cannot be treated as a complete release coverage result.

The release evidence assembler formerly accepted a bare `{schemaVersion: 1, complete: true}` coverage stub. It now checks a non-dirty audit with registered route/recipe/library counts, empty pending and error lists, a candidate source digest, and a `sourceRevision` equal to the release manifest revision. `bash scripts/test-managed-resource-evidence.sh` proves a mismatched revision is refused.

The reviewed volume restore Job verifies the accepted receipt and archive hashes and extracts to a separate scratch PVC, but its normal output only reports verification completion. The smoke scripts therefore no longer claim they read the file sentinel back from that PVC; EP-155's native recovery proof must exercise that readback before treating the volume round-trip as complete.


## Decision Log

2026-09-29 (design reassessment): Replace the shared dispatch boundary as one cohesive change rather than distributing more preflight exceptions. A pure serial next-operation decision and one IO interpreter own phase order, while immutable registry construction and existing authority checks remain separate.

2026-09-29 (E10): Extend the phase repair into the executor after the actual two-operation prune fixture disproved the single-operation extrapolation. Fix F12 dependency ordering and F13 terminal-failure handling; retain structural checks and exact explicit recovery.

2026-09-29: Treat registry construction and target selection as implementation boundaries that must preserve executor recovery and avoid irrelevant prerequisites. The command-service counterfactual and built CLI reproduction justify this repair; generic executor tests and command registration do not prove it. Coordinate selected native inputs with EP-156 and actual retained-prune recovery with EP-159.

2026-09-28: Align with the operator-approved MP-23 reduction and ADR 22 amendment. Keep complete evidence for supported behavior and explicit guards/recovery compatibility for deferred routes. EP-161 is Cancelled and no longer a completion dependency; earlier full-feature decomposition instructions are superseded.

2026-09-26: Absorb EP-148 M4 command/library cutover, smoke and webhook consumer wiring, and user docs. Feature protocols move to EP-158–161, installed packages to EP-154, and native migration/collection/integration proof to EP-155/156. The finite registry determines ownership without hiding new substantial protocols inside this audit.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.

2026-09-26: Bind the generated coverage result to the release source revision and require concrete registration counts and zero unresolved rows. A manually written complete flag cannot serve as command-coverage proof. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) now records this durable release-evidence boundary.

2026-09-26: Reforecast M2 after the finite audit exposed separate VM power, builder lifecycle, host credential, profile migration, and cleanup protocols. These require reviewed operation identities and recovery behavior; a transport child marker alone does not make their public recipes inventory-backed. Keep them in this plan's platform cutover boundary and do not count refusal tests as working replacements.


## Outcomes & Retrospective


M1 is complete. M2 has a reviewed hello recipe and source-level smoke consumer cutover, but the native smoke runs, platform profile/credential/cleanup protocols, VM and host recipes, and dependent feature plans remain open. A registration audit pass is evidence that the finite catalogue has no omissions; it is not a complete release-coverage result while its pending lists remain populated.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator's 2026-09-28 MP-23 decision reduces the supported feature set while retaining full validation, typed ownership, and cross-tool journal/state. General live overwrite, new custom interactive mutating maintenance, and generalized scheduled pruning are explicitly deferred. Refusal does not complete a retained feature; deferred routes need tested admission guards and recovery compatibility. Earlier no-reduction instructions are superseded.

docs/architecture/managed-resource-coverage.md is the existing traceability catalogue, not an authority that grants effects. cli/nagarectl/app/Main.hs, cli/nagarectl/nagared/Main.hs, justfile, nix/checks/scripts.nix, scripts/test-inventory-entrypoint-guards.sh, and scripts/test-application-entrypoint-guards.sh identify public and packaged routes. InventorySpec.hs and the command-family tests in cli/nagarectl/test provide behavioral checks. Inventory store export/restore and wire compatibility are implemented and should be reused.


## Plan of Work

### First repair: replace the shared operation dispatch boundary

The [design reassessment](../audits/mp23-design-reassessment.md) supersedes a sequence of isolated factory/preflight patches. Keep the existing journal wire format and native adapters. Introduce an internal pure next-operation decision in `cli/nagarectl/src/Nagare/Inventory/OperationStep.hs` (or a narrowly named equivalent): finished, blocked, recover the uncertain operation, or execute the dependency-ready operation. Interpret validated existing journal records, including operator-resolution markers, without rewriting them. Unknown legacy resolution states stop explicitly. Preserve deterministic serial execution and the current writer lock; add no daemon or parallel scheduler.

Route both apply and resume through this one driver in Execute.hs. The IO interpreter alone owns operation-time preflight, recovery, mutation, and verification. Keep review/base/claim/identity/capability validation and necessary pre-admission ownership/retention observations; remove the second whole-review live-dispatch path. Registry construction loads selected immutable inputs and creates adapters. It must not run live predicates whose truth changes across operation phases. Current accepted state cannot substitute for the historical source pinned by a review after admission changes the head.

Use E10's existing two-operation prune review as the first production consumer. Test absent, completed, terminal-failed, interrupted, and changed-source states through the public command. Explicitly interpret all four RecoveryDecision constructors, with exhaustiveness checks failing the build for the transition code. A terminal failure stops with original evidence available for the proved operator action. The reviewable patch must remove duplicate orchestration and preserve historical recovery; moving helpers without eliminating competing phase decisions does not satisfy this outcome. Do not expand engine variants before this fixed path passes.

The detailed findings below are constraints on that replacement, not independently scheduled patch work.

`app/Main.hs:inventoryExecutionRegistryWithPrunePreflight` currently combines immutable reconstruction, source-native lookup, live eligibility checks, and adapter creation. `Command.resumeInventoryWithFactoryTakeover` invokes its factory before the executor can inspect and recover the operation. The controlled `RecoveryBoundary.hs` experiment keeps the transaction identical: a factory predicate blocks with zero recovery calls; moving the same predicate to adapter preflight converges with one original effect and one recovery. Preserve that existing executor behavior.

Move live, stage-sensitive predicates out of registry construction. Registry construction may validate immutable review/private-member bindings and select implementations. A check that assumes absence, original policy eligibility, an undeleted pair, or an unchanged pre-effect listing belongs to the corresponding adapter preflight/effect boundary. Recovery instead observes the original selected physical identities and the operation's recorded state. Merely adding another Boolean exception in the registry does not establish the boundary. Move checks without dropping their identity, authorization, or effect-time protection, and test that a genuine new mutation still reaches the required preflight. EP-159 supplies the two public saved-prune cases below before this change is accepted. Preserve source bindings that admission moves from accepted to retained history.

At `runInventoryStatus`, parse and resolve a requested ID against the validated accepted/retained declaration set immediately after composition. On an unknown ID, return the specific unknown-resource result before `loadAcceptedNative`, `resolvePlatformPaths`, workspace construction, adapter construction, or health probes. For a known ID, compute the needed resource/dependency/retained-incarnation selection before native lookup and provider observation. EP-156 owns the selected-evidence loader; this child passes its explicit selection and constructs only required adapters. A global status request still intentionally selects the whole current inventory. Dependency and consumer explanations retain their declaration graph without observing every unrelated provider.

Add public CLI fixtures with provider command recorders. An unknown ID in an empty accepted store must produce the same unknown-resource refusal with no workspace available and with 500 unrelated reviews, including one malformed unused review. A known single-resource explanation must preserve its identity-bound health and dependency output while adding unrelated resources causes no new unrelated provider calls. Selected corrupt evidence must still fail closed; this change cannot turn absence of required evidence into absence of a resource. The existing `ExplainBoundary.py` captures the current failure but does not cover the nonempty known-target case; add that product regression before closing F10. Consume EP-156's selected-member evidence reader, not the whole-review loader rejected by E6. Keep resource read acceleration separate from historical execution authority. Missing optional derived lookup state cannot become a new prerequisite that strands an already-admitted review; use EP-156's verified compatibility reader or an explicit bounded extraction when the old format lacks a direct evidence reference. Missing/corrupt original evidence still refuses. Do not recreate implicit whole-history scans in ordinary commands.

**Measured executor corrections (F12/F13, E10).** The public partial-prune fixture now reaches explicit abandonment successfully and rejects a changed ingestion UID. Factory-only diagnosis is no longer sufficient: ordinary resume preflights the later completion operation before recovering its ambiguous create prerequisite. In `cli/nagarectl/src/Nagare/Inventory/Execute.hs`, split `preflightOperations` into structural validation for the whole immutable review and live checks for dependency-ready operations. Preserve adapter identity/version, native digest, fence capabilities, and claim validation before effects; retain `executePrepared`'s immediate pre-effect check. Do not copy the diagnostic's blanket preflight removal into production. Make `recoverOrStop` exhaustive over `RecoveryProvedComplete`, `RecoverySafeToRetry`, `RecoveryTerminalFailure`, and `RecoveryUnresolved`; terminal failure must stop explicitly with original history available, never throw or blindly retry.

Port `PruneExecutor.hs`'s actual two-operation review into checked-in regressions, then run EP-159's public fixture with absent, failed, completed, and changed-source-UID responses. Assert recovery call order, no duplicate effect, dependent verification only after prerequisite completion, and successful explicit abandonment with one journal decision. Preserve the existing single-operation recovery and batch/lost-ack tests. E10's temporary terminal handler proves a safe stop is possible, not that this implementation is delivered. F12/F13 are part of order 0a and must be resolved before affected native resumption.

**Remaining M2 backlog.** The earlier unregistered `planInventoryCandidateWithPayloadIdentity` defect was repaired; do not restart that discovery/audit as the first task. Keep its existing injected-registration regression. After the command-boundary repair, continue the finite families below. A current registration failure remains a defect, but a green registration audit is not evidence that the registered behavior works.

Close these known platform/consumer families with a public saved-review → apply → observe/recover fixture before adding more component helpers:

| Existing pending surface | Owner and required disposition |
|---|---|
| `Command.Cleanup`, `InfraCommand.InfraDestroy`, `infra-destroy` | EP-153: exact reviewed cleanup/destruction preserving protected or unresolved data/history. EP-155 supplies the named native lifecycle bindings. |
| `ContextCommand.ContextCreate`, `ContextCommand.ContextDelete` | EP-153: safe profile replacement/removal with existing accepted history and store/project authority preserved. Fresh creation already supported must remain supported. |
| `HostCommand.HostPlaceAgeKey`, `host-image`, `host-switch`, `vm-start`, `vm-stop` | EP-153: existing host/credential/image/VM operations use reviewed execution or their already accepted bounded delegation; verify recovery, not just child-token refusal. |
| `local-smoke`, `smoke`, webhook consumer | EP-153: finish consumer wiring; EP-155/156 own native results. Do not rerun full clouds to validate a shell-only edit. |
| Access grant/revoke, portal sync, CDN purge/disable | EP-158 implements; EP-153 consumes registration/proof. |
| `DbCommand.DbShell`, custom mutating maintenance/exec | Deferred by MP-23 on 2026-09-28; EP-153 guards new admission and preserves recovery of recorded sessions. |
| Live database/PVC overwrite; generalized scheduled prune | Deferred by the same decision; guard new command/library/recipe/saved-review admission without blocking evidence-bound recovery of already-admitted work. |

The 30 incomplete catalogue rows additionally contain earlier feature and native-proof obligations. Assign each failure to its existing owning child; a row labelled partial does not authorize inventing a new operation. Known builder, cache, data, image, and lifecycle obligations in the catalogue remain included. Repair concrete omissions within those promised families. Additional product behavior or providers require an explicit scope decision in the parent. Update the audit alongside changes to shared entrypoints so completion of another child cannot silently leave M1's invariant broken.


M1 enumerates init/context/profile replacement/deletion, platform/infra/host/builder, auth/observability/cache/bootstrap, application/site/worker/preview, env/Secret, storage and database backup/restore/pruning, broker/topics, task/jobs, domain/CDN/access, maintenance, image publication, and release/control paths. Tie the executable registry to typed command dispatch and recipe/library entrypoints. Each record identifies declaration compiler, executor or bounded delegation, test evidence, and legacy disposition. A grep can discover candidates but cannot be the acceptance test. Include a test-only mutation entry that makes the audit fail when omitted. Update the existing catalogue from this same registration evidence; do not invent another resource inventory.

M2 owns remaining platform-side behavior: admitted-context profile changes, reviewed cleanup, host credential placement, and the finite platform/consumer families listed above. Classify profile changes by the authority they affect: a change of store/project cannot silently abandon existing history. Bind cleanup to exact accepted preview/history members and credential placement to an owned host/revision/private input. Preserve supported functionality and reject unsafe requests before effects. EP-148 is superseded. Its remaining feature owners are [EP-158](158-complete-reviewed-access-and-cdn-operations.md) for access/CDN, [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) for scheduled receipts/retention reporting and [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) for isolated restore and retained shared fencing. EP-161 is Cancelled; this plan owns only its deferred-admission guards and existing-session recovery compatibility. Do not reimplement those protocols in this audit. This plan now also owns EP-148 M4's remaining application/library entrypoint cutover and consumer wiring, including scripts/local-smoke.sh, scripts/live-smoke.sh, cli/nagarectl/nagared/Main.hs and its in-cluster launch/configuration, scripts/test-nagared-inventory-guard.py, and scripts/test-nagared-reviewed-deploy.py. Connect consumers to the existing reviewed compilers and accepted image/input channels, remove proven-obsolete live functions, and preserve selected-scope credential isolation. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) owns outstanding promised native collection/migration bindings under EP-149's lifecycle contract; record gaps there. Every public command variant stays in the catalogue, including deferred routes. Retained EP-148 variants still require implementation when a row says partial. The finite new exclusions are general live database/PVC overwrite, custom interactive mutating maintenance/unscoped exec-migration sessions, and generalized scheduled retention pruning, in addition to prior exclusions such as in-place platform version transition. Do not classify an unrelated implementation failure as deferred; any further exclusion needs an explicit product decision.

Finish user docs and remove proven-obsolete policy wrappers. Preserve provider transports that perform unique work. The finite registration manifest freezes this plan's audit boundary; a newly discovered entry maps to that manifest and an owner, with an explicit impact on the estimate.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
(python3 scripts/audit-managed-commands.py --coverage-result /tmp/nagare-command-coverage.json)
bash scripts/test-managed-command-audit.sh
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p inventory' --test-show-details=failures)
nagarectl_bin="$(cd cli/nagarectl && cabal list-bin exe:nagarectl)"
bash scripts/test-inventory-entrypoint-guards.sh "$nagarectl_bin"
bash scripts/test-application-entrypoint-guards.sh "$nagarectl_bin"
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
```

Expected result: the audit and relevant checks exit zero; the injected mutation fails inside the audit test and the current coverage JSON has `complete: false` with explicit pending routes and catalogue rows. Refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance

**Finite support-boundary proof.** The generated catalogue/result must distinguish supported operations from the specific 2026-09-28 exclusions, bind that decision to the candidate, and include each excluded route's refusal and retained-recovery evidence. Never omit those routes from registration counts or emit a hand-written complete flag. A missing registration, unguarded deferred route, incomplete supported feature, or stranded existing transaction is a release failure. Align the coverage schema and EP-157 reader together if fields change; no arbitrary ignore list or override flag.

Exercise both CLI and shared admission: newly saved or old unexecuted live-restore/maintenance/scheduled-prune reviews refuse before effects, while already-admitted work can be observed and resolved using its immutable original identity/evidence. Distinguish a new mutation from recovery; a newly fabricated review cannot claim to be historical recovery. Do not delete private native bundles, session records, or fence/partial-prune handlers. Keep read-only inspection, static reviewed hooks, verified isolated restore, receipt ingestion, and already-supported exact manual pruning working. Documentation states that scheduled keep-N/expiry is unenforced and backups grow until a supported reviewed disposal path is used.


Every registered live command has an implemented owner/executor or previously accepted non-live disposition. Newly named resources and fresh contexts cannot evade review. Library calls and webhook/recipe routes cannot reach removed imperative effects. The injected missing registration fails the audit. Verified examples show reviewed platform cleanup and credential/profile operations working, not only old routes refusing. Complete coverage is generated for the exact candidate revision; a missing supported implementation in EP-158–160, an unguarded deferred route, or an unresolved consumer cutover keeps it incomplete. Documentation states exact supported commands and recovery limitations.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Completed EP-146/147/149/151 provide underlying contracts. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) owns bootstrap, [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), and [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) own the remaining feature protocols, and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes the revision-bound coverage result. The coverage producer in scripts/audit-managed-commands.py emits schema version 1 with `sourceRevision`, `candidateDigest`, `dirty`, registration counts, and exact pending/error lists. The `--coverage-result` reader in scripts/assemble-managed-resource-evidence.sh requires the release revision and complete zero-gap result; extend both together if the schema changes. Final full coverage requires all supported command implementations plus the exact guarded exclusions and retained-recovery proof described above; EP-161 completion is not required. The former 16–30-hour post-audit range is an uncalibrated historical estimate, superseding the parent’s older 6–12 range. It is not a current delivery forecast. VM power, builder lifecycle, profile change, host credentials, and cleanup still need distinct reviewed recovery behavior; measure the first complete platform operation before revising effort.


## Revision Notes

2026-09-29: Adopt the bounded orchestration replacement in the design reassessment; correct the generalization from E3, make E10 the first production consumer, and remove mandatory derived-index rollout from historical recovery.

2026-09-29: Replace the stale registration-first task with experimentally demonstrated phase/selection repairs; specify exact public positive/negative fixtures and fix missing binary arguments in the guard commands.

2026-09-28: Align current implementation and acceptance with the reduced MP-23 contract while preserving native evidence requirements and existing transaction recovery.

2026-09-27: Apply the execution-log diagnosis to the existing outcome: drive implementation through its production command/recovery fixture, make handoffs and known ownership explicit, and prevent new requirements from entering through an open-ended audit. Existing functionality and final release acceptance remain required.
