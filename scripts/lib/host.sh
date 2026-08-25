#!/usr/bin/env bash
# Resolve the context-owned host flake. Callers may set NAGARE_HOST_FLAKE to an
# explicit compatibility or test flake; otherwise nagarectl derives the active
# context's XDG configuration path.

_nagare_resolve_host_flake() {
  local resolved="${NAGARE_HOST_FLAKE:-}"
  if [ -z "${resolved}" ]; then
    if ! command -v nagarectl >/dev/null 2>&1; then
      echo "nagare: nagarectl is required to resolve the active host flake; set NAGARE_HOST_FLAKE explicitly" >&2
      return 1
    fi
    resolved="$(nagarectl host path)" || return 1
  fi

  if [ ! -f "${resolved}/flake.nix" ] || [ ! -f "${resolved}/host.nix" ]; then
    echo "nagare: invalid host flake '${resolved}' (expected flake.nix and host.nix)" >&2
    return 1
  fi

  NAGARE_HOST_FLAKE="$(cd "${resolved}" && pwd)"
  export NAGARE_HOST_FLAKE
}
