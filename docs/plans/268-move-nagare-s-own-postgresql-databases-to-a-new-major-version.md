---
id: 268
slug: move-nagare-s-own-postgresql-databases-to-a-new-major-version
title: "Move Nagare's own PostgreSQL databases to a new major version"
kind: exec-plan
created_at: 2026-11-18T07:00:00Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-18T07:00:00Z
---

# Move Nagare's own PostgreSQL databases to a new major version

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

**Held** (operator, 2026-11-18, MasterPlan 36 decision D5 (c)). Start it when a new PostgreSQL
major is wanted on the intranet, or when PostgreSQL 18 nears its end of life, whichever comes
first. Until then, F156 keeps every platform database at `platformPostgresVersion` (18), so no
release can force a move.


## Purpose / Big Picture

EP-266 proved a side-by-side major upgrade for app databases, standalone and on a shared server.
Nagare's own databases have no such procedure: `en-db`, `shomei-db` and each En tenant's
`en-<name>-db`. They hold accounts, passkeys and grants. After this plan, the operator can move them
to a new major. A fresh, verified backup comes first. A failed attempt ends on the old major with
every acknowledged row. The work is proved on a disposable local context before any cloud step.

Why it needs code ([EP-266](266-upgrade-the-intranet-s-platform-and-shared-server-postgresql-databases-side-by-side.md), "M1 desk-check"):

- The names are fixed as `<service>-db` (`cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs`).
- En and Shōmei reach the databases by fixed hosts and Secrets (`cluster/bootstrap/en/service.yaml`,
  `cluster/bootstrap/shomei/service.yaml`, `cli/nagarectl/src/Nagare/Inventory/Components/AuthTenants.hs`).
- So no second instance can sit beside the first, and no reviewed switch or retirement exists.
- A writer can already be held absent (F144, `cli/nagarectl/src/Nagare/Inventory/RebuildRestore.hs`).
- The rebuild-and-restore path is proved (`ep245`, `docs/audits/ep245-vm-loss-drill-2026-11-04.txt`).
- Every release pins the version (`platformPostgresVersion`, `cli/nagarectl/src/Nagare/Inventory/Database.hs`).


## Progress

- [ ] M0: choose the approach, recorded in the Decision Log:
  - (a) A reviewed second instance beside the old one, with En and Shōmei rebound. This is true side
    by side. It touches the auth components, the bootstrap manifests, and the backup, restore, escrow
    and rebuild paths keyed on those names. Largest.
  - (b) The same name, reincarnated at the new major through the rebuild-and-restore path. Writers
    are held absent and the old volume is retained. If the new one fails, the same backup is
    restored at the old major. Smaller, but "return to the old instance" becomes a restore.
- [ ] M1: a desk-check of the chosen approach against current code, each step with a file:line
  citation. It covers what changes for backup, restore, escrow, rebuild and inventory export.
- [ ] M2: the planner change for the chosen approach. An in-place major change stays refused (F86).
  The change ships with unit tests and a mutation record for each guard, the heavy path for
  data-risk work.
- [ ] M3: a local drill on a disposable context with real En and Shōmei data (an account, a passkey,
  a grant and an En tenant):
  - the backup is restored equal;
  - the move is made, the fingerprints match, and sign-in works on the new major;
  - fail 1, the copy or restore fails: the old major serves every row;
  - fail 2, the new major is rejected after the switch: the old major serves every row.
- [ ] M4: the procedure in `docs/user/managed-databases.md`, and the platform major raised in a
  release whose transition carries it.
- [ ] M5: the intranet moves, under a bounded operator go-ahead, followed by the deploy-and-login
  check.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: held until a new major is wanted (MasterPlan 36, D5 (c)).
  Rationale: these databases hold accounts, passkeys and grants, and F156 keeps every release at
  PostgreSQL 18. The data-loss guarantee of readiness box 4 holds without this plan.
  Date: 2026-11-18


## Outcomes & Retrospective

(To be filled at completion.)
