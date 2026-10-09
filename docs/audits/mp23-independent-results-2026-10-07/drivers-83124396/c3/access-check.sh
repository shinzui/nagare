#!/usr/bin/env bash
# C3 access grant/revoke with an interrupted acknowledgement (EP-158), en reached by port-forward.
set -uo pipefail
ROOT=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; RUN=$ROOT/runctl-access.sh; R=$ROOT/reviews; E=$ROOT/pending-evidence/access-grant-revoke; mkdir -p $E
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/mp23-c3m.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs
U=gs://tan-ng-labs-c3-1012-vbmsjgn-state/inventory
K() { command kubectl --context mp23-c3m "$@"; }
die() { echo "ACCESS FAILED: $*"; kill $PF 2>/dev/null; exit 1; }
K -n nagare-system port-forward svc/en 28182:80 > $E/port-forward.log 2>&1 & PF=$!
sleep 3
export NAGARE_EN_URL=http://127.0.0.1:28182
NAGARE_EN_API_KEY=$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d); export NAGARE_EN_API_KEY
HOST=scenario-a.c3-1012.labs.topagentnetwork.net; SUBJECT=0199a1c2-c3a0-7000-8000-00000000c3a1
listing() { $RUN access list --host $HOST --en-url $NAGARE_EN_URL --en-api-key "$NAGARE_EN_API_KEY" 2>/dev/null | tr '\n' ' '; }
BEFORE=$(listing)
$RUN access grant --host $HOST --user $SUBJECT --en-url $NAGARE_EN_URL --en-api-key "$NAGARE_EN_API_KEY" --save-plan $R/access-grant > $E/grant-plan.log 2>&1 || die "grant plan: $(tail -1 $E/grant-plan.log)"
$RUN inventory apply $R/access-grant --yes > $E/grant-apply.log 2>&1 & AP=$!
killed=""
for i in $(seq 1 600); do
  if [ "$(gcloud storage cat $U/head.json 2>/dev/null | jq -r '.activeTransaction // empty')" != "" ]; then kill -9 $AP; killed=$(date -u +%FT%TZ); break; fi
  kill -0 $AP 2>/dev/null || break; sleep 0.2
done
wait $AP 2>/dev/null
$RUN inventory status --json > $E/status-after-kill.json 2>/dev/null
TX=$(jq -r '.activeTransaction // empty' $E/status-after-kill.json)
if [ -n "$TX" ]; then
  $RUN inventory resume $TX --yes > $E/grant-resume.log 2>&1 || die "grant resume: $(tail -1 $E/grant-resume.log)"
fi
sleep 6; AFTER_GRANT=$(listing)
$RUN access revoke --host $HOST --user $SUBJECT --en-url $NAGARE_EN_URL --en-api-key "$NAGARE_EN_API_KEY" --save-plan $R/access-revoke > $E/revoke-plan.log 2>&1 || die "revoke plan: $(tail -1 $E/revoke-plan.log)"
$RUN inventory apply $R/access-revoke --yes > $E/revoke-apply.log 2>&1 || die "revoke apply: $(tail -1 $E/revoke-apply.log)"
sleep 6; AFTER_REVOKE=$(listing)
$RUN access portal --help > $E/portal-help.txt 2>&1
jq -n --arg host $HOST --arg subject $SUBJECT --arg before "$BEFORE" --arg afterGrant "$AFTER_GRANT" --arg afterRevoke "$AFTER_REVOKE" --arg killed "$killed" --arg tx "$TX" \
  --arg grantReview "$(tail -1 $R/access-grant/review.sha256 2>/dev/null)" --arg resume "$(tail -1 $E/grant-resume.log 2>/dev/null)" --arg revoke "$(tail -1 $E/revoke-apply.log)" \
  '{host:$host, subject:$subject, subjectNote:"test subject id; grants are en relationship tuples (D3 browser login remains a stated restriction)", listBefore:$before, interruptedAt:$killed, transactionLeftActive:$tx, resume:$resume, listAfterGrant:$afterGrant, revoke:$revoke, listAfterRevoke:$afterRevoke, subjectListedAfterGrant:($afterGrant|contains($subject)), subjectAbsentAfterRevoke:($afterRevoke|contains($subject)|not)}' > $E/result.json
kill $PF 2>/dev/null
jq -c '{interruptedAt, transactionLeftActive, subjectListedAfterGrant, subjectAbsentAfterRevoke}' $E/result.json
