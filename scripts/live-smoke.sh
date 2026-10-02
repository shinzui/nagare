#!/usr/bin/env bash
# scripts/live-smoke.sh (EP-5, MasterPlan 13) — the live end-to-end smoke test.
#
# Drives the exact paths that were dark for weeks before the 2026-06-10 audit:
# build a private-registry app archive, publish and deploy it under reviews
# (cluster pulls the PRIVATE
# image), snapshot a volume to GCS and RESTORE that snapshot (the path that
# returned 401 Anonymous before EP-1's unified GCS-auth helper), confirm the app
# answers HTTP 200, and tear everything down. Soft deps EP-1/EP-2/EP-3/EP-6 are
# all landed, so this runs the real scenario (no skip stub).
#
# This is NOT part of per-PR CI: it needs the running VM + GCP credentials and
# touches the billable cluster. Run it on demand: `just smoke`.
#
# Safety: the single-project guardrail (_require_target_project) refuses to act on
# any project but the configured target; reviews and accepted resources remain
# available for exact recovery after interruption.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"
_require_target_project

# The smoke app is the shipped uploads-volume example: a build-mode app with a
# durable /uploads volume and upload/list endpoints — ideal for a snapshot/restore
# round-trip.
SMOKE_APP="uploads-volume"
SMOKE_VOL="uploads"
SMOKE_NS="personal"
APP_DIR="${NAGARE_REPO_ROOT}/cluster/examples/${SMOKE_APP}"
SENTINEL="smoke-sentinel-$$.txt"

export ZONE="${ZONE:-${TARGET_ZONE}}"
export SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

# Resolve a runnable nagarectl: prefer one on PATH, else build + use the binary.
echo "== building nagarectl =="
( cd "${NAGARE_REPO_ROOT}/cli/nagarectl" && cabal build -v0 exe:nagarectl )
NAGARECTL_BIN="$(ls "${NAGARE_REPO_ROOT}"/cli/nagarectl/dist-newstyle/build/*/ghc-*/nagarectl-*/x/nagarectl/build/nagarectl/nagarectl | head -1)"
nagarectl() { "${NAGARECTL_BIN}" "$@"; }

TUN_PIDS=""
SMOKE_RUN_ID="s$(date -u +%y%m%d%H%M%S)$$"
SMOKE_RUN_ID="${SMOKE_RUN_ID:0:20}"
REVIEW_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nagare-live-smoke.XXXXXX")"

cleanup() {
  echo "== teardown =="
  # Retain accepted resources and private reviews for exact recovery/collection.
  echo "  accepted resources retained; reviews: ${REVIEW_ROOT}"
  # Reap only tunnels started by this invocation.
  # shellcheck disable=SC2086
  [ -n "${TUN_PIDS}" ] && kill ${TUN_PIDS} 2>/dev/null || true
  echo "== teardown done =="
}
trap cleanup EXIT

review_apply() {
  nagarectl inventory apply "$1" --yes
}

# --- Step 1: ensure the VM is RUNNING ---
echo "== step 1: ensure ${NAGARE_INSTANCE_NAME:-nagare-01} is RUNNING =="
INSTANCE="${NAGARE_INSTANCE_NAME:-nagare-01}"
state="$(gcloud --project="${TARGET_PROJECT}" compute instances describe "${INSTANCE}" --zone="${ZONE}" --format='value(status)' 2>/dev/null || echo UNKNOWN)"
if [ "${state}" != "RUNNING" ]; then
  echo "  VM is ${state}; starting it…"
  nagarectl host start --operation-id "${SMOKE_RUN_ID}-start" --save-plan "${REVIEW_ROOT}/vm-start"
  review_apply "${REVIEW_ROOT}/vm-start"
  sleep 30
fi

