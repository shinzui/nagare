# Phase-3a rvf16 sequence on `mp23-c3i`: the F54 wedge (frozen record, not maintained)

The raw output of the reviewer's operator-approved phase-3a sequence (the F16/F30 steps) on the
cloud C3 context `mp23-c3i` (candidate `847543896d07`). nagare-reviewer ran it on
**2026-10-05, about 02:22–02:44 UTC** (2026-10-04 19:22–19:44 at -07:00). It stopped when the
landed but unready Service update could not be stopped, which opened F54. The summary is
[`../phase3a-c3-mp23-c3i.json`](../phase3a-c3-mp23-c3i.json) (`operatorApprovedSequence`). The
finding is [F54](../../mp23-findings.md#f54) ("Native evidence"). The later native F54 run that
released the store is in
[`../../mp23-implementer-results-2026-10-03/f54-native-mp23-c3i/`](../../mp23-implementer-results-2026-10-03/f54-native-mp23-c3i/README.md).

This copy was made on 2026-10-05 by session nagare-84 from scratch storage that is not kept:
`/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/e52c3ad3-7837-46c3-9104-2d027c6c1e88/scratchpad/c3/seq/`.
Files are byte-for-byte copies; nothing was edited.

## Files, in sequence order

| File | What it is |
|---|---|
| `head-0.json` | Store head before the sequence: generation 916, idle. |
| `nonce` | The run marker `d747f5b7` used in the known row. Not a secret. |
| `1-create/review.json`, `review.sha256` | The rvf16 create review `22572096…` (64-CPU Service request, never Ready). |
| `1-create.plan.log`, `1-create.apply.log` | Plan digest; apply stopped `ambiguous … at op-ccef4bff…`. |
| `head-1.json` | Head with `tx-22572096…` active (generation 935). |
| `1-ksvc.json`, `1-sts.txt`, `1-pvc.json` | Service UID `442ecbcb…` (generation 1, Ready False), StatefulSet `308a3ea3…` (ready=1), PVC `6df5e086…` (Bound). |
| `1-status.json` | `inventory status --json` after the stopped create. |
| `2-stop-decision.json`, `2-stop.log` | Reviewed `stop-incomplete-application` for `op-ccef4bff…`, and its success. |
| `head-2.json` | Head idle after the stop (generation 938). |
| `2-known-row.txt` | The known row written to `rvf16-pg`: `1|rvf16-d747f5b7-before-correction`. |
| `3-correct/review.json`, `review.sha256` | The correction review `44577a2c…` (100m CPU; still no `REDIS_URL`, the fixture error). |
| `3-ksvc-rv-before-plan.txt` | Service resourceVersion `45284` before planning (no status churn). |
| `3-correct.plan.log`, `3-correct.apply.log` | Plan digest; the apply was killed with SIGKILL after 15 s, so its log is empty. |
| `head-3-after-kill.json` | Head after the kill: `tx-44577a2c…` active, executor claim held. |
| `3-resume.log` | Resume stopped `ambiguous … at op-7a4cc6b7…` (the landed update). |
| `head-4-before.json` | Head before the second stop (generation 962). |
| `4-stop2-decision.json`, `4-stop2.log` | Reviewed stop for `op-7a4cc6b7…`, refused with `unsupported-recovery`. The F54 native run later reused this decision file. |
| `head-4-after.json` | Head after the refusal: still active (generation 964). |
| `4-status-wedged.json` | Status of the wedged store. |

## Excluded

- `1-create/scopes/`, `3-correct/scopes/`: 50 content-addressed scope revisions each (file name =
  sha256 of content), about 1.6 MB per set. The reviews name them by digest.
- The rest of the reviewer's `c3/` scratch directory, which is outside this sequence: F31 samples,
  node images, the rehearsals, the fixture copies and store status. `phase3a-c3-mp23-c3i.json`
  summarises it.
- Nothing from the operator root `/private/tmp/nagare-mp23-c3i` (keys, kubeconfig, state).

## Secret scan

Every file was scanned before and after the copy with the repository's rule (`reject_sensitive` in
`scripts/assemble-inventory-release-index.py`) and the generic patterns: PEM private keys, AWS keys,
service-account JSON, OAuth and bearer tokens, kubeconfig client credentials, age keys, sops
metadata, signed URLs, URL passwords and JWTs. There were no hits.
