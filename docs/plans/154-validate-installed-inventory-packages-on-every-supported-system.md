---
id: 154
slug: validate-installed-inventory-packages-on-every-supported-system
title: "Validate installed inventory packages on every supported system"
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
      at: 2026-09-27T13:38:39Z
      mode: "update"
      note: "Schedule an early installed-package check before feature/provider runs and retain full final-candidate acceptance"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T14:15:37Z
      mode: "implement"
      note: "Pass bounded installed Darwin smoke and identify stale full-run typed-config fixture"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T15:35:21Z
      mode: "implement"
      note: "Verify committed deferred-admission package in bounded installed Darwin smoke"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T16:56:05Z
      mode: "implement"
      note: "Pass exact-revision Darwin clone-free and typed-config negative package checks"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-30T04:43:10Z
      mode: "update"
      note: "Prioritize cloud integration and safe ongoing operation ahead of full local integration; retain final release gates"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:10Z
      mode: "update"
      note: "Consolidated with MP-23 into a current-state plan; prior body archived in docs/audits/mp23-archive/plan-history"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T04:05:29Z
      mode: "implement"
      note: "F31 cadence fix and restored typed-config rehearsal check (source)"
---

# Validate installed inventory packages on every supported system

This ExecPlan is a living document. It was consolidated with [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md) on 2026-10-02; the previous text, including every dated checkpoint, is preserved verbatim in [the pre-consolidation snapshot](../audits/mp23-archive/plan-history/ep154-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file.


## Purpose / Big Picture

An operator installs Nagare from the immutable Nix flake, not from a source checkout. After this plan, the installed operator and developer packages run the inventory commands from any directory, with isolated operator state, on every system listed in `release.json` (`x86_64-linux` and `aarch64-darwin`). Every schema, manifest, payload file, transport script and typed-config capability the supported commands need is present in the installed outputs; secrets and private material are not; and an invalid explicit payload root fails instead of silently falling back to the source tree. The installed host package also refreshes private registry credentials before they expire (finding F31).

To see it working, run `scripts/rehearse-clone-free-release.sh` against the exact candidate flake reference on each native system (see Concrete Steps). Each run writes a JSON report with `cloneFree: true`, the candidate revision, the system, and passing checks including `typed-config`; [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes those reports together with the native build outputs. Today the runner works only on `aarch64-darwin`, at revisions older than the final candidate, and names its compile check `inventory-compile`, which the release gate refuses.


## Progress

Full dated history is in [the snapshot](../audits/mp23-archive/plan-history/ep154-before-consolidation-2026-10-02.md). Item IDs in parentheses refer to the MasterPlan 23 Progress phases. The early reports below were written to private `/tmp` paths and are not repository evidence; their results are recorded in the cited commits.

- [x] Early installed smoke on `aarch64-darwin` (2026-09-27/28). `rehearse-clone-free-release.sh --smoke-only` passed outside the checkout at `2717b386`, `699ae909` and `7f3e2eac` (version, context, inventory compilation, payload, operator tools, local init; `cloneFree: false` by design). Evidence: commits `9600f18e`, `61064401`.
- [x] Full clone-free rehearsal on `aarch64-darwin` (2026-09-28). Passed at `ba216160` and again at `c7fdb132` with `cloneFree: true` and ten checks (version, context, inventory-compile, payload, host-config, local-init, cloud-init, context-env, operator-recipe, platform-upgrade); the upgrade dry run stayed `planned` with one Pulumi preview and no apply. Evidence: commits `6ebc106d`, `dfd674e7`.
- [x] Negative package checks on `aarch64-darwin` (2026-09-28). At `c7fdb132`, `nix build` of the checks `nagare-clone-free-platform` and `nagarectl-external-config` passed: packaged `cluster/secrets` are excluded, context-owned secrets resolve externally, an invalid explicit `NAGARE_PLATFORM_ROOT` is refused, an invalid typed config fails before provider effects, and the private `ServiceName` constructor is not constructible. Evidence: `c7fdb132` (wrapper fix), `6705e83f`.
- [ ] (MP-23 A3, with EP-156) F31 fixed: the refresh timer in `nixos/hosts/nagare-01/registries.nix` and its token-lifetime check are aligned with metadata-server token caching so every successful refresh installs credentials that outlive the next scheduled run with margin; a rendered-timer regression demonstrates the old gap and its absence; EP-156 independently observes a genuine automatic replacement before expiry on a fresh host (F15 closure is EP-156's C3). Source complete (2026-10-02, `ebe9d3a7`): 120 s cadence, 5 s accuracy and 60 s timeout, asserted below the 300 s minimum token lifetime, with no write for an unchanged token. `scripts/test-registry-credential-delegation.py` checks the invariant and fails on the old module. The installed fresh-host observation remains.
- [ ] (MP-23 A5, with EP-157) The clone-free rehearsal performs and reports a `typed-config` check — loading a shipped typed config from outside the checkout, not merely renaming `inventory-compile` — and a real report is accepted by `scripts/assemble-inventory-release-index.py` and `Nagare.Inventory.ReleaseEvidence`. The other half of A5, the missing cloud `fixture.json`/`cloud-health.json` producer, belongs to EP-157. Source complete (2026-10-02, `7e26a1bb`): the rehearsal runs the new read-only `nagarectl app check --file Config.hs` on the multi-workload example and reports `typed-config` and `inventory-compile`, both now required by the gate. A native rehearsal report accepted by the index remains.
- [ ] (MP-23 C4) M1: at the final candidate, the runtime resources used by bootstrap, application/data commands, image publication, store recovery, provider transports and the deferred-route guards and recovery handlers resolve from installed outputs, with missing-resource and negative checks passing.
- [ ] (MP-23 C4) M2: at the same candidate revision, `nix flake check` passes and the full clone-free rehearsal passes natively on both `aarch64-darwin` and `x86_64-linux`; a manifest of native output paths, payload digest, tool versions and both reports is handed to EP-157.


## Surprises & Discoveries

Only entries that still shape the work are kept; the rest are in [the snapshot](../audits/mp23-archive/plan-history/ep154-before-consolidation-2026-10-02.md).

2026-09-27: The runner's unqualified `deploy --dry-run` stopped before typed-config loading because reviewed deploy now requires `--tag` and an accepted `--image-resource`. The runner was changed to use the read-only inventory compiler instead (`9600f18e`), which also renamed its check from `typed-config` to `inventory-compile`. The same day `fe048bde` made the release index require `typed-config`. This is the origin of the A5 mismatch: every real rehearsal would be refused at assembly.

2026-09-28: Adding an invalid-root assertion to the negative fixture found a real wrapper defect: `--set NAGARE_PLATFORM_ROOT` erased the caller's explicit root, so an invalid root silently used the installed payload. Using `--set-default` fixes it (`c7fdb132`). The same fixture's older expectations (Pulumi `config set` calls from `init --dry-run`, direct `kubectl` bootstrap recipes) were stale against reviewed bootstrap and were aligned, not weakened.

2026-10-02 (F31): The host timer refreshes every 30 minutes (`OnUnitActiveSec = "30min"`) and accepts any token with `expires_in > 300`. The metadata server returns a cached token until about five minutes of lifetime remain, so a successful refresh can install a credential that expires before the next run; native evidence showed at least 128 seconds of expiry before the next scheduled refresh ([F31 evidence](../audits/mp23-independent-results-2026-10-02/registry-timer-expiry-gap-f31.json)).

2026-10-02: All existing installed evidence is `aarch64-darwin`-only and predates the EP-153/158–160 work: 98 commits since `c7fdb132` touch `cli/`, `nix/`, `scripts/` or `nixos/`. `x86_64-linux` has never been exercised. None of it is final-candidate evidence.


## Decision Log

Decisions still in force, condensed. Full entries are in [the snapshot](../audits/mp23-archive/plan-history/ep154-before-consolidation-2026-10-02.md).

2026-10-02: Consolidate this plan to current state with MP-23; history moves to the snapshot. No scope or acceptance change. This plan co-owns F31 (A3) with EP-156 and F15 (Verifying; native closure in EP-156 C3). F23, F24 and F27, which also list EP-154 as co-owner, are Closed and need no work here.

2026-10-02: Final evidence is bound to one candidate revision. Earlier runs count only where their recorded inputs match that candidate; evidence for an older payload is never relabelled.

2026-09-29: Cloud-first scheduling: installed checks needed by EP-156's cloud work come first; the full multi-system matrix runs once, after feature and command work stabilizes, not after every small edit. Both native systems remain mandatory.

2026-09-28: Package the supported commands plus the deferred-route guards and retained recovery handlers (fence, session and partial-prune decoders) required by EP-153; deferral of new admission is not a reason to remove recovery code.

2026-09-27: The `--smoke-only` report deliberately says `cloneFree: false` so the release gate can never count a smoke as a complete rehearsal. Darwin success never implies Linux success, and `supportedSystems` is not reduced to avoid a failing runner.


## Outcomes & Retrospective

Current state (2026-10-02): installed smoke, full clone-free rehearsal and negative package checks have passed on `aarch64-darwin` at September 28 revisions. M1 and M2 are open: the payload matrix has not been traced at the final candidate, `x86_64-linux` has never run, `nix flake check` has not been recorded green (it previously stopped at the formatting gate, which EP-153's A6 owns), the runner's check name does not match the gate (A5), and F31 is open.

Lesson: the smoke workaround of 2026-09-27 silently diverged from the gate written the same day because neither side ran the other's fixture. Producer and consumer of a check name must change in one commit with a test that feeds a real report to the gate.


## Context and Orientation

Terms used here. The *payload* is the immutable Nix output holding platform files (Pulumi program, NixOS modules, cluster manifests, scripts) that the installed `nagarectl` uses; the *operator package* adds platform tools (Pulumi, kubectl, Helm and similar), the *developer package* only what application commands need. *Clone-free* means run from a directory outside the repository, with a fresh `HOME`, config and state root, against an exact flake reference such as `git+file:///path/to/nagare?rev=<sha>`. A *native system* is a real machine of that architecture and OS, not emulation. A *typed config* is a Haskell-DSL resource declaration compiled by `nagare-dsl`; the `typed-config` check proves an installed CLI can load one shipped with the payload.

Key files. `release.json` declares `supportedSystems`. Packaging is `nix/platform-package.nix`, `nix/nagare-packages.nix` and `nix/haskell-packages.nix`; flake checks are `nix/checks/{haskell,infra,platform,scripts}.nix` (the negative checks are `nagare-clone-free-platform` in `nix/checks/platform.nix` and `nagarectl-external-config` in `nix/checks/haskell.nix`). `scripts/rehearse-clone-free-release.sh` is the clone-free runner; `scripts/check-release.sh` and `scripts/test-release.sh` check release metadata; `.github/workflows/release.yml` records native output identities. The gate readers are `scripts/assemble-inventory-release-index.py` and `cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs`, which require `cloneFree: true`, not `installedSmoke`, every supported system, and checks `version`, `context`, `typed-config`, `payload` and `operator-recipe`. The registry credential timer is in `nixos/hosts/nagare-01/registries.nix`, with typed ownership in `cli/nagarectl/src/Nagare/Inventory/RegistryCredentials.hs`. Finding status lives in [the findings tracker](../audits/mp23-findings.md).

Relevant ADRs: [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) (immutable releases and native evidence), [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) (operator state stays outside the payload), [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) (version identity across CLI, payload and host), [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (revision-bound release evidence).


## Plan of Work

First the Phase A fixes, which need no native matrix. For F31 (A3), change the refresh schedule and lifetime acceptance in `registries.nix` so the installed credential's remaining lifetime always exceeds the time to the next run plus a retry margin — for example by refreshing well within the metadata cache window and rejecting tokens whose remaining lifetime does not cover the next interval — and extend the rendered-timer regression to fail against the current values. Coordinate with EP-156, which proves the behavior on a fresh host without manually starting the unit or patching credentials. For A5, restore a real typed-config check in `rehearse-clone-free-release.sh` (compile a shipped typed config from the installed payload outside the checkout and report `typed-config`), keep `inventory-compile` as an additional check if useful, and add a test that feeds a runner-shaped report to the release index so the names cannot drift again.

Then M1 at the candidate: trace each runtime resource used by the supported commands into the installed outputs, extending the two negative checks and the runner where a resource is unchecked. Finally M2: once EP-153's coverage and the feature children have converged on the final candidate, run `nix flake check` and the full rehearsal on both native systems at that one revision and assemble the manifest for EP-157. Host activation is proved by EP-156's cloud scenario; a Linux package build alone does not prove it.


## Concrete Steps

Run from the repository root in the project development shell; the rehearsal must run on each native machine.

```bash
bash scripts/test-release.sh
nix build --no-link .#checks."$(nix eval --raw --impure --expr builtins.currentSystem)".nagare-clone-free-platform
nix build --no-link .#checks."$(nix eval --raw --impure --expr builtins.currentSystem)".nagarectl-external-config
nix flake check
: "${NAGARE_CANDIDATE_VERSION:?version from release.json}"
: "${NAGARE_CANDIDATE_FLAKE:?exact flake ref, e.g. git+file:///path/to/nagare?rev=<sha>}"
: "${NAGARE_NATIVE_EVIDENCE:?private output path for the JSON report}"
bash scripts/rehearse-clone-free-release.sh --version "$NAGARE_CANDIDATE_VERSION" --flake-ref "$NAGARE_CANDIDATE_FLAKE" --output "$NAGARE_NATIVE_EVIDENCE"
```

The runner exits nonzero on the first failing check. A successful run prints and writes a report whose `revision` equals the candidate, whose `system` is the machine's, with `cloneFree: true`, a `checks` list that includes `typed-config` once A5 lands, and `platformUpgrade.state` equal to `planned` with no apply. The negative checks build successfully because their refusals are asserted inside the check.


## Validation and Acceptance

The plan is accepted when, for one candidate revision: both native systems pass `nix flake check` and the full clone-free rehearsal, and both reports carry the same revision and release contract with a passing `typed-config` check; the release index accepts the real reports; installed commands resolve every reviewed native source without a checkout, private material is absent from package outputs, and context state stays writable outside the payload; the negative schema, constructor and invalid-root checks still refuse; and F31 is Closed in the tracker by independent verification. Darwin evidence never substitutes for Linux.


## Idempotence and Recovery

Each rehearsal uses a fresh temporary home and state root and can be rerun; it performs only a planned upgrade preview and no apply. Do not reuse a report across revisions. Native cloud checks belong to EP-156 and follow its guardrails. Nothing here publishes a release, and source inspection never reads `/nix/store`.


## Interfaces and Dependencies

Produces, per system: the rehearsal JSON report and native build output identities, consumed by EP-157's `scripts/assemble-inventory-release-index.py` and `Nagare.Inventory.ReleaseEvidence` under `docs/release-evidence/<revision>/`. Consumes the code of [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) (commands, guards, style gate), [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) and [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md); packaging repairs can land at any time, but final evidence must cover the final code. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) and [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) consume installed candidates; EP-156 co-owns F31 and owns F15 closure.


## Revision Notes

2026-10-02: Consolidated with MP-23; history in the snapshot.
