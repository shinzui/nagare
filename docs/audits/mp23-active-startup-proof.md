# MP-23 active-command startup repair

This checkpoint exercises the real CLI execution factory for the saved synthetic
prune transaction used in [the shared-driver proof](mp23-rescue-proof.md). It does
not admit a new prune, mutate a real provider, or establish GCS latency.

## Defect and repair

The [baseline trace](mp23-active-startup-results-2026-09-29/before.json), using the
binary from `6ac96bf7`, shows that a single malformed unrelated archived review
prevents recovery before it can inspect the original operation. With no unrelated
review, the store path costs 66 cold / 39 warm gcloud subprocesses. The initial
fixture's host module failed the cluster guard, so these baseline counts measure
store setup and unresolved finalization, not provider recovery. The corrected
regression requires the original Job to be observed and records provider calls
separately; a guard-only refusal cannot pass.

Execution factories now receive the command's already validated store instead of
reopening it for each source-proof helper. Heads are still read at their existing
validation boundaries; no mutable head or claim is cached across commands.

`Status.loadAcceptedNativeSelected` resolves only the native members named by the
backup, volume, scheduled-ingestion or prune proof. Accepted/retained declarations
bind the bytes and their incarnation. A typed missing-member result permits the
legacy archive fallback, but corruption never does—even when another selected
member is missing. Current publications therefore avoid source-review archive
scans. Legacy histories still recover through their original envelopes without
requiring materialization. The fallback remains archive-sized and can still be
blocked by corrupt archives; that limitation is explicit, not a closed finding.

The complete original mutation review is still loaded and validated for execution.
Digest-addressed source bytes are inputs, not an authorization token. Scope,
source UID, policy, ownership, writer-claim and operation-time checks remain.
Kubernetes/broker execution does not resolve a workspace unless a selected
executor or required cache resolver needs one. Bootstrap payload/stamp checks and
workspace-dependent adapters retain their prerequisites.

## Measured outcome

[The corrected trace](mp23-active-startup-results-2026-09-29/after.json) passes all
12 cold/warm combinations with **57 total subprocesses cold / 36 warm**. Six are
Kubernetes observation calls. Store transport is **51 cold / 30 warm**, down from
66/39; neither unrelated review count nor journal length changes these counts.
Local wall times are 3.148–4.373 seconds cold and 1.874–2.375 seconds warm.

| Component | Cold calls | Warm calls |
| --- | ---: | ---: |
| Bucket/project/format initialization | 5 | 5 |
| Immutable original review, scopes and selected source bytes | 21 | 0 |
| Head/claim reads and conditional writes | 23 | 23 |
| Journal batch | 1 | 1 |
| Publication-key listing | 1 | 1 |
| Kubernetes guards and object observations | 6 | 6 |

The unresolved command performs no journal append. Its 23 head/claim calls are
seven generation-checked GETs (three subprocesses each) and two conditional PUTs.
This identifies the next transport target; it does not authorize removing claim
acquisition, fresh-head checks, or finalization. Completed-operation/append cost
remains covered by the earlier driver and append proofs, not this running-Job
matrix.

[All 947 tests pass](mp23-active-startup-results-2026-09-29/full-tests.txt) in 47.85
seconds. [All 11 legacy CLI cases](mp23-active-startup-results-2026-09-29/legacy-cli.json)
pass with extracted native copies removed. [All 12 complete no-op commands](mp23-active-startup-results-2026-09-29/noop.json) remain at 12 transport calls. Managed-command audit (139 routes,
34 recipes, 26 library calls), both entrypoint guards, Haskell style and strict
user/guide documentation validation pass.

## Regression boundary

`scripts/test-inventory-active-command-cost.py` holds the original active review
and uncertain operation fixed while independently varying 50/500 journal events
and 0/50/500 unrelated malformed reviews. Each combination starts a cold process
and a warm process, with an absent workspace. The recorder models conditional
head writes, observes the saved Job, and refuses provider mutations. The operation
remains unresolved under the same transaction and journal sequence. There is one
journal batch per command. Full original-review validation still lists publication
keys, so constant subprocess counts do not imply constant listing bytes or CPU.

The separate saved-transaction driver tests terminal recovery, completion,
interruption, changed UID and no-op replay, including histories without extracted
native copies. Unit tests reject corrupt selected sources and corruption hidden behind another
missing source; an absent unselected sibling does not block source reconstruction.

## Reproduction

From the repository root, generate a fixture if none is retained:

```bash
python3 docs/audits/mp23-reproductions/run-operational-cost.py prune-fixture
```

Then build both targets sequentially from `cli/nagarectl`:

```bash
cabal build exe:nagarectl test:nagarectl-test --enable-tests
cabal test nagarectl-test --enable-tests --test-show-details=direct
```

From the repository root, pass the generated `fixture-prune-fixture` directory:

```bash
python3 scripts/test-inventory-active-command-cost.py FIXTURE_DIRECTORY
MP23_LEGACY_OBSERVATION=1 python3 scripts/test-inventory-operation-driver.py FIXTURE_DIRECTORY
python3 scripts/test-inventory-command-cost.py
```

The active cost recorder caps each command at 25 seconds and 180 subprocesses.
It reports object initialization, immutable evidence, journal, head/claim, listing
and provider-observation counts separately. Its wall times include local recorder
startup and JSON simulation; they are not estimates of live GCS latency.

F04/F06 remain Partial. This repair removes the measured modern-history archive
coupling; it does not finish legacy archive isolation, command-wide head/cursor
reuse, or the real cold/warm GCS gate. The existing F05/F07/F08 host prerequisites
still apply before a cloud rehearsal. No cloud command was run for this proof.
