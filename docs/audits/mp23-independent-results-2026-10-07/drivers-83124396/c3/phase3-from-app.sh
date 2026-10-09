#!/usr/bin/env bash
# C3 phase 3: cluster-generic release checks on mp23-c3m, evidence under pending-evidence/<check>/.
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; REPO=/private/tmp/nagare-cand-83124396-src
F=$REPO/fixtures/inventory-release/gcp/apps
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/mp23-c3m.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs
R=$ROOT/reviews; PE=$ROOT/pending-evidence; RUN=$ROOT/runctl.sh
U=gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory
K() { command kubectl --context mp23-c3m "$@"; }
die() { echo "PHASE3 FAILED: $*"; exit 1; }
step() { echo "== $(date -u +%H:%M:%S) $*"; mkdir -p "$PE/$1"; }
head_json() { gcloud storage cat $U/head.json | jq -c '{generation,sequence,activeTransaction}'; }
plan_apply() { local name=$1; shift; [ -e "$R/$name.done" ] && return 0
  "$@" --save-plan $R/$name > $R/$name.log 2>&1 || die "$name plan: $(tail -1 $R/$name.log)"
  $RUN inventory apply $R/$name --yes >> $R/$name.log 2>&1 || die "$name apply: $(tail -1 $R/$name.log)"
  touch $R/$name.done; echo "$name: $(tail -1 $R/$name.log)"; }
DEPB="$RUN app deploy -f $F/scenario-b/nagare/Config.hs --tag c3 --image-resource publication:app-image-scenario-b-c3/scenario-b-c3/oci-image --database-recovery scenario-redis=scenario-redis:v1"
DEPA_ARGS="--database-recovery scenario-pg=scenario-pg:v1 --service-volume-recovery uploads=scenario-a-uploads:scenario-a-uploads-key:v1 --hook-no-data-effects scenario-a-report --env-secret-resource application:secret-scenario-a-runtime/runtime-secret/secret"

# Continuation after F88: the refused deploy-a-c3b was closed (no effect); resume at application-change.
step application-change; E=$PE/application-change
plan_apply image-scenario-a-c3b $RUN app image-plan --archive $ROOT/images/scenario-a-c3b.tar --destination us-west1-docker.pkg.dev/tan-ng-labs/nagare-c3-1012/scenario-a:c3b --key scenario-a-c3b
plan_apply deploy-a-c3b $RUN app deploy -f $F/scenario-a/nagare/Config.hs --tag c3b --image-resource publication:app-image-scenario-a-c3b/scenario-a-c3b/oci-image $DEPA_ARGS
$RUN app deploy -f $F/scenario-a/nagare/Config.hs --tag c3b --image-resource publication:app-image-scenario-a-c3b/scenario-a-c3b/oci-image $DEPA_ARGS --save-plan $R/deploy-a-c3b-replay > $E/replay.log 2>&1 || die "replay plan"
jq -c '{changeOps:([.operations[].operation.action.tag]|group_by(.)|map({(.[0]):length})|add)}' $R/deploy-a-c3b/review.json > $E/change.json
jq -c '{replayOps:(.operations|length)}' $R/deploy-a-c3b-replay/review.json > $E/replay.json
[ "$(jq -r .replayOps $E/replay.json)" = 0 ] || die "replay not empty"; echo "application change: $(cat $E/change.json) replay $(cat $E/replay.json)"

step adoption; E=$PE/adoption
cat > $E/pvc.yaml <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: scenario-redis-restore-c3gadopt, namespace: personal}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
YAML
K apply -f $E/pvc.yaml >/dev/null; UID_=$(K -n personal get pvc scenario-redis-restore-c3gadopt -o jsonpath='{.metadata.uid}')
$RUN db restore scenario-redis c3grd1 --restore-id c3gadopt --save-plan $R/adopt > $E/plan.log 2>&1; code=$?
[ $code -ne 0 ] && grep -q adoption-required $E/plan.log || die "adoption refusal"
K -n personal delete pvc scenario-redis-restore-c3gadopt --wait=false >/dev/null 2>&1
jq -n --arg uid "$UID_" --arg out "$(grep -o 'PlanError {[^}]*}' $E/plan.log | head -1)" '{command:"nagarectl db restore scenario-redis c3grd1 --restore-id c3gadopt --save-plan DIR", foreignObject:{kind:"PersistentVolumeClaim",name:"scenario-redis-restore-c3gadopt",uid:$uid,createdBeforePlanning:true}, refusal:$out, reviewSaved:false}' > $E/refusal.json
echo "adoption: refused adoption-required"

step backup-freshness; E=$PE/backup-freshness
$RUN db backup-receipts scenario-pg --check-freshness > $E/receipts.txt 2>&1 || die "freshness"; $RUN server status > $E/server-status.txt 2>&1
grep -h "Recovery-point freshness" $E/receipts.txt | head -1
step PHASE3-OK
