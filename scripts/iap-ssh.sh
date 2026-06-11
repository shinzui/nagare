#!/usr/bin/env bash
# IAP-tunneled SSH/SCP wrapper.
#
# Why this exists:
#   `gcloud compute ssh --tunnel-through-iap` is broken on macOS OpenSSH 10.x
#   (the same kex-handshake-eating bug recorded in EP-1, EP-2, and EP-5
#   Surprises). The documented workaround is to open the tunnel with
#   `gcloud compute start-iap-tunnel --local-host-port` and route OpenSSH
#   through `socat` as the ProxyCommand. This wrapper does that automatically
#   on each invocation, manages the tunnel's lifecycle via a trap, and exposes
#   the same surface as `ssh` and `scp` plus a thin `recv-file` helper that
#   streams a remote file through `cat` (so the SSH user does not need group
#   read on, e.g., postgres-owned files).
#
# Subcommands:
#   iap-ssh.sh ssh <instance> -- <command...>
#       Run a command on <instance> as ${SSH_USER}.
#   iap-ssh.sh scp <instance>:<remote> <local>
#   iap-ssh.sh scp <local> <instance>:<remote>
#       Copy files. Only one side may be remote.
#   iap-ssh.sh recv-file <instance> <remote-path> <local-path>
#       Stream a remote file through `sudo cat` and write it locally.
#       Use this when ${SSH_USER} cannot read the file directly
#       (e.g. /var/lib/postgresql/17/postgresql.conf).
#   iap-ssh.sh tunnel <instance> <remote-port> <local-port>
#       Open a long-lived TCP tunnel and print its PID; caller is responsible
#       for `kill <pid>` when done. Useful for talking to HTTP APIs on the VM.
#
# Required env:
#   ZONE          GCE zone of the instance (defaults to gcloud's active zone).
#   SSH_USER      Linux user to SSH as. Defaults to NAGARE_SSH_USER from the
#                 target profile, or 'deploy' (the dedicated NixOS operator user).
#                 The OS-Login-derived name never works here — the VM only accepts
#                 the 'deploy' user.
#   SSH_KEY       Private SSH key path. Defaults to the first of
#                 ~/.ssh/id_ed25519 or ~/.ssh/id_rsa that is readable.
#
# Project isolation: gcloud's active project must equal the configured target
# project (TARGET_PROJECT from the profile; see CLAUDE.md and EP-60).
set -euo pipefail

# Load the target profile and run the configurable, fail-closed project-isolation
# preflight (EP-60). Exports TARGET_PROJECT for the gcloud call sites below.
source "$(dirname "$0")/lib/target.sh"
_require_target_project

# The SSH login user (EP-6): an explicit SSH_USER wins, then NAGARE_SSH_USER from
# the target profile (exported by lib/target.sh), then the default 'deploy'. The
# OS-Login-derived name was removed because it never authenticates here.
SSH_USER="${SSH_USER:-${NAGARE_SSH_USER:-deploy}}"
ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || true)}"

if [ -z "${ZONE}" ]; then
  echo "iap-ssh: ZONE is not set and gcloud has no default zone" >&2
  exit 2
fi

# macOS bare-name SHELL kills ssh's ProxyCommand exec. macOS default $SHELL
# is "zsh" (no path), and OpenSSH 10.x on Darwin execs the ProxyCommand
# via the user's shell; that fails with "zsh: No such file or directory"
# the moment ssh tries to fork the ProxyCommand. Force /bin/sh so the
# exec resolves regardless of the operator's interactive-shell choice.
export SHELL=/bin/sh

# Identity selection. OS Login authenticates against keys uploaded via
# `gcloud compute os-login ssh-keys add`, not against per-VM ssh-keys
# metadata. We pass the operator's default keys as `-i` candidates so
# whichever one was registered with OS Login wins authentication. If the
# operator's OS Login key happens to live at ~/.ssh/google_compute_engine
# (e.g. carried over from prior `gcloud compute ssh` usage), set
# SSH_KEY=~/.ssh/google_compute_engine explicitly.
SSH_IDENTITIES=()
if [ -n "${SSH_KEY:-}" ]; then
  if [ ! -r "${SSH_KEY}" ]; then
    echo "iap-ssh: SSH_KEY '${SSH_KEY}' is not readable" >&2
    exit 2
  fi
  SSH_IDENTITIES+=("${SSH_KEY}")
else
  for cand in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa"; do
    [ -r "${cand}" ] && SSH_IDENTITIES+=("${cand}")
  done
