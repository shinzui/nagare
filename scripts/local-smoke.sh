#!/usr/bin/env bash
# scripts/local-smoke.sh (EP-86, MasterPlan 16) — the LOCAL end-to-end smoke test.
#
# The zero-cloud twin of scripts/live-smoke.sh: the SAME scenario (reviewed
# publication/deploy -> sentinel -> reviewed snapshot/restore -> HTTP 200), against the EP-82
# k3d cluster + local registry, with the volume snapshot round-tripping through
# the local MinIO object store (EP-84) instead of GCS. NO gcloud, IAP, or GCS.
#
# Local mode (NAGARE_MODE=local) makes scripts/lib/target.sh's GCP guardrail step
# aside (MasterPlan 16, Integration Point 6): there is no GCP project to protect.
#
# Requires Docker plus the platform tools used by the local recipes. The
# packaged launcher supplies nagarectl; a contributor dev shell supplies the
# same toolchain. If the local cluster is down the script stands it up (just
# local-up + local-bootstrap + local-minio, all EP-82/EP-84).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This harness owns one fixed loopback target. Clear an inherited resolution
# marker before sourcing target.sh: a packaged workspace has a different root
# from the contributor shell that may have exported the marker, and target.sh
# deliberately clears stale context variables when those identities disagree.
unset NAGARE_RESOLVED_CONTEXT NAGARE_ACTIVE_CONTEXT NAGARE_ACTIVE_CONTEXT_FILE
export NAGARE_MODE=local
export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io
export NAGARE_LOCAL_OBJECT_STORE=http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
case "$(uname -m)" in
  arm64|aarch64) export NAGARE_TARGET_PLATFORM=linux/arm64 ;;
  *) export NAGARE_TARGET_PLATFORM=linux/amd64 ;;
esac
# shellcheck source=scripts/lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"

_require_target_project                  # short-circuits in local mode (EP-82)

# The smoke app is the shipped uploads-volume example: a build-mode app with a
# durable /uploads volume and upload/list endpoints — ideal for a snapshot/restore
# round-trip (identical pinning to scripts/live-smoke.sh).
SMOKE_APP="uploads-volume"
SMOKE_VOL="uploads"
SMOKE_NS="personal"
APP_DIR="${NAGARE_REPO_ROOT}/cluster/examples/${SMOKE_APP}"
SENTINEL="smoke-sentinel-$$.txt"
# shellcheck source=scripts/lib/smoke-readback.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/smoke-readback.sh"
CONFIG="${APP_DIR}/nagare/Config.hs"

# Resolve a runnable nagarectl. Packaged `nagare local-smoke` already puts the
# release-matched CLI on PATH and its workspace deliberately has no contributor
# `cli/` tree. A source checkout without an installed CLI retains the Cabal
# fallback so contributor behavior stays unchanged.
if command -v nagarectl >/dev/null 2>&1; then
  NAGARECTL_BIN="$(command -v nagarectl)"
  echo "== using nagarectl: ${NAGARECTL_BIN} =="
elif [ -d "${NAGARE_REPO_ROOT}/cli/nagarectl" ]; then
  echo "== building checkout nagarectl =="
  ( cd "${NAGARE_REPO_ROOT}/cli/nagarectl" && cabal build -v0 exe:nagarectl )
  NAGARECTL_BIN="$(find "${NAGARE_REPO_ROOT}/cli/nagarectl/dist-newstyle/build" -path '*/x/nagarectl/build/nagarectl/nagarectl' -type f -print -quit)"
  if [ -z "${NAGARECTL_BIN}" ]; then
    echo "local smoke: Cabal completed but no nagarectl executable was found" >&2
    exit 1
  fi
else
  echo "local smoke: nagarectl is not on PATH and this platform workspace has no contributor CLI source" >&2
  exit 1
fi
nagarectl() { "${NAGARECTL_BIN}" "$@"; }

SMOKE_DB="smokedb"
PF_PID=""
SMOKE_RUN_ID="s$(date -u +%y%m%d%H%M%S)$$"
SMOKE_RUN_ID="${SMOKE_RUN_ID:0:20}"
REVIEW_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nagare-local-smoke.XXXXXX")"

cleanup() {
  # Preserve accepted reviews and their private journals for exact recovery.
  # Broad PVC/object deletion would bypass the reviewed collection boundary.
  echo "  accepted resources retained; reviews: ${REVIEW_ROOT}"
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  echo "== teardown done =="
}
trap cleanup EXIT

review_apply() {
  nagarectl inventory apply "$1" --yes
}

# --- Step 1 (vs. cloud Step 1+2): ensure the LOCAL cluster is up. NO VM, NO IAP.
echo "== step 1: ensure the local k3d cluster + registry + MinIO are up =="
if ! k3d cluster list nagare-local >/dev/null 2>&1; then
  ( cd "${NAGARE_REPO_ROOT}" && just local-up && just local-bootstrap && just local-minio )
