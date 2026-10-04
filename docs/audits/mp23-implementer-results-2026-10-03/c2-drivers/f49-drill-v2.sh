#!/usr/bin/env bash
# EP-159 source-replacement native proof on the 7596632c C2 context (procedure:
# docs/audits/mp23-implementer-results-2026-10-03/ep159-source-replacement-7596632c-procedure.md).
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad
ROOT=$(cat $S/c2-root); cd $ROOT
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
DB=ep159-throwaway; NS=personal; P=$ROOT/pending-evidence/ep159; R=$ROOT/reviews; mkdir -p $P
C=/private/tmp/nagare-mp23-cp3.1EQ78L/.cp3-claim
K() { command kubectl --context local "$@"; }
step() { echo "== $(date -u +%H:%M:%S) $*"; }
die() { echo "EP159 STOPPED: $*"; exit 1; }
headj() { python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print(json.dumps({'generation':h['generation'],'sequence':h['sequence'],'activeTransaction':h['activeTransaction']}))"; }
uids() { K -n $NS get sts,pvc -o json | jq -c '[.items[] | {kind, name: .metadata.name, uid: .metadata.uid, resourceVersion: .metadata.resourceVersion}] | sort_by(.kind, .name)'; }
receipts() { ./runctl.sh db backup-receipts $DB 2>/dev/null | grep -E '^[0-9a-f-]{36}\s' | awk '{print $1}' | sort; }
plan_apply() { local name=$1; shift; "$@" --save-plan $R/$name > $P/$name.plan.log 2>&1 || die "$name plan: $(tail -1 $P/$name.plan.log)"; ./runctl.sh inventory apply $R/$name --yes > $P/$name.apply.log 2>&1 || die "$name apply: $(tail -1 $P/$name.apply.log)"; echo "$name: $(tail -1 $P/$name.apply.log)"; }
# Record a refusal: the --save-plan directory must not exist before or after, exit non-zero, head unchanged.
refusal() { local name=$1 dir=$2 shown=$3; shift 3
  local before after existed exists rc
  before=$(headj); existed=$([ -e "$dir" ] && echo true || echo false)
  "$@" --save-plan "$dir" > $P/$name.out 2>&1; rc=$?
  after=$(headj); exists=$([ -e "$dir" ] && echo true || echo false)
  python3 - "$P/$name.json" "$shown" "$rc" "$P/$name.out" "$before" "$after" "$existed" "$exists" <<'PY'
import json,sys
out,shown,rc,log,before,after,existed,exists=sys.argv[1:]
lines=[l for l in open(log).read().strip().splitlines() if l.strip()]
json.dump({"command":shown,"exitCode":int(rc),"refusal":lines[-3:],"headBefore":json.loads(before),"headAfter":json.loads(after),
 "saveDirExistedBefore":existed=="true","saveDirExistsAfter":exists=="true",
 "refused":int(rc)!=0 and exists=="false" and json.loads(before)==json.loads(after)},open(out,'w'),indent=1)
PY
  echo "$name: exit=$rc $(tail -1 $P/$name.out | cut -c1-160)"; }

# Head incarnation and retained records for the throwaway (reviewer additions, read-only).
incj() { python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print(json.dumps({'incarnations':{e['resource']:e['physical'] for e in h.get('incarnations',[]) if '$DB' in e['resource']},'retained':{e['resource']:e['incarnation'].get('physical') for e in h.get('retained',[]) if '$DB' in e['resource']}},sort_keys=True))"; }
snap() { incj > $P/incarnations-$1.json; echo "incarnations $1: $(cat $P/incarnations-$1.json | cut -c1-300)"; }
step claim
if [ -d "$C" ]; then
  [ "$(cat "$C/owner")" = nagare-phase-b ] || die "cp3 claim is held by $(cat "$C/owner")"
else
  mkdir "$C" && echo nagare-phase-b > "$C/owner" || die "cp3 claim could not be taken"
fi
date -u +%FT%TZ > "$C/since"; echo "F49 native drill v2 on throwaway $DB (escrow before replacement; reviewer-approved procedure)" > "$C/purpose"
[ "$(headj | jq -r .activeTransaction)" = null ] || die "store not idle"

step "1 baseline"
headj > $P/head-baseline.json; uids > $P/uids-baseline.json; ./runctl.sh inventory status --json > $P/status-baseline.json 2>/dev/null

step "2 create"
plan_apply ep159-create ./runctl.sh db create postgres $DB --size 1Gi --recovery-backup $DB --recovery-key-version v1
for i in $(seq 1 60); do [ "$(K -n $NS get sts $DB -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && break; sleep 5; done
K -n $NS exec $DB-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q -c "create table ep159_known(id int primary key, v text); insert into ep159_known values (1, '"'"'ep159-row-1'"'"');" && psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||'"'"'|'"'"'||v from ep159_known"' > $P/seed.txt 2>&1 || die "seed"
echo "seed: $(cat $P/seed.txt)"; date -u +%FT%TZ > $P/seed-at.txt

step "3 scheduled receipt A (wait, then ingest)"
A=""; for i in $(seq 1 25); do A=$(receipts | head -1); [ -n "$A" ] && break; sleep 60; done
[ -n "$A" ] || die "no scheduled receipt A"
echo "$A" > $P/receipt-A.txt; echo "A=$A"
ingested=false; for i in $(seq 1 10); do
  if ./runctl.sh db backup-receipts $DB --backup-id $A --save-plan $R/ep159-ingest-A-$i > $P/ingest-A-$i.plan.log 2>&1; then
    cp $P/ingest-A-$i.plan.log $P/ingest-A.plan.log
    ./runctl.sh inventory apply $R/ep159-ingest-A-$i --yes > $P/ingest-A.apply.log 2>&1 || die "ingest A apply: $(tail -1 $P/ingest-A.apply.log)"
    ingested=true; break
  fi
  echo "ingest A plan attempt $i refused ($(tail -1 $P/ingest-A-$i.plan.log | cut -c1-120)); retry in 60s"; sleep 60
done
$ingested || die "receipt A could not be ingested"
echo "ingest A: $(tail -1 $P/ingest-A.apply.log)"
python3 - $ROOT $DB > $P/receipt-A-accepted.json <<'PY'
import json,sys,glob
root,db=sys.argv[1:]
def walk(v):
    if isinstance(v,dict):
        if 'scheduled.backup.id' in v and db in json.dumps(v): yield v
        for x in v.values(): yield from walk(x)
    elif isinstance(v,list):
        for x in v: yield from walk(x)
found=[]
for f in glob.glob(root+'/state/nagare/local/inventory/scopes/*.json'):
    found+= [ {k:o[k] for k in sorted(o) if k.startswith('scheduled.backup')} for o in walk(json.load(open(f)))]
print(json.dumps(found[0] if found else {}, indent=1))
PY
AID=$(jq -r '."scheduled.backup.id" // empty' $P/receipt-A-accepted.json); [ -n "$AID" ] || die "A's accepted scope has no scheduled.backup.id"
echo "A scheduled.backup.id=$AID"

step "3 scheduled receipt B (wait, leave pending)"
B=""; for i in $(seq 1 25); do B=$(receipts | grep -v "^$A$" | head -1); [ -n "$B" ] && break; sleep 60; done
[ -n "$B" ] || die "no scheduled receipt B"
echo "$B" > $P/receipt-B.txt; echo "B=$B"
./runctl.sh db backup-receipts $DB > $P/receipts-before-replacement.txt 2>&1

step "3b escrow BEFORE the replacement"
mkdir -m 700 -p $ROOT/escrow-ep159; cp $ROOT/cluster-secrets/sops-config.yaml $ROOT/escrow-ep159/.sops.yaml
./runctl.sh db escrow-signing-key $DB --output $ROOT/escrow-ep159/personal-$DB.sops.yaml > $P/escrow.log 2>&1 || die "escrow: $(tail -1 $P/escrow.log)"
chmod 600 $ROOT/escrow-ep159/personal-$DB.sops.yaml
step "4 pre-replacement snapshot"
headj > $P/head-before-replacement.json; uids > $P/uids-before-replacement.json
K -n $NS get sts $DB -o json > $P/sts-old.json; K -n $NS get pvc nagare-db-$DB-data -o json > $P/pvc-old.json
snap before-replacement
python3 - $P <<'PY' || die "the head does not record the live StatefulSet and PVC as accepted incarnations"
import json,sys
P=sys.argv[1]; inc=json.load(open(P+'/incarnations-before-replacement.json'))['incarnations']
sts=json.load(open(P+'/sts-old.json'))['metadata']['uid']; pvc=json.load(open(P+'/pvc-old.json'))['metadata']['uid']
ok=any(k.endswith('/statefulset') and v==sts for k,v in inc.items()) and any(k.endswith('/pvc') and v==pvc for k,v in inc.items())
print("recorded incarnations equal the old live UIDs:", ok); sys.exit(0 if ok else 1)
PY

step "5 out-of-band replacement (throwaway only)"
SUID=$(jq -r .metadata.uid $P/sts-old.json); SRV=$(jq -r .metadata.resourceVersion $P/sts-old.json)
PUID=$(jq -r .metadata.uid $P/pvc-old.json); PRV=$(jq -r .metadata.resourceVersion $P/pvc-old.json)
printf '{"kind":"DeleteOptions","apiVersion":"v1","propagationPolicy":"Background","preconditions":{"uid":"%s","resourceVersion":"%s"}}' $SUID $SRV > $P/sts-delete-options.json
K delete --raw /apis/apps/v1/namespaces/$NS/statefulsets/$DB -f $P/sts-delete-options.json > $P/sts-delete.out 2>&1 || die "sts delete: $(tail -1 $P/sts-delete.out)"
for i in $(seq 1 60); do K -n $NS get pod $DB-0 >/dev/null 2>&1 || break; sleep 2; done
PRV=$(K -n $NS get pvc nagare-db-$DB-data -o jsonpath='{.metadata.resourceVersion}')
printf '{"kind":"DeleteOptions","apiVersion":"v1","preconditions":{"uid":"%s","resourceVersion":"%s"}}' $PUID $PRV > $P/pvc-delete-options.json
K delete --raw /api/v1/namespaces/$NS/persistentvolumeclaims/nagare-db-$DB-data -f $P/pvc-delete-options.json > $P/pvc-delete.out 2>&1 || die "pvc delete: $(tail -1 $P/pvc-delete.out)"
for i in $(seq 1 60); do K -n $NS get pvc nagare-db-$DB-data >/dev/null 2>&1 || break; sleep 2; done
jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.finalizers, .status, .spec.volumeName)
    | .metadata.annotations |= with_entries(select(.key | startswith("nagare.dev/")))' $P/pvc-old.json > $P/pvc-recreate.json
jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.generation, .status)' $P/sts-old.json > $P/sts-recreate.json
K create -f $P/pvc-recreate.json > $P/pvc-create.out 2>&1 || die "pvc create: $(tail -1 $P/pvc-create.out)"
K create -f $P/sts-recreate.json > $P/sts-create.out 2>&1 || die "sts create: $(tail -1 $P/sts-create.out)"
for i in $(seq 1 90); do [ "$(K -n $NS get sts $DB -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && break; sleep 5; done
K -n $NS get sts $DB -o json > $P/sts-new.json; K -n $NS get pvc nagare-db-$DB-data -o json > $P/pvc-new.json
echo "sts uid $SUID -> $(jq -r .metadata.uid $P/sts-new.json); pvc uid $PUID -> $(jq -r .metadata.uid $P/pvc-new.json); ready=$(jq -r .status.readyReplicas $P/sts-new.json)"
date -u +%FT%TZ > $P/replaced-at.txt
snap after-replacement
./runctl.sh inventory status --json > $P/status-after-replacement.json 2>/dev/null
jq -c --arg db "$DB" '[.findings[]? | select((.resource // "" | tostring | contains($db)))]' $P/status-after-replacement.json > $P/status-throwaway-after-replacement.json
echo "status after replacement: $(jq -c '[.[] | {resource: (.resource|tostring|split("/")[-1]), category}]' $P/status-throwaway-after-replacement.json)"
jq -c --arg db "$DB" '[.findings[]? | select(.category == "replaced-incarnation") | .resource | tostring] ' $P/status-after-replacement.json > $P/replaced-findings.json
echo "replaced-incarnation findings: $(cat $P/replaced-findings.json)"
[ "$(jq --arg db "$DB" '[.[] | select(contains($db) | not)] | length' $P/replaced-findings.json)" = 0 ] || die "replaced-incarnation reported outside the throwaway"
[ "$(jq '[.[] | select(test("statefulset$|/pvc$"))] | length' $P/replaced-findings.json)" = 2 ] || die "status does not report both replaced members"

step "6 refusal 1: ingest B"
refusal ingest-B $R/ep159-ingest-B "nagarectl db backup-receipts $DB --backup-id B --save-plan DIR" ./runctl.sh db backup-receipts $DB --backup-id $B

snap after-refusal-B
step "7 refusal 2: isolated restore of A"
refusal restore-A $R/ep159-restore-A "nagarectl db restore $DB <A scheduled.backup.id> --restore-id ep159r1 --save-plan DIR" ./runctl.sh db restore $DB $AID --restore-id ep159r1
K -n $NS get sts,pvc,job -o name 2>/dev/null | grep -i 'ep159r1\|restore.*ep159\|ep159.*restore' > $P/scratch-after-restore.txt; echo "scratch objects after restore attempt: $(wc -l < $P/scratch-after-restore.txt)"

snap after-refusal-A
step "7a listing and freshness refuse the replaced source"
./runctl.sh db backup-receipts $DB > $P/listing-after-replacement.out 2>&1; echo "listing exit=$? $(tail -1 $P/listing-after-replacement.out | cut -c1-160)"
./runctl.sh db backup-receipts $DB --check-freshness > $P/freshness-after-replacement.out 2>&1; echo "freshness exit=$? $(tail -1 $P/freshness-after-replacement.out | cut -c1-160)"
step "7b recovery path for A (online verify with the escrow taken before the replacement)"
./runctl.sh db verify-escrowed-backup $DB --backup-id $A --escrow $ROOT/escrow-ep159/personal-$DB.sops.yaml > $P/verify-A.log 2>&1; echo "verify A exit=$? $(sed -n 2p $P/verify-A.log | cut -c1-160)"

step "7c receipt C from the new incarnation (wait up to 16 min)"
Cid=""; for i in $(seq 1 16); do Cid=$(receipts | grep -v "^$A$" | grep -v "^$B$" | head -1); [ -n "$Cid" ] && break; sleep 60; done
if [ -n "$Cid" ]; then echo "$Cid" > $P/receipt-C.txt; echo "C=$Cid"
  refusal ingest-C $R/ep159-ingest-C "nagarectl db backup-receipts $DB --backup-id C --save-plan DIR" ./runctl.sh db backup-receipts $DB --backup-id $Cid
else echo "no receipt C appeared within 16 minutes" | tee $P/receipt-C.txt; fi

snap after-refusal-C
cmp -s <(jq -S .incarnations $P/incarnations-before-replacement.json) <(jq -S .incarnations $P/incarnations-after-refusal-C.json) && echo "incarnations unchanged through every refusal" || echo "INCARNATIONS CHANGED (recorded, see files)"
step "8 no ingestion happened"
./runctl.sh db backup-receipts $DB > $P/receipts-after.txt 2>&1
python3 - $ROOT $DB > $P/accepted-after.json <<'PY'
import json,sys
root,db=sys.argv[1:]
h=json.load(open(root+'/state/nagare/local/inventory/head.json'))
print(json.dumps({"acceptedThrowawayScopes":sorted(e['scope']['name'] for e in h['accepted'] if db in e['scope']['name'])}))
PY
echo "accepted after: $(cat $P/accepted-after.json)"

step "9 confinement"
uids > $P/uids-after.json
python3 - $P $DB <<'PY'
import json,sys
P,db=sys.argv[1:]
key=lambda r:(r['kind'],r['name'])
b={key(r):r['uid'] for r in json.load(open(P+'/uids-baseline.json'))}; a={key(r):r['uid'] for r in json.load(open(P+'/uids-after.json'))}
others={k:(v,a.get(k)) for k,v in b.items() if db not in k[1]}
changed={f"{k[0]}/{k[1]}":v for k,v in others.items() if v[0]!=v[1]}
json.dump({"othersCompared":len(others),"othersChanged":changed},open(P+'/confinement.json','w'),indent=1)
print("confinement: compared",len(others),"changed",len(changed))
PY

step "10 cleanup: joint retire of the database and its ingested receipt scope"
RSCOPE=$(python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print([e['scope']['name'] for e in h['accepted'] if 'scheduled-receipt' in e['scope']['name'] and '$DB' in e['scope']['name']][0])")
if ./runctl.sh inventory retire --scope standalone:database-$DB --scope standalone:$RSCOPE --out $R/ep159-retire > $P/retire.plan.log 2>&1; then
  ./runctl.sh inventory apply $R/ep159-retire --yes > $P/retire.apply.log 2>&1; echo "retire apply: $(tail -1 $P/retire.apply.log)"
else echo "retire plan REFUSED (recorded, not worked around): $(tail -1 $P/retire.plan.log | cut -c1-200)"; fi
headj > $P/head-final.json; echo "final head: $(cat $P/head-final.json)"
snap after-retire

step release
if [ "$(headj | jq -r .activeTransaction)" = null ]; then rm $C/owner $C/since $C/purpose && rmdir $C && echo "cp3 claim released"; else echo "store has an active transaction; claim KEPT"; fi
echo EP159-DONE
