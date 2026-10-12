#!/usr/bin/env bash
# EP-172 M3: rehearse the reviewed release transition of a local context, from a published
# source release to this payload, on a disposable Docker daemon; seed a database row before
# the move and read it back unchanged after it. Every step stops at its first refusal.
set -euo pipefail

: "${NAGARE_REHEARSAL_SOURCE:?the source release nagarectl, a nix output bin/nagarectl}"
: "${NAGARE_REHEARSAL_TARGET:?the candidate nagarectl, a nix output bin/nagarectl}"
: "${DOCKER_HOST:?the disposable Docker daemon socket, never the shared cp3 daemon}"
ROOT="${NAGARE_REHEARSAL_ROOT:-$(mktemp -d /private/tmp/nagare-transition.XXXXXX)}"
CTX="${NAGARE_REHEARSAL_CONTEXT:-transition}"
NS=personal
DB=rehearsal
SENTINEL="transition $(date -u +%Y%m%dT%H%M%SZ)"
STAGES_MAX=12

# The ambient shell may carry a context, a payload root and a kubeconfig from direnv; the
# rehearsal uses only its own root and each nagarectl's packaged payload.
for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_REHEARSAL_*) ;; *) unset "$v" ;; esac
done
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
mkdir -p "$ROOT"/{config,state,cache,reviews,evidence,sops/age}
chmod 700 "$ROOT" "$ROOT/sops" "$ROOT/sops/age"
log() { printf '%s rehearsal: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
S() { "$NAGARE_REHEARSAL_SOURCE" --context "$CTX" "$@"; }
T() { "$NAGARE_REHEARSAL_TARGET" --context "$CTX" "$@"; }
# Operations of a review; a review with none that also re-accepts no scope revision is the
# converged state. A review that only re-accepts declarations (a transition re-declares every
# scope from the target payload) is applied, so that the next plan sees them accepted. A source
# release before F124's fix plans a check of every member on each replan, so its bootstrap loop
# does not count VerifyResource; the candidate's loops count every operation.
operations() { python3 -I -c 'import json,sys; ops=json.load(open(sys.argv[1]))["operations"]; print(sum(1 for o in ops if sys.argv[2] == "all" or (o.get("operation", o).get("action") or {}).get("tag") != "VerifyResource"))' "$1/review.json" "${2:-all}"; }
# Every platform replan selects the bootstrap stamp, so it is re-accepted at a new generation
# with the same declaration; it does not count.
reaccepts() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); base={json.dumps(e["scope"],sort_keys=True): e["revision"] for e in d["baseRevisions"]}; print(sum(1 for e in d["desiredRevisions"] if e["scope"].get("name") != "bootstrap-stamp" and base.get(json.dumps(e["scope"],sort_keys=True)) != e["revision"]))' "$1/review.json"; }

# --- 3. the images the platform stages pin, copied once the registry exists ---
seed_images() {
  local pair repo tag
  for pair in en:9577009 shomei:9577009 nagare-access:9577009 nagare-minio:release-2025-09-07-arm64 nagare-mc:release-2025-08-13-arm64; do
    repo="${pair%%:*}"; tag="${pair#*:}"
    # Pinned images stay in the daemon's store across resets; NAGARE_REHEARSAL_IMAGE_DAEMON
    # names a daemon to copy them from when this one lacks them.
    docker image inspect "k3d-registry.localhost:5000/$repo:$tag" >/dev/null 2>&1 \
      || docker --host "${NAGARE_REHEARSAL_IMAGE_DAEMON:?this daemon lacks $repo:$tag; set NAGARE_REHEARSAL_IMAGE_DAEMON}" save "k3d-registry.localhost:5000/$repo:$tag" | docker load >/dev/null
    docker tag "k3d-registry.localhost:5000/$repo:$tag" "localhost:5000/$repo:$tag"
    digest="$(docker push "localhost:5000/$repo:$tag" | sed -n 's/.*digest: \(sha256:[0-9a-f]*\).*/\1/p' | tail -1)"
    [ -n "$digest" ] || { echo "no digest for $repo" >&2; exit 1; }
    case "$repo" in
      en) export NAGARE_AUTH_EN_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      shomei) export NAGARE_AUTH_SHOMEI_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      nagare-access) export NAGARE_AUTH_ACCESS_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      nagare-minio) export NAGARE_LOCAL_MINIO_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      nagare-mc) export NAGARE_LOCAL_MC_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
    esac
  done
  env | grep -E '^NAGARE_(AUTH_[A-Z]+|LOCAL_(MINIO|MC))_IMAGE=' > "$ROOT/images.env"
  # Port 5000 on this Mac belongs to AirPlay, so host-side publications reach the registry
  # through a loopback forward, which the artifact transport honours. The port must be free
  # on the host (cp3's registry tunnel holds 15013), and the forward must answer with this
  # daemon's registry, not another one.
  local port="${NAGARE_REHEARSAL_FORWARD_PORT:-15213}"
  [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/v2/")" = 000 ] || { echo "127.0.0.1:$port is already in use on the host; set NAGARE_REHEARSAL_FORWARD_PORT" >&2; exit 1; }
  docker rm -f registry-forward >/dev/null 2>&1 || true
  docker run -d --name registry-forward --network k3d-nagare-local -p "127.0.0.1:$port:5000" alpine/socat TCP-LISTEN:5000,fork,reuseaddr TCP:k3d-registry.localhost:5000 >/dev/null
  for _ in $(seq 1 30); do curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/v2/" && break; sleep 1; done
  [ "$(curl -s -m 3 "http://127.0.0.1:$port/v2/_catalog")" = "$(docker exec k3d-registry.localhost wget -q -O - http://localhost:5000/v2/_catalog)" ] \
    || { echo "the registry forward on 127.0.0.1:$port does not answer with this daemon's registry" >&2; exit 1; }
  export NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:$port"
}

