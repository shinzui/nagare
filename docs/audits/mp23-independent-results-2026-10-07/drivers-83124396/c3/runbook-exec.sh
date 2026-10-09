#!/usr/bin/env bash
# Independent execution of docs/runbooks/inventory-operations.md on mp23-c3m (candidate 83124396),
# by nagare-verify, after the C3 runner. One function per runbook section; each writes its evidence
# under pending-evidence/runbook/<section>/ and stops the run at the first unexpected result.
# Usage: runbook-exec.sh SECTION...   (sections in the order below; `all` runs them in order)
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; REPO=/private/tmp/nagare-cand-83124396-src
F=$REPO/fixtures/inventory-release/gcp/apps; V=$ROOT/runbook/apps/scenario-a-bigcpu
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/mp23-c3m.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs
RUN=$ROOT/runctl.sh; RUNB=$ROOT-b/runctl.sh; U=gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory
PE=$ROOT/pending-evidence/runbook; R=$ROOT/reviews/runbook; mkdir -p $PE $R
K() { command kubectl --context mp23-c3m "$@"; }
die() { echo "RUNBOOK FAILED [$SECTION]: $*"; exit 1; }
head_json() { gcloud storage cat $U/head.json | jq -c '{generation,sequence,activeTransaction,executorClaim}'; }
status() { $RUN inventory status --json 2>/dev/null; }
idle() { [ "$(status | jq -r .activeTransaction)" = null ]; }
rec() { jq -n "$@" > $E/result.json; echo "$SECTION: $(jq -c . $E/result.json | cut -c1-300)"; }
begin() { SECTION=$1; E=$PE/$1; mkdir -p $E; echo "== $(date -u +%H:%M:%S) $1"; idle || die "store not idle at start"; }
DEPA_ARGS="--tag c3 --image-resource publication:app-image-scenario-a-c3/scenario-a-c3/oci-image --database-recovery scenario-pg=scenario-pg:v1 --service-volume-recovery uploads=scenario-a-uploads:scenario-a-uploads-key:v1 --hook-no-data-effects scenario-a-report --env-secret-resource application:secret-scenario-a-runtime/runtime-secret/secret"
tx_of() { echo "tx-$(cat $1/review.sha256 2>/dev/null || shasum -a 256 $1/review.json | cut -c1-64)"; }

# Select the private context: guard, store status, and kubeconfig recovery into a fresh root.
select_context() {
  begin select-context
  $RUN context guard > $E/guard.log 2>&1 || die "context guard: $(tail -1 $E/guard.log)"
  $RUN inventory store status --json > $E/store-status.json 2>/dev/null || die "store status"
  C=$ROOT-runbook-fresh; rm -rf $C; mkdir -p -m 700 $C/config/nagare/contexts $C/config/nagare/hosts $C/state $C/cache
  cp $ROOT/config/nagare/contexts/mp23-c3m.env $C/config/nagare/contexts/; cp -R $ROOT/config/nagare/hosts/mp23-c3m $C/config/nagare/hosts/
  sed "s#root=$ROOT\$#root=$C#; s#\"\$root/age-key.txt\"#\"$ROOT/age-key.txt\"#g" $RUN > $C/runctl.sh; chmod 700 $C/runctl.sh
  start=$(date +%s); $C/runctl.sh kubeconfig recover > $E/recover.log 2>&1 || die "kubeconfig recover: $(tail -2 $E/recover.log | tr '\n' ' ')"
  secs=$(( $(date +%s) - start ))
  mode=$(stat -c %a $C/config/nagare/kubeconfigs/mp23-c3m.yaml 2>/dev/null || stat -f %Lp $C/config/nagare/kubeconfigs/mp23-c3m.yaml)
  node=$(KUBECONFIG=$C/config/nagare/kubeconfigs/mp23-c3m.yaml command kubectl --context mp23-c3m get nodes -o name)
  rec --arg guard "$(tail -1 $E/guard.log)" --arg node "$node" --arg mode "$mode" --argjson secs $secs --argjson head "$(head_json)" \
    '{guard:$guard, kubeconfigRecover:{seconds:$secs, mode:$mode, node:$node}, headAfter:$head}'
  [ "$mode" = 600 ] || die "recovered kubeconfig mode $mode"
}

