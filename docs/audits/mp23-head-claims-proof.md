# MP-23 claim observations and selected publication proof

This checkpoint follows [the active-startup proof](mp23-active-startup-proof.md).
It repairs duplicate head reads at conditional claim writes and removes the
remaining publication-key listing from saved-review execution. It does not change
provider operations, transaction identities, review bytes, or the head schema.

## Reproduced failure

Before the repair, a public `inventory resume` test rewrote identical head bytes
under a new provider generation immediately after journal loading. The command
rediscovered that new generation inside `replaceHeadIfGenerationMatches` and
continued into six Kubernetes guard/observation calls. The expected stale-claim
refusal failed. [The retained baseline](mp23-head-claims-results-2026-09-29/acquire-race-before.txt)
uses the `9e901a44` binary and the original synthetic saved prune transaction.
There was no network or real provider effect.

Logical equality is insufficient for this conditional-write boundary. The claim
must be acquired against the provider generation of the authority check that
preceded journal validation; an intervening replacement must invalidate it.

## Repair

Admission, resume/recovery claim acquisition, normal/aborted claim release, and
collection finalization retain an opaque `ObservedHead` through their existing
checks and use `replaceObservedHead` for the conditional write. Remote writes use
the originally captured provider generation; local writes still recheck under the
backend guard. This removes redundant discovery without caching a mutable head
across commands or removing the fresh reads at existing safety boundaries.
Explicit recovery also loads the committed journal prefix from its first head
observation instead of reading the head again for that same prefix.

`readReviewSnapshot` reads the fresh head and the exact named immutable publication,
checks its content digest, and records only that verified publication in the
snapshot. Remote publication checks bypass the local immutable cache: valid cached
bytes cannot manufacture publication authority in a different or damaged store.
This intentionally costs one bounded remote GET instead of an archive-wide list. Apply, inline convergence, resume and explicit recovery use it. Their
complete original bundle still passes the existing context, desired/base,
private-member, capability and lifecycle checks. Missing, corrupt or unreadable
selected publications refuse. An unrelated malformed publication name or body is
not execution input. Planning/export/integrity paths retain their broader inventory
APIs; legacy missing-native reconstruction still retains its archive fallback.

## Measured result

[The complete public-command trace](mp23-head-claims-results-2026-09-29/active.json)
passes 12 cold/warm cases. Total subprocesses are **53 cold / 32 warm**, down from
57/36. Six calls remain Kubernetes guards/observations. Store transport is **47/26**,
down from 51/30. Head/claim calls fall from **23 to 17**: five fresh GETs and two
conditional PUTs. The two removed discovery GETs save six subprocesses. Removing
the archive listing saves one; uncached publication verification costs three.
That deliberate two-call tradeoff preserves publication authority while eliminating
archive-size coupling. No archive list occurs in this tested active path.

| Component | Cold calls | Warm calls |
| --- | ---: | ---: |
| Initialization | 5 | 5 |
| Immutable inputs and uncached selected publication | 24 | 3 |
| Head/claim | 17 | 17 |
| Journal batch | 1 | 1 |
| Provider guards/observations | 6 | 6 |

[All 954 tests pass](mp23-head-claims-results-2026-09-29/full-tests.txt) in 60.51
seconds. The full suite and local cost matrix ran concurrently; their elapsed
times are not a controlled before/after latency benchmark. [Both public race cases](mp23-head-claims-results-2026-09-29/acquire-race-after.json)
refuse before provider observation and preserve the original logical head.
[All 11 legacy saved-transaction cases](mp23-head-claims-results-2026-09-29/legacy-cli.json)
pass without extracted native copies; [all 12 no-op cases](mp23-head-claims-results-2026-09-29/noop.json)
remain at 12 calls. [Style, command audit, entrypoint guards and strict documentation
validation](mp23-head-claims-results-2026-09-29/checks.json) pass.
[Source hashes](mp23-head-claims-results-2026-09-29/source-hashes.json) match the tested tree;
all successful public reports bind the same binary.

## Read-only GCS diagnostic and next priority

[A bounded diagnostic](mp23-head-claims-results-2026-09-29/gcs-readonly-diagnostic.json)
used the stored disposable `ep150-preview` binding, explicit project `tan-ng-labs`,
and exact `gs://tan-ng-labs-ep150-pmkjjpp-state/inventory/head.json`. Each command
had a 20-second timeout. `gcloud --version` took **1.142 seconds**; describing that
1773-byte object's generation/size took **1.368 seconds**. Neither command changed
cloud or transaction state or switched a global context.

These are single samples collected while local tests were running, not a latency
gate. They suggest process/client startup is substantial. The next performance
experiment should compare the production three-subprocess GET with a bounded
transport-reuse prototype against this same read-only object. Preserve provider
generation checks, unknown/absent distinction, exact project/prefix confinement,
conditional writes and ambiguous-ack recovery before selecting an implementation.
Do not remove required authority reads just to lower the subprocess count. Use
Mori to inspect dependency/API sources before implementing a transport change.

## Acceptance boundary

The unit regressions exercise an unresolved transaction with three execution-layer
head observations and two conditional claim writes; provider-generation changes
before acquisition and release; stale admission; lost claim acknowledgements
resolved through read-back; direct publication lookup with invalid unrelated keys;
and missing/corrupt/unreadable selected publications despite valid cached bytes. The pre-existing takeover,
intent/effect, journal hash-chain, lost-ack, data-fence, retention, and collection
tests remain acceptance requirements.

The real CLI matrix independently varies 50/500 events and 0/50/500 unrelated
reviews, now including a malformed unrelated publication key. Each command must
observe the original Job, preserve the unresolved transaction/sequence, read one
journal batch, and perform no provider mutation or archive listing. A separate
race mode must refuse before any provider observation and preserve the original
logical head. Both cold and warm processes are tested.

## Reproduction

Build and test sequentially from `cli/nagarectl`:

```bash
cabal build exe:nagarectl test:nagarectl-test --enable-tests
cabal test nagarectl-test --enable-tests --test-show-details=direct
cabal build exe:nagarectl test:nagarectl-test --enable-tests
```

The final build restores the joint executable/test configuration after Cabal's
test command. From the repository root, use the retained/generated prune fixture
as described in [the preceding proof](mp23-active-startup-proof.md):

```bash
python3 scripts/test-inventory-active-command-cost.py FIXTURE_DIRECTORY
MP23_CLAIM_RACE=acquire python3 scripts/test-inventory-active-command-cost.py FIXTURE_DIRECTORY
MP23_LEGACY_OBSERVATION=1 python3 scripts/test-inventory-operation-driver.py FIXTURE_DIRECTORY
python3 scripts/test-inventory-command-cost.py
```

Each recorded command is bounded to 25 seconds and 180 subprocesses. The tests
use local provider recorders; their elapsed times do not establish live GCS
latency. F04/F06 remain Partial. Remaining work includes legacy archive isolation,
further command-wide head/journal reuse where safe, and the existing host/native
prerequisites before the real GCS gate. No cloud mutation or native rehearsal was run; the single metadata lookup above
does not satisfy the real cold/warm GCS gate.
