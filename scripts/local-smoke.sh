#!/usr/bin/env bash
# scripts/local-smoke.sh (EP-86, MasterPlan 16) — the LOCAL end-to-end smoke test.
#
# The zero-cloud twin of scripts/live-smoke.sh: the SAME scenario (deploy ->
# sentinel -> snapshot -> restore -> HTTP 200 -> teardown), but against the EP-82
# k3d cluster + local registry, with the volume snapshot round-tripping through
# the local MinIO object store (EP-84) instead of GCS. NO gcloud, IAP, or GCS.
#
# Local mode (NAGARE_MODE=local) makes scripts/lib/target.sh's GCP guardrail step
# aside (MasterPlan 16, Integration Point 6): there is no GCP project to protect.
#
# Requires only Docker + the dev shell. If the local cluster is down the script
# stands it up (just local-up + local-bootstrap + local-minio, all EP-82/EP-84).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NAGARE_MODE=local                 # set BEFORE the guardrail call (IP-6)
# shellcheck source=scripts/lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"

# Populate the local-target contract variables (Integration Point 1) when the
# shell did not already (e.g. invoked outside direnv). Environment wins; we only
# fill in from the profile — preferring the real nagare.local.env, else the
# tracked worked example — when the canonical vars are unset.
if [ -z "${NAGARE_BASE_DOMAIN:-}" ] || [ -z "${NAGARE_REGISTRY_HOST:-}" ]; then
  LOCAL_ENV="${NAGARE_REPO_ROOT}/nagare.local.env"
  [ -f "${LOCAL_ENV}" ] || LOCAL_ENV="${NAGARE_REPO_ROOT}/nagare.local.env.example"
  # shellcheck disable=SC1090
  [ -f "${LOCAL_ENV}" ] && . "${LOCAL_ENV}"
fi

_require_target_project                  # short-circuits in local mode (EP-82)

# The smoke app is the shipped uploads-volume example: a build-mode app with a
# durable /uploads volume and upload/list endpoints — ideal for a snapshot/restore
# round-trip (identical pinning to scripts/live-smoke.sh).
SMOKE_APP="uploads-volume"
SMOKE_VOL="uploads"
SMOKE_NS="personal"
APP_DIR="${NAGARE_REPO_ROOT}/cluster/examples/${SMOKE_APP}"
SENTINEL="smoke-sentinel-$$.txt"
CONFIG="${APP_DIR}/nagare/Config.hs"

# Resolve a runnable nagarectl: prefer one on PATH, else build + use the binary.
echo "== building nagarectl =="
( cd "${NAGARE_REPO_ROOT}/cli/nagarectl" && cabal build -v0 exe:nagarectl )
NAGARECTL_BIN="$(ls "${NAGARE_REPO_ROOT}"/cli/nagarectl/dist-newstyle/build/*/ghc-*/nagarectl-*/x/nagarectl/build/nagarectl/nagarectl | head -1)"
nagarectl() { "${NAGARECTL_BIN}" "$@"; }

SNAPSHOT_URL=""
PF_PID=""

# Best-effort removal of the local MinIO snapshot object (there is no `nagarectl
# storage delete`; everything is wiped by `just local-down` anyway). Runs a
# throwaway minio/mc pod against the in-cluster endpoint. Local creds are the
# fixed minioadmin/minioadmin seeded by cluster/local/minio/minio.yaml.
minio_rm() {
  local url="$1" key
  key="${url#s3://}"                                 # nagare-backups/volumes/...
  [ "${key}" = "${url}" ] && return 0                # not an s3:// url; skip
  kubectl -n nagare-system run "minio-rm-$$" --rm -i --restart=Never \
    --image=minio/mc:latest --quiet \
    --env=AK=minioadmin --env=SK=minioadmin --command -- /bin/sh -c \
    "mc alias set s http://minio.nagare-system.svc.cluster.local:9000 \"\$AK\" \"\$SK\" >/dev/null 2>&1 && mc rm \"s/${key}\"" \
    >/dev/null 2>&1 || true
}

