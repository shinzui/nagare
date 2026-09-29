# MP-23 operational experiments — 2026-09-29

The operator requested experiments before another planning revision. These probes test
the claim that locally correct primitives were mistaken for usable command paths.
They use production source at `270db9191a4220444421e2c36f47b5f1141c4f79`, isolated
local stores, and recording provider boundaries. No cloud or cluster was contacted.
They do not establish release readiness or close the scheduled-prune finding F09.

## Reproduction and evidence

Run from the repository root in its existing development shell:

```bash
python3 docs/audits/mp23-reproductions/run-operational-cost.py
python3 docs/audits/mp23-reproductions/ExplainBoundary.py
# Run only the follow-up native lookup/publication spike:
python3 docs/audits/mp23-reproductions/run-operational-cost.py native
```

The first runner limits each source probe to 90 seconds including compilation,
records source hashes, and fails if those source bytes change during the run.
It exposes private `appendEvent`, `sameNativeBinding`, and the `ReviewBundle` constructor only in temporary module copies. Four temporary
imports explicitly select `memory`, matching Cabal when the interactive environment
also exposes `ram`; no production logic is changed. The second runner uses the
built CLI (confirmed up-to-date with `cabal build exe:nagarectl --dry-run`), gives
each invocation 15 seconds, and replaces provider executables with refusing recorders.
These deadlines are for isolated diagnostics, not instructions to kill live mutations.

[Retained source hashes](mp23-experiment-results-2026-09-29/source-hashes.json),
[history results](mp23-experiment-results-2026-09-29/history.txt),
[append trace](mp23-experiment-results-2026-09-29/transport.txt),
[counterfactual append trace](mp23-experiment-results-2026-09-29/snapshot.txt),
[recovery results](mp23-experiment-results-2026-09-29/recovery.txt),
[replay checks](mp23-experiment-results-2026-09-29/replay.txt), and
[public explain results](mp23-experiment-results-2026-09-29/explain.json)
are retained in the repository. Temporary paths in the raw traces name synthetic diagnostic files.
Their continued existence is not needed to reproduce the experiments.

## E1 — a primitive write is not a complete journal append

Hypothesis: the one-write `appendAtObservedHead` test understates the cost paid by
`Execute.appendEvent`. Invoke the latter through the real `gcloudObjectOps`
transport with a local fake `gcloud` implementing generation-conditional storage.
Exclude initialization from the counters; record every subprocess for two appends.

Observed: the first event launches **8** subprocesses; the next launches **11**.
The noninitial trace is head GET (describe/copy/describe), previous-event GET
(describe/copy/describe), conditional event PUT, another head GET
(describe/copy/describe), and conditional head PUT. The previous audit's 27/21
counts describe older code and must not be used as current measurements.

A counterfactual wrapper reuses the observed head only within one append, while
keeping the actual transport's conditional PUT. This reduces counts to **5/8**.
Injecting a competing head generation immediately before the head PUT makes both
versions refuse with `inventory head generation changed`. The prototype preserves
this tested concurrency refusal; it does not prove lost-ack, takeover, or full
transaction correctness. It is deliberately absent from production code.

Conclusion: duplicate head discovery is a demonstrated removable cost, but removing
it saves only three calls. A head cache alone cannot justify a performance claim.
EP-156 must own the complete append protocol and its observed provider generation,
then count a complete resume, including registry construction and finalization.
These are subprocess measurements, not real GCS latencies or HTTP-request counts.

## E2 — unrelated review history is an input to current evidence lookup

Hypothesis: `Status.loadNativeFor` scales with historical reviews rather than the
resources requested. Hold accepted and retained state empty. Publish 0, 50, and 500
distinct, canonical reviews with no operations. Invoke `loadAcceptedNative` twice
at each size, first without and then with the production immutable-file cache.

| Unrelated reviews | Cold object GETs | Repeated GETs, no cache | Repeated GETs, warm cache |
|---|---:|---:|---:|
| 0 | 1 | 1 | 1 |
| 50 | 51 | 51 | 1 |
| 500 | 501 | 501 | 1 |

Every call also performs one list. Every result contains zero native resources.
An unused malformed review changes the empty lookup from success to failure.

Conclusion: cold or second-root reads have the predicted history multiplier.
The hypothesis that a warm cache repeats every remote GET is **rejected**. Source
inspection still shows traversal and reconstruction of every review on each call;
the probe did not measure decoded-member counts or real warm-cloud duration.
Fixing only the cache leaves the irrelevant-history dependency. EP-156 needs
selected native-evidence lookup; EP-153 must pass the actual resource selection.
Unknown IDs and empty native requests need no historical native scan. Corrupt
evidence actually selected for an operation must still fail closed.

## E3 — recovery ordering changes when a check moves across the factory boundary

