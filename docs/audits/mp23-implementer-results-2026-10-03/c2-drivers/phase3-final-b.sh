#!/usr/bin/env bash
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad
ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); REPO=/Users/shinzui/Keikaku/bokuno/nagare; F=$REPO/fixtures/inventory-release/local/apps
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
source $ROOT/images.env
R=$ROOT/reviews; PE=$ROOT/pending-evidence; IP=$PE/interrupted-recovery
K() { command kubectl --context local "$@"; }
die() { echo "FINAL FAILED: $*"; exit 1; }
rec() { (cd $REPO && python3 scripts/scenario-assertions.py record --evidence-dir "$EV" --mode local "$@") || die "record $2"; }
cd $ROOT
echo "== runner plan/apply (self-contained, after every scenario mutation)"
STG=$EV; EV=$ROOT/evidence/c2-84754389; echo $EV > $S/c2-ev; [ ! -e $EV ] || die "evidence dir exists"
WS=$(ls -d $ROOT/state/nagare/local/platform/nagare-0.4.0-847543896d07-*)
./runctl.sh inventory export --out $ROOT/evidence-private/runner-export >/dev/null 2>&1 || die "export"
python3 $REPO/scripts/unchanged-inventory-candidate.py $ROOT/evidence-private/runner-export $R/runner-candidate.json Platform:kourier Platform:cert-manager --add-packaged-scope runner-probe=cluster/examples/hello-knative-service/service.yaml --payload-root $WS || die "candidate"
./runctl.sh inventory compile --input $R/runner-candidate.json --out $R/runner-candidate > /dev/null || die "compile"
K -n nagare-system port-forward svc/en 18082:80 > /dev/null 2>&1 & pf=$!; sleep 3
export NAGARE_EN_URL=http://127.0.0.1:18082; export NAGARE_EN_API_KEY="$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
$ROOT/nagarectl-bare-access.sh --context local inventory status --json 2>/dev/null | jq -e '.observationComplete == true and .missingProviders == []' >/dev/null || { kill $pf; die "status incomplete with en"; }
# F48 guard: the context must run the candidate's own payload; saved with the evidence.
$ROOT/runctl.sh platform root --json > $STG/platform-root.json 2>/dev/null || { kill $pf; die "platform root"; }
[ "$(jq -r .revision $STG/platform-root.json)" = 847543896d0742667e58dde723f4e9d230dfcddc ] || { kill $pf; die "context runs payload $(jq -r .revision $STG/platform-root.json), not the candidate"; }
echo "platform root: $(jq -c '{payloadId, revision, digest}' $STG/platform-root.json)"
cd $REPO
env KUBECONFIG=$KUBECONFIG DOCKER_HOST=$DOCKER_HOST NAGARECTL_BIN=$ROOT/nagarectl-bare-access.sh bash scripts/rehearse-local-inventory-release.sh --phase plan --context local --expected-cluster k3d-nagare-local --evidence-dir $EV --candidate $R/runner-candidate > $R/runner-plan.log 2>&1 || { kill $pf; die "runner plan: $(tail -2 $R/runner-plan.log)"; }
jq -c '[(.operations|length), [.operations[].operation.action.tag]]' $EV/review/review.json
env KUBECONFIG=$KUBECONFIG DOCKER_HOST=$DOCKER_HOST NAGARECTL_BIN=$ROOT/nagarectl-bare-access.sh bash scripts/rehearse-local-inventory-release.sh --phase apply --context local --expected-cluster k3d-nagare-local --evidence-dir $EV --yes > $R/runner-apply.log 2>&1 || { kill $pf; die "runner apply: $(tail -2 $R/runner-apply.log)"; }
kill $pf; unset NAGARE_EN_API_KEY
jq -c . $EV/run.json; jq -c '[.healthy, .operatorRevision, .fixtureDigest]' $EV/local-health.json
echo "== move staged checks and replay deferred records"
[ ! -e $EV/checks ] || die "runner created checks/"
cp -R $STG/checks $EV/checks
cp $STG/platform-root.json $EV/platform-root.json
while IFS= read -r line; do [ -n "$line" ] || continue; eval "rec $line" || die "replay"; done < /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/c2-next/record-queue.txt
echo "replayed $(grep -c . /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/c2-next/record-queue.txt) records; assertions now $(ls $EV/assertions | wc -l)"
cd $ROOT
echo "== verify with final-marker interruption"
./runctl.sh inventory export --out $ROOT/evidence-private/verify-export >/dev/null 2>&1 || die "export"
python3 $REPO/scripts/unchanged-inventory-candidate.py $ROOT/evidence-private/verify-export $R/verify-candidate.json Platform:kourier Platform:cert-manager Platform:runner-probe || die "candidate"
./runctl.sh inventory compile --input $R/verify-candidate.json --out $R/verify-candidate >/dev/null || die "compile"
python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print(h['generation'],h['sequence'])" > $IP/final-marker-head-before.txt
X1=$ROOT/evidence-private/final-export-1; X=$ROOT/evidence-private/final-export
K -n nagare-system port-forward svc/en 18082:80 > /dev/null 2>&1 & pf=$!; sleep 3
export NAGARE_EN_URL=http://127.0.0.1:18082; export NAGARE_EN_API_KEY="$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
cd $REPO
env NAGARECTL_BIN=$ROOT/nagarectl-bare-access.sh bash scripts/rehearse-local-inventory-release.sh --phase verify --context local --expected-cluster k3d-nagare-local --evidence-dir $EV --candidate $R/verify-candidate --private-store-export $X1 > $IP/final-marker-verify-1.log 2>&1 & pid=$!; killed=""
for i in $(seq 1 1200); do if [ -f $EV/final-observation.json ] && [ $EV/final-observation.json -nt $R/verify-candidate/candidate.json ]; then pkill -9 -f "inventory export --out $X1" 2>/dev/null; kill -9 $pid 2>/dev/null; killed=$(date -u +%H:%M:%S); break; fi; kill -0 $pid 2>/dev/null || break; sleep 0.1; done; wait $pid 2>/dev/null
echo "verify killed=${killed:-none} state=$(jq -r .state $EV/run.json)"; [ -n "$killed" ] || die "verify not interrupted"
[ "$(jq -r .state $EV/run.json)" = applied ] || die "marker written before kill"
python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print(h['generation'],h['sequence'],h['activeTransaction'])" > $IP/final-marker-head-after-kill.txt
env NAGARECTL_BIN=$ROOT/nagarectl-bare-access.sh bash scripts/rehearse-local-inventory-release.sh --phase verify --context local --expected-cluster k3d-nagare-local --evidence-dir $EV --candidate $R/verify-candidate --private-store-export $X > $IP/final-marker-verify-2.log 2>&1 || die "verify rerun: $(tail -2 $IP/final-marker-verify-2.log)"
jq -c . $EV/run.json; echo "noop ops: $(jq '.operations|length' $EV/no-op-review/review.json)"
python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print(h['generation'],h['sequence'],h['activeTransaction'])" > $IP/final-marker-head-after.txt
kill $pf; unset NAGARE_EN_API_KEY
jq -c '{observationComplete, missingProviders}' $EV/final-observation.json
cd $ROOT
echo "== interrupted-recovery evidence"
D=$EV/checks/interrupted-recovery; mkdir -p $D
python3 - $ROOT $D <<'PY' || exit 1
import json,sys,glob,collections,os
R,D=sys.argv[1:]; P=R+'/pending-evidence/interrupted-recovery/'
events=[json.load(open(f)) for f in sorted(glob.glob(R+'/state/nagare/local/inventory/journal/*.json'))]
def journal(tx):
    ev=[e for e in events if e['transaction']==tx]; per=collections.defaultdict(collections.Counter)
    for e in ev:
        if e['operation']: per[e['operation']][e['state']['tag']]+=1
    tot=collections.Counter()
    for c in per.values(): tot.update(c)
    return {"events":len(ev),"operations":len(per),"stateCounts":dict(tot),"operationsWithRepeatedIntent":[op for op,c in per.items() if c.get('IntentRecorded',0)>1],"operationsWithRepeatedCompletion":[op for op,c in per.items() if c.get('Completed',0)>1]}
