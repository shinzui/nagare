#!/usr/bin/env bash
# C3 shared-history takeover: deploy-b's interrupted transaction is refused from root B for
# planning and plain resume, then converged by explicit takeover; then phase 2b continues.
set -uo pipefail
G=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; B=/Users/shinzui/.local/state/nagare-verify/mp23-c3m-b; E=$G/pending-evidence/shared-history-takeover; mkdir -p $E
P=$G/pending-evidence/interrupted-recovery
export CLOUDSDK_ACTIVE_CONFIG_NAME=labs KUBECONFIG=$G/config/nagare/kubeconfigs/mp23-c3m.yaml
U=gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory
quiet() { grep -v -E "^(  warning|warning: Application|context guard)" "$1" | tail -1 | cut -c1-250; }
mkdir -p $B/config/nagare/kubeconfigs; cp $G/config/nagare/kubeconfigs/mp23-c3m.yaml $B/config/nagare/kubeconfigs/; chmod 600 $B/config/nagare/kubeconfigs/mp23-c3m.yaml
TX=$(cat $P/cluster-completion-tx.txt); echo $TX > $E/tx.txt
gcloud storage cat $U/head.json | jq '{generation, sequence, activeTransaction, executorClaim}' > $E/head-before.json
$B/runctl.sh inventory resume $TX --yes > $E/b-resume-plain.stdout 2> $E/b-resume-plain.stderr; echo "plain exit=$? $(quiet $E/b-resume-plain.stderr)"
$B/runctl.sh db backup scenario-pg --backup-id c3i-takeover-probe --save-plan $E/b-other-plan > $E/b-other-plan.stdout 2> $E/b-other-plan.stderr; echo "other exit=$? $(quiet $E/b-other-plan.stderr)"
start=$(date +%s); $B/runctl.sh inventory resume $TX --yes --take-over > $E/b-takeover.stdout 2> $E/b-takeover.stderr; code=$?
echo "{\"exit\":$code,\"seconds\":$(( $(date +%s) - start ))}" | tee $E/b-takeover.result.json; tail -1 $E/b-takeover.stdout
[ $code -eq 0 ] || { echo "TAKEOVER FAILED"; exit 1; }
gcloud storage cat $U/head.json | jq '{generation, sequence, activeTransaction, executorClaim}' > $E/head-after.json
kubectl --context mp23-c3m -n personal get ksvc,statefulset,pvc -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid --no-headers 2>/dev/null | grep -E 'scenario-(b|redis)' > $P/cluster-completion-uids-after.txt
diff $P/cluster-completion-uids-before.txt $P/cluster-completion-uids-after.txt && echo "uids unchanged across takeover"
touch $G/reviews/deploy-b.done
echo TAKEOVER-OK