Hypothesis: the executor's recovery-before-preflight guarantee does not cover
checks performed by command registry construction. Use the actual filesystem
store and `Command.resumeInventoryWithFactory` with an injected recording adapter.
Apply once; the effect records success externally but returns an ambiguous result.
Its old pre-effect condition is now false.

With that condition in the registry factory, resume refuses: **one original
effect, zero recoveries, zero adapter preflights**, unchanged head. Move the same
condition into `adapterPreflight` and resume the same transaction: it converges
with **one total effect, one recovery, zero repeated preflights**. A subsequent
converged command does not construct a registry at all.

Conclusion: check placement is causal, and the existing executor already handles
the tested ordering correctly. This single-operation probe does not justify rewriting its recovery state machine. E10 below subsequently exposes specific multi-operation executor defects that this fixture did not cover.
EP-153 must make registry construction reconstruct immutable inputs and place live
preconditions in the appropriate operation phase. EP-159 must then test actual
saved-prune CLI recovery before effect and after partial deletion. This experiment
uses a synthetic condition, not the production prune factory, so **F09 stays open**.

## E4 — the public explain command checks its target too late

Run the built CLI against an initialized empty private local history, asking for
`standalone:missing/object/resource`. No resource can match. The clean fixture
returns a platform-workspace manifest error, not unknown-resource; with an unused
malformed review it instead returns the review parsing error. Both make zero
provider calls. The second observation used a mode-0600 review; an earlier harness
attempt had incorrectly created it with public permissions and was corrected.

Conclusion: unrelated workspace/native prerequisites precede even negative target
resolution in the actual CLI. The experiment does not measure nonempty-context
provider fan-out. EP-153 must reject an unknown target immediately after loading
and validating the accepted/retained declaration set, and only then construct the
provider inputs required for a known target. An invalid target must not require a
working platform workspace.

## E5 — corrections that already work

Five checked-in tests passed against current source in 0.21 seconds of test time:
50/500-event batch replay and gap rejection; batched active status; converged replay
without a registry; active resume with one journal batch and no repeated proven
effect; and lost-journal-acknowledgement no-duplicate-effect recovery. Source loading
and compilation took about nine seconds separately.

This rejects the claim that the original per-event replay and duplicate-resume
defects remain the immediate implementation task. Keep these regressions; do not
rewrite passing replay code merely because the complete command remains slow.

## E6 — an index can move the multiplier into the selected review

Hypothesis: a binding-to-review lookup solves nonempty evidence reconstruction
without weakening the original native checks. `NativeEvidence.hs` prepares real
Kubernetes and Helm operations through `prepareReview`, publishes their immutable
members through `publishReview`, and creates diagnostic lookup sidecars through
recording `ObjectOps`. Reads use a second store instance with a fresh immutable
cache. No operation is admitted and adapter mutation callbacks throw if reached.

Vary unrelated canonical reviews (0/500, plus one malformed unused review) and
unselected sibling operations **inside the chosen review** (0/50) independently.
Select the same one Kubernetes and one Helm binding in every case.

| Lookup implementation | Siblings | Cold GETs | Warm GETs | Private members reconstructed per call |
|---|---:|---:|---:|---:|
| Pointer + existing full review loader | 0 | 6 | 2 | 2 |
| Pointer + existing full review loader | 50 | 56 | 2 | 52 |
| Pointer + diagnostic selected projection | 0 | 6 | 2 | 2 |
| Pointer + diagnostic selected projection | 50 | 6 | 2 | 2 |

These counts include the two lookup GETs. Both unrelated-history sizes give the
same counts. The full-loader calls make zero list requests. Removing one
unselected sibling's private member blocks the full loader. The projection still
reconstructs the exact selected bytes. Empty projection performs zero GETs.

The projection verifies the original review's canonical bytes and digest, reads
the required immutable scope documents, loads only the selected operations'
private members, and invokes the actual Kubernetes/Helm reconstructors on a
temporary view. Both paths rebind changed source metadata and distinguish two
caller-supplied old/current declarations with the same resource ID but different
native bytes. Both refuse a wrong-incarnation pointer, cross-context pointer,
changed selected private bytes, and a missing selected private member.

This **rejects whole-review lookup as the final implementation**. A pointer alone
removes history scanning but retains sibling amplification and unrelated failure
dependencies. Selected private-member reconstruction is a demonstrated direction.
It is not constant total work: the original review plus required scope bytes grow
from **3,084 to 68,639** in this fixture, and both still need decoding. Those bytes
must be measured separately before deciding whether a format change is justified.
The displayed reconstruction counts are native-member counts, not all JSON decodes.

Limits: these are direct, unfenced native objects, not generated contributions;
old/current declarations are supplied to the loader, not admitted through a real
retirement journal. The filtered temporary `ReviewBundle` must never reach
admission or become the production API. EP-156 must factor a distinct opaque
selected-evidence reader, retain full admission validation, and test generated
resources and actual history. EP-153 must prove the public known-target consumer.

