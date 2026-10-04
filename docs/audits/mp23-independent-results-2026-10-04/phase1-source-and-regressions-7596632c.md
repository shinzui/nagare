# MP-23 independent review, phase 1: source and regressions (candidate `7596632c`)

Reviewer: nagare-reviewer (claude-opus-5-5), 2026-10-04. Brief: [mp23-independent-review-brief-7596632c.md](../mp23-independent-review-brief-7596632c.md), §4 phase 1.

## Method

- **Source:** each fix's diff was read in the clean worktree `/private/tmp/nagare-cand-7596632c-src` (HEAD `7596632cee07d107a93b7d2032923b7f4b6b8904`), never the shared checkout.
- **Candidate suite:** the full `nagarectl-test` suite at the candidate passes all 1,184 tests.
- **"Fails without the fix"** was established in private throwaway worktrees, by one of three methods:
  - **Literal parent:** the fix's parent commit with the fix's own test files overlaid. Used for the older fixes, whose source no longer reverse-applies at the candidate.
  - **Fix removed:** the fix's non-test source reverse-applied at the candidate.
  - **Mutation:** where the regression cannot compile without the fix because the tested API is new, the specific guard was disabled at the candidate and the regression rerun.
- **Raw results:** [phase1-regression-runs-7596632c.txt](phase1-regression-runs-7596632c.txt). A compile failure alone was not accepted as proof; every such case either got a behavioural mutation or is noted below.

## Results

| Finding | Fix | Regression without the fix | Source read | Phase-1 verdict |
| --- | --- | --- | --- | --- |
| F16 | `0f6fa7db` `49db2199` `7c957c02` `eb582eb0` | `eb582eb0` fails (convergence leak); `7c957c02` fails ("unchanged stopped workload lacks fresh readiness proof"). `0f6fa7db` fails only to compile, and its stop-guard mutation fails "refuses foreign scope". `49db2199` fails only to compile. | ok | source verified; native in phase 3 |
| F30 | `95b58a24` `52432400` | `52432400` fails ("observation Kubernetes envelope differs from reviewed operation"). `95b58a24` fails only to compile (new module). | ok | source verified; native in phase 3 |
| F32 | `c2dc2bb1` (`ae1f26ee`) | `test-image-prune-protocol.py`: the first sandbox case fails on the parent script; 23/23 pass at the candidate. Coverage tests pass. | ok | source verified; native in phase 3 |
| F33 | `e1371442` | ID-check mutation fails ("replacement incarnation was prepared"). | ok; the recheck runs at preparation, at preflight, and immediately before `up --plan` (collection uses `RetireResource`) | source verified; native in phase 3 |
| F34 | `beca6886` | fails only to compile. The Orphan-refusal mutation survives, because the same fix also removed DomainMapping from `collectionPathPrefix` (redundant guard). | ok | **Closed**, on native C2 evidence |
| F35 | `570467f0` (`d9aed800`) | the prerequisite-guard mutation fails (EarlierUncertain) | ok | **Closed**, with the reviewer's native race ([record](f35-native-race-7596632c.json)) |
| F36 | `6d7951c9` | the owner-UID mutation fails. The two "extra member" mutations survive; the role-set check is redundant with them. | ok; a false-positive restart only permits abandoning an isolated scratch restore | **Closed**, on native C2 evidence |
| F37 | `d9aed800` `1df735a6` | `d9aed800` fails (ExecuteRefusal: the native `recovery-state` wedge). The `1df735a6` settled, binding and identity mutations fail 1/7, 2/7 and 1/7. | ok; refusals precede any write, and the takeover apply carries UID/resourceVersion preconditions | **Closed**, on native C2 evidence |
| F38 | `7596632c` | all three cases fail individually; the third wedges at resume | ok; claim check before publish; orphan adoption limited to the same transaction and chain position; whole-manifest comparison (generation, so no ABA) | **Closed**; deviation accepted |
| F39 | `24320d82` `d9c244ed` | fails with the native `PulumiResourceStepMissing` | ok | source verified; native in phase 3b |
| F40 | `8fef3559` `07d203ad` | fails with the native `retirement-required`; fails with `invalid-retirement` for the host system | ok; the remainder equals MasterPlan 25's three obstacles | stays **Partial**; native in phase 3b |
| F41 | `64f5c0e3` `57553ab5` | MinIO scope fails (5 natives, no PVC); loopback mutation fails | ok; loopback-only origin; credentials via stdin | **Closed**, on native C2 evidence |
| F42 | `97ae5f54` (`4ad4392a` `e41b1cab`) | fails with the native refusal; both helper regressions fail on their parents | ok | **Closed**: the reviewer re-assembled the C2 evidence identically |
| F43 | `0c6ad875` | catalog mutation fails; Pulumi tests 8/8 at the candidate | ok; `scripts/lib/target.sh` only adds validation, guardrail untouched | source verified; native B3 in phase 3 |
| F44 | `9c831749` | fails only to compile. The regression is structural: it checks `missingStatusObservers` against a list, not the executable's real observer registry (`app/…/Inventory/Status.hs`). | ok | source verified; native C3 runner in phase 3 |
| F45/F46/F47 | `471cb409` | all three regressions fail; F47 has no unit test by design | ok; the apex guard stays fail-closed on a failed `apexIp` read | source verified; native in phase 3 |

## Notes for the owners (not reopenings)

- **F41:** the offline credential-file mode check (`SigningKeyEscrow.hs`) has no unit test. Natively, the C2 credential file is mode 0600.
- **F37/F35:** `abandon-refused-operation` now trusts any journalled `KnownNoEffect`. `CdnPurge.execute` labels a failed re-verification after an earlier submitted purge as `KnownNoEffect`; abandoning it is harmless (no ownership), but the label is imprecise.
- **F36:** the "extra member" test exercises only one of three redundant conditions.
- **Tasty patterns** containing parentheses, such as `-p '(F35)'`, are rejected and run nothing; use plain substrings.

## Recorded arguments

- **EP-159, source replacement:** the re-scope was accepted on source grounds (`replacement-review-required`, `retained-reactivation`, `reserved-claim`, and the restore incarnation guard all exist). The native drill (implementer, `d19df6d1`) then disproved half of the re-scoped claim: a receipt written by the replaced incarnation plans for ingestion, and status reports the replaced database converged. This is opened as [F49](../mp23-findings.md#f49), and the item stays open.
- **EP-160, Redis interruption and partial ClickHouse effect:** accepted, with a correction. A kill during the Redis download init container leaves partial files on the PVC-backed `/dump`. The restarted init container then fails (`test ! -e`), so the outcome is F36 abandonment, not resume convergence. A kill after the completion marker converges. In every case:
  - `redis-check-rdb` validates the file before the server starts;
  - the verify Job requires `loading:0`;
  - restore Jobs have `backoffLimit: 0`.
  So a half-loaded instance cannot be accepted, and a partial ClickHouse effect fails the Job and ends in the F22 terminal abandonment.
