#!/usr/bin/env bash
# C3 phase 2b (after the shared-history takeover): site, env, preview, seeds.
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; REPO=/private/tmp/nagare-cand-83124396-src
F=$REPO/fixtures/inventory-release/gcp/apps; FL=$REPO/fixtures/inventory-release/local/apps
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/mp23-c3m.yaml
R=$ROOT/reviews; SP=$ROOT/pending-evidence/seed; mkdir -p $SP
K() { command kubectl --context mp23-c3m "$@"; }
die() { echo "PHASE2B FAILED: $*"; exit 1; }
step() { echo "== $(date -u +%H:%M:%S) $*"; }
plan_apply() {
  local name=$1; shift
  [ -e "$R/$name.done" ] && { echo "$name: already done"; return 0; }
  "$@" --save-plan $R/$name > $R/$name.log 2>&1 || die "$name plan: $(tail -1 $R/$name.log)"
  $ROOT/runctl.sh inventory apply $R/$name --yes >> $R/$name.log 2>&1 || die "$name apply: $(tail -1 $R/$name.log)"
  touch "$R/$name.done"; echo "$name: $(tail -1 $R/$name.log)"
}
cd $ROOT
step site
FS=$F/scenario-site
plan_apply site ./runctl.sh site deploy -f $FS/nagare/Config.hs -C $FL/scenario-site --skip-build --tag c3 --image-resource publication:app-image-scenario-site-c3/scenario-site-c3/oci-image
for scope in runtime preview; do
  plan_apply site-env-$scope ./runctl.sh env set scenario-site -f $FS/nagare/Config.hs --$scope SCENARIO_SITE_MODE c3-$scope --reviewed
  if [ ! -e $R/site-secret-$scope.done ]; then
    (umask 077; python3 -c "import secrets; print(secrets.token_urlsafe(24), end='')" | ./runctl.sh secret set scenario-site -f $FS/nagare/Config.hs --$scope SCENARIO_SITE_TOKEN --version c3v1 --save-plan $R/site-secret-$scope > $R/site-secret-$scope.log 2>&1) || die "site secret $scope plan: $(tail -1 $R/site-secret-$scope.log)"
    ./runctl.sh inventory apply $R/site-secret-$scope --yes >> $R/site-secret-$scope.log 2>&1 || die "site secret $scope apply"
    touch $R/site-secret-$scope.done
  fi
done
plan_apply preview ./runctl.sh site preview deploy -f $FS/nagare/Config.hs -C $FL/scenario-site --name pr-scenario --skip-build --tag c3 --image-resource publication:app-image-scenario-site-c3/scenario-site-c3/oci-image --preview-env-resource application:env-scenario-site-runtime/runtime-env/configmap --preview-env-resource application:secret-scenario-site-runtime/runtime-secret/secret --preview-env-resource application:env-scenario-site-preview/preview-env/configmap --preview-env-resource application:secret-scenario-site-preview/preview-secret/secret
step seeds
K -n personal exec scenario-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q -c "create table if not exists scenario_known(id int primary key, v text); insert into scenario_known values (1, '"'"'scenario-pg-row-1'"'"'), (2, '"'"'scenario-pg-row-2'"'"') on conflict do nothing;" && psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||'"'"'|'"'"'||v from scenario_known order by id"' > $SP/postgresql.txt 2>&1
K -n personal exec scenario-redis-0 -c redis -- sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" SET scenario:known:1 scenario-redis-value-1 >/dev/null && redis-cli --no-auth-warning -a "$REDIS_PASSWORD" SET scenario:known:2 scenario-redis-value-2 >/dev/null && redis-cli --no-auth-warning -a "$REDIS_PASSWORD" MGET scenario:known:1 scenario:known:2' > $SP/redis.txt 2>&1
K -n personal exec scenario-ch-0 -- sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery -q "create table if not exists scenario_events (id UInt32, v String) engine = MergeTree order by id; insert into scenario_events values (1, '"'"'scenario-ch-row-1'"'"'), (2, '"'"'scenario-ch-row-2'"'"');" && clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "select concat(toString(id), '"'"'|'"'"', v) from scenario_events order by id"' > $SP/clickhouse.txt 2>&1
POD=$(K -n personal get pods -l serving.knative.dev/service=scenario-a -o jsonpath='{.items[0].metadata.name}')
K -n personal exec $POD -c user-container -- sh -c 'printf mp23-cloud-scenario-volume > /uploads/scenario-known.txt && sha256sum /uploads/scenario-known.txt' > $SP/volume.txt 2>&1
for f in postgresql redis clickhouse volume; do echo "seed $f: $(tr '\n' ' ' < $SP/$f.txt)"; done
step PHASE2B-OK
