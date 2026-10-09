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

echo "== rebind unrecorded (lost create responses, ADR 27 §3 / F80)"; bash $ROOT/rebind-unrecorded.sh || die "rebind"
step collision-refusal; E=$PE/collision-refusal
H0=$(head_json); $RUN app deploy -f $F/scenario-collision/nagare/Config.hs --tag c3 --image-resource publication:app-image-scenario-b-c3/scenario-b-c3/oci-image --save-plan $R/collision > $E/plan.log 2>&1; code=$?; H1=$(head_json)
jq -n --arg h0 "$H0" --arg h1 "$H1" --argjson code $code --arg out "$(grep -o 'PlanError {[^}]*}\|code = "[^"]*"' $E/plan.log | head -3 | tr '\n' ' ')" '{command:"nagarectl app deploy -f apps/scenario-collision/nagare/Config.hs --save-plan DIR", exitCode:$code, refusal:$out, reviewSaved:false, headBefore:($h0|fromjson), headAfter:($h1|fromjson)}' > $E/result.json
[ $code -ne 0 ] && [ ! -e $R/collision/review.json ] && [ "$H0" = "$H1" ] || die collision; echo "collision: refused, head unchanged"

step independent-scope-preservation; E=$PE/independent-scope-preservation
snap() { gcloud storage cat $U/head.json | jq -c '[.accepted[] | select(.scope.kind=="Application") | {s:.scope.name, d:.revision.digest, g:.revision.generation}]'; }
S0=$(snap); B0=$(K -n personal get ksvc scenario-b -o jsonpath='{.metadata.uid}')
plan_apply env-a $RUN env set scenario-a -f $F/scenario-a/nagare/Config.hs --runtime SCENARIO_MODE updated --reviewed
S1=$(snap); B1=$(K -n personal get ksvc scenario-b -o jsonpath='{.metadata.uid}')
jq -n --argjson s0 "$S0" --argjson s1 "$S1" --arg b0 "$B0" --arg b1 "$B1" '{command:"nagarectl env set scenario-a --runtime SCENARIO_MODE updated --reviewed", scopesBefore:$s0, scopesAfter:$s1, scenarioBUidBefore:$b0, scenarioBUidAfter:$b1, scenarioBUnchanged:(([$s0[]|select(.s=="scenario-b")]==[$s1[]|select(.s=="scenario-b")]) and $b0==$b1)}' > $E/result.json
jq -e .scenarioBUnchanged $E/result.json >/dev/null || die "independent scope"; echo "independent scope: scenario-b unchanged"

step drift-classification; E=$PE/drift-classification
plan_apply retire-db $RUN db retire scenario-retire
K -n personal get ksvc scenario-b -o json | jq '{uid:.metadata.uid, maxScale:.spec.template.metadata.annotations["autoscaling.knative.dev/max-scale"]}' > $E/ksvc-before.json
K -n personal patch ksvc scenario-b --type merge -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/max-scale":"5"}}}}}' >/dev/null 2>&1
$RUN inventory status --json > $E/status-drift.json 2>/dev/null
jq -e '[.findings[] | select(.category=="configuration-drift") | .resource] == ["application:scenario-b/scenario-b/service"]' $E/status-drift.json >/dev/null || die "drift classification"
${DEPB} --save-plan $R/drift-strict > $E/strict-plan.log 2>&1 || die "strict plan"
$RUN inventory apply $R/drift-strict --yes > $E/strict-apply.log 2>&1 && die "strict apply unexpectedly converged"
$RUN inventory status --json > $E/status-after-refusal.json 2>/dev/null
TX=$(jq -r .activeTransaction $E/status-after-refusal.json); OP=$(jq -r '.transactionStatus.operations[] | select(.state!="completed") | .operation' $E/status-after-refusal.json | head -1)
printf '{"version":1,"transaction":"%s","operation":"%s","review":"%s","action":"abandon-refused-operation"}\n' $TX $OP ${TX#tx-} > $E/decision.json
$RUN inventory recover $TX --operation $OP --decision $E/decision.json > $E/recover.log 2>&1 || die "abandon: $(tail -1 $E/recover.log)"
${DEPB} --take-over-fields --save-plan $R/drift-takeover > $E/takeover-plan.log 2>&1 || die "takeover plan"
$RUN inventory apply $R/drift-takeover --yes > $E/takeover-apply.log 2>&1 || die "takeover apply"
K -n personal get ksvc scenario-b -o json --show-managed-fields | jq '{uid:.metadata.uid, maxScale:.spec.template.metadata.annotations["autoscaling.knative.dev/max-scale"], managers:([.metadata.managedFields[]?.manager]|unique)}' > $E/ksvc-after.json
echo "drift: $(grep -o 'KnownNoEffect[^]]*' $E/strict-apply.log | head -1 | cut -c1-90); after=$(jq -c . $E/ksvc-after.json)"

step postgresql-backup-restore; E=$PE/postgresql-backup-restore
plan_apply pg-backup $RUN db backup scenario-pg --backup-id c3gpg1
K -n personal exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -c "insert into scenario_known values (3, '"'"'after-backup'"'"') on conflict do nothing;"' >/dev/null
plan_apply pg-restore $RUN db restore scenario-pg c3gpg1 --restore-id c3gpgr1
K -n personal exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "scenario-pg_restore_c3gpgr1" -tA -c "select id||'"'"'|'"'"'||v from scenario_known order by id"' > $E/scratch-rows.txt
K -n personal exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||'"'"'|'"'"'||v from scenario_known order by id"' > $E/live-rows.txt
[ "$(cat $E/scratch-rows.txt)" = "$(printf '1|scenario-pg-row-1\n2|scenario-pg-row-2')" ] || die "pg scratch rows"; echo "pg: scratch 1-2, live has row 3"

step redis-backup-restore; E=$PE/redis-backup-restore
plan_apply redis-backup $RUN db backup scenario-redis --backup-id c3grd1
plan_apply redis-restore $RUN db restore scenario-redis c3grd1 --restore-id c3grdr1
K -n personal rollout status statefulset/scenario-redis-restore-c3grdr1 --timeout=300s >/dev/null 2>&1
K -n personal exec scenario-redis-restore-c3grdr1-0 -c redis -- sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" MGET scenario:known:1 scenario:known:2' > $E/scratch-keys.txt 2>&1
grep -q scenario-redis-value-2 $E/scratch-keys.txt || die "redis scratch keys"; echo "redis: scratch keys restored"

step clickhouse-backup-restore; E=$PE/clickhouse-backup-restore
plan_apply ch-backup $RUN db backup scenario-ch --backup-id c3gch1
plan_apply ch-restore $RUN db restore scenario-ch c3gch1 --restore-id c3gchr1
K -n personal exec scenario-ch-0 -- sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "select concat(toString(id), '"'"'|'"'"', v) from \`scenario-ch_restore_c3gchr1\`.scenario_events order by id"' > $E/scratch-rows.txt 2>&1
grep -q "2|scenario-ch-row-2" $E/scratch-rows.txt || die "clickhouse scratch rows: $(head -2 $E/scratch-rows.txt)"; echo "clickhouse: scratch rows restored"

step volume-backup-restore; E=$PE/volume-backup-restore
plan_apply vol-snap $RUN storage snapshot scenario-a -f $ROOT/projection/nagare/Config.hs uploads --snapshot-id c3gvol1
POD=$(K -n personal get pods -l serving.knative.dev/service=scenario-a -o jsonpath='{.items[0].metadata.name}')
K -n personal exec $POD -c user-container -- sh -c 'echo changed-after-snapshot > /uploads/scenario-known.txt'
plan_apply vol-restore $RUN storage restore scenario-a -f $ROOT/projection/nagare/Config.hs uploads c3gvol1 --restore-id c3gvolr1
J=$(K -n personal get pods -o name | grep c3gvolr1 | head -1); K -n personal logs $J 2>/dev/null | grep NAGARE_VOLUME_RESTORE > $E/manifest.txt
grep -q be6a2310d65b391f582af08cd1d6eea37c1857fa75bae29ff624f74d1963a927 $E/manifest.txt || die "volume manifest"; echo "volume: restored snapshot-time file"

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
