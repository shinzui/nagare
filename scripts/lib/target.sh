#!/usr/bin/env bash
# scripts/lib/target.sh (EP-60, EP-89) — the SINGLE source of the active nagare
# target context and the configurable, fail-closed isolation guardrail. SOURCE
# this file; do not run it:
#
#   source "$(dirname "$0")/lib/target.sh"
#   _require_target_project
#
# It resolves the active context from, in order: NAGARE_CONTEXT, the user-level
# current-context pointer, the in-repo nagare.target.env/nagare.local.env
# back-compat profile, then the historic tan-nb-exp defaults. It exports the
# CLOUDSDK_* / NAGARE_* contract plus TARGET_PROJECT / TARGET_REGION /
# TARGET_ZONE for scripts. `_require_target_project` refuses to proceed unless
# gcloud's active project equals the active context's project in cloud mode.

# Resolve the repository root from THIS file's path, independent of the caller's
# cwd. ${BASH_SOURCE[0]} is this file; its parent is scripts/lib, so ../.. is the
# repo root.
_target_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAGARE_REPO_ROOT="$(cd "${_target_lib_dir}/../.." && pwd)"

_NAGARE_CONTEXT_VARS=(
  CLOUDSDK_CORE_PROJECT CLOUDSDK_COMPUTE_REGION CLOUDSDK_COMPUTE_ZONE
  NAGARE_REGISTRY_HOST NAGARE_ARTIFACT_REGISTRY_ID
  NAGARE_IMAGE_BUCKET NAGARE_BACKUP_BUCKET NAGARE_BASE_DOMAIN
  NAGARE_INSTANCE_NAME NAGARE_TARGET_PLATFORM NAGARE_SSH_USER
  NAGARE_MODE NAGARE_LOCAL_OBJECT_STORE
)

_nagare_config_dir() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s\n' "${XDG_CONFIG_HOME}/nagare"
  elif [ -n "${HOME:-}" ]; then
    printf '%s\n' "${HOME}/.config/nagare"
  else
    printf '%s\n' ".config/nagare"
  fi
}

