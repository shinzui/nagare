# C3 on the final candidate `83124396`

nagare-verify ran this on 2026-10-09 on the fresh context `mp23-c3m` (project `tan-ng-labs`, names
`c3-1012`). The context was bootstrapped from the candidate's own payload (`platform-root.json`:
`nagare-0.4.0-831243962c6b`), stages 1–9 with stage 10 verify-only (`bootstrap-loop.log`). The run
finalized 17 of 17 assertions (`cloud-health.json`), and the assembler accepted it
(`inventory-evidence.json`). The full console log is `chain.log`. Once the bootstrap converged, the
chain ran from start to finish without a stop. The `rebind unrecorded` step is the documented rebind
before backups (ADR 27 §3, F80), not a recovery.

## Stage 7 stopped ambiguous, then converged by `inventory resume`

Stage 7, the first host activation, stopped ambiguous at 09:50Z. This was not a defect in the
candidate. The context's Tailscale auth key granted no tag, so the host fell under the tailnet's
default SSH `check` rule. The host transport's mandatory fresh login waited for a browser
re-authentication that nobody could give overnight. A probe kept a check session open
(`stage7/ts-probe.log`: 261 unapproved attempts). The operator approved the check at 13:41Z. A
gcloud CLI re-authentication then held the run until 13:43Z; that attempt passed no transaction and
wrote nothing (`stage7/continuation.log`). At 13:44Z, `inventory resume` re-observed the host and
converged the transaction (`stage7/resume.txt`), as the runbook prescribes. Stages 8–10 followed.

The operator has since given `tag:nagare-test` an SSH `accept` rule, and test-context keys now carry
that tag. The runbook's Tailscale bullet in `docs/runbooks/native-verification-harness.md` records
this.
