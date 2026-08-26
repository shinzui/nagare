#!/usr/bin/env bash
# Context-owned encrypted Kubernetes Secret resolution.
#
# Released Nagare payloads are immutable and must not carry an operator's
# credentials.  By default, cluster bootstrap secrets therefore live under:
#
#   ${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/
#
# NAGARE_CLUSTER_SECRETS_DIR is an explicit override. A source checkout keeps
# compatibility with its tracked cluster/secrets directory, but only when the
# context-owned directory does not exist. This file expects scripts/lib/target.sh
# to have been sourced first so _nagare_config_dir and NAGARE_CONTEXT exist.

nagare_cluster_secrets_dir() {
  local explicit="${NAGARE_CLUSTER_SECRETS_DIR:-}"
  local context_owned source_compat

  if [ -n "${explicit}" ]; then
    if [ ! -d "${explicit}" ]; then
      echo "nagare: NAGARE_CLUSTER_SECRETS_DIR is not a directory: ${explicit}" >&2
      return 1
    fi
    (cd "${explicit}" && pwd)
    return
  fi

  context_owned="$(_nagare_config_dir)/cluster-secrets/${NAGARE_CONTEXT:-default}"
  if [ -d "${context_owned}" ]; then
    (cd "${context_owned}" && pwd)
    return
  fi

  source_compat="${NAGARE_REPO_ROOT}/cluster/secrets"
  if [ -d "${source_compat}" ]; then
    (cd "${source_compat}" && pwd)
    return
  fi

  # Return the intended context-owned location even when it has not been
  # created, so callers can emit one precise recovery instruction.
  printf '%s\n' "${context_owned}"
}

nagare_require_cluster_secret() {
  local directory="$1" name="$2" path
  path="${directory}/${name}"
  if [ ! -f "${path}" ]; then
    echo "nagare: missing encrypted cluster secret: ${path}" >&2
    echo "nagare: create the context-owned directory or set NAGARE_CLUSTER_SECRETS_DIR" >&2
    return 1
  fi
  printf '%s\n' "${path}"
}
