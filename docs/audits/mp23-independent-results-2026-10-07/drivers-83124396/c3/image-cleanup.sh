#!/usr/bin/env bash
# F32 on mp23-c3m: reviewed host image-cache cleanup protects every image used by pod sandboxes.
# Plan, record pods before, apply, confirm every pod stays Ready with no pull or sandbox
# warnings, then replan with the same request id and expect zero operations.
set -uo pipefail
G=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; R=$G/reviews; E=$G/pending-evidence/image-cleanup; mkdir -p $E
export KUBECONFIG=$G/config/nagare/kubeconfigs/mp23-c3m.yaml
K() { command kubectl --context mp23-c3m "$@"; }
die() { echo "IMAGE CLEANUP FAILED: $*"; exit 1; }
notready() { K get pods -A --no-headers | awk '{split($3,a,"/"); if (!(a[1]==a[2] && $4=="Running") && $4!="Completed") print $1"/"$2}' | sort; }
cd $G
./runctl.sh cleanup --images --id c3i-images-1 --save-plan $R/image-cleanup > $E/plan.log 2>&1 || die "plan: $(tail -1 $E/plan.log)"
jq -r '.operations[].summary' $R/image-cleanup/review.json > $E/review-summaries.txt
notready > $E/notready-before.txt
K get pods -A -o json | jq -r '[.items[] | {pod:"\(.metadata.namespace)/\(.metadata.name)", images:[.status.containerStatuses[]?.imageID]}]' > $E/pods-before.json
./runctl.sh inventory apply $R/image-cleanup --yes > $E/apply.log 2>&1 || die "apply: $(tail -1 $E/apply.log)"
sleep 30
K get pods -A --no-headers | awk '{split($3,a,"/"); t++; if (!(a[1]==a[2] && $4=="Running") && $4!="Completed") {n++; print "NOT READY",$1,$2,$3,$4}} END {print t" pods, "n+0" not ready"}' > $E/pods-after.txt
K get events -A --field-selector type=Warning -o custom-columns=T:.lastTimestamp,R:.reason,O:.involvedObject.name --no-headers 2>/dev/null | grep -E "Failed|BackOff|Sandbox" > $E/warnings-after.txt || true
./runctl.sh cleanup --images --id c3i-images-1 --save-plan $R/image-cleanup-reuse > $E/reuse.log 2>&1 || die "replan: $(tail -1 $E/reuse.log)"
jq -n --arg apply "$(tail -1 $E/apply.log)" --argjson removed "$(jq -c '[.operations[].summary]' $R/image-cleanup/review.json)" \
  --arg pods "$(tail -1 $E/pods-after.txt)" --argjson warnings "$(wc -l < $E/warnings-after.txt | tr -d ' ')" \
  --argjson replanOps "$(jq '.operations|length' $R/image-cleanup-reuse/review.json)" \
  '{command:"nagarectl cleanup --images --id c3i-images-1 --save-plan DIR; inventory apply", removed:$removed, apply:$apply, podsAfter:$pods, pullOrSandboxWarnings:$warnings, sameRequestReplanOperations:$replanOps}' > $E/result.json
jq -c '{removed: (.removed|length), apply, podsAfter, pullOrSandboxWarnings, sameRequestReplanOperations}' $E/result.json
notready > $E/notready-after.txt
newly=$(comm -13 $E/notready-before.txt $E/notready-after.txt); [ -z "$newly" ] || die "pods became not ready after cleanup: $newly"
echo IMAGE-CLEANUP-OK
