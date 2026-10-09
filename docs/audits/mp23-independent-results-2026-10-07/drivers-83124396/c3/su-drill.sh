#!/usr/bin/env bash
# C3 source-unavailable recovery (F41 cloud form): escrow scenario-pg's signing key, pick the
# newest verified scheduled backup created AFTER the seed (runbook section 6 rule 7), verify it
# online, stop the VM through a reviewed host stop, verify offline from escrow + GCS, restore the
# exact object version into a disposable PostgreSQL 18, then restart the VM and wait to settle.
set -uo pipefail
G=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; RUN=$G/runctl.sh; E=$G/pending-evidence/source-unavailable-recovery; mkdir -p $E
export KUBECONFIG=$G/config/nagare/kubeconfigs/mp23-c3m.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs CLOUDSDK_CORE_PROJECT=tan-ng-labs
export DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
BK=gs://tan-ng-labs-c3-1012-vbmsjgn-backups/databases/scenario-pg
die() { echo "SU FAILED: $*"; exit 1; }
quiet() { grep -v -E '^(  warning|warning: Application|context guard)' "$1" | tail -1 | cut -c1-200; }
K() { command kubectl --context mp23-c3m "$@"; }
umask 077
ESC=$(find $G/config/nagare/cluster-secrets -name '*scenario-pg*' | head -1)
if [ -z "$ESC" ]; then $RUN db escrow-signing-key scenario-pg > $E/escrow.log 2>&1 || die "escrow: $(quiet $E/escrow.log)"; ESC=$(find $G/config/nagare/cluster-secrets -name '*scenario-pg*' | head -1); fi; [ -n "$ESC" ] && grep -q "ENC\[" $ESC || die "escrow file missing or unencrypted"
$RUN db backup-receipts scenario-pg > $E/receipts.txt 2>&1 || die "receipts"
SEED=$(date -u -r $G/pending-evidence/seed/postgresql.txt +%FT%TZ)
gcloud storage objects list "$BK/*.sql.gz" --format=json > $E/backup-objects.json || die "list backups"
python3 - $E/receipts.txt $E/backup-objects.json "$SEED" > $E/selection.json <<'PY' || die "no verified backup after the seed"
import json, sys, re
receipts, objects, seed = sys.argv[1:]
verified = {l.split()[0] for l in open(receipts) if re.match(r"^[0-9a-f-]{36}\s+verified", l)}
cands = []
for o in json.load(open(objects)):
    m = re.search(r"/([0-9a-f-]{36})\.sql\.gz$", o["name"])
    if m and m.group(1) in verified and o["creation_time"][:19] > seed[:19]:
        cands.append({"job": m.group(1), "generation": str(o["generation"]), "created": o["creation_time"]})
