# C2 evidence directory for candidate `b74b7e49` (frozen record, not maintained)

The public rehearsal directory of the MP-23 acceptance C2 that nagare-phase-b ran on a fresh local
context (Colima profile `nagare-mp23-cp3`, k3d cluster `k3d-nagare-local`, context `local`) for
frozen candidate `b74b7e49bf33cee19a13b58020ab1762d8ae4638`, payload `nagare-0.4.0-b74b7e49bf33`.
The chain ran **2026-10-05, 00:32:30–01:11 UTC** (2026-10-04 17:32:30–18:11 at -07:00); the
16 assertion records are dated 01:09:30Z–01:10:53Z. `scenario-assertions.py finalize` passed 16/16
and `assemble-managed-resource-evidence.sh` accepted this directory.

The summary record is [`../c2-acceptance-b74b7e49.json`](../c2-acceptance-b74b7e49.json), cited by
[MasterPlan 23](../../../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md)
(C2) and [EP-155](../../../plans/155-prove-local-application-and-data-recovery-end-to-end.md). Its
`evidenceDirectory` is "operator root evidence/c2-b74b7e49"; this is a copy of that directory. The
procedure is [runbook §6](../../../runbooks/native-verification-harness.md).

This copy was made on 2026-10-05 by session nagare-84 from scratch storage that is not kept:
`/private/tmp/nagare-mp23-c2-b74b7e49.eL0UTi/evidence/c2-b74b7e49`. Files are byte-for-byte copies;
nothing was edited.

## Files

| Path | What it is |
|---|---|
| `target.json`, `context-guard.json`, `fixture.json` | The local target, its confinement guard, and the scenario fixture binding. |
| `operator-version.json`, `platform-root.json` | Operator revision and the installed payload (`nagare-0.4.0-b74b7e49bf33`, the F48 guard). |
| `candidate.json`, `candidate.sha256` | The runner's platform candidate (digest `514781e1…`). |
| `review/review.json`, `review.sha256` | The runner's review (`b229f741…`). |
| `after-apply.json` | `inventory status` after the runner's apply. |
| `no-op-review/review.json`, `review.sha256` | The verify replan, zero operations (`5c8fd5ba…`). |
| `run.json` | Run state: `verified`, `noOp: true`. |
| `final-observation.json` | Final observation: complete, no missing providers, no active transaction. |
| `local-health.json` | Platform health and preflight checks. |
| `assertions/*.json` | The 16 assertion records (`access-grant-revoke` … `volume-backup-restore`). |
| `checks/<assertion>/*` | The evidence each assertion record cites. |
| `inventory-evidence.json` | The assembler's output for this directory. |

## Excluded

- `review/scopes/`, `no-op-review/scopes/`: 46 content-addressed scope revisions each (file name =
  sha256 of content), identical between the two, about 1.6 MB per set. The reviews name them by digest.
- The sibling staging directory `evidence/c2-b74b7e49-staging/` (39 files): its `checks/` tree is
  identical to `checks/` here except that it lacks `interrupted-recovery` and `secret-read-refusal`,
  and its `platform-root.json` was copied here by `phase3-final-b.sh`.
- Everything else in the operator root, including `evidence-private/`, `config/`, `images.env`,
  `cache/`, `images/`, `history-restore-root/`, `escrow/`, `cluster-secrets/` and `state/`. Those
  hold credentials, keys or private store exports and are never archived.
- The shell drivers for this run. The kept set in [`../c2-drivers/`](../c2-drivers/README.md) is the
  one for `84754389`.

## Secret scan

Every file was scanned before and after the copy with the repository's rule (`reject_sensitive` in
`scripts/assemble-inventory-release-index.py`), the run's own needle check (the run-time
`SCENARIO_API_TOKEN`, raw and base64, read from the private root for comparison only, as
`phase3-final-b.sh` does), and generic patterns (PEM private keys, AWS keys, service-account JSON,
OAuth and bearer tokens, kubeconfig client credentials, age keys, sops metadata, signed URLs, URL
passwords, JWTs). No match. The only generic hit is `"kind":"Secret"` in
`checks/retained-postgresql-rename/uids.json`: names and UIDs of Secret objects, no data.
