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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:53:10Z
      mode: "update"
      note: "Record critical intranet upgrade readiness and backup recovery acceptance with a one-hour recovery-point objective"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T20:11:06Z
      mode: "implement"
      note: "Enforce complete supported-contract evidence during non-publishing release acceptance"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:10Z
      mode: "update"
      note: "Consolidated with MP-23 into a current-state plan; prior body archived in docs/audits/mp23-archive/plan-history"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T04:05:29Z
      mode: "implement"
      note: "A5 producers and docs; record scenario-assertion producer gap"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T13:56:59Z
      mode: "update"
      note: "List concrete unmet production targets from D2, D3, D4 and D6"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T14:20:42Z
      mode: "implement"
      note: "Bound scenario assertion records: record/finalize tool and both gates require them"
---

# Gate the inventory release on complete immutable evidence

This ExecPlan is a living document and a child of [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. It was consolidated on 2026-10-02; the earlier dated narrative, superseded handoffs and full decision history are preserved verbatim in [the pre-consolidation snapshot](../audits/mp23-archive/plan-history/ep157-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file.


## Purpose / Big Picture

A Nagare release that claims the managed-resource inventory feature must be backed by proof, not by a checkbox. After this plan, release assembly accepts only one *candidate* (an exact commit whose Nix payload is built and tested) whose evidence is complete, matching and secret-free: native build outputs and clone-free installed rehearsals for every system in `release.json`, a complete command-coverage result, and one local and one GCP scenario run. Any missing, stale, altered or narrowed input refuses before any GitHub request. The observable result is a checked-in `docs/release-evidence/<revision>/` directory, a non-publishing release workflow run that assembles checksummed attachments including `nagare-inventory-evidence-v<version>.json`, and a `nagarectl release publish` review that reports "Review only" without contacting the forge.

This plan does not publish a release; publication is a separate, explicitly authorized action. It also does not make Nagare production-ready. MasterPlan 23 separates release acceptance from production readiness: production use additionally needs the data-protection gate (off-cluster backups within a one-hour recovery-point objective after total cluster loss, verified restored content, a documented recovery procedure) and [MP-21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md)'s rehearsed upgrade on an inventory-backed context. The release notes this plan produces must state every unmet production target explicitly.


## Progress

- [x] (2026-09-27) Aggregate evidence index binds both native systems, complete coverage and one local plus one cloud scenario to one candidate. Commit `fe048bde`; `python3 scripts/test-inventory-release-index.py` passes complete, missing-cloud, stale-native, incomplete-coverage, secret-canary and changed-target cases.
- [x] (2026-10-02) Assembly, workflow and checked publisher require the complete evidence directory and the exact supported/deferred contract. Commit `d1f2f9ec`; `scripts/test-release-evidence-public.py` accepts complete synthetic evidence and refuses a missing index, stale bindings, a missing Redis assertion with recomputed hashes, a changed target and expanded deferrals before any forge request. Independently re-run ([verification](../audits/mp23-independent-verification-2026-10-02.md), [output](../audits/mp23-independent-results-2026-10-02/release-public-e6255e6f.txt)).
- [x] (2026-10-02) Each scenario's public `fixture.json` definition is bound by its health record, the index and the publisher (attached as `inventory-<mode>-fixture.json`). Commit `32d59ee0`; a semantically foreign fixture refuses even with recomputed hashes. Independently verified ([output](../audits/mp23-independent-results-2026-10-02/host-and-release-public-c4-32d59ee0.json)).
- [ ] The clone-free rehearsal emits the check names the gate requires (`typed-config`, not `inventory-compile`) for both systems, and a cloud producer writes `cloud/fixture.json` and `cloud/cloud-health.json` with the local record's identity fields (MP-23 A5; co-owned with EP-154 and EP-156). Source complete (2026-10-02, `7e26a1bb`): a real `typed-config` check via `nagarectl app check` plus `inventory-compile`, both required by the index and `ReleaseEvidence`, and the GCP runner's cloud fixture/health producer. The aarch64-darwin native report at `7419f416` carries every required rehearsal name (EP-154). Outstanding: the x86_64-linux report. The scenario assertion record shape is now agreed and implemented (next item).
- [x] `docs/user/upgrades.md` describes inventory evidence as mandatory (2026-10-02, `7e26a1bb`; `okf validate docs/user --strict …` passes).
- [ ] `docs/release-evidence/<revision>/` exists for the final candidate with coverage, local and cloud inputs produced by EP-153/155/156, and the native artifacts from a workflow build of the same revision exist for x86_64-linux and aarch64-darwin (MP-23 C1–C4 inputs).
- [ ] A `workflow_dispatch` release run with `candidate_revision` and `evidence_revision` assembles without refusal, `nagarectl release publish` without `--yes` reports "Review only", and IR-24 cases 1–7 each map to a named evidence file (MP-23 C5).
- [x] (2026-10-03, implementer) Scenario assertion producer and gate agree on one record shape (see Decision Log). New tool `scripts/scenario-assertions.py` (record/finalize). The assembler and `ReleaseEvidence.hs` require bound records. `scripts/test-inventory-release-index.py` builds both synthetic scenarios through the tool and refuses: finalize before any or all records, an unsupported name, a re-record with different evidence, secret-shaped evidence, an evidence path outside the directory, a removed record, a foreign context, a failed record, edited evidence bytes, and extra checks. `scripts/test-release-evidence-public.py` refuses a removed record through the CLI validator. `scripts/test-release.sh` passes. The real producers are the C2/C3 runs.
- [ ] `docs/releases/v<version>.md` states the unmet production targets and that documentation and ADRs match supported behavior (MP-23 C5, D). The targets are: the data-protection gate (including restore after total cluster loss); the MP-21 upgrade gate; volumes outside the recovery-point objective (D2); HTTPS and protected browser login as a stated restriction (D3); recovery-time and retention targets not yet agreed (D4); and, for any context using `NAGARE_BACKUP_RECOVERY_POINT=daily`, an objective weaker than the one-hour production target (D6).


## Surprises & Discoveries

Full history is in [the snapshot](../audits/mp23-archive/plan-history/ep157-before-consolidation-2026-10-02.md).

2026-10-02 (consolidation assessment): every real clone-free rehearsal would be refused at assembly. `scripts/rehearse-clone-free-release.sh` lists `inventory-compile` in its full clone-free record (line 376; the installed-smoke record at line 174 uses the same name), while `scripts/assemble-inventory-release-index.py` (line 214) and `cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs` (line 72) require `typed-config`. The synthetic fixtures used by the gate tests write the required names, so the tests stayed green. Also, `scripts/rehearse-gcp-inventory-release.sh` writes only `target.json` and the review; no producer writes the cloud fixture definition or `cloud-health.json`. `fixtures/inventory-release/gcp/` holds only `ep150-target.json` (context `ep150-preview`) and the retired `f15-target.json`.

2026-10-02 (A5 implementation): the health records' `checks` serve two roles that no producer reconciles. The gate requires every scenario assertion name (`collision-refusal`, `adoption`, the three engine restores, `access-grant-revoke`, …, plus `retained-postgresql-rename` locally or `shared-history-takeover`/`google-cdn` in the cloud). Both runners write only infrastructure health checks (`kubernetes-api`, `knative-webhook`, …) at plan time. So even a complete scenario run is refused at assembly until the scenario runners (EP-155 B5/C2, EP-156 C3) record each assertion as it passes, bound to its evidence. Emitting the names without those runs would fabricate acceptance. The record shape must be agreed with EP-155/156 before C2/C3.

2026-10-02 (A5 implementation): `9600f18e` replaced the rehearsal's typed-config check (`deploy --dry-run --file Config.hs`) rather than renaming it, because reviewed `deploy`/`app deploy` require an accepted platform after loading. The read-only `nagarectl app check` restores an offline typed-config evaluation through the installed runtime.

2026-09-27: the existing one-run projector (`inventory-evidence.json`) cannot stand for both scenarios. The index therefore consumes one projector result per scenario and binds each to its own target and health record instead of redesigning the private export.

2026-10-02: the health record's `fixtureDigest` (hash of the shipped fixture definition) and the projector's canonical target digest intentionally differ; both are checked, and neither substitutes for the other.


## Decision Log

Decisions still in force, condensed. Verbatim entries are in [the snapshot](../audits/mp23-archive/plan-history/ep157-before-consolidation-2026-10-02.md).

2026-10-02 (consolidation): rewrite this plan as a current-state document aligned with MasterPlan 23 Phases A–D. No scope or acceptance change.

2026-10-02: keep the candidate commit and the later public-evidence commit separate and exact. Native builds use only the candidate; assembly checks evidence from `evidence_revision` against that candidate's payloads. The publisher re-validates the index and its inputs; checksums alone are not proof of complete supported-contract coverage.

2026-10-02: resolve the check-name mismatch on the producer side. The gate's `typed-config` name is the published contract recorded in evidence; the rehearsal must report the typed-configuration check under that name. Do not relax the gate.

2026-10-02: the retired `f15-preview` fixture and its transactions are not acceptance inputs ([disposition](../audits/mp23-prerelease-fixture-disposition.md)). A retired attempt is diagnostic history, never a successful receipt.

2026-10-02: release acceptance is not production readiness. Release notes must name unmet production targets rather than imply readiness.

2026-10-03: scenario assertions are bound records, not bare names. Each assertion is recorded as it passes with `scripts/scenario-assertions.py record --evidence-dir DIR --mode MODE --name NAME --summary TEXT --evidence PATH...`. That writes a create-only `assertions/<name>.json`, bound to the run's context, cluster, operator revision and fixture digest from the plan-time health record, with the SHA-256 of each public evidence file inside the evidence directory. Only gate-supported names are accepted, and secret-shaped content is refused. After verify, `scripts/scenario-assertions.py finalize` folds the records into `<mode>-health.json` (`preflightChecks`, `checks`, `assertions`). It refuses while any required name is missing. The assembler (`validate_assertions`) rehashes every evidence file, and `ReleaseEvidence.hs` (`scenarioAssertionsBound`) requires a bound, passed record for each required name. A name in `checks` without its record refuses.

2026-09-28: bind the operator-approved scope reduction into evidence. Coverage must carry the exact `deferredRoutes` (interactive maintenance, scheduled pruning, live database/volume overwrite) and `recoveryOnlyRoutes` sets; a still-enabled deferred route, an undocumented exclusion or a missing supported assertion refuses. There is no bypass flag.

2026-09-26: this plan takes the release-gate outcome from EP-150 and reuses its publisher (`1891b34c`) and projector (`432dad9a`, `cbd7c3cf`) rather than reimplementing them.


## Outcomes & Retrospective

The gate is implemented and independently tested: assembly, index, publisher and workflow refuse incomplete or dishonest evidence before any provider call. No real candidate evidence exists yet, so IR-24 case 7 is unproven. Remaining: the A5 producer fixes, the stale user documentation, and final C5 assembly once EP-153/154/155/156 deliver matching inputs. Lesson: gate tests built from synthetic producers hid a contract mismatch with the real producer; every evidence schema needs one test that runs the real producer's output through the gate.


## Context and Orientation

A *scope* is one owner's complete declared resource set; the *inventory* composes all scopes. A *review* is an immutable, digest-named plan of native effects; the private *journal* records execution receipts. The *projector* turns one run's private history into the public, secret-free `inventory-evidence.json`. A *clone-free rehearsal* installs `nagarectl` from the built Nix output, without a source checkout, and runs named checks. The *fixture definition* (`fixture.json`) describes the scenario environment; the *target* (`target.json`) is the saved-review target whose canonical digest the projector binds; the *health record* (`<mode>-health.json`) carries `schemaVersion`, `mode`, `context`, `cluster`, `operatorRevision`, `fixtureDigest`, `healthy` and `checks`.

The gate lives in four places. `scripts/assemble-release.sh --version V --input-root DIR --inventory-evidence DIR --output-dir DIR` combines native artifacts with the evidence directory, calls `scripts/assemble-inventory-release-index.py`, and copies every public input as `inventory-*.json` with `SHA256SUMS`. `cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs` re-checks the same contract inside `nagarectl release publish` (publisher modules `cli/nagarectl/src/Nagare/Inventory/Adapters/GitHubRelease.hs` and `GitHubReleaseRuntime.hs`). `.github/workflows/release.yml` builds each system in `release.json` (`x86_64-linux`, `aarch64-darwin`), runs the clone-free rehearsal there, and on `workflow_dispatch` assembles without publishing; a tag push publishes. Coverage comes from `scripts/audit-managed-commands.py --coverage-result FILE` (EP-153); local scenario inputs from `scripts/rehearse-local-inventory-release.sh` (EP-155); cloud inputs from `scripts/rehearse-gcp-inventory-release.sh` (EP-156).

The evidence directory, committed at `evidence_revision`, has this shape; native files come from the workflow's build jobs, not from the repository:

```text
docs/release-evidence/<candidate-revision>/
  coverage.json
  local/  fixture.json  target.json  local-health.json  inventory-evidence.json
  cloud/  fixture.json  target.json  cloud-health.json  inventory-evidence.json
native artifacts (per system): nix-output-<system>.json  clone-free-<system>.json
```

[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence from validated tags. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) defines scopes, reviews and the reduced supported contract. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) limits this first release to fresh inventory-backed contexts. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private state out of payloads and public evidence. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) governs the cloud scenario's project guardrail.


