# C3 on candidate `3b78d905`

nagare-verify ran this on 2026-10-08 on the fresh context `mp23-c3k` (project `tan-ng-labs`, names
`c3-1010`). The context was bootstrapped from the candidate's own payload (`platform-root.json`):
stages 1–9, with stage 10 verify-only (`bootstrap-loop.log`). The run finalized 17 of 17 assertions
(`cloud-health.json`), and the assembler accepted it (`inventory-evidence.json`). The full console log
is `chain.log`.

The chain stopped three times. Each stop was resolved by a documented step, and the chain then
continued from the stopping point:
1. **F88 (phase 3, application change).** `deploy-a-c3b` was refused at preflight. The CronJob's
   status was written between planning and apply, and the refusal gave no reason. The transaction was
   closed with no effect: every refused operation "never started". The deploy was planned and applied
   again and converged. Fixed by nagare-fix (`478e51de`) for the final candidate.
2. **F89 (image-cache cleanup).** A transient GCS store read failed during a journal append, which left
   the apply ambiguous; `inventory resume` converged it. Deferred to the next release by the operator.
   An earlier read failure in bootstrap stage 3 coincided with an expired gcloud reauthentication and
   was likewise resumed.
3. **Harness typo (runner).** The driver's payload-workspace glob used a wrong 12-character revision
   prefix. It was corrected and the runner rerun from its start.
