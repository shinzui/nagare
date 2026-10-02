# Manual receipt public-command fixture

2026-10-01. This source-level fixture uses the real `nagarectl` executable,
a disposable filesystem inventory with accepted foundation, database, manual
backup, and independent neighbor scopes, and recording `kubectl`/`curl`
transports. It contacts no cluster or object store.

Run both transport modes from the repository root, serially:

```bash
python3 scripts/test-manual-receipt-public.py
python3 scripts/test-manual-receipt-public.py --gcs
```

The first mode uses recording MinIO `curl` reads. The second selects a cloud
profile with a local fixture history, records the Kubernetes cluster guard,
and replaces `gcloud` with a strict shim. That shim requires `objects describe`
to return the accepted bucket, object name, decimal generation and length,
then permits `storage cp --do-not-decompress` only for that exact generation.
Both modes keep all effects inside the disposable fixture.

The fixture executes the following public sequence with the same accepted
history. It checks every command's exit status and records provider calls and
the final head in a temporary `result.json` printed at completion.

1. A foreign physical Job UID refuses `db backup-receipt` before an object
   read, without saving a review or changing the head.
2. The exact completed Job and Pod receipt, stored receipt, and archive produce
   a receipt review. Applying it converges without provider mutation and keeps
   the database and neighbor revisions fixed.
3. `inventory collect` selects only that retained Job. Applying its separate
   review issues one UID-conditional Job deletion and records one tombstone
   with the original physical UID. The database and neighbor revisions remain
   fixed.
4. A changed archive provider version refuses `db restore` before a review is
   saved and leaves the head unchanged.
5. With the original provider versions, `db restore` saves and applies a new
   scratch Job review. Neither command reads the collected backup Job or Pod.
   The only create effect is the scratch restore Job, and accepted/converged
   history is idle with the source and neighbor revisions unchanged.

The recording transport marks the restore Job complete; it does not run a
database or verify recovered rows. This proof covers public routing, accepted
history, retirement/collection, stored-byte and version checks, registry
construction, and restore transaction selection. Native restored-content,
GCS exact-generation, and installed candidate evidence remain open.

The 2026-10-01 final runs passed all eight public commands in each mode and
checked exactly two provider mutations per run: UID-conditional deletion of
the old backup Job and creation of the new scratch restore Job. Individual
commands took 0.08–0.83 seconds in local mode and 0.24–2.19 seconds in
recording GCS mode. Both final heads had no active transaction and identical
accepted/converged vectors. Each result file records the executable SHA-256,
every provider call, and the final head for repeatable inspection.

The complete `nagarectl-test` suite subsequently passed all 1,017 tests in
48.34 seconds. A read-only preflight against the frozen installed operator,
accepted payload and recorded idle generation 705 failed before comparing the
shared head: the selected `labs` GCloud configuration for `tan-ng-labs` could
not refresh its token in non-interactive mode. The exact `gcloud config
config-helper --format=json --min-expiry=120s --quiet` command returned
`Reauthentication failed. cannot prompt during non-interactive execution`.
The active configuration/project labels still matched. This is a credential
preflight failure, not evidence of a changed head. No new review, build,
installation or cloud effect followed it. After interactive reauthentication,
rerun the runbook's exact read-only preflight with its recorded generation and
digest before preparing a candidate; never replace them with a newly observed
head value just to make the check pass.

## Pending native boundary

The next installed check must reuse the existing `f15-preview` context,
payload, VM, source databases and primary completed backup. It must not submit
a fourth backup Job. The retained cleanup proof already retired and collected
the earlier scratch restore Job. At its generation 705 checkpoint the primary
backup Job UID was `1d3dfffd-7285-45ad-aaa8-44648af18990`; PostgreSQL A's
source row was `mp23-f15-source-after-backup`, the neighbor row was
`mp23-f15-neighbor-preserved`, and the original scratch row was
`mp23-f15-source-before-backup`. These are expected inputs to verify again,
not permission to assume the shared head is unchanged.

After login, first rerun the [runbook preflight](../runbooks/inventory-operations.md)
with the frozen operator's exact generation 705 and digest. If it passes,
inspect the current accepted backup Job, its UID, the database/PVC identities,
and accepted dependents without effects. Only then prepare one new installed
candidate containing the source and fixture commits. Its local package gate
must prove the executable revision and unchanged accepted payload before any
cloud review.

The first new review should select the exact manual backup ID
`mp23-f15-pg-a-v1` for `db backup-receipt mp23-f15-pg-a -n personal`.
Require zero provider mutation operations, one retention of the exact Job UID,
and no changed database/application/neighbor revision. Apply that saved review
once; inspect the new idle head. Next select only the now-retained Job for a
separate `inventory collect` review, require its UID-conditional deletion and
one matching tombstone, and apply only after checking its accepted consumers
again. Finally save an isolated `db restore` review with a new restore ID, such
as `mp23f15pgav2`; require exact stored generations and no dependency on the
deleted Job. Apply and query the new scratch database for the original backed-up
row while confirming the source and neighbor still hold their later values and
original physical identities. The existing scratch database and backup objects
stay intact.

Each stage stops on a changed head, UID, provider version, unexpected resource
selection, extra native effect, or unresolved transaction. Existing reviews
and journal state remain authoritative after an interruption; diagnose and
resume the same transaction when its evidence permits. Use the parent plan's
15-minute maximum diagnostic checkpoint for an unmeasured stage, and do not
repeat accepted backup, takeover, or broad bootstrap work to fill this proof.
