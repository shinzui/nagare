---
id: 36
slug: finish-and-keep-current-the-production-readiness-checklist
title: "Finish and keep current the production readiness checklist"
kind: master-plan
created_at: 2026-11-18T02:09:42Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-18T02:09:42Z
---

# Finish and keep current the production readiness checklist

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The goal is fixed by the [production readiness checklist](../releases/production-readiness-checklist.md):
developers deploy and log in to the intranet, and the operator changes and upgrades Nagare without
losing data. A release counts when the intranet runs on it.

Every box on the checklist is ticked, but most ticks rest on candidate `83124396` (v0.5.0 era,
2026-10-07 to 10-10) and on disposable contexts `mp23-c3j`, `mp23-c3l` and `mp23-c3m`. The real
intranet has had sixteen releases since and now runs v0.21.0 (2026-11-14). This MasterPlan records
each box's current state, and plans the smallest work that makes the boxes true for the intranet on
the release it runs.

In scope: the checklist's boxes, and the open deferrals in [the findings ledger](../audits/mp23-findings.md)
that bear on them. Out of scope: anything that adds a box. That covers MasterPlan 19's alert
delivery, MasterPlan 24's volume work (EP-183; volumes are outside the objective by decision D2),
MasterPlan 30's intranet timing sample, MasterPlan 18's cache proof, MasterPlan 31 (complete), and
the held MasterPlan 25 and MasterPlan 26's EP-173 M3–M4. The per-release evidence chain stays
retired: a release proves a green full gate, the EP-172 upgrade rehearsal and the intranet's
deploy-and-login, and nothing here re-runs C2–C5.

### Box-by-box state (2026-11-17; updated 2026-11-18 where marked)

"Done" means the linked evidence still proves the box on today's code. "Partly done" means it holds
on a drill context, but no evidence shows it on the intranet. "Stale" means the box's wording no
longer matches an operator decision.