cleanup() {
  echo "== teardown =="
  # `app delete NAME -n NS` deletes the Knative Service + DomainMappings + history
  # (no --yes flag, no prompt); it resolves domains from the cluster when the
  # config file is absent, so it is safe to run from the repo root.
  nagarectl app delete "${SMOKE_APP}" -n "${SMOKE_NS}" >/dev/null 2>&1 || true
  # Best-effort: drop the local MinIO snapshot object + any restore-scratch PVC.
  [ -n "${SNAPSHOT_URL}" ] && minio_rm "${SNAPSHOT_URL}"
  kubectl -n "${SMOKE_NS}" delete pvc -l nagare.dev/restore-scratch=true >/dev/null 2>&1 || true
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  echo "== teardown done =="
}
trap cleanup EXIT

# --- Step 1 (vs. cloud Step 1+2): ensure the LOCAL cluster is up. NO VM, NO IAP.
echo "== step 1: ensure the local k3d cluster + registry + MinIO are up =="
if ! k3d cluster list nagare-local >/dev/null 2>&1; then
  ( cd "${NAGARE_REPO_ROOT}" && just local-up && just local-bootstrap && just local-minio )
fi
# Talk to the local cluster regardless of any ambient KUBECONFIG (no IAP tunnel,
# no scripts/live-test.sh): use the kubeconfig k3d writes for this cluster.
export KUBECONFIG="$(k3d kubeconfig write nagare-local)"
kubectl get nodes >/dev/null
# MinIO may be absent if the cluster was brought up by a bare `just local-up`.
if ! kubectl -n nagare-system get deploy/minio >/dev/null 2>&1; then
  ( cd "${NAGARE_REPO_ROOT}" && just local-minio )
fi

# --- Step 2 (vs. cloud Step 3): deploy on the local cluster ---
echo "== step 2: nagarectl deploy ${SMOKE_APP} (host-arch build -> local registry) =="
deploy_out="$( cd "${APP_DIR}" && nagarectl deploy --file nagare/Config.hs )"
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
echo "  read back: $(curlapp "${BASE}/files/${SENTINEL}")"

echo "== step 3b: snapshot the volume to local MinIO =="
snap_out="$(nagarectl storage snapshot "${SMOKE_APP}" "${SMOKE_VOL}" --config "${CONFIG}")"
echo "${snap_out}"
SNAPSHOT_URL="$(printf '%s\n' "${snap_out}" | sed -n 's/^Snapshot written: //p' | head -1)"
SNAP_ID="$(basename "${SNAPSHOT_URL}" .tar.gz)"
echo "  snapshot: ${SNAPSHOT_URL} (id ${SNAP_ID})"
case "${SNAPSHOT_URL}" in
  s3://*) : ;;
  *) echo "  expected an s3:// (MinIO) snapshot URL, got '${SNAPSHOT_URL}'" >&2; exit 1 ;;
esac

echo "== step 3c: delete the live data, then restore + confirm the sentinel round-trips =="
curlapp -X POST --data "" "${BASE}/upload/${SENTINEL}" >/dev/null   # clobber the live copy
restore_out="$(nagarectl storage restore "${SMOKE_APP}" "${SMOKE_VOL}" "${SNAP_ID}" --config "${CONFIG}")"
echo "${restore_out}"
if printf '%s\n' "${restore_out}" | grep -q "${SENTINEL}"; then
  echo "  RESTORE OK: sentinel ${SENTINEL} present in the restored tree"
else
  echo "  RESTORE FAILED: sentinel ${SENTINEL} not found in the restored tree" >&2
  exit 1
fi

# --- Step 4 (vs. cloud Step 5): verify HTTP 200 — plain loopback, no gateway IP ---
echo "== step 4: verify HTTP 200 =="
code="$(curlapp -o /dev/null -w '%{http_code}' "${BASE}/")"
if [ "${code}" = "200" ]; then
  echo "  HTTP ${code} OK"
else
  echo "  expected 200, got ${code}" >&2
  exit 1
fi

# --- Step 5: teardown runs via the trap ---
echo "local smoke: OK"
