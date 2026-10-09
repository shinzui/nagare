#!/usr/bin/env bash
# F15/F31 late evidence on mp23-c3m, run after the boot registry credential has expired:
# private image pulls that happened after expiry, and the owned pull Secrets' refresh timeline
# sampled across more than one 120 s timer period. Token values are never read.
set -uo pipefail
G=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; E=$G/pending-evidence/f15; mkdir -p $E
export KUBECONFIG=$G/config/nagare/kubeconfigs/mp23-c3m.yaml
K() { command kubectl --context mp23-c3m "$@"; }
VM=$(cat $G/evidence/vm-created-at.txt)
snap() { K get secrets -A -o json | jq --arg t "$(date -u +%FT%TZ)" '{sampledAt:$t, secrets:[.items[] | select(.type=="kubernetes.io/dockerconfigjson") | {namespace:.metadata.namespace, name:.metadata.name, resourceVersion:.metadata.resourceVersion, created:.metadata.creationTimestamp, lastWrite:([.metadata.managedFields[]?.time] | max), annotations:(.metadata.annotations // {} | with_entries(select(.key|test("nagare|refresh|expir"))))}]}'; }
snap > $E/secrets-t0.json; sleep 150; snap > $E/secrets-t1.json
K get events -A -o json | jq '[.items[] | select(.reason=="Pulled" or .reason=="Pulling" or .reason=="Failed") | select(.message|test("pkg.dev")) | {namespace:.metadata.namespace, object:.involvedObject.name, reason, time:(.lastTimestamp // .eventTime), message:.message[0:220]}] | sort_by(.time)' > $E/private-pulls.json
python3 - "$E" "$VM" <<'PY'
import json, sys
from datetime import datetime, timedelta
E, vm = sys.argv[1:]
t = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00"))
boot = t(vm); expiry = boot + timedelta(hours=1)
pulls = json.load(open(f"{E}/private-pulls.json"))
late = [p for p in pulls if p["time"] and t(p["time"]) > expiry and p["reason"] == "Pulled"]
failed = [p for p in pulls if p["reason"] == "Failed"]
s0, s1 = (json.load(open(f"{E}/secrets-t{i}.json")) for i in (0, 1))
boot = json.load(open(f"{E}/secrets-boot.json"))
rv = lambda sample: {(x["namespace"], x["name"]): x["resourceVersion"] for x in sample["secrets"]}
refreshed = sorted(f"{k[0]}/{k[1]}" for k, v in rv(s1).items() if rv(boot).get(k) not in (None, v))
out = {"vmCreated": vm, "bootCredentialExpiresBy": expiry.isoformat(), "pullsAfterBootCredentialExpiry": late,
       "privatePullFailures": failed, "secretSamples": [boot, s0, s1], "secretsRewrittenSinceBoot": refreshed,
       "note": "boot credentials are a one-hour access token from first boot; later private pulls use the owned pull Secrets the 120 s timer refreshes"}
json.dump(out, open(f"{E}/late.json", "w"), indent=1)
print(json.dumps({"latePulls": len(late), "failures": len(failed), "secrets": len(s1["secrets"]), "rewrittenSinceBoot": refreshed}))
PY
