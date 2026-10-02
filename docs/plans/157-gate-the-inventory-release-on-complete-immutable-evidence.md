---
id: 157
slug: gate-the-inventory-release-on-complete-immutable-evidence
title: "Gate the inventory release on complete immutable evidence"
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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T15:17:03Z
      mode: "implement"
      note: "Bind early two-scenario/native-system evidence index and missing-input refusals"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T15:26:04Z
      mode: "implement"
      note: "Bind immutable coverage evidence to the authorized deferred route set"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:36:25Z
      mode: "update"
      note: "Remove retired prerelease fixture recovery and frozen candidate from acceptance; retain supported candidate proof"
---

# Gate the inventory release on complete immutable evidence

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


The inventory release is accepted only when the complete candidate has working commands, installed native packages, local and GCP recovery evidence, and immutable public release attachments. A missing prerequisite fails the release gate. This plan integrates the existing publisher instead of implementing it again.


## Progress

**Current acceptance boundary (2026-10-02).** [The operator's prerelease fixture disposition](../audits/mp23-prerelease-fixture-disposition.md) supersedes historical freeze and old-transaction handoffs below. `f15-preview` is retired from acceptance; its recovery, cascade exception, failed-Job recovery and frozen operator do not gate this child or MP-23. Keep diagnostic evidence and existing regression coverage, but do not extend compatibility solely for obsolete development transactions. Verify supported recovery on the selected candidate. The safe-use review does not stop other supported implementation or release verification.

Final evidence must contain successful candidate-bound local/cloud scenarios. A retired attempt remains a diagnostic failure, never a successful receipt or substitute for missing recovery proof. Do not require every historical prerelease transaction to converge before assembly.

2026-09-28 scope update: no milestone is newly accepted by this edit. Use the revised MP-23 support boundary; historical findings retain their observations but do not reinstate deferred live overwrite, maintenance, or scheduled-pruning requirements.


- [ ] M1: Assembly and publication require complete revision-bound coverage, local/cloud rehearsal evidence, and native-system artifacts; missing, stale, or tampered evidence refuses.
- [ ] M2: A full non-publishing release rehearsal passes for the final candidate, documentation/ADRs match supported behavior, and every parent acceptance requirement has evidence.

Inherited baseline: commit `1891b34c` delivered GitHubRelease/GitHubReleaseRuntime, checked publication, fault tests, and a real private-repository fresh-checkout retry without duplicate writes. Commits `432dad9a` and `cbd7c3cf` delivered evidence projection with exact receipt coverage. Do not repeat the provider probe or rewrite the publisher unless a relevant change invalidates its evidence.

Early schema handoff (2026-09-27): `scripts/assemble-inventory-release-index.py` binds the assembled release manifest and `release.json` supported systems to each native output/rehearsal, complete command coverage, and one projected local plus cloud inventory run. Each scenario directory supplies `target.json`, `<mode>-health.json`, and `inventory-evidence.json`; the health record binds mode/context/cluster/operator revision/fixture digest, while the projector manifest binds the canonical target digest, candidate payload, completed receipts, final observation, and coverage digest. The index emits only safe identities and file digests. `python3 scripts/test-inventory-release-index.py` passed its complete, missing cloud, stale native, incomplete coverage, secret-canary, and changed-target checks. The current full clone-free runner lacks the already required `typed-config` check, so the index deliberately rejects it until EP-154 supplies that gate. Assembly/workflow/publication integration and actual matching local/cloud evidence remain open; neither M1 nor M2 is complete.

Support-boundary schema checkpoint (2026-09-28): The command audit emits an exact `deferredRoutes` set for interactive maintenance, scheduled pruning, and live database/volume overwrite, plus `recoveryOnlyRoutes` for historical partial-prune recovery. The public evidence assembler now requires those exact fields; its fixture accepts the declared set and rejects a missing deferred set. `bash scripts/test-managed-resource-evidence.sh` and the audit fixture pass. This binds the operator-approved reduction to the coverage asset without treating still-pending supported commands as complete. M1 remains open for complete supported coverage, native-system inputs, and matching local/cloud candidate evidence.


## Surprises & Discoveries


The previous one-run projector cannot stand in for both scenario modes. The early index consumes its safe output twice and binds the scenario-specific target/health records rather than redesigning the private export. EP-154's current full clone-free manifest does not yet report the typed configuration check required by its own acceptance, so a matching native-system record still needs that work.


## Decision Log

2026-10-02 (operator correction): Apply the prerelease fixture disposition: old F15 recovery and its frozen candidate are not acceptance dependencies; retain supported candidate recovery proof and continue ready work through the former step-4 scheduling stop.

2026-09-28: Align with the operator-approved MP-23 reduction and ADR 22 amendment. Keep complete evidence for supported behavior and explicit guards/recovery compatibility for deferred routes. EP-161 is Cancelled and no longer a completion dependency; earlier full-feature decomposition instructions are superseded.

2026-09-26: Redirect unfinished EP-148 dependencies to EP-158–161 and preserve this plan’s assigned integration, package, or release obligations. EP-148 is superseded history, not a pending completion gate.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.


## Outcomes & Retrospective


Remaining-work plan created; no new acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator's 2026-09-28 MP-23 decision reduces the supported feature set while retaining full validation, typed ownership, and cross-tool journal/state. General live overwrite, new custom interactive mutating maintenance, and generalized scheduled pruning are explicitly deferred. Refusal does not complete a retained feature; deferred routes need tested admission guards and recovery compatibility. Earlier no-reduction instructions are superseded.

cli/nagarectl/src/Nagare/Inventory/Adapters/GitHubRelease.hs and GitHubReleaseRuntime.hs, cli/nagarectl/test/InventoryPublicationSpec.hs, scripts/assemble-managed-resource-evidence.sh, scripts/assemble-release.sh, scripts/test-managed-resource-evidence.sh, scripts/test-release.sh, release.json, and .github/workflows/release.yml own publication/evidence. The workflow already calls checked `release publish`; EP-150's prose claiming it still uses softprops is historical. Inventory evidence is currently optional at assembly, and the workflow assembly invocation does not supply it. The existing projector binds one rehearsal/private export to a candidate; require both local and cloud evidence through an explicit aggregate/index rather than treating one as both.


## Plan of Work

**Revised support contract (2026-09-28).** Retain mandatory native-system, local/GCP, immutable-candidate, receipt-integrity, and complete registration gates. Consume EP-153's explicit supported/deferred dispositions and proof; the only new exclusions are general live database/PVC overwrite, new custom interactive mutating maintenance/unscoped exec-migration, and generalized scheduled retention pruning. Bind this support contract to the candidate evidence. Keep deferred routes in the audited catalogue and reject missing refusal/recovery proof. Do not replace native behavior evidence with tool provenance or GitHub attestations.

Add negative assembly cases for an undocumented exclusion, a still-enabled deferred route, and a missing supported engine/receipt/restore assertion. Do not add a generic bypass/ignore flag or treat a failed supported feature as deferred. EP-161's completion and any EP-163 prototype/tool selection are not release prerequisites. This plan edit changes the intended gate; the producer/reader changes and actual final evidence still need implementation/verification.

**Early schema, late final acceptance.** Before EP-155/156 collect expensive native runs, implement/check the existing evidence index against representative local/cloud/native/coverage manifests and its missing-input tests with their producers. Bind the agreed schema and identity fields in those runners; do not redesign the evidence format after final provider proof. Final candidate assembly remains last, after complete matching evidence exists. Reuse the existing publisher and projector.

The early index interface is `python3 scripts/assemble-inventory-release-index.py --release-metadata release.json --release-manifest FILE --native-dir DIR --coverage-result FILE --local-dir DIR --cloud-dir DIR --output FILE`. Each scenario directory contains the generic saved-review `target.json`, a public `<mode>-health.json` with schemaVersion/mode/context/cluster/operatorRevision/fixtureDigest/healthy/checks, and the public projector result named `inventory-evidence.json`. EP-155 already writes the local health shape; EP-156 must write its cloud counterpart with the same identity fields and cloud-specific checks. The index checks the target's canonical digest against the projected run and each native output/rehearsal against the same release revision and system payload. Its output is a candidate-bound index for the later release assembler, not yet an attachment or publication grant.

**Closure discipline (2026-09-27).** Consume the existing child assertions and finite command catalogue. The final rehearsal must report each missing or failing existing assertion with its owner. Reuse matching targeted evidence only under the recorded candidate/fixture binding; collect the required final manifests for the same release candidate. A newly noticed implementation defect still blocks its existing assertion, while a new feature/provider/security guarantee is a product-scope proposal, not an automatic new release condition. The parent execution-log audit is explanatory history and is not another evidence artifact or release gate.


M1 defines a versioned public evidence index over local and GCP run manifests, native-system output/rehearsal manifests, exact coverage result, and the candidate source/payload identity. Reuse the current projector for exact committed receipts and secret-safe fields. Extend schema/assembly/publisher validation together for the declared evidence asset shape. Require every supported system in release.json, both scenario modes, and complete command coverage. Different revisions, missing receipts, uncommitted journal objects, incomplete coverage, secret canaries, missing native runs, and absent cloud proof all fail before publication. Cached artifacts or prior provider probes cannot be relabeled as final candidate evidence. Same-tag retries retain exact bytes and physical IDs.

M2 runs the complete release rehearsal without creating a tag or publishing a real Nagare release. Map all seven IR-24 verification cases—collision, adoption, data-preserving rename, resume, drift classification, real convergence/no-op/removal, and immutable evidence—to accepted results. Include independent-scope preservation, secret-read refusal, store corruption/concurrency/stale-review checks, and exact declaration/execution coverage. Review docs/user and affected ADRs; correct stale instructions and promote durable discoveries. The parent can close only after EP-152–156 and EP-158–160 are complete under the revised contract (EP-148/150 are superseded history and EP-161 is Cancelled) and all evidence matches the candidate. Publication itself remains a separate explicitly authorized release action.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p publication' --test-show-details=failures)
bash scripts/test-managed-resource-evidence.sh
bash scripts/test-release.sh
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
bash scripts/assemble-release.sh --help
bash scripts/assemble-managed-resource-evidence.sh --help
```

Expected result: relevant checks exit zero; refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance


A valid complete candidate assembles reproducibly; removing either scenario mode, a native system, a receipt, or a required coverage entry makes the gate fail before any publication call. Altered source/payload/digest bindings refuse. Same inputs produce the same attachment bytes, while private archives and Secret values remain absent. The checked publisher still recovers exact already-verified assets from provider evidence after a fresh checkout. No release-ready claim is issued while any supported command/native/data assertion, deferred-admission guard, or required recovery compatibility is unresolved. Record final results in this plan, MasterPlan 23, and IR-24 only after the full gate passes.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Completed EP-146/147/149/151 are implementation prerequisites. [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) owns coverage, [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md) native artifacts, [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) local evidence, and [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) cloud evidence. These interfaces can be implemented/tested offline before providers finish; all are mandatory final inputs. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) bootstrap and [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), and [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) promised behavior must be accepted for parent closure. Historical, uncalibrated estimate (not a current delivery forecast): 4–8 active hours after evidence inputs are available, low confidence; assess missing-input rejection first. This estimate excludes public release publication and does not waive any gate.


## Revision Notes

2026-10-02: Remove retired prerelease fixture recovery from the critical path; preserve truthful diagnostics and supported candidate acceptance.

2026-09-28: Align current implementation and acceptance with the reduced MP-23 contract while preserving native evidence requirements and existing transaction recovery.

2026-09-27: Apply the execution-log diagnosis to the existing outcome: drive implementation through its production command/recovery fixture, make handoffs and known ownership explicit, and prevent new requirements from entering through an open-ended audit. Existing functionality and final release acceptance remain required.
