#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
n="$1"; review="$RUN/reviews/s$n"; [ ! -e "$review" ] || rm -rf "$review" "$review.plan.log"
st="$(gcloud compute instances describe nix-builder-x86 --project "$PROJECT" --zone us-west1-a --format='value(status)')"
if [ "$st" != RUNNING ]; then
  for _ in $(seq 1 18); do st="$(gcloud compute instances describe nix-builder-x86 --project "$PROJECT" --zone us-west1-a --format='value(status)')"; [ "$st" = TERMINATED ] || [ "$st" = RUNNING ] && break; sleep 10; done
  [ "$st" = RUNNING ] || { gcloud compute instances start nix-builder-x86 --project "$PROJECT" --zone us-west1-a --quiet >/dev/null 2>&1; sleep 30; }
fi
N platform bootstrap plan --out "$review" > "$review.plan.log" 2>&1 || { tail -n 14 "$review.plan.log" | cut -c1-230 >&2; die "plan $n refused"; }
j="$review/review.json"
log "plan $n: $(jq '.operations|length' "$j") operations; changed scopes: $(jq -r '[.baseRevisions as $b | .desiredRevisions[] | . as $d | select(($b|map(select(.scope==$d.scope))|.[0].revision.digest) != $d.revision.digest) | .scope.name]|join(",")' "$j" | cut -c1-150)"
jq -r '.operations[]|(.operation//.)|"\(.action.tag)\t\(.executor//.plannedExecutor)"' "$j" | sort | uniq -c | cut -c1-70