## E7 — derived evidence publication creates a recoverable crash boundary

Hypothesis: populating the lookup when a review is published is sufficient by
itself. Deterministically stop the fixture between publishing the original review
and writing its derived lookup. Reading that selected binding refuses with
`selected evidence index missing; explicit rebuild required`. Explicitly completing
the sidecar restores lookup using the same original review and bytes, with no
provider action. The test does not kill a process or simulate lost acknowledgements.

This exposes a missing publication protocol in the earlier plan. New publication
must establish and validate required witnesses before admission can depend on them;
a retry must check the existing conditional-write winner. Old or restored history
needs an explicit resumable rebuild. Neither implicit scans on each command nor
interpreting a missing lookup as an empty native set is acceptable. The prototype
skips an already-existing sidecar in its writer; this is deliberately **not** proof
of race, corrupt-winner, or acknowledgement-loss safety. EP-156 now requires those
fault injections and second-root rebuild proof before rollout, with EP-153 owning
the public actionable failure/rebuild boundary.

The E6/E7 run passed in **8.09 seconds including source compilation**, under the
runner's 90-second limit. [Raw output](mp23-experiment-results-2026-09-29/native.txt),
[production source hashes](mp23-experiment-results-2026-09-29/native-source-hashes.json),
and [probe hashes](mp23-experiment-results-2026-09-29/native-probe-hashes.json) are retained.
No production file was modified, no provider was contacted, and no audit finding
was closed by this spike.

## E8 — publication races and lost acknowledgements

Run `python3 docs/audits/mp23-reproductions/run-operational-cost.py protocol`.
`EvidenceProtocol.hs` wraps actual immutable publication and a candidate checked
lookup writer. It injects failure before, and lost acknowledgement after, each of
six writes: the scope, two native members, review document, and two lookup entries.
All six before-write cases refuse; after-write cases for the four immutable
members refuse initially and retry successfully against the existing bytes. Lost
lookup acknowledgements are resolved by reading and validating the landed witness.
All twelve retry cases reconstruct the exact selected bindings; publication never
advances the head. This does not prove a future admission caller respects that gate.

Two concurrent publishers with different valid immutable review digests for the
same bindings are synchronized at the contested lookup write. Both succeed by
validating the conditional-write winner rather than insisting on their own review
digest. A corrupt existing winner refuses without overwrite; an unknown lookup
read refuses rather than becoming absence. The race is at the sidecar boundary,
not an exhaustive transport or immutable-member race model.

The diagnostic writer now uses strict result checks. An initial harness version
used a lazy `void (ok <$> action)` and could discard a `Left`; that harness was
corrected before retaining these passing results. No result from that initial run
is acceptance evidence. This is another reason to assert the resulting immutable
state, not merely a command exit or counter.

## E9 — bounded rebuild after real export/restore

The same protocol probe exports immutable history using the real `exportStore`,
restores it with `restoreStoreFor` into a fresh **filesystem** root, and verifies
identical heads. The accepted catalogue is synthetic and names the prepared
immutable scopes. Restore-to-local follows the supported CLI contract; directly
restoring to an initialized object prefix is intentionally not the supported route.
The independent derived-index recorder initially has no entries, and selected
lookup refuses.

A persistent checkpoint captures the head, four immutable review digests, and a
cursor. Inject interruption after writing evidence but before committing the
cursor. Reopen the store and resume with a one-review budget: progress is explicitly
incomplete at 1/4, 2/4, and 3/4, then complete at 4/4. Repeating the interrupted
entry is safe and exact selected evidence is available afterward. Advancing the
head invalidates the old checkpoint; an explicit rebuild with a new captured head
succeeds. Original immutable history is preserved.

The prototype uses a plain checkpoint file and recording sidecars; production
still needs an atomic private checkpoint, error classification, the CLI interface,
and integration with real accepted/retained histories. It does not prove recovery
from torn checkpoint writes or a provider outage. E8/E9 passed in **8.79 seconds**
including compilation. [Raw results](mp23-experiment-results-2026-09-29/protocol.txt)
and [source hashes](mp23-experiment-results-2026-09-29/protocol-source-hashes.json)
are retained, along with [probe hashes](mp23-experiment-results-2026-09-29/protocol-probe-hashes.json).

## E10 — the real partial-prune command reveals two more executor defects

Run the following from the development shell; the CLI probe requires an up-to-date
built executable and checks that before invoking it:

```bash
(cd cli/nagarectl && cabal build exe:nagarectl)
python3 docs/audits/mp23-reproductions/PruneBoundary.py
python3 docs/audits/mp23-reproductions/run-operational-cost.py prune-executor prune-executor-cf prune-executor-fixed
```

