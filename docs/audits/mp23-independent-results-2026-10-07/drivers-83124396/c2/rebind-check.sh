#!/usr/bin/env bash
# C2 F80 native check: an application-scope member replaced outside review is reported
# replaced-incarnation, and the documented reviewed rebind (through the CLI) records it.
# The member is scenario-a's stateless backup-read Role (no data). Any member left `unrecorded`
# by a lost create response is rebound in the same pass. Stops at the first unexpected result.
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad
ROOT=$(cat $S/c2-root); REPO=$(cat $S/c2-repo); cd $ROOT
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml
K() { command kubectl --context local "$@"; }
D=$ROOT/reviews/rebind-check; mkdir -p $D
die() { echo "REBIND-CHECK FAILED: $*"; exit 1; }
[ "$(K get nodes -o name)" = node/k3d-nagare-local-server-0 ] || die "unexpected kube node"
RES=application:scenario-a/scenario-pg/backup-read-role
./runctl.sh inventory status --json > $D/status-0.json 2>/dev/null || die status0
jq -e --arg r $RES '[.findings[] | select(.resource==$r and .category=="converged")] | length == 1' $D/status-0.json >/dev/null || die "$RES not converged before the drill"
ADDR=$(jq -c --arg r $RES '.findings[] | select(.resource==$r) | .address.contents' $D/status-0.json)
NS=$(echo "$ADDR" | jq -r '.[3]'); NAME=$(echo "$ADDR" | jq -r '.[4]')
OLD=$(K -n $NS get role $NAME -o jsonpath='{.metadata.uid}') || die "read role"
K -n $NS get role $NAME -o json | jq 'del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields,.metadata.generation)' > $D/role.json
K replace --force -f $D/role.json > $D/replace.log 2>&1 || die "replace: $(tail -1 $D/replace.log)"
NEW=$(K -n $NS get role $NAME -o jsonpath='{.metadata.uid}')
[ "$NEW" != "$OLD" ] || die "role UID unchanged after replace"
echo "role $NS/$NAME replaced: $OLD -> $NEW"
./runctl.sh inventory status --json > $D/status-1.json 2>/dev/null || die status1
jq -e --arg r $RES --arg u $NEW '[.findings[] | select(.resource==$r and .category=="replaced-incarnation" and .physical==$u)] | length == 1' $D/status-1.json >/dev/null \
  || die "status does not report $RES as replaced-incarnation with $NEW: $(jq -c --arg r $RES '.findings[] | select(.resource==$r) | {category,physical}' $D/status-1.json)"
echo "status: replaced-incarnation $NEW"
# Rebind through the documented path, for every replaced or unrecorded member, one scope at a time.
jq -r '[.findings[] | select(.category=="replaced-incarnation" or .category=="unrecorded") | .owner | "\(.kind):\(.name)"] | unique[]' $D/status-1.json > $D/scopes.txt
while read -r scope; do
  n=$(echo "$scope" | tr ':' '-'); W=$D/$n; rm -rf $W; mkdir -p $W; X=$ROOT/evidence-private/rebind-check/$n-export
  ./runctl.sh inventory export --out $X > $W/export.log 2>&1 || die "$scope export: $(tail -1 $W/export.log)"
  python3 $REPO/scripts/unchanged-inventory-candidate.py $X $W/candidate.json "$scope" > $W/candidate.log 2>&1 || die "$scope candidate: $(tail -1 $W/candidate.log)"
  ./runctl.sh inventory compile --input $W/candidate.json --out $W/compiled > $W/compile.log 2>&1 || die "$scope compile: $(tail -1 $W/compile.log)"
  jq --arg c "$W/compiled" --arg k "${scope%%:*}" --arg nm "${scope#*:}" --argjson b "$(jq -c .binding $ROOT/state/nagare/local/inventory/head.json)" \
    '{version: 1, candidate: $c, binding: $b,
      resources: [.findings[] | select((.category=="unrecorded" or .category=="replaced-incarnation") and .owner.kind==$k and .owner.name==$nm)
                  | {resource, address, physicalIdentity: .physical, rebind: true}]}' $D/status-1.json > $W/proposal.json
  echo "$scope: rebinding $(jq -c '[.resources[].resource | split("/") | .[-1]]' $W/proposal.json)"
  ./runctl.sh inventory adopt --input $W/proposal.json --out $W/review > $W/adopt.log 2>&1 || die "$scope adopt: $(tail -2 $W/adopt.log | tr '\n' ' ')"
  ./runctl.sh inventory apply $W/review --yes > $W/apply.log 2>&1 || die "$scope apply: $(tail -2 $W/apply.log | tr '\n' ' ')"
  echo "$scope: $(tail -1 $W/apply.log)"
done < $D/scopes.txt
./runctl.sh inventory status --json > $D/status-2.json 2>/dev/null || die status2
jq -e --arg r $RES '[.findings[] | select(.resource==$r and .category=="converged")] | length == 1' $D/status-2.json >/dev/null || die "$RES not converged after the rebind"
left=$(jq '[.findings[] | select(.category=="unrecorded" or .category=="replaced-incarnation")] | length' $D/status-2.json)
[ "$left" = 0 ] || die "$left replaced or unrecorded member(s) remain"
echo "after rebind: $RES converged at $NEW; 0 replaced or unrecorded"
echo REBIND-CHECK-OK
