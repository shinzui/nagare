# C3 on the final candidate `3b59bcb7`

nagare-verify ran this on 2026-10-09 on the fresh context `mp23-c3l` (project `tan-ng-labs`, names
`c3-1011`). The context was bootstrapped from the candidate's own payload (`platform-root.json`:
`nagare-0.4.0-3b59bcb7612d`), stages 1–9 with stage 10 verify-only (`bootstrap-loop.log`). The run
finalized 17 of 17 assertions (`cloud-health.json`), and the assembler accepted it
(`inventory-evidence.json`). The full console log is `chain.log`.

The chain ran from start to finish without a stop. The application-change phase that F88 refused on
`3b78d905` converged on its first apply, and the host transport ran under the operator's `PATH`
without a candidate-binary override, so F90's fix is exercised. The `rebind unrecorded` step is the
documented rebind before backups (ADR 27 §3, F80), not a recovery.
