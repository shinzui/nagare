#!/usr/bin/env bash
# EP-199 M2: confirm a fresh ClickHouse database on the default version, on a disposable local
# context already bootstrapped on the candidate (for example the root a release rehearsal
# leaves). Create it through a reviewed scope without --version, query it authenticated over
# both protocols through its Service, keep rows across a reviewed restart, and restore a manual
# and a scheduled backup into isolated scratch databases. Every step stops at its first
# unexpected result. The record is evidence/clickhouse-drill.json under the root; it names
# revisions, the image digest and observed rows, never a secret.
set -euo pipefail

: "${DOCKER_HOST:?the disposable Docker daemon socket, never the shared cp3 daemon}"
: "${NAGARE_DRILL_NAGARECTL:?the candidate nagarectl}"
: "${NAGARE_DRILL_ROOT:?a root whose local context is bootstrapped on the candidate}"
ROOT="$NAGARE_DRILL_ROOT"
CTX="${NAGARE_DRILL_CONTEXT:-transition}"
NS=personal
DB="${NAGARE_DRILL_DATABASE:-ep199-ch}"
RUN="${NAGARE_DRILL_RUN:-$(date -u +%H%M)}"
MANUAL="ep199-$RUN"
SCHEDULE_WAIT="${NAGARE_DRILL_SCHEDULE_WAIT:-1500}"