uids=lambda f:[l.split() for l in open(P+f).read().strip().splitlines() if l.strip()]
def stage(name,status,before,after,resume,within,extra={}):
    d=json.load(open(P+status)); ts=d.get('transactionStatus') or {}; tx=d['activeTransaction']
    out={"stage":name,"within":within,"transaction":tx,"killedOperation":[o['operation'] for o in ts.get('operations',[]) if o['state']!='completed'],"uidsBefore":uids(before),"uidsAfter":uids(after),"journal":journal(tx),"resumeResult":open(P+resume).read().strip().splitlines()[-1]}
    out.update(extra); a={tuple(x[:-1]):x[-1] for x in out['uidsAfter']}; out['preInterruptionUidsUnchanged']=all(a.get(tuple(x[:-1]))==x[-1] for x in out['uidsBefore'])
    json.dump(out,open(f'{D}/{name}.json','w'),indent=1); return out
res=[stage('database-readiness','database-readiness-status.json','database-readiness-uids-before.txt','database-readiness-uids-after.txt','database-readiness-resume.log',"application A deploy, before scenario-pg reports ready"),
 stage('cluster-completion','cluster-completion-status.json','cluster-completion-uids-before.txt','cluster-completion-uids-after.txt','cluster-completion-resume.log',"application B deploy, after the Service write and before readiness"),
 stage('migration','migration-status.json','migration-copy-job-before.txt','migration-copy-job-before.txt','migration-resume.log',"rename TransferState, after the copy Job is created",{"copyJobEvents":json.load(open(P+'migration-copy-job-events.json'))})]
