#!/usr/bin/env bash
# EP-198 M2: the native proof of the admin API on a disposable local context that
# scripts/site-access-drill.sh bootstrapped with NAGARE_DRILL_ADMIN_API=1 and
# NAGARE_DRILL_BOOTSTRAP_ONLY=1, in the same NAGARE_DRILL_ROOT. Through the real gateway it
# drives an unauthenticated client, a signed-in person and a Shomei service account against
# admin.<base>/v1; from pods it tries to bypass the gateway; it measures warm latency through
# the gateway, stops the server to see the gateway's answer, and replans to zero operations.
# Every step stops at its first unexpected answer. The record is evidence/admin-api-drill.json;
# it names revisions, images and observations, never a secret.
set -euo pipefail

: "${DOCKER_HOST:?the disposable Docker daemon socket, never the shared cp3 daemon}"
: "${NAGARE_DRILL_NAGARECTL:?the candidate nagarectl}"
: "${NAGARE_DRILL_ROOT:?the bootstrapped drill root}"
ROOT="$NAGARE_DRILL_ROOT"
CTX="${NAGARE_DRILL_CONTEXT:-site-access}"
BASE=127-0-0-1.sslip.io
HOST="admin.$BASE"
INGRESS_PORT="${NAGARE_DRILL_INGRESS_PORT:-18443}"
SHOMEI_PORT="${NAGARE_DRILL_SHOMEI_PORT:-18084}"
CURL_IMAGE=curlimages/curl:8.10.1