fi
if [ ${#SSH_IDENTITIES[@]} -eq 0 ]; then
  echo "iap-ssh: no SSH identity found. Set SSH_KEY=<path> or generate one with" >&2
  echo "  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519" >&2
  exit 2
fi

# Open an IAP tunnel to <instance>:<remote-port> on a fresh ephemeral local
# port and echo "<local-port> <tunnel-pid>". Caller must `kill <pid>` and
# `wait <pid> 2>/dev/null || true` when finished.
start_tunnel() {
  local instance="$1" remote_port="$2"
  # Pick a random ephemeral port. /dev/urandom is portable enough; 30000–60000
  # is well above the usual privileged-binding range.
  local local_port
  local_port=$(( 30000 + (RANDOM % 30000) ))
  local logfile
  logfile="$(mktemp -t iap-tunnel.XXXXXX)"
  gcloud --project="${TARGET_PROJECT}" compute start-iap-tunnel "${instance}" "${remote_port}" \
    --zone="${ZONE}" --local-host-port="localhost:${local_port}" \
    --quiet >"${logfile}" 2>&1 &
  local pid=$!
  # Wait for the tunnel to start listening. 60 seconds covers cold-boot
  # IAP propagation on a freshly-created instance (EP-6 run #7 tripped the
  # previous 15s budget — see MasterPlan Surprises 2026-05-15 evening).
  local deadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < deadline )); do
    if (echo >/dev/tcp/127.0.0.1/${local_port}) 2>/dev/null; then
      printf '%s %s %s\n' "${local_port}" "${pid}" "${logfile}"
      return 0
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "iap-ssh: tunnel for ${instance}:${remote_port} exited prematurely:" >&2
      cat "${logfile}" >&2
      rm -f "${logfile}"
      return 1
    fi
    sleep 0.5
  done
  echo "iap-ssh: timed out waiting for tunnel to ${instance}:${remote_port}" >&2
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  cat "${logfile}" >&2 || true
  rm -f "${logfile}"
  return 1
}

# Resolve socat's absolute path once. ssh's ProxyCommand is exec'd by an
# inner shell whose PATH and SHELL handling are surprisingly inconsistent
# across macOS / linux / OpenSSH versions — e.g. on macOS OpenSSH 10.2p1
# the ProxyCommand runs under `zsh` (the user's $SHELL, unset to a bare
# "zsh") and a `socat` lookup against that shell's reset PATH fails with
# "zsh: No such file or directory". Pinning the absolute path sidesteps
# every flavour of that bug.
SOCAT_BIN="$(command -v socat || true)"
if [ -z "${SOCAT_BIN}" ]; then
  echo "iap-ssh: socat not found on PATH" >&2
  exit 2
fi

# Emit the ProxyCommand body. ssh already wraps it with "exec sh -c ..."
# so we do NOT prepend our own `exec` — doing so produces "exec exec
# /path/to/socat ..." and the shell tries to find a binary literally
# named "exec", which fails with "No such file or directory". The outer
# shell choice doesn't matter because socat is named by absolute path.
ssh_proxy_cmd() {
  printf '%s - TCP:localhost:%s\n' "${SOCAT_BIN}" "$2"
}

# Common ssh args. -o options match the nix-gcp-builder pattern: no host
# key checks (the tunnel is authenticated by IAP, the instance is short-lived)
# and a tight ServerAliveInterval so a dead tunnel surfaces fast.
ssh_common_args() {
  for ident in "${SSH_IDENTITIES[@]}"; do
    echo "-i"
    echo "${ident}"
  done
  # Only offer the explicit -i identities above, not every key in the agent.
  # Without this, a workstation whose ssh-agent holds several keys offers them
  # all and trips the host's MaxAuthTries before reaching the right one,
  # surfacing as a generic rc=255 that gets misread as a transient tunnel drop.
  echo "-o IdentitiesOnly=yes"
  echo "-o StrictHostKeyChecking=no"
  echo "-o UserKnownHostsFile=/dev/null"
  echo "-o GlobalKnownHostsFile=/dev/null"
  echo "-o LogLevel=ERROR"
  echo "-o ServerAliveInterval=15"
  echo "-o ServerAliveCountMax=3"
}