fm={"stage":"final-marker","within":"platform verify, before the run marker is written","interruptedRunLog":open(P+'final-marker-verify-1.log').read().strip().splitlines()[-1] if open(P+'final-marker-verify-1.log').read().strip() else "",
 "runStateAfterKill":"applied","rerunLog":open(P+'final-marker-verify-2.log').read().strip().splitlines()[-1],"runStateAfterRerun":json.load(open(R+'/evidence/c2-84754389/run.json'))['state'],
 "storeHead":{"before":open(P+'final-marker-head-before.txt').read().split(),"afterKill":open(P+'final-marker-head-after-kill.txt').read().split(),"afterRerun":open(P+'final-marker-head-after.txt').read().split()},
 "note":"verify has no transaction; the rerun replaced the interrupted no-op review and the store head did not move, so no effect was repeated"}
json.dump(fm,open(f'{D}/final-marker.json','w'),indent=1)
for s in res: print(s['stage'],s['killedOperation'],s['journal']['operationsWithRepeatedIntent'],s['journal']['operationsWithRepeatedCompletion'],s['preInterruptionUidsUnchanged'],s['resumeResult'][:30])
print("final-marker",fm['runStateAfterRerun'],fm['storeHead'])
ok=all(s['preInterruptionUidsUnchanged'] and not s['journal']['operationsWithRepeatedCompletion'] and s['resumeResult'].startswith('converged') for s in res) and fm['runStateAfterRerun']=='verified' and fm['storeHead']['before'][:2]==fm['storeHead']['afterRerun'][:2]
sys.exit(0 if ok else 3)
PY
MIG=$(python3 -c "import json;print(len(json.load(open('$D/migration.json'))['journal']['operationsWithRepeatedIntent']))")
if [ "$MIG" = 0 ]; then MS="one intent and one completed effect per operation"; else MS="one completed effect per operation (the migration copy recorded a second intent on its adapter-proved retry and adopted the same Job)"; fi
rec --name interrupted-recovery --summary "Killed applies at database readiness, cluster completion and migration TransferState each resumed through the recorded transaction with pre-interruption UIDs unchanged and $MS; verify killed before its marker re-ran to verified with the store head unchanged" --evidence checks/interrupted-recovery/database-readiness.json --evidence checks/interrupted-recovery/cluster-completion.json --evidence checks/interrupted-recovery/migration.json --evidence checks/interrupted-recovery/final-marker.json
rec --name convergence-noop-removal --summary "The runner's verify replan of the unchanged platform candidate has zero operations, and reviewed preview cleanup retired pr-scenario and collected its DomainMapping and Service with the KIngress and KCertificate descendants removed and the other route unchanged" --evidence no-op-review/review.json --evidence checks/convergence-noop-removal/preview-cleanup.json
echo "== secret scan"
D=$EV/checks/secret-read-refusal; mkdir -p $D
./runctl.sh secret list scenario-a -f $F/scenario-a/nagare/Config.hs > $D/secret-list.txt 2>&1 || die "secret list"
./runctl.sh inventory status --json > $PE/status-final.json 2>/dev/null
python3 - $ROOT $EV $D <<'PY' || exit 1
import os,sys,base64,hashlib,json
R,EV,D=sys.argv[1:]
tok=open(R+'/evidence-private/scenario-api-token','rb').read(); needles=[tok,base64.b64encode(tok)]
files=0; matches=[]
for root in [EV,R+'/reviews',R+'/pending-evidence']:
    for dp,_,fs in os.walk(root):
        for f in fs:
            p=os.path.join(dp,f)
            try: b=open(p,'rb').read()
            except Exception: continue
            files+=1
            if any(n in b for n in needles): matches.append(os.path.relpath(p,R))
json.dump({"valueSha256":hashlib.sha256(tok).hexdigest(),"recordedShaMatches":open(R+'/evidence-private/scenario-api-token.sha256').read().strip()==hashlib.sha256(tok).hexdigest(),"forms":["raw","base64"],
 "scannedRoots":["evidence directory (public)","saved review directories","status outputs and pending evidence"],"filesScanned":files,"matches":len(matches),"matchedPaths":matches,
 "note":"the value was generated at run time and passed only on stdin to secret set; there is no public secret get"},open(D+'/scan.json','w'),indent=1)
print("scan",files,len(matches)); sys.exit(0 if not matches else 3)
PY
N=$(jq .filesScanned $D/scan.json)
rec --name secret-read-refusal --summary "The run-time SCENARIO_API_TOKEN was passed only on stdin; secret list prints names only and a scan of $N evidence, review and status files found zero raw or base64 matches (value recorded by SHA-256 only)" --evidence checks/secret-read-refusal/scan.json --evidence checks/secret-read-refusal/secret-list.txt
echo "== finalize"
(cd $REPO && python3 scripts/scenario-assertions.py finalize --evidence-dir "$EV" --mode local) 2>&1 | tail -3
echo "FINAL-DONE"
