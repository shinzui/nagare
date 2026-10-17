#!/usr/bin/env bash
# EP-198 M3: confirm the admin API on a cloud context after its transition enabled it. Run
# from the operator shell of that context (NAGARE_CONTEXT and KUBECONFIG set; the reader's sops
# Secret in its cluster-secrets directory). Through the public gateway it drives an anonymous
# client and a throwaway Shomei service account against admin.<base>/v1 and measures warm
# latency to GCS; from pods it tries to bypass the gateway and to reach the node's metadata
# credential; with the reader's own key it checks that IAM refuses everything but the recorded
# reads. It grants and revokes only its own service account and deletes only its own pods.
# Every step stops at its first unexpected answer. The record (no secret) is
# $NAGARE_PROOF_OUT/admin-api-cloud-proof.json.
#
# NAGARE_PROOF_REHEARSAL=local rehearses it on a local context bootstrapped by
# scripts/site-access-drill.sh with the admin API: the gateway through Kourier and the local
# CA, everything except the Cloud Storage IAM section.
set -euo pipefail
REHEARSAL="${NAGARE_PROOF_REHEARSAL:-}"

: "${NAGARE_CONTEXT:?the cloud context the API runs in}"
: "${KUBECONFIG:?the kubeconfig of that context}"
: "${NAGARE_PROOF_OUT:?a new directory for the record}"
NAGARECTL="${NAGARE_PROOF_NAGARECTL:-nagarectl}"
CURL_IMAGE=curlimages/curl:8.10.1
SHOMEI_PORT="${NAGARE_PROOF_SHOMEI_PORT:-18094}"
mkdir -p "$NAGARE_PROOF_OUT"
OUT="$(cd "$NAGARE_PROOF_OUT" && pwd)"
WORK="$(mktemp -d)"
chmod 700 "$WORK"
: > "$OUT/observations.tsv"
log() { printf '%s cloud proof: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
record() { printf '%s\t%s\n' "$1" "$2" >> "$OUT/observations.tsv"; log "$1: $2"; }
expect() { [ "$2" = "$3" ] || { echo "cloud proof: $1: got $2, wanted $3" >&2; exit 1; }; record "$1" "$2"; }
N() { "$NAGARECTL" --context "$NAGARE_CONTEXT" "$@"; }
K() { kubectl "$@"; }
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  K -n personal delete pod admin-proof-probe admin-proof-lookalike --ignore-not-found >/dev/null 2>&1 || true
  K -n nagare-system delete pod admin-proof-neighbour --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

eval "$(N context env)"
CURL=()
if [ "$REHEARSAL" = local ]; then
  [ "${NAGARE_MODE:-}" = local ] || { echo "a local rehearsal needs a local context" >&2; exit 1; }
  K -n cert-manager get secret nagare-local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK/ca.pem"
  K -n kourier-system port-forward svc/kourier 18453:443 >/dev/null 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 30); do nc -z 127.0.0.1 18453 2>/dev/null && break; sleep 1; done
  CURL=(--cacert "$WORK/ca.pem" --connect-to "admin.$NAGARE_BASE_DOMAIN:443:127.0.0.1:18453")
else
  [ "${NAGARE_MODE:-}" = cloud ] || { echo "the context is not a cloud context" >&2; exit 1; }
fi
HOST="admin.$NAGARE_BASE_DOMAIN"
nodes="$(K get nodes -o jsonpath='{.items[*].metadata.name}')"
record "context" "$NAGARE_CONTEXT ($CLOUDSDK_CORE_PROJECT), nodes $nodes"
candidate="$(N version --json)"
record "nagarectl" "$(printf '%s' "$candidate" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("version"), d.get("revision"))')"

# --- 1. the converged scope ---
K -n nagare-system rollout status deploy/nagare-admin-api --timeout=120s >/dev/null
record "admin API image" "$(K -n nagare-system get deploy nagare-admin-api -o jsonpath='{.spec.template.spec.containers[0].image}')"
expect "admin API pod user" "$(K -n nagare-system get deploy nagare-admin-api -o jsonpath='{.spec.template.spec.securityContext.runAsUser}')" "$([ "$REHEARSAL" = local ] && echo 0 || echo 10001)"
expect "admin route target" "$(K -n nagare-system get domainmapping "$HOST" -o jsonpath='{.spec.ref.name}')" "nagare-access"
record "backend entry" "$(K -n nagare-system get configmap nagare-access-backends -o json | python3 -I -c 'import json,sys; m=json.loads(json.load(sys.stdin)["data"]["backends.json"]); print(json.dumps(m[sys.argv[1]], sort_keys=True))' "$HOST")"

