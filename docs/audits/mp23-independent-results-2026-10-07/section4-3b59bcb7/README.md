# Checklist section 4 on the final candidate `3b59bcb7`

nagare-verify ran this on 2026-10-09 on `mp23-c3l` (project `tan-ng-labs`), the C3 context, through
the documented procedure
[Upgrade PostgreSQL to a new major version](../../../user/managed-databases.md#upgrade-postgresql-to-a-new-major-version).
The driver is `s4-drill.sh`, run by `s4-run.sh`. `logs/run.log` lists the phases, and
`logs/phase-*.log` hold each phase's timeline.

The application `upg-app` owns `upg-pg` (PostgreSQL 17.11). It writes a row on every `/add` request,
so the row count shows whether a write landed. Each `config-*.hs` is the application config that a
step reviews.

| Phase | Result |
|---|---|
| setup | `upg-app` deployed on PostgreSQL 17; 5 rows seeded |
| backup | A fresh reviewed backup of the old instance (`s4pre`), restored into an isolated scratch database: 6:6 rows equal to the source |
| add | `upg-pg18` (PostgreSQL 18.6) added beside the old instance; the binding is unchanged |
| probe-inplace | An in-place major change of the old instance is refused at planning (F86's guard, `probe-inplace.txt`) |
| fail1 | **Failed upgrade 1:** the copy into the new instance fails, as injected. The old instance is unfenced and takes writes again (7 → 8 rows). While it was fenced, a write was refused (HTTP 502). |
| copy | The old instance is fenced, copied with `pg_dump` 18 into `psql --single-transaction`, and both fingerprints match (`copy-fp-*.txt`) |
| fail2 | **Failed upgrade 2:** after the reviewed switch-over, the new instance is rejected, and a reviewed switch back returns the application to the old instance (9 rows). The new instance never accepted a write. |
| recopy | The new instance is reset and the copy is repeated; the fingerprints match |
| switch | Reviewed switch-over to PostgreSQL 18 (9 → 10 rows). The old instance is kept, read-only. |
| prove | A reviewed backup of the new instance (`s4post`), restored in isolation: 11:11 rows equal to the source |
| retire | Only now: the pre-upgrade consumer scopes are retired, then `app deploy --retire-database upg-pg` (F87's fix, `review-v6-new-only.txt`) retains the old instance. Its volume and StatefulSet are kept, and the application holds 12:12 rows. |

Every review the drill applied is saved as `review-*.txt`. Both failure drills return to the old
instance with every acknowledged row present.
