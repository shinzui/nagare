#!/usr/bin/env bash
# EP-183 M1 on cp3: deploy scenario-a on the fresh N0 context, then route-check and its wrong-CA negative.
set -euo pipefail
W=/private/tmp/nagare-b9-ep183; ROOT=$(cat $W/n0-root); REPO=/Users/shinzui/Keikaku/bokuno/nagare
F=$REPO/fixtures/inventory-release/local/apps; C2=/private/tmp/nagare-mp23-c2-83124396.PqNDSb
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
R=$ROOT/reviews; mkdir -p $ROOT/evidence-private $ROOT/evidence; cd $ROOT
die() { echo "N0 FAILED: $*"; exit 1; }
step() { echo "== $(date -u +%H:%M:%S) $*"; }
plan_apply() { local name=$1; shift
  "$@" --save-plan $R/$name > $R/$name.log 2>&1 || die "$name plan: $(tail -1 $R/$name.log)"
  ./runctl.sh inventory apply $R/$name --yes >> $R/$name.log 2>&1 || die "$name apply: $(tail -1 $R/$name.log)"
  echo "$name: $(tail -1 $R/$name.log)"; }
python3 -c "import json;assert json.load(open('$ROOT/state/nagare/local/inventory/head.json')).get('activeTransaction') is None" || die "active transaction before start"
step image
plan_apply image-scenario-a ./runctl.sh app image-plan --archive "$C2/images/scenario-a.tar" --destination "k3d-registry.localhost:5000/scenario-a:n0" --key scenario-a-n0
step secret-a
[ -f $ROOT/evidence-private/scenario-api-token ] || (umask 077; python3 -c "import secrets; print(secrets.token_urlsafe(32), end='')" > $ROOT/evidence-private/scenario-api-token)
./runctl.sh secret set scenario-a -f $F/scenario-a/nagare/Config.hs --runtime SCENARIO_API_TOKEN --version n0v1 --save-plan $R/secret-a < $ROOT/evidence-private/scenario-api-token > $R/secret-a.log 2>&1 || die "secret plan: $(tail -1 $R/secret-a.log)"
./runctl.sh inventory apply $R/secret-a --yes >> $R/secret-a.log 2>&1 || die "secret apply: $(tail -1 $R/secret-a.log)"
echo "secret-a: $(tail -1 $R/secret-a.log)"
step deploy-a
plan_apply deploy-a ./runctl.sh app deploy -f $F/scenario-a/nagare/Config.hs --tag n0 --image-resource publication:app-image-scenario-a-n0/scenario-a-n0/oci-image --database-recovery scenario-pg=scenario-pg:v1 --service-volume-recovery uploads=scenario-a-uploads:scenario-a-uploads-key:v1 --hook-no-data-effects scenario-a-report --env-secret-resource application:secret-scenario-a-runtime/runtime-secret/secret
step route-check
cd $REPO/.claude/worktrees/integrate-ep183
H() { cabal run --project-dir=cli/nagare-harness -v0 nagare-harness -- route-check --context local --kube-context local --nagarectl $ROOT/runctl-bare.sh --reviews $R/route-check-$1 --ingress-port-forward 18443 "${@:2}"; }
mkdir -p $R/route-check-pos $R/route-check-neg
H pos 2>&1 | tee $ROOT/evidence/route-check.txt; rc=${PIPESTATUS[0]}; echo "route-check rc=$rc"; [ $rc -eq 0 ] || die "route-check"
set +e; H neg --ca /dev/null > $ROOT/evidence/route-check-wrong-ca.txt 2>&1; nrc=$?; set -e
tail -3 $ROOT/evidence/route-check-wrong-ca.txt; echo "wrong-ca rc=$nrc"; [ $nrc -ne 0 ] || die "wrong-CA run passed"
python3 -c "import json;assert json.load(open('$ROOT/state/nagare/local/inventory/head.json')).get('activeTransaction') is None" || die "active transaction at end"
echo "N0 ROUTE DONE"
