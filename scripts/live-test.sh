#!/usr/bin/env bash
# scripts/live-test.sh (EP-6, MasterPlan 13) — stand up a workstation->cluster
# kube connection in ONE command.
#
# The k3s API server listens on 127.0.0.1:6443 on the VM, and the project's
# firewall exposes only port 22 (over IAP). So reaching the API from a
# workstation is a five-step dance (open an IAP port-22 tunnel, layer an ssh -L
# forward of the API port over it, fetch the cluster kubeconfig, rewrite its
# server: to the forwarded port, export KUBECONFIG). This script does all of it
# and prints the KUBECONFIG to export, plus the PIDs to kill when done. It reuses
# scripts/iap-ssh.sh for the tunnel and the root-file fetch.
#
# Env overrides:
#   LIVE_TEST_PORT      local port the k3s API is forwarded to (default 16443)
#   LIVE_TEST_SSH_PORT  local port for the IAP port-22 tunnel (default 2223)
#   SSH_USER / SSH_KEY  passed through to scripts/iap-ssh.sh (default deploy /
#                       ~/.ssh/id_ed25519)
set -euo pipefail

# Load the target profile + fail-closed project guard (same preamble as iap-ssh.sh).
# Exports NAGARE_REPO_ROOT, TARGET_ZONE, NAGARE_SSH_USER, and the project guard.
source "$(dirname "$0")/lib/target.sh"
_require_target_project

INSTANCE="${NAGARE_INSTANCE_NAME:-nagare-01}"
LOCAL_API_PORT="${LIVE_TEST_PORT:-16443}"
SSH_TUN_PORT="${LIVE_TEST_SSH_PORT:-2223}"
KCDIR="${NAGARE_REPO_ROOT}/.live-test"
KCFG="${KCDIR}/kubeconfig.yaml"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
# iap-ssh.sh needs a zone; default it from the profile if the caller did not set one.
export ZONE="${ZONE:-${TARGET_ZONE}}"
export SSH_KEY

mkdir -p "${KCDIR}"

echo "live-test: fetching kubeconfig from ${INSTANCE} ..." >&2
# 1) Fetch the root-owned k3s kubeconfig (recv-file streams it via `sudo cat`,
#    logging in as the M2-resolved deploy user).
"${NAGARE_REPO_ROOT}/scripts/iap-ssh.sh" recv-file "${INSTANCE}" /etc/rancher/k3s/k3s.yaml "${KCFG}"

echo "live-test: opening IAP port-22 tunnel (localhost:${SSH_TUN_PORT}) ..." >&2
# 2) Open the port-22 IAP tunnel (IAP forwards only 22). It persists after
#    iap-ssh.sh returns; we kill it via the printed PID.
TUN_PID="$("${NAGARE_REPO_ROOT}/scripts/iap-ssh.sh" tunnel "${INSTANCE}" 22 "${SSH_TUN_PORT}" 2>/dev/null | head -1)"
if [ -z "${TUN_PID}" ]; then
  echo "live-test: failed to open the IAP port-22 tunnel" >&2
  exit 1
fi

echo "live-test: forwarding k3s API 6443 -> localhost:${LOCAL_API_PORT} over the tunnel ..." >&2
# 3) Layer an ssh -L forward of the k3s API (127.0.0.1:6443 on the VM) over the
#    port-22 tunnel. nohup + disown so it survives this script exiting.
nohup ssh -p "${SSH_TUN_PORT}" -i "${SSH_KEY}" \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
  -L "${LOCAL_API_PORT}:127.0.0.1:6443" -N \
  "${NAGARE_SSH_USER}@127.0.0.1" >/dev/null 2>&1 &
FWD_PID=$!
disown "${FWD_PID}" 2>/dev/null || true

# Wait for the forward to start listening (up to 20s).
deadline=$(( $(date +%s) + 20 ))
until (echo >"/dev/tcp/127.0.0.1/${LOCAL_API_PORT}") 2>/dev/null; do
  if [ "$(date +%s)" -ge "${deadline}" ] || ! kill -0 "${FWD_PID}" 2>/dev/null; then
    echo "live-test: the k3s API forward did not come up; killing tunnel ${TUN_PID}" >&2
    kill "${FWD_PID}" "${TUN_PID}" 2>/dev/null || true
    exit 1
  fi
  sleep 0.5
done

# 4) Rewrite the kubeconfig server: to the forwarded local port. The k3s serving
#    cert SANs include 127.0.0.1, so TLS still validates. Portable (no GNU sed -i).
tmp="$(mktemp)"
sed "s#https://127.0.0.1:6443#https://127.0.0.1:${LOCAL_API_PORT}#" "${KCFG}" > "${tmp}"
mv "${tmp}" "${KCFG}"

# 5) Print the KUBECONFIG and the management hints on stdout.
echo "KUBECONFIG=${KCFG}"
echo "# k3s API forwarded to https://127.0.0.1:${LOCAL_API_PORT} (ssh -L pid ${FWD_PID}, IAP tunnel pid ${TUN_PID})"
echo "# run:       export KUBECONFIG=${KCFG} && kubectl get nodes"
echo "# when done: kill ${FWD_PID} ${TUN_PID}"
