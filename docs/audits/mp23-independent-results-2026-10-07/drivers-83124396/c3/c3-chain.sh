#!/usr/bin/env bash
# Acceptance C3 on mp23-c3m (candidate 83124396) after bootstrap, in runbook order; stops at the
# first failure. Every step writes its own evidence under pending-evidence/ or evidence/.
set -uo pipefail
I=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; L=$I/c3-chain.log
export KUBECONFIG=$I/config/nagare/kubeconfigs/mp23-c3m.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs
run() { echo "== $(date -u +%T) $1" >> $L; bash "$I/$1" >> $L 2>&1; rc=$?; echo "-- $1 rc=$rc" >> $L; [ $rc -eq 0 ] || { echo "CHAIN STOPPED at $1" >> $L; exit 1; }; }
echo "== $(date -u +%T) post-bootstrap status" >> $L
gcloud compute instances describe nagare-c3-1012 --zone us-west1-a --project tan-ng-labs --format="value(creationTimestamp)" > $I/evidence/vm-created-at.txt
$I/runctl.sh inventory status --json > $I/evidence/status-post-bootstrap.json 2>/dev/null
n=$(jq '[.. | strings | select(. == "replaced-incarnation")] | length' $I/evidence/status-post-bootstrap.json)
echo "replaced-incarnation findings after bootstrap: $n" >> $L; [ "$n" = 0 ] || { echo "CHAIN STOPPED: replaced-incarnation after bootstrap" >> $L; exit 1; }
run f15.sh
run phase2.sh
grep -q "PHASE2-PAUSE-FOR-TAKEOVER" $L || { echo "CHAIN STOPPED: phase 2 did not pause for takeover" >> $L; exit 1; }
run takeover.sh
# F49/F52: replaced-incarnation entries in the status samples taken mid-transaction (recorded, not gating).
python3 - $I/pending-evidence/interrupted-recovery $I/evidence/replaced-incarnation-samples.json <<'PY' >> $L
import json, sys
d, out = sys.argv[1:]
count = lambda v: sum(count(x) for x in (v.values() if isinstance(v, dict) else v)) if isinstance(v, (dict, list)) else int(v == "replaced-incarnation")
res = {n: count(json.load(open(f"{d}/{n}-status.json"))) for n in ("database-readiness", "cluster-completion")}
json.dump({"replacedIncarnationEntries": res, "sampledWithin": "interrupted application deploys, before resume or takeover"}, open(out, "w"), indent=1)
print("replaced-incarnation mid-transaction:", res)
PY
run phase2b.sh
run phase3.sh
run access-check.sh
run retained-check.sh
run image-cleanup.sh
run b3.sh
# The late F15/F31 read needs the boot credential (a one-hour token) to have expired.
due=$(python3 -c "import datetime,sys; print(int(datetime.datetime.fromisoformat(open(sys.argv[1]).read().strip()).timestamp()) + 75*60)" $I/evidence/vm-created-at.txt)
while [ "$(date +%s)" -lt "$due" ]; do sleep 30; done
run f15-late.sh
run su-drill.sh
run preview-cleanup.sh
run precheck-runner.sh
run c3-runner.sh
run c3-assemble.sh
echo "CHAIN-DONE" >> $L
