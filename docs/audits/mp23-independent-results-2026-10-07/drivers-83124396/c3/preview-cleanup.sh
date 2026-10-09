#!/usr/bin/env bash
# C3 preview cleanup (convergence-noop-removal), the last scenario mutation: settle first
# (runbook section 6 rule 6), then reviewed preview cleanup rounds until no review remains.
set -uo pipefail
G=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; E=$G/pending-evidence/convergence-noop-removal; mkdir -p $E
export KUBECONFIG=$G/config/nagare/kubeconfigs/mp23-c3m.yaml
K() { command kubectl --context mp23-c3m "$@"; }
settle() { local prev="" same=0; for i in $(seq 1 80); do
  K get apiservices -o json | jq -e '[.items[] | .status.conditions[]? | select(.type=="Available") | .status] | all(. == "True")' > /dev/null || { same=0; sleep 3; continue; }
  cur=$(K api-resources --namespaced=true -o name 2>/dev/null | wc -l | tr -d ' '); if [ "$cur" = "$prev" ]; then same=$((same+3)); else same=0; prev=$cur; fi
  [ $same -ge 15 ] && return 0; sleep 3; done; echo "PREVIEW FAILED: discovery never settled"; exit 1; }
settle
K -n personal get domainmapping,ksvc,kingress,certificate -o custom-columns=KIND:.kind,NAME:.metadata.name --no-headers 2>/dev/null > $E/before.txt
for i in 1 2 3 4 5 6; do
  d=$G/reviews/preview-cleanup-$i
  $G/runctl.sh cleanup --previews --preview-ttl-days 0 -n personal --save-plan $d > $E/plan-$i.log 2>&1; code=$?
  if [ ! -f $d/review.json ]; then echo "round $i: no review ($code)"; break; fi
  echo "round $i: $(jq -r '[.operations[].operation.action.tag]|group_by(.)|map("\(.[0])=\(length)")|join(" ")' $d/review.json)"
  $G/runctl.sh inventory apply $d --yes > $E/apply-$i.log 2>&1 || { echo "PREVIEW FAILED: apply $i: $(tail -1 $E/apply-$i.log)"; exit 1; }
  echo "  $(tail -1 $E/apply-$i.log | cut -c1-100)"
done
K -n personal get domainmapping,ksvc,kingress,certificate -o custom-columns=KIND:.kind,NAME:.metadata.name --no-headers 2>/dev/null > $E/after.txt
grep -q pr-scenario $E/after.txt && { echo "PREVIEW FAILED: pr-scenario remains"; exit 1; }
echo PREVIEW-OK
