# EP-159 source replacement: native proof procedure (candidate `7596632c`)

Implementer evidence, produced by nagare-phase-b and checked by nagare-reviewer (its choice (b),
2026-10-04). This file is written **before** the run so the reviewer can check the procedure.
The results file `ep159-source-replacement-7596632c.json` will sit beside it.

**Claim under test** (EP-159 "Source replacement", as re-scoped and accepted on source grounds by
the reviewer): an out-of-band replacement of a database source refuses both scheduled-receipt
ingestion and isolated restore of an earlier ingested receipt, with no writes. Recovery then uses the
source-unavailable path.

## Setting

- **Context:** the C2 context for `7596632c` on cp3 (`/private/tmp/nagare-mp23-c2-7596632c.*`), through its `env -i` wrapper `runctl.sh`, with the candidate CLI `/private/tmp/result-7596632c-nagare`.
- **cp3 claim:** taken before step 1, released after the last step, only with no active transaction.
- **Throwaway database:** `ep159-throwaway` (PostgreSQL), namespace `personal`. Every out-of-band write targets only it.
- **Expected refusal texts, from the candidate source:**
  - restore: `scheduled restore target source incarnation changed after ingestion` (`app/Nagare/Cli/Data/Restore.hs`);
  - ingestion: `scheduled receipt source incarnation differs from accepted evidence` (`src/Nagare/Inventory/BackupReceipt.hs`), or an earlier planning refusal that names the drifted or replaced source. Whichever appears is recorded verbatim.

## Steps

1. **Baseline:**
   - the head's generation, sequence and `activeTransaction`;
   - `inventory status --json` findings for every scope;
   - the UID and resourceVersion of every StatefulSet and PVC in `personal`, excluding none.
2. **Create:**
   - `db create postgres ep159-throwaway --size 1Gi --recovery-backup ep159-throwaway --recovery-key-version v1 --save-plan DIR`, then `inventory apply DIR --yes`;
   - write one known row (`ep159_known`: `1|ep159-row-1`).
3. **Two scheduled backups.** Wait for two runs of the signed schedule. On this context they run every 15 minutes, at about :00, :15, :30 and :45. Record from `db backup-receipts` the Job UID, object version and receipt version of each:
   - **A** is ingested (`db backup-receipts ep159-throwaway --backup-id A --save-plan DIR`, then apply). Record its accepted scope's `scheduled.backup.id` and source StatefulSet/PVC UIDs from `inventory export`.
   - **B** is left pending, never ingested.
4. **Pre-replacement snapshot:** the head generation/sequence, the throwaway's StatefulSet and PVC UIDs and resourceVersions, and the accepted backup scopes for the throwaway (exactly one, A).
5. **Out-of-band replacement** (the deliberate drift, throwaway only):
   - Save the StatefulSet object.
   - `DELETE` the StatefulSet through the raw API with preconditions `{"uid": <old>, "resourceVersion": <current>}`, Background propagation. Record the exact precondition values.
   - Wait for its Pod to disappear.
   - `DELETE` the PVC `data-ep159-throwaway-0` through the raw API with preconditions `{"uid": <old>, "resourceVersion": <current>}`.
   - Recreate the StatefulSet from the saved object with `kubectl create`, server fields stripped (uid, resourceVersion, managedFields, creationTimestamp, status). The StatefulSet controller creates a new PVC from the claim template.
   - Wait for Ready. Record the new StatefulSet and PVC UIDs; both must differ from the old ones.
   - Record `inventory status --json` for the throwaway's scope members: how the operator surface classifies the StatefulSet and PVC after the replacement. (Reviewer addition 2.)
6. **Refusal 1, ingestion:** `db backup-receipts ep159-throwaway --backup-id B --save-plan DIR`. Record:
   - the command, exit code and refusal text;
   - the head generation/sequence/`activeTransaction` before and after (unchanged, null);
   - that no review directory was saved.
7. **Refusal 2, isolated restore:** `db restore ep159-throwaway <A's scheduled.backup.id> --restore-id ep159r1 --save-plan DIR`. Record:
   - the same fields as refusal 1;
   - that no StatefulSet, PVC or Job named for a restore of the throwaway exists afterwards (no scratch database).

   **7b. The recovery path still works for A** (reviewer addition 3, no write). Run `db escrow-signing-key ep159-throwaway` into a 0600 file outside the repository, then the online `db verify-escrowed-backup ep159-throwaway --backup-id <A's Job UID> --escrow FILE`. It must verify A's exact object version, receipt version and sha256 after the replacement.
   **7c. Receipt C** (reviewer addition 1, no write). If the schedule writes a receipt C from the new incarnation, attempt `db backup-receipts ep159-throwaway --backup-id C --save-plan DIR` and record the refusal as for B. This is the stronger case: C's source UIDs match the live objects but not the accepted evidence. The run waits up to one schedule interval (16 minutes) after the replacement for C. If none appears, that is recorded.
8. **No ingestion happened:** the accepted backup scopes for the throwaway are still exactly {A}. `db backup-receipts` still lists B as pending. Any receipt C that the schedule wrote from the new incarnation during the window is listed and recorded, never ingested.
9. **Confinement:** every other StatefulSet and PVC in `personal` has the same UID as in step 1.
10. **Cleanup:** `db retire ep159-throwaway --save-plan DIR`, then apply. The store ends idle (no active transaction).

    **Known risk:** the recreated StatefulSet's fields are owned by `kubectl-create`, which F37 classifies as configuration drift. Retirement requires a present, undrifted observation, so it may refuse. If it does, the refusal is recorded verbatim, nothing is worked around (no takeover, raw delete or field-manager rewrite), and the throwaway stays as a documented drifted scope, with the store idle. The decision on further cleanup goes back to the reviewer and operator.

## Recorded for each step

The command (secrets redacted), exit code, last output line, and the head generation, sequence and
`activeTransaction` before and after. For each refusal, also: the exit code is non-zero, and the
`--save-plan` directory did not exist before and does not exist after (reviewer addition 4). Raw outputs go to the operator root's `pending-evidence/ep159/`.
The public results file contains no secret-shaped keys.
