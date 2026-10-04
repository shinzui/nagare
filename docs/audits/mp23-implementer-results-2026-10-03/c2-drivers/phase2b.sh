#!/usr/bin/env bash
# C2 phase 2b (7d486457): drift + takeover, collision, rename interruption, retained-data collection and history restore
set -uo pipefail
echo "== $(date -u +%H:%M:%S) drift"
(
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad; ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); F=/Users/shinzui/Keikaku/bokuno/nagare/fixtures/inventory-release/local/apps; export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml; cd $ROOT; ./runctl.sh db retire scenario-retire --save-plan $ROOT/reviews/retire > reviews/retire.log 2>&1 && ./runctl.sh inventory apply $ROOT/reviews/retire --yes >> reviews/retire.log 2>&1; echo "retire: $(tail -1 reviews/retire.log)"; command kubectl --context local -n personal get ksvc scenario-b -o json > $ROOT/ksvc-b-before.json; command kubectl --context local -n personal patch ksvc scenario-b --type merge -p '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/max-scale":"5"}}}}}' >/dev/null 2>&1; sleep 3; ./runctl.sh inventory status --json > $ROOT/status-drift.json 2>/dev/null; python3 -c "
import json,collections;st=json.load(open('$ROOT/status-drift.json'));print(collections.Counter(f['category'] for f in st['findings']),collections.Counter(r['category'] for r in st['retained']))"; DEP="app deploy -f $F/scenario-b/nagare/Config.hs --tag c2 --image-resource publication:app-image-scenario-b-c2/scenario-b-c2/oci-image --database-recovery scenario-redis=scenario-redis:v1"; ./runctl.sh $DEP --save-plan $ROOT/reviews/repair-strict > reviews/repair-strict.log 2>&1; ./runctl.sh inventory apply $ROOT/reviews/repair-strict --yes > reviews/repair-strict-apply.log 2>&1; echo "strict: $(tail -1 reviews/repair-strict-apply.log)"; T=$(grep -E '^[0-9a-f]{64}$' reviews/repair-strict.log | head -1); OP=$(python3 -c "
import json;r=json.load(open('$ROOT/reviews/repair-strict/review.json'));print([o['operation']['id'] for o in r['operations'] if o['operation']['action']['tag']=='UpdateResource'][0])"); echo "{\"version\":1,\"transaction\":\"tx-$T\",\"operation\":\"$OP\",\"review\":\"$T\",\"action\":\"abandon-refused-operation\"}" > reviews/repair-strict-abandon.json; ./runctl.sh inventory recover tx-$T --operation $OP --decision $ROOT/reviews/repair-strict-abandon.json > reviews/repair-strict-abandon.log 2>&1; echo "abandon: $(tail -1 reviews/repair-strict-abandon.log)"; ./runctl.sh $DEP --take-over-fields --save-plan $ROOT/reviews/repair-takeover > reviews/repair-takeover.log 2>&1 && ./runctl.sh inventory apply $ROOT/reviews/repair-takeover --yes > reviews/repair-takeover-apply.log 2>&1; echo "takeover: $(tail -1 reviews/repair-takeover-apply.log)"; command kubectl --context local -n personal get ksvc scenario-b -o json --show-managed-fields > $ROOT/ksvc-b-after.json; ./runctl.sh inventory status --json > $ROOT/status-repaired.json 2>/dev/null; python3 -c "
import json,collections;a=json.load(open('$ROOT/ksvc-b-after.json'));b=json.load(open('$ROOT/ksvc-b-before.json'));st=json.load(open('$ROOT/status-repaired.json'))
print(a['metadata']['uid']==b['metadata']['uid'], a['spec']['template']['metadata']['annotations'].get('autoscaling.knative.dev/max-scale'), [m['manager'] for m in a['metadata']['managedFields']], st['activeTransaction'], collections.Counter(f['category'] for f in st['findings']))"
) || { echo "DRIFT FAILED"; exit 1; }
echo "== $(date -u +%H:%M:%S) drift-collision-record"
(
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad; ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); D=$EV/checks/drift-classification; mkdir -p $D; python3 - $ROOT $D <<'EOF'
import json,sys,collections,re
R,D=sys.argv[1:]
st=json.load(open(R+'/status-drift.json'))
json.dump({"observedAt":st['observedAt'],"findingCategories":dict(collections.Counter(f['category'] for f in st['findings'])),
 "retainedCategories":dict(collections.Counter(r['category'] for r in st['retained'])),
 "configurationDrift":[f for f in st['findings'] if f['category']!='converged'],
 "retainedOrphans":[{"resource":r['resource'],"category":r['category'],"physical":r['physical']} for r in st['retained']],
 "edit":"kubectl patch ksvc personal/scenario-b: spec.template.metadata.annotations autoscaling.knative.dev/max-scale 3 -> 5 (field manager kubectl-patch)"},open(D+'/status-drift.json','w'),indent=1,sort_keys=True)