## Plan of Work

Milestone 1 — align the real producers with the gate (MasterPlan A5). In `scripts/rehearse-clone-free-release.sh`, report the typed-configuration check as `typed-config` in the full clone-free record (and, for consistency, in the installed-smoke record) so the clone-free record contains `version`, `context`, `typed-config`, `payload` and `operator-recipe`. Add a checked-in GCP fixture definition for the fresh cloud context EP-156 uses in C3 and make `scripts/rehearse-gcp-inventory-release.sh` copy it to `cloud/fixture.json` and write `cloud/cloud-health.json` with the same identity fields as the local record and cloud-specific checks, following the pattern in `scripts/rehearse-local-inventory-release.sh`. Add one test that feeds actual producer output (not a synthetic fixture) through the index. Correct `docs/user/upgrades.md` so inventory evidence is described as a mandatory part of assembly. Done when the index accepts real producer output and the existing refusal tests still pass.

Milestone 2 — final non-publishing assembly (MasterPlan C5). After C1–C4 on one frozen candidate, commit the produced inputs under `docs/release-evidence/<candidate>/` in a separate evidence commit. Dispatch the release workflow with `version`, `candidate_revision` and `evidence_revision`; it must assemble without refusal. Run `nagarectl release publish --repo shinzui/nagare --version V --assets dist` without `--yes` on the assembled attachments and observe "Review only". Map each IR-24 verification case to the evidence file that proves it, update the release notes with unmet production targets, then record results here, in MasterPlan 23 and in IR-24. Evidence from an earlier candidate counts only where its recorded inputs match the final candidate.