for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_DRILL_*) ;; *) unset "$v" ;; esac
done
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
set -a; . "$ROOT/images.env"; set +a
REVIEWS="$ROOT/reviews/ep199-$RUN"
EV="$ROOT/evidence/ep199-$RUN"
mkdir -p "$REVIEWS" "$EV"
: > "$EV/observations.tsv"
log() { printf '%s drill: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
N() { "$NAGARE_DRILL_NAGARECTL" --context "$CTX" "$@"; }
record() { printf '%s\t%s\n' "$1" "$2" >> "$EV/observations.tsv"; log "$1: $2"; }
expect() { # label got wanted
  [ "$2" = "$3" ] || { echo "drill: $1: got $2, wanted $3" >&2; exit 1; }
  record "$1" "$2"
}
resume_ambiguous() { # apply-log
  local applyLog="$1" tx n
  tx="$(tail -2 "$applyLog" | sed -n "s/^ambiguous \(tx-[0-9a-f]*\) at .*/\1/p" | tail -1)"
  [ -n "$tx" ] || return 1
  for n in $(seq 1 12); do
    sleep 20
    log "resume $n of $tx"
    if N inventory resume "$tx" --yes >> "$applyLog" 2>&1; then return 0; fi
    tail -2 "$applyLog" | grep -q "^ambiguous $tx at " || return 1
  done
  return 1
}
review_apply() { # dir
  N inventory apply "$1" --yes > "$1.apply.log" 2>&1 || resume_ambiguous "$1.apply.log" || { echo "apply of $1 failed: $(tail -3 "$1.apply.log")" >&2; exit 1; }
}
saved() { # label nagarectl-args...
  local label="$1"; shift
  N "$@" --save-plan "$REVIEWS/$label" > "$REVIEWS/$label.plan.log" 2>&1 || { echo "$label plan refused: $(tail -3 "$REVIEWS/$label.plan.log")" >&2; exit 1; }
  review_apply "$REVIEWS/$label"
}

# --- 0. the daemon, cluster and candidate are the disposable ones this root names ---
[ "$DOCKER_HOST" != "unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock" ] || { echo "refusing the shared cp3 daemon" >&2; exit 1; }
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
KUBE="$(kubectl config current-context)"
expect "kube server" "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" "https://0.0.0.0:$(docker port k3d-nagare-local-serverlb 6443/tcp | sed -n 's/^0\.0\.0\.0://p' | head -1)"
expect "kube node" "$(kubectl --context "$KUBE" get nodes -o jsonpath='{.items[*].metadata.name}')" "k3d-nagare-local-server-0"
N version --json > "$EV/candidate.json"
N platform status --json > "$EV/platform.json"
record "candidate" "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("version"), d.get("revision"))' "$EV/candidate.json")"
record "node architecture" "$(kubectl --context "$KUBE" get node k3d-nagare-local-server-0 -o jsonpath='{.status.nodeInfo.architecture}')"
K() { kubectl --context "$KUBE" -n "$NS" "$@"; }
! K get statefulset "$DB" >/dev/null 2>&1 || { echo "$NS/$DB already exists; set NAGARE_DRILL_DATABASE to a fresh name" >&2; exit 1; }

# --- 1. a fresh database on the default version, through a reviewed scope ---
saved create db create clickhouse "$DB" -n "$NS" --size 1Gi --memory 2Gi \
  --recovery-backup "$DB-backup" --recovery-key-version v1
K rollout status statefulset "$DB" --timeout=600s >/dev/null
expect "declared image" "$(K get statefulset "$DB" -o jsonpath='{.spec.template.spec.containers[0].image}')" "clickhouse/clickhouse-server:26.8"
expect "version annotation" "$(K get statefulset "$DB" -o jsonpath='{.metadata.annotations.nagare\.dev/version}')" "26.8"
expect "memory limit" "$(K get statefulset "$DB" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')" "2Gi"
expect "service ports" "$(K get service "$DB" -o jsonpath='{.spec.ports[*].port}')" "9000 8123"
record "image digest" "$(K get pod "$DB-0" -o jsonpath='{.status.containerStatuses[0].imageID}')"
POD_UID="$(K get pod "$DB-0" -o jsonpath='{.metadata.uid}')"

# The managed identity is read once and passed only as process environment inside the pod.
CH_USER="$(K get secret "nagare-db-$DB" -o jsonpath='{.data.CLICKHOUSE_USER}' | base64 -d)"
CH_PASSWORD="$(K get secret "nagare-db-$DB" -o jsonpath='{.data.CLICKHOUSE_PASSWORD}' | base64 -d)"
SVC="$DB.$NS.svc.cluster.local"
native() { K exec "$DB-0" -- env CH_USER="$CH_USER" CH_PASSWORD="$CH_PASSWORD" sh -c 'clickhouse-client --host "$1" --port 9000 --user "$CH_USER" --password "$CH_PASSWORD" --query "$2"' _ "$SVC" "$1"; }
http() { K exec "$DB-0" -- env CH_USER="$CH_USER" CH_PASSWORD="$CH_PASSWORD" sh -c 'wget -q -O - --header "X-ClickHouse-User: $CH_USER" --header "X-ClickHouse-Key: $CH_PASSWORD" --post-data "$2" "http://$1:8123/"' _ "$SVC" "$1"; }
rows() { native "SELECT arrayStringConcat(groupArray(concat(toString(id), ':', note)), ',') FROM (SELECT id, note FROM $1.ep199_probe ORDER BY id)"; }
ready_queries() {
  local n
  for n in $(seq 1 60); do native "SELECT 1" >/dev/null 2>&1 && return 0; sleep 2; done
  echo "ClickHouse did not answer an authenticated native query within 120 s" >&2; exit 1
}
ready_queries
VERSION="$(native 'SELECT version()')"
case "$VERSION" in 26.8.*) record "native version" "$VERSION" ;; *) echo "server reports $VERSION, not 26.8.*" >&2; exit 1 ;; esac
expect "http version" "$(http 'SELECT version()')" "$VERSION"
expect "unauthenticated http" "$(K exec "$DB-0" -- sh -c 'wget -S -q -O - --post-data "SELECT 1" "http://$1:8123/" 2>&1 | sed -n "s/^ *HTTP\/1.1 \([0-9]*\).*/\1/p" | head -1' _ "$SVC" || true)" "401"
expect "unauthenticated native" "$(K exec "$DB-0" -- clickhouse-client --host "$SVC" --port 9000 --user default --query 'SELECT 1' 2>&1 | sed -n 's/.*Code: \([0-9]*\)\..*/\1/p' | head -1 || true)" "516"
expect "server memory cap" "$(native "SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage'")" "1610612736"
expect "mark cache" "$(native "SELECT value FROM system.server_settings WHERE name = 'mark_cache_size'")" "268435456"