# Classify a failure as an IAP-transient transport error.
#
# Returns 0 iff the failure should be retried. Decision uses two signals:
#   * exit code 255 — canonical OpenSSH "transport-layer error" (kex failure,
#     ProxyCommand died, tunnel dropped). scp inherits this from ssh, and
#     bash's `command > file` propagates the underlying ssh exit code, so
#     this also catches the recv-file form.
#   * stderr substring match — for the rare flavors that surface with a
#     non-255 code (mostly mid-transfer scp drops where the file write
#     to disk returns a different code). The patterns enumerate every
#     transient flavor MasterPlan #3 EP-2 M1 observed across the three
#     bench loops (round 1 = 4003 IAP backend, round 3 = mid-collect socat
#     E read drop, round 3 retry = the same with no inline socat message).
_iap_is_transient() {
  local rc="$1" stderr_file="$2"
  if [ "${rc}" = "255" ]; then
    return 0
  fi
  if [ -s "${stderr_file}" ] && grep -qE \
       'Connection reset by peer|Connection timed out|kex_exchange_identification|broken pipe|socat\[[0-9]+\] [EW] read|failed to connect to backend|read from socket failed|Channel open failed|client_loop: send disconnect|ssh_exchange_identification' \
       "${stderr_file}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Run a function with IAP-transient retries. Each attempt is run as the
# given command; stderr is teed to a temp file so the classifier can
# inspect it. Caller's command should itself open the tunnel inside a
# subshell, so a torn-down tunnel from a failed attempt does not leak
# into the retry. Retries up to IAP_MAX_ATTEMPTS (default 3) with a 15s
# sleep between attempts. No bash RETURN trap (which would require set -T);
# stderr_file is cleaned up explicitly on every exit path.
with_iap_retry() {
  local max="${IAP_MAX_ATTEMPTS:-3}" attempt=1 rc=0 stderr_file
  stderr_file="$(mktemp -t iap-retry-stderr.XXXXXX)"
  while :; do
    rc=0
    # Process substitution tees stderr to the file AND the real stderr,
    # so the operator still sees the live failure messages while the
    # classifier inspects them.
    "$@" 2> >(tee -a "${stderr_file}" >&2) || rc=$?
    if [ "${rc}" = "0" ]; then
      rm -f "${stderr_file}"
      return 0
    fi
    if [ "${attempt}" -ge "${max}" ] || ! _iap_is_transient "${rc}" "${stderr_file}"; then
      rm -f "${stderr_file}"
      return "${rc}"
    fi
    printf '[iap-ssh] transient failure (rc=%s, attempt %d/%d); sleeping 15s before retry\n' \
      "${rc}" "${attempt}" "${max}" >&2
    sleep 15
    attempt=$(( attempt + 1 ))
    : > "${stderr_file}"
  done
}

# Internal: open a tunnel and run a single ssh command. Subshell so the
# EXIT trap reliably tears down the tunnel even on early exit.
_do_ssh() (
  set -e
  local instance="$1"; shift
  local info port pid logfile
  info="$(start_tunnel "${instance}" 22)"
  port="$(echo "${info}" | awk '{print $1}')"
  pid="$(echo "${info}" | awk '{print $2}')"
  logfile="$(echo "${info}" | awk '{print $3}')"
  # shellcheck disable=SC2064  # we want vars expanded now (subshell EXIT).
  trap "kill ${pid} 2>/dev/null || true; wait ${pid} 2>/dev/null || true; rm -f '${logfile}'" EXIT
  # shellcheck disable=SC2046
  ssh $(ssh_common_args) \
    -o ProxyCommand="$(ssh_proxy_cmd "${instance}" "${port}")" \
    "${SSH_USER}@localhost" "$@"
)

cmd_ssh() {
  if [ $# -lt 1 ]; then
    echo "usage: iap-ssh.sh ssh <instance> [-- <cmd...>]" >&2
    exit 2
  fi
  local instance="$1"; shift
  # Strip a leading -- if present.
  if [ $# -gt 0 ] && [ "$1" = "--" ]; then shift; fi
  with_iap_retry _do_ssh "${instance}" "$@"
}

# Internal: open a tunnel and run a single scp (either direction).
_do_scp() (
  set -e
  local mode="$1" instance="$2" remote_path="$3" local_path="$4"
  local info port pid logfile
  info="$(start_tunnel "${instance}" 22)"
  port="$(echo "${info}" | awk '{print $1}')"
  pid="$(echo "${info}" | awk '{print $2}')"
  logfile="$(echo "${info}" | awk '{print $3}')"
  # shellcheck disable=SC2064
  trap "kill ${pid} 2>/dev/null || true; wait ${pid} 2>/dev/null || true; rm -f '${logfile}'" EXIT
  if [ "${mode}" = recv ]; then
    # shellcheck disable=SC2046
    scp $(ssh_common_args) \
      -o ProxyCommand="$(ssh_proxy_cmd "${instance}" "${port}")" \
      "${SSH_USER}@localhost:${remote_path}" "${local_path}"
  else
    # shellcheck disable=SC2046
    scp $(ssh_common_args) \
      -o ProxyCommand="$(ssh_proxy_cmd "${instance}" "${port}")" \
      "${local_path}" "${SSH_USER}@localhost:${remote_path}"
  fi
)

cmd_scp() {
  if [ $# -ne 2 ]; then
    echo "usage: iap-ssh.sh scp <src> <dst>   (exactly one side must be <instance>:<path>)" >&2
    exit 2
  fi
  local src="$1" dst="$2"
  local instance="" remote_path="" local_path="" mode=""
  if [[ "${src}" == *:* ]] && [[ "${dst}" != *:* ]]; then
    instance="${src%%:*}"; remote_path="${src#*:}"; local_path="${dst}"; mode=recv
  elif [[ "${dst}" == *:* ]] && [[ "${src}" != *:* ]]; then
    instance="${dst%%:*}"; remote_path="${dst#*:}"; local_path="${src}"; mode=send
  else
    echo "iap-ssh.sh scp: exactly one side must be <instance>:<path>" >&2
    exit 2
  fi
  with_iap_retry _do_scp "${mode}" "${instance}" "${remote_path}" "${local_path}"
}

# Internal: open a tunnel and stream a remote file through `sudo cat`,
# writing the result to ${out_path}. The shell `>` lives INSIDE the
# subshell so each retry truncates ${out_path} fresh — a partial write
# from a failed attempt cannot bleed into the retry's output.
_do_recv_file_inner() (
  set -e
  local instance="$1" remote_path="$2" out_path="$3"
  local info port pid logfile
  info="$(start_tunnel "${instance}" 22)"
  port="$(echo "${info}" | awk '{print $1}')"
  pid="$(echo "${info}" | awk '{print $2}')"
  logfile="$(echo "${info}" | awk '{print $3}')"
  # shellcheck disable=SC2064
  trap "kill ${pid} 2>/dev/null || true; wait ${pid} 2>/dev/null || true; rm -f '${logfile}'" EXIT
  # shellcheck disable=SC2046
  ssh $(ssh_common_args) \
    -o ProxyCommand="$(ssh_proxy_cmd "${instance}" "${port}")" \
    "${SSH_USER}@localhost" "sudo cat ${remote_path}" > "${out_path}"
)

cmd_recv_file() {
  if [ $# -ne 3 ]; then
    echo "usage: iap-ssh.sh recv-file <instance> <remote-path> <local-path>" >&2
    exit 2
  fi
  local instance="$1" remote_path="$2" local_path="$3"
  # Stream into a temp file so a failed attempt doesn't poison the
  # caller's destination. On success the temp is atomic-renamed into
  # place; on failure the temp is removed.
  local tmp_path rc
  tmp_path="$(mktemp -t iap-recv.XXXXXX)"
  rc=0
  with_iap_retry _do_recv_file_inner "${instance}" "${remote_path}" "${tmp_path}" || rc=$?
  if [ "${rc}" = "0" ]; then
    mv "${tmp_path}" "${local_path}"
    return 0
  fi
  rm -f "${tmp_path}"
  return "${rc}"
}

cmd_tunnel() {
  if [ $# -ne 3 ]; then
    echo "usage: iap-ssh.sh tunnel <instance> <remote-port> <local-port>" >&2
    exit 2
  fi
  local instance="$1" remote_port="$2" want_local_port="$3"
  # Use the requested local port verbatim.
  local logfile
  logfile="$(mktemp -t iap-tunnel.XXXXXX)"
  gcloud --project="${TARGET_PROJECT}" compute start-iap-tunnel "${instance}" "${remote_port}" \
    --zone="${ZONE}" --local-host-port="localhost:${want_local_port}" \
    --quiet >"${logfile}" 2>&1 &
  local pid=$!
  local deadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < deadline )); do
    if (echo >/dev/tcp/127.0.0.1/"${want_local_port}") 2>/dev/null; then
      printf '%s\n' "${pid}"
      # Log path is useful for the caller to debug a hang.
      printf '# tunnel log: %s\n' "${logfile}" >&2
      return 0
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      cat "${logfile}" >&2
      rm -f "${logfile}"
      return 1
    fi
    sleep 0.5
  done
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  cat "${logfile}" >&2 || true
  rm -f "${logfile}"
  return 1
}

if [ $# -lt 1 ]; then
  echo "usage: $0 <ssh|scp|recv-file|tunnel> ..." >&2
  exit 2
fi
sub="$1"; shift
case "${sub}" in
  ssh)       cmd_ssh "$@" ;;
  scp)       cmd_scp "$@" ;;
  recv-file) cmd_recv_file "$@" ;;
  tunnel)    cmd_tunnel "$@" ;;
  *) echo "unknown subcommand: ${sub}" >&2; exit 2 ;;
esac
