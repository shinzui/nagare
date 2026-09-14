#!/usr/bin/env bash
# Deterministic local origin-TLS acceptance for EP-131. This is intentionally
# separate from the volume/database local smoke so routing failures stay small.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset NAGARE_RESOLVED_CONTEXT NAGARE_ACTIVE_CONTEXT NAGARE_ACTIVE_CONTEXT_FILE
export NAGARE_CONTEXT=local
export NAGARE_MODE=local
export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io
# shellcheck source=scripts/lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"

# Contributor checkouts can retain package environments for more than one GHC
# version. Select the file matching the dev shell instead of the lexically first
# (and potentially stale) one. Packaged workspaces already set this explicitly.
if [ -z "${NAGARE_GHC_ENVIRONMENT:-}" ] && command -v ghc >/dev/null 2>&1; then
  for candidate in "${NAGARE_REPO_ROOT}/cli/nagare-dsl"/.ghc.environment.*-"$(ghc --numeric-version)"; do
    if [ -f "${candidate}" ]; then
      export NAGARE_GHC_ENVIRONMENT="${candidate}"
      break
    fi
  done
fi

FIXTURE_DIR="${NAGARE_REPO_ROOT}/cluster/examples/multi-domain-tls"
NAMESPACE=personal
APP=multi-domain-tls
PORT=18443
CA_FILE="$(mktemp "${TMPDIR:-/tmp}/nagare-local-ca.XXXXXX.pem")"
PF_PID=""

cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" >/dev/null 2>&1 || true
  if kubectl config current-context 2>/dev/null | grep -q '^k3d-nagare-local$'; then
    nagarectl app delete "${APP}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
  fi
  rm -f -- "${CA_FILE}"
}
trap cleanup EXIT

NAGARECTL_BIN="${NAGARECTL_BIN:-$(command -v nagarectl || true)}"
if [ -z "${NAGARECTL_BIN}" ] || [ ! -x "${NAGARECTL_BIN}" ]; then
  echo "test-multi-domain-tls: nagarectl is not on PATH; enter the Nagare dev shell" >&2
  exit 1
fi
nagarectl() { "${NAGARECTL_BIN}" "$@"; }
if ! k3d cluster list nagare-local >/dev/null 2>&1; then
  echo "test-multi-domain-tls: nagare-local is down; run just local-up && just local-bootstrap" >&2
  exit 1
fi
export KUBECONFIG="$(k3d kubeconfig write nagare-local)"
kubectl -n cert-manager wait --for=condition=Ready certificate/nagare-local-ca --timeout=120s
kubectl get clusterissuer nagare-local-ca >/dev/null
kubectl -n cert-manager get secret nagare-local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d >"${CA_FILE}"

deploy_output="$(cd "${FIXTURE_DIR}" && nagarectl deploy --file nagare/Config.hs)"
printf '%s\n' "${deploy_output}"
canonical="$(printf '%s\n' "${deploy_output}" | sed -n 's/^Deployed: //p' | head -1)"
if [ "${canonical}" != "https://${NAGARE_BASE_DOMAIN}" ]; then
  echo "expected canonical URL https://${NAGARE_BASE_DOMAIN}, got ${canonical:-<none>}" >&2
  exit 1
fi

kubectl -n kourier-system port-forward svc/kourier "${PORT}:443" >/dev/null 2>&1 &
PF_PID=$!
for _attempt in $(seq 1 30); do
  if curl --silent --show-error --cacert "${CA_FILE}" \
      --resolve "${NAGARE_BASE_DOMAIN}:${PORT}:127.0.0.1" \
      "https://${NAGARE_BASE_DOMAIN}:${PORT}/" >/dev/null 2>&1; then
    break
  fi
  if [ "${_attempt}" = 30 ]; then
    echo "Kourier TLS port-forward did not become ready" >&2
    exit 1
  fi
  sleep 1
done

for host in "${NAGARE_BASE_DOMAIN}" "www.${NAGARE_BASE_DOMAIN}" "alternate.${NAGARE_BASE_DOMAIN}"; do
  body="$(curl --fail --silent --show-error --cacert "${CA_FILE}" \
    --resolve "${host}:${PORT}:127.0.0.1" "https://${host}:${PORT}/")"
  if ! printf '%s' "${body}" | grep -q 'multi-domain fixture'; then
    echo "${host}: unexpected application response" >&2
    exit 1
  fi
  echo "ok: ${host} -> multi-domain fixture (trusted TLS)"
done

nagarectl domains check --all-namespaces --base-domain "${NAGARE_BASE_DOMAIN}"
echo "ok: canonical URL is https://${NAGARE_BASE_DOMAIN}"