| Box | State | Evidence and gap |
|---|---|---|
| 1. Close by per-operation proof (ADR 26, EP-175) | Done | Pinned by tests in every full gate; ADR 26 amended for F139 (2026-11-03). |
| 1. Physical identity at creation (ADR 27, EP-176) | Done | Pinned by tests. |
| 1. Kubernetes proof rules (RES-4, EP-180) | Done | `c3755ad7`, `aaa96eaf`. |
| 1. Recovery model on a derived world (EP-182) | Done | `356e7f18`. |
| 1. Stuck StatefulSet rollouts have an exit (EP-181) | Done | `341b01bc`; F78 is the known limit. |
| 1. Step-3d fix batch | Done | `8824f469`. |
| 1. Step 5: independent verification, candidate, C2, C3–C5 | Done, one-time | v0.5.0's proofs, retired for later releases by the three-proof rule. Each release since binds a `transition-rehearsal.json`, the latest under `docs/release-evidence/af1141b4f6a949f3afd5da788f9c354a4013c9ab/`. |
| 1. Known limits F77, F78 | Deferred | Runbooks exist; operator-error cases outside review. |
| 2. `hourly` objective | Done (2026-11-18, EP-265) | Shown on `mp23-c3j`; `hourly` is the default (`docs/user/contexts.md`). No intranet `server status` on v0.21.0 is linked. EP-265. |
| 2. Every signing key escrowed | Done (2026-11-18, EP-265) | Shown on `mp23-c3j`. The intranet had no escrow until 2026-11-03 (F145). By 2026-11-04 it had escrowed `en-db`, `shomei-db` and Shomei's key-encryption key (F146), `labs-postgres`, `labs-clickhouse`, `kansoku-pg` and `kansoku-ch`. v0.21.0 added En tenant databases `en-<name>-db` (EP-262), with no record that they are escrowed. Nothing checks for a missing escrow (F145). EP-265. |
| 2. Every store off-cluster within one hour | Done (2026-11-18, EP-265) | Shown on `mp23-c3j`; for app databases, F132 graded `kansoku-pg` and `kansoku-ch` healthy on 0.7.1. Nothing shows the intranet's schedules on the pinned `cloud-sdk` digest after F143. EP-265. |
| 2. Deterioration visible, breach unhealthy | Done | Pinned by tests in every full gate; app-database schedules graded since 0.7.1 (F132). |
| 2. Retrievable with cluster and operator root gone | Done | `mp23-c3j`; repeated with escrow and bucket only on `ep245` and `ep246`. On the intranet it depends on the escrow row above. |
| 2. Corrupt and incomplete uploads refused | Done | Pinned by tests in every full gate. |
| 2. Drill: destroy, restore, verify, time | Done | `mp23-c3j` (data only). VM-loss rebuilds with live service followed: [`ep245`](../audits/ep245-vm-loss-drill-2026-11-04.txt) (v0.16.2, platform databases, 85 min, no hand fixes) and [`ep246`](../audits/ep246-app-database-vm-loss-drill-2026-11-04.txt) (app databases, 89 min). F149 stays deferred, and the runbook names its workaround (`docs/runbooks/disaster-recovery.md`, "take a manual snapshot"). The checklist links neither drill. EP-267. |
| 3. Fresh, proven backup before a node upgrade | Done (2026-11-18, D2: the operator runbook's step 2) | Shown on `mp23-c3m` and `mp23-c3l`. `docs/runbooks/releases.md` has no backup step. Whether the intranet's own runbook in `mori://tan/tan-ng-labs` has one is not linked. EP-265, decision D2. |
| 3. Drill: node upgrade under load | Done | `83124396` on `mp23-c3m`. The F95 regression runs in every full gate (`host-switch-identity` in `nix/checks/platform.nix` runs `test-host-switch-session-loss.sh`). |
| 3. Drill: failed node upgrade reverts | Done | `83124396` and `3b59bcb7`. F91 (status refuses after a closed failed host upgrade until the lock is restored) stays deferred. |
| 4. Fresh, verified backup before a database upgrade | Done for app-bound standalone databases | `s4pre` on `mp23-c3l`. |
| 4. Drill: PostgreSQL major upgrade side by side | Done for app databases (2026-11-18, EP-266); Nagare's own databases held in [EP-268](../plans/268-move-nagare-s-own-postgresql-databases-to-a-new-major-version.md) (D5) | Shown for an app-bound standalone database, by the procedure in `docs/user/managed-databases.md` ("Upgrade PostgreSQL to a new major version"). That procedure moves the binding with an application deploy. It does not cover the intranet's other PostgreSQL stores: `en-db` and `shomei-db` (bound by the platform), `en-<name>-db`, and shared servers carrying app databases (ADR 30, ADR 37). EP-266, decision D3. |
| 4. Drill: failed database upgrade returns to the old instance | Done for app databases (2026-11-18, EP-266); Nagare's own databases held in [EP-268](../plans/268-move-nagare-s-own-postgresql-databases-to-a-new-major-version.md) (D5) | The same scope as the row above. EP-266. |
| 5. Master moves only through `just land` with a full-gate record | Done (2026-11-18, reworded by EP-267) | Since 2026-10-11, `just land` needs a `gate-fast` record and runs the full gate and the selective sweep after landing; a red record blocks the next land (CLAUDE.md). nagare-fix is changing the per-commit gate again now. EP-267. |
| 5. Heavy runs on the remote builder | Done | `just test-remote`, `just mutation-sweep`. |
| 5. Mutation sweep proves every guard observed | Done | It now runs selectively at land time. |
| 5. Deep tier per release as monitoring | Superseded (`[-]`, EP-267) | Operator, 2026-10-12: the deep tier is not part of a release. EP-267. |
| 5. Builder probe first in the full gate | Done | `8824f469`. |
| Goal: deploy and log in; the intranet runs the release | Done for v0.21.0 | Live 2026-11-14; operator sign-in confirmed on v0.19.2. The evidence is in `mori://tan/tan-ng-labs`, and the checklist does not link it. EP-267. |

### Open deferrals that bear on the goal

From [the findings ledger](../audits/mp23-findings.md). No open deferral blocks a box by itself.
The items marked "this plan" are where the intranet's evidence is missing.

| Finding | Bears on | Disposition |
|---|---|---|
| F145 (escrow not enforced) | 2. escrow | This plan: EP-265 escrows and verifies every intranet database, the En tenants included. Whether to enforce escrow is decision D4; until then it stays deferred. |
| F143 (schedule digest moves per database) | 2. within one hour | This plan: EP-265 reads each intranet schedule's image. |
| F132, F131 (app-database grading, suspend) | 2. visible / within one hour | Verifying; EP-265 reads the rows. The prune check waits for runs past policy. |
| F149 (second VM loss before the first backup) | 2. drill | Stays deferred (operator, 2026-11-04); the runbook names the workaround. |
| F135 (login form CSRF) | Goal: log in | The register says Open, but fix `d125e9b9` shipped in v0.16.0. EP-267 moves it to Verifying; the next check is a Chrome sign-in through the built-in form. |
| F48 (evidence names the manifest's payload, not the running one) | Goal: intranet runs it | Its owner, EP-168, is cancelled. EP-267 re-owns it to the deferral ledger. It stays deferred, because the intranet's own version reads are the evidence. |
| F91, F89, F94 | 3. failed upgrade; 1. ledger | Stay deferred or Verifying; each is a safe stop with an exit. |
| F77, F78 | 1. known limits | Stay deferred, with runbooks. |
| F113, F114, F123, F126–F128, F130 | Upgrades of the intranet | Verifying. EP-267 closes each one whose next check an intranet upgrade since has met, citing the operator repository; it schedules nothing new. |
| F152, F153 | Rebuild and bootstrap | Stay deferred; safe stops. |
| F154, F155 (lifecycle worker, cloud) | Not on the checklist | Stay deferred. The intranet runs with the worker off. F155 is confirmed in the next release's rehearsal with the worker on, as its row says. |
| F33, F40, F84, F110, F134, F136–F138 | Teardown and fresh contexts | Stay deferred; MasterPlan 25 is held. |
| F102–F109, F111, F112, F115, F117, F120, F133 | Developer polish | Stay deferred. |


## Decomposition Strategy

The work splits by where the evidence comes from:

- EP-265 reads the running intranet, and escrows any key that is missing.
- EP-266 is the one box whose procedure does not yet exist for the intranet's own database kinds. It
  is rehearsed on the local warm drill context.
- EP-267 is docs only: it links the evidence and rewords the stale boxes.

No plan re-runs a drill whose code is pinned by the full gate. The `ep245` and `ep246` VM-loss
drills already cover section 2's drill on newer code than the checklist cites.

Rejected: one fresh cloud context per box. That re-runs the retired evidence chain, and the intranet
is the context the goal names. Also rejected: folding EP-265 into the next release's intranet step.
The release proves deploy-and-login, and attaching a data audit to it adds a step to every release.
EP-265 runs once; decision D2 settles what recurs.

ADRs read: [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
(native runs only confirm), [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md),
[ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md)
(hourly recovery points and a four-hour rebuild),
[ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) and
[ADR 37](../adr/0037-an-app-may-own-its-database-and-nagare-keeps-apps-apart.md) (app databases on a
shared server, which EP-266 must carry). No cross-repository ADR applies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-265 | Show the intranet's backups, escrow and freshness on the release it runs | docs/plans/265-show-the-intranet-s-backups-escrow-and-freshness-on-the-release-it-runs.md | None | None | Complete (2026-11-18) |
| EP-266 | Upgrade the intranet's platform and shared-server PostgreSQL databases side by side | docs/plans/266-upgrade-the-intranet-s-platform-and-shared-server-postgresql-databases-side-by-side.md | None | nagare-fix's warm drill context | Complete (2026-11-18; M2b voided by D5, moved to EP-268) |
| EP-267 | Bring the readiness checklist's evidence, gate rules and ledger rows up to the current release | docs/plans/267-bring-the-readiness-checklist-s-evidence-gate-rules-and-ledger-rows-up-to-the-current-release.md | None | EP-265, EP-266, nagare-fix's gate change | Complete (2026-11-18) |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

EP-265 and EP-266 are independent and can run in parallel. EP-267 has no hard dependency. Its
ledger and wording edits can land at once. It ticks or relinks section 2–4 rows only as EP-265 and
EP-266 produce evidence, and it rewords section 5 once nagare-fix's per-commit gate has landed, so
the wording names the gate that exists. It completes last.


## Integration Points

- `docs/releases/production-readiness-checklist.md`: EP-267 owns every edit to it. EP-265 and
  EP-266 hand it evidence paths and do not edit it themselves.
- `docs/audits/mp23-findings.md`: EP-267 owns the register-row edits. EP-265 and EP-266 add a new
  finding only by the ledger's rules: a data-loss risk is fixed in place, and anything else is
  deferred with the operator's approval.
- Intranet evidence lives in the operator repository `mori://tan/tan-ng-labs` (ADR 13 keeps operator
  material out of this repository). Plans cite it by that URI and a commit.


## Progress

EP-265 and EP-267 are complete. EP-266 has its desk-check, its shared-server drill (PASS,
2026-11-18) and its guide section. F156 landed as `8e0a2981` (master `b561a622`) and ships after v0.22.0.
All three plans are complete. Every checklist box is Done on current evidence or Superseded. Section
4's platform-database part is held in [EP-268](../plans/268-move-nagare-s-own-postgresql-databases-to-a-new-major-version.md) (D5 (c), 2026-11-18).


## Surprises & Discoveries

- Every checklist box was already ticked. The real gaps were that the evidence was on disposable
  contexts, not the intranet, and that three boxes no longer matched later decisions or code (see
  the box table).
- F135's register row says Open, but its fix `d125e9b9` has shipped since v0.16.0.


## Decision Log

- Decision: This plan takes no action on labs, `ep246d`, its run root or the
  `topagentnetworklabs.com` zone. EP-265's reads of the intranet run from the operator shell only
  after the operator's go-ahead (D1).
  Rationale: the instruction from nagare-3, 2026-11-17.
  Date: 2026-11-17
- Decision: D1, open for the operator: go-ahead for EP-265. It is read-only against the cluster and
  the bucket (`server status`, `doctor`, `db verify-escrowed-backup`,
  `db app-database verify-escrowed-backup`, plus reading each schedule's image). The only writes are
  sops escrow files in `mori://tan/tan-ng-labs`.
  Rationale: the intranet is the context the goal names, and no other source holds its evidence.
  Date: 2026-11-17
- Decision: D2, open for the operator. Box 3's "fresh backup proven restorable before a node upgrade"
  could be met on the intranet by a read-only pre-upgrade check: `server status` healthy, plus
  `verify-escrowed-backup` of each database's newest scheduled backup. The alternative is a reviewed
  backup and scratch restore before each upgrade that has a host stage. Recommended: the read-only
  check. It costs seconds and mutates nothing, and the restore path from such receipts was shown on
  `ep245` and `ep246`.
  Rationale: prefer the smaller step; the box asks for proof, not a new backup.
  Date: 2026-11-17
- Decision: D3, open for the operator. Does box 4 cover the intranet's platform databases, En tenant
  databases and shared servers with app databases? If yes, do EP-266 now, desk-check and local
  rehearsal only, with no cloud step until a real major upgrade. If no, hold EP-266 until the
  operator wants a new PostgreSQL major on the intranet. Recommended: yes, now. These are the stores
  the intranet's data is in.
  Rationale: the operator's words, "not worry about upgrading a database".
  Date: 2026-11-17
- Decision: D4, open for the operator: whether F145's missing escrow should be enforced (a `doctor`
  row for a database with no escrow file in the operator root) or stay deferred once EP-265 has
  escrowed everything. Recommended: stay deferred. A new database is rare, and the guides name the
  step.
  Rationale: never add a check in answer to a past mistake (CLAUDE.md), unless data is at risk.
  Date: 2026-11-17


- Decision: The operator approved D1–D4 as recommended ("go ahead", 2026-11-17). D1: EP-265 runs.
  D2: the read-only pre-upgrade check. D3: EP-266 now, local only. D4: escrow enforcement stays
  deferred.
  Rationale: the operator's answer to the plan's summary.
  Date: 2026-11-17
- Decision: Reopen D4 for the operator. EP-265 found two databases with no escrow, `en-mori-db`
  and `mori-registry-pg`, both created within two weeks of the last escrow pass. That contradicts
  D4's premise that a new database is rare. Both are escrowed now; enforcement stays deferred until
  the operator answers.
  Rationale: an unescrowed key leaves backups unverifiable after a cluster loss (F145, P1).
  Date: 2026-11-18
- Decision: Reword section 5 only after nagare-fix's process change lands in full. That change
  moves the mutation sweep from `just land` to `just gate-release` and rewrites CLAUDE.md's
  "Plans, evidence and gates", not only the per-commit gate.
  Rationale: nagare-fix, 2026-11-18.
  Date: 2026-11-18

- Decision: D5, decided (c) by the operator on 2026-11-18, and the work moved to the held
  [EP-268](../plans/268-move-nagare-s-own-postgresql-databases-to-a-new-major-version.md). The question was how a platform database (`en-db`, `shomei-db`,
  `en-<name>-db`) moves to a new PostgreSQL major. EP-266's desk-check found that app databases on
  a shared server need no code, but the platform databases have fixed names and hosts.
  - (a) A reviewed second instance beside the old one, with En and Shomei rebound. This is true
    side by side. It touches the auth components, the bootstrap manifests, and the backup,
    restore, escrow and rebuild paths keyed on those names. Largest.
  - (b) The same name, reincarnated through the proven rebuild-and-restore path (`ep245`), with
    writers held absent and the old volume retained. If the new one fails, the same backup is
    restored at the old major. Smaller, but "return to the old instance" becomes a restore.
  - (c) Hold the platform part until a new major is wanted on the intranet. EP-266 M2 (F156)
    keeps every release from forcing one.

  Recommended: (c). These databases hold accounts, passkeys and grants, and nothing forces a move
  off 18 once F156 is fixed. EP-266 M2 and M3 do not depend on D5 and go ahead.
  Rationale: the smallest step that keeps upgrades safe; the box's data-loss guarantee holds under
  all three.
  Date: 2026-11-18

## Outcomes & Retrospective

Every readiness box now rests on evidence from the current release or is superseded. The intranet's
backups, escrow and freshness are shown on the release it runs (EP-265). App databases move to a new
PostgreSQL major side by side, and no release forces a platform database's major (EP-266, F156).
The checklist's evidence, gate rules and ledger rows are current (EP-267). What remains is moving
Nagare's own databases to a new major. That is held in [EP-268](../plans/268-move-nagare-s-own-postgresql-databases-to-a-new-major-version.md) until a new major is wanted. No
ADR.
