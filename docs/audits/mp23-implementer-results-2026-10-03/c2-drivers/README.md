# C2 drivers for candidate 7d486457 (frozen record, not maintained)

These are the exact shell drivers that ran the passing MP-23 acceptance C2 for candidate
`7d486457` on 2026-10-04 (session nagare-phase-b). Order of execution:
- `chain.sh`: `phase1.sh`, C1, `phase2.sh`, `phase2b.sh`, `phase3-restores.sh`, `phase3-misc.sh`, `phase3-su.sh`, `phase3-final-a.sh`;
- then, after the refused preview collect described in the results record, `chain-resume.sh`: `phase3-final-a-resume.sh`, `phase3-final-b.sh`, assembly.

`defer-record.sh` queues assertion records while the checks write into a staging directory.
`scope-snap.sh` is used by the independent-scope check.

They are kept as evidence of what ran, **not** as tooling:
- they hard-code one session's scratch directory, operator root and candidate;
- the evidence shaping is untested inline Python.

Do not build on them. The procedure is
[runbook §6](../../../runbooks/native-verification-harness.md). The replacement tool is
[EP-168](../../../plans/168-script-the-local-acceptance-run-as-one-command.md), written in Haskell
under [ADR 24](../../../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md).

No secret value is stored here. Credentials are read from the cluster or private files at run
time. The one literal password belongs to a disposable offline-restore container.
