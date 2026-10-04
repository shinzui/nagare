# F49 native drill v2: EP-159 source replacement on candidate `84754389`

Implementer evidence produced by nagare-phase-b for nagare-reviewer's check. It reruns
[the `7596632c` procedure](ep159-source-replacement-7596632c-procedure.md), including the
reviewer's additions 1–4, on the frozen candidate `847543896d07` that contains the F49 fix
(`38815245` and `84754389`). This addendum lists only the differences. The results go in
`ep159-source-replacement-84754389.json`.

## Differences from the `7596632c` run

1. **Escrow before the replacement.** Step 7b's escrow (`db escrow-signing-key`, a 0600 file outside the repository) is taken after receipt B is recorded and before step 4's snapshot. After the replacement, the online `db verify-escrowed-backup --backup-id A` uses that escrow. It must verify A's exact object version, receipt version and sha256. This is the check that was invalid in the `7596632c` run.
2. **Status must report the replacement.** After step 5, `inventory status --json` must list `replaced-incarnation` for the throwaway's StatefulSet and PVC, and for no member outside the throwaway. Either failure stops the drill.
3. **Expected refusals under F49:**
   - B's ingestion refuses. The message may be F49's "scheduled receipt source is not the accepted database incarnation…" rather than the earlier source-incarnation text; whichever appears is recorded verbatim.
   - C's ingestion (addition 1) must refuse now. In the `7596632c` run it planned.
   - The isolated restore of A still refuses with "scheduled restore target source incarnation changed after ingestion".
   - `db backup-receipts` listing and `--check-freshness` for the throwaway now refuse a replaced source. Both are recorded.
4. **Cleanup uses the supported joint retire.** `inventory retire --scope standalone:database-ep159-throwaway --scope standalone:<A's scheduled-receipt scope> --out DIR`, then apply. The reviewer found this plans where `db retire` alone refuses. The store must end idle.
5. **Clean-context guard.** The C2 chain on this context has already asserted zero `replaced-incarnation` findings after C1 and before the runner. The drill's own status check confirms the throwaway is the only member reported.

Everything else is unchanged:
- the throwaway `personal/ep159-throwaway`;
- receipts A (ingested) and B (pending);
- preconditioned raw DELETEs (uid + resourceVersion), then `kubectl create` from the saved objects;
- every refusal recorded with exit code, save directory absent before and after, and head unchanged;
- no other StatefulSet or PVC changed;
- runs under the cp3 claim.
