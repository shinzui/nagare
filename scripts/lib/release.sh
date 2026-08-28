#!/usr/bin/env bash
# Resolve the immutable source tag shared by release-owned image builders and
# manifest renderers. Source checkouts use Git; packaged workspaces use the
# revision injected into release.json by the Nix release build.

nagare_release_source_tag() {
  local root="${1:?nagare_release_source_tag requires a platform root}"
  local git_root=""
  local revision=""

  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "${root}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "${git_root}" ] && [ "$(cd "${root}" && pwd -P)" = "$(cd "${git_root}" && pwd -P)" ]; then
      revision="$(git -C "${root}" rev-parse --verify HEAD 2>/dev/null || true)"
    fi
  fi

  if [ -z "${revision}" ] && [ -f "${root}/release.json" ]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "nagare: jq is required to read packaged release provenance" >&2
      return 1
    fi
    revision="$(jq -er '.sourceRevision | select(type == "string" and length > 0)' \
      "${root}/release.json" 2>/dev/null || true)"
  fi

  if [ -z "${revision}" ]; then
    echo "nagare: no Git revision or packaged release sourceRevision is available" >&2
    return 1
  fi

  printf '%.12s\n' "${revision}"
}
