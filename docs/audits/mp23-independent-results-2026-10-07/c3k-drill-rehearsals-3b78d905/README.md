# Section 3 and section 4 drills on `mp23-c3k`, candidate `3b78d905` (2026-10-08 to 2026-10-09)

nagare-verify first ran the checklist's node-upgrade and database-upgrade drills here, on the
cloud context where C3 ran for `3b78d905`
([`../c3-acceptance-3b78d905/`](../c3-acceptance-3b78d905/README.md)). These are the first
versions of the drivers later used on `3b59bcb7` and `83124396`.

- `section4/` is the PostgreSQL 17 → 18 side-by-side drill (`s4-drill.sh`, `s4-run.sh`,
  `timeline.txt`). It ran to retirement with 12:12 rows.
- `section3/` holds the node-upgrade drill records up to the stops that found F90, F91, F92 and
  F93 (see [the register](../../mp23-findings.md)); `attempt1/` is the first drill A attempt.

These runs found defects, so they count for no box. The boxes are ticked from the reruns on the
final candidates: [`../section3-83124396/`](../section3-83124396/README.md) and
[`../section4-3b59bcb7/`](../section4-3b59bcb7/README.md).
