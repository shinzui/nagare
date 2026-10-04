# MP-23 independent review brief: candidate `7596632c`

You are the **independent reviewer** for MasterPlan 23's release. This brief is self-contained:
read it, then the documents it links, and you can start.
- You did not implement any of the work under review. Two sessions did: nagare-phase-b and nagare-f3.
- Your job is to check that each fix really corrects its stated failure, and that the release's operational runbook works for an operator who has never seen it.
- A finding closes only on your check. The implementers never close their own work.

Written 2026-10-04 by session nagare-phase-b (claude-opus-5-5), at the operator's request. The
operator's decisions behind it are recorded in the
[MP-23 Finish line](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md)
("Operator decisions").

## 1. Ground rules

- **Repository rules:** follow `CLAUDE.md`.
  - Act only on the active context's project.
  - Stop and report when any guard refuses; never work around one.
  - Never reset history, patch a provider or hand-write evidence to manufacture a result.
  - A cloud-mutating step needs the operator's go-ahead. Rehearse first, then ask once for a bounded sequence.
- **Don't change implementation code.** If a check fails, mark the finding **Reopen** with your evidence and tell both sessions. The owner fixes it, which makes a new candidate.
- **Run `nagarectl` through `env -i` wrappers** with isolated XDG roots, never from a direnv shell. See [the native verification harness runbook](../runbooks/native-verification-harness.md), §2.
- **The shared local cluster (cp3)** is used under the claim protocol in runbook §3. Never break another session's claim.
- **Never print a secret value.** Evidence must not contain JSON keys matching `password|credential|access.?token|private.?key|secret`.
- **Commits:**
  - Conventional Commits, trailer `MasterPlan: docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md`.
  - Stage and commit by explicit pathspec (`git add -- <paths> && git commit -F - -- <paths>`): several sessions share this checkout.
  - No `git stash`, `git checkout <rev> --` or `git add -A`.

## 2. The candidate

| Item | Value |
| --- | --- |
| Revision | `7596632cee07d107a93b7d2032923b7f4b6b8904` |
| Clean worktree | `/private/tmp/nagare-cand-7596632c-src` |
| Package (CLI + payload) | `/private/tmp/result-7596632c-nagare` (`bin/nagarectl version --json` reports the revision) |
| Release manifest | `/private/tmp/nagare-release-7596632c/aarch64-darwin/nagare-release-0.4.0.json` |
| Coverage audit | `/private/tmp/nagare-release-7596632c/coverage.json` (complete, not dirty) |

Read source and run tests **in the clean worktree**, not the shared checkout, so other sessions' work in progress cannot affect your results.

```bash
cd /private/tmp/nagare-cand-7596632c-src/cli/nagarectl
cabal build nagarectl-test --builddir /tmp/review-7596632c
"$(find /tmp/review-7596632c -type f -name nagarectl-test -perm -u+x | head -1)" -p '<pattern>'
```

## 3. What "closed" means

From the [findings tracker](mp23-findings.md):

> `Closed`: an independent check proves the stated failure corrected and the required regression evidence is retained. Reopen on failed verification.

A sent message, a passing unrelated suite or a test count is not closure. For every finding:
1. Read its tracker section: the failure, the required repair and the implementer's evidence.
2. Read the fix's diff.
3. Confirm the regression fails on the parent commit and passes at the candidate.
4. Where native evidence is required, check it on the run named below.
5. Record a **Verification** paragraph in the finding's section, with what you checked, how, and the result. Set the status to Closed, or Reopen.

## 4. Work plan

Three phases, matching when the evidence exists. Phase 1 can start now.

**Phase 1: source and regressions (now, no cluster).**

| Finding | Fix commits | Regression / what to check |
| --- | --- | --- |
| F16 unready create cannot yield to a corrected config | `0f6fa7db` `49db2199` `7c957c02` `eb582eb0` | the tracker section's regressions; corrected config converges without losing ownership |
| F30 status churn strands an admitted Service correction | `95b58a24` `52432400` (and the F34 repair `beca6886`) | the tracker section's regressions. Native terminal resume (A4) was recorded on 2026-10-02; check it in the tracker |
| F32 image cleanup selects an image in use by sandboxes | `c2dc2bb1` `ae1f26ee` | cleanup protects images of Ready/retained sandboxes and the sandbox image; fails closed when observation is missing |
| F33 cloud collection skips its incarnation recheck | `e1371442` | the selected stack entry, physical ID and protection are rechecked at preflight and just before execution; regression for a change between the two |
| F35 refused preflight after admission strands the transaction | `570467f0` | `test/InventoryRefusedPreflightRecoverySpec.hs` (`abandon-refused-operation`) |
| F36 failed Redis scratch restore wedges the store | `6d7951c9` | `test/InventoryRedisRestoreRecoverySpec.hs` |
| F37 foreign field-manager drift has no reviewed repair | `d9aed800` `1df735a6` | `test/InventoryKubernetesFieldTakeoverSpec.hs`, `test/InventoryRefusedPreflightRecoverySpec.hs` |
| F38 failed GCS head advance stops ambiguous and drops the error | `7596632c` | `test/InventoryJournalHeadAdvanceSpec.hs` (three cases). The implementer reports all three fail on the parent; confirm. Also judge the stated deviation: the error goes to stderr, not into the `StoppedAmbiguous` value |
| F39 staged cloud teardown cannot prepare Pulumi operations | `24320d82` `d9c244ed` | `test/InventoryCloudSpec.hs` |
| F40 (part in scope) contribution targets, cycles, host/artifact retention | `8fef3559` `07d203ad` `d9c244ed` | `test/InventoryContributionRetirementSpec.hs`. The remainder (full-context VM collection) moved to MasterPlan 25 by operator decision; check that only that remainder is left |
| F41 local node restart destroys local backups; offline escrow verification | `64f5c0e3` `57553ab5` | the MinIO PVC and Recreate strategy; `db verify-escrowed-backup --offline-object-store` accepts loopback only and checks credential-file mode |
| F42 evidence assembler cannot accept real runner output | `97ae5f54` (plus helper fixes `4ad4392a` `e41b1cab`) | `scripts/test-managed-resource-evidence.sh` with its real-output fixture |
| F43 fresh context cannot enable the platform CDN backend | `0c6ad875` | the CDN flag and catalogue section |
| F44 status never observes cloud-foundation members | `9c831749` | `test/InventoryObservationSpec.hs` (`missingStatusObservers`) |
| F45 / F46 / F47 Google CDN DNS on inventory contexts | `471cb409` | `test/InventoryCdnSpec.hs`, `test/AppDeploySpec.hs`, `test/Nagare/Test/SiteInventory/Server.hs` |

