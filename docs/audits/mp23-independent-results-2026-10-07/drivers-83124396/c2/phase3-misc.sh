#!/usr/bin/env bash
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad
ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); REPO=/private/tmp/nagare-cand-83124396-src; F=$REPO/fixtures/inventory-release/local/apps
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml
source $ROOT/images.env
R=$ROOT/reviews; PE=$ROOT/pending-evidence
K() { command kubectl --context local "$@"; }
die() { echo "MISC FAILED: $*"; exit 1; }
rec() { (cd $REPO && bash /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad/c2-83124396/defer-record.sh --evidence-dir "$EV" --mode local "$@") || die "record $2"; }
cd $ROOT
echo "== adoption"
D=$EV/checks/adoption; mkdir -p $D
printf '{"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"scenario-redis-restore-c2adopt","namespace":"personal","labels":{"c2-drill":"adoption"}},"spec":{"accessModes":["ReadWriteOnce"],"storageClassName":"local-path","resources":{"requests":{"storage":"1Gi"}}}}' | K create -f - >/dev/null || die "adopt pvc"
B=$(./runctl.sh inventory store status 2>&1); ./runctl.sh db restore scenario-redis c2red1 --restore-id c2adopt --save-plan $R/adopt > $R/adopt.log 2>&1; RC=$?; A=$(./runctl.sh inventory store status 2>&1)
PVC=$(K -n personal get pvc scenario-redis-restore-c2adopt -o json); ./runctl.sh inventory status --json > $PE/status-adopt.json 2>/dev/null
RC=$RC B="$B" A="$A" PVC="$PVC" ROOT=$ROOT D=$D python3 - <<'PY' || exit 1
import json,os,sys
root,D=os.environ['ROOT'],os.environ['D']; pvc=json.loads(os.environ['PVC']); st=json.load(open(root+'/pending-evidence/status-adopt.json')); out=open(root+'/reviews/adopt.log').read().strip()
r={"command":"nagarectl db restore scenario-redis c2red1 --restore-id c2adopt --save-plan DIR","foreignObject":{"kind":"PersistentVolumeClaim","namespace":"personal","name":"scenario-redis-restore-c2adopt","uid":pvc['metadata']['uid'],"createdBeforePlanning":True},
 "exitCode":int(os.environ['RC']),"output":out,"errorCode":"adoption-required" if "adoption-required" in out else None,"reviewDirectoryExists":os.path.exists(root+'/reviews/adopt'),"storeBefore":os.environ['B'],"storeAfter":os.environ['A']}
json.dump(r,open(D+'/refusal.json','w'),indent=1)
labels=pvc['metadata'].get('labels',{}); ann=pvc['metadata'].get('annotations',{})
json.dump({"object":{"uid":pvc['metadata']['uid'],"nagareOwnershipLabels":sorted(k for k in labels if 'nagare' in k),"nagareOwnershipAnnotations":sorted(k for k in ann if 'nagare' in k)},
 "statusFindings":len(st['findings']),"statusCategories":sorted(set(f['category'] for f in st['findings'])),"statusMatchesForObject":len([f for f in st['findings'] if pvc['metadata']['uid'] in json.dumps(f) or 'c2adopt' in json.dumps(f)]),"activeTransaction":st.get('activeTransaction'),
 "observation":"inventory status reports only accepted addresses ('unowned' means an accepted address observed without its owner stamp); an unowned object at an unaccepted address is reported by the planner refusal adoption-required"},open(D+'/status-unowned.json','w'),indent=1)
