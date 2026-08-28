#!/usr/bin/env bash
# Render cluster bootstrap templates from the active target context.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: cluster/bootstrap/render-context-template.sh <template>" >&2
  exit 2
fi

template="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/release.sh
source "${repo_root}/scripts/lib/release.sh"

sed_escape() {
  sed -e 's/[&|]/\\&/g'
}

esc() {
  printf '%s' "$1" | sed_escape
}

project="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
registry_host="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"
artifact_repo="${NAGARE_ARTIFACT_REGISTRY_ID:-nagare}"
acme_email="${NAGARE_ACME_EMAIL:-nadeem@gmail.com}"

if [ -n "${NAGARE_AUTH_TAG:-}" ]; then
  auth_tag="${NAGARE_AUTH_TAG}"
else
  auth_tag=""
  if grep -q '\${NAGARE_AUTH_TAG}' "${template}"; then
    auth_tag="$(nagare_release_source_tag "${repo_root}")"
  fi
fi

if [ -n "${NAGARE_REGISTRY_PREFIX:-}" ]; then
  registry_prefix="${NAGARE_REGISTRY_PREFIX}"
elif [ "${NAGARE_MODE:-cloud}" = "local" ]; then
  registry_prefix="${registry_host}"
else
  registry_prefix="${registry_host}/${project}/${artifact_repo}"
fi

sed \
  -e 's|${CLOUDSDK_CORE_PROJECT}|'"$(esc "${project}")"'|g' \
  -e 's|${NAGARE_ACME_EMAIL}|'"$(esc "${acme_email}")"'|g' \
  -e 's|${NAGARE_REGISTRY_PREFIX}|'"$(esc "${registry_prefix}")"'|g' \
  -e 's|${NAGARE_AUTH_TAG}|'"$(esc "${auth_tag}")"'|g' \
  "${template}"
