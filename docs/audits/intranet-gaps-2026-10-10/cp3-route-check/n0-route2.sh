#!/usr/bin/env bash
# EP-183 M1 on cp3: roll the fixed enforcer (0212a55e) through the saved bootstrap review, then route-check and its wrong-CA negative.
set -euo pipefail
W=/private/tmp/nagare-b9-ep183; ROOT=$(cat $W/n0-root); REPO=/Users/shinzui/Keikaku/bokuno/nagare
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml
R=$ROOT/reviews; die() { echo "N0 FAILED: $*"; exit 1; }
head_idle() { python3 -c "import json;assert json.load(open('$ROOT/state/nagare/local/inventory/head.json')).get('activeTransaction') is None"; }
head_idle || die "active transaction before start"
# rollout converged in the first run (tx-5971bda5…)

kubectl --context local -n nagare-system get ksvc nagare-access -o jsonpath='{.status.latestReadyRevisionName} {.spec.template.spec.containers[0].image}{"\n"}'
cd $REPO/.claude/worktrees/integrate-ep183
H() { cabal run --project-dir=cli/nagare-harness -v0 nagare-harness -- route-check --context local --kube-context local --nagarectl $ROOT/runctl-bare.sh --reviews $R/route-check-$1 --ingress-port-forward 18443 "${@:2}"; }
rm -rf $R/route-check-pos2 $R/route-check-neg2; mkdir -p $R/route-check-pos2 $R/route-check-neg2
set +e; H pos2 > $ROOT/evidence/route-check.txt 2>&1; rc=$?; set -e
cat $ROOT/evidence/route-check.txt; echo "route-check rc=$rc"; [ $rc -eq 0 ] || die "route-check"
set +e; H neg2 --ca /dev/null > $ROOT/evidence/route-check-wrong-ca.txt 2>&1; nrc=$?; set -e
tail -3 $ROOT/evidence/route-check-wrong-ca.txt; echo "wrong-ca rc=$nrc"; [ $nrc -ne 0 ] || die "wrong-CA run passed"
head_idle || die "active transaction at end"
echo "N0 ROUTE DONE"
