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
# TARGET_ZONE for scripts. It also derives the per-context Pulumi backend/home
# and stack name. In cloud mode `_require_target_project` (EP-97) refuses to
# proceed unless the effective project equals the project the active context
# DECLARES — or, when no context declares one, unless gcloud's configured
# project agrees. In local mode it asserts the target is provably loopback.

# Resolve the physical payload from THIS file's path, independent of the caller's
# cwd. An operator launcher may point at a writable, materialized workspace; the
# repository-root name remains as a compatibility alias for existing recipes.
_target_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_nagare_physical_root="$(cd "${_target_lib_dir}/../.." && pwd)"
NAGARE_PLATFORM_ROOT="${NAGARE_PLATFORM_ROOT:-${_nagare_physical_root}}"
NAGARE_REPO_ROOT="${NAGARE_WORKSPACE_ROOT:-${NAGARE_PLATFORM_ROOT}}"

if [ ! -f "${NAGARE_REPO_ROOT}/release.json" ] || [ ! -f "${NAGARE_REPO_ROOT}/justfile" ]; then
  echo "nagare: invalid operational root '${NAGARE_REPO_ROOT}' (missing release.json or justfile)" >&2
  return 1 2>/dev/null || exit 1
fi

export NAGARE_PLATFORM_ROOT NAGARE_REPO_ROOT

