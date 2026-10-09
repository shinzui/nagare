#!/usr/bin/env bash
# Acceptance C3 on mp23-c3m (candidate 83124396) after bootstrap, in runbook order; stops at the
# first failure. Every step writes its own evidence under pending-evidence/ or evidence/.
set -uo pipefail
I=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; L=$I/c3-chain.log
export KUBECONFIG=$I/config/nagare/kubeconfigs/mp23-c3m.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs
run() { echo "== $(date -u +%T) $1" >> $L; bash "$I/$1" >> $L 2>&1; rc=$?; echo "-- $1 rc=$rc" >> $L; [ $rc -eq 0 ] || { echo "CHAIN STOPPED at $1" >> $L; exit 1; }; }
run su-drill.sh
run preview-cleanup.sh
run precheck-runner.sh
run c3-runner.sh
run c3-assemble.sh
echo "CHAIN-DONE" >> $L
