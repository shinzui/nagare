# F54 native run on `mp23-c3i` (frozen record, not maintained)

The raw output of the native F54 sequence that nagare-phase-b ran on the cloud C3 context
`mp23-c3i` on **2026-10-05, 03:39:45–03:51:00 UTC** (2026-10-04 20:39:45–20:51 at -07:00). The CLI
was built from `96d38d67` (the F54 fix); the platform root was pinned to the accepted
`nagare-0.4.0-847543896d07` workspace. The run is described in
[F54](../../mp23-findings.md#f54) ("Reviewer read of the native run") and in
[retrospective §7.1](../../mp23-engineering-retrospective-2026-10-04.md). It confirmed the fix
natively; it did not follow [the pre-flight checklist](../../../runbooks/before-a-native-run.md).

This copy was made on 2026-10-05 by session nagare-84 from scratch storage that is not kept:
`/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/f54/`.
Files are byte-for-byte copies; nothing was edited.

## Sequence

`native.sh run` stops at the first unexpected result:
- **pre** (read-only): node is `mp23-c3i-nagare`; Service, StatefulSet and PVC UIDs and the known
  row match; the store's active transaction is `tx-44577a2c…`.
- **a**: `inventory recover tx-44577a2c… --operation op-7a4cc6b7… --decision stop-incomplete-application`.
- **b**: corrected rvf16 review (literal `REDIS_URL`), a plan gate on its actions, then apply. It
  converged as `tx-5160965a…` with the same three UIDs and the known row.
- **c**: replan of the same config; zero operations.

## Files

| File | What it is |
|---|---|
| `native.sh` | The driver as run (`native.sh pre`, then `native.sh run`). Hard-codes this session's paths. |
| `native-run.log` | Console output of the run, UTC step times. |
| `inputs/4-stop2-decision.json` | The reviewed stop decision consumed by step a. It comes from the reviewer's phase-3a sequence, archived in [`../../mp23-independent-results-2026-10-04/phase3a-seq-mp23-c3i/`](../../mp23-independent-results-2026-10-04/phase3a-seq-mp23-c3i/README.md); this copy is byte-identical to the one there. |
| `evidence/ksvc-before.json` | Knative Service `rvf16` with managed fields before the stop: generation 2, observed 2, Ready False. |
| `evidence/status-before.json` (`.err`) | `inventory status --json` before step a: active `tx-44577a2c…`, `operation-recovery-required`. |
| `evidence/a-stop.log` | Output of the reviewed stop. |
| `evidence/status-after-stop.json` (`.err`) | Status after the stop: no active transaction. |
| `evidence/b-plan.log` | Saved corrected review digest `5160965a…`. |
| `evidence/b-plan-ops.tsv` | Its 11 operations: 1 `UpdateResource` on the Service, 1 `CreateResource` (release history), 9 `VerifyResource`. |
| `evidence/b-apply.log` | `converged tx-5160965a…`. |
| `evidence/status-after-apply.json` (`.err`) | Status after the corrected apply: idle. |
| `evidence/ksvc-after.json` | Service after correction: generation 3, observed 3, Ready True. |
| `evidence/c-plan.log` | Replan review digest `6b2d0145…`. |
| `b-correct/review.json`, `review.sha256` | The corrected review (sha256 matches `5160965a…`). |
| `c-replan/review.json`, `review.sha256` | The replan review, zero operations (sha256 matches `6b2d0145…`). |
| `rvf16-fixed/nagare/Config.hs` | The corrected rvf16 fixture config used by steps b and c (100m CPU, literal `REDIS_URL`). |
| `app18080.py`, `app18080.log` | The local "does the workload start" check before the run: the `scenario-b` entrypoint bound to 127.0.0.1:18080. `/` served 200; a Redis request then failed as expected with no Redis. |
| `mutations.log` | Per-guard mutation results from `mutate.py`, run 2026-10-04 20:21 (-07:00) on the F54 working tree before `96d38d67`; context for retrospective §7.2. |

## Excluded

- `b-correct/scopes/`, `c-replan/scopes/`: 50 content-addressed scope revisions each (file name =
  sha256 of content), identical between the two, about 1.6 MB per set.
- `app.py`: identical to [`fixtures/inventory-release/local/apps/scenario-b/app.py`](../../../../fixtures/inventory-release/local/apps/scenario-b/app.py). `app.log`: empty.
- `InventoryLandedUpdateStopSpec.hs`, `spec-backup.hs`, `f54-wip.diff`: working copies of source
  now committed (`cli/nagarectl/test/InventoryLandedUpdateStopSpec.hs`, `96d38d67`, `d58218d0`).
- `mutate.py`: the mutation driver (hard-codes the shared tree).
- Build and test logs (`suite*.log`, `wt-*.log`, `dsl.log`, `style*.log`, `arch.log`) and `venv/`.
- The rest of the phase-3a sequence directory, which is archived separately (see above).

## Secret scan

Every file was scanned before and after the copy with the repository's rule (`reject_sensitive` in
`scripts/assemble-inventory-release-index.py`: JSON keys matching
`password|credential|access.?token|private.?key|secret`, and the value markers) plus generic
patterns (PEM private keys, AWS keys, service-account JSON, OAuth and bearer tokens, kubeconfig
client credentials, age keys, sops metadata, signed URLs, URL passwords, JWTs). No secret value was
found. The only hits are `secretRef` / `secretKeyRef` keys in `ksvc-before.json` and
`ksvc-after.json`: references to Secret names (`nagare-db-rvf16-pg`, `nagare-secret-rvf16-runtime`),
not values. They were kept; committed archives such as
`../cp3-postgresql-rename-bc2fd90e.json` already carry the same references.
