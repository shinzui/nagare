# C2 drivers for candidate 84754389 (frozen record, not maintained)

These are the exact shell drivers that ran the passing MP-23 acceptance C2 for frozen candidate
`84754389` on 2026-10-04 (session nagare-phase-b), and the F49 native drill v2 on the same context
(`f49-drill-v2.sh`). Earlier candidates' sets are in git history.

Order of execution:
- `setup.sh`, run after the operator approved the teardown: claim, private export, teardown, fresh root, context.
- `chain.sh`: `phase1.sh`, C1, a zero-`replaced-incarnation` status check, `phase2.sh`, `phase2b.sh`, `phase3-restores.sh`, `phase3-misc.sh`, `phase3-su.sh`, `phase3-final-a.sh`, the zero-`replaced-incarnation` check again, `phase3-final-b.sh`, assembly. It passed first time.
- `f49-drill-v2.sh`: the EP-159 source-replacement drill, with the escrow taken before the replacement.

`defer-record.sh` queues assertion records while checks write into a staging directory.
`scope-snap.sh` is used by the independent-scope check. `phase3-final-b.sh` records and asserts
`platform root --json` before the runner's plan (the F48 guard).

They are kept as evidence of what ran, **not** as tooling:
- they hard-code one session's scratch directory, operator root and candidate;
- the evidence shaping is untested inline Python.

Do not build on them. The procedure is
[runbook §6](../../../runbooks/native-verification-harness.md). The replacement tool is
[EP-168](../../../plans/168-script-the-local-acceptance-run-as-one-command.md), written in Haskell
under [ADR 24](../../../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md).

No secret value is stored here. Credentials are read from the cluster or private files at run
time. The one literal password belongs to a disposable offline-restore container.