for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_DRILL_*) ;; *) unset "$v" ;; esac
done
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
set -a; . "$ROOT/images.env"; set +a
[ -n "${NAGARE_ADMIN_API_IMAGE:-}" ] || { echo "the drill root pins no admin API image; bootstrap it with NAGARE_DRILL_ADMIN_API=1" >&2; exit 1; }
export NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:${NAGARE_DRILL_FORWARD_PORT:-15213}"
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
KUBE="$(kubectl config current-context)"
EV="$ROOT/evidence"
: > "$EV/admin-observations.tsv"
log() { printf '%s admin drill: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
N() { "$NAGARE_DRILL_NAGARECTL" --context "$CTX" "$@"; }
K() { kubectl --context "$KUBE" "$@"; }
record() { printf '%s\t%s\n' "$1" "$2" >> "$EV/admin-observations.tsv"; log "$1: $2"; }
expect() { # label got wanted
  [ "$2" = "$3" ] || { echo "admin drill: $1: got $2, wanted $3" >&2; exit 1; }
  record "$1" "$2"
}
review_apply() { # dir
  N inventory apply "$1" --yes > "$1.apply.log" 2>&1 || { echo "apply of $1 failed: $(tail -3 "$1.apply.log")" >&2; exit 1; }
}
PIDS=()
cleanup() { for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; K -n personal delete pod admin-drill-probe admin-drill-lookalike --ignore-not-found >/dev/null 2>&1 || true; K -n nagare-system delete pod admin-drill-neighbour --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT
candidate="$(N version --json)"
log "root $ROOT; candidate $(printf '%s' "$candidate" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("version"), d.get("revision"))')"

# --- 1. the reviewed scope converged and its pod runs the pinned image on the mounted store ---
K -n nagare-system rollout status deploy/nagare-admin-api --timeout=300s >/dev/null
expect "admin API image" "$(K -n nagare-system get deploy nagare-admin-api -o jsonpath='{.spec.template.spec.containers[0].image}')" "$NAGARE_ADMIN_API_IMAGE"
expect "admin API pod ready" "$(K -n nagare-system get pod -l app.kubernetes.io/name=nagare-admin-api -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" "True"
record "admin API pod user" "$(K -n nagare-system get pod -l app.kubernetes.io/name=nagare-admin-api -o jsonpath='{.items[0].spec.securityContext.runAsUser}')"
expect "admin route target" "$(K -n nagare-system get domainmapping "$HOST" -o jsonpath='{.spec.ref.name}')" "nagare-access"
python3 -I -c 'import json,sys; m=json.loads(json.load(sys.stdin)["data"]["backends.json"]); e=m[sys.argv[1]]; assert e["apiPrefix"]=="/v1" and e["timeoutSeconds"]==15, e; print(json.dumps(e, sort_keys=True))' "$HOST" \
  < <(K -n nagare-system get configmap nagare-access-backends -o json) > "$EV/admin-backend-entry.json"
record "backend entry" "$(cat "$EV/admin-backend-entry.json")"

# --- 2. the gateway over the local CA ---
K -n cert-manager get secret nagare-local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ROOT/ca.pem"
K -n kourier-system port-forward svc/kourier "$INGRESS_PORT:443" >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$INGRESS_PORT" 2>/dev/null && break; sleep 1; done
get() { # path [curl args...]
  local path="$1"; shift
  curl -sS -o "$ROOT/body" -D "$ROOT/headers" -w '%{http_code}' --max-time 30 --cacert "$ROOT/ca.pem" \
    --connect-to "$HOST:443:127.0.0.1:$INGRESS_PORT" "$@" "https://$HOST$path" 2>/dev/null || true
}
header() { sed -n "s/^$1: *\\(.*\\)$/\\1/Ip" "$ROOT/headers" | tr -d '\r' | tail -1; }
code() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("code"))' "$ROOT/body" 2>/dev/null || echo none; }
for n in $(seq 1 600); do
  [ "$(get /v1/platform/version)" = 401 ] && { record "seconds until the admin route answered" "$n"; break; }
  [ "$n" != 600 ] || { echo "admin.$BASE did not answer 401 within 600 s: $(get /v1/platform/version)" >&2; exit 1; }
  sleep 1
done
expect "anonymous /v1 without Accept" "$(get /v1/platform/version)" "401"
expect "anonymous problem code" "$(code)" "unauthenticated"
expect "anonymous problem media type" "$(header Content-Type)" "application/problem+json"
expect "anonymous challenge" "$(header WWW-Authenticate)" "Bearer"
expect "anonymous /v1 with Accept */*" "$(get /v1/inventory/head -H 'Accept: */*')" "401"
expect "anonymous UI document" "$(get / -H 'Accept: text/html')" "302"
expect "raw identity header, anonymous" "$(get /v1/inventory/head -H 'X-Forwarded-User: user_forged')" "401"

# --- 3. a signed-in person: refused without the grant, served with it ---
secret="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
email="admin-drill-$(printf '%s' "$secret" | tr 'A-Z' 'a-z' | head -c 10)@example.test"
password="Dr-$secret"
user="$(printf '%s\n' "$password" | K -n nagare-system exec -i deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin users create --email "$email" --display-name "admin API drill" --email-verified | sed -n 's/^created user \(user_[A-Za-z0-9_-]*\).*/\1/p')"
[ -n "$user" ] || { echo "shomei-admin created no user" >&2; exit 1; }
unset secret
get "/_nagare/login?rd=%2F" > /dev/null
csrf="$(sed -n 's/^[Ss]et-[Cc]ookie: __Host-nagare_csrf=\([^;]*\).*/\1/p' "$ROOT/headers" | tail -1)"
token="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$ROOT/body" | head -1)"
[ -n "$csrf" ] && [ "$csrf" = "$token" ] || { echo "no matching CSRF cookie and form token" >&2; exit 1; }
expect "login" "$(get /_nagare/login -X POST -H "Cookie: __Host-nagare_csrf=$csrf" --data-urlencode "csrf=$token" --data-urlencode "rd=/" --data-urlencode "email=$email" --data-urlencode "password=$password")" "302"
unset password
session="$(sed -n 's/^[Ss]et-[Cc]ookie: nagare_session=\([^;]*\).*/\1/p' "$ROOT/headers" | tail -1)"
[ -n "$session" ] || { echo "login set no session cookie" >&2; exit 1; }
: > "$ROOT/headers"
as_user() { get "$1" -H "Cookie: nagare_session=$session" "${@:2}"; }
expect "signed in, no grant" "$(as_user /v1/inventory/head)" "403"
expect "ungranted problem code" "$(code)" "forbidden"
export NAGARE_EN_API_KEY="$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
grant() { N access grant --host "$HOST" --user "$1" --save-plan "$ROOT/reviews/admin-grant-$2" > /dev/null; review_apply "$ROOT/reviews/admin-grant-$2"; }
revoke() { N access revoke --host "$HOST" --user "$1" --save-plan "$ROOT/reviews/admin-revoke-$2" > /dev/null; review_apply "$ROOT/reviews/admin-revoke-$2"; }
grant "$user" person
for _ in $(seq 1 90); do [ "$(as_user /v1/inventory/head)" = 200 ] && break; sleep 1; done
expect "granted person, head" "$(as_user /v1/inventory/head)" "200"
etag="$(header ETag)"; revision="$(header Nagare-Head-Revision)"
[ -n "$etag" ] && [ -n "$revision" ] || { echo "the head answer carries no ETag or Nagare-Head-Revision" >&2; exit 1; }
record "head revision through the gateway" "$revision"
expect "conditional head through the gateway" "$(as_user /v1/inventory/head -H "If-None-Match: $etag")" "304"
expect "granted person, sites" "$(as_user /v1/sites)" "200"
expect "granted person, version" "$(as_user /v1/platform/version)" "200"
expect "granted person, unknown route" "$(as_user /v1/nope)" "404"
expect "granted person, POST" "$(as_user /v1/inventory/head -X POST)" "405"