# An apply that stops ambiguous (an effect the provider did not acknowledge in time) is
# resumed, as the operator would, until it converges; anything else is a stop.
resume_ambiguous() { # bin-fn apply-log
  local fn="$1" applyLog="$2" tx n
  tx="$(tail -2 "$applyLog" | sed -n "s/^ambiguous \(tx-[0-9a-f]*\) at .*/\1/p" | tail -1)"
  [ -n "$tx" ] || return 1
  for n in $(seq 1 12); do
    sleep 20
    log "resume $n of $tx"
    if "$fn" inventory resume "$tx" --yes >> "$applyLog" 2>&1; then return 0; fi
    tail -2 "$applyLog" | grep -q "^ambiguous $tx at " || return 1
  done
  return 1
}

# --- 4. bootstrap on the source release until a review has no operations ---
reviewed_loop() { # bin-fn plan-words... -- apply-words...
  local fn="$1" label="$2"; shift 2
  local n review
  LOOP_REVIEWS=0; LOOP_OPERATIONS=0
  for n in $(seq 1 "$STAGES_MAX"); do
    review="$ROOT/reviews/$label-$n"
    "$fn" platform "${PLAN_CMD[@]}" --out "$review" > "$review.plan.log" 2>&1 || { echo "$label plan $n refused: $(tail -2 "$review.plan.log")" >&2; exit 1; }
    ops="$(operations "$review" "$([ "$label" = bootstrap ] && echo mutating || echo all)")"; moves="$(reaccepts "$review")"
    log "$label stage $n: $ops operations, re-accepts scopes: $moves"
    [ "$ops" != 0 ] || [ "$moves" != 0 ] || return 0
    "$fn" "${APPLY_CMD[@]}" "$review" --yes > "$review.apply.log" 2>&1 || resume_ambiguous "$fn" "$review.apply.log" || { echo "$label apply $n failed: $(tail -3 "$review.apply.log")" >&2; exit 1; }
    LOOP_REVIEWS=$((LOOP_REVIEWS + 1)); LOOP_OPERATIONS=$((LOOP_OPERATIONS + ops))
    if [ "$label" = bootstrap ] && [ ! -f "$ROOT/images.env" ] && docker ps --format '{{.Names}}' | grep -q '^k3d-registry'; then
      seed_images; log "images seeded: $(wc -l < "$ROOT/images.env") pins"
    fi
  done
  echo "$label did not converge in $STAGES_MAX stages" >&2; exit 1
}
if [ "${NAGARE_REHEARSAL_SKIP_BOOTSTRAP:-0}" = 1 ]; then
  # Continue from a root whose context is already bootstrapped on the source release.
  export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
  set -a; . "$ROOT/images.env"; set +a
  export NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:${NAGARE_REHEARSAL_FORWARD_PORT:-15213}"
  bootstrap_reviews=null
  log "continuing in $ROOT on the bootstrapped context $CTX"
else
# --- 0. the daemon is disposable and empty of k3d ---
[ "$DOCKER_HOST" != "unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock" ] || { echo "refusing the shared cp3 daemon" >&2; exit 1; }
if docker ps -a --format '{{.Names}}' | grep -q '^k3d-\|^registry-forward$'; then
  if [ "${NAGARE_REHEARSAL_RESET:-0}" = 1 ]; then
    docker rm -f registry-forward >/dev/null 2>&1 || true
    k3d cluster delete nagare-local >/dev/null 2>&1 || true
    k3d registry delete k3d-registry.localhost >/dev/null 2>&1 || true
  else
    echo "the daemon already holds a k3d cluster; set NAGARE_REHEARSAL_RESET=1 to delete it" >&2; exit 1
  fi
fi
log "root $ROOT; source $("$NAGARE_REHEARSAL_SOURCE" version | head -1); target $("$NAGARE_REHEARSAL_TARGET" version | head -1)"

