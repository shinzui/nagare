#!/usr/bin/env bash
# Move ep248 to the drill package's payload: plan/apply stages until none, then commit.
source "$(dirname "$0")/ep248-lib.sh"
for n in $(seq 1 12); do
  d="$RUN/reviews/transition-$n"; rm -rf "$d"
  N platform transition plan --out "$d" --summary "$d.summary.json" > "$d.plan.log" 2>&1 || { tail -n 10 "$d.plan.log" | cut -c1-220 >&2; die "transition plan $n refused"; }
  ops="$(jq '.operations|length' "$d/review.json")"
  log "transition $n: $ops operations; $(jq -c '.' "$d.summary.json" | cut -c1-200)"
  jq -e '[.operations[]|(.operation//.)|.action.tag]|any(test("Delete|Retire|Replace"))' "$d/review.json" >/dev/null && die "transition $n holds a delete, retire or replace"
  if [ "$ops" = 0 ]; then break; fi
  N inventory apply "$d" --yes > "$d.apply.log" 2>&1 || { tail -n 10 "$d.apply.log" | cut -c1-220 >&2; die "transition apply $n did not converge"; }
  tail -n 1 "$d.apply.log" | cut -c1-110
done
N platform transition commit > "$RUN/evidence/transition-commit.log" 2>&1 || { tail -n 10 "$RUN/evidence/transition-commit.log" | cut -c1-220 >&2; die "transition commit refused"; }
tail -n 2 "$RUN/evidence/transition-commit.log" | cut -c1-160