# --- 4. a Shomei service account through the bearer path ---
created="$(K -n nagare-system exec deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin service-accounts create --display-name "admin API drill")"
client_id="$(printf '%s\n' "$created" | sed -n 's/^client_id: *\([^ ]*\).*/\1/p')"
client_secret="$(printf '%s\n' "$created" | sed -n 's/^client_secret: *\([^ ]*\).*/\1/p')"
unset created
[ -n "$client_id" ] && [ -n "$client_secret" ] || { echo "shomei-admin service-accounts create printed no client credentials" >&2; exit 1; }
K -n nagare-system port-forward svc/shomei "$SHOMEI_PORT:80" >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$SHOMEI_PORT" 2>/dev/null && break; sleep 1; done
bearer="$(curl -sS --max-time 20 -u "$client_id:$client_secret" -d grant_type=client_credentials "http://127.0.0.1:$SHOMEI_PORT/oauth/token" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
unset client_secret
machine="$(printf '%s' "$bearer" | python3 -I -c 'import base64,json,sys; p=sys.stdin.read().split(".")[1]; print(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4)))["sub"])')"
record "service account subject" "$machine"
as_machine() { get "$1" -H "Authorization: Bearer $bearer" "${@:2}"; }
expect "service account, no grant" "$(as_machine /v1/inventory/head)" "403"
expect "invalid bearer" "$(get /v1/inventory/head -H 'Authorization: Bearer not.a.token')" "401"
grant "$machine" machine
for _ in $(seq 1 90); do [ "$(as_machine /v1/inventory/head)" = 200 ] && break; sleep 1; done
expect "granted service account, head" "$(as_machine /v1/inventory/head)" "200"
expect "granted service account, grants" "$(as_machine /v1/access/grants)" "200"

# --- 5. no path around the gateway: application and platform pods, a look-alike label ---
pod_ip="$(K -n nagare-system get pod -l app.kubernetes.io/name=nagare-admin-api -o jsonpath='{.items[0].status.podIP}')"
probe() { # namespace pod [labels] -- url...
  local ns="$1" name="$2" labels="$3"; shift 3
  K -n "$ns" delete pod "$name" --ignore-not-found >/dev/null 2>&1
  K -n "$ns" run "$name" --image "$CURL_IMAGE" --restart=Never ${labels:+--labels "$labels"} --command -- sleep 600 >/dev/null
  K -n "$ns" wait pod "$name" --for=condition=Ready --timeout=180s >/dev/null
}
reach() { # namespace pod url
  K -n "$1" exec "$2" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'X-Forwarded-User: user_forged' "$3" 2>/dev/null || true
}
service_url="http://nagare-admin-api.nagare-system.svc.cluster.local/v1/inventory/head"
probe personal admin-drill-probe ""
probe nagare-system admin-drill-neighbour ""
probe personal admin-drill-lookalike "serving.knative.dev/service=nagare-access"
# Controls: the probes reach other cluster Services, so a refusal below is the policy's.
record "control: application pod to the gateway Service" "$(reach personal admin-drill-probe http://nagare-access.nagare-system.svc.cluster.local/_nagare/healthz)"
record "control: platform pod to the Shomei Service" "$(reach nagare-system admin-drill-neighbour http://shomei.nagare-system.svc.cluster.local/)"
expect "application pod to the API Service" "$(reach personal admin-drill-probe "$service_url")" "000"
expect "application pod to the API Pod IP" "$(reach personal admin-drill-probe "http://$pod_ip:8085/v1/inventory/head")" "000"
expect "platform pod to the API Service" "$(reach nagare-system admin-drill-neighbour "$service_url")" "000"
expect "platform pod to the API Pod IP" "$(reach nagare-system admin-drill-neighbour "http://$pod_ip:8085/v1/inventory/head")" "000"
expect "look-alike label in another namespace" "$(reach personal admin-drill-lookalike "http://$pod_ip:8085/v1/inventory/head")" "000"
expect "kubelet readiness still passes" "$(K -n nagare-system get pod -l app.kubernetes.io/name=nagare-admin-api -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" "True"