# --- 2. the public gateway ---
get() { # path [curl args...]
  local path="$1"; shift
  curl -sS -o "$WORK/body" -D "$WORK/headers" -w '%{http_code}' --max-time 30 ${CURL[@]+"${CURL[@]}"} "$@" "https://$HOST$path" 2>/dev/null || true
}
header() { sed -n "s/^$1: *\\(.*\\)$/\\1/Ip" "$WORK/headers" | tr -d '\r' | tail -1; }
code() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("code"))' "$WORK/body" 2>/dev/null || echo none; }
expect "anonymous /v1 without Accept" "$(get /v1/platform/version)" "401"
expect "anonymous problem code" "$(code)" "unauthenticated"
expect "anonymous challenge" "$(header WWW-Authenticate)" "Bearer"
expect "anonymous UI document" "$(get / -H 'Accept: text/html')" "302"

# --- 3. a throwaway Shomei service account through the bearer path ---
created="$(K -n nagare-system exec deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin service-accounts create --display-name "admin API cloud proof")"
client_id="$(printf '%s\n' "$created" | sed -n 's/^client_id: *\([^ ]*\).*/\1/p')"
client_secret="$(printf '%s\n' "$created" | sed -n 's/^client_secret: *\([^ ]*\).*/\1/p')"
unset created
[ -n "$client_id" ] && [ -n "$client_secret" ] || { echo "shomei-admin printed no client credentials" >&2; exit 1; }
record "service account" "$client_id"
K -n nagare-system port-forward svc/shomei "$SHOMEI_PORT:80" >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$SHOMEI_PORT" 2>/dev/null && break; sleep 1; done
bearer="$(curl -sS --max-time 20 -u "$client_id:$client_secret" -d grant_type=client_credentials "http://127.0.0.1:$SHOMEI_PORT/oauth/token" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
unset client_secret
machine="$(printf '%s' "$bearer" | python3 -I -c 'import base64,json,sys; p=sys.stdin.read().split(".")[1]; print(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4)))["sub"])')"
as_machine() { get "$1" -H "Authorization: Bearer $bearer" "${@:2}"; }
expect "service account, no grant" "$(as_machine /v1/inventory/head)" "403"
export NAGARE_EN_API_KEY="$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
N access grant --host "$HOST" --user "$machine" --save-plan "$WORK/grant" > /dev/null
N inventory apply "$WORK/grant" --yes > "$WORK/grant.log" 2>&1 || { tail -3 "$WORK/grant.log" >&2; exit 1; }
for _ in $(seq 1 90); do [ "$(as_machine /v1/inventory/head)" = 200 ] && break; sleep 1; done
expect "granted service account, head" "$(as_machine /v1/inventory/head)" "200"
record "head revision" "$(header Nagare-Head-Revision)"
etag="$(header ETag)"
expect "conditional head" "$(as_machine /v1/inventory/head -H "If-None-Match: $etag")" "304"
record "first sites read (cold for this list)" "$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 30 ${CURL[@]+"${CURL[@]}"} -H "Authorization: Bearer $bearer" "https://$HOST/v1/sites")"
for route in /v1/inventory/scopes /v1/access/grants /v1/inventory/publications; do
  expect "granted service account, $route" "$(as_machine "$route")" "200"
done

# --- 4. warm latency through the public gateway to GCS: 100 requests at concurrency 8 ---
for route in /v1/inventory/head /v1/sites /v1/inventory/scopes; do
  seq 1 100 | xargs -P 8 -I{} curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 30 ${CURL[@]+"${CURL[@]}"} \
    -H "Authorization: Bearer $bearer" "https://$HOST$route" > "$OUT/latency-${route//\//_}.txt"
  record "warm latency $route" "$(python3 -I -c '
import sys
rows=[l.split() for l in open(sys.argv[1])]
assert len(rows)==100 and all(c=="200" for c,_ in rows), [c for c,_ in rows if c!="200"][:5]
t=sorted(float(s) for _,s in rows)
assert t[94] < 2.0, "p95 %.3f s exceeds the 2 s budget" % t[94]
print("p50 %.3f s, p95 %.3f s, max %.3f s" % (t[49], t[94], t[-1]))
' "$OUT/latency-${route//\//_}.txt")"
done

# --- 5. no path around the gateway, and no node credential from the API pod ---
pod="$(K -n nagare-system get pod -l app.kubernetes.io/name=nagare-admin-api -o jsonpath='{.items[0].metadata.name}')"
pod_ip="$(K -n nagare-system get pod "$pod" -o jsonpath='{.status.podIP}')"
probe() { # namespace pod labels
  K -n "$1" delete pod "$2" --ignore-not-found >/dev/null 2>&1
  K -n "$1" run "$2" --image "$CURL_IMAGE" --restart=Never ${3:+--labels "$3"} --command -- sleep 600 >/dev/null
  K -n "$1" wait pod "$2" --for=condition=Ready --timeout=180s >/dev/null
}
reach() { K -n "$1" exec "$2" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'X-Forwarded-User: user_forged' "$3" 2>/dev/null || true; }
probe personal admin-proof-probe ""
probe nagare-system admin-proof-neighbour ""
probe personal admin-proof-lookalike "serving.knative.dev/service=nagare-access"
record "control: application pod to the gateway Service" "$(reach personal admin-proof-probe http://nagare-access.nagare-system.svc.cluster.local/_nagare/healthz)"
for target in "http://nagare-admin-api.nagare-system.svc.cluster.local/v1/inventory/head" "http://$pod_ip:8085/v1/inventory/head"; do
  expect "application pod to $target" "$(reach personal admin-proof-probe "$target")" "000"
  expect "platform pod to $target" "$(reach nagare-system admin-proof-neighbour "$target")" "000"
