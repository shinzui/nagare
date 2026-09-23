#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="${repo_root}/cli/nagarectl/test/fixtures/helm-review"
static_fixture="${repo_root}/cli/nagarectl/test/fixtures/helm-review-static"
plugin="${repo_root}/cluster/observability/helm-review"
work="$(mktemp -d "${TMPDIR:-/tmp}/nagare-helm-review-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/plugins"
ln -s "${plugin}" "${work}/plugins/nagare-reviewed-manifests"
ln -s "${plugin}/capture" "${work}/plugins/nagare-capture-manifests"
export HELM_PLUGINS="${work}/plugins"

NAGARE_HELM_CAPTURE_PATH="${work}/static-native.yaml" \
  helm template fixture "${static_fixture}" --post-renderer nagare-capture-manifests > "${work}/static-review.yaml"
static_digest="$(openssl dgst -sha256 -r "${work}/static-native.yaml")"
static_digest="${static_digest%% *}"
NAGARE_HELM_REVIEW_SHA256="${static_digest}" \
  helm template fixture "${static_fixture}" --post-renderer nagare-reviewed-manifests \
    > "${work}/static-applied.yaml"
grep -q 'inventory-review-static-fixture' "${work}/static-applied.yaml"
if NAGARE_HELM_CAPTURE_PATH="${work}/static-native.yaml" \
    helm template fixture "${static_fixture}" --post-renderer nagare-capture-manifests \
      > "${work}/unexpected.yaml" 2> "${work}/refusal.log"; then
  echo "nagare: Helm review capture overwrote an existing native member" >&2
  exit 1
fi

NAGARE_HELM_CAPTURE_PATH="${work}/random-native.yaml" \
  helm template fixture "${fixture}" --post-renderer nagare-capture-manifests > "${work}/review.yaml"
review_digest="$(openssl dgst -sha256 -r "${work}/random-native.yaml")"
review_digest="${review_digest%% *}"

if NAGARE_HELM_REVIEW_SHA256="${review_digest}" \
    helm template fixture "${fixture}" --post-renderer nagare-reviewed-manifests \
      > "${work}/unexpected.yaml" 2> "${work}/refusal.log"; then
  echo "nagare: random Helm chart unexpectedly matched a separately rendered review" >&2
  exit 1
fi

if NAGARE_HELM_REVIEW_SHA256=bad \
    helm template fixture "${fixture}" --post-renderer nagare-reviewed-manifests \
      > "${work}/unexpected.yaml" 2> "${work}/refusal.log"; then
  echo "nagare: malformed Helm review digest was accepted" >&2
  exit 1
fi

# The packaged release set must render reproducibly at the same boundary as
# helm upgrade. This also catches accidental changes to chart or values pins.
(cd "${repo_root}/cluster/observability/vendor" && shasum -a 256 -c SHA256SUMS)
while read -r release namespace chart values; do
  for pass in 1 2; do
    NAGARE_HELM_CAPTURE_PATH="${work}/${release}-${pass}.yaml" \
      helm template "${release}" "${repo_root}/cluster/observability/vendor/${chart}" \
        --namespace "${namespace}" \
        -f "${repo_root}/cluster/observability/${values}" \
        --skip-crds \
        --post-renderer nagare-capture-manifests > /dev/null
  done
  if ! cmp -s "${work}/${release}-1.yaml" "${work}/${release}-2.yaml"; then
    echo "nagare: packaged ${release} chart changed between reviewed renders" >&2
    exit 1
  fi
done <<'CHARTS'
vmks monitoring victoria-metrics-k8s-stack-0.81.0.tgz victoria-metrics/values.yaml
victoria-logs logging victoria-logs-single-0.13.5.tgz victoria-logs/values.yaml
victoria-logs-collector logging victoria-logs-collector-0.3.4.tgz victoria-logs/collector-values.yaml
victoria-traces tracing victoria-traces-single-0.1.6.tgz victoria-traces/values.yaml
otel-collector tracing opentelemetry-collector-0.158.0.tgz opentelemetry-collector/values.yaml
CHARTS
echo "Helm post-renderer accepted exact bytes and refused nondeterministic and malformed reviews."
