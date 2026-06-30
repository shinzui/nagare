#!/usr/bin/env bash
# scripts/lib/target.sh (EP-60) — the SINGLE source of the GCP target and the
# configurable, fail-closed isolation guardrail. SOURCE this file; do not run it:
#
#   source "$(dirname "$0")/lib/target.sh"
#   _require_target_project
#
# It loads the git-ignored target profile `nagare.target.env` from the repo root
# (if present), then sets TARGET_PROJECT / TARGET_REGION / TARGET_ZONE, falling
# back to the historic tan-nb-exp / us-west1 / us-west1-a defaults so a checkout
# with no profile behaves exactly as before. `_require_target_project` refuses to
# proceed unless gcloud's active project equals TARGET_PROJECT — the same
# fail-closed guard every script used to inline, now configurable.

# Resolve the repository root from THIS file's path, independent of the caller's
# cwd. ${BASH_SOURCE[0]} is this file; its parent is scripts/lib, so ../.. is the
# repo root.
_target_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAGARE_REPO_ROOT="$(cd "${_target_lib_dir}/../.." && pwd)"

# Load the per-operator profile if it exists. Lines are `export NAME=value`.
# A value already exported in the environment is NOT overwritten by sourcing,
# because the example uses bare `export NAME=value`; if you want the environment
# to win unconditionally, do not set it in the profile. (.envrc applies the same
# precedence via ${VAR:-default}.)
if [ -f "${NAGARE_REPO_ROOT}/nagare.target.env" ]; then
  # shellcheck disable=SC1091
  . "${NAGARE_REPO_ROOT}/nagare.target.env"
fi

# Derive the guardrail's comparison values, with the historic defaults as the
# fallback so "do nothing" preserves today's behavior.
TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
TARGET_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
TARGET_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"
# Build platform for nagarectl image builds (EP-3); mirrored here for completeness.
TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"
# SSH login user for scripts/iap-ssh.sh (EP-6); env > profile > default 'deploy'.
NAGARE_SSH_USER="${NAGARE_SSH_USER:-deploy}"
export NAGARE_SSH_USER

# Fail-closed preflight: abort unless gcloud's active project equals the
# configured target. Returns/exits non-zero on mismatch. Call it once at the top
# of any script that talks to GCP, AFTER sourcing this file.
_require_target_project() {
  # Local mode (MasterPlan 16 / EP-82, IP-6): there is no GCP project to protect,
  # so the GCP guardrail steps aside — but assert the local target is genuinely
  # loopback, never real cloud resources, so a misconfigured profile cannot
  # silently bypass protection while pointing at GCP.
  if [ "${NAGARE_MODE:-}" = "local" ]; then
    case "${NAGARE_BASE_DOMAIN:-}" in
      *sslip.io|*nip.io|*127.0.0.1*|*127-0-0-1*) : ;;
      *)
        echo "refusing local run: NAGARE_MODE=local but NAGARE_BASE_DOMAIN='${NAGARE_BASE_DOMAIN:-<unset>}' is not a loopback wildcard." >&2
        return 1 ;;
    esac
    case "${NAGARE_REGISTRY_HOST:-}" in
      *.pkg.dev|*.pkg.dev:*)
        echo "refusing local run: NAGARE_MODE=local but NAGARE_REGISTRY_HOST='${NAGARE_REGISTRY_HOST}' is an Artifact Registry host." >&2
        return 1 ;;
    esac
    return 0
  fi

  # Cloud mode (unchanged, fail-closed): abort unless gcloud's active project
  # equals the configured target.
  local active
  active="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [ "${active}" != "${TARGET_PROJECT}" ]; then
    echo "refusing to run: gcloud active project is '${active:-<unset>}', expected '${TARGET_PROJECT}'." >&2
    echo "fix: run 'direnv allow' in the repo root, set CLOUDSDK_CORE_PROJECT in nagare.target.env," >&2
    echo "     or 'export CLOUDSDK_CORE_PROJECT=${TARGET_PROJECT}'." >&2
    return 1
  fi
}
