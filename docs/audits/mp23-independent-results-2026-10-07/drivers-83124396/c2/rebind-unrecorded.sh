#!/usr/bin/env bash
# C2 checkpoint (candidate 83124396): rebind every `unrecorded` member through the documented
# reviewed rebind (inventory-operations.md "Replaced and unrecorded members"), scope by scope:
# export -> unchanged candidate -> compile -> adoption proposal with rebind -> adopt -> apply.
# DRY=1 stops after saving each review. Stops at the first refusal.
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad
ROOT=$(cat $S/c2-root); REPO=/private/tmp/nagare-cand-83124396-src; cd $ROOT
D=$ROOT/reviews/rebind; mkdir -p $D
die() { echo "REBIND FAILED: $*"; exit 1; }
./runctl.sh inventory status --json > $D/status-before.json 2>/dev/null || die "status"
[ "$(jq -r .activeTransaction $D/status-before.json)" = null ] || die "active transaction"
[ -n "${SCOPES_FILE:-}" ] && cp "$SCOPES_FILE" $D/scopes.txt || jq -r '[.findings[] | select(.category=="unrecorded") | .owner | "\(.kind):\(.name)"] | unique[]' $D/status-before.json > $D/scopes.txt
[ -s $D/scopes.txt ] || { echo "nothing unrecorded"; echo REBIND-OK; exit 0; }
while read -r scope; do
  n=$(echo "$scope" | tr ':' '-'); W=$D/$n; rm -rf $W; mkdir -p $W
  ./runctl.sh inventory export --out $W/export > $W/export.log 2>&1 || die "$scope export: $(tail -1 $W/export.log)"
  python3 $REPO/scripts/unchanged-inventory-candidate.py $W/export $W/candidate.json "$scope" > $W/candidate.log 2>&1 || die "$scope candidate: $(tail -1 $W/candidate.log)"
  ./runctl.sh inventory compile --input $W/candidate.json --out $W/compiled > $W/compile.log 2>&1 || die "$scope compile: $(tail -1 $W/compile.log)"
  jq --arg c "$W/compiled" --arg k "${scope%%:*}" --arg nm "${scope#*:}" --argjson b "$(jq -c .binding $ROOT/state/nagare/local/inventory/head.json)" \
    '{version: 1, candidate: $c, binding: $b,
      resources: [.findings[] | select(.category=="unrecorded" and .owner.kind==$k and .owner.name==$nm)
                  | {resource, address, physicalIdentity: .physical, rebind: true}]}' $D/status-before.json > $W/proposal.json
  echo "$scope: $(jq '.resources|length' $W/proposal.json) member(s)"
  ./runctl.sh inventory adopt --input $W/proposal.json --out $W/review > $W/adopt.log 2>&1 || die "$scope adopt: $(tail -2 $W/adopt.log | tr '\n' ' ')"
  jq -r '[.operations[].operation.action.tag] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' $W/review/review.json
  [ "${DRY:-0}" = 1 ] && continue
  ./runctl.sh inventory apply $W/review --yes > $W/apply.log 2>&1 || die "$scope apply: $(tail -2 $W/apply.log | tr '\n' ' ')"
  echo "$scope applied: $(tail -1 $W/apply.log)"
done < $D/scopes.txt
./runctl.sh inventory status --json > $D/status-after.json 2>/dev/null
echo "unrecorded after: $(jq '[.findings[] | select(.category=="unrecorded")] | length' $D/status-after.json)"
echo REBIND-OK
