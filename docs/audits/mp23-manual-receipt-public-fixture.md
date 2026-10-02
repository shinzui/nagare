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