fi
# Talk to the local cluster regardless of any ambient KUBECONFIG (no IAP tunnel,
# no scripts/live-test.sh): use the kubeconfig k3d writes for this cluster.
KUBECONFIG="$(k3d kubeconfig write nagare-local)"
export KUBECONFIG
kubectl get nodes >/dev/null
# The k3d kubeconfig is written and answering.
# MinIO may be absent if the cluster was brought up by a bare `just local-up`.
if ! kubectl -n nagare-system get deploy/minio >/dev/null 2>&1; then
  ( cd "${NAGARE_REPO_ROOT}" && just local-minio )
fi

# --- Step 2 (vs. cloud Step 3): deploy on the local cluster ---
echo "== step 2: review image publication and deploy ${SMOKE_APP} =="
image_out="$(nagarectl app image-plan \
  --archive "${REVIEW_ROOT}/image.tar" \
  --build-dockerfile "${APP_DIR}/Dockerfile" --build-context "${APP_DIR}" \
  --destination "${NAGARE_REGISTRY_HOST}/${TARGET_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}/${SMOKE_APP}:${SMOKE_RUN_ID}" \
  --key "${SMOKE_RUN_ID}" --save-plan "${REVIEW_ROOT}/image-review")"
echo "${image_out}"
IMAGE_RESOURCE="$(printf '%s\n' "${image_out}" | sed -n 's/^Image resource: //p' | tail -1)"
[ -n "${IMAGE_RESOURCE}" ] || { echo "local smoke: image review did not name a resource" >&2; exit 1; }
review_apply "${REVIEW_ROOT}/image-review"
deploy_out="$( cd "${APP_DIR}" && nagarectl deploy --file nagare/Config.hs \
  --tag "${SMOKE_RUN_ID}" --image-resource "${IMAGE_RESOURCE}" )"
echo "${deploy_out}"
URL="$(printf '%s\n' "${deploy_out}" | sed -n 's/^Deployed: //p' | head -1)"
URL="${URL:-https://${SMOKE_APP}.${SMOKE_NS}.${NAGARE_BASE_DOMAIN}}"
# The route host Knative matches on (scheme + path stripped). Used as the curl
# `Host:` header through the Kourier port-forward below.
APP_HOST="$(printf '%s' "${URL}" | sed -E 's#^https?://##; s#/.*$##')"
echo "  app URL: ${URL} (host ${APP_HOST})"

# Reach Knative via a Kourier port-forward + Host header rather than curling the
# loopback domain directly. On the loopback wildcard a host reverse proxy
# (Caddy/portless) can hold ports 80/443 and shadow the k3d load balancer
# (MasterPlan 16, EP-82 Surprise: "Literal curl http://<app>.<base> can be
# intercepted by a host process on port 80"). The port-forward owns a fresh
# 127.0.0.1 port that bypasses any such proxy and hits Kourier directly. Kourier
# serves the route over HTTP on :80 (HTTP 200, no forced HTTPS redirect) even when
# EP-85's external-domain-tls is Enabled, so the smoke needs no TLS/CA trust.
PF_PORT=18080
echo "== port-forward kourier :80 -> 127.0.0.1:${PF_PORT} =="
kubectl -n kourier-system port-forward svc/kourier "${PF_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
BASE="http://127.0.0.1:${PF_PORT}"
# Wait for the forward to accept connections (any HTTP reply means it is up).
for _ in $(seq 1 30); do curl -sS -o /dev/null "${BASE}/" >/dev/null 2>&1 && break || sleep 1; done
curlapp() { curl -sS -H "Host: ${APP_HOST}" "$@"; }

# --- Step 3 (vs. cloud Step 4): sentinel + snapshot + restore via MinIO ---
echo "== step 3a: write a sentinel into the volume =="
curlapp -X POST --data "smoke ok $$" "${BASE}/upload/${SENTINEL}" >/dev/null
got="$(curlapp "${BASE}/files/${SENTINEL}")"
[ "${got}" = "smoke ok $$" ] || { echo "local smoke: volume sentinel readback differed: ${got}" >&2; exit 1; }
echo "  read back: ${got}"

echo "== step 3b: snapshot the volume to local MinIO =="
SNAP_ID="${SMOKE_RUN_ID}"
nagarectl storage snapshot "${SMOKE_APP}" "${SMOKE_VOL}" --config "${CONFIG}" \
  --snapshot-id "${SNAP_ID}" --save-plan "${REVIEW_ROOT}/volume-backup"
review_apply "${REVIEW_ROOT}/volume-backup"
echo "  accepted volume snapshot: ${SNAP_ID}"

