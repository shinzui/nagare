#!/usr/bin/env bash
# EP-235 M3: the native proof of the lifecycle worker on a disposable local context that
# scripts/site-access-drill.sh bootstrapped with NAGARE_DRILL_LIFECYCLE=1 and
# NAGARE_DRILL_BOOTSTRAP_ONLY=1, in the same NAGARE_DRILL_ROOT. The example receiver
# (cluster/examples/lifecycle-webhook-receiver) runs on the workstation behind a fault proxy
# the cluster reaches at the VM's host address. Through reviewed changes only it drives a
# site release and a no-op redeploy, an unattended scheduled PostgreSQL backup and its
# ingestion, catch-up after the worker stops, a receiver outage, a lost acknowledgement, a
# restart with queued work, a replay, and the worker's credential denials. Every step stops
# at its first unexpected answer. The record is evidence/lifecycle-drill.tsv under the root;
# it names IDs, digests and timings, never a key.
set -euo pipefail

: "${DOCKER_HOST:?the disposable Docker daemon socket, never the shared cp3 daemon}"
: "${NAGARE_DRILL_NAGARECTL:?the candidate nagarectl}"
: "${NAGARE_DRILL_ROOT:?the bootstrapped drill root}"
: "${NAGARE_DRILL_GHC_ENV:?the GHC package environment that resolves nagare-dsl}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$NAGARE_DRILL_ROOT"
CTX="${NAGARE_DRILL_CONTEXT:-site-access}"
NS=personal
SITE=protected-static-site
EXAMPLE="$REPO/cluster/examples/$SITE"
SUB=drill-deploys
# The VM's address for the workstation (Colima's host.lima.internal), private: allowed by review.
HOST_ADDR="${NAGARE_DRILL_HOST_ADDRESS:-192.168.5.2}"
PROXY_PORT="${NAGARE_DRILL_PROXY_PORT:-18890}"
RECEIVER_PORT=$((PROXY_PORT + 1))
CURL_IMAGE=curlimages/curl:8.10.1