Also in phase 1, accept or reject the two **recorded arguments**:
- [EP-159](../plans/159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), "Source replacement (MP-23 B1)": the proposal re-scopes the item to "out-of-band replacement refuses ingestion and isolated restore; recovery uses the source-unavailable path".
- [EP-160](../plans/160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md): the Redis load interruption and partial ClickHouse effect are covered by existing runs plus F36 and F22.

Record your verdict on each in its plan's Progress item.

**Phase 2: local evidence (after the 7596632c C2 finishes; nagare-phase-b reports it).**
- The C2 evidence directory, path from nagare-phase-b:
  - `local-health.json` must be finalized with 16 assertions;
  - `inventory-evidence.json` must have been accepted by the assembler;
  - `platform-root.json` must show revision `7596632c…`. That is F48's procedural guard, which the operator accepted for this release.
- Native local proof inside that run: F34 (preview cleanup collects the DomainMapping and its descendants), F36, F37 and F41 (`checks/` and `assertions/`). Check the evidence, not just the assertion summaries.
- **Independent local PostgreSQL isolated restore** ([EP-160](../plans/160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md)): do it yourself on the C2 context after nagare-phase-b releases the cp3 claim. Take the claim, back up a database with known rows, write a later row, restore into an isolated target, read the known rows back, confirm the source kept the later row, then release the claim.

**Phase 3: cloud evidence and the runbook (after nagare-f3's acceptance C3 on `mp23-c3h` / `*-c3-1006`).**
- Native cloud proof in that run:
  - F15: a genuine credential refresh and an expired-credential pull;
  - F31: refresh lands before expiry;
  - F33: exact collection;
  - F45, F46, F47: the CDN cycle create, disable, retire and collect;
  - F16, F30: application change and recovery;
  - F39: staged retirement.
- Check `platform-root.json` in the cloud evidence as well (F48 guard).
- **Execute [the operations runbook](../runbooks/inventory-operations.md) end to end on the acceptance C3 context, before it is torn down.** Record F14–F18 and the cloud operational checks in the tracker. nagare-f3 keeps the context alive until you finish. Any cloud-mutating step in the runbook needs the operator's go-ahead, which you ask for once for a bounded sequence.

## 5. Recording results

- Per finding: a **Verification** paragraph in its [tracker](mp23-findings.md) section, with the status set in both the section header and the status register.
- Per run or check: JSON or Markdown records under `docs/audits/mp23-independent-results-2026-10-04/`, following the shape of `docs/audits/mp23-independent-results-2026-10-02/`.
- When phase 3 is done, tick the "Independent verification" boxes in the MP-23 Finish line, with links to your records.
- Message both sessions after each phase: nagare-phase-b and nagare-f3, which can be found with `ListAgents`. Name every finding still Open, Partial or Verifying and the next required check.

## 6. Out of scope

- F48's code fix. The operator accepted the procedural guard for this release, so you verify the guard was followed; F48 stays Open for [EP-168](../plans/168-script-the-local-acceptance-run-as-one-command.md).
- F40's remainder (MasterPlan 25).
- D4 recovery-time targets and the data-protection and production gates.
- [MasterPlan 26](../masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md).

## 7. Known limits of the implementers' evidence

These are worth your scepticism:
- The F38 regressions use the production `ObjectBackend` code path over fake object operations. A real GCS head failure was not injected natively.
- B3 was first proven natively with a development CLI on the `7d486457` checkpoint (`mp23-c3g`). Only the acceptance C3 on `7596632c` counts.
- The acceptance C2 drivers are session-written shell (archived under `docs/audits/mp23-implementer-results-2026-10-03/c2-drivers/`, unmaintained). Judge the evidence they produced, not the drivers.
