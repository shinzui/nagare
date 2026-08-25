#!/usr/bin/env bash
# Apply the active context's generated NixOS configuration to its running host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"
# shellcheck source=lib/host.sh
source "${SCRIPT_DIR}/lib/host.sh"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

_nagare_resolve_host_flake

HOST_ATTR="${NAGARE_HOST_ATTR:-${NAGARE_INSTANCE_NAME}}"
TARGET_HOST="${NAGARE_SSH_USER:-deploy}@${NAGARE_INSTANCE_NAME}"
COMMAND=(nixos-rebuild switch --flake "${NAGARE_HOST_FLAKE}#${HOST_ATTR}" --target-host "${TARGET_HOST}" --sudo)

if [ "${DRY_RUN}" -eq 1 ]; then
  printf 'context: %s\n' "${NAGARE_CONTEXT}"
  printf 'host flake: %s\n' "${NAGARE_HOST_FLAKE}"
  printf 'target host: %s\n' "${TARGET_HOST}"
  printf 'command:'
  printf ' %q' "${COMMAND[@]}"
  printf '\n'
  exit 0
fi

exec "${COMMAND[@]}"
