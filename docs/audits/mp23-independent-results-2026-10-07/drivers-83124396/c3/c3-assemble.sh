#!/usr/bin/env bash
# Assemble the C3 rehearsal's inventory evidence for candidate 83124396 (acceptance).
set -euo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; REPO=/private/tmp/nagare-cand-83124396-src
EV=$ROOT/evidence/c3-83124396; REL=/private/tmp/nagare-release-83124396
cd $REPO
bash scripts/assemble-managed-resource-evidence.sh --release-manifest $REL/aarch64-darwin/nagare-release-0.4.0.json \
  --system aarch64-darwin --rehearsal-dir $EV --private-store-export $ROOT/evidence-private/final-export \
  --coverage-result $REL/coverage.json --output $EV/inventory-evidence.json
jq -c '{schemaVersion, payload, converged: .converged}' $EV/inventory-evidence.json | cut -c1-400