# --- 2. rows survive a reviewed restart ---
native "CREATE TABLE default.ep199_probe (id UInt32, note String) ENGINE = MergeTree ORDER BY id"
native "INSERT INTO default.ep199_probe VALUES (1, 'before-restart'), (2, 'backup-sentinel')"
expect "rows before restart" "$(rows default)" "1:before-restart,2:backup-sentinel"
saved restart db restart "$DB" -n "$NS"
for _ in $(seq 1 120); do [ "$(K get pod "$DB-0" -o jsonpath='{.metadata.uid}' 2>/dev/null)" != "$POD_UID" ] && break; sleep 2; done
K rollout status statefulset "$DB" --timeout=600s >/dev/null
K wait pod "$DB-0" --for=condition=Ready --timeout=300s >/dev/null
[ "$(K get pod "$DB-0" -o jsonpath='{.metadata.uid}')" != "$POD_UID" ] || { echo "the reviewed restart did not replace $DB-0" >&2; exit 1; }
POD_UID="$(K get pod "$DB-0" -o jsonpath='{.metadata.uid}')"
ready_queries
case "$(native 'SELECT version()')" in 26.8.*) record "version after restart" "$(native 'SELECT version()')" ;; *) echo "server version changed across the restart" >&2; exit 1 ;; esac
expect "rows after restart" "$(rows default)" "1:before-restart,2:backup-sentinel"

# --- 3. a manual backup, a write after it, and an isolated scratch restore ---
saved backup db backup "$DB" -n "$NS" --backup-id "$MANUAL"
native "INSERT INTO default.ep199_probe VALUES (3, 'after-backup')"
AFTER_BACKUP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
saved restore-manual db restore "$DB" "$MANUAL" -n "$NS" --restore-id manual
# The scratch database is the one this database's restore scope names (scopes/*.json); a
# review also carries other accepted scopes, including earlier restores.
scratch_of() { # review-dir restore-id
  python3 -I - "$1" "$DB" "$2" <<'PY'
import json, pathlib, sys
review, database, restore_id = sys.argv[1:]
found = set()
def walk(node):
    if isinstance(node, dict):
        if node.get("restore.database") == database and node.get("restore.id") == restore_id and isinstance(node.get("restore.target.database"), str):
            found.add(node["restore.target.database"])
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)
for path in sorted(pathlib.Path(review).rglob("*.json")):
    walk(json.loads(path.read_text()))