ok=r['exitCode']!=0 and r['errorCode']=='adoption-required' and not r['reviewDirectoryExists'] and r['storeBefore']==r['storeAfter']; print("adoption ok",ok); sys.exit(0 if ok else 3)
PY
U=$(K -n personal get pvc scenario-redis-restore-c2adopt -o jsonpath='{.metadata.uid}'); printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}' $U | K delete --raw /api/v1/namespaces/personal/persistentvolumeclaims/scenario-redis-restore-c2adopt -f - >/dev/null || die "adopt delete"; echo "{\"deletedUid\":\"$U\"}" > $D/cleanup.json
rec --name adoption --summary "An unowned PVC at a restore's planned scratch address refused planning with adoption-required; no review saved, store generation unchanged; the object was then deleted by exact UID" --evidence checks/adoption/refusal.json --evidence checks/adoption/status-unowned.json --evidence checks/adoption/cleanup.json
echo "== independent-scope"
D=$EV/checks/independent-scope-preservation; mkdir -p $D
$S/scope-snap.sh $ROOT $D/before.json || die "snap before"
./runctl.sh env set scenario-a -f $F/scenario-a/nagare/Config.hs --runtime SCENARIO_MODE updated --reviewed --save-plan $R/update-a > $R/update-a.log 2>&1 && ./runctl.sh inventory apply $R/update-a --yes >> $R/update-a.log 2>&1 || die "update-a: $(tail -1 $R/update-a.log)"
echo "update-a: $(tail -1 $R/update-a.log)"
$S/scope-snap.sh $ROOT $D/after.json || die "snap after"
python3 - $D $(grep -E '^[0-9a-f]{64}$' $R/update-a.log | head -1) $ROOT <<'PY' || exit 1
import json,sys
D,rev,root=sys.argv[1:]
b=json.load(open(D+'/before.json')); a=json.load(open(D+'/after.json'))
B={x['scope']:x['revision'] for x in b['accepted']}; A={x['scope']:x['revision'] for x in a['accepted']}
changed=[{"scope":k,"before":B.get(k),"after":A.get(k)} for k in sorted(set(B)|set(A)) if B.get(k)!=A.get(k)]
plat=[k for k in B if k.startswith('Platform:')]
diff={"review":rev,"reviewOperations":len(json.load(open(root+'/reviews/update-a/review.json'))['operations']),"changedScopes":changed,"platformScopesCompared":len(plat),
 "platformScopesUnchanged":all(B[k]==A.get(k) for k in plat),"scenarioBRevisionUnchanged":B['Application:scenario-b']==A['Application:scenario-b'],"scenarioBServiceUnchanged":b['scenarioBService']==a['scenarioBService']}
json.dump(diff,open(D+'/diff.json','w'),indent=1,sort_keys=True)
ok=diff['platformScopesUnchanged'] and diff['scenarioBRevisionUnchanged'] and diff['scenarioBServiceUnchanged'] and all(c['scope'].startswith('Application:env-scenario-a') for c in changed)
print("independent ok",ok,len(plat),changed); sys.exit(0 if ok else 3)
PY
rec --name independent-scope-preservation --summary "update-a (env set scenario-a, one operation) changed only application A's runtime env scope; scenario-b's revision and Service UID and all platform revisions were unchanged" --evidence checks/independent-scope-preservation/before.json --evidence checks/independent-scope-preservation/after.json --evidence checks/independent-scope-preservation/diff.json
echo "== access"
P=$PE/access; mkdir -p $P; H=scenario-a.127-0-0-1.sslip.io; U=0199a1c2-c2a0-7000-8000-00000000c2a1
K -n nagare-system port-forward svc/en 18082:80 > /dev/null 2>&1 & pf=$!; sleep 3
export NAGARE_EN_URL=http://127.0.0.1:18082; export NAGARE_EN_API_KEY="$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
./runctl-access.sh access list --host $H > $P/list-before.txt 2>&1
./runctl-access.sh access grant --host $H --user $U --save-plan $R/access-grant > $P/grant.log 2>&1 && ./runctl-access.sh inventory apply $R/access-grant --yes >> $P/grant.log 2>&1 || { kill $pf; die "grant: $(tail -1 $P/grant.log)"; }
for i in $(seq 1 12); do sleep 5; ./runctl-access.sh access list --host $H > $P/list-after-grant.txt 2>&1; grep -q $U $P/list-after-grant.txt && break; done
./runctl-access.sh access revoke --host $H --user $U --save-plan $R/access-revoke > $P/revoke.log 2>&1 && ./runctl-access.sh inventory apply $R/access-revoke --yes >> $P/revoke.log 2>&1 || { kill $pf; die "revoke: $(tail -1 $P/revoke.log)"; }
for i in $(seq 1 12); do sleep 5; ./runctl-access.sh access list --host $H > $P/list-after-revoke.txt 2>&1; grep -q $U $P/list-after-revoke.txt || break; done
kill $pf; unset NAGARE_EN_API_KEY
D=$EV/checks/access-grant-revoke; mkdir -p $D
python3 - $ROOT $P $D $U <<'PY' || exit 1
import json,sys,re
R,P,D,U=sys.argv[1:]
r=lambda f: open(P+'/'+f).read().strip(); dig=lambda f: re.findall(r'^[0-9a-f]{64}$',open(P+'/'+f).read(),re.M)[0]
summ=lambda d: [o['summary'] for o in json.load(open(R+'/reviews/'+d+'/review.json'))['operations']]
g={"host":"scenario-a.127-0-0-1.sslip.io","subject":U,"subjectNote":"test subject id; grants are en relationship tuples, so no shomei account or browser is needed (D3 browser login remains a stated restriction)",
 "review":dig('grant.log'),"operations":summ('access-grant'),"result":r('grant.log').splitlines()[-1],"listBefore":r('list-before.txt'),"listAfterGrant":r('list-after-grant.txt'),"subjectListedAfterGrant":U in r('list-after-grant.txt'),"note":"access list polled every 5 s past en's read cache"}
