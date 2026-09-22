#!/usr/bin/env bash
# Apply the active context's generated NixOS configuration to its running host.
#
# The switch reverts itself unless a fresh SSH login proves access (ExecPlan 115, ADR 11):
# refuse the evaluation fixture, refuse a configuration that does not authorize the
# operator's key, build, copy, then arm an on-host rollback timer, activate without
# changing the boot default, verify with a brand-new connection, and only then commit.
#
# Exit codes: 0 committed (or already active), 2 usage, 3 would lock you out,
# 4 not committed (the host reverts by itself), other non-zero for earlier failures.
set -euo pipefail

if [ -n "${NAGARE_INVENTORY_TRANSACTION:-}" ] && [ "${NAGARE_INVENTORY_ADAPTER_CHILD:-}" != "host" ]; then
  echo "host-switch: refusing inventory re-entry without the host adapter child marker" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"
# shellcheck source=lib/host.sh
source "${SCRIPT_DIR}/lib/host.sh"

usage() { echo "usage: $0 [--dry-run] [--build-on-host]" >&2; exit 2; }

DRY_RUN=0
BUILD_ON_HOST=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --build-on-host) BUILD_ON_HOST=1 ;;
    *) usage ;;
  esac
done

_nagare_resolve_host_flake

GENERATED_HOST_NAME="$(nagarectl host name)"
HOST_ATTR="${NAGARE_HOST_ATTR:-${GENERATED_HOST_NAME}}"
SSH_USER="${NAGARE_SSH_USER:-deploy}"
SSH_HOST="${NAGARE_SSH_HOST:-${NAGARE_HOST_ATTR:-${GENERATED_HOST_NAME}}}"
TARGET_HOST="${SSH_USER}@${SSH_HOST}"
KEY_FILE="${NAGARE_SSH_PUBLIC_KEY_FILE:-${SSH_KEY:-${HOME}/.ssh/id_ed25519}.pub}"
CONFIRM_SECONDS="${NAGARE_SWITCH_CONFIRM_SECONDS:-600}"
CONFIG_REF="${NAGARE_HOST_FLAKE}#nixosConfigurations.${HOST_ATTR}.config"
SAFE_LIB="${NAGARE_REPO_ROOT}/nixos/lib"

if [ "${BUILD_ON_HOST}" -eq 1 ]; then BUILD_MODE="on-host"; else BUILD_MODE="local+copy"; fi

if [ "${DRY_RUN}" -eq 1 ]; then
  printf 'context: %s\n' "${NAGARE_CONTEXT}"
  printf 'host flake: %s\n' "${NAGARE_HOST_FLAKE}"
  printf 'GCE instance: %s\n' "${NAGARE_INSTANCE_NAME}"
  printf 'attribute: %s\n' "${HOST_ATTR}"
  printf 'target host: %s\n' "${TARGET_HOST}"
  printf 'operator key file: %s\n' "${KEY_FILE}"
  printf 'confirm seconds: %s\n' "${CONFIRM_SECONDS}"
  printf 'build mode: %s\n' "${BUILD_MODE}"
  exit 0
fi

# 1. Refuse the in-repo evaluation fixture (`or false` keeps older Nagare inputs evaluable).
fixture="$(nix eval --json "${CONFIG_REF}" --apply 'c: c.nagare.host.evaluationFixture or false')"
if [ "${fixture}" != "false" ]; then
  echo "host-switch: refusing: ${HOST_ATTR} is the in-repo evaluation fixture; use the context-owned host flake" >&2
  exit 3
fi

# 2. Refuse a lockout before building: the configuration must authorize the operator's key.
if [ ! -r "${KEY_FILE}" ]; then
  echo "host-switch: refusing: cannot read operator public key ${KEY_FILE} (set NAGARE_SSH_PUBLIC_KEY_FILE)" >&2
  exit 3
fi
operator_key="$(awk 'NF >= 2 { print $2; exit }' "${KEY_FILE}")"
authorized="$(nix eval --json "${CONFIG_REF}.users.users.${SSH_USER}.openssh.authorizedKeys.keys")"
if [ -z "${operator_key}" ] || ! printf '%s' "${authorized}" \
    | jq -e --arg k "${operator_key}" 'any(.[]; (split(" ") | map(select(. != "")) | .[1]) == $k)' >/dev/null; then
  echo "host-switch: refusing: the configuration does not authorize ${KEY_FILE} for ${SSH_USER}; applying it would lock you out" >&2
  exit 3
fi

# 3. Build (or consume the exact inventory-reviewed closure), and make the
# toplevel present in the host's store.
TOPLEVEL_REF="${CONFIG_REF}.system.build.toplevel"
if [ -n "${NAGARE_HOST_PREPARED_CLOSURE:-}" ]; then
  [ "${BUILD_ON_HOST}" -eq 0 ] || { echo "host-switch: --build-on-host cannot alter a reviewed closure" >&2; exit 2; }
  NEW="${NAGARE_HOST_PREPARED_CLOSURE}"
  CURRENT="$(ssh -o BatchMode=yes "${TARGET_HOST}" 'readlink -f /run/current-system' | tail -n 1)"
  [ -z "${NAGARE_HOST_EXPECTED_OLD_CLOSURE:-}" ] || [ "${CURRENT}" = "${NAGARE_HOST_EXPECTED_OLD_CLOSURE}" ] || {
    echo "host-switch: current closure ${CURRENT} differs from reviewed ${NAGARE_HOST_EXPECTED_OLD_CLOSURE}" >&2
    exit 4
  }
  nix copy --no-check-sigs --to "ssh-ng://${TARGET_HOST}" "${NEW}"
elif [ "${BUILD_ON_HOST}" -eq 1 ]; then
  NEW="$(nix build --no-link --print-out-paths --eval-store auto --store "ssh-ng://${TARGET_HOST}" "${TOPLEVEL_REF}")"
else
  NEW="$(nix build --no-link --print-out-paths "${TOPLEVEL_REF}")"
  # --no-check-sigs: paths built on a remote builder carry no signature, and nix copy
  # checks signatures on the client even when the host trusts the deploy user
  # (ExecPlan 114). The host already requires that user to be trusted to accept the copy.
  nix copy --no-check-sigs --to "ssh-ng://${TARGET_HOST}" "${NEW}"
fi
echo "host-switch: built ${NEW}"

# 4. Arm, activate, verify with a fresh login, commit.
# shellcheck source=../nixos/lib/nagare-safe-switch-client.sh
source "${SAFE_LIB}/nagare-safe-switch-client.sh"
rc=0
nagare_safe_switch "${TARGET_HOST}" "${NEW}" "${CONFIRM_SECONDS}" "${SAFE_LIB}/nagare-safe-activate.sh" || rc=$?
exit "${rc}"