_nagare_context_name_valid() {
  local name="${1:-}"
  [ -n "${name}" ] || return 1
  [ "${name}" != "." ] && [ "${name}" != ".." ] || return 1
  case "${name}" in
    .*|*/*) return 1 ;;
  esac
  [[ "${name}" =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]]
}

_nagare_source_if_present() {
  local file="${1:-}"
  if [ -n "${file}" ] && [ -f "${file}" ]; then
    # shellcheck disable=SC1090
    . "${file}"
  fi
}

_nagare_resolve_context() {
  local cfg ctxdir ptrfile requested selkey name file overlay ptr
  cfg="$(_nagare_config_dir)"
  ctxdir="${cfg}/contexts"
  ptrfile="${cfg}/current-context"
  requested="${NAGARE_CONTEXT:-}"
  selkey=""
  name=""
  file=""
  overlay=""

  if [ -n "${requested}" ] && [ "${requested}" != "default" ]; then
    if ! _nagare_context_name_valid "${requested}"; then
      echo "nagare: invalid context name '${requested}'" >&2
      return 1
    fi
    if [ ! -f "${ctxdir}/${requested}.env" ]; then
      echo "nagare: context '${requested}' not found (expected ${ctxdir}/${requested}.env)" >&2
      return 1
    fi
    name="${requested}"
    file="${ctxdir}/${requested}.env"
    selkey="ctx:${requested}"
  fi

  if [ -z "${selkey}" ] && [ -f "${ptrfile}" ]; then
    ptr="$(tr -d '[:space:]' < "${ptrfile}")"
    if [ -n "${ptr}" ] && _nagare_context_name_valid "${ptr}"; then
      if [ ! -f "${ctxdir}/${ptr}.env" ]; then
        echo "nagare: current-context '${ptr}' not found (expected ${ctxdir}/${ptr}.env)" >&2
        return 1
      fi
      name="${ptr}"
      file="${ctxdir}/${ptr}.env"
      selkey="ctx:${ptr}"
    fi
  fi

  if [ -z "${selkey}" ]; then
    local target_env="${NAGARE_REPO_ROOT}/nagare.target.env"
    local local_env="${NAGARE_REPO_ROOT}/nagare.local.env"
    name="default"
    if [ -f "${target_env}" ] || [ -f "${local_env}" ]; then
      selkey=":inrepo:"
      [ -f "${target_env}" ] && file="${target_env}"
      if [ "${NAGARE_MODE:-}" = "local" ] || { [ -f "${local_env}" ] && grep -q '^export NAGARE_MODE=local' "${local_env}"; }; then
        overlay="${local_env}"
      fi
      [ -z "${file}" ] && file="${overlay}"
    else
      selkey=":default:"
    fi
  fi

  if [ -n "${NAGARE_RESOLVED_CONTEXT:-}" ] && [ "${NAGARE_RESOLVED_CONTEXT}" != "${selkey}" ]; then
    local v
    for v in "${_NAGARE_CONTEXT_VARS[@]}"; do
      unset "${v}"
    done
  fi

  local _snap=() v
  for v in "${_NAGARE_CONTEXT_VARS[@]}"; do
    [ -n "${!v+x}" ] && _snap+=("${v}=${!v}")
  done

  _nagare_source_if_present "${file}"
  _nagare_source_if_present "${overlay}"

  local kv
  for kv in "${_snap[@]+"${_snap[@]}"}"; do
    export "${kv?}"
  done

  export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
  export CLOUDSDK_COMPUTE_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
  export CLOUDSDK_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"
  export NAGARE_REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-${CLOUDSDK_COMPUTE_REGION}-docker.pkg.dev}"
  export NAGARE_ARTIFACT_REGISTRY_ID="${NAGARE_ARTIFACT_REGISTRY_ID:-nagare}"
  export NAGARE_IMAGE_BUCKET="${NAGARE_IMAGE_BUCKET:-${CLOUDSDK_CORE_PROJECT}-nagare-images}"
  export NAGARE_BACKUP_BUCKET="${NAGARE_BACKUP_BUCKET:-${CLOUDSDK_CORE_PROJECT}-nagare-backups}"
  export NAGARE_BASE_DOMAIN="${NAGARE_BASE_DOMAIN:-apps.example.com}"
  export NAGARE_INSTANCE_NAME="${NAGARE_INSTANCE_NAME:-nagare-01}"
  export NAGARE_TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"
  export NAGARE_MODE="${NAGARE_MODE:-cloud}"
  export NAGARE_LOCAL_OBJECT_STORE="${NAGARE_LOCAL_OBJECT_STORE:-}"
  export NAGARE_SSH_USER="${NAGARE_SSH_USER:-deploy}"

  if [ "${NAGARE_MODE}" = "local" ]; then
    export NAGARE_REGISTRY_PREFIX="${NAGARE_REGISTRY_HOST:-k3d-registry.localhost:5000}"
  else
    export NAGARE_REGISTRY_PREFIX="${NAGARE_REGISTRY_HOST}/${CLOUDSDK_CORE_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}"
  fi

  export NAGARE_RESOLVED_CONTEXT="${selkey}"
  export NAGARE_CONTEXT="${name}"
  export NAGARE_ACTIVE_CONTEXT="${name}"
  export NAGARE_ACTIVE_CONTEXT_FILE="${file}"
}

if ! _nagare_resolve_context; then
  return 1 2>/dev/null || exit 1
fi

TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
TARGET_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
TARGET_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"
TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"

# Fail-closed preflight over the active context. Call it once at the top of any
# script that talks to GCP, AFTER sourcing this file.
_require_target_project() {
  # Local context: there is no GCP project to protect, but assert the target is
  # genuinely loopback so a bad local context cannot point at cloud resources.
  if [ "${NAGARE_MODE:-}" = "local" ]; then
    case "${NAGARE_BASE_DOMAIN:-}" in
      *sslip.io|*nip.io|*127.0.0.1*|*127-0-0-1*) : ;;
      *)
        echo "refusing local run: active context is mode=local but NAGARE_BASE_DOMAIN='${NAGARE_BASE_DOMAIN:-<unset>}' is not a loopback wildcard." >&2
        return 1 ;;
    esac
    case "${NAGARE_REGISTRY_HOST:-}" in
      *.pkg.dev|*.pkg.dev:*)
        echo "refusing local run: active context is mode=local but NAGARE_REGISTRY_HOST='${NAGARE_REGISTRY_HOST}' is an Artifact Registry host." >&2
        return 1 ;;
    esac
    return 0
  fi

  # Cloud context: abort unless gcloud's effective project equals the active
  # context's project.
  local active
  active="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [ "${active}" != "${TARGET_PROJECT}" ]; then
    echo "refusing to run: gcloud active project is '${active:-<unset>}', expected '${TARGET_PROJECT}' (active context: ${NAGARE_CONTEXT:-default})." >&2
    echo "fix: select the right context (NAGARE_CONTEXT=<name> or 'nagarectl context use <name>')," >&2
    echo "     run 'direnv allow' in the repo root, or 'export CLOUDSDK_CORE_PROJECT=${TARGET_PROJECT}'." >&2
    return 1
  fi
}
