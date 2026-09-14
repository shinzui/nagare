#!/usr/bin/env bash
# Opt-in staging-ACME acceptance. Setting the gate is explicit authorization to
# create and later delete the temporary public DomainMappings in the active
# context. Output contains certificate names/conditions, never Secret data.
set -euo pipefail

if [ "${NAGARE_RUN_CLOUD_MULTI_DOMAIN_TLS:-0}" != "1" ]; then
  echo "skipped: set NAGARE_RUN_CLOUD_MULTI_DOMAIN_TLS=1 to run the staging-ACME cloud smoke"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"
_require_target_project

NAGARECTL_BIN="${NAGARECTL_BIN:-$(command -v nagarectl || true)}"
if [ -z "${NAGARECTL_BIN}" ] || [ ! -x "${NAGARECTL_BIN}" ]; then
  echo "test-cloud-multi-domain-tls: nagarectl is not available" >&2
  exit 1
fi
nagarectl() { "${NAGARECTL_BIN}" "$@"; }

case "${NAGARE_ACME_DIRECTORY:-}" in
  staging) ;;
  *) echo "refusing cloud TLS smoke: active context must set NAGARE_ACME_DIRECTORY=staging" >&2; exit 1 ;;
esac

FIXTURE_DIR="${NAGARE_REPO_ROOT}/cluster/examples/multi-domain-tls"
NAMESPACE=personal
APP=multi-domain-tls
export NAGARE_MULTI_DOMAIN_CLOUD_PREFIX="nagare-tls-$(date -u +%Y%m%d%H%M%S)"
HOST_ONE="${NAGARE_MULTI_DOMAIN_CLOUD_PREFIX}.${NAGARE_BASE_DOMAIN}"
HOST_TWO="${NAGARE_MULTI_DOMAIN_CLOUD_PREFIX}-alternate.${NAGARE_BASE_DOMAIN}"

cleanup() {
  nagarectl app delete "${APP}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

deploy_output="$(cd "${FIXTURE_DIR}" && nagarectl deploy --file nagare/Config.hs)"
printf '%s\n' "${deploy_output}"
kubectl -n "${NAMESPACE}" get certificates.cert-manager.io \
  -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason'

for host in "${HOST_ONE}" "${HOST_TWO}"; do
  body="$(curl --fail --silent --show-error "https://${host}/")"
  printf '%s' "${body}" | grep -q 'multi-domain fixture'
  echo "ok: ${host} -> multi-domain fixture (staging ACME TLS)"
done
nagarectl domains check --all-namespaces