# --- 6. warm latency through the gateway: 100 requests at concurrency 8 per route ---
for route in /v1/inventory/head /v1/sites /v1/inventory/scopes; do
  seq 1 100 | xargs -P 8 -I{} curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 30 --cacert "$ROOT/ca.pem" \
    --connect-to "$HOST:443:127.0.0.1:$INGRESS_PORT" -H "Cookie: nagare_session=$session" "https://$HOST$route" > "$EV/latency-${route//\//_}.txt"
  record "warm latency $route" "$(python3 -I -c '
import sys
rows=[l.split() for l in open(sys.argv[1])]
assert len(rows)==100 and all(c=="200" for c,_ in rows), [c for c,_ in rows if c!="200"][:5]
t=sorted(float(s) for _,s in rows)
print("p50 %.3f s, p95 %.3f s, max %.3f s" % (t[49], t[94], t[-1]))
' "$EV/latency-${route//\//_}.txt")"
done

# --- 7. the server stops: the gateway answers a problem promptly; it returns, unchanged ---
K -n nagare-system scale deploy/nagare-admin-api --replicas=0 >/dev/null
K -n nagare-system wait pod -l app.kubernetes.io/name=nagare-admin-api --for=delete --timeout=120s >/dev/null 2>&1 || true
started=$(date +%s)
expect "server stopped" "$(as_user /v1/inventory/head)" "502"
expect "server stopped, problem code" "$(code)" "upstream_unavailable"
grep -qiE 'ConnectionFailure|HttpException|svc\.cluster\.local' "$ROOT/body" && { echo "the gateway's problem names its client exception" >&2; exit 1; }
record "seconds to the stopped-server answer" "$(( $(date +%s) - started ))"
K -n nagare-system scale deploy/nagare-admin-api --replicas=1 >/dev/null
K -n nagare-system rollout status deploy/nagare-admin-api --timeout=300s >/dev/null
for _ in $(seq 1 60); do [ "$(as_user /v1/inventory/head)" = 200 ] && break; sleep 1; done
expect "server returned" "$(as_user /v1/inventory/head)" "200"

# --- 8. revocation reaches the gateway after its decision TTL; a replan has no operations ---
revoke "$user" person
for _ in $(seq 1 90); do [ "$(as_user /v1/inventory/head)" = 403 ] && break; sleep 1; done
expect "revoked person" "$(as_user /v1/inventory/head)" "403"
revoke "$machine" machine
unset NAGARE_EN_API_KEY session bearer
review="$ROOT/reviews/admin-replan"
N platform bootstrap plan --out "$review" > "$review.plan.log" 2>&1 || { echo "replan refused: $(tail -2 "$review.plan.log")" >&2; exit 1; }
expect "replan operations" "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["operations"]))' "$review/review.json")" "0"
N inventory status --json > "$EV/admin-inventory.json"

# --- the record ---
python3 -I - "$ROOT" "$CTX" "$candidate" "$NAGARE_ADMIN_API_IMAGE" "$HOST" <<'PY'
import json, sys
root, context, candidate, image, host = sys.argv[1:]
ev = f"{root}/evidence"
rows = [line.rstrip("\n").split("\t", 1) for line in open(f"{ev}/admin-observations.tsv")]
record = {
    "schemaVersion": 1, "mode": "local", "context": context, "host": host,
    "candidate": {k: json.loads(candidate).get(k) for k in ("version", "revision")},
    "adminApiImage": image,
    "observations": [{"step": k, "value": v} for k, v in rows],
}
json.dump(record, open(f"{ev}/admin-api-drill.json", "w"), indent=2, sort_keys=True)
PY
log "admin API drill OK: record in $EV/admin-api-drill.json"
