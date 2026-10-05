# Recovery-model mutation records (EP-173)

Each diff reverts one finding's guard. Applied in a scratch worktree (never in a
shared checkout), it must make the recovery model fail with a violation that names
that finding's scenario:

```bash
git worktree add "$SCRATCH/mut" HEAD
git -C "$SCRATCH/mut" apply "$PWD/cli/nagarectl/test/mutations/<name>.diff"
(cd "$SCRATCH/mut/cli/nagarectl" && cabal test nagarectl-test --test-options='-p "recovery model"')
git worktree remove --force "$SCRATCH/mut"
```

| Diff | Guard reverted | Expected failure (2026-10-05, at `c9a86b82`) |
|---|---|---|
| `F16-unready-create-stop.diff` | the stop of an unready created Service (`RecoveryAwaitingReadiness`) | I1 under `LandsUnready` on the Service create (5 violations) |
| `F30-refresh-before-state-at-write.diff` | a version-2 write submits the current resourceVersion | I7: under persistent status churn a good update needs an exit (16 violations) |
| `F35-abandon-after-fresh-preflight-refusal.diff` | abandoning a never-intended operation after a fresh preflight refusal | I1 under `ForeignObject` at a planned create (11 violations) |
| `F37-abandon-journalled-no-effect-refusal.diff` | abandoning an operation whose journal shows a no-effect refusal | I1 under a persistent foreign field manager (16 violations) |
| `F38-journal-head-retry-and-orphan-adoption.diff` | a failed head advance is reread and retried, and an uncommitted orphan event of the same transaction is adopted | I1 under `PutRefused` or `PutLandedUnacknowledged` on a head write (4 violations, at `c9a0b170`) |
| `F49-status-ignores-incarnation.diff` | status reports a member whose live UID differs from its recorded incarnation as `replaced-incarnation` | I3 under `Replaced` on the durable volume (7 violations, at `c9a0b170`) |
| `F49-ingestion-ignores-incarnation.diff` | scheduled ingestion refuses a source that is not the recorded incarnation | I3 receipt clause under `Replaced` at an ingestion observation (2 violations, 2026-10-05) |
| `F52-status-compares-migrated-records.diff` | status skips the records of members the active migration moves | rename recovery model: I3 at the first stop, for example under a lost acknowledgement on the first create (run with `-p "rename recovery model"`) |
| `F59-statefulset-create-awaits-readiness.diff` | an unready created StatefulSet recovers as awaiting readiness | I1 under `LandsUnready` on the database StatefulSet create (1 violation) |
| `F59-standalone-statefulset-stop.diff` | the stop admits a standalone scope's StatefulSet create | I1 under `LandsUnready` on the database StatefulSet create (1 violation) |
| `F59-statefulset-pending-companions.diff` | never-started companions of a stopped StatefulSet create are admitted | I1 under `LandsUnready` on the database StatefulSet create (1 violation) |
| `F58-absence-proof-holds-no-data.diff` | only a stateless or never-started member may leave history as absent | "a durable member only verified by a stopped update is never replanned or retired as absent (F55, F58)": the deleted volume is retired as absent |
| `F58-admission-absence-recheck.diff` | admission re-observes absence-proved members | "retirement drops a confirmed-absent stateless member only while it stays absent (F58)": the reappeared member is dropped and the retirement converges |

The two F58 records are caught by focused regressions rather than by the model;
run them with `-p "application update recovery"`.

F50's guard (a transient failed `gcloud` read in the state-bucket ownership check)
is not reachable from the Kubernetes or store worlds; its record waits for
EP-173 M4's cloud-foundation world.
