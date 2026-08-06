#!/usr/bin/env bash
# scripts/live-smoke.sh (EP-5, MasterPlan 13) — the live end-to-end smoke test.
#
# Drives the exact paths that were dark for weeks before the 2026-06-10 audit:
# build a private-registry build-mode app, deploy it (cluster pulls the PRIVATE
# image), snapshot a volume to GCS and RESTORE that snapshot (the path that
# returned 401 Anonymous before EP-1's unified GCS-auth helper), confirm the app
# answers HTTP 200, and tear everything down. Soft deps EP-1/EP-2/EP-3/EP-6 are
# all landed, so this runs the real scenario (no skip stub).
#
# This is NOT part of per-PR CI: it needs the running VM + GCP credentials and
# touches the billable cluster. Run it on demand: `just smoke`.
#
# Safety: the single-project guardrail (_require_target_project) refuses to act on
# any project but the configured target; a teardown trap runs on every exit.
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
SNAPSHOT_URL=""
HARNESS_READY=0

cleanup() {
  echo "== teardown =="
  # Cluster-facing cleanup ONLY once our own harness (tunnel + kubeconfig) was
  # verified — otherwise these commands would fire against whatever ambient
  # kubectl context / gcloud project the operator's shell happened to hold.
  if [ "${HARNESS_READY}" = "1" ]; then
    nagarectl app delete "${SMOKE_APP}" --yes >/dev/null 2>&1 || true
    # Best-effort: remove the smoke snapshot object and any restore-scratch PVC.
    [ -n "${SNAPSHOT_URL}" ] && gsutil rm "${SNAPSHOT_URL}" >/dev/null 2>&1 || true
    kubectl -n "${SMOKE_NS}" delete pvc -l nagare.dev/restore-scratch=true >/dev/null 2>&1 || true
  else
    echo "== teardown: harness never became ready; skipping cluster cleanup =="
  fi
  # Our own child tunnels are reaped unconditionally: identified by PID, and by
  # the INSTANCE name in the start-iap-tunnel argv (NOT the app name — tunnels
  # are opened as 'start-iap-tunnel nagare-01 22 …').
  # shellcheck disable=SC2086
  [ -n "${TUN_PIDS}" ] && kill ${TUN_PIDS} 2>/dev/null || true
  pkill -f "start-iap-tunnel ${NAGARE_INSTANCE_NAME:-nagare-01} " 2>/dev/null || true
  echo "== teardown done =="
}
trap cleanup EXIT

# --- Step 1: ensure the VM is RUNNING ---
echo "== step 1: ensure ${NAGARE_INSTANCE_NAME:-nagare-01} is RUNNING =="
INSTANCE="${NAGARE_INSTANCE_NAME:-nagare-01}"
state="$(gcloud --project="${TARGET_PROJECT}" compute instances describe "${INSTANCE}" --zone="${ZONE}" --format='value(status)' 2>/dev/null || echo UNKNOWN)"
if [ "${state}" != "RUNNING" ]; then
  echo "  VM is ${state}; starting it…"
  gcloud --project="${TARGET_PROJECT}" compute instances start "${INSTANCE}" --zone="${ZONE}"
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
# Our own tunnel + kubeconfig are proven: the EXIT trap may now touch the cluster.
HARNESS_READY=1
PUBLIC_IP="$(cd "${NAGARE_REPO_ROOT}/infra/pulumi" && pulumi stack output publicIp 2>/dev/null)"
echo "  KUBECONFIG=${KCFG} ; publicIp=${PUBLIC_IP}"

# --- Step 3: deploy the private-registry build-mode app (EP-2 pull + EP-3 amd64) ---
echo "== step 3: nagarectl deploy ${SMOKE_APP} (build amd64 -> push private AR -> deploy) =="
( cd "${APP_DIR}" && nagarectl deploy --file nagare/Config.hs )
HOST="${SMOKE_APP}.${SMOKE_NS}.${NAGARE_BASE_DOMAIN:-apps.example.com}"
curlapp() { curl -sS --resolve "${HOST}:80:${PUBLIC_IP}" "$@"; }

# --- Step 4: snapshot + restore the volume (EP-1; the old 401-Anonymous path) ---
echo "== step 4a: write a sentinel into the volume =="
curlapp -X POST --data "smoke ok $$" "http://${HOST}/upload/${SENTINEL}" >/dev/null
got="$(curlapp "http://${HOST}/files/${SENTINEL}")"
echo "  uploaded + read back: ${got}"

echo "== step 4b: snapshot the volume to GCS =="
snap_out="$(nagarectl storage snapshot "${SMOKE_APP}" "${SMOKE_VOL}" --config "${APP_DIR}/nagare/Config.hs")"
echo "${snap_out}"
SNAPSHOT_URL="$(echo "${snap_out}" | sed -n 's/^Snapshot written: //p' | head -1)"
SNAP_ID="$(basename "${SNAPSHOT_URL}" .tar.gz)"
echo "  snapshot: ${SNAPSHOT_URL} (id ${SNAP_ID})"

echo "== step 4c: restore the snapshot into a scratch PVC and confirm the sentinel round-trips =="
restore_out="$(nagarectl storage restore "${SMOKE_APP}" "${SMOKE_VOL}" "${SNAP_ID}" --config "${APP_DIR}/nagare/Config.hs")"
echo "${restore_out}"
if echo "${restore_out}" | grep -q "${SENTINEL}"; then
  echo "  RESTORE OK: sentinel ${SENTINEL} present in the restored tree"
else
  echo "  RESTORE FAILED: sentinel ${SENTINEL} not found in the restored tree" >&2
  exit 1
fi

# --- Step 5: verify HTTP 200 through the gateway ---
echo "== step 5: verify HTTP 200 =="
code="$(curlapp -o /dev/null -w '%{http_code}' "http://${HOST}/")"
if [ "${code}" = "200" ]; then
  echo "  HTTP ${code} OK"
else
  echo "  expected 200, got ${code}" >&2
  exit 1
fi

# --- Step 6: teardown runs via the trap ---
echo "live smoke: OK"
