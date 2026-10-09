#!/usr/bin/env bash
set -uo pipefail
S=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/fe35126f-a94c-4190-a632-3310e450547d/scratchpad
ROOT=$(cat $S/c2-root); EV=$(cat $S/c2-ev); REPO=/private/tmp/nagare-cand-83124396-src; F=$REPO/fixtures/inventory-release/local/apps
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/local.yaml DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
source $ROOT/images.env
R=$ROOT/reviews; PE=$ROOT/pending-evidence; IP=$PE/interrupted-recovery
K() { command kubectl --context local "$@"; }
die() { echo "FINAL FAILED: $*"; exit 1; }
rec() { (cd $REPO && python3 scripts/scenario-assertions.py record --evidence-dir "$EV" --mode local "$@") || die "record $2"; }
settle() { # wait until every APIService is Available and namespaced discovery is identical across two reads 15s apart
  local a b
  for i in $(seq 1 40); do
    if [ "$(K get apiservices -o json | jq '[.items[] | select(([.status.conditions[]? | select(.type=="Available") | .status] | first) != "True")] | length')" = 0 ]; then
      a=$(K api-resources --namespaced=true -o name 2>/dev/null | sort | shasum); sleep 15; b=$(K api-resources --namespaced=true -o name 2>/dev/null | sort | shasum)
      [ "$a" = "$b" ] && { echo "cluster API discovery settled"; return 0; }
    else sleep 5; fi
  done; die "API discovery did not settle"; }
cd $ROOT
echo "== preview cleanup"
settle
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
for d in sorted(glob.glob(R+'/reviews/preview-collect-[0-9][0-9]')):
    n=d[-2:]
    if os.path.exists(P+f'{n}-apply.log'):
        steps.append({"step":f"collect-{n}","operations":[o['summary'] for o in json.load(open(d+'/review.json'))['operations']],"result":open(P+f'{n}-apply.log').read().strip().splitlines()[-1]})
out={"command":"nagarectl cleanup --previews --preview-ttl-days 0 -n personal --save-plan DIR, then inventory apply DIR --yes, repeated until no review is created","preview":"pr-scenario (site scenario-site)","steps":steps,
 "domainMappingsBefore":rows('dm-before.txt'),"domainMappingsAfter":rows('dm-after.txt'),"previewDescendantsBefore":rows('descendants-before.txt'),"previewObjectsAfter":rows('descendants-after.txt'),
 "descendantsCollected":len(rows('descendants-after.txt'))==0,"otherDomainMappingUnchanged":[r for r in rows('dm-before.txt') if 'pr-scenario' not in r[1]]==rows('dm-after.txt')}
json.dump(out,open(D+'/preview-cleanup.json','w'),indent=1)
ok=out['descendantsCollected'] and out['otherDomainMappingUnchanged'] and len(rows('descendants-before.txt'))>0; print("cleanup ok",ok); sys.exit(0 if ok else 3)
PY
echo FINAL-A-OK
