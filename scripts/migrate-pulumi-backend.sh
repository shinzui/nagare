#!/usr/bin/env bash
# Migrate a target context's Pulumi state between the EP-90 per-context local
# file backend and an EP-93 remote GCS backend, using Pulumi's supported
# `stack export` / `stack import` mechanism (never by copying backend files).
#
#   scripts/migrate-pulumi-backend.sh [--context NAME] [--url gs://…] [--member P]
#   scripts/migrate-pulumi-backend.sh --rollback [--context NAME]
#
# Forward (local -> gcs): export the local stack to a timestamped artifact,
# bootstrap the GCS state bucket, import the artifact into the GCS backend,
# verify the stack outputs match, and only then flip the context file to
# NAGARE_PULUMI_BACKEND=gcs. Rollback (gcs -> local): re-import the most recent
# pre-migration artifact into the local backend and flip the context back to
# local. Rollback never deletes the GCS bucket or its objects.
#
# Idempotent: a context already on the requested backend is a no-op. The local
# export artifact is always kept as a rollback source.
set -euo pipefail

MODE="forward"
CTX_ARG=""
TARGET_URL_ARG=""
MEMBER_ARG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --rollback) MODE="rollback"; shift ;;
    --context) CTX_ARG="${2:-}"; shift 2 ;;
    --url) TARGET_URL_ARG="${2:-}"; shift 2 ;;
    --member) MEMBER_ARG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Select the context to migrate BEFORE sourcing the resolver, so target.sh
# resolves the intended context (and its still-current backend) for us.
[ -n "${CTX_ARG}" ] && export NAGARE_CONTEXT="${CTX_ARG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"

PULUMI_DIR="${NAGARE_REPO_ROOT}/infra/pulumi"
CTX="${NAGARE_CONTEXT:-default}"
STACK="${CTX}"
STATE_ROOT="$(_nagare_state_dir)/${CTX}"
LOCAL_HOME="${STATE_ROOT}/home"
LOCAL_URL="file://${STATE_ROOT}/state"
MIGRATIONS_DIR="${STATE_ROOT}/pulumi-migrations"

log() { printf '[migrate-pulumi-backend] %s\n' "$*" >&2; }

# Migration only makes sense for a cloud context (local mode has no GCP project
# and no remote state). Fail closed otherwise.
if [ "${NAGARE_MODE:-cloud}" != "cloud" ]; then
  echo "refusing: context '${CTX}' is mode=${NAGARE_MODE}; only cloud contexts use a GCS Pulumi backend." >&2
  exit 1
fi

# The destination GCS backend URL (explicit flag/env wins, else the default).
gcs_url() {
  if [ -n "${TARGET_URL_ARG}" ]; then
    printf '%s\n' "${TARGET_URL_ARG}"
  elif [ -n "${NAGARE_PULUMI_BACKEND_URL:-}" ] && [ "${NAGARE_PULUMI_BACKEND_URL}" != "" ]; then
    printf '%s\n' "${NAGARE_PULUMI_BACKEND_URL}"
  else
    printf 'gs://%s-nagare-pulumi-state/nagare/%s\n' "${CLOUDSDK_CORE_PROJECT}" "${CTX}"
  fi
}

# Update one `export KEY=VALUE` line in the active context file, in place
# (replacing an existing line or appending). The file is the operator's
# source-of-truth context definition under ~/.config/nagare/contexts/<ctx>.env.
set_context_var() {
  local key="$1" value="$2" file="${NAGARE_ACTIVE_CONTEXT_FILE:-}"
  if [ -z "${file}" ] || [ ! -f "${file}" ]; then
    log "no context file to update (NAGARE_ACTIVE_CONTEXT_FILE unset); set ${key}=${value} manually."
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  if grep -q "^export ${key}=" "${file}"; then
    sed "s|^export ${key}=.*$|export ${key}=${value}|" "${file}" > "${tmp}"
  else
    cat "${file}" > "${tmp}"
    printf 'export %s=%s\n' "${key}" "${value}" >> "${tmp}"
  fi
  mv "${tmp}" "${file}"
}

pulumi_output() {
  # $1 backend url, $2 output name. Empty string if unavailable.
  PULUMI_HOME="${LOCAL_HOME}" PULUMI_BACKEND_URL="$1" PULUMI_CONFIG_PASSPHRASE="" \
    PULUMI_CONFIG_PASSPHRASE_FILE="${LOCAL_HOME}/passphrase" \
    pulumi -C "${PULUMI_DIR}" stack output "$2" --stack "${STACK}" 2>/dev/null || true
}

ensure_bucket() {
  # Idempotent GCS state-bucket bootstrap (mirrors Nagare.Ops.PulumiBackend).
  local url="$1" bucket
  bucket="${url#gs://}"; bucket="${bucket%%/*}"
  if [ -z "${bucket}" ]; then
    echo "cannot derive a bucket from backend URL '${url}'" >&2; return 1
  fi
  if ! gcloud storage buckets describe "gs://${bucket}" --format='value(name)' >/dev/null 2>&1; then
    log "creating state bucket gs://${bucket}"
    gcloud storage buckets create "gs://${bucket}" \
      --project="${CLOUDSDK_CORE_PROJECT}" \
      --location="${CLOUDSDK_COMPUTE_REGION}" \
      --uniform-bucket-level-access \
      --public-access-prevention
  fi
  gcloud storage buckets update "gs://${bucket}" \
    --versioning --uniform-bucket-level-access --public-access-prevention
  if [ -n "${MEMBER_ARG}" ]; then
    gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
      --member="${MEMBER_ARG}" --role=roles/storage.objectAdmin
  fi
}

