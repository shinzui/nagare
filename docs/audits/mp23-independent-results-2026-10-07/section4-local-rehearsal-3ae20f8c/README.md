# Section 4 local rehearsal: PostgreSQL 17 to 18, side by side

nagare-verify ran this on 2026-10-08 on cp3, in the C2 context of candidate `3ae20f8c`
(`/private/tmp/nagare-mp23-c2-3ae20f8c.Ocy9vF`), under the cp3 claim. It is the local rehearsal
that ADR 25 requires before the native drill on the next candidate's cloud context. It ticks no
checklist box by itself.

The driver is [`s4-drill.sh`](s4-drill.sh), the console log is [`run-log.txt`](run-log.txt), and the
procedure it exercises is
[Upgrade PostgreSQL to a new major version](../../../user/managed-databases.md#upgrade-postgresql-to-a-new-major-version).

## Side-by-side upgrade (`upg2-app/`)

The application `upg2-app` runs the scenario-a image, which writes a row per `/add`. It owns
`upg2-pg` at `"17"` (PostgreSQL 17.11) and later `upg2-pg18` at `"18"` (18.6). Rows are `count:max id`.

| Step | Result | Evidence |
| --- | --- | --- |
| Fresh backup | Reviewed manual backup `s4pre`, restored into an isolated scratch database: 6:6, the same as the source | `rows-at-backup.txt`, `rows-restored.txt` |
| Add the new instance | `v2-both-old` converged. `upg2-pg18` runs 18.6, and the service stays bound to `upg2-pg` | `review-v2-both-old.txt`, `new-version.txt` |
| Failed upgrade 1 | A conflicting `hits` table was injected into the new instance. With the old one fenced, its write was refused (HTTP 502). The copy failed under `ON_ERROR_STOP` in one transaction and left only the injected table. Unfencing returned the app to the old instance: 7:7 → 8:8 | `fail1-copy.log`, `timeline.txt` |
| Copy and verify | Fenced with `default_transaction_read_only`, dumped with `pg_dump` 18.6, restored in one transaction. The `hits` md5 and `hits_id_seq` are equal in both instances | `copy-fp-old.txt`, `copy-fp-new.txt` |
| Failed upgrade 2 | Reviewed switch to new (`v3`), then reviewed switch back (`v4`) while new was still read-only. Old unfenced, rows 9:9 and the app writes. New never accepted a write | `review-v3-switch-new.txt`, `review-v4-switch-back.txt` |
| Copy again | Same checks, equal fingerprints at 9 | `recopy-fp-*.txt` |
| Switch-over | Reviewed `v5`. New unfenced, and the app writes on 18: 9:9 → 10:10. Old kept read-only | `review-v5-switch-new.txt` |
| Prove the new instance | Reviewed backup `s4post`, isolated restore 11:11, the same as the source | `rows-new-*.txt` |
| Retire the old instance | First `inventory retire` of its two consumer scopes, the pre-upgrade backup and restore (the plan refused `dangling-reference` without that). Then `v6-new-only` with `--retire-database upg2-pg` (F87, built from `d459ba78`'s code) converged. Retained resources went from 17 to 28, which is 2 consumer scopes plus 9 database members. The old StatefulSet and volume stay live; nothing was deleted. The app writes at 12:12 | `review-retire-consumers.txt`, `review-v6-new-only.txt`, `pvcs-after-retire.txt`, `sts-after-retire.txt` |

Write downtime is the time from fencing the old instance to unfencing the new one: 41 s, from
16:49:05 to 16:49:46Z, at this data size. Failed upgrade 1 kept writes refused for 2 s, and failed
upgrade 2 for 50 s.

## In-place major change (`f86-inplace/`, F86)

`upg-app` owned `upg-pg` at `"17"` with 7:7. Changing that database's version to `"18"` planned
without refusal (`probe-inplace.txt`). Applied, PostgreSQL 18 refused to start on the 17 data
directory, with the data intact. The F78 exit then failed at `db restart` for an application-owned
database (`review-restart-old.txt`, `inplace-*.log`, `revert-close.log`). nagare-fix fixed three
defects in `4d6abd28`: the planning guard, the restart's supplied natives, and the review loader
that could never apply a `ReplaceStuckPod`. Their native proof on this stuck state is in
`f86-fix-proof/`. nagare-verify re-checked it read-only: `upg-pg-0` is a new pod on postgres:17, Ready,
0 restarts, at 7:7.

## Open before the checklist boxes

The section 4 boxes need this drill natively on the next candidate's cloud context, with the
candidate's own build. The local retire step used nagare-fix's build of `d459ba78`'s code.
