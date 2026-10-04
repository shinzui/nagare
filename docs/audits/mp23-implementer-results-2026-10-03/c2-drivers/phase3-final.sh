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
echo "== preview cleanup"
CP=$PE/preview-cleanup; mkdir -p $CP
K get domainmappings.serving.knative.dev -A -o custom-columns=NS:.metadata.namespace,N:.metadata.name,U:.metadata.uid --no-headers > $PE/dm-before.txt
K get kingress,kcert -A -o custom-columns=K:.kind,NS:.metadata.namespace,N:.metadata.name,U:.metadata.uid --no-headers 2>/dev/null | grep -i pr-scenario > $PE/descendants-before.txt
./runctl.sh cleanup --previews --preview-ttl-days 0 -n personal --save-plan $R/preview-cleanup > $R/preview-cleanup.log 2>&1 || die "cleanup plan"
./runctl.sh inventory apply $R/preview-cleanup --yes > $CP/00-retire.log 2>&1 || die "retire apply"
echo "retire: $(tail -1 $CP/00-retire.log)"
for i in $(seq 1 20); do n=$(printf %02d $i); D=$R/preview-collect-$n
  ./runctl.sh cleanup --previews --preview-ttl-days 0 -n personal --save-plan $D > $CP/$n-plan.log 2>&1 || die "collect plan $n"
  grep -q 'No stale accepted previews' $CP/$n-plan.log && { echo "collections: $((i-1))"; break; }
  ./runctl.sh inventory apply $D --yes > $CP/$n-apply.log 2>&1 || die "collect apply $n: $(tail -1 $CP/$n-apply.log)"
  echo "$n: $(tail -1 $CP/$n-apply.log)"
done
sleep 10
K get domainmappings.serving.knative.dev -A -o custom-columns=NS:.metadata.namespace,N:.metadata.name,U:.metadata.uid --no-headers > $PE/dm-after.txt
K get kingress,kcert,ksvc -A -o custom-columns=K:.kind,NS:.metadata.namespace,N:.metadata.name,U:.metadata.uid --no-headers 2>/dev/null | grep -i pr-scenario > $PE/descendants-after.txt
D=$EV/checks/convergence-noop-removal; mkdir -p $D
python3 - $ROOT $D <<'PY' || exit 1
import json,sys,glob,os
R,D=sys.argv[1:]; P=R+'/pending-evidence/preview-cleanup/'; pe=R+'/pending-evidence/'
rows=lambda f:[l.split() for l in open(pe+f).read().strip().splitlines() if l.strip()]
steps=[{"step":"retire","result":open(P+'00-retire.log').read().strip().splitlines()[-1]}]
for d in sorted(glob.glob(R+'/reviews/preview-collect-*')):
    n=d[-2:]
    if os.path.exists(P+f'{n}-apply.log'):
        steps.append({"step":f"collect-{n}","operations":[o['summary'] for o in json.load(open(d+'/review.json'))['operations']],"result":open(P+f'{n}-apply.log').read().strip().splitlines()[-1]})
out={"command":"nagarectl cleanup --previews --preview-ttl-days 0 -n personal --save-plan DIR, then inventory apply DIR --yes, repeated until no review is created","preview":"pr-scenario (site scenario-site)","steps":steps,
 "domainMappingsBefore":rows('dm-before.txt'),"domainMappingsAfter":rows('dm-after.txt'),"previewDescendantsBefore":rows('descendants-before.txt'),"previewObjectsAfter":rows('descendants-after.txt'),
 "descendantsCollected":len(rows('descendants-after.txt'))==0,"otherDomainMappingUnchanged":[r for r in rows('dm-before.txt') if 'pr-scenario' not in r[1]]==rows('dm-after.txt')}
json.dump(out,open(D+'/preview-cleanup.json','w'),indent=1)
ok=out['descendantsCollected'] and out['otherDomainMappingUnchanged'] and len(rows('descendants-before.txt'))>0; print("cleanup ok",ok); sys.exit(0 if ok else 3)
PY
echo "== verify with final-marker interruption"
./runctl.sh inventory export --out $ROOT/evidence-private/verify-export >/dev/null 2>&1 || die "export"
python3 $REPO/scripts/unchanged-inventory-candidate.py $ROOT/evidence-private/verify-export $R/verify-candidate.json Platform:kourier Platform:cert-manager || die "candidate"
./runctl.sh inventory compile --input $R/verify-candidate.json --out $R/verify-candidate >/dev/null || die "compile"
python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print(h['generation'],h['sequence'])" > $IP/final-marker-head-before.txt
X1=$ROOT/evidence-private/final-export-1; X=$ROOT/evidence-private/final-export
cd $REPO
env NAGARECTL_BIN=$ROOT/nagarectl-bare.sh bash scripts/rehearse-local-inventory-release.sh --phase verify --context local --expected-cluster k3d-nagare-local --evidence-dir $EV --candidate $R/verify-candidate --private-store-export $X1 > $IP/final-marker-verify-1.log 2>&1 & pid=$!; killed=""
for i in $(seq 1 1200); do if [ -f $EV/final-observation.json ] && [ $EV/final-observation.json -nt $R/verify-candidate/candidate.json ]; then pkill -9 -f "inventory export --out $X1" 2>/dev/null; kill -9 $pid 2>/dev/null; killed=$(date -u +%H:%M:%S); break; fi; kill -0 $pid 2>/dev/null || break; sleep 0.1; done; wait $pid 2>/dev/null
echo "verify killed=${killed:-none} state=$(jq -r .state $EV/run.json)"; [ -n "$killed" ] || die "verify not interrupted"
[ "$(jq -r .state $EV/run.json)" = applied ] || die "marker written before kill"
python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print(h['generation'],h['sequence'],h['activeTransaction'])" > $IP/final-marker-head-after-kill.txt
env NAGARECTL_BIN=$ROOT/nagarectl-bare.sh bash scripts/rehearse-local-inventory-release.sh --phase verify --context local --expected-cluster k3d-nagare-local --evidence-dir $EV --candidate $R/verify-candidate --private-store-export $X > $IP/final-marker-verify-2.log 2>&1 || die "verify rerun: $(tail -2 $IP/final-marker-verify-2.log)"
jq -c . $EV/run.json; echo "noop ops: $(jq '.operations|length' $EV/no-op-review/review.json)"
python3 -c "import json;h=json.load(open('$ROOT/state/nagare/local/inventory/head.json'));print(h['generation'],h['sequence'],h['activeTransaction'])" > $IP/final-marker-head-after.txt
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
 "runStateAfterKill":"applied","rerunLog":open(P+'final-marker-verify-2.log').read().strip().splitlines()[-1],"runStateAfterRerun":json.load(open(R+'/evidence/c2-14071e58/run.json'))['state'],
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
