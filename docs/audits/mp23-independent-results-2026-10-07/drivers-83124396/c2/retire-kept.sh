#!/usr/bin/env bash
# C2: retire the scratch-restore scopes that close kept after the designed refusal drills
# (ADR 26: a scope in which anything took effect is kept, unconverged). This confirms F83 natively:
# a retirement with absence proofs is admitted through the CLI. The runner needs accepted == converged.
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad
ROOT=$(cat $S/c2-root); cd $ROOT
D=$ROOT/reviews/retire-kept; mkdir -p $D
die() { echo "RETIRE-KEPT FAILED: $*"; exit 1; }
./runctl.sh inventory status --json > $D/status-before.json 2>/dev/null || die status
[ "$(jq -r .activeTransaction $D/status-before.json)" = null ] || die "active transaction"
jq -r '([.converged[].scope | "\(.kind):\(.name)"]) as $c | [.accepted[].scope | "\(.kind):\(.name)" | select(. as $s | $c | index($s) | not)] | .[]' $D/status-before.json > $D/kept.txt
echo "kept, unconverged: $(tr '\n' ' ' < $D/kept.txt)"
grep -v '^Standalone:database-restore-' $D/kept.txt && die "an unconverged scope other than a scratch restore"
while read -r scope; do
  n=${scope#Standalone:}; W=$D/$n
  ./runctl.sh inventory retire --scope "standalone:$n" --out $W > $W.log 2>&1 || die "$n plan: $(tail -2 $W.log | tr '\n' ' ')"
  echo "$n: $(jq -r '"\(.operations|length) ops, \(.retentions|length) retained, \(.absences|length) absence proofs"' $W/review.json)"
  ./runctl.sh inventory apply $W --yes >> $W.log 2>&1 || die "$n apply: $(tail -2 $W.log | tr '\n' ' ')"
  echo "$n: $(tail -1 $W.log)"
done < $D/kept.txt
./runctl.sh inventory status --json > $D/status-after.json 2>/dev/null || die status-after
jq -e '(.accepted|length) == (.converged|length) and .activeTransaction == null' $D/status-after.json >/dev/null || die "accepted != converged after retirement"
echo "accepted == converged: $(jq '.accepted|length' $D/status-after.json)"
echo RETIRE-KEPT-OK
