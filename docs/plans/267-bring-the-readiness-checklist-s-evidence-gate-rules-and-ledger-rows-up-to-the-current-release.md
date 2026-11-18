---
id: 267
slug: bring-the-readiness-checklist-s-evidence-gate-rules-and-ledger-rows-up-to-the-current-release
title: "Bring the readiness checklist's evidence, gate rules and ledger rows up to the current release"
kind: exec-plan
created_at: 2026-11-18T02:09:52Z
master_plan: "docs/masterplans/36-finish-and-keep-current-the-production-readiness-checklist.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-18T02:09:52Z
---

# Bring the readiness checklist's evidence, gate rules and ledger rows up to the current release

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

After this plan, the production readiness checklist says what is true today, and the findings
ledger's rows that bear on it are current. Every box links evidence on the release the intranet
runs, or says which drill context and candidate it rests on. Docs only.


## Progress

- [ ] Ledger rows, which need no other plan:
  - F135 moves from Open to Verifying, citing fix `d125e9b9` (in v0.16.0) and the next check, a
    Chrome sign-in through the built-in login form.
  - F48's owner, EP-168, is cancelled, so the row moves to the deferral ledger.
  - Each Verifying row among F113, F114, F123, F126–F128 and F130 whose next check an intranet
    upgrade since has met is closed, citing the commit in `mori://tan/tan-ng-labs`. The others stay
    Verifying.

  Pass: the register rows are edited in `docs/audits/mp23-findings.md`.
- [ ] Section 2 links the newer drills `docs/audits/ep245-vm-loss-drill-2026-11-04.txt` and
  `docs/audits/ep246-app-database-vm-loss-drill-2026-11-04.txt`. Once
  `docs/plans/265-show-the-intranet-s-backups-escrow-and-freshness-on-the-release-it-runs.md` is
  complete, the objective, escrow and one-hour boxes link its intranet record.
- [ ] Section 3's backup box states decision D2's outcome, from
  `docs/masterplans/36-finish-and-keep-current-the-production-readiness-checklist.md`. Section 4
  links the drill log of
  `docs/plans/266-upgrade-the-intranet-s-platform-and-shared-server-postgresql-databases-side-by-side.md`,
  or states the hold D3 chose.
- [ ] Section 5 names today's gate: the per-commit gate nagare-fix lands, then `just land` with its
  post-land full gate and selective sweep, where a red record blocks the next land. The deep-tier
  box is marked superseded by the operator's decision of 2026-10-12. Pass: each box links a current
  gate record, or names the operator decision that retired it.
- [ ] The checklist links the intranet's deploy-and-login evidence for the release it runs, by
  `mori://tan/tan-ng-labs` and commit.


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

- `docs/releases/production-readiness-checklist.md`: its rules allow ticking a box only with
  linked evidence. Its scope is fixed, so this plan adds no box.
- `docs/audits/mp23-findings.md`: its update and closure rules are at the top of the file.
- `CLAUDE.md`, "Plans, evidence and gates", states the current gate rules (operator decisions of
  2026-10-10 to 10-12).
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md).


## Plan of Work

Land the ledger rows first. Then edit each section of the checklist as its evidence arrives.
Section 5 waits for nagare-fix's gate change, so that the wording names the gate that exists.


## Concrete Steps

Docs-only commits carry their gated ancestor's record forward. Stage explicit paths:

```bash
git add docs/releases/production-readiness-checklist.md docs/audits/mp23-findings.md
git commit -m "docs(releases): ..."
```


## Validation and Acceptance

Every box in the checklist either links evidence on the intranet's current release or a current
gate record, or names the candidate and context it rests on, or names the operator decision that
retired it.


## Idempotence and Recovery

Text edits only.


## Interfaces and Dependencies

No hard dependency. Soft: EP-265, EP-266 and nagare-fix's per-commit gate.
