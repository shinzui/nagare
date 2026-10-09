#!/usr/bin/env bash
# usage: scope-snap.sh ROOT OUT
set -euo pipefail
root=$1; out=$2
"$root/runctl.sh" inventory status --json > "$out.status" 2>/dev/null
ksvc=$(KUBECONFIG="$root/config/nagare/kubeconfigs/local.yaml" command kubectl --context local -n personal get ksvc scenario-b -o json)
python3 - "$out.status" "$out" "$ksvc" <<'PY'
import json,sys
st=json.load(open(sys.argv[1])); k=json.loads(sys.argv[3])
acc=sorted(({"scope":f"{e['scope']['kind']}:{e['scope']['name']}","revision":e['revision']} for e in st['accepted']),key=lambda x:x['scope'])
json.dump({"observedAt":st['observedAt'],"accepted":acc,
 "scenarioBService":{"uid":k['metadata']['uid'],"generation":k['metadata']['generation'],"latestReadyRevision":k['status'].get('latestReadyRevisionName')}},open(sys.argv[2],'w'),indent=1,sort_keys=True)
PY
rm -f "$out.status"