v={"host":"scenario-a.127-0-0-1.sslip.io","subject":U,"review":dig('revoke.log'),"operations":summ('access-revoke'),"result":r('revoke.log').splitlines()[-1],"listAfterRevoke":r('list-after-revoke.txt'),"subjectAbsentAfterRevoke":U not in r('list-after-revoke.txt')}
json.dump(g,open(D+'/grant.json','w'),indent=1); json.dump(v,open(D+'/revoke.json','w'),indent=1)
ok=g['subjectListedAfterGrant'] and v['subjectAbsentAfterRevoke']; print("access ok",ok); sys.exit(0 if ok else 3)
PY
rec --name access-grant-revoke --summary "Reviewed access grant and revoke for a test subject on scenario-a.127-0-0-1.sslip.io converged as en viewer tuples; access list showed the subject after the grant and not after the revoke (polled past en's read cache); browser login remains a stated restriction" --evidence checks/access-grant-revoke/grant.json --evidence checks/access-grant-revoke/revoke.json
echo "== f36"
P=$PE/f36; mkdir -p $P
./runctl.sh db backup scenario-redis --backup-id c2f36 --save-plan $R/backup-f36 > $R/backup-f36.log 2>&1 && ./runctl.sh inventory apply $R/backup-f36 --yes >> $R/backup-f36.log 2>&1 || die "f36 backup"
./runctl.sh db restore scenario-redis c2f36 --restore-id c2f36r --save-plan $R/restore-f36 > $R/restore-f36.log 2>&1 || die "f36 restore plan"
cat <<YAML | K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: drill-mc, namespace: nagare-system, labels: {nagare.dev/drill: nagare-verify}}
spec:
  restartPolicy: Never
  containers:
  - name: mc
    image: ${NAGARE_LOCAL_MC_IMAGE}
    command: ["sh", "-c", "sleep 1800"]
    envFrom: [{secretRef: {name: nagare-minio-credentials}}]