# Apply a saved review: inspect it, apply it, explain a member.
apply_saved() {
  begin apply-saved-review
  $RUN env set scenario-a -f $F/scenario-a/nagare/Config.hs --runtime SCENARIO_MODE runbook-apply --reviewed --save-plan $R/apply > $E/plan.log 2>&1 || die "plan: $(tail -1 $E/plan.log)"
  jq '{context, payloadIdentity, baseRevisions, desiredRevisions, barriers, operations: [.operations[] | {operation, summary}]}' $R/apply/review.json > $E/inspect.json
  $RUN inventory apply $R/apply --yes > $E/apply.log 2>&1 || die "apply: $(tail -1 $E/apply.log)"
  $RUN inventory explain application:scenario-a/scenario-a/service --json > $E/explain.json 2>/dev/null || die explain
  rec --arg out "$(tail -1 $E/apply.log)" --argjson ops "$(jq '.operations|length' $E/inspect.json)" '{operations:$ops, result:$out}'
}

# Resume the original transaction (and resolve with adapter proof first): an apply killed mid-flight.
resume_and_proof() {
  begin resume-original-transaction
  $RUN env set scenario-a -f $F/scenario-a/nagare/Config.hs --runtime SCENARIO_MODE runbook-resume --reviewed --save-plan $R/resume > $E/plan.log 2>&1 || die "plan"
  TX=$(tx_of $R/resume)
  $RUN inventory apply $R/resume --yes > $E/apply.log 2>&1 & pid=$!
  for i in $(seq 1 600); do a=$(head_json | jq -r .activeTransaction); [ "$a" = "$TX" ] && break; kill -0 $pid 2>/dev/null || break; sleep 0.5; done
  sleep 2; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
  head_json > $E/head-after-kill.json
  if [ "$(jq -r .activeTransaction $E/head-after-kill.json)" != "$TX" ]; then echo "kill landed after completion; resume has nothing to do"; fi
  status > $E/status-after-kill.json
  OP=$(jq -r '.transactionStatus.operations[]? | select(.state!="completed") | .operation' $E/status-after-kill.json | head -1)
  proof="not attempted"
  if [ -n "$OP" ] && [ "$OP" != null ]; then
    printf '{"version":1,"transaction":"%s","operation":"%s","review":"%s","action":"accept-adapter-proof"}\n' $TX $OP ${TX#tx-} > $E/decision.json
    $RUN inventory recover $TX --operation $OP --decision $E/decision.json > $E/recover.log 2>&1; proof="exit $? $(tail -1 $E/recover.log | cut -c1-200)"
  fi
  if [ "$(head_json | jq -r .activeTransaction)" = "$TX" ]; then
    $RUN inventory resume $TX --yes > $E/resume.log 2>&1 || die "resume: $(tail -1 $E/resume.log)"
  fi
  idle || die "not idle after resume"
  rec --arg tx $TX --arg op "${OP:-none}" --arg proof "$proof" --arg resume "$(tail -1 $E/resume.log 2>/dev/null)" '{transaction:$tx, uncertainOperation:$op, adapterProofRecover:$proof, resume:$resume}'
}

# Close a stopped transaction: an update that lands but never becomes Ready (64 CPU), closed by
# per-operation proof, then corrected by an ordinary review; plus attested close refused when unneeded.
close_stopped() {
  begin close-stopped-transaction
  UID0=$(K -n personal get ksvc scenario-a -o jsonpath='{.metadata.uid}')
  $RUN app deploy -f $V/nagare/Config.hs $DEPA_ARGS --save-plan $R/unready > $E/plan.log 2>&1 || die "unready plan: $(tail -1 $E/plan.log)"
  TX=$(tx_of $R/unready)
  start=$(date +%s); timeout 1200 $RUN inventory apply $R/unready --yes > $E/apply.log 2>&1; code=$?
  echo "unready apply exit=$code after $(( $(date +%s) - start ))s: $(tail -1 $E/apply.log | cut -c1-200)"
  [ $code -ne 0 ] || die "unready update unexpectedly converged"
  status > $E/status-stopped.json
  $RUN inventory close $TX --review ${TX#tx-} > $E/close.log 2>&1 || die "close: $(tail -2 $E/close.log | tr '\n' ' ')"
  idle || die "not idle after close"
  # Attested close on an already-closed transaction: must be refused, never accept anything.
  printf '{"version":1,"operator":"nagare-verify","reason":"runbook check: attestation on a proved stop must be refused","evidence":[]}\n' > $E/attest.json
  $RUN inventory close $TX --review ${TX#tx-} --attest $E/attest.json > $E/attest.log 2>&1; acode=$?
  $RUN app deploy -f $F/scenario-a/nagare/Config.hs $DEPA_ARGS --save-plan $R/corrected > $E/corrected-plan.log 2>&1 || die "corrected plan: $(tail -1 $E/corrected-plan.log)"
  $RUN inventory apply $R/corrected --yes > $E/corrected-apply.log 2>&1 || die "corrected apply: $(tail -1 $E/corrected-apply.log)"
  UID1=$(K -n personal get ksvc scenario-a -o jsonpath='{.metadata.uid}'); READY=$(K -n personal get ksvc scenario-a -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  rec --arg tx $TX --arg close "$(tail -1 $E/close.log)" --argjson acode $acode --arg attest "$(tail -1 $E/attest.log | cut -c1-200)" \
      --arg corrected "$(tail -1 $E/corrected-apply.log)" --arg u0 "$UID0" --arg u1 "$UID1" --arg ready "$READY" \
      '{transaction:$tx, close:$close, attestedCloseOnClosed:{exit:$acode, output:$attest}, corrected:$corrected, serviceUidUnchanged:($u0==$u1), ready:$ready}'
  [ "$UID0" = "$UID1" ] && [ "$READY" = True ] || die "service replaced or not Ready after correction"
}

# Abandon a migration that cannot go forward: a disposable standalone PostgreSQL renamed, killed at its
# copy Job, abandoned (writer unfenced, old DB accepted, nothing deleted), then D1's documented manual
# exit for the leftovers, and the rename completed.
abandon_migration() {
  begin abandon-migration
  N=rbk-pg; NN=rbk-pg2
  [ -e $R/create-$N.done ] || { $RUN db create postgres $N --size 1Gi --recovery-backup $N --recovery-key-version v1 --save-plan $R/create-$N > $E/create.log 2>&1 && $RUN inventory apply $R/create-$N --yes >> $E/create.log 2>&1 && touch $R/create-$N.done; } || die "create: $(tail -1 $E/create.log)"
  K -n personal rollout status statefulset/$N --timeout=300s > /dev/null || die "db not ready"
  K -n personal exec $N-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "create table if not exists runbook(v text); insert into runbook values ('"'"'before-rename'"'"')"' > $E/seed.log 2>&1 || die "seed: $(tail -1 $E/seed.log)"
  $RUN db rename postgres $N $NN --size 1Gi --recovery-backup $N --recovery-key-version v1 --save-plan $R/rename > $E/rename-plan.log 2>&1 || die "rename plan: $(tail -1 $E/rename-plan.log)"
  TX=$(tx_of $R/rename)
  $RUN inventory apply $R/rename --yes > $E/rename-apply.log 2>&1 & pid=$!; job=""
  for i in $(seq 1 1800); do job=$(K -n personal get jobs -o name 2>/dev/null | grep 'nagare-migrate-.*-copy' | head -1); [ -n "$job" ] && { kill -9 $pid; break; }; kill -0 $pid 2>/dev/null || break; sleep 0.2; done
  wait $pid 2>/dev/null; echo "killed at copy job: ${job:-none}"; [ -n "$job" ] || die "no copy job observed"
  K -n personal get statefulset $N -o json | jq '{uid:.metadata.uid, replicas:.spec.replicas, fence:.metadata.annotations["nagare.dev/migration-fence"]}' > $E/writer-before-abandon.json
  $RUN inventory abandon-migration $TX --review ${TX#tx-} > $E/abandon.log 2>&1; code=$?
  echo "abandon exit=$code: $(tail -1 $E/abandon.log | cut -c1-200)"
  if [ $code -ne 0 ]; then grep -q 'migration-past-return' $E/abandon.log && { $RUN inventory resume $TX --yes > $E/resume.log 2>&1 || die "resume after past-return"; rec --arg r "past-return; resumed: $(tail -1 $E/resume.log)" '{abandon:$r}'; return 0; }; die "abandon: $(tail -2 $E/abandon.log | tr '\n' ' ')"; fi
  idle || die "not idle after abandon"
  K -n personal rollout status statefulset/$N --timeout=300s > /dev/null || die "old writer not running after abandon"
  K -n personal get statefulset $N -o json | jq '{uid:.metadata.uid, replicas:.spec.replicas, fence:.metadata.annotations["nagare.dev/migration-fence"]}' > $E/writer-after-abandon.json
  ROW=$(K -n personal exec $N-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select v from runbook"' 2>/dev/null)
  status > $E/status-after-abandon.json
  # D1 manual exit: delete the leftover destination objects by exact UID, after confirming none is accepted.
  K -n personal get statefulset,pvc,service,secret,serviceaccount,role,rolebinding,cronjob -o json | jq --arg nn $NN '[.items[] | select(.metadata.annotations["nagare.dev/context-id"] != null or .metadata.labels["nagare.dev/managed-by"] != null) | select(.metadata.name as $n | [$nn, "nagare-db-\($nn)", "nagare-db-\($nn)-data", "nagare-dbbackup-\($nn)", "nagare-dbbackup-\($nn)-signing"] | index($n)) | {kind, name:.metadata.name, uid:.metadata.uid, apiVersion}]' > $E/leftovers.json
  jq -e --arg nn $NN '[.findings[]? | select(.resource|test($nn))] | length == 0' $E/status-after-abandon.json > /dev/null || die "a leftover is accepted"
  rec --arg tx $TX --arg abandon "$(tail -1 $E/abandon.log)" --argjson before "$(cat $E/writer-before-abandon.json)" --argjson after "$(cat $E/writer-after-abandon.json)" --arg row "$ROW" --argjson left "$(cat $E/leftovers.json)" \
      '{transaction:$tx, abandon:$abandon, writerBefore:$before, writerAfter:$after, rowAfter:$row, leftovers:$left}'
  [ "$ROW" = before-rename ] || die "row lost"
  [ "$(jq -r .replicas $E/writer-after-abandon.json)" = 1 ] && [ "$(jq -r .fence $E/writer-after-abandon.json)" = null ] || die "writer still fenced"
}

# Replaced and unrecorded members: a stateless Role replaced outside review, then the documented rebind.
replaced_rebind() {
  begin replaced-and-unrecorded
  RES=application:scenario-a/scenario-pg/backup-read-role
  status > $E/status-0.json
  ADDR=$(jq -c --arg r $RES '.findings[] | select(.resource==$r) | .address.contents' $E/status-0.json); NS=$(echo "$ADDR" | jq -r '.[3]'); NAME=$(echo "$ADDR" | jq -r '.[4]')
  OLD=$(K -n $NS get role $NAME -o jsonpath='{.metadata.uid}')
  K -n $NS get role $NAME -o json | jq 'del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields,.metadata.generation)' > $E/role.json
  K replace --force -f $E/role.json > $E/replace.log 2>&1 || die "replace"
  NEW=$(K -n $NS get role $NAME -o jsonpath='{.metadata.uid}')
  status > $E/status-1.json
  jq -e --arg r $RES --arg u $NEW '[.findings[] | select(.resource==$r and .category=="replaced-incarnation" and .physical==$u)] | length == 1' $E/status-1.json > /dev/null || die "not reported replaced"
  bash $ROOT/rebind-unrecorded.sh > $E/rebind.log 2>&1 || die "rebind: $(tail -2 $E/rebind.log | tr '\n' ' ')"
  status > $E/status-2.json
  rec --arg old "$OLD" --arg new "$NEW" --argjson after "$(jq -c '[.findings[].category] | group_by(.) | map({(.[0]): length}) | add' $E/status-2.json)" '{replacedUid:{old:$old, new:$new}, rebind:"converged", categoriesAfter:$after}'
}

# Synchronize a newly protected backend.
portal_sync() {
  begin synchronize-protected-backend
  $RUN access portal sync --save-plan $R/portal-sync > $E/plan.log 2>&1 || die "plan: $(tail -1 $E/plan.log)"
  $RUN inventory apply $R/portal-sync --yes > $E/apply.log 2>&1 || die "apply: $(tail -1 $E/apply.log)"
  rec --arg ops "$(jq -r '[.operations[].operation.action.tag] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' $R/portal-sync/review.json)" --arg out "$(tail -1 $E/apply.log)" '{operations:$ops, result:$out}'
}

[ $# -gt 0 ] || { echo "usage: $0 SECTION... | all"; exit 2; }
[ "$1" = all ] && set -- select_context apply_saved resume_and_proof close_stopped abandon_migration replaced_rebind portal_sync
for s in "$@"; do "$s"; done
echo RUNBOOK-OK