`PruneFixture.hs` prepares/publishes real source and two-operation prune reviews,
then synthesizes historical admission and ambiguity with production head/journal
writers. It does not bypass the production admission guard to create a new prune.
The catalogue is abbreviated synthetic accepted history, not a real previously
executed ingestion. `PruneBoundary.py` runs the **unmodified built CLI**, supplies a
minimal valid workspace and private kubeconfig, and replaces every provider
executable with a recorder that refuses writes. It models an absent prune Job,
a terminal failed prune Job after object deletion with receipt retained, and a
changed ingestion UID. No actual backup object is deleted or receipt parsed in
this experiment; storage versions remain pinned in the saved native review.

Observed public behavior:

- Before effect, an absent Job permits adapter-proved retry: eight read calls and
  one refused create attempt, then the same transaction remains ambiguous. No
  provider write actually occurs. This is not a successful create proof.
- After partial effect, ordinary resume refuses the later declared operation's
  `Job is not complete` preflight. It makes two reads, no writes, and no journal
  progress. The earlier ambiguous create is never recovered.
- Explicit `abandon-partial-prune` reaches the actual recovery adapter, accepts the
  exact owned failed Job and ingestion UID, appends one decision, and clears the
  active transaction. The two provider calls are reads. A later resume reports
  inactive-transaction with no provider calls, not convergence.
- With a changed ingestion UID, explicit abandonment refuses; the original
  transaction remains active and no journal decision or provider write occurs.

Each public invocation completed in **0.033–1.263 seconds** in the retained run.
[Public results, heads, recording calls, and binary hash](mp23-experiment-results-2026-09-29/prune-cli.json)
and [public probe hashes](mp23-experiment-results-2026-09-29/prune-cli-probe-hashes.json)
are retained. An earlier before-effect fixture used the wrong absence digest;
that was corrected to the production resource-specific digest before these results.
The explicit route works at this boundary, but receipt-only cleanup, retained
source history, and independent F09 closure remain unproved.

A controlled executor comparison uses the **same two-operation review** with the
real Kubernetes adapter and a terminal-failed Job response:

| Source variant | Recovery calls | Effects | Result |
|---|---:|---:|---|
| Current production | 0 | 0 | Later operation preflight refuses |
| Temporary removal of resume's whole-review live preflight | 1 | 0 | Non-exhaustive pattern exception |
| Same temporary change plus explicit terminal-failure branch | 1 | 0 | `StoppedAmbiguous`, original transaction preserved |

The first counterfactual proves that `Execute.recoverOrStop` lacks a
`RecoveryTerminalFailure` case. The second demonstrates a bounded explicit stop;
it is **not** permission to remove structural/admission validation or a production
patch. The production fix must retain whole-review structural checks, move live
preconditions to dependency-ready execution, and handle every recovery outcome.
Retain per-operation preflight immediately before a proved-safe effect.

[Baseline](mp23-experiment-results-2026-09-29/prune-executor.txt),
[ordering counterfactual](mp23-experiment-results-2026-09-29/prune-executor-cf.txt),
[terminal-handling counterfactual](mp23-experiment-results-2026-09-29/prune-executor-fixed.txt),
[source hashes](mp23-experiment-results-2026-09-29/executor-source-hashes.json),
and [counterfactual probe hashes](mp23-experiment-results-2026-09-29/fixed-probe-hashes.json)
are retained. The runner applies its two exact substitutions only to temporary
source copies. Production source is unchanged. Probe durations including compilation
were 10.74, 7.50, and 9.83 seconds respectively.

This narrows and corrects E3's earlier conclusion: its single-operation result was
valid, but it did not establish multi-operation executor ordering. F12/F13 now
track the newly reproduced ordering and missing-terminal-case defects under
EP-153/159. No audit finding or child is marked complete.

## Consequence for implementation

The evidence supports a narrower root cause than “the whole architecture is wrong”:
command orchestration crosses boundaries that the primitive tests do not cover.
Those boundaries introduce extra I/O, irrelevant prerequisites, and checks in the
wrong lifecycle phase. Completed foundation status and a primitive test pass cannot
establish the corresponding command's operational contract.

MP-23 now schedules three existing-owner repairs before another cloud rehearsal:
phase-correct recovery (EP-153/159), demand-driven target/native resolution
(EP-153/156), and an append protocol retaining its observed provider generation
(EP-156). Each needs command-boundary positive and negative proof. E6/E7 additionally rule out whole-review lookup and require selected-member
reconstruction plus publication/rebuild recovery. Native-evidence indexing and
production append changes still need implementation and adversarial validation; the experiments do not claim those designs are delivered.

The historical Pulumi snapshot and builder-KVM failures remain useful examples,
but were not re-experimented here. No new acceptance claim or implementation change
for either is based on this pass. No child is marked complete.