for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_DRILL_*) ;; *) unset "$v" ;; esac
done
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
set -a; . "$ROOT/images.env"; set +a
export NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:${NAGARE_DRILL_FORWARD_PORT:-15213}"
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
KUBE="$(kubectl config current-context)"
EV="$ROOT/evidence"; RV="$ROOT/reviews/lifecycle"; RX="$ROOT/receiver"
mkdir -p "$EV" "$RV" "$RX"
: > "$EV/lifecycle-drill.tsv"
log() { printf '%s lifecycle drill: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "lifecycle drill: FAIL: $*" >&2; exit 1; }
N() { "$NAGARE_DRILL_NAGARECTL" --context "$CTX" "$@"; }
K() { kubectl --context "$KUBE" "$@"; }
record() { printf '%s\t%s\n' "$1" "$2" >> "$EV/lifecycle-drill.tsv"; log "$1: $2"; }
expect() { [ "$2" = "$3" ] || fail "$1: got $2, wanted $3"; record "$1" "$2"; }
now() { date -u +%s; }
review_apply() { N inventory apply "$1" --yes > "$1.apply.log" 2>&1 || fail "apply of $1: $(tail -3 "$1.apply.log")"; }
operations() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["operations"]))' "$1/review.json"; }
converge_platform() { # label
  local n review
  for n in $(seq 1 6); do
    review="$RV/platform-$1-$n"
    N platform bootstrap plan --out "$review" > "$review.plan.log" 2>&1 || fail "platform plan $1-$n: $(tail -2 "$review.plan.log")"
    [ "$(operations "$review")" != 0 ] || return 0
    N platform bootstrap apply "$review" --yes > "$review.apply.log" 2>&1 || fail "platform apply $1-$n: $(tail -3 "$review.apply.log")"
  done
  fail "the platform did not converge after $1"
}
PIDS=()
cleanup() { for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; K -n "$NS" delete pod lifecycle-drill-probe --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --- 1. the worker runs the pinned image, ready, as the scope reviewed it ---
K -n nagare-system rollout status deploy/nagare-events --timeout=300s >/dev/null
expect "worker image" "$(K -n nagare-system get deploy nagare-events -o jsonpath='{.spec.template.spec.containers[0].image}')" "$NAGARE_ADMIN_API_IMAGE"
expect "worker ready" "$(K -n nagare-system get pod -l app.kubernetes.io/name=nagare-events -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" True
record "candidate" "$(N version --json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("version"), d.get("revision"))')"
metrics() { # label
  K -n nagare-system port-forward deploy/nagare-events 18086:8086 >/dev/null 2>&1 & local pf=$!
  for _ in $(seq 1 20); do curl -s -m 2 -o /dev/null http://127.0.0.1:18086/health/live && break; sleep 1; done
  curl -s -m 5 http://127.0.0.1:18086/metrics > "$EV/metrics-$1.txt" || true
  kill "$pf" 2>/dev/null || true; wait "$pf" 2>/dev/null || true
  record "metrics $1 failing loops" "$(grep -c '^nagare_events_cycle_failing{.*} 1' "$EV/metrics-$1.txt" || true)"
}
metrics idle

# --- 2. the example receiver behind a fault proxy, reachable from the cluster ---
KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
( cd "$RX" && NAGARE_WEBHOOK_KEY="$KEY" PORT="$RECEIVER_PORT" cabal run -v0 "$REPO/cluster/examples/lifecycle-webhook-receiver/Receiver.hs" > "$RX/receiver.log" 2>&1 ) &
PIDS+=($!)
echo pass > "$RX/mode"
python3 -I - "$PROXY_PORT" "$RECEIVER_PORT" "$RX/mode" "$RX/proxy.log" <<'PY' &
import http.server, sys, time, urllib.request
port, upstream, modefile, logfile = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        mode = open(modefile).read().strip()
        with open(logfile, "a") as f:
            f.write(f"{time.time():.3f}\t{mode}\t{self.headers.get('Nagare-Event-Id')}\t{self.headers.get('Nagare-Delivery-Id')}\n")
        if mode == "500":
            self.send_response(500); self.end_headers(); return
        req = urllib.request.Request(f"http://127.0.0.1:{upstream}{self.path}", data=body, method="POST",
            headers={k: v for k, v in self.headers.items() if k.lower().startswith("nagare-") or k.lower() == "content-type"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r: status, data = r.status, r.read()
        except urllib.error.HTTPError as e: status, data = e.code, e.read()
        if mode == "drop":  # processed upstream; the acknowledgement never reaches the sender
            self.close_connection = True; self.connection.shutdown(2); return
        self.send_response(status); self.end_headers(); self.wfile.write(data)
http.server.ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
PY
PIDS+=($!)
for _ in $(seq 1 600); do curl -s -m 2 -o /dev/null "http://127.0.0.1:$RECEIVER_PORT/" && break; sleep 1; done
curl -s -m 2 -o /dev/null "http://127.0.0.1:$RECEIVER_PORT/" || fail "the example receiver did not start: $(tail -3 "$RX/receiver.log")"
K -n "$NS" run lifecycle-drill-probe --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
K -n "$NS" wait pod/lifecycle-drill-probe --for=condition=Ready --timeout=180s >/dev/null
expect "receiver reachable from the cluster" "$(K -n "$NS" exec lifecycle-drill-probe -- curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "http://$HOST_ADDR:$PROXY_PORT/hook")" 400

# --- 3. the signing Secret and the reviewed subscription; the worker may read only it ---
K -n "$NS" create secret generic drill-webhook --from-literal=key="$KEY" --dry-run=client -o yaml | K apply -f - >/dev/null
N events webhook create "$SUB" --url "http://$HOST_ADDR:$PROXY_PORT/hook" --allow-host "$HOST_ADDR" \
  --type app.deployed --type database.backup.completed --type database.backup.accepted \
  --signing-secret "$NS/drill-webhook" --signing-key key --save-plan "$RV/subscribe" > "$RV/subscribe.log"
review_apply "$RV/subscribe"
converge_platform subscribe
SA=system:serviceaccount:nagare-system:nagare-events
expect "worker may read the signing Secret" "$(K auth can-i get secret/drill-webhook -n "$NS" --as "$SA")" yes
expect "worker may not read another Secret" "$(K auth can-i get secret/nagare-minio-credentials -n nagare-system --as "$SA" || true)" no
expect "worker may not list Secrets" "$(K auth can-i list secrets -n "$NS" --as "$SA" || true)" no

received() { grep -c "^processed " "$RX/receiver.log" || true; }
await_received() { # count label started
  local n
  for n in $(seq 1 "${4:-180}"); do
    if [ "$(received)" -ge "$1" ]; then record "$2 seconds to the receiver" "$(( $(now) - $3 ))"; return 0; fi
    sleep 1
  done
  fail "$2: the receiver has $(received) events, wanted $1; proxy: $(tail -3 "$RX/proxy.log" 2>/dev/null)"
}
last_event() { grep "^processed " "$RX/receiver.log" | tail -1 | sed 's/^processed \([^:]*\): .*/\1/'; }
last_type() { grep "^processed " "$RX/receiver.log" | tail -1 | sed 's/^processed [^:]*: //' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["type"])'; }

# --- 4. a reviewed site release reaches the receiver once; a no-op redeploy announces nothing ---
eval "$(N context env | grep -E '^export (NAGARE_REGISTRY_HOST|CLOUDSDK_CORE_PROJECT|NAGARE_ARTIFACT_REGISTRY_ID)=')"
destination="$NAGARE_REGISTRY_HOST/$CLOUDSDK_CORE_PROJECT/$NAGARE_ARTIFACT_REGISTRY_ID/$SITE"
PUBLIC="$ROOT/site/public"; mkdir -p "$PUBLIC"; cp -R "$EXAMPLE/public/." "$PUBLIC/"
release() { # tag
  printf '<!-- %s -->\n' "$1" >> "$PUBLIC/index.html"
  N site package -f "$EXAMPLE/nagare/Config.hs" -C "$EXAMPLE" --ghc-env "$NAGARE_DRILL_GHC_ENV" --output-dir "$PUBLIC" \
    --archive "$ROOT/site/$1.tar" --tag "$1" > "$ROOT/site/$1.package"
  N app image-plan --archive "$ROOT/site/$1.tar" --destination "$destination:$1" --key "$SITE" --save-plan "$RV/image-$1" > "$RV/image-$1.log"
  review_apply "$RV/image-$1"
  IMAGE="$(sed -n 's/^Image resource: //p' "$RV/image-$1.log" | tail -1)"
  [ -n "$IMAGE" ] || fail "image review $1 named no resource"
  deploy_image "$1"
}
deploy_image() { # tag
  N site deploy -f "$EXAMPLE/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" -C "$EXAMPLE" --skip-build --tag "$1" --image-resource "$IMAGE" \
    > "$RV/deploy-$1.log" 2>&1 || fail "deploy $1: $(tail -3 "$RV/deploy-$1.log")"
}
t0="$(now)"; release d1
await_received 1 "release d1" "$t0"
expect "release d1 event type" "$(last_type)" app.deployed
D1="$(last_event)"; record "release d1 event" "$D1"
t0="$(now)"; deploy_image d1
sleep 75
expect "events after a no-op redeploy" "$(received)" 1

# --- 5. an unattended scheduled PostgreSQL backup completes, then its ingestion is accepted ---
N db create postgres drill-pg -n "$NS" --recovery-backup postgres-backup --recovery-key-version v1 > "$RV/db.log" 2>&1 || fail "db create: $(tail -3 "$RV/db.log")"
K -n "$NS" rollout status statefulset/drill-pg --timeout=300s >/dev/null
record "backup schedule" "$(K -n "$NS" get cronjob -l nagare.dev/database=drill-pg -o jsonpath='{.items[0].spec.schedule}' 2>/dev/null || true)"
t0="$(now)"
await_received 2 "scheduled backup completion" "$t0" 1800
expect "backup event type" "$(last_type)" database.backup.completed
N db backup-receipts drill-pg -n "$NS" --all --save-plan "$RV/ingest" > "$RV/ingest.log" 2>&1 || fail "ingest: $(tail -3 "$RV/ingest.log")"
t0="$(now)"; review_apply "$RV/ingest"
await_received 3 "backup acceptance" "$t0"
expect "acceptance event type" "$(last_type)" database.backup.accepted

# --- 6. catch-up: a release while the worker is stopped arrives once after it starts ---
K -n nagare-system scale deploy/nagare-events --replicas=0 >/dev/null
K -n nagare-system wait pod -l app.kubernetes.io/name=nagare-events --for=delete --timeout=120s >/dev/null 2>&1 || true
release d2
sleep 30
expect "events while the worker is stopped" "$(received)" 3
t0="$(now)"; K -n nagare-system scale deploy/nagare-events --replicas=1 >/dev/null
await_received 4 "catch-up after restart" "$t0"
expect "catch-up event type" "$(last_type)" app.deployed

# --- 7. a receiver outage retries; the release itself converges meanwhile ---
echo 500 > "$RX/mode"
release d3
record "release d3 converged during the outage" yes
sleep 60
expect "events during the outage" "$(received)" 4
record "attempts refused during the outage" "$(grep -c $'\t500\t' "$RX/proxy.log" || true)"
t0="$(now)"; echo pass > "$RX/mode"
await_received 5 "delivery after the outage" "$t0" 3700

# --- 8. a lost acknowledgement: processed once, delivered again, deduplicated ---
echo drop > "$RX/mode"
release d4
await_received 6 "release d4 first attempt" "$(now)"
echo pass > "$RX/mode"
for _ in $(seq 1 600); do grep -q "^duplicate " "$RX/receiver.log" && break; sleep 1; done
expect "duplicate deliveries deduplicated by the receiver" "$(grep -c "^duplicate " "$RX/receiver.log" || true)" 1
expect "processed events after the duplicate" "$(received)" 6

# --- 9. a restart with queued work keeps it ---
echo 500 > "$RX/mode"
release d5
sleep 45
K -n nagare-system delete pod -l app.kubernetes.io/name=nagare-events --wait=true >/dev/null
K -n nagare-system rollout status deploy/nagare-events --timeout=300s >/dev/null
t0="$(now)"; echo pass > "$RX/mode"
await_received 7 "queued delivery after the restart" "$t0" 3700
N events delivery list "$SUB" --contract 1 > "$EV/deliveries.json"
python3 -I - "$EV/deliveries.json" <<'PY' | while IFS=$'\t' read -r k v; do record "$k" "$v"; done
import json, sys, collections
d = json.load(open(sys.argv[1]))
items = d.get("deliveries") or d.get("items") or []
states = collections.Counter(i.get("state") for i in items)
print("delivery states\t" + ",".join(f"{k}={v}" for k, v in sorted(states.items())))
print("distinct events delivered\t" + str(len({i.get("event") or i.get("eventId") for i in items})))
PY

# --- 10. a reviewed replay sends the original event ID again; nothing is deployed ---
before_revision="$(K -n "$NS" get ksvc "$SITE" -o jsonpath='{.status.latestReadyRevisionName}')"
N events delivery replay "$SUB" --event "$D1" --save-plan "$RV/replay" > "$RV/replay.log" 2>&1 || fail "replay: $(tail -3 "$RV/replay.log")"
review_apply "$RV/replay"
for _ in $(seq 1 180); do [ "$(grep -c "^duplicate $D1" "$RX/receiver.log" || true)" -ge 1 ] && break; sleep 1; done
expect "replay arrived under the original event ID" "$(grep -c "^duplicate $D1" "$RX/receiver.log" || true)" 1
expect "site revision unchanged by the replay" "$(K -n "$NS" get ksvc "$SITE" -o jsonpath='{.status.latestReadyRevisionName}')" "$before_revision"

# --- 11. the worker's credentials refuse writes ---
expect "inventory mount is read-only to the worker" \
  "$(K -n nagare-system get deploy nagare-events -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.mountPath=="/var/lib/nagare/inventory")].readOnly}')" true
mc_image="$NAGARE_LOCAL_MC_IMAGE"
ak="$(K -n nagare-system get secret nagare-events-minio -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
K -n nagare-system run lifecycle-drill-mc --image="$mc_image" --restart=Never --rm -i --quiet \
  --overrides='{"spec":{"containers":[{"name":"mc","image":"'"$mc_image"'","command":["/bin/sh","-c","mc alias set w http://minio.nagare-system.svc.cluster.local:9000 \"$AK\" \"$SK\" >/dev/null && (mc ls w/nagare-backups >/dev/null && echo list-ok || echo list-refused) && (echo x | mc pipe w/nagare-backups/drill-write >/dev/null 2>&1 && echo write-ok || echo write-refused)"],"env":[{"name":"HOME","value":"/tmp"},{"name":"AK","value":"'"$ak"'"},{"name":"SK","valueFrom":{"secretKeyRef":{"name":"nagare-events-minio","key":"AWS_SECRET_ACCESS_KEY"}}}]}]}}' \
  > "$EV/minio-user.txt" 2>/dev/null || true
expect "worker object-store user lists backups" "$(grep -c '^list-ok$' "$EV/minio-user.txt" || true)" 1
expect "worker object-store user cannot write backups" "$(grep -c '^write-refused$' "$EV/minio-user.txt" || true)" 1

metrics loaded
N platform bootstrap plan --out "$RV/final" > "$RV/final.plan.log" 2>&1 || fail "final plan"
expect "final platform replan operations" "$(operations "$RV/final")" 0
log "PASS"
