#!/usr/bin/env bash
# F54 native proof on mp23-c3i (cloud, tan-ng-labs). Bounded sequence:
#   pre: read-only checks with the candidate CLI (node, store, live Service facts)
#   a:   stop the wedged tx-44577a2c... through review (fixed CLI)
#   b:   corrected rvf16 review (REDIS_URL literal) -> plan gate -> apply -> same UIDs + known row
#   c:   zero-operation replan
# Every step stops on the first unexpected result; nothing is worked around.
set -uo pipefail
MODE=${1:?usage: native.sh pre|run}
CLI=${F54_CLI:?set F54_CLI to the candidate nagarectl binary}
ROOT=/private/tmp/nagare-mp23-c3i
F=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/dc0e8853-c761-4c35-88cd-db57750f8f5b/scratchpad/f54
Q=/private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-nagare/e52c3ad3-7837-46c3-9104-2d027c6c1e88/scratchpad/c3/seq
E=$F/evidence; mkdir -p "$E"
TX=tx-44577a2cbba91e46e8e754ffc3ce32b21c0caa146551385b6c6c28b8cc0c527a
OP=op-7a4cc6b7364a9ad834f551a9
SVC_UID=442ecbcb-9b03-41af-9543-0e293089585e
STS_UID=308a3ea3-2cd2-4942-98df-a6ecce29ec62
PVC_UID=6df5e086-0b2b-419c-a633-10ac9f484e48
ROW='1|rvf16-d747f5b7-before-correction'
PAYLOAD=$ROOT/state/nagare/mp23-c3i/platform/nagare-0.4.0-847543896d07-9442ead5f5362fd3
export KUBECONFIG=$ROOT/config/nagare/kubeconfigs/mp23-c3i.yaml
step() { echo "== $(date -u +%H:%M:%S) $*"; }
die() { echo "F54 NATIVE STOPPED: $*"; exit 1; }

