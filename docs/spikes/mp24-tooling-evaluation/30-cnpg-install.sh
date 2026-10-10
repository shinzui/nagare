#!/usr/bin/env bash
# Install cert-manager (required by the barman-cloud plugin's TLS), the
# CloudNativePG operator and the barman-cloud plugin, from release manifests
# downloaded into $EVAL_DL. Records idle footprint after install.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
dl="${EVAL_DL:?set EVAL_DL to the directory holding the downloaded manifests}"
out="$EVAL_STATE/cnpg"
mkdir -p "$out"

# Upstream URLs, for the record:
#   https://github.com/cert-manager/cert-manager/releases/download/v$CERT_MANAGER_VERSION/cert-manager.yaml
#   https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$CNPG_VERSION/cnpg-$CNPG_VERSION.yaml
#   https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v$BARMAN_PLUGIN_VERSION/manifest.yaml
k apply -f "$dl/cert-manager-$CERT_MANAGER_VERSION.yaml"
k -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
k apply --server-side -f "$dl/cnpg-$CNPG_VERSION.yaml"
k -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s
k apply -f "$dl/barman-cloud-$BARMAN_PLUGIN_VERSION.yaml"
k -n cnpg-system rollout status deploy/barman-cloud --timeout=300s
sleep 60
k top pod -n cnpg-system --no-headers | tee "$out/idle-cnpg-system.top"
k top pod -n cert-manager --no-headers | tee "$out/idle-cert-manager.top"
