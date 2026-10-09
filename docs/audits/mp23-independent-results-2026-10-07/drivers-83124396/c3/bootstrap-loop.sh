#!/usr/bin/env bash
# Drive the reviewed bootstrap stages of mp23-c3m: plan (with safety filter) then apply,
# one stage per pass. Stops on any refusal or failure, or when a plan is verify-only.
set -uo pipefail
root=/Users/shinzui/.local/state/nagare-verify/mp23-c3m
log="$root/evidence/bootstrap-loop.log"
for n in ${START:-2} $(seq $(( ${START:-2} + 1 )) 12); do
  name="s$n-stage"
  if ! out=$("$root/c3-stage.sh" "$name" plan 2>&1); then
    echo "$(date -u +%FT%TZ) $name plan FAILED: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-300) $(tail -2 "$root/evidence/$name/plan.stderr" 2>/dev/null | tr '\n' ' ' | cut -c1-300)" | tee -a "$log"
    exit 1
  fi
  echo "$(date -u +%FT%TZ) $name planned: $out" | tee -a "$log"
  if [ "$(jq -r '[.operations[].operation.action.tag] | unique | join(",")' "$root/evidence/$name/review/review.json")" = "VerifyResource" ]; then
    echo "$(date -u +%FT%TZ) $name is verify-only; bootstrap converged" | tee -a "$log"
    exit 0
  fi
  if ! out=$("$root/c3-stage.sh" "$name" apply 2>&1); then
    echo "$(date -u +%FT%TZ) $name apply FAILED: $(echo "$out" | tail -3 | tr '\n' ' ' | cut -c1-400)" | tee -a "$log"
    exit 2
  fi
  echo "$(date -u +%FT%TZ) $name applied: $(cat "$root/evidence/$name/apply.result.json")" | tee -a "$log"
done
