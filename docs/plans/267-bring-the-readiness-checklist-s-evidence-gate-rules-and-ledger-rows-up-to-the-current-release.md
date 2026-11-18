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

- [x] (2026-11-18) Ledger rows in `docs/audits/mp23-findings.md`:
  - F135 is Verifying, with fix `d125e9b9` (v0.16.0) and its next check, a Chrome sign-in through
    the built-in form.
  - F48 is Closed as obsolete: its runner and assembler were removed in `7863cd95`, and the
    intranet's `platform version` row checks the running payload.
  - F127 is Closed: the 0.21.0 transition converged through the agenix symlink
    (`mori://tan/tan-ng-labs` `56decf3`).
  - F145 records EP-265's two missing escrows.
  - F113, F114, F123, F126, F128 and F130 stay Verifying, because no intranet run since has met
    their next check. F126's tenant change edited `intranet.env` directly, not through
    `context apply`.
- [x] (2026-11-18) Section 2 links EP-265's intranet record on the objective, escrow and one-hour
  boxes, and the `ep245` and `ep246` VM-loss drills on the drill box.
- [x] (2026-11-18) Section 3's backup box states D2's outcome: the operator runbook's step 2
  already requires healthy, verified recovery points before the host stage. Section 4 links EP-266's
  shared-server drill (`docs/audits/ep266-pg-major-upgrade-drill-2026-11-18.txt`) and names F156
  and D5 for Nagare's own databases.
- [x] (2026-11-18) Section 5 and the rules section name today's gate, as nagare-fix landed it
  (`b38e3a79`, `f28d7eb2`):
  - `just gate-commit` per Haskell commit;
  - `just gate-fast`, then `just land` with the post-land full gate, where a red record blocks the
    next land (`f28d7eb2`'s record is green);
  - the mutation sweep only in `just gate-release`.

  The deep-tier box is `[-]`, superseded by the operator's decision of 2026-10-12.
- [x] (2026-11-18) The checklist's rules section links the intranet's v0.21.0 upgrade
  (`mori://tan/tan-ng-labs` `56decf3`) and the operator's last recorded sign-in (v0.19.2).


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


## Outcomes & Retrospective

Every box in the checklist now either links evidence on the intranet's v0.21.0 or a current gate
record, or names the candidate it rests on, or is marked superseded by an operator decision. The
ledger rows that bear on the goal are current: F48 and F127 are Closed, F135 is Verifying, and F145
and F156 are recorded. What remains is outside this plan: decision D5 for Nagare's own databases,
and the Verifying rows that close when the intranet next meets their checks. Nothing moves to an
ADR.


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
