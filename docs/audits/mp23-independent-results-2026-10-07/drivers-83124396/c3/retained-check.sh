#!/usr/bin/env bash
# C3 retained-data: collect scenario-retire's stateless companions in dependency order,
# show the PVC refuses collection, then export history and restore it into an isolated root.
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; RUN=$ROOT/runctl.sh; R=$ROOT/reviews; E=$ROOT/pending-evidence/retained-data; mkdir -p $E
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/mp23-c3m.yaml
K() { command kubectl --context mp23-c3m "$@"; }
die() { echo "RETAINED FAILED: $*"; exit 1; }
P=standalone:database-scenario-retire/scenario-retire
# Settle wait: every APIService Available and discovery stable for 15 s (C2 rule 7).
settle() { local prev="" same=0; for i in $(seq 1 60); do
  K get apiservices -o json | jq -e '[.items[] | .status.conditions[]? | select(.type=="Available") | .status] | all(. == "True")' >/dev/null || { same=0; sleep 3; continue; }
  cur=$(K api-resources --namespaced=true -o name 2>/dev/null | wc -l | tr -d ' '); if [ "$cur" = "$prev" ]; then same=$((same+3)); else same=0; prev=$cur; fi
  [ $same -ge 15 ] && return 0; sleep 3; done; die "discovery never settled"; }
K -n personal get statefulset,pvc -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers > $E/neighbors-before.txt
results='[]'; n=0
for group in "backup" "statefulset backup-read-binding" "service backup-read-role backup-account"; do
  n=$((n+1)); settle
  args=""; for m in $group; do args="$args --resource $P/$m"; done
  $RUN inventory collect $args --out $R/collect-retire-$n > $E/collect-$n-plan.log 2>&1 || die "collect $n plan: $(tail -1 $E/collect-$n-plan.log)"
  $RUN inventory apply $R/collect-retire-$n --yes > $E/collect-$n-apply.log 2>&1 || die "collect $n apply: $(tail -1 $E/collect-$n-apply.log)"
  results=$(jq -c --arg g "$group" --arg r "$(tail -1 $E/collect-$n-apply.log)" '. + [{members:($g|split(" ")), result:$r}]' <<<"$results")
done
$RUN inventory collect --resource $P/pvc --out $R/collect-retire-pvc > $E/pvc-plan.log 2>&1 && die "PVC collection unexpectedly planned"
K -n personal get statefulset,pvc -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers > $E/neighbors-after.txt
jq -n --argjson c "$results" --arg pvc "$(grep -o 'PlanError {[^}]*}' $E/pvc-plan.log | head -1)" '{database:"scenario-retire", collectedInOrder:$c, pvcCollection:{command:"inventory collect --resource '$P'/pvc --out DIR", output:$pvc}}' > $E/collection.json
# History export and clean-root restore into an isolated root.
$RUN inventory export --out $ROOT/evidence-private/retained-export > $E/export.log 2>&1 || die "export"
IR=$ROOT/history-restore-root; rm -rf $IR; mkdir -p $IR/config/nagare/contexts $IR/state $IR/cache; chmod 700 $IR
grep -v -E '^export NAGARE_INVENTORY_STORE(_URL)?=' $ROOT/config/nagare/contexts/mp23-c3m.env > $IR/config/nagare/contexts/mp23-c3m.env
printf 'export NAGARE_INVENTORY_STORE=local\nexport NAGARE_INVENTORY_STORE_URL=\n' >> $IR/config/nagare/contexts/mp23-c3m.env
IRUN() { env -i PATH="$PATH" HOME=$HOME XDG_CONFIG_HOME=$IR/config XDG_STATE_HOME=$IR/state XDG_CACHE_HOME=$IR/cache CLOUDSDK_ACTIVE_CONFIG_NAME=labs /private/tmp/result-83124396-nagare/bin/nagarectl --context mp23-c3m "$@"; }
IRUN inventory restore --from $ROOT/evidence-private/retained-export --yes > $E/restore.log 2>&1 || die "history restore: $(tail -1 $E/restore.log)"
python3 - "$ROOT/evidence-private/retained-export/head.json" "$IR/state/nagare/mp23-c3m/inventory/head.json" > $E/history-restore.json <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
keys = ["accepted", "converged", "retained", "collected", "binding"]
print(json.dumps({"command": "nagarectl inventory export, then inventory restore --from DIR --yes into an isolated local root",
  "identical": {k: a.get(k) == b.get(k) for k in keys}, "acceptedScopes": len(a.get("accepted") or []),
  "retained": len(a.get("retained") or {}), "collected": len(a.get("collected") or {})}, indent=2))
PY
jq -e '.identical | all' $E/history-restore.json > /dev/null || die "restored history differs: $(jq -c .identical $E/history-restore.json)"
echo "collected: $(jq -c '[.collectedInOrder[].members]' $E/collection.json); pvc refused: $(jq -r .pvcCollection.output $E/collection.json | cut -c1-80)"