# --- Step 2: stand up the workstation->cluster harness (EP-6) ---
echo "== step 2: just live-test harness =="
LT_OUT="$("${NAGARE_REPO_ROOT}/scripts/live-test.sh" 2>/dev/null)"
KCFG="$(echo "${LT_OUT}" | grep '^KUBECONFIG=' | cut -d= -f2-)"
TUN_PIDS="$(echo "${LT_OUT}" | grep '^# when done: kill' | sed 's/^# when done: kill //')"
if [ -z "${KCFG}" ]; then echo "  live-test failed to produce a KUBECONFIG" >&2; exit 1; fi
export KUBECONFIG="${KCFG}"
kubectl get nodes >/dev/null
# Our own tunnel + kubeconfig are proven.
PUBLIC_IP="$(cd "${NAGARE_REPO_ROOT}/infra/pulumi" && pulumi stack output publicIp 2>/dev/null)"
echo "  KUBECONFIG=${KCFG} ; publicIp=${PUBLIC_IP}"

# --- Step 3: deploy the private-registry build-mode app (EP-2 pull + EP-3 amd64) ---
echo "== step 3: review image publication and deploy ${SMOKE_APP} =="
image_out="$(nagarectl app image-plan \
  --archive "${REVIEW_ROOT}/image.tar" \
  --build-dockerfile "${APP_DIR}/Dockerfile" --build-context "${APP_DIR}" \
  --destination "${NAGARE_REGISTRY_HOST}/${TARGET_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}/${SMOKE_APP}:${SMOKE_RUN_ID}" \
  --key "${SMOKE_RUN_ID}" --save-plan "${REVIEW_ROOT}/image-review")"
echo "${image_out}"
IMAGE_RESOURCE="$(printf '%s\n' "${image_out}" | sed -n 's/^Image resource: //p' | tail -1)"
[ -n "${IMAGE_RESOURCE}" ] || { echo "live smoke: image review did not name a resource" >&2; exit 1; }
review_apply "${REVIEW_ROOT}/image-review"
( cd "${APP_DIR}" && nagarectl deploy --file nagare/Config.hs \
  --tag "${SMOKE_RUN_ID}" --image-resource "${IMAGE_RESOURCE}" )
HOST="${SMOKE_APP}.${SMOKE_NS}.${NAGARE_BASE_DOMAIN:-apps.example.com}"
curlapp() { curl -sS --resolve "${HOST}:80:${PUBLIC_IP}" "$@"; }

# --- Step 4: snapshot + restore the volume (EP-1; the old 401-Anonymous path) ---
echo "== step 4a: write a sentinel into the volume =="
curlapp -X POST --data "smoke ok $$" "http://${HOST}/upload/${SENTINEL}" >/dev/null
got="$(curlapp "http://${HOST}/files/${SENTINEL}")"
[ "${got}" = "smoke ok $$" ] || { echo "live smoke: volume sentinel readback differed: ${got}" >&2; exit 1; }
echo "  uploaded + read back: ${got}"

echo "== step 4b: snapshot the volume to GCS =="
SNAP_ID="${SMOKE_RUN_ID}"
nagarectl storage snapshot "${SMOKE_APP}" "${SMOKE_VOL}" \
  --config "${APP_DIR}/nagare/Config.hs" --snapshot-id "${SNAP_ID}" \
  --save-plan "${REVIEW_ROOT}/volume-backup"
review_apply "${REVIEW_ROOT}/volume-backup"
echo "  accepted volume snapshot: ${SNAP_ID}"

echo "== step 4c: restore the accepted snapshot into a scratch PVC =="
nagarectl storage restore "${SMOKE_APP}" "${SMOKE_VOL}" "${SNAP_ID}" \
  --config "${APP_DIR}/nagare/Config.hs" --restore-id "${SMOKE_RUN_ID}" \
  --save-plan "${REVIEW_ROOT}/volume-restore"
review_apply "${REVIEW_ROOT}/volume-restore"
echo "  RESTORE OK: accepted receipt and archive verified into scratch PVC"

# --- Step 5: verify HTTP 200 through the gateway ---
echo "== step 5: verify HTTP 200 =="
code="$(curlapp -o /dev/null -w '%{http_code}' "http://${HOST}/")"
if [ "${code}" = "200" ]; then
  echo "  HTTP ${code} OK"
else
  echo "  expected 200, got ${code}" >&2
  exit 1
fi

# --- Step 6: the trap closes this invocation's tunnels ---
echo "live smoke: OK"