b=json.load(open(R+'/ksvc-b-before.json')); a=json.load(open(R+'/ksvc-b-after.json')); rep=json.load(open(R+'/status-repaired.json'))
last=lambda f: open(R+'/reviews/'+f).read().strip().splitlines()[-1]
dig=lambda f: re.findall(r'^[0-9a-f]{64}$',open(R+'/reviews/'+f).read(),re.M)[0]
json.dump({"strictRepair":{"review":dig('repair-strict.log'),"applyResult":last('repair-strict-apply.log'),"closedWith":"inventory recover ... abandon-refused-operation","recoverResult":last('repair-strict-abandon.log')},
 "takeoverRepair":{"command":"nagarectl app deploy -f apps/scenario-b/nagare/Config.hs ... --take-over-fields --save-plan DIR","review":dig('repair-takeover.log'),
   "reviewSummaryNamesTakeover":any('takes over fields from kubectl-patch' in o['summary'] for o in json.load(open(R+'/reviews/repair-takeover/review.json'))['operations']),"applyResult":last('repair-takeover-apply.log')},
 "serviceUidUnchanged":b['metadata']['uid']==a['metadata']['uid'],"maxScaleAfter":a['spec']['template']['metadata']['annotations'].get('autoscaling.knative.dev/max-scale'),
 "reviewedBytesRestored":a['spec']['template']['metadata']['annotations'].get('autoscaling.knative.dev/max-scale')=="3",
 "managedFieldsAfter":[{"manager":m['manager'],"operation":m.get('operation'),"subresource":m.get('subresource')} for m in a['metadata']['managedFields']],
 "statusAfter":{"activeTransaction":rep['activeTransaction'],"findingCategories":dict(collections.Counter(f['category'] for f in rep['findings']))}},open(D+'/repair.json','w'),indent=1,sort_keys=True)
EOF
F=/Users/shinzui/Keikaku/bokuno/nagare/fixtures/inventory-release/local/apps; D2=$EV/checks/collision-refusal; mkdir -p $D2; before=$($ROOT/runctl.sh inventory store status --json); $ROOT/runctl.sh app deploy -f $F/scenario-collision/nagare/Config.hs --tag c2 --image-resource publication:app-image-scenario-b-c2/scenario-b-c2/oci-image --save-plan $ROOT/reviews/collision > $ROOT/reviews/collision.log 2>&1; code=$?; after=$($ROOT/runctl.sh inventory store status --json); python3 - "$D2" "$code" "$ROOT/reviews/collision.log" "$ROOT/reviews/collision" "$before" "$after" <<'EOF'
import json,sys,os
d,code,log,review,before,after=sys.argv[1:]
text=open(log).read().strip().splitlines(); b,a=json.loads(before),json.loads(after)
out={"command":"nagarectl app deploy -f apps/scenario-collision/nagare/Config.hs --tag c2 --image-resource publication:app-image-scenario-b-c2/scenario-b-c2/oci-image --save-plan DIR",
 "exitCode":int(code),"output":text[-1] if text else "","reviewDirectoryExists":os.path.exists(review),
 "headBefore":{"generation":b["generation"],"headDigest":b["headDigest"]},"headAfter":{"generation":a["generation"],"headDigest":a["headDigest"]}}
