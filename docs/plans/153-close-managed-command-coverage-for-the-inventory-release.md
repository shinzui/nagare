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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T03:07:03Z
      mode: "implement"
      note: "Verify installed initial GCS foundation recovery and preserve the pre-VM checkpoint"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T03:41:20Z
      mode: "update"
      note: "Add driver-consolidation and model-based driver test checkpoints from the independent review"
    - model: "gpt-5.6-terra"
      harness: "codex-cli"
      at: 2026-10-01T04:02:25Z
      mode: "implement"
      note: "Accept driver-consolidation checkpoint and record source evidence"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T16:25:29Z
      mode: "implement"
      note: "Write bounded operator apply/resume/recovery/takeover runbook with measured cloud timings and pending fresh-context verification"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T03:23:15Z
      mode: "implement"
      note: "Refactor the CLI entry point into explicit command, parsing, and runtime ownership boundaries"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-10-02T05:10:09Z
      mode: "implement"
      note: "Add collectable release-history source contract with focused checks"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T14:57:48Z
      mode: "implement"
      note: "Implement Kubernetes effect boundary and assign local F20 recovery next"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:36:25Z
      mode: "update"
      note: "Remove retired prerelease fixture recovery and frozen candidate from acceptance; retain supported candidate proof"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T22:18:28Z
      mode: "implement"
      note: "Implement reviewed same-payload host and credential transitions with exact-key recovery and public command proof"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:09Z
      mode: "update"
      note: "Consolidated with MP-23 into a current-state plan; prior body archived in docs/audits/mp23-archive/plan-history"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T04:05:29Z
      mode: "implement"
      note: "A6 style gate green; F33 and F32 source fixes; A4 resume refused by F34"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T17:30:19Z
      mode: "implement"
      note: "F35 reviewed exit for refused preflight after admission, with native cp3 proof"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T20:36:19Z
      mode: "implement"
      note: "F37: execute-time no-effect abandonment (d9aed800), reviewed field takeover (1df735a6); C2 adoption/drift/storage notes"
---

# Close managed command coverage for the inventory release