## Concrete Steps

Run from the repository root in the development shell. None of these publishes or touches a cloud project.

```bash
python3 scripts/test-inventory-release-index.py
python3 scripts/test-release-evidence-public.py --nagarectl "$(cd cli/nagarectl && cabal list-bin exe:nagarectl)"
bash scripts/test-release.sh
bash scripts/test-managed-resource-evidence.sh
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p publication' --test-show-details=failures)
grep -n 'typed-config' scripts/rehearse-clone-free-release.sh
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
```

Expected: every test exits zero and the public evidence test prints `public release review accepts complete proof and refuses missing, stale and narrowed evidence`. After Milestone 1 the `grep` finds `typed-config` in the clone-free check list. For Milestone 2, with downloaded native artifacts in `native/` and the evidence directory checked out:

```bash
bash scripts/assemble-release.sh --version "$VERSION" --input-root native \
  --inventory-evidence "docs/release-evidence/$CANDIDATE" --output-dir dist
```


## Validation and Acceptance

A complete candidate assembles reproducibly: the same inputs produce the same attachment bytes and `SHA256SUMS`. Removing either scenario, either native system, a receipt or a coverage entry, changing a source, payload or fixture binding, or widening the deferred set refuses before any publication call. No private archive, native bundle or Secret value appears in any attachment. The checked publisher still recovers exact already-verified assets after a fresh checkout. Acceptance is the Milestone 2 workflow run plus the "Review only" result plus the IR-24 mapping, all bound to one candidate revision. No release-ready claim is made while any supported assertion, deferred-route guard or finding in [the tracker](../audits/mp23-findings.md) is unresolved.


## Idempotence and Recovery

The index, assembly and review steps are pure checks over files and can be rerun freely. Never relabel cached artifacts or earlier-candidate evidence as final-candidate evidence; a changed input needs a new evidence commit. Same-tag retries must keep exact bytes and provider asset IDs. Do not search `/nix/store`; inspect sources in the checkout and use Mori for dependencies.


## Interfaces and Dependencies

Index interface: `python3 scripts/assemble-inventory-release-index.py --release-metadata release.json --release-manifest FILE --native-dir DIR --coverage-result FILE --local-dir DIR --cloud-dir DIR --output FILE`. Workflow inputs: `version`, `candidate_revision`, `evidence_revision` (40-hex commits). Producers: [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) coverage, [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md) native artifacts on both systems, [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) local scenario, [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) cloud scenario. [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) and [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) must be accepted for MasterPlan closure. Hard prerequisites EP-146, EP-147, EP-149 and EP-151 are complete.


## Revision Notes

2026-10-02: Consolidated with MP-23; history in the snapshot.