YAML
K -n nagare-system wait --for=condition=Ready pod/drill-mc --timeout=120s >/dev/null || die "drill pod"
VID=$(K -n nagare-system exec drill-mc -- sh -c 'mc alias set d http://minio:9000 "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null && mc ls --versions d/nagare-backups/manual-databases/personal/scenario-redis/' | awk '$NF=="c2f36.rdb.gz"{print $(NF-3)}')
[ -n "$VID" ] || die "f36 version id"
K -n nagare-system exec drill-mc -- sh -c "mc alias set d http://minio:9000 \"\$AWS_ACCESS_KEY_ID\" \"\$AWS_SECRET_ACCESS_KEY\" >/dev/null && mc rm --version-id $VID d/nagare-backups/manual-databases/personal/scenario-redis/c2f36.rdb.gz" > $P/version-removal.txt 2>&1
K -n nagare-system delete pod drill-mc --wait=false >/dev/null
timeout 1200 ./runctl.sh inventory apply $R/restore-f36 --yes > $P/apply.log 2>&1; echo "f36 apply: $(tail -1 $P/apply.log)"
K -n personal logs scenario-redis-restore-c2f36r-0 -c download --previous 2>&1 | tail -3 > $P/download-log-tail.txt
TXF=$(python3 -c "import re;print(re.findall(r'(tx-[0-9a-f]{64}) at (op-[0-9a-f]+)',open('$P/apply.log').read())[-1][0])"); OPF=$(python3 -c "import re;print(re.findall(r'(tx-[0-9a-f]{64}) at (op-[0-9a-f]+)',open('$P/apply.log').read())[-1][1])")
printf '{"version":1,"transaction":"%s","operation":"%s","review":"%s","action":"abandon-partial-database-restore"}\n' $TXF $OPF ${TXF#tx-} > $P/decision.json
./runctl.sh inventory recover $TXF --operation $OPF --decision $P/decision.json > $P/recover.log 2>&1 || die "f36 recover: $(tail -1 $P/recover.log)"
echo "f36 recover: $(tail -1 $P/recover.log)"
python3 - $ROOT $P $VID ${TXF#tx-} <<'PY'
import json,sys,re
R,P,vid,rev=sys.argv[1:]; r=lambda f: open(P+'/'+f).read().strip()
h=json.load(open(R+'/state/nagare/local/inventory/head.json'))
json.dump({"finding":"F36","candidate":"831243962c6b80f91da1028cdab8238ae6acdabd","backup":{"id":"c2f36","database":"scenario-redis"},"restoreReview":rev,"restoreId":"c2f36r",
 "removedObjectVersion":{"object":"s3://nagare-backups/manual-databases/personal/scenario-redis/c2f36.rdb.gz","versionId":vid},"applyResult":r('apply.log').splitlines()[-1],"downloadLogTail":r('download-log-tail.txt'),
 "recovery":{"action":"abandon-partial-database-restore","result":r('recover.log').splitlines()[-1]},"storeIdleAfter":h['activeTransaction'] is None and h['accepted']==h['converged']},open(P+'/f36-native.json','w'),indent=1)
print("f36 idle", h['activeTransaction'] is None)
PY
echo "== freshness"
for i in $(seq 1 40); do ./runctl.sh db backup-receipts scenario-pg --check-freshness > $PE/freshness-scenario-pg.txt 2>&1; grep -q 'freshness: healthy' $PE/freshness-scenario-pg.txt && break; sleep 30; done
./runctl.sh server status > $PE/server-status.txt 2>&1
for db in scenario-pg scenario-redis scenario-ch; do ./runctl.sh db backup-receipts $db --check-freshness > $PE/freshness-$db.txt 2>&1; done
D=$EV/checks/backup-freshness; mkdir -p $D; cp $PE/server-status.txt $D/server-status.txt
python3 - $ROOT $D <<'PY' || exit 1
import json,sys,re
R,D=sys.argv[1:]; rows=[]
for db in ['scenario-pg','scenario-redis','scenario-ch']:
    t=open(f'{R}/pending-evidence/freshness-{db}.txt').read()
    line=[l for l in t.splitlines() if l.startswith('Recovery-point freshness')][0]
    m=re.search(r'freshness: (\w+); age=(\d+)s; objective=(\w+)',line)
    rows.append({"database":db,"grade":m.group(1),"ageSeconds":int(m.group(2)),"objective":m.group(3),"receipts":len(re.findall(r'^[0-9a-f-]{36}\s',t,re.M)),"line":line})
json.dump({"command":"nagarectl db backup-receipts NAME --check-freshness","databases":rows,"allHealthy":all(r['grade']=='healthy' for r in rows)},open(D+'/freshness.json','w'),indent=1)
ok=all(r['grade']=='healthy' for r in rows); print("freshness",[(r['database'],r['grade'],r['ageSeconds']) for r in rows]); sys.exit(0 if ok else 3)
PY
rec --name backup-freshness --summary "server status and db backup-receipts --check-freshness grade scenario-pg, scenario-redis and scenario-ch healthy under the hourly objective from verified scheduled receipts" --evidence checks/backup-freshness/server-status.txt --evidence checks/backup-freshness/freshness.json
echo "MISC-OK"
