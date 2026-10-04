#!/usr/bin/env bash
# C2 phase 2 driver: scenario resources, interruptions, seeds, runner plan/apply.
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad
ROOT=$(cat $S/c2-root); REPO=/Users/shinzui/Keikaku/bokuno/nagare; F=$REPO/fixtures/inventory-release/local/apps
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
source $ROOT/images.env
R=$ROOT/reviews; P=$ROOT/pending-evidence/interrupted-recovery; mkdir -p $P $ROOT/pending-evidence/seed
K() { command kubectl --context local "$@"; }
die() { echo "PHASE2 FAILED: $*"; exit 1; }
step() { echo "== $(date -u +%H:%M:%S) $*"; }
plan_apply() { # name, then plan command...
  local name=$1; shift
  "$@" --save-plan $R/$name > $R/$name.log 2>&1 || die "$name plan: $(tail -1 $R/$name.log)"
  $ROOT/runctl.sh inventory apply $R/$name --yes >> $R/$name.log 2>&1 || die "$name apply: $(tail -1 $R/$name.log)"
  echo "$name: $(tail -1 $R/$name.log)"
}
cd $ROOT
step data
for spec in "clickhouse scenario-ch" "postgres scenario-rename-src" "postgres scenario-retire"; do
  eng=${spec%% *}; name=${spec#* }
  plan_apply create-$name ./runctl.sh db create $eng $name --size 1Gi --recovery-backup $name --recovery-key-version v1
done
plan_apply create-scenario-events ./runctl.sh broker create redpanda scenario-events --namespace personal --size 1Gi --recovery-backup scenario-events --recovery-key scenario-events-key --recovery-key-version v1
plan_apply topic-jobs ./runctl.sh broker create redpanda scenario-events --namespace personal --size 1Gi --topic jobs --recovery-backup scenario-events --recovery-key scenario-events-key --recovery-key-version v1
step images
for app in scenario-a scenario-b scenario-site; do
  ./runctl.sh app image-plan --archive "$ROOT/images/${app}.tar" --destination "k3d-registry.localhost:5000/${app}:c2" --key "${app}-c2" --save-plan "$R/image-${app}" > "$R/image-${app}.log" 2>&1 || die "image $app plan"
  ./runctl.sh inventory apply "$R/image-${app}" --yes >> "$R/image-${app}.log" 2>&1 || die "image $app apply"
  echo "image $app: $(tail -1 $R/image-$app.log)"
done
step secret-a
(umask 077; python3 -c "import secrets; print(secrets.token_urlsafe(32), end='')" > $ROOT/evidence-private/scenario-api-token; shasum -a 256 $ROOT/evidence-private/scenario-api-token | cut -c1-64 > $ROOT/evidence-private/scenario-api-token.sha256)
./runctl.sh secret set scenario-a -f $F/scenario-a/nagare/Config.hs --runtime SCENARIO_API_TOKEN --version c2v1 --save-plan $R/secret-a < $ROOT/evidence-private/scenario-api-token > $R/secret-a.log 2>&1 || die "secret plan"
./runctl.sh inventory apply $R/secret-a --yes >> $R/secret-a.log 2>&1 || die "secret apply"
step deploy-a
./runctl.sh app deploy -f $F/scenario-a/nagare/Config.hs --tag c2 --image-resource publication:app-image-scenario-a-c2/scenario-a-c2/oci-image --database-recovery scenario-pg=scenario-pg:v1 --service-volume-recovery uploads=scenario-a-uploads:scenario-a-uploads-key:v1 --hook-no-data-effects scenario-a-report --env-secret-resource application:secret-scenario-a-runtime/runtime-secret/secret --save-plan $R/deploy-a > $R/deploy-a.log 2>&1 || die "deploy-a plan: $(tail -1 $R/deploy-a.log)"
./runctl.sh inventory apply $R/deploy-a --yes > $R/deploy-a-apply.log 2>&1 & pid=$!; killed=""
for i in $(seq 1 240); do st=$(K -n personal get statefulset scenario-pg -o jsonpath='{.metadata.uid} {.status.readyReplicas}' 2>/dev/null); if [ -n "$st" ] && [ "${st#* }" != "1" ]; then kill -9 $pid; killed=$(date -u +%H:%M:%S); break; fi; kill -0 $pid 2>/dev/null || break; sleep 0.5; done; wait $pid 2>/dev/null
echo "deploy-a killed=${killed:-none}"; [ -n "$killed" ] || die "deploy-a not interrupted"
./runctl.sh inventory status --json > $P/database-readiness-status.json
K -n personal get statefulset,pvc,secret -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers 2>/dev/null | grep -E 'scenario-(pg|a)' > $P/database-readiness-uids-before.txt
TX=$(python3 -c "import json;print(json.load(open('$P/database-readiness-status.json'))['activeTransaction'])")
./runctl.sh inventory resume $TX --yes > $P/database-readiness-resume.log 2>&1 || die "deploy-a resume: $(tail -1 $P/database-readiness-resume.log)"
K -n personal get statefulset,pvc,secret -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers 2>/dev/null | grep -E 'scenario-(pg|a)' > $P/database-readiness-uids-after.txt
echo "deploy-a: $(tail -1 $P/database-readiness-resume.log)"
step deploy-b
./runctl.sh app deploy -f $F/scenario-b/nagare/Config.hs --tag c2 --image-resource publication:app-image-scenario-b-c2/scenario-b-c2/oci-image --database-recovery scenario-redis=scenario-redis:v1 --save-plan $R/deploy-b > $R/deploy-b.log 2>&1 || die "deploy-b plan"
./runctl.sh inventory apply $R/deploy-b --yes > $R/deploy-b-apply.log 2>&1 & pid=$!; killed=""
for i in $(seq 1 600); do st=$(K -n personal get ksvc scenario-b -o jsonpath='{.metadata.uid} {.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null); if [ -n "$st" ] && [ "${st#* }" != "True" ]; then kill -9 $pid; killed=$(date -u +%H:%M:%S); break; fi; kill -0 $pid 2>/dev/null || break; sleep 0.3; done; wait $pid 2>/dev/null
echo "deploy-b killed=${killed:-none}"; [ -n "$killed" ] || die "deploy-b not interrupted"
./runctl.sh inventory status --json > $P/cluster-completion-status.json
K -n personal get ksvc,statefulset,pvc -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers 2>/dev/null | grep -E 'scenario-(b|redis)' > $P/cluster-completion-uids-before.txt
TX=$(python3 -c "import json;print(json.load(open('$P/cluster-completion-status.json'))['activeTransaction'])")
./runctl.sh inventory resume $TX --yes > $P/cluster-completion-resume.log 2>&1 || die "deploy-b resume: $(tail -1 $P/cluster-completion-resume.log)"
K -n personal get ksvc,statefulset,pvc -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers 2>/dev/null | grep -E 'scenario-(b|redis)' > $P/cluster-completion-uids-after.txt
echo "deploy-b: $(tail -1 $P/cluster-completion-resume.log)"
step site
FS=$F/scenario-site
plan_apply site ./runctl.sh site deploy -f $FS/nagare/Config.hs -C $FS --skip-build --tag c2 --image-resource publication:app-image-scenario-site-c2/scenario-site-c2/oci-image
for scope in runtime preview; do
  plan_apply site-env-$scope ./runctl.sh env set scenario-site -f $FS/nagare/Config.hs --$scope SCENARIO_SITE_MODE c2-$scope --reviewed
  (umask 077; python3 -c "import secrets; print(secrets.token_urlsafe(24), end='')" | ./runctl.sh secret set scenario-site -f $FS/nagare/Config.hs --$scope SCENARIO_SITE_TOKEN --version c2v1 --save-plan $R/site-secret-$scope > $R/site-secret-$scope.log 2>&1) || die "site secret $scope plan"
  ./runctl.sh inventory apply $R/site-secret-$scope --yes >> $R/site-secret-$scope.log 2>&1 || die "site secret $scope apply"
done
plan_apply preview ./runctl.sh site preview deploy -f $FS/nagare/Config.hs -C $FS --name pr-scenario --skip-build --tag c2 --image-resource publication:app-image-scenario-site-c2/scenario-site-c2/oci-image --preview-env-resource application:env-scenario-site-runtime/runtime-env/configmap --preview-env-resource application:secret-scenario-site-runtime/runtime-secret/secret --preview-env-resource application:env-scenario-site-preview/preview-env/configmap --preview-env-resource application:secret-scenario-site-preview/preview-secret/secret
step seeds
SP=$ROOT/pending-evidence/seed
K -n personal exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q -c "create table scenario_known(id int primary key, v text); insert into scenario_known values (1, '"'"'scenario-pg-row-1'"'"'), (2, '"'"'scenario-pg-row-2'"'"');" && psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||'"'"'|'"'"'||v from scenario_known order by id"' > $SP/postgresql.txt 2>&1
K -n personal exec scenario-rename-src-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q -c "create table scenario_rename(id int primary key, v text); insert into scenario_rename values (1, '"'"'scenario-rename-row-1'"'"'), (2, '"'"'scenario-rename-row-2'"'"'), (3, '"'"'scenario-rename-row-3'"'"');" && psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||'"'"'|'"'"'||v from scenario_rename order by id"' > $SP/rename.txt 2>&1
K -n personal exec scenario-redis-0 -c redis -- sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" SET scenario:known:1 scenario-redis-value-1 >/dev/null && redis-cli --no-auth-warning -a "$REDIS_PASSWORD" SET scenario:known:2 scenario-redis-value-2 >/dev/null && redis-cli --no-auth-warning -a "$REDIS_PASSWORD" MGET scenario:known:1 scenario:known:2' > $SP/redis.txt 2>&1
K -n personal exec scenario-ch-0 -- sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery -q "create table scenario_events (id UInt32, v String) engine = MergeTree order by id; insert into scenario_events values (1, '"'"'scenario-ch-row-1'"'"'), (2, '"'"'scenario-ch-row-2'"'"');" && clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "select concat(toString(id), '"'"'|'"'"', v) from scenario_events order by id"' > $SP/clickhouse.txt 2>&1
POD=$(K -n personal get pods -l serving.knative.dev/service=scenario-a -o jsonpath='{.items[0].metadata.name}')
K -n personal exec $POD -c user-container -- sh -c 'printf mp23-local-scenario-volume > /uploads/scenario-known.txt && sha256sum /uploads/scenario-known.txt' > $SP/volume.txt 2>&1
for f in postgresql rename redis clickhouse volume; do echo "seed $f: $(tr '\n' ' ' < $SP/$f.txt)"; done
mkdir -p $ROOT/evidence; EV=$ROOT/evidence/c2-7596632c-staging; mkdir -p $EV/checks; echo $EV > $S/c2-ev
: > /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/c2-7596/record-queue.txt
step PHASE2-OK