latest_artifact() {
  ls -1t "${MIGRATIONS_DIR}"/pre-gcs-*.json 2>/dev/null | head -1
}

do_forward() {
  _require_target_project
  local url; url="$(gcs_url)"
  if [ "${NAGARE_PULUMI_BACKEND:-local}" = "gcs" ]; then
    log "context '${CTX}' is already on the gcs backend (${url}); nothing to do."
    return 0
  fi

  mkdir -p "${MIGRATIONS_DIR}"
  local stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local artifact="${MIGRATIONS_DIR}/pre-gcs-${stamp}.json"

  log "exporting local stack '${STACK}' -> ${artifact}"
  PULUMI_HOME="${LOCAL_HOME}" PULUMI_BACKEND_URL="${LOCAL_URL}" PULUMI_CONFIG_PASSPHRASE="" \
    PULUMI_CONFIG_PASSPHRASE_FILE="${LOCAL_HOME}/passphrase" \
    pulumi -C "${PULUMI_DIR}" stack export --show-secrets --stack "${STACK}" --file "${artifact}"

  local pre_domain pre_bucket
  pre_domain="$(pulumi_output "${LOCAL_URL}" baseDomain)"
  pre_bucket="$(pulumi_output "${LOCAL_URL}" backupBucket)"
  log "pre-migration outputs: baseDomain='${pre_domain}' backupBucket='${pre_bucket}'"

  ensure_bucket "${url}"

  log "importing into GCS backend ${url}"
  PULUMI_HOME="${LOCAL_HOME}" PULUMI_BACKEND_URL="${url}" PULUMI_CONFIG_PASSPHRASE="" \
    PULUMI_CONFIG_PASSPHRASE_FILE="${LOCAL_HOME}/passphrase" \
    pulumi -C "${PULUMI_DIR}" stack init "${STACK}" >/dev/null 2>&1 || true
  PULUMI_HOME="${LOCAL_HOME}" PULUMI_BACKEND_URL="${url}" PULUMI_CONFIG_PASSPHRASE="" \
    PULUMI_CONFIG_PASSPHRASE_FILE="${LOCAL_HOME}/passphrase" \
    pulumi -C "${PULUMI_DIR}" stack import --stack "${STACK}" --file "${artifact}"

  local post_domain post_bucket
  post_domain="$(pulumi_output "${url}" baseDomain)"
  post_bucket="$(pulumi_output "${url}" backupBucket)"
  log "post-migration outputs: baseDomain='${post_domain}' backupBucket='${post_bucket}'"

  if [ "${pre_domain}" != "${post_domain}" ] || [ "${pre_bucket}" != "${post_bucket}" ]; then
    echo "verification FAILED: stack outputs differ after import. Leaving context on 'local'." >&2
    echo "  local backend and the export artifact (${artifact}) are intact; inspect the GCS stack before retrying." >&2
    exit 1
  fi

  set_context_var NAGARE_PULUMI_BACKEND gcs
  set_context_var NAGARE_PULUMI_BACKEND_URL "${url}"
  log "migrated context '${CTX}' to GCS backend ${url}."
  log "rollback artifact: ${artifact}"
  log "the local backend under ${STATE_ROOT}/state is left intact as a rollback source; remove it only after a successful 'pulumi preview' on GCS."
}

do_rollback() {
  local artifact; artifact="$(latest_artifact)"
  if [ -z "${artifact}" ]; then
    echo "no pre-migration artifact under ${MIGRATIONS_DIR}; cannot roll back automatically." >&2
    exit 1
  fi
  log "rolling back: importing ${artifact} into the local backend ${LOCAL_URL}"
  mkdir -p "${STATE_ROOT}/state" "${LOCAL_HOME}"
  : > "${LOCAL_HOME}/passphrase"
  PULUMI_HOME="${LOCAL_HOME}" PULUMI_BACKEND_URL="${LOCAL_URL}" PULUMI_CONFIG_PASSPHRASE="" \
    PULUMI_CONFIG_PASSPHRASE_FILE="${LOCAL_HOME}/passphrase" \
    pulumi -C "${PULUMI_DIR}" stack init "${STACK}" >/dev/null 2>&1 || true
  PULUMI_HOME="${LOCAL_HOME}" PULUMI_BACKEND_URL="${LOCAL_URL}" PULUMI_CONFIG_PASSPHRASE="" \
    PULUMI_CONFIG_PASSPHRASE_FILE="${LOCAL_HOME}/passphrase" \
    pulumi -C "${PULUMI_DIR}" stack import --stack "${STACK}" --file "${artifact}"
  set_context_var NAGARE_PULUMI_BACKEND local
  set_context_var NAGARE_PULUMI_BACKEND_URL ""
  log "rolled context '${CTX}' back to the local file backend. The GCS bucket and its objects were left untouched."
}

case "${MODE}" in
  forward) do_forward ;;
  rollback) do_rollback ;;
esac