# --- 1. context-owned observability secrets, encrypted to a fresh age key ---
export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
(umask 077; age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1)
recipient="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
secrets="$XDG_CONFIG_HOME/nagare/cluster-secrets/$CTX"
mkdir -p "$secrets"
printf 'creation_rules:\n  - age: %s\n' "$recipient" > "$secrets/.sops.yaml"
(umask 077; printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin\n  namespace: monitoring\nstringData:\n  admin-user: admin\n  admin-password: %s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" > "$secrets/grafana-admin.yaml")
sops --config "$secrets/.sops.yaml" --encrypt --in-place "$secrets/grafana-admin.yaml"

# --- 2. the context on the source release ---
S context create "$CTX" --mode local --registry-host k3d-registry.localhost:5000 --base-domain 127-0-0-1.sslip.io \
  --target-platform linux/arm64 --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups --use | tail -1
source_version="$(S platform root --json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("platformVersion"))')"
[ "$source_version" = "$("$NAGARE_REHEARSAL_SOURCE" version | sed -n "s/^nagarectl \([0-9.]*\).*/\1/p")" ] || { echo "the source nagarectl resolved payload $source_version, not its own release" >&2; exit 1; }
log "source payload $source_version"

PLAN_CMD=(bootstrap plan); APPLY_CMD=(platform bootstrap apply)
reviewed_loop S bootstrap
bootstrap_reviews=$LOOP_REVIEWS
S inventory status --json > "$ROOT/evidence/before-status.json"
fi

# --- 5. seed a database row on the source release ---
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
if ! kubectl -n "$NS" get statefulset "$DB" >/dev/null 2>&1; then
  S db create postgres "$DB" -n "$NS" --recovery-backup postgres-backup --recovery-key-version v1 | tail -1
fi
pguser="$(kubectl -n "$NS" get secret "nagare-db-$DB" -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)"
pgpass="$(kubectl -n "$NS" get secret "nagare-db-$DB" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
pgdb="$(kubectl -n "$NS" get secret "nagare-db-$DB" -o jsonpath='{.data.POSTGRES_DB}' | base64 -d)"
for _ in $(seq 1 60); do kubectl -n "$NS" exec "$DB-0" -- pg_isready -h 127.0.0.1 -U "$pguser" -d "$pgdb" >/dev/null 2>&1 && break; sleep 2; done
psql_in_pod() { kubectl -n "$NS" exec "$DB-0" -- env PGPASSWORD="$pgpass" psql -h 127.0.0.1 -U "$pguser" -d "$pgdb" -tAc "$1"; }
psql_in_pod "CREATE TABLE IF NOT EXISTS transition_sentinel(v text); TRUNCATE transition_sentinel; INSERT INTO transition_sentinel VALUES ('$SENTINEL');" >/dev/null
log "seeded: $(psql_in_pod 'SELECT v FROM transition_sentinel;')"

# --- 6. the transition on the candidate, then the pin ---
PLAN_CMD=(transition plan); APPLY_CMD=(inventory apply)
reviewed_loop T transition
transition_reviews=$LOOP_REVIEWS; transition_operations=$LOOP_OPERATIONS
T platform transition commit --yes | tail -1

# --- 7. read back on the candidate ---
T platform status --json > "$ROOT/evidence/after-platform.json"
T inventory status --json > "$ROOT/evidence/after-status.json"
got="$(psql_in_pod 'SELECT v FROM transition_sentinel;')"
[ "$got" = "$SENTINEL" ] || { echo "sentinel differs after the transition: $got" >&2; exit 1; }
PLAN_CMD=(bootstrap plan); APPLY_CMD=(platform bootstrap apply)
replan="$ROOT/reviews/replan"
T platform bootstrap plan --out "$replan" > "$replan.plan.log" 2>&1
[ "$(operations "$replan")" = 0 ] && [ "$(reaccepts "$replan")" = 0 ] || { echo "replan on the candidate has operations or re-accepts a scope" >&2; exit 1; }
# The record a release binds (scripts/assemble-release.sh --transition-rehearsal): what moved
# from where, the seeded row and what read back, the final platform status, the idle inventory
# and the converged replan.
python3 -I - "$ROOT" "$CTX" "$("$NAGARE_REHEARSAL_SOURCE" version --json)" "$("$NAGARE_REHEARSAL_TARGET" version --json)" \
  "${bootstrap_reviews:-null}" "$transition_reviews" "$transition_operations" "$SENTINEL" "$got" <<'PY'
import json, sys
root, context, source, candidate, bootstrap_reviews, reviews, operations, seeded, read_back = sys.argv[1:]
identity = lambda raw: {key: json.loads(raw).get(key) for key in ("version", "revision")}
status = json.load(open(f"{root}/evidence/after-status.json"))
record = {
    "schemaVersion": 1, "mode": "local", "context": context,
    "source": identity(source), "candidate": identity(candidate),
    "bootstrap": {"reviews": json.loads(bootstrap_reviews)},
    "transition": {"reviews": int(reviews), "operations": int(operations)},
    "sentinel": {"seeded": seeded, "readBack": read_back},
    "platform": json.load(open(f"{root}/evidence/after-platform.json")),
    "inventory": {key: status.get(key) for key in ("activeTransaction", "transactionStatus", "observationComplete")},
    "replan": {"operations": 0, "reaccepts": 0},
}
json.dump(record, open(f"{root}/evidence/transition-rehearsal.json", "w"), indent=2, sort_keys=True)
PY
log "transition rehearsal OK: record in $ROOT/evidence/transition-rehearsal.json"
