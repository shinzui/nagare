#!/usr/bin/env bash
# C3: rebind every `unrecorded` member through the documented reviewed rebind
# (inventory-operations.md "Replaced and unrecorded members"; F80), one scope at a time:
# export -> unchanged candidate -> compile -> adoption proposal with rebind -> adopt -> apply.
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; REPO=/private/tmp/nagare-cand-83124396-src; cd $ROOT
U=gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory
D=$ROOT/reviews/rebind; mkdir -p $D $ROOT/evidence-private/rebind
die() { echo "REBIND FAILED: $*"; exit 1; }
./runctl.sh inventory status --json > $D/status-before.json 2>/dev/null || die status
[ "$(jq -r .activeTransaction $D/status-before.json)" = null ] || die "active transaction"
jq -r '[.findings[] | select(.category=="unrecorded" or .category=="replaced-incarnation") | .owner | "\(.kind):\(.name)"] | unique[]' $D/status-before.json > $D/scopes.txt
echo "to rebind: $(jq -c '[.findings[] | select(.category=="unrecorded" or .category=="replaced-incarnation") | {resource, category}]' $D/status-before.json)"
[ -s $D/scopes.txt ] || { echo REBIND-OK; exit 0; }
B=$(CLOUDSDK_ACTIVE_CONFIG_NAME=labs gcloud storage cat $U/head.json | jq -c .binding)
while read -r scope; do
  n=$(echo "$scope" | tr ':' '-'); W=$D/$n; X=$ROOT/evidence-private/rebind/$n-export; rm -rf $W $X; mkdir -p $W
  ./runctl.sh inventory export --out $X > $W/export.log 2>&1 || die "$scope export: $(tail -1 $W/export.log)"
  python3 $REPO/scripts/unchanged-inventory-candidate.py $X $W/candidate.json "$scope" > $W/candidate.log 2>&1 || die "$scope candidate: $(tail -1 $W/candidate.log)"
  ./runctl.sh inventory compile --input $W/candidate.json --out $W/compiled > $W/compile.log 2>&1 || die "$scope compile: $(tail -1 $W/compile.log)"
  jq --arg c "$W/compiled" --arg k "${scope%%:*}" --arg nm "${scope#*:}" --argjson b "$B" \
    '{version: 1, candidate: $c, binding: $b,
      resources: [.findings[] | select((.category=="unrecorded" or .category=="replaced-incarnation") and .owner.kind==$k and .owner.name==$nm)
                  | {resource, address, physicalIdentity: .physical, rebind: true}]}' $D/status-before.json > $W/proposal.json
  ./runctl.sh inventory adopt --input $W/proposal.json --out $W/review > $W/adopt.log 2>&1 || die "$scope adopt: $(tail -2 $W/adopt.log | tr '\n' ' ')"
  echo "$scope review: $(jq -r '[.operations[].operation.action.tag] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' $W/review/review.json)"
  ./runctl.sh inventory apply $W/review --yes > $W/apply.log 2>&1 || die "$scope apply: $(tail -2 $W/apply.log | tr '\n' ' ')"
  echo "$scope: $(tail -1 $W/apply.log)"
done < $D/scopes.txt
./runctl.sh inventory status --json > $D/status-after.json 2>/dev/null
n=$(jq '[.findings[] | select(.category=="unrecorded" or .category=="replaced-incarnation")] | length' $D/status-after.json)
[ "$n" = 0 ] || die "$n replaced or unrecorded member(s) remain"
echo REBIND-OK