print(found.pop() if len(found) == 1 else "ambiguous:" + ",".join(sorted(found)))
PY
}
MANUAL_SCRATCH="$(scratch_of "$REVIEWS/restore-manual" manual)"
expect "manual scratch database" "$MANUAL_SCRATCH" "${DB}_restore_manual"
expect "manual scratch rows" "$(rows "\`$MANUAL_SCRATCH\`")" "1:before-restart,2:backup-sentinel"
expect "source rows after manual restore" "$(rows default)" "1:before-restart,2:backup-sentinel,3:after-backup"

# --- 4. a scheduled backup taken after the third row, ingested and restored ---
SCHEDULE="nagare-dbbackup-$DB"
record "schedule" "$(K get cronjob "$SCHEDULE" -o jsonpath='{.spec.schedule}')"
JOB=""
for _ in $(seq 1 $((SCHEDULE_WAIT / 15))); do
  JOB="$(K get jobs -o json | python3 -I -c 'import json,sys; after=sys.argv[1]; sched=sys.argv[2]; jobs=[j for j in json.load(sys.stdin)["items"] if any(o.get("name")==sched for o in j["metadata"].get("ownerReferences",[])) and j["metadata"]["creationTimestamp"] > after and j.get("status",{}).get("succeeded")]; print(sorted(jobs,key=lambda j:j["metadata"]["creationTimestamp"])[0]["metadata"]["name"] if jobs else "")' "$AFTER_BACKUP" "$SCHEDULE")"
  [ -n "$JOB" ] && break
  sleep 15
done
[ -n "$JOB" ] || { echo "no scheduled backup completed within $SCHEDULE_WAIT s after the third row" >&2; exit 1; }
JOB_UID="$(K get job "$JOB" -o jsonpath='{.metadata.uid}')"
record "scheduled job" "$JOB $JOB_UID $(K get job "$JOB" -o jsonpath='{.metadata.creationTimestamp}')"
N db backup-receipts "$DB" -n "$NS" > "$EV/backup-receipts.txt" 2>&1 || { echo "backup-receipts listing failed: $(tail -3 "$EV/backup-receipts.txt")" >&2; exit 1; }
record "listing names the run" "$(grep -q "$JOB_UID" "$EV/backup-receipts.txt" && echo yes || echo no)"
saved scheduled-receipt db backup-receipts "$DB" -n "$NS" --backup-id "$JOB_UID"
saved restore-scheduled db restore "$DB" "$JOB_UID" -n "$NS" --restore-id sched
SCHED_SCRATCH="$(scratch_of "$REVIEWS/restore-scheduled" sched)"
expect "scheduled scratch database" "$SCHED_SCRATCH" "${DB}_restore_sched"
expect "scheduled scratch rows" "$(rows "\`$SCHED_SCRATCH\`")" "1:before-restart,2:backup-sentinel,3:after-backup"
expect "source rows at the end" "$(rows default)" "1:before-restart,2:backup-sentinel,3:after-backup"

# --- 5. no memory failure or unexplained restart over the window ---
expect "pod after the reviewed restart" "$(K get pod "$DB-0" -o jsonpath='{.metadata.uid}')" "$POD_UID"
expect "container restarts" "$(K get pod "$DB-0" -o jsonpath='{.status.containerStatuses[0].restartCount}')" "0"
expect "last termination" "$(K get pod "$DB-0" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}')" ""
expect "OOM events" "$(K get events -o json | python3 -I -c 'import json,sys; print(sum(1 for e in json.load(sys.stdin)["items"] if "oom" in (e.get("reason","")+e.get("message","")).lower()))')" "0"
record "resident memory" "$(native "SELECT formatReadableSize(value) FROM system.asynchronous_metrics WHERE metric = 'MemoryResident'")"
K get pods -o wide > "$EV/pods.txt"
N inventory status --json > "$EV/inventory.json"
unset CH_USER CH_PASSWORD

python3 -I - "$EV" "$CTX" "$DB" "$NS" <<'PY'
import json, sys
ev, context, db, ns = sys.argv[1:]
rows = [line.rstrip("\n").split("\t", 1) for line in open(f"{ev}/observations.tsv")]
candidate = json.load(open(f"{ev}/candidate.json"))
status = json.load(open(f"{ev}/inventory.json"))
record = {
    "schemaVersion": 1, "plan": "EP-199", "mode": "local", "context": context,
    "database": f"{ns}/{db}",
    "candidate": {k: candidate.get(k) for k in ("version", "revision")},
    "observations": [{"step": k, "value": v} for k, v in rows],
    "inventory": {key: status.get(key) for key in ("activeTransaction", "transactionStatus", "observationComplete")},
}
json.dump(record, open(f"{ev}/clickhouse-drill.json", "w"), indent=2, sort_keys=True)
PY
log "ClickHouse drill OK: record in $EV/clickhouse-drill.json"