if not cands: sys.exit(3)
pick = max(cands, key=lambda c: c["created"])
print(json.dumps({"seedTime": seed, "rule": "newest verified scheduled backup created after the seed", "candidates": len(cands), **pick}, indent=1))
PY
JOB=$(jq -r .job $E/selection.json); GEN=$(jq -r .generation $E/selection.json); echo "picked $JOB ($(jq -r .created $E/selection.json), seed $SEED)"
$RUN db verify-escrowed-backup scenario-pg --backup-id $JOB > $E/verify-online.log 2>&1 || die "verify online: $(quiet $E/verify-online.log)"
$RUN host stop --operation-id c3i-source-unavailable-stop --save-plan $G/reviews/vm-stop > $E/vm-stop-plan.log 2>&1 || die "stop plan: $(quiet $E/vm-stop-plan.log)"
$RUN inventory apply $G/reviews/vm-stop --yes > $E/vm-stop-apply.log 2>&1 || die "stop apply: $(quiet $E/vm-stop-apply.log)"
gcloud compute instances describe nagare-c3-1012 --zone us-west1-a --format='value(status)' > $E/vm-status-stopped.txt
[ "$(cat $E/vm-status-stopped.txt)" = TERMINATED ] || die "VM not stopped: $(cat $E/vm-status-stopped.txt)"
timeout 300 $RUN db verify-escrowed-backup scenario-pg --backup-id $JOB > $E/verify-offline.log 2>&1 || die "verify offline: $(quiet $E/verify-offline.log)"
mkdir -p $G/evidence-private/restore; gcloud storage cp "$BK/$JOB.sql.gz#$GEN" $G/evidence-private/restore/backup.sql.gz > /dev/null 2>&1 || die "download"
N=c3i-pg-restore; docker rm -f $N > /dev/null 2>&1
docker run -d --name $N -e POSTGRES_PASSWORD=disposable -e POSTGRES_USER=nagare -e POSTGRES_DB=restore postgres:18 > /dev/null || die "docker run"
for i in $(seq 1 60); do docker exec $N pg_isready -U nagare -d restore > /dev/null 2>&1 && break; sleep 2; done
gunzip -c $G/evidence-private/restore/backup.sql.gz | docker exec -i $N psql -U nagare -d restore -q -v ON_ERROR_STOP=0 > $E/restore-psql.log 2>&1
docker exec $N psql -U nagare -d restore -tA -c "select id||'|'||v from scenario_known order by id" > $E/restored-rows.txt
docker image inspect postgres:18 --format '{{index .RepoDigests 0}}' > $E/postgres-image.txt; docker rm -f $N > /dev/null
grep -qx "1|scenario-pg-row-1" $E/restored-rows.txt && grep -qx "2|scenario-pg-row-2" $E/restored-rows.txt || die "restored rows lack the seed rows: $(tr '\n' ' ' < $E/restored-rows.txt)"
$RUN host start --operation-id c3i-source-unavailable-start --save-plan $G/reviews/vm-start > $E/vm-start-plan.log 2>&1 || die "start plan: $(quiet $E/vm-start-plan.log)"
$RUN inventory apply $G/reviews/vm-start --yes > $E/vm-start-apply.log 2>&1 || die "start apply: $(quiet $E/vm-start-apply.log)"
for i in $(seq 1 90); do K get --raw=/readyz > /dev/null 2>&1 && break; sleep 10; done
for i in $(seq 1 90); do n=$(K get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if (!(a[1]==a[2] && $4=="Running") && $4!="Completed") c++} END {print c+0}'); [ "$n" = 0 ] && break; sleep 10; done
for i in $(seq 1 90); do K get apiservices -o json | jq -e '[.items[] | .status.conditions[]? | select(.type=="Available") | .status] | all(. == "True")' > /dev/null && break; sleep 10; done
gcloud storage cat gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory/head.json | jq -c '{generation,sequence,activeTransaction,executorClaim}' > $E/idle-after.json
$RUN db backup-receipts scenario-pg --check-freshness 2>&1 | grep "Recovery-point freshness" > $E/freshness-after.txt
jq -n --arg escrowSha "$(shasum -a 256 $ESC | cut -c1-64)" --slurpfile sel $E/selection.json --arg sha "$(shasum -a 256 $G/evidence-private/restore/backup.sql.gz | cut -c1-64)" \
  --arg rows "$(tr '\n' ' ' < $E/restored-rows.txt)" --arg stop "$(tail -1 $E/vm-stop-apply.log)" --arg start "$(tail -1 $E/vm-start-apply.log)" --arg img "$(cat $E/postgres-image.txt)" \
  --arg errors "$(grep -c ERROR $E/restore-psql.log)" \
  '{database:"personal/scenario-pg", escrow:{command:"nagarectl db escrow-signing-key scenario-pg", fileSha256:$escrowSha, mode:"0600", sopsEncrypted:true},
    selection:$sel[0], verifyOnline:"verified with the escrowed key while the VM ran",
    sourceUnavailable:{command:"nagarectl host stop --operation-id c3i-source-unavailable-stop --save-plan DIR; inventory apply", result:$stop, vmStatus:"TERMINATED"},
    verifyOffline:"nagarectl db verify-escrowed-backup scenario-pg --backup-id JOB passed with the VM stopped (escrow + GCS only)",
    restore:{downloadedSha256:$sha, target:("disposable local " + $img), psqlErrors:($errors|tonumber), rows:$rows, seedRowsPresent:true},
    restart:{command:"nagarectl host start --operation-id c3i-source-unavailable-start --save-plan DIR; inventory apply", result:$start, podsReady:true, apiservicesAvailable:true}}' > $E/result.json
jq -c '{selection: .selection.job, restore: .restore.rows, idle: input}' $E/result.json $E/idle-after.json
echo SU-OK