echo "== step 3c: clobber live data, then restore the accepted archive to scratch =="
curlapp -X POST --data "" "${BASE}/upload/${SENTINEL}" >/dev/null   # clobber the live copy
nagarectl storage restore "${SMOKE_APP}" "${SMOKE_VOL}" "${SNAP_ID}" --config "${CONFIG}" \
  --restore-id "${SMOKE_RUN_ID}" --save-plan "${REVIEW_ROOT}/volume-restore"
review_apply "${REVIEW_ROOT}/volume-restore"
verify_restored_sentinel "${SMOKE_NS}" "nagare-volrestore-${SMOKE_APP}-${SMOKE_VOL}-${SMOKE_RUN_ID}" \
  "${SENTINEL}" "smoke ok $$"
live="$(curlapp "${BASE}/files/${SENTINEL}")"
[ -z "${live}" ] || { echo "local smoke: restore changed the live volume: ${live}" >&2; exit 1; }
echo "  RESTORE OK: scratch PVC holds the sentinel; the live copy kept its clobbered value"

# --- Step 4 (vs. cloud Step 5): verify HTTP 200 — plain loopback, no gateway IP ---
echo "== step 4: verify HTTP 200 =="
code="$(curlapp -o /dev/null -w '%{http_code}' "${BASE}/")"
if [ "${code}" = "200" ]; then
  echo "  HTTP ${code} OK"
else
  echo "  expected 200, got ${code}" >&2
  exit 1
fi

# --- Step 5 (EP-101): managed-DB backup -> restore round-trip via MinIO ---
echo "== step 5: managed-DB create -> backup -> restore -> assert row count =="
nagarectl db create postgres "${SMOKE_DB}" -n "${SMOKE_NS}" \
  --recovery-backup postgres-backup --recovery-key-version v1

# Read the managed identity once. The password is passed only as the psql
# process environment inside the pod; it is never printed or written to disk.
PGUSER="$(kubectl -n "${SMOKE_NS}" get secret "nagare-db-${SMOKE_DB}" -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)"
PGPASSWORD="$(kubectl -n "${SMOKE_NS}" get secret "nagare-db-${SMOKE_DB}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
PGDB="$(kubectl -n "${SMOKE_NS}" get secret "nagare-db-${SMOKE_DB}" -o jsonpath='{.data.POSTGRES_DB}' | base64 -d)"
for _attempt in $(seq 1 60); do
  if kubectl -n "${SMOKE_NS}" exec "${SMOKE_DB}-0" -- \
      pg_isready -h 127.0.0.1 -U "${PGUSER}" -d "${PGDB}" >/dev/null 2>&1; then
    break
  fi
  if [ "${_attempt}" = "60" ]; then
    echo "local smoke: PostgreSQL did not accept connections within 120s" >&2
    exit 1
  fi
  sleep 2
done
psql_in_pod() {
  kubectl -n "${SMOKE_NS}" exec "${SMOKE_DB}-0" -- \
    env PGPASSWORD="${PGPASSWORD}" psql -h 127.0.0.1 -U "${PGUSER}" -d "$1" -tAc "$2"
}

echo "== step 5a: write a sentinel row =="
psql_in_pod "${PGDB}" "CREATE TABLE IF NOT EXISTS smoke_sentinel(v text); TRUNCATE smoke_sentinel; INSERT INTO smoke_sentinel VALUES ('smoke $$');"

echo "== step 5b: back up to MinIO =="
nagarectl db backup "${SMOKE_DB}" -n "${SMOKE_NS}" \
  --backup-id "${SMOKE_RUN_ID}" --save-plan "${REVIEW_ROOT}/db-backup"
review_apply "${REVIEW_ROOT}/db-backup"

echo "== step 5c: clobber the live table, restore into the scratch target =="
psql_in_pod "${PGDB}" "TRUNCATE smoke_sentinel;"
nagarectl db restore "${SMOKE_DB}" "${SMOKE_RUN_ID}" -n "${SMOKE_NS}" \
  --restore-id "${SMOKE_RUN_ID}" --save-plan "${REVIEW_ROOT}/db-restore"
review_apply "${REVIEW_ROOT}/db-restore"

echo "== step 5d: assert the sentinel row survived the round-trip =="
db_count="$(psql_in_pod "${PGDB}_restore_${SMOKE_RUN_ID}" "SELECT count(*) FROM smoke_sentinel;" | tr -d '[:space:]')"
if [ "${db_count}" = "1" ]; then
  echo "  DB RESTORE OK: smoke_sentinel has ${db_count} row in ${PGDB}_restore_${SMOKE_RUN_ID}"
else
  echo "  DB RESTORE FAILED: expected 1 row in ${PGDB}_restore_${SMOKE_RUN_ID}, got '${db_count}'" >&2
  exit 1
fi

# --- Step 6: the trap closes this invocation's port-forward ---
echo "local smoke: OK"
