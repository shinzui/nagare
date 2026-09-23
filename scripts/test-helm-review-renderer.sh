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
echo "Helm post-renderer accepted exact bytes and refused nondeterministic and malformed reviews."
