#!/usr/bin/env bash
# C3 phase 2 driver (cloud copy of the EP-155 C2 driver by nagare-phase-b):
# scenario data, images, secret, deploy-a/b with interruptions, site, env,
# preview, seeds. Stops at the first failure.
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; REPO=/private/tmp/nagare-cand-83124396-src
F=$REPO/fixtures/inventory-release/gcp/apps
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/mp23-c3m.yaml
REG=us-west1-docker.pkg.dev/tan-ng-labs/nagare-c3-1012
R=$ROOT/reviews; P=$ROOT/pending-evidence/interrupted-recovery; SP=$ROOT/pending-evidence/seed
mkdir -p $R $P $SP $ROOT/evidence-private
K() { command kubectl --context mp23-c3m "$@"; }
die() { echo "PHASE2 FAILED: $*"; exit 1; }
step() { echo "== $(date -u +%H:%M:%S) $*"; }
plan_apply() { # name, then plan command...
  local name=$1; shift
  [ -e "$R/$name.done" ] && { echo "$name: already done"; return 0; }
  "$@" --save-plan $R/$name > $R/$name.log 2>&1 || die "$name plan: $(tail -1 $R/$name.log)"
  $ROOT/runctl.sh inventory apply $R/$name --yes >> $R/$name.log 2>&1 || die "$name apply: $(tail -1 $R/$name.log)"
  touch "$R/$name.done"; echo "$name: $(tail -1 $R/$name.log)"
}
cd $ROOT
step data
for spec in "clickhouse scenario-ch" "postgres scenario-retire"; do
  eng=${spec%% *}; name=${spec#* }
  plan_apply create-$name ./runctl.sh db create $eng $name --size 1Gi --recovery-backup $name --recovery-key-version v1
done
plan_apply create-scenario-events ./runctl.sh broker create redpanda scenario-events --namespace personal --size 1Gi --recovery-backup scenario-events --recovery-key scenario-events-key --recovery-key-version v1
plan_apply topic-jobs ./runctl.sh broker create redpanda scenario-events --namespace personal --size 1Gi --topic jobs --recovery-backup scenario-events --recovery-key scenario-events-key --recovery-key-version v1
step images
for app in scenario-a scenario-b scenario-site; do
  plan_apply image-$app ./runctl.sh app image-plan --archive "$ROOT/images/${app}.tar" --destination "$REG/${app}:c3" --key "${app}-c3"
done
step secret-a
if [ ! -e $R/secret-a.done ]; then
  (umask 077; python3 -c "import secrets; print(secrets.token_urlsafe(32), end='')" > $ROOT/evidence-private/scenario-api-token; shasum -a 256 $ROOT/evidence-private/scenario-api-token | cut -c1-64 > $ROOT/evidence-private/scenario-api-token.sha256)
  ./runctl.sh secret set scenario-a -f $F/scenario-a/nagare/Config.hs --runtime SCENARIO_API_TOKEN --version c3v1 --save-plan $R/secret-a < $ROOT/evidence-private/scenario-api-token > $R/secret-a.log 2>&1 || die "secret plan: $(tail -1 $R/secret-a.log)"
  ./runctl.sh inventory apply $R/secret-a --yes >> $R/secret-a.log 2>&1 || die "secret apply"
  touch $R/secret-a.done
fi
step deploy-a
if [ ! -e $R/deploy-a.done ]; then
  ./runctl.sh app deploy -f $F/scenario-a/nagare/Config.hs --tag c3 --image-resource publication:app-image-scenario-a-c3/scenario-a-c3/oci-image --database-recovery scenario-pg=scenario-pg:v1 --service-volume-recovery uploads=scenario-a-uploads:scenario-a-uploads-key:v1 --hook-no-data-effects scenario-a-report --env-secret-resource application:secret-scenario-a-runtime/runtime-secret/secret --save-plan $R/deploy-a > $R/deploy-a.log 2>&1 || die "deploy-a plan: $(tail -1 $R/deploy-a.log)"
  ./runctl.sh inventory apply $R/deploy-a --yes > $R/deploy-a-apply.log 2>&1 & pid=$!; killed=""
  for i in $(seq 1 600); do st=$(K -n personal get statefulset scenario-pg -o jsonpath='{.metadata.uid} {.status.readyReplicas}' 2>/dev/null); if [ -n "$st" ] && [ "${st#* }" != "1" ]; then kill -9 $pid; killed=$(date -u +%H:%M:%S); break; fi; kill -0 $pid 2>/dev/null || break; sleep 0.5; done; wait $pid 2>/dev/null
  echo "deploy-a killed=${killed:-none}"; [ -n "$killed" ] || die "deploy-a not interrupted"
  ./runctl.sh inventory status --json > $P/database-readiness-status.json
  K -n personal get statefulset,pvc,secret -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers 2>/dev/null | grep -E 'scenario-(pg|a)' > $P/database-readiness-uids-before.txt
  TX=$(python3 -c "import json;print(json.load(open('$P/database-readiness-status.json'))['activeTransaction'])")
  echo $TX > $P/database-readiness-tx.txt
  ./runctl.sh inventory resume $TX --yes > $P/database-readiness-resume.log 2>&1 || die "deploy-a resume: $(tail -1 $P/database-readiness-resume.log)"
  K -n personal get statefulset,pvc,secret -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers 2>/dev/null | grep -E 'scenario-(pg|a)' > $P/database-readiness-uids-after.txt
  touch $R/deploy-a.done; echo "deploy-a: $(tail -1 $P/database-readiness-resume.log)"
fi
step deploy-b
if [ ! -e $R/deploy-b.done ]; then
  ./runctl.sh app deploy -f $F/scenario-b/nagare/Config.hs --tag c3 --image-resource publication:app-image-scenario-b-c3/scenario-b-c3/oci-image --database-recovery scenario-redis=scenario-redis:v1 --save-plan $R/deploy-b > $R/deploy-b.log 2>&1 || die "deploy-b plan: $(tail -1 $R/deploy-b.log)"
  ./runctl.sh inventory apply $R/deploy-b --yes > $R/deploy-b-apply.log 2>&1 & pid=$!; killed=""
  for i in $(seq 1 900); do st=$(K -n personal get ksvc scenario-b -o jsonpath='{.metadata.uid} {.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null); if [ -n "$st" ] && [ "${st#* }" != "True" ]; then kill -9 $pid; killed=$(date -u +%H:%M:%S); break; fi; kill -0 $pid 2>/dev/null || break; sleep 0.3; done; wait $pid 2>/dev/null
  echo "deploy-b killed=${killed:-none}"; [ -n "$killed" ] || die "deploy-b not interrupted"
  ./runctl.sh inventory status --json > $P/cluster-completion-status.json
  K -n personal get ksvc,statefulset,pvc -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers 2>/dev/null | grep -E 'scenario-(b|redis)' > $P/cluster-completion-uids-before.txt
  TX=$(python3 -c "import json;print(json.load(open('$P/cluster-completion-status.json'))['activeTransaction'])")
  echo $TX > $P/cluster-completion-tx.txt
  echo "deploy-b interrupted; transaction $TX left for the shared-history takeover from a second root"
fi
step PHASE2-PAUSE-FOR-TAKEOVER
