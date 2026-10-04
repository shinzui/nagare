Session-local prototype drivers that ran the MP-23 acceptance C2 for candidate `14071e58` on
2026-10-03 (nagare-phase-b). They are reference material for
[EP-168](../../../plans/168-script-the-local-acceptance-run-as-one-command.md), not maintained
tooling: they hard-code one operator root and scratch directory, assume a bootstrapped context, and
read credentials only from the cluster or private files at run time (no secret value is stored
here). `phase2.sh` creates the scenario resources, captures two interruptions and seeds the stores;
`phase3-restores.sh`, `phase3-misc.sh` and `phase3-final.sh` run and record the checks;
`scope-snap.sh` snapshots scope revisions for independent-scope-preservation.
