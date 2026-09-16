#!/usr/bin/env bash
# EP-100: guard the Grafana startup contract. Default mode is hermetic;
# --render also checks the pinned Helm chart (requires its repository/cache).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
values="$root/cluster/observability/victoria-metrics/values.yaml"
expected='victoriametrics-logs-datasource@0.31.0'

valid_pin() {
  [[ "$1" =~ ^[a-z0-9-]+@[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

plugins="$(yq -r '.grafana.plugins[]' "$values")"
valid_pin "$plugins"
test "$plugins" = "$expected"
# These must never be accepted as a pinned preinstall entry.
for invalid in 'victoriametrics-logs-datasource 0.31.0' 'victoriametrics-logs-datasource' '0.31.0'; do
  if valid_pin "$invalid"; then
    echo "accepted invalid Grafana plugin pin: $invalid" >&2
    exit 1
  fi
done
test "$(yq -r '.grafana.admin.existingSecret' "$values")" = grafana-admin
test "$(yq -r '.grafana.admin.userKey' "$values")" = admin-user
test "$(yq -r '.grafana.admin.passwordKey' "$values")" = admin-password
test "$(yq -r '.grafana.adminPassword' "$values")" = null

case "${1:-}" in
  '') ;;
  --render)
    version="$(sed -n 's/^VMKS_VERSION="\([^"]*\)".*/\1/p' "$root/cluster/observability/install.sh")"
    test -n "$version"
    rendered="$(helm template vmks vm/victoria-metrics-k8s-stack --version "$version" \
      --namespace monitoring -f "$values")"
    test "$(yq -Nr 'select(.kind == "ConfigMap" and .metadata.name == "vmks-grafana") | .data.plugins' <<< "$rendered")" = "$expected"
    test "$(yq -Nr 'select(.kind == "Deployment" and .metadata.name == "vmks-grafana") | .spec.template.spec.containers[] | select(.name == "grafana") | .env[] | select(.name == "GF_PLUGINS_PREINSTALL_SYNC") | .valueFrom.configMapKeyRef.key' <<< "$rendered")" = plugins
    test "$(yq -Nr 'select(.kind == "Deployment" and .metadata.name == "vmks-grafana") | .spec.template.spec.containers[] | select(.name == "grafana") | .env[] | select(.name == "GF_PLUGINS_PREINSTALL_SYNC") | .valueFrom.configMapKeyRef.name' <<< "$rendered")" = vmks-grafana
    ;;
  *) echo "usage: bash scripts/test-observability-grafana.sh [--render]" >&2; exit 2 ;;
esac

echo 'Grafana pinned preinstall and existing-Secret contract passed.'
