#!/usr/bin/env bash
# One bounded C3 bootstrap stage: plan (save review + safety checks) or apply.
# Usage: c3-stage.sh NAME plan|apply
set -euo pipefail
root=/Users/shinzui/.local/state/nagare-verify/mp23-c3m
name="$1"; phase="$2"
evidence="$root/evidence/$name"
run="$root/runctl.sh"
digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
case "$phase" in
  plan)
    [[ ! -e "$evidence" ]] || { echo "evidence $evidence exists" >&2; exit 1; }
    mkdir -m 700 -p "$evidence"
    start=$(date +%s)
    "$run" platform bootstrap plan --out "$evidence/review" > "$evidence/plan.stdout" 2> "$evidence/plan.stderr"
    echo "{\"exit\":0,\"seconds\":$(( $(date +%s) - start ))}" > "$evidence/plan.result.json"
    review="$evidence/review/review.json"
    jq -e '.operations | length > 0' "$review" > /dev/null || { echo "review has no operations" >&2; exit 1; }
    # Never touch standing project resources of tan-ng-labs.
    jq -e '[.operations[].summary | gsub("[0-9a-f]{8,}"; "")] | all((contains("nagare-node") or contains("tan-ng-labs-nagare-backups") or contains("tan-ng-labs-nagare-images") or contains("ep150") or contains("f15") or contains("c3-1003") or contains("c3-1004") or contains("c3p-1006") or contains("c3-1005") or contains("c3-1007") or contains("c3-1008") or contains("c3-1009") or contains("pmkjjpp") or contains("c3-1010") or contains("tbvezyx") or contains("c3-1011") or contains("oxwfiry")) | not)' "$review" > /dev/null \
      || { echo "review names a standing or retired fixture resource" >&2; exit 1; }
    if jq -e '[.operations[] | select(.operation.action.tag == "CreateResource") | .operation.resources[] | contains("/pulumi-stack/")] | any' "$review" > /dev/null; then
      cfg="$root/config/nagare/pulumi/Pulumi.mp23-c3m.yaml"
      [[ ! -s "$cfg" ]] || { echo "new stack has preexisting Pulumi config" >&2; exit 1; }
    fi
    jq -n --arg d "$(digest "$review")" '{state:"planned",reviewDigest:$d}' > "$evidence/stage.json"
    jq -r '.operations | group_by(.operation.action.tag) | map("\(.[0].operation.action.tag)=\(length)") | join(" ")' "$review"
    ;;
  apply)
    jq -e --arg d "$(digest "$evidence/review/review.json")" '.state == "planned" and .reviewDigest == $d' "$evidence/stage.json" > /dev/null \
      || { echo "saved review is not the planned review" >&2; exit 1; }
    jq '.state="applying"' "$evidence/stage.json" > "$evidence/stage.tmp" && mv "$evidence/stage.tmp" "$evidence/stage.json"
    start=$(date +%s)
    set +e
    "$run" platform bootstrap apply "$evidence/review" --yes > "$evidence/apply.stdout" 2> "$evidence/apply.stderr"
    code=$?
    set -e
    echo "{\"exit\":$code,\"seconds\":$(( $(date +%s) - start ))}" > "$evidence/apply.result.json"
    if [[ $code -eq 0 ]]; then
      jq '.state="applied"' "$evidence/stage.json" > "$evidence/stage.tmp" && mv "$evidence/stage.tmp" "$evidence/stage.json"
    fi
    tail -3 "$evidence/apply.stdout"; tail -5 "$evidence/apply.stderr"
    exit $code
    ;;
  *) echo "phase must be plan or apply" >&2; exit 2 ;;
esac
