Real `rehearse-local-inventory-release.sh` output from the MP-23 acceptance C2 runner rehearsal for
candidate `14071e58` (2026-10-03): the compiled candidate, its single-CreateResource review, the run
marker, and the verify no-op review. `final-observation.json` keeps only the fields the assembler
reads. That observation is incomplete (`missingProviders: ["AccessExecutor"]`) because the runner ran
without the en endpoint, so the assembler must bind both reviews and then refuse the observation
(finding F42, `scripts/test-managed-resource-evidence.sh`).
