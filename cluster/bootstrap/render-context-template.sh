#!/usr/bin/env bash
# Render cluster bootstrap templates from the active target context.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: cluster/bootstrap/render-context-template.sh <template>" >&2
  exit 2
fi

template="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Capture the caller's explicit registry override BEFORE sourcing the resolver:
# scripts/lib/target.sh exports NAGARE_REGISTRY_PREFIX unconditionally, and
# cluster/bootstrap/local-auth/install.sh passes it per invocation.
caller_registry_prefix="${NAGARE_REGISTRY_PREFIX:-}"

# shellcheck source=scripts/lib/target.sh
source "${repo_root}/scripts/lib/target.sh"
# shellcheck source=scripts/lib/release.sh
source "${repo_root}/scripts/lib/release.sh"

sed_escape() {
  sed -e 's/[&|]/\\&/g'
}

esc() {
  printf '%s' "$1" | sed_escape
}

project="${CLOUDSDK_CORE_PROJECT}"
registry_prefix="${caller_registry_prefix:-${NAGARE_REGISTRY_PREFIX}}"

if [ -n "${NAGARE_AUTH_TAG:-}" ]; then
  auth_tag="${NAGARE_AUTH_TAG}"
else
  auth_tag=""
  if grep -q '\${NAGARE_AUTH_TAG}' "${template}"; then
    auth_tag="$(nagare_release_source_tag "${repo_root}")"
  fi
fi

# EP-112. Resolve only what the template actually asks for — the same discipline
# the NAGARE_AUTH_TAG block above uses. Eight of the nine bootstrap templates
# mention neither the project nor ACME, and four of those are rendered on a
# laptop by cluster/bootstrap/local-auth/install.sh where no ACME contact exists
# or should.
if grep -q '\${CLOUDSDK_CORE_PROJECT}' "${template}"; then
  # This template writes a project id into a live cluster object, so it must be
  # rendered under the same fail-closed confinement every cloud-touching script
  # uses. In local mode the guardrail asserts the target is genuinely loopback.
  _require_target_project || exit 1
fi

acme_email=""
acme_directory_url=""
if grep -q '\${NAGARE_ACME_EMAIL}\|\${NAGARE_ACME_DIRECTORY_URL}' "${template}"; then
  acme_email="${NAGARE_ACME_EMAIL:-}"
  if [ -z "${acme_email}" ]; then
    echo "nagare: no ACME contact is configured for context '${NAGARE_CONTEXT:-default}'." >&2
    echo "  Set NAGARE_ACME_EMAIL in the active context:" >&2
    echo "    nagarectl init <name> --acme-email you@example.com" >&2
    echo "    nagarectl context create <name> --acme-email you@example.com" >&2
    echo "  Refusing to render ${template}: a Let's Encrypt account registered under" >&2
    echo "  the wrong address cannot be re-pointed without deleting its account key." >&2
    exit 1
  fi
  if ! nagare_acme_email_valid "${acme_email}"; then
    echo "nagare: NAGARE_ACME_EMAIL='${acme_email}' is not a usable ACME contact address (expected one address of the form you@example.com)." >&2
    exit 1
  fi
  acme_directory_url="${NAGARE_ACME_DIRECTORY_URL:-}"
  if [ -z "${acme_directory_url}" ]; then
    echo "nagare: NAGARE_ACME_DIRECTORY='${NAGARE_ACME_DIRECTORY:-}' is not recognized (expected 'production', 'staging', or an absolute https:// ACME directory URL)." >&2
    exit 1
  fi
fi

# The nagare-access session cookie is scoped to the parent of every protected
# host, so one sign-in covers all protected apps under the context's base domain.
cookie_domain=""
if grep -q '\${NAGARE_ACCESS_COOKIE_DOMAIN}' "${template}"; then
  base_domain="${NAGARE_BASE_DOMAIN:-}"
  if ! printf '%s' "${base_domain}" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then
    echo "nagare: NAGARE_BASE_DOMAIN='${base_domain}' is not a usable cookie parent domain for context '${NAGARE_CONTEXT:-default}' (expected a bare DNS name such as apps.example.com)." >&2
    exit 1
  fi
  cookie_domain=".${base_domain}"
fi

sed \
  -e 's|${CLOUDSDK_CORE_PROJECT}|'"$(esc "${project}")"'|g' \
  -e 's|${NAGARE_ACCESS_COOKIE_DOMAIN}|'"$(esc "${cookie_domain}")"'|g' \
  -e 's|${NAGARE_ACME_EMAIL}|'"$(esc "${acme_email}")"'|g' \
  -e 's|${NAGARE_ACME_DIRECTORY_URL}|'"$(esc "${acme_directory_url}")"'|g' \
  -e 's|${NAGARE_REGISTRY_PREFIX}|'"$(esc "${registry_prefix}")"'|g' \
  -e 's|${NAGARE_AUTH_TAG}|'"$(esc "${auth_tag}")"'|g' \
  "${template}"
