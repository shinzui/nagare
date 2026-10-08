#!/usr/bin/env bash
# Usage: retire-group.sh GROUP SCOPE... : plan one joint retirement, check it, apply it.
set -euo pipefail
t=/private/tmp/nagare-mp23-c3i/teardown-3ae20f8c
w=/private/tmp/nagare-mp23-c3i/runctl-3ae20f8c.sh
group=$1; shift
dir=$t/retire-$group
[ ! -e "$dir" ] || { echo "STOP: $dir exists"; exit 1; }
args=()
for s in "$@"; do args+=(--scope "$s"); done
s0=$(date +%s)
"$w" inventory retire "${args[@]}" --out "$dir" || { echo "STOP: retire plan refused ($group)"; exit 1; }
echo "plan $group seconds=$(( $(date +%s) - s0 ))"
jq -c '[.operations[].operation.action.tag] | group_by(.) | map({(.[0]): length}) | add' "$dir/review.json"
bad=$(jq -r '[.operations[].operation.action.tag | select(. != "RetireResource" and . != "VerifyResource")] | length' "$dir/review.json")
[ "$bad" = 0 ] || { echo "STOP: $bad operations other than Retire/Verify in $group"; exit 1; }
if jq -r '.operations[].summary' "$dir/review.json" | grep -E -i 'c3-1009|mp23-c3j|nagare-01|nix-builder-ep150'; then
  echo "STOP: foreign name in $group review"; exit 1
fi
s0=$(date +%s)
"$w" inventory apply "$dir" --yes || { echo "STOP: apply failed ($group)"; exit 1; }
echo "apply $group seconds=$(( $(date +%s) - s0 ))"
echo "GROUP-DONE $group"