# The phase-3a wrapper with the candidate binary and the accepted payload pinned.
run() {
  timeout "${TIMEOUT:-0}" env -i PATH="$PATH" HOME=/Users/shinzui USER=shinzui \
    XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache" \
    CLOUDSDK_ACTIVE_CONFIG_NAME=labs CLOUDSDK_CORE_PROJECT=tan-ng-labs \
    CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true CLOUDSDK_CORE_DISABLE_PROMPTS=true \
    CLOUDSDK_COMPUTE_ZONE=us-west1-a ZONE=us-west1-a \
    SSH_KEY=/Users/shinzui/.ssh/google_compute_engine IAP_MAX_ATTEMPTS=1 \
    KUBECONFIG="$KUBECONFIG" SOPS_AGE_KEY_FILE="$ROOT/age-key.txt" NAGARE_HOST_AGE_KEY_FILE="$ROOT/age-key.txt" \
    NAGARE_BUILDER_PROJECT=tan-ng-labs NAGARE_BUILDER_ZONE=us-west1-a NAGARE_BUILDER_INSTANCE=nix-builder-ep150 \
    NAGARE_MODE=cloud NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev NAGARE_ARTIFACT_REGISTRY_ID=nagare-c3-1008 \
    NAGARE_BASE_DOMAIN=c3-1008.labs.topagentnetwork.net \
    NAGARE_PLATFORM_ROOT="$PAYLOAD" \
    NAGARE_AUTH_ACCESS_IMAGE=us-west1-docker.pkg.dev/tan-ng-labs/nagare/nagare-access@sha256:c679a2627f92f0d7f8dcd2c7edc9d3e6ce400bac7c8702605d79edfc9cf1097c \
    NAGARE_AUTH_EN_IMAGE=us-west1-docker.pkg.dev/tan-ng-labs/nagare/en@sha256:5999f31f823b9fa470e2cab01a10a8cd0fdf574a72740e9373ad9b95624990b3 \
    NAGARE_AUTH_SHOMEI_IMAGE=us-west1-docker.pkg.dev/tan-ng-labs/nagare/shomei@sha256:0b88cb6b7b0a843dd868902ba4dabede2beb65e918cce59404b9f1f6dc3f1bf2 \
    "$CLI" --context mp23-c3i "$@"
}
K() { command kubectl "$@"; }
uids() { K -n personal get ksvc rvf16 -o jsonpath='{.metadata.uid}'; echo -n " "; K -n personal get sts rvf16-pg -o jsonpath='{.metadata.uid}'; echo -n " "; K -n personal get pvc nagare-db-rvf16-pg-data -o jsonpath='{.metadata.uid}'; }
row() { K -n personal exec rvf16-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||chr(124)||v from rv_known"'; }
status() { run inventory status --json > "$E/status-$1.json" 2> "$E/status-$1.err"; jq -c '{active: .activeTransaction, tx: .transactionStatus.transaction, reason: .transactionStatus.reason}' "$E/status-$1.json"; }

[ -d "$PAYLOAD" ] || die "accepted payload workspace missing"
step "pre: node and identities (read-only)"
[ "$(K get nodes -o name)" = node/mp23-c3i-nagare ] || die "kube context is not mp23-c3i: $(K get nodes -o name)"
[ "$(uids)" = "$SVC_UID $STS_UID $PVC_UID" ] || die "UIDs differ before: $(uids)"
[ "$(row)" = "$ROW" ] || die "known row differs before"
K -n personal get ksvc rvf16 -o json --show-managed-fields > "$E/ksvc-before.json"
jq -c '{gen: .metadata.generation, observed: .status.observedGeneration, ready: [.status.conditions[]? | select(.type=="Ready") | .status], managers: [.metadata.managedFields[] | {manager, operation, subresource}]}' "$E/ksvc-before.json"
step "pre: candidate CLI reads the store"
status before
[ "$(jq -r .transactionStatus.transaction "$E/status-before.json")" = "$TX" ] || die "active transaction is not $TX"
[ "$MODE" = pre ] && { echo F54-PRE-DONE; exit 0; }

step "a: reviewed stop of the landed unready update"
run inventory recover "$TX" --operation "$OP" --decision "$Q/4-stop2-decision.json" > "$E/a-stop.log" 2>&1 || die "stop refused: $(tail -2 "$E/a-stop.log")"
tail -1 "$E/a-stop.log"
status after-stop
[ "$(jq -r .activeTransaction "$E/status-after-stop.json")" = null ] || die "store still active after stop"
[ "$(uids)" = "$SVC_UID $STS_UID $PVC_UID" ] || die "UIDs changed by the stop"

step "b: corrected review (REDIS_URL literal)"
run app deploy -f "$F/rvf16-fixed/nagare/Config.hs" --tag c3 --image-resource publication:app-image-scenario-b-c3/scenario-b-c3/oci-image --database-recovery rvf16-pg=rvf16-pg:v1 --save-plan "$F/b-correct" > "$E/b-plan.log" 2>&1 || die "plan refused: $(tail -2 "$E/b-plan.log")"
jq -r '.operations[] | [.operation.action.tag, (.operation.resources|join(","))] | @tsv' "$F/b-correct/review.json" | tee "$E/b-plan-ops.tsv"
# Plan gate: the Service is updated in place; nothing is created, replaced or retired on the three identities.
awk -F'\t' '$1 != "VerifyResource" && $1 != "UpdateResource" && $1 != "CreateResource" {bad=1} END {exit bad}' "$E/b-plan-ops.tsv" || die "unexpected action in the corrected plan"
awk -F'\t' '$1 == "UpdateResource" && $2 == "application:rvf16/rvf16/service" {ok=1} END {exit !ok}' "$E/b-plan-ops.tsv" || die "corrected plan does not update the Service"
awk -F'\t' '$1 == "CreateResource" && ($2 ~ /rvf16\/service$/ || $2 ~ /statefulset$/ || $2 ~ /pvc$/) {bad=1} END {exit bad}' "$E/b-plan-ops.tsv" || die "corrected plan recreates a retained member"
TIMEOUT=580 run inventory apply "$F/b-correct" --yes > "$E/b-apply.log" 2>&1 || die "apply did not converge: $(tail -2 "$E/b-apply.log")"
tail -1 "$E/b-apply.log"
status after-apply
[ "$(uids)" = "$SVC_UID $STS_UID $PVC_UID" ] || die "UIDs changed by the correction: $(uids)"
[ "$(row)" = "$ROW" ] || die "known row differs after correction"
K -n personal get ksvc rvf16 -o json > "$E/ksvc-after.json"
jq -c '{gen: .metadata.generation, observed: .status.observedGeneration, ready: [.status.conditions[]? | select(.type=="Ready") | .status]}' "$E/ksvc-after.json"

step "c: zero-operation replan"
run app deploy -f "$F/rvf16-fixed/nagare/Config.hs" --tag c3 --image-resource publication:app-image-scenario-b-c3/scenario-b-c3/oci-image --database-recovery rvf16-pg=rvf16-pg:v1 --save-plan "$F/c-replan" > "$E/c-plan.log" 2>&1
echo "replan exit $?: $(tail -1 "$E/c-plan.log")"
[ -f "$F/c-replan/review.json" ] && jq -r '[.operations[] | .operation.action.tag] | group_by(.) | map({(.[0]): length}) | add' "$F/c-replan/review.json"
echo F54-NATIVE-DONE