_NAGARE_CONTEXT_VARS=(
  CLOUDSDK_CORE_PROJECT CLOUDSDK_COMPUTE_REGION CLOUDSDK_COMPUTE_ZONE
  NAGARE_REGISTRY_HOST NAGARE_ARTIFACT_REGISTRY_ID
  NAGARE_IMAGE_BUCKET NAGARE_BACKUP_BUCKET NAGARE_BASE_DOMAIN
  NAGARE_INSTANCE_NAME NAGARE_TARGET_PLATFORM NAGARE_SSH_USER
  NAGARE_MODE NAGARE_LOCAL_OBJECT_STORE
  NAGARE_PULUMI_BACKEND NAGARE_PULUMI_BACKEND_URL
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

_nagare_state_dir() {
  if [ -n "${XDG_STATE_HOME:-}" ]; then
    printf '%s\n' "${XDG_STATE_HOME}/nagare"
  elif [ -n "${HOME:-}" ]; then
    printf '%s\n' "${HOME}/.local/state/nagare"
  else
    printf '%s\n' ".local/state/nagare"
  fi
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
    # An EMPTY pointer file means "no context selected" and falls through to the
    # in-repo profile / defaults. A NON-EMPTY but malformed name means the
    # operator's selection would be silently ignored — fail closed instead.
    if [ -n "${ptr}" ]; then
      if ! _nagare_context_name_valid "${ptr}"; then
        echo "nagare: current-context pointer '${ptr}' is not a valid context name (from ${ptrfile})" >&2
        return 1
      fi
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

  # Clear the slate so that after sourcing, a set variable can ONLY have come
  # from the context/profile files. The snapshot restore below reinstates every
  # ambient value, so the final per-field precedence (env > context > default)
  # is unchanged.
  for v in "${_NAGARE_CONTEXT_VARS[@]}"; do
    unset "${v}"
  done

  _nagare_source_if_present "${file}"
  _nagare_source_if_present "${overlay}"

  # The project the active context/profile DECLARES (empty when no file declares
  # one). Captured before the env snapshot is re-applied, so an ambient
  # CLOUDSDK_CORE_PROJECT cannot masquerade as the context's project.
  # _require_target_project asserts against this. Not exported: it is
  # recomputed on every source of this file, and consumers always source it.
  _NAGARE_CTX_PROJECT="${CLOUDSDK_CORE_PROJECT:-}"

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

  # EP-93: Pulumi backend selection. Default to EP-90's per-context local file
  # backend; `gcs` opts a cloud context into a remote GCS backend. A local-mode
  # context can never use GCS (the guardrail steps aside in local mode, so there
  # is no project to protect and no credentials to assume) — downgrade to local
  # and warn, mirroring the Haskell resolver's effectivePulumiBackend.
  export NAGARE_PULUMI_BACKEND="${NAGARE_PULUMI_BACKEND:-local}"
  export NAGARE_PULUMI_BACKEND_URL="${NAGARE_PULUMI_BACKEND_URL:-}"
  if [ "${NAGARE_MODE}" = "local" ] && [ "${NAGARE_PULUMI_BACKEND}" = "gcs" ]; then
    echo "nagare: local context '${name}' cannot use NAGARE_PULUMI_BACKEND=gcs; using local file state." >&2
    export NAGARE_PULUMI_BACKEND="local"
  fi

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

_nagare_select_pulumi_stack() {
  local pd="${NAGARE_REPO_ROOT}/infra/pulumi"
  local stack="${NAGARE_PULUMI_STACK:-${NAGARE_CONTEXT:-default}}"
  command -v pulumi >/dev/null 2>&1 || return 0
  pulumi -C "${pd}" stack select "${stack}" >/dev/null 2>&1 \
    || pulumi -C "${pd}" stack init "${stack}" >/dev/null 2>&1 \
    || true
}

_nagare_export_pulumi_env() {
  local ctx="${NAGARE_CONTEXT:-default}"
  local root="$(_nagare_state_dir)/${ctx}"
  local backend="${NAGARE_PULUMI_BACKEND:-local}"
  # PULUMI_HOME is ALWAYS the per-context local home (Pulumi keeps its workspace
  # and credentials cache there even for a remote backend); only the backend URL
  # differs between local and gcs.
  mkdir -p "${root}/home"
  # Create the passphrase file only when absent: this function runs on EVERY
  # source of target.sh, and an unconditional truncation would destroy a real
  # passphrase an operator had written here (losing access to stack secrets).
  [ -f "${root}/home/passphrase" ] || : > "${root}/home/passphrase"
  export PULUMI_HOME="${root}/home"
  export PULUMI_CONFIG_PASSPHRASE="${PULUMI_CONFIG_PASSPHRASE:-}"
  export PULUMI_CONFIG_PASSPHRASE_FILE="${root}/home/passphrase"
  export NAGARE_PULUMI_STACK="${ctx}"
  if [ "${backend}" = "gcs" ]; then
    local url="${NAGARE_PULUMI_BACKEND_URL:-}"
    if [ -z "${url}" ]; then
      url="gs://${CLOUDSDK_CORE_PROJECT}-nagare-pulumi-state/nagare/${ctx}"
    fi
    export NAGARE_PULUMI_BACKEND_URL="${url}"
    export PULUMI_BACKEND_URL="${url}"
    # Remote backend: do NOT eagerly `pulumi stack select` here. This function
    # runs on every shell source (every `direnv reload`); selecting against gs://
    # would require GCP credentials + a network round-trip each time. nagarectl
    # operations and `nagarectl context` (and the migration path) select/init the
    # stack against GCS when they actually need it.
  else
    mkdir -p "${root}/state"
    export PULUMI_BACKEND_URL="file://${root}/state"
    _nagare_select_pulumi_stack
  fi
}

_nagare_export_pulumi_env

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
    # Whitelist, not blacklist. sslip.io / nip.io resolve the LAST IP encoded in
    # their labels (dashed or dotted), so 34-120-1-1.sslip.io is a PUBLIC
    # address; accept those providers only when the encoded address starts with
    # 127. Also accept localhost and *.localhost (loopback per RFC 6761).
    local _d="${NAGARE_BASE_DOMAIN:-}"
    if ! { [ "${_d}" = "localhost" ] \
        || [[ "${_d}" =~ \.localhost$ ]] \
        || [[ "${_d}" =~ (^|[.-])127([.-][0-9]{1,3}){3}\.(sslip|nip)\.io$ ]]; }; then
      echo "refusing local run: active context is mode=local but NAGARE_BASE_DOMAIN='${_d:-<unset>}' is not provably loopback (allowed: localhost, *.localhost, 127.x.x.x-encoded sslip.io/nip.io)." >&2
      return 1
    fi
    local _r="${NAGARE_REGISTRY_HOST:-}"
    if ! { [[ "${_r}" =~ ^localhost(:[0-9]+)?$ ]] \
        || [[ "${_r}" =~ \.localhost(:[0-9]+)?$ ]] \
        || [[ "${_r}" =~ ^127(\.[0-9]{1,3}){3}(:[0-9]+)?$ ]]; }; then
      echo "refusing local run: active context is mode=local but NAGARE_REGISTRY_HOST='${_r:-<unset>}' is not a loopback registry (allowed: localhost[:port], *.localhost[:port], 127.x.x.x[:port])." >&2
      return 1
    fi
    return 0
  fi

  # Cloud context: fail closed on ANY disagreement about the target project.
  #
  # TARGET_PROJECT is derived from the FINAL CLOUDSDK_CORE_PROJECT, where an
  # ambient environment value wins over the context file (per-field precedence).
  # For the project field that precedence must never silently retarget a guarded
  # script, so:
  #   - when the active context/profile declares a project (_NAGARE_CTX_PROJECT
  #     is non-empty), the effective project must equal it;
  #   - when nothing declares one, the effective project came from ambient env
  #     or the built-in default, so cross-check gcloud's CONFIGURED project,
  #     read with CLOUDSDK_CORE_PROJECT stripped from the environment (gcloud
  #     lets that env var shadow its configuration, which would re-create the
  #     tautology this replaces).
  if [ -n "${_NAGARE_CTX_PROJECT:-}" ]; then
    if [ "${TARGET_PROJECT}" != "${_NAGARE_CTX_PROJECT}" ]; then
      echo "refusing to run: effective project '${TARGET_PROJECT}' does not match the active context's declared project '${_NAGARE_CTX_PROJECT}' (context: ${NAGARE_CONTEXT:-default})." >&2
      echo "fix: unset the ambient CLOUDSDK_CORE_PROJECT override, or select the context that declares '${TARGET_PROJECT}' (NAGARE_CONTEXT=<name> or 'nagarectl context use <name>')." >&2
      return 1
    fi
  else
    local configured
    configured="$(env -u CLOUDSDK_CORE_PROJECT gcloud config get-value project 2>/dev/null || true)"
    if [ -z "${configured}" ] || [ "${configured}" != "${TARGET_PROJECT}" ]; then
      echo "refusing to run: gcloud's configured project is '${configured:-<unset>}', expected '${TARGET_PROJECT}' (active context: ${NAGARE_CONTEXT:-default})." >&2
      echo "fix: select a context that declares the project ('nagarectl context use <name>')," >&2
      echo "     or run 'gcloud config set project ${TARGET_PROJECT}'." >&2
      return 1
    fi
  fi
}
