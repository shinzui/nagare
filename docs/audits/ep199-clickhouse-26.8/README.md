# EP-199 ClickHouse 26.8 first-use drill, 2026-10-17

The native confirmation of [EP-199](../../plans/199-prepare-clickhouse-26-8-for-first-production-use.md)
M2, run by `scripts/clickhouse-drill.sh` on a disposable local context
(`transition`, Colima profile `nagare-mp23`, k3d, arm64) from an empty environment. The
candidate's full gate was green before the run (`just gate-verify 20c71309` printed
`green, systems x86_64-linux aarch64-darwin`). Native runs confirm what the interpreters
proved ([ADR 25](../../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).
This is local engine proof: no GCS object store, cloud context or application deployment
was exercised.

| what | value |
| --- | --- |
| candidate `nagarectl` | 0.6.3 at `20c7130927e3c2c4ae6fc4758870355311740df5`, nix package ([`candidate.json`](candidate.json)) |
| context | fresh local context bootstrapped on v0.6.3 by `scripts/release-rehearse.sh 20c71309… 0.6.3` (root `/private/tmp/nagare-release-rehearse.vMXd44`); its transition step refused with `the context is already pinned to 0.6.3; nothing to move`, so the platform payload is the released 0.6.3 and the database commands ran on the candidate CLI |
| database | `personal/ep199-ch3`, `db create clickhouse ep199-ch3 --size 1Gi --memory 2Gi --recovery-backup ep199-ch3-backup --recovery-key-version v1` with no `--version` |
| server | `clickhouse/clickhouse-server:26.8` → `26.8.29.10`, image `docker.io/clickhouse/clickhouse-server@sha256:6ded2b2c2f2c46f12784bd8000c75f8aa7363372ed64afccaa932456b8cb41e4` (the Docker Hub `26.8` index digest observed at planning) |
| record | [`clickhouse-drill.json`](clickhouse-drill.json); observations in [`observations.tsv`](observations.tsv); the receipt listing in [`backup-receipts.txt`](backup-receipts.txt) |
| M1 dry run | [`db-create-dry-run.txt`](db-create-dry-run.txt), `db create clickhouse ep199-ch --size 1Gi --memory 2Gi --dry-run` from a dev build of `cd921241`'s tree |

The invocation, with the candidate built by
`nix build --no-link --print-out-paths "git+file://$PWD?rev=20c7130927e3c2c4ae6fc4758870355311740df5#nagarectl"`:

```bash
env -i HOME="$HOME" USER="$USER" TMPDIR="${TMPDIR:-/tmp}" PATH="$PATH" \
  DOCKER_HOST=unix://$HOME/.colima/nagare-mp23/docker.sock \
  NAGARE_DRILL_NAGARECTL=/nix/store/di2ib86vfq6sfg8l4rqr196a6akbz1y2-nagarectl-0.6.3/bin/nagarectl \
  NAGARE_DRILL_ROOT=/private/tmp/nagare-release-rehearse.vMXd44/run \
  NAGARE_DRILL_RUN=r3 NAGARE_DRILL_DATABASE=ep199-ch3 \
  bash scripts/clickhouse-drill.sh
```

## Timeline (run r3, observed)

| time (UTC) | step |
| --- | --- |
| 05:49 | reviewed create applied; StatefulSet image `clickhouse-server:26.8`, annotation `26.8`, `limits.memory` 2Gi, Service ports 9000 and 8123 |
| 05:49 | through the Service: native and HTTP `SELECT version()` both `26.8.29.10` with the managed credential; unauthenticated HTTP 401, unauthenticated native code 516; `max_server_memory_usage` 1610612736, `mark_cache_size` 268435456 |
| 05:49 | `default.ep199_probe` (`MergeTree ORDER BY id`) holds `1:before-restart,2:backup-sentinel`; reviewed `db restart` replaced the Pod; same rows and version after it |
| 05:50 | reviewed manual backup `ep199-r3`; row `3:after-backup` inserted into the source; reviewed scratch restore `manual` into `ep199-ch3_restore_manual` holds exactly rows 1 and 2; source holds 1, 2 and 3 |
| 06:00 | scheduled Job `nagare-dbbackup-ep199-ch3-29870280` (UID `947a99b2-d279-48f8-88de-f05940d64597`, owner `CronJob/nagare-dbbackup-ep199-ch3`) succeeded; `db backup-receipts` listed it `verified; ingestion pending`, freshness healthy |
| 06:01 | reviewed receipt ingestion of that UID; reviewed scratch restore `sched` into `ep199-ch3_restore_sched` holds rows 1, 2 and 3, the rows present when the run started; source unchanged |
| 06:01 | the post-restart Pod is unchanged, 0 container restarts, no last termination, 0 OOM events in the namespace, resident memory 770.50 MiB under the 2Gi limit |

## Earlier runs on the same context

Runs r1 (`ep199-ch`) and r2 (`ep199-ch2`) stopped in the drill's own evidence read, after
their manual scratch restores had converged: the scratch name lives in the review's
`scopes/*.json` (fixed in `64c4c0e8`), and a review carries other accepted restore scopes
(fixed in `119c5c2a`). Every observation each recorded before stopping matched r3's.

## Cleanup

Not completed. `db retire ep199-ch3 --save-plan` refused with `dangling-reference`: the
accepted manual backup, both restore scopes and the scheduled-receipt scope still depend
on the database's credential, PVC and StatefulSet. The disposable cluster retains
`ep199-ch`, `ep199-ch2` and `ep199-ch3` (StatefulSets, PVCs, backup CronJobs, backup and
restore Jobs, scratch databases inside each server) and the rehearsal's `rehearsal`
PostgreSQL database. The next `release-rehearse` resets this daemon's k3d cluster.

No secret appears in these files: the managed ClickHouse credential was read into the
drill's process and passed only as process environment inside the database Pod.
