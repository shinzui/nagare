# Proposal: stop finding MP-23's defects one at a time

Status: **approved by the operator, 2026-10-05**: "approve all six, go with release line b". Written by nagare-84. Recorded as [ADR 26](../../adr/0026-stopped-transactions-close-by-per-operation-proof.md) (D1, D5), [ADR 27](../../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md) (D2), the [ADR 25 amendment](../../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) (D3, D6) and MP-23's finish line (D4). Basis: the exhaustive review in this
directory, files A–F, read at master `09241d35`. Every number below comes from those files; they were
derived from source reading, not test runs, unless marked observed.

## 1. Why the reviews have not converged

MP-23 has had seven review rounds:
1. the initial audit;
2. the 09-29 design reassessment;
3. the 10-02 independent verification;
4. the 10-04 reviewer phases;
5. the 10-04 retrospective;
6. the 10-05 recovery model;
7. the 10-05 independent verification.

They produced 65 finding IDs (F64 and F65 exist so far only in nagare's uncommitted checkpoint), of which 37 are closed now that F51 is reopened. Discovery has held at about ten findings a day
since 09-29, and only its source changed: native runs at first, then the model and review (F). Each
round found the next instance of a class that the previous fix had handled for one instance. The
09-29 design reassessment had already named the cause, "recovery is a total operation-state
transition", but the fixes that followed stayed instance-level.

This review enumerated the whole space instead of sampling it.

| Dimension | Result | File |
|---|---|---|
| Recovery: executor/kind × action × provider outcome | 748 reachable cells: 446 have a supported exit, **281 wedge** (the store stays active), **21 are stuck idle** (the scope cannot move). Only 33 wedge and 3 stuck cells are tracked, so **266 are untracked**. | A |
| Exit rules | 23 special-case rules: about 10 predicates with about 35 hard-coded allowlist entries (scope kind, resource kind, action, executor, review shape). F16 through F65 each added or widened one. | B |
| Identity | No create path captures the UID the provider returns. Four readers trust the record; only one writer, a fresh observation at convergence, produces it. 22 untracked paths trust a fresh observation or pass without a record, including backup and restore sources, collection deletes and fence capture. | C |
| Model coverage | 70 of 414 reachable fault cells (17%), all on the Kubernetes executor. There is no world for nine executors. The harness masks some refusals and has a no-op fault. | D |
| Crash points | The journal and head core is sound (F38 holds). New: an abandon whose head write fails wedges the store (U1); CDN purge and VM power have no exit (U2); an abort keeps stale retained entries (U3); a local cache can skip remote publication (U4); `plan` writes the head unlocked (U5). | E |
| Open obligations | 27 findings not closed, and the candidate gates C1–C5 to rerun. | F |

At the current rate of about 2–4 hours per finding, 266 untracked cells cannot be worked off one at a
time. The cells come from three structural causes, and each cause has one fix.

## 2. Three structural causes

1. **Exits are allowlists, not proofs.** Operations run in operation-ID (digest) order, so which
   companions are still pending at a stall is effectively arbitrary. Every stop or abandon rule guesses
   "no effect" from the review's shape and from named kinds, instead of from each operation's own
   proof. Each new kind or situation is a new finding (B; A §"Where exits are decided").
2. **Identity was added after the journal.** Nothing records what Nagare created, so every consumer
   either trusts a fresh observation (a replacement passes) or passes when no record exists. F49, F51,
   F52, F58, F60 and F62, plus N1–N22 in C, are this one cause.
3. **Coverage is sampled.** The model covers the rows somebody thought of. Gaps are found by reviewers,
   one cell at a time (D).

## 3. Proposed decisions

### D1. One proof-based exit rule replaces the allowlists (new ADR 26)

Every adapter gets one total function, `adapterSettle`. Each operation in a stopped transaction is
classified once:
- **from the journal, with no adapter call:** Completed, NeverStarted (no intent event, which is sound
  because intent is journalled before any effect), Refused, or Reverted;
- **from the adapter:** NoEffect (a proved, unchanged before-state), Landed (the exact reviewed effect,
  not ready), TargetGone (replaced or deleted outside review), TerminalPartial, or Unknown.

A single reviewed **close-transaction** decision is admissible when:
- no operation is Unknown;
- resume is stuck;
- no data fence or migration is active.

It writes nothing to the provider and binds no incarnation. A changed scope reverts to its review base
only if every one of its operations had no effect, and it undoes its own retained and migrated
additions. Otherwise it keeps its desired revision, so everything created or landed stays owned. Scopes
the review did not change are untouched. The never-started set is computed for every scope kind.

This rule:
- **Replaces** `incompleteApplicationOnlyReview`, the four review-shape abandon predicates, the stop
  branch, the partial-restore, partial-prune and refused-operation abandons, and both terminal claim
  releases. That is about −800 lines of source, +650.
- **Covers** F16, F29, F30, F35–F37, F54–F59, F63, F64 and F65, and the F55/F57/F59 class gaps. It also
  covers the review's untracked cells for the same reasons (A items 4, 5, 7–9).
- **Fixes** the abort hazards (A items 1–3; E U1, U3; B H1–H3) by making the abort scope-local and its
  head release retryable.
- **Does not cover** F60, F62, or F61's dirty destination. F61 needs a forward "wipe an unused
  destination" exit. Unobservable providers stay Unknown and need D5's last-resort exit.
- **Changes behaviour you must accept:** the F35, F36 and prune exits keep the scope accepted but not
  converged, instead of orphaning its leftovers.

Estimate: 2–3 days for the rule and adapters, plus the model work in D3.

### D2. Identity through one checked accessor, with a create-identity record

- Record the provider-returned identity at create, adopt and update in the journal's completion event.
  This is F60's five-step design, plus `copySecret` and the adopt and update paths.
- Every consumer reads identity only through one accessor that refuses a mismatch: status, retention,
  migration source, ingestion, backup and restore source, fences and collection delete preconditions.
- Add a reviewed **rebind** decision, so a replaced data member has an exit (N1) instead of a refusal.

This closes F60, F62 and N2–N13, and makes F49's and F51's limits hard. It does not reach the
non-Kubernetes kinds (N14–N20) without provider identities.

Estimate: F60's 4–6 hours plus 1–2 days for the accessor and rebind.

### D3. Coverage generated from a kind table, not found by review

- Declare each kind's world behaviour in one table: actions, readiness, single- or multi-step writes,
  identity, fixture.
- Generate the scenario × applicable-fault × invariant product from that table.
- Add a totality test that fails when an executor or admitted action has no row.
- Fix the harness defects found in D:
  - the `ForeignObject` exemption masks refusals;
  - `LandsFailed` is a no-op;
  - admission refusals count as `Done` (this hid N1);
  - the corrected-review exit is not explored.
- Add the deletion, crash-at-store and claim-loss faults.

The full table is about 25–35 days of work (D). For the release line in D4, only the rows inside the
line are needed, which is roughly a week.

### D4. Draw the release line once

Recommendation: **line (b)**. MP-23 guarantees reviewed, recoverable changes for **Kubernetes
application scopes (Knative Service, worker Deployment, tasks, DomainMapping), standalone databases,
sites and previews**, on the reviewed paths. Those are what the team's intranet use runs.

The following become **documented limits** for this release, each with D5's exit:
- the rare-fault cells of Pulumi/foundation, host, CDN, Cloudflare, broker and Helm;
- F57's other executors;
- F59's broker gap;
- the rename's partial copy, if F61's forward exit does not land.

Line (a), everything, stays unbounded while discovery continues at about ten findings a day. Line (c),
ship nearly as-is, leaves a bad worker image or an out-of-band delete able to block every app's
deploys (F).

### D5. A last-resort exit for anything Unknown

Add an operator-attested **close, accept nothing** decision for a transaction whose operations the
adapters cannot prove. It is logged as an operator attestation in the journal and never binds or
converges anything. Today the only way out of such a state is a raw store edit, which the repository
rules forbid. This turns every remaining wedge into a documented, reviewed manual step rather than a
stuck store.

### D6. No more open-ended review rounds

Order of work:
1. D1 with D2's accessor and rebind;
2. D3 for the release-line rows;
3. **one** final verification against the line;
4. a new candidate, then C1–C5.

Findings outside the line go to the ledger as documented limits, not into MP-23. The model-plus-gate
loop finds defects; reviewers verify against the line.

## 4. Sequencing and cost

| Step | Work | Estimate |
|---|---|---|
| 1 | ADR 26 and D1 (rule, adapter settlement, scope-local abort, retryable release, F61's forward exit) | 3–4 days |
| 2 | D2 accessor, rebind and F60 create-identity record (Kubernetes) | 2 days |
| 3 | D3 for the release-line rows; harness fixes | ~5 days |
| 4 | D5 last-resort exit; U2, U4, U5 fixes | 1 day |
| 5 | Final verification, a new candidate with a green `just gate`, C1–C5 (including the phase 3b teardown) | 2–3 days |

The total is about 2–2.5 weeks for line (b). The current way, about ten findings a day, does not end.

## 5. What happens to the open findings

- **Folded into D1:** F55, F56, F57 (within the line), F59, F61's no-exit half, F63, F64 and F65.
- **Folded into D2:** F51 (reopened: N1), F52's convergence half, F60 and F62.
- **Unchanged:** the verification-only and native-only findings (F15, F16, F30, F31, F32, F33, F39,
  F40, F43–F48, F53). They are finished in step 5.
- **New, from this review:** A's untracked cells, C's N1–N22 and E's U1–U8. None of them is filed
  separately. Each is a case D1, D2 or D3 must cover, and the step-5 verification checks them against
  these files.

## 6. Decisions requested

1. Adopt D1 as ADR 26, replacing the stop and abandon allowlists with the proof-based close rule.
2. Choose the release line: (b) recommended, or (a) or (c).
3. Approve D2's scope, including F60's create-identity record (previously deferred at 4–6 hours).
4. Approve D5's operator-attested last-resort exit.
5. Confirm D6: no new review rounds until step 5.

Until decided, nagare holds after its current checkpoint (operator instruction, 2026-10-05).

## 7. Corrections in this review

- **F51 is reopened.** I closed it earlier today on a caught mutant. The identity review (C, N1) shows
  that the fix makes admission refuse to retire a replaced database, contradicting F51's own update and
  ADR 22's documented exit. The model hid this because it counts admission refusals as `Done`. A
  pinned guard is not a working exit.
- My own verification round today followed the pattern this proposal stops: it closed 2 findings,
  reopened 1 and opened 3.
