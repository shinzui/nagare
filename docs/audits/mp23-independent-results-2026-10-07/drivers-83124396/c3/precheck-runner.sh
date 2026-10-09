#!/usr/bin/env bash
# Before the C3 runner: the assembler requires accepted == converged and no active transaction.
# ADR 26 close keeps a scope in which anything took effect; such a scope must be retired first.
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m
$ROOT/runctl.sh inventory status --json > $ROOT/evidence/status-precheck-runner.json 2>/dev/null || { echo "precheck: status failed"; exit 1; }
jq -r '([.converged[].scope|"\(.kind):\(.name)"]) as $c | [.accepted[].scope|"\(.kind):\(.name)"|select(. as $s|$c|index($s)|not)] | "unconverged: \(.)"' $ROOT/evidence/status-precheck-runner.json
jq -e '.activeTransaction == null and (.accepted|length) == (.converged|length)' $ROOT/evidence/status-precheck-runner.json >/dev/null || { echo "precheck: accepted != converged or a transaction is active"; exit 1; }
echo "precheck: accepted == converged ($(jq '.accepted|length' $ROOT/evidence/status-precheck-runner.json))"