json.dump(out,open(d+'/result.json','w'),indent=2,sort_keys=True); print(out['exitCode'],'claim-conflict' in out['output'],out['reviewDirectoryExists'],out['headBefore']==out['headAfter'])
EOF
cd /Users/shinzui/Keikaku/bokuno/nagare && bash /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/rerun/defer-record.sh --evidence-dir "$EV" --mode local --name drift-classification --summary "Status separated application B's kubectl-patch configuration drift from scenario-retire's retained orphans; the strict replan refused the foreign field manager and was closed by abandon-refused-operation, and the --take-over-fields replan restored the reviewed bytes under the same UID with Nagare as sole field manager" --evidence checks/drift-classification/status-drift.json --evidence checks/drift-classification/repair.json && bash /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/rerun/defer-record.sh --evidence-dir "$EV" --mode local --name collision-refusal --summary "A second application claiming application A's route host is refused at composition with claim-conflict; no review is published and the head is unchanged" --evidence checks/collision-refusal/result.json
) || { echo "DRIFT-COLLISION-RECORD FAILED"; exit 1; }
echo "== $(date -u +%H:%M:%S) rename"
(
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad; ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); P=$ROOT/pending-evidence/interrupted-recovery; PE=$ROOT/pending-evidence; export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml; snap() { command kubectl --context local get statefulset,pvc,secret,cronjob,serviceaccount,role,rolebinding,service -A -o json | python3 -c "
import json,sys; d=json.load(sys.stdin)
print(json.dumps(sorted([{'kind':i['kind'],'namespace':i['metadata']['namespace'],'name':i['metadata']['name'],'uid':i['metadata']['uid']} for i in d['items']], key=lambda x:(x['kind'],x['namespace'],x['name'])),indent=1))"; }; shomei() { command kubectl --context local -n nagare-system get secret nagare-shomei-keys -o json | python3 -c "import json,sys,hashlib; d=json.load(sys.stdin); print(json.dumps({'uid':d['metadata']['uid'],'resourceVersion':d['metadata']['resourceVersion'],'dataSha256':hashlib.sha256(json.dumps(d.get('data',{}),sort_keys=True).encode()).hexdigest()}))"; }; snap > $PE/rename-uids-before.json; shomei > $PE/shomei-before.json; cd $ROOT/reviews; $ROOT/runctl.sh db rename postgres scenario-rename-src scenario-renamed --size 1Gi --recovery-backup scenario-rename-src --recovery-key-version v1 --save-plan $ROOT/reviews/rename > rename.log 2>&1 || { echo "plan failed $(tail -1 rename.log)"; exit 1; }; $ROOT/runctl.sh inventory apply $ROOT/reviews/rename --yes > rename-apply.log 2>&1 & pid=$!; killed=""; job=""; for i in $(seq 1 1500); do job=$(command kubectl --context local -n personal get jobs -o name 2>/dev/null | grep 'nagare-migrate-.*-copy' | head -1); if [ -n "$job" ]; then kill -9 $pid; killed=$(date -u +%H:%M:%S); break; fi; kill -0 $pid 2>/dev/null || break; sleep 0.2; done; wait $pid 2>/dev/null; echo "killed=${killed:-none} job=$job"; $ROOT/runctl.sh inventory status --json > $P/migration-status.json; command kubectl --context local -n personal get $job -o jsonpath='{.metadata.uid} {.metadata.creationTimestamp}{"\n"}' > $P/migration-copy-job-before.txt; TX=$(python3 -c "import json;print(json.load(open('$P/migration-status.json'))['activeTransaction'])"); $ROOT/runctl.sh inventory resume $TX --yes > $P/migration-resume.log 2>&1; echo "resume: $(tail -1 $P/migration-resume.log)"; JN=${job#job.batch/}; PFX=${JN%-copy}; command kubectl --context local -n personal get events -o json | python3 -c "
import json,sys; d=json.load(sys.stdin)
ev=[e for e in d['items'] if e['involvedObject'].get('name','').startswith('$PFX')]
print(json.dumps([{'object':e['involvedObject']['kind']+'/'+e['involvedObject']['name'],'uid':e['involvedObject'].get('uid'),'reason':e['reason'],'count':e.get('count'),'message':e['message']} for e in ev],indent=1))" > $P/migration-copy-job-events.json; command kubectl --context local -n personal exec scenario-renamed-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||'"'"'|'"'"'||v from scenario_rename order by id"' > $PE/rename-rows-after.txt; snap > $PE/rename-uids-after.json; shomei > $PE/shomei-after.json; fence=$(command kubectl --context local -n personal get statefulset scenario-rename-src -o jsonpath='{.spec.replicas} {.metadata.annotations.nagare\.dev/migration-fence}'); sched=$(command kubectl --context local -n personal get cronjob nagare-dbbackup-scenario-rename-src -o jsonpath='{.spec.suspend} {.metadata.annotations.nagare\.dev/migration-fence}'); D=$EV/checks/retained-postgresql-rename; mkdir -p $D; RV=$(grep -E '^[0-9a-f]{64}$' rename.log | head -1); python3 - "$D" "$ROOT" "$fence" "$sched" "$RV" <<'EOF'
import json,sys
d,root,fence,sched,rev=sys.argv[1:]
pe=root+'/pending-evidence/'
before=json.load(open(pe+'rename-uids-before.json')); after=json.load(open(pe+'rename-uids-after.json'))
key=lambda r:(r['kind'],r['namespace'],r['name'])
B={key(r):r['uid'] for r in before}; A={key(r):r['uid'] for r in after}
old={k:v for k,v in B.items() if 'scenario-rename-src' in k[2]}; new={k:v for k,v in A.items() if 'scenario-renamed' in k[2]}
same=all(A.get(k)==v for k,v in B.items())
seed=open(pe+'seed/rename.txt').read().split(); rows=open(pe+'rename-rows-after.txt').read().split()
json.dump({"seed":seed,"renamedDatabaseRows":rows,"equal":seed==rows},open(d+'/rows.json','w'),indent=2)
ops=len(json.load(open(root+'/reviews/rename/review.json'))['operations'])
json.dump({"oldIncarnationsRetained":[{"kind":k[0],"name":k[2],"uid":v,"stillPresentWithSameUid":A.get(k)==v} for k,v in sorted(old.items())],
 "newIncarnations":[{"kind":k[0],"name":k[2],"uid":v} for k,v in sorted(new.items())],"everyPreexistingObjectUnchanged":same,
 "oldStatefulSet":{"replicas":fence.split()[0],"migrationFence":fence.split()[1] if len(fence.split())>1 else None},
 "oldBackupSchedule":{"suspend":sched.split()[0],"migrationFence":sched.split()[1] if len(sched.split())>1 else None},
 "review":rev,"operations":ops},open(d+'/uids.json','w'),indent=2)
sb,sa=json.load(open(pe+'shomei-before.json')),json.load(open(pe+'shomei-after.json'))
json.dump({"object":"nagare-system/nagare-shomei-keys","before":sb,"after":sa,"unchanged":sb==sa},open(d+'/unrelated-identity.json','w'),indent=2)
print(seed==rows, same, len(old), len(new), sb==sa, fence, sched, ops)
EOF
cd /Users/shinzui/Keikaku/bokuno/nagare && bash /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/rerun/defer-record.sh --evidence-dir "$EV" --mode local --name retained-postgresql-rename --summary "db rename moved scenario-rename-src to scenario-renamed through $(jq ".operations|length" $ROOT/reviews/rename/review.json) reviewed migration stages; the three known rows read back, the old incarnations stay retained with unchanged UIDs and fenced writers, and the unrelated auth signing key is unchanged" --evidence checks/retained-postgresql-rename/rows.json --evidence checks/retained-postgresql-rename/uids.json --evidence checks/retained-postgresql-rename/unrelated-identity.json
) || { echo "RENAME FAILED"; exit 1; }
echo "== $(date -u +%H:%M:%S) collect"
(
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad; ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml; cd $ROOT; ls reviews | grep -c collect; R=standalone:database-scenario-retire/scenario-retire; neighborsnap() { command kubectl --context local get statefulset,pvc -A -o json | python3 -c "
import json,sys; d=json.load(sys.stdin); print(json.dumps(sorted([[i['kind'],i['metadata']['namespace'],i['metadata']['name'],i['metadata']['uid']] for i in d['items']])))"; }; neighborsnap > pending-evidence/collect-neighbors-before.json; ./runctl.sh inventory status --json > pending-evidence/collect-status-before.json 2>/dev/null; n=0; for group in "backup" "statefulset backup-read-binding" "service backup-read-role backup-account"; do n=$((n+1)); args=(); for m in $group; do args+=(--resource $R/$m); done; ./runctl.sh inventory collect "${args[@]}" --out $ROOT/reviews/collect-$n > reviews/collect-$n.log 2>&1 && ./runctl.sh inventory apply $ROOT/reviews/collect-$n --yes >> reviews/collect-$n.log 2>&1; echo "collect-$n: $(tail -1 reviews/collect-$n.log)"; done; ./runctl.sh inventory collect --resource $R/pvc --out $ROOT/reviews/collect-pvc > reviews/collect-pvc.log 2>&1; echo "pvc exit=$? $(tail -1 reviews/collect-pvc.log | cut -c1-80)"; neighborsnap > pending-evidence/collect-neighbors-after.json; ./runctl.sh inventory status --json > pending-evidence/collect-status-after.json 2>/dev/null; X=$ROOT/evidence-private/history-export; ./runctl.sh inventory export --out $X >/dev/null 2>&1; I=$ROOT/history-restore-root; mkdir -p $I/config $I/state $I/cache; sed "s#XDG_CONFIG_HOME=\"\$root/config\" XDG_STATE_HOME=\"\$root/state\" XDG_CACHE_HOME=\"\$root/cache\"#XDG_CONFIG_HOME=\"$I/config\" XDG_STATE_HOME=\"$I/state\" XDG_CACHE_HOME=\"$I/cache\"#; s#^if \[\[ -f.*##" $ROOT/runctl.sh > $ROOT/runctl-isolated.sh; chmod 700 $ROOT/runctl-isolated.sh; ./runctl-isolated.sh context create local --mode local --registry-host k3d-registry.localhost:5000 --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups --use >/dev/null 2>&1; ./runctl-isolated.sh inventory restore --from $X --yes 2>&1 | tail -1
) || { echo "COLLECT FAILED"; exit 1; }
echo "== $(date -u +%H:%M:%S) retained-data-record"
(
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad; ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); D=$EV/checks/retained-data; mkdir -p $D; python3 - $ROOT $D <<'EOF'
import json,sys,hashlib,os
R,D=sys.argv[1:]
src=json.load(open(R+'/state/nagare/local/inventory/head.json')); dst=json.load(open(R+'/history-restore-root/state/nagare/local/inventory/head.json'))
canon=lambda x: hashlib.sha256(json.dumps(x,sort_keys=True,separators=(',',':')).encode()).hexdigest()
keys=['accepted','converged','retained','generation','sequence','activeTransaction']
h=lambda x:{"generation":x['generation'],"sequence":x['sequence'],"acceptedDigest":canon(x['accepted']),"convergedDigest":canon(x['converged']),"retainedDigest":canon(x.get('retained',[]))}
json.dump({"export":"private, outside the evidence directory","sourceHead":h(src),"restoredHead":h(dst),
 "acceptedScopeRevisions":[{"scope":f"{e['scope']['kind']}:{e['scope']['name']}","revision":e['revision']} for e in src['accepted']],
 "identical":all(src.get(k)==dst.get(k) for k in keys),"isolatedStateRoot":"separate XDG config/state/cache; context local created fresh, then inventory restore --from PRIVATE --yes"},open(D+'/history-restore.json','w'),indent=1,sort_keys=True)
b=json.load(open(R+'/pending-evidence/collect-status-before.json')); a=json.load(open(R+'/pending-evidence/collect-status-after.json'))
ret=lambda st:{r['resource']:r for r in st['retained'] if 'scenario-retire' in r['resource']}
rb,ra=ret(b),ret(a)
nbm={tuple(x[:3]):x[3] for x in json.load(open(R+'/pending-evidence/collect-neighbors-before.json'))}; nam={tuple(x[:3]):x[3] for x in json.load(open(R+'/pending-evidence/collect-neighbors-after.json'))}
neighbors=all(nam.get(k)==v for k,v in nbm.items() if 'scenario-retire' not in k[2])
order=[["backup"],["statefulset","backup-read-binding"],["service","backup-read-role","backup-account"]]
reviews=[open(R+f'/reviews/collect-{i}.log').read().strip().splitlines()[-1] for i in (1,2,3)]
json.dump({"database":"scenario-retire","retire":"db retire scenario-retire (converged)","collectedInOrder":[{"members":g,"result":r} for g,r in zip(order,reviews)],
 "retainedBefore":sorted(x.split('/')[-1] for x in rb),"retainedAfter":sorted(x.split('/')[-1] for x in ra),
 "staysRetained":[{"member":k.split('/')[-1],"physical":v['physical'],"unchangedPhysical":rb.get(k,{}).get('physical')==v['physical']} for k,v in sorted(ra.items())],
 "pvcCollection":{"command":"inventory collect --resource standalone:database-scenario-retire/scenario-retire/pvc --out DIR","output":open(R+'/reviews/collect-pvc.log').read().strip().splitlines()[-1],"reviewSaved":os.path.exists(R+'/reviews/collect-pvc')},
 "neighborStatefulSetsAndPvcsUnchanged":neighbors},open(D+'/collection.json','w'),indent=1,sort_keys=True)
print(json.load(open(D+'/history-restore.json'))['identical'], sorted(x.split('/')[-1] for x in ra), neighbors)
EOF
cd /Users/shinzui/Keikaku/bokuno/nagare && bash /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/rerun/defer-record.sh --evidence-dir "$EV" --mode local --name retained-data --summary "Reviewed collection removed only scenario-retire's stateless companions in dependency order while the PVC, credential and signing key stayed retained and PVC collection was refused; the private history export restored into an isolated state root with identical accepted, converged and retained identities" --evidence checks/retained-data/collection.json --evidence checks/retained-data/history-restore.json
) || { echo "RETAINED-DATA-RECORD FAILED"; exit 1; }
echo PHASE2B-OK