done
expect "look-alike label to the Pod IP" "$(reach personal admin-proof-lookalike "http://$pod_ip:8085/v1/inventory/head")" "000"
# An ephemeral container shares the API pod's network and so its policy.
metadata() {
  local name="metadata-$1-$RANDOM" state="" reason=""
  K -n nagare-system debug "$pod" --image "$CURL_IMAGE" --target nagare-admin-api --container "$name" --profile general -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Metadata-Flavor: Google' "$2" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    state="$(K -n nagare-system get pod "$pod" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$name\")].state.terminated.reason}")"
    reason="$(K -n nagare-system get pod "$pod" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$name\")].state.waiting.reason}")"
    [ -n "$state" ] && break
    case "$reason" in *Error*|*BackOff*) echo "cloud proof: the metadata probe container did not start: $reason" >&2; exit 1 ;; esac
    sleep 2
  done
  [ -n "$state" ] || { echo "cloud proof: the metadata probe container did not finish" >&2; exit 1; }
  K -n nagare-system logs "$pod" -c "$name" 2>/dev/null | tail -c 3
}
expect "API pod to the metadata server by address" "$(metadata ip 'http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token')" "000"
expect "API pod to the metadata server by name" "$(metadata name 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token')" "000"

# --- 6. what the reader key can do, asked of Cloud Storage directly ---
if [ "$REHEARSAL" != local ]; then
secrets="${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/$NAGARE_CONTEXT/admin-api-reader.yaml"
(umask 077; sops -d --extract '["stringData"]["key.json"]' "$secrets" > "$WORK/key.json")
token="$(CLOUDSDK_CONFIG="$WORK/gcloud" gcloud auth activate-service-account --key-file "$WORK/key.json" >/dev/null 2>&1 && CLOUDSDK_CONFIG="$WORK/gcloud" gcloud auth print-access-token)"
rm -f "$WORK/key.json"
url="${NAGARE_INVENTORY_STORE_URL:?the context names its inventory URL}"
rest="${url#gs://}"; bucket="${rest%%/*}"; prefix="${rest#*/}"; prefix="${prefix%/}"
enc() { python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
gcs() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer $token" "$@"; }
api="https://storage.googleapis.com/storage/v1/b/$bucket"
expect "reader: head.json" "$(gcs "$api/o/$(enc "$prefix/head.json")?alt=media")" "200"
expect "reader: bucket metadata" "$(gcs "$api")" "200"
expect "reader: list the bucket" "$(gcs "$api/o?maxResults=1")" "403"
journal="$prefix/journal/0.json"   # refused whether or not it exists: the grant names no journal
expect "reader: a journal object" "$(gcs "$api/o/$(enc "$journal")?alt=media")" "403"
expect "reader: a sibling Pulumi object" "$(gcs "$api/o/$(enc "pulumi/.pulumi/meta.yaml")?alt=media")" "403"
expect "reader: write a scratch object" "$(gcs -X POST -H 'Content-Type: text/plain' --data 'x' "https://storage.googleapis.com/upload/storage/v1/b/$bucket/o?uploadType=media&name=$(enc "$prefix/admin-proof-forbidden")")" "403"
unset token
fi

# --- 7. undo the proof's own grant and account ---
N access revoke --host "$HOST" --user "$machine" --save-plan "$WORK/revoke" > /dev/null
N inventory apply "$WORK/revoke" --yes > "$WORK/revoke.log" 2>&1 || { tail -3 "$WORK/revoke.log" >&2; exit 1; }
for _ in $(seq 1 90); do [ "$(as_machine /v1/inventory/head)" = 403 ] && break; sleep 1; done
expect "revoked service account" "$(as_machine /v1/inventory/head)" "403"
K -n nagare-system exec deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin service-accounts revoke "$client_id" >/dev/null
unset bearer NAGARE_EN_API_KEY
N inventory status --json > "$OUT/inventory-status.json"

python3 -I - "$OUT" "$NAGARE_CONTEXT" "$candidate" "$HOST" <<'PY'
import json, sys
out, context, candidate, host = sys.argv[1:]
rows = [line.rstrip("\n").split("\t", 1) for line in open(f"{out}/observations.tsv")]
record = {"schemaVersion": 1, "mode": "cloud", "context": context, "host": host,
          "nagarectl": {k: json.loads(candidate).get(k) for k in ("version", "revision")},
          "observations": [{"step": k, "value": v} for k, v in rows]}
json.dump(record, open(f"{out}/admin-api-cloud-proof.json", "w"), indent=2, sort_keys=True)
PY
log "admin API cloud proof OK: $OUT/admin-api-cloud-proof.json"