This ExecPlan is a living document. It was consolidated with [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md) on 2026-10-02; the previous text, including every dated checkpoint, handoff and superseded instruction, is preserved verbatim in [the pre-consolidation snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep153-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file.

Full plan before trimming: [153-close-managed-command-coverage-for-the-inventory-release.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/153-close-managed-command-coverage-for-the-inventory-release.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan, every command an operator can run that changes a Nagare-managed resource — each `nagarectl` subcommand, each `just` recipe, and each production call into the inventory library — either goes through the reviewed inventory path (compile, review, apply, resume with a durable journal) or refuses with an explicit, tested guard. No supported command reaches cloud, host or cluster state through an older imperative path that bypasses review. The operator-approved exclusions (interactive `db shell`, scheduled keep-N pruning, live database/volume overwrite) refuse new work but still let already-admitted work be observed and recovered.

To see it working, run the command audit (`scripts/audit-managed-commands.py`, see Concrete Steps). Today it reports registration complete but coverage incomplete: two routes and three recipes are still `pending`, and 26 catalogue rows are gaps. When this plan is done, the same audit run against the release candidate emits a coverage result with `complete: true`, empty pending and error lists and the candidate's source revision, which the release gate ([EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md)) consumes as `coverage.json`. This plan also owns the open MP-23 findings F30, F32 and F33 (with EP-156) and the repository-wide Haskell style gate.

## Progress

Full dated history is in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep153-before-consolidation-2026-10-02.md). Item IDs in parentheses refer to the MasterPlan 23 Progress phases.

- [x] M1 — finite command audit (2026-09-26). `scripts/audit-managed-commands.py` registers every typed CLI route, recipe and production library call against a coverage family; `bash scripts/test-managed-command-audit.sh` rejects an injected unregistered mutation; the catalogue snapshot is generated from the same registry. Evidence: commits `914b0e9b`–`491657ed`.
- [x] Deferred-admission boundary (2026-09-28). The four deferred variants (`DbShell`, `DbPruneScheduledBackups`, `DbRestore --into-live`, `StorageRestore --into-live`) refuse before provider access at the CLI and at shared saved-review admission; `DbRecoverScheduledPrune` remains the one recovery-only route. The audit fails if either set differs from `AUTHORIZED_DEFERRED`/`AUTHORIZED_RECOVERY_ONLY`. Evidence: `699ae909`.
- [x] One serial operation driver with model-based tests (2026-09-30). Bootstrap-registry recovery runs through the shared `runOperations` driver, and four fixed-seed in-memory interruption models check no duplicate effect, selected-only convergence and monotonic head/journal state. Evidence: `da2bb2b1`, `705716b7`.
- [x] Registration-only entrypoint (2026-10-01). `cli/nagarectl/app/Main.hs` is 16 lines; parsing, dispatch and command workflows live in executable-private `Nagare.Cli` modules, and the audit's architecture checks enforce explicit exports, acyclic imports and module size caps. Evidence: `b5d61f27`, [executable guide](../../cli/nagarectl/app/README.md).
- [x] Reviewed host, VM power, host image and context profile routes (2026-10-02). Same-payload host transitions and age-key replacement (`c4d219e4`), one-shot VM start/stop (`3905012e`), host image publication with read-only inspection (`c352cfec`) and profile update/removal/restore with retained history authority (`caa37d19`). Independent evidence: [native VM power](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/native-vm-power-3905012e.json), [F24 closure](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/image-plan-readonly-f24.json), [F26 original restore](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/context-gcs-original-restore-f26-fixed.json); F23–F27 are Closed in the tracker.
- [x] Release-history and stale-preview cleanup reviews with local native proof (2026-10-02). `cleanup --releases` (`0c6f228e`) and `cleanup --previews` (`def53168`) save exact reviews; independent local runs on `nagare-mp23-cp3` retain current history, durable PVCs and all unselected scopes. Evidence: [release cleanup (F28 closed)](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/release-cleanup-native-f28-fixed.json), [preview cleanup at `b805d64a`](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/preview-cleanup-native-b805d64a.json). Both still need binding to the final candidate.
- [x] F30 source repair (2026-10-02). New Knative Service update reviews use a version-2 status-stable observation with a fresh UID/resourceVersion write precondition; version-1 reviews keep strict semantics. Evidence: `95b58a24`, `52432400`; the native correction was interrupted at the operator's instruction and its transaction preserved ([handoff](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/application-status-race-f30-handoff.json), `c57f1638`).
- [-] (MP-23 A1) F33 closed: staged cloud collection (`infra destroy --save-plan`, `3fb92136`) binds the selected Pulumi stack entry, physical ID and protection state into collection evidence and rechecks them at preflight and immediately before saved-plan execution; a regression changes them between the two and is refused; an independent fresh disposable native collection passes. Source complete (2026-10-02, `e1371442`): preparation, preflight and pre-execution now compare each selected stack entry with the retained physical identity from history, and the regression covers replacement before preparation, missing identity and changes between preflight and execution. All 1,129 tests pass. Independent review and the native collection remain. Superseded/Moved (2026-10-09): the fix ships in v0.4.0, and F33 stays Verifying in [the tracker](../audits/mp23-findings.md#f33). Its native proof needs a staged cloud teardown's collection stage, which F84 (access-grant retirement) blocked on every acceptance context, so it moved to the next release with F84 ([deferral ledger](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/README.md)). The candidate does not change the collection code since the source verification (`CloudCollection.hs` and `Adapters/PulumiRuntime.hs` are identical at `3ae20f8c` and `83124396`). Closed here without native proof (2026-10-09): F33 stays Verifying, and its proof comes with the first staged cloud teardown, which MasterPlan 25 proves. {disposition=delivered-elsewhere, by=docs/masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md}
- [x] (MP-23 A2) F32 closed: `cleanup --images` (`cb782ad8`) protects image IDs referenced by Ready and retained sandboxes and the configured sandbox image, fails closed when sandbox observations are missing or ambiguous, and a fresh installed native review excludes those images while deleting an ordinary unused image. The unsafe saved review in [the F32 evidence](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/image-prune-sandbox-f32.json) is never applied. Source complete (2026-10-02, `c2dc2bb1`): sandbox (`crictl pods`/`inspectp .info.image`) and configured sandbox images are protected and fail closed. `scripts/test-image-prune-protocol.py` passes 23 cases, and the new cases fail on the old script. The installed native review and independent closure remain. (2026-10-09: F32 Closed by nagare-verify on 2026-10-08. On `mp23-c3j` (candidate `3ae20f8c`), the reviewed image cleanup removed 3 images with 0 pull or sandbox warnings, 68 pods stayed Ready, and a same-request replan had 0 operations; [C3 evidence](../audits/mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/), [tracker](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-findings-closed.md#f32). `ImagePruneScript.hs` is unchanged from `3ae20f8c` to `83124396`.)
- [x] (MP-23 A4, with EP-156) The interrupted F30 correction transaction reaches a terminal state through the public `inventory resume` path, with the same Service, PostgreSQL and PVC identities and the known row intact; F30 and F16 are then independently verified. Blocked (2026-10-02): the public resume with the admitting binary refused in 3 s as `ambiguous … at op-fed6a9432af7669b7446f230` with no effect, because Kourier on cp3 rejects every gateway snapshot ([F34](../audits/mp23-findings.md#f34)). The transaction stays preserved; repair F34 under a written recovery step first. Terminal (2026-10-02, implementer): after the F34 fix (`beca6886`) and the gated cp3 repair, the same public resume converged in 3 s. Identities and the known row are unchanged, and an unchanged replan has zero operations (tracker F30). Independent F30/F16 verification remains. (2026-10-09: F30 and F16 Closed by nagare-verify on 2026-10-08 on `mp23-c3j` (candidate `3ae20f8c`). A corrective Knative Service update converged under live controller status churn, and an update that landed but never became Ready was closed with its scope kept, then a corrected review converged with the same Service UID; [runbook execution](../audits/mp23-independent-results-2026-10-07/runbook-execution-3ae20f8c/), [F30](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-findings-closed.md#f30), [F16](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-findings-closed.md#f16).)
- [x] (MP-23 A6) `just haskell-style-check` (structural checks, Fourmolu over every tracked `cli/**/*.hs` file, Cabal Gild) passes (2026-10-02). Formatting-only commit `d4aa7168` reformatted 167 files and rebased `scripts/haskell-size-allowances.json` on formatted line counts. The gate exits 0 on that tree and on every later commit this session; all 1,129 `nagarectl` and the `nagare-dsl` tests pass, and `nagare-access` builds. (2026-10-09: the style check is a step of the green gate record on the final candidate `83124396`; [gate](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/gate-83124396.json).)
- [x] F35 closed: an admitted transaction stopped by a later operation's refused preflight has a reviewed exit. Source and native implementer proof (2026-10-03, `570467f0`): new decision `abandon-refused-operation`, four regression variants, and a native cp3 race that ended without deleting the foreign object (tracker F35). Independent verification remains. (2026-10-09: F35 Closed by the independent reviewer on candidate `7596632c`, which re-ran the native race on the C2 context; [phase-1 record](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-04/phase1-source-and-regressions-7596632c.md), [tracker](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-findings-closed.md#f35). ADR 26 later replaced the decision with `inventory close`.)
- [x] (MP-23 B4) The `Cleanup` and `InfraDestroy` routes and the `infra-destroy`, `smoke` and `local-smoke` recipes are promoted from `pending` with public review → apply → observe/recover proof; each of the 26 gap rows (`partial` or `adapter-ready`) in `docs/architecture/managed-resource-coverage.md` is migrated or an explicit guarded exclusion; the audit emits `complete: true` for the candidate revision for EP-157 (MP-23 C5). Progress (2026-10-03, implementer, `ae1f26ee` and `5abc56f5`): all 26 gap rows were rechecked against the code. Now 24 are `migrated`, each naming its guarded exclusions and C-phase proof owner; the Nix builder is `delegated`; and two rows that relied on an audit title exemption are `excluded`. The remaining direct paths now refuse after admission: the net-certmanager controller import, `just local-down` and the legacy `upload-images.sh` publish. Named `init` no longer runs gcloud for local contexts. Stale access, Cloudflare and local auth docs are fixed. `smoke` and `local-smoke` read back the restored sentinel from the pinned restore manifest (`fc8cba5b`), and the audit now registers them as reviewed. Remaining: one gap row (cleanup, waiting on F32) and three pending items (`Cleanup`, `InfraDestroy`, `infra-destroy`), each waiting on the independent F32/F33 closure and its native proof. (2026-10-09: the audit result for the final candidate is generated with `complete: true`, `dirty: false`, `sourceRevision` `83124396`, empty `pending`, `pendingRecipes`, `incompleteCatalogueRows` and `errors`, and the exact deferred and recovery-only sets; [coverage.json](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/coverage.json). C5 consumed it. Native proofs on the release line: preview cleanup in C2 and C3 on `83124396` ([C2](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396), [C3](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/c3-acceptance-83124396)), image cleanup (F32 above), and staged teardown stage 1 on `mp23-c3i`, which closed F39 ([c3i teardown](../audits/mp23-independent-results-2026-10-07/c3i-teardown/)). Later teardown stages are blocked by F84; see A1.)

## Surprises & Discoveries

Only entries that still shape the work are kept; the rest are in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep153-before-consolidation-2026-10-02.md).

2026-09-26: A passing registration audit only proves the catalogue has no omissions. Coverage completeness is a separate result that stays `false` while pending routes, pending recipes or gap rows remain; never report one as the other.

2026-09-26: The release evidence assembler once accepted a bare `{schemaVersion: 1, complete: true}` coverage stub. It now requires a non-dirty audit with registration counts, empty pending/error lists, a candidate digest and a `sourceRevision` equal to the release revision; `bash scripts/test-managed-resource-evidence.sh` proves a mismatched revision is refused.

2026-09-26: The reviewed volume restore Job verifies receipt and archive hashes and extracts into a scratch PVC, but does not print the restored file. The smoke scripts therefore do not claim a sentinel readback; promoting `smoke`/`local-smoke` needs an explicit readback step, and EP-155 owns the native round trip.

2026-10-02 (F30): Knative's status-only `RevisionFailed` transition changes `resourceVersion` after planning while spec, labels, ownership and UID stay exact, so the strict saved-state preflight stranded an admitted correction that cannot replan. The repair versions the observation rather than relaxing preconditions.

2026-10-02 (F32): The container runtime reports the sandbox pause image as `pinned=false`, and the production capture lists only ordinary containers (`crictl ps -a`), so an image used by 35 sandboxes was selected for deletion. Sandbox references must be observed directly (see `cli/nagarectl/src/Nagare/Inventory/ImagePruneScript.hs` and `scripts/test-image-prune-protocol.py`).

2026-10-02 (F33): Pulumi saved-plan deletion constraints bind the URN and operation class, not the physical ID, so a same-URN replacement between review and apply escapes the retained-incarnation check. See canonical project `mori://pulumi/pulumi/repos/pulumi`, `pkg/resource/deploy/plan.go` and `pkg/resource/deploy/step_generator.go` (artifact-level URI pending). Fresh rechecks narrow but cannot close the window against arbitrary external writers; document that limit.

2026-10-02 (A6): The architecture size ratchet (`scripts/check-haskell-architecture.py`, 1000-line cap plus `scripts/haskell-size-allowances.json`) had been calibrated on files Fourmolu had never formatted. Formatting pushed 16 modules over their allowance. The allowances were rebased on formatted counts because formatting adds no responsibility; the ratchet still bounds growth from that baseline.

2026-10-02 (F32): On k3s v1.34.6 (containerd 2.x) `crictl info` no longer exposes the sandbox image. The configured image is only in containerd's `config.toml` (`pinned_images.sandbox`), and each sandbox's image is `crictl inspectp` `.info.image`.

2026-10-02: The native preview cleanup run also removed one uninventoried, ownerless `Endpoints` object that shared a reviewed descendant Service's name. Kubernetes garbage collection gives no atomic namespace UID boundary, so reviewed descendant collection must not claim one.

## Decision Log

Decisions still in force, condensed. Full entries are in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep153-before-consolidation-2026-10-02.md).

2026-10-09: F33's native proof does not delay the release, under the operator's rule of 2026-10-07 that only a data-loss or release-unusable break does. It needs a staged cloud teardown, which no acceptance context ran after F84's fix (`b171712a`, in 0.4.0), so F33 stays Verifying. The disposable acceptance contexts were removed by exact-name deletes from their own stack exports instead of a staged teardown ([disposals](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/context-disposals)).

2026-10-02: Consolidate this plan to current state with MP-23; history moves to the snapshot. No scope or acceptance change.

2026-10-02: Apply [the prerelease fixture disposition](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-prerelease-fixture-disposition.md). The retired `f15-preview` fixture, its old transactions and earlier frozen candidates are not acceptance dependencies; recovery is proven on the supported candidate. Do not extend compatibility solely for retired development transactions.

2026-10-02: F30 is repaired by a versioned (v2) status-stable observation for new reviews plus a fresh atomic UID/resourceVersion write precondition; v1 reviews keep full-object semantics. No generic precondition relaxation, history reset or raw patch.

2026-10-02: Knative descendant collection is a distinct opt-in reviewed adapter (`inventory collect --controller-descendants`, `cli/nagarectl/src/Nagare/Inventory/Collection/`); old Orphan reviews are unchanged. Effectful interpreters are adopted incrementally at external request boundaries only (`Nagare.Inventory.KubernetesTransport`, `just test-inventory-effects`). Both are recorded in ADR 22.

2026-10-01: Keep `Main.hs` registration-only; new command behavior goes into its named `Nagare.Cli` module, guarded by the audit's architecture check ([ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md)).

2026-09-29/30: Apply and resume share one serial driver (`OperationStep.hs` decision, `Execute.hs` interpreter). Registry construction only validates immutable bindings and selects adapters; live, phase-sensitive predicates belong in adapter preflight so recovery is never blocked by a later operation's precondition.

2026-09-28: Follow the operator-approved MP-23 scope reduction: guard new admission of the deferred set while preserving recovery of admitted work; a refusal never counts as a working replacement for a supported feature. Any further exclusion needs a MasterPlan decision.

2026-09-26: Coverage proof is the generated, revision-bound audit result, never a hand-written flag ([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)). This plan owns command/consumer cutover (including EP-148 M4's smoke and webhook consumers); access/CDN, backups and restore belong to EP-158–160, packaging to EP-154, and native scenarios to EP-155/156.

## Outcomes & Retrospective

**Status: Complete (2026-10-09).** Every required item is met on the final candidate `83124396` or explicitly moved.

Final outcome (2026-10-09): v0.4.0 ships the complete managed-command surface. The audit at `83124396` reports `complete: true` (156 routes, 46 recipes, 35 library calls, no pending route, recipe or gap row) and C5 consumed it; `just haskell-style-check` is a step of the candidate's green gate. F30, F16, F32 and F35 are Closed by independent verification. F33's fix ships, but it stays Verifying, like F84, until a staged cloud collection runs; F40's remainder (full-context VM collection) is MasterPlan 25. Lessons: a coverage audit bound to a revision kept the release honest where hand-ticked rows had drifted; and a finding whose only proof sits at the end of a long teardown stays open for as long as any earlier stage is blocked, so put such proofs where a drill can reach them early.

Earlier state (2026-10-02, at `c57f1638`): M1 is complete. The command surface is registration-complete (150 typed routes, 35 recipes, 31 library calls in the generated catalogue) with an exact deferred/recovery-only boundary, one shared driver and a 16-line entrypoint. Reviewed host, VM power, host image, context profile, release-history and preview cleanup routes exist, several with independent native proof. M2 remains open: F33 and F32 block the staged teardown and image cleanup families, the F30 correction is awaiting terminal recovery, the repository-wide style gate is not recorded green, and two routes, three recipes and 26 gap rows keep coverage incomplete. All native evidence so far predates the final candidate and must be rebound to it.

Non-gating hardening noted by the 2026-09-30 review remains: partial functions on runtime data in `Adapters/FoundationRuntime.hs` (`physicalStack`) and `BootstrapRegistryRecovery.hs` (missing host revision) should become typed refusals when those modules are next touched.

Lesson: checkpoint narration inside Progress grew faster than it was reconciled and hid which families were actually open. Record one line per outcome with evidence, and keep raw output in the dated results directories.

