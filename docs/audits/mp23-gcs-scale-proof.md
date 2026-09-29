# Real GCS 500-event replay and worker scheduling proof

Date: 2026-09-29. This checkpoint accepts the complete 500-event no-op replay
budgets and fixes a scheduling defect found by that experiment. It does not
accept active append/provider latency, host recovery, or EP-156 M1/M2.

## Failed measurement and local diagnosis

The [first cloud result](mp23-gcs-scale-results-2026-09-29/before.json) passed cold
replay at 28.212 seconds but failed warm replay at 12.783 seconds against the
unchanged 10-second limit. Both commands converged with three gcloud processes.
The runner stopped the series at that first budget failure and removed all 502
created object generations. The retained inventory head stayed unchanged.

The downloader previously split listed objects into batches of eight and waited
for the slowest response in each batch before starting any later request. The
[local regression](mp23-gcs-scale-results-2026-09-29/worker-before.txt) holds the
first HTTP media response open while the other seven complete. The ninth request
never starts under the old implementation, proving that available capacity sits
idle behind a slow request. This is a scheduling assertion, not a timing guess
based solely on the cloud measurement.

`Nagare.Inventory.Store.Gogol` now uses eight persistent workers taking entries
from an MVar-protected queue. A completed worker immediately takes the next item.
A failed download clears pending work, and the result remains a failure rather
than a successful partial journal. Listing completeness, exact generation/size
checks, the eight-request concurrency limit, authentication, and write semantics
are unchanged. No cache shortcut skips journal validation.

The previously failing scheduling test now passes, alongside a new incomplete
media refusal and the existing pagination/concurrency/identity/conditional-write
tests. [All 977 tests pass](mp23-gcs-scale-results-2026-09-29/tests.txt).

## Repaired cloud result

The [second cloud report](mp23-gcs-scale-results-2026-09-29/after.json) records
three complete cold/warm pairs using the repaired binary. Each round starts from
new local config/state/cache roots with no copied history.

| Round | Cold, limit 60 s | Warm, limit 10 s | Isolated journal fetch | Auth/ownership setup |
| --- | ---: | ---: | ---: | ---: |
| 1 | 8.987 s | 8.594 s | 6.227 s | 2.467 s |
| 2 | 9.139 s | 9.371 s | 4.813 s | 2.448 s |
| 3 | 7.670 s | 8.042 s | 4.751 s | 2.383 s |

All six public `inventory resume` commands converge with three gcloud processes
and no native executor calls. Each command is followed by an exact comparison
of all 502 object generations and sizes. The separate read-only probe uses the
production remote factory and journal downloader; its fetch includes listing and
500 generation-bound media reads, while setup covers credentials and ownership.
It is a separate process, so its durations are not subtracted from CLI totals.

The fixture is synthetic, hash-chained committed history validated through the
local public CLI before cloud upload. Its 500 journal objects contain 150,334
bytes; the head and format bring the total to 150,630 bytes. This proves read
scaling for that history, not 500 native mutations or arbitrary journal sizes.
No compilation or regression-suite workload ran during the repaired cloud series.

Each attempt used a new UUID beneath the disposable state bucket's
`mp23-replay-bench/` prefix. Uploads required generation zero. Two manifest files
validated the upload/recording boundary before the 500-object journal upload.
Cleanup used only the exact version-specific URLs reported by successful creates,
never a recursive prefix or bucket deletion. Both reports confirm complete
cleanup. The standing `inventory/head.json` retained provider generation
`1790656456769847` and size 1773 bytes throughout. No global context changed.

The [retained 61-event transaction](mp23-gcs-scale-results-2026-09-29/retained.json)
was then checked with the same binary: three cold runs at 3.669–4.089 seconds and
three warm runs at 3.688–4.066 seconds, all within the original 30/5-second limits.
Each round used a fresh local root, and the exact retained GCS head was unchanged.
This rerun is justified by the changed reader; it replaces no native recovery gate.

## Reproduction and remaining gates

From `cli/nagarectl`, build the candidate and the small read-only timing probe:

```bash
cabal build exe:nagarectl test:nagarectl-test --enable-tests
cabal test nagarectl-test --enable-tests --test-show-details=direct
cabal exec -- ghc -threaded -package nagarectl \
  -outputdir /tmp/mp23-gcs-timing-build -o /tmp/mp23-gcs-journal-timing \
  ../../docs/audits/mp23-reproductions/GcsJournalTiming.hs
```

From the repository root:

```bash
# Local validation only; no cloud writes.
python3 scripts/test-inventory-gcs-scale.py
# Explicit disposable-prefix cloud setup, measurements and exact cleanup.
python3 scripts/test-inventory-gcs-scale.py --cloud \
  --journal-probe /tmp/mp23-gcs-journal-timing
python3 scripts/test-inventory-sdk-retained-replay.py
```

The reports bind the measured CLI binary hashes and
[source hashes](mp23-gcs-scale-results-2026-09-29/source-hashes.json). Preserve the
before-fix failure as evidence; do not change the budget to make it pass. Active
claim/append/finalization timing, F05/F07 host recovery, independent verification,
and final-candidate package/native-system checks remain open. The preceding
Darwin Nix package build belongs to the earlier auth candidate; it is not a build
of this worker repair.
