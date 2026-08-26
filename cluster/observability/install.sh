#!/usr/bin/env bash
# Idempotent installer for the Nagare observability stack (EP-5).
# Re-running updates each release in place (helm upgrade --install).
#
# Prerequisites:
#   - KUBECONFIG points at nagare-01 (see docs/plans/5-...md "Context and Orientation";
#     until Tailscale is joined, open an SSH local-forward to 127.0.0.1:6443 over the
#     port-22 IAP tunnel and use the unmodified kubeconfig).
#   - helm, kubectl, and sops on PATH (provided by `nix develop`).
#
# Chart versions are pinned. They move; refresh with `helm search repo vm/ --versions`
# and `helm search repo open-telemetry/ --versions`.
set -euo pipefail

VMKS_VERSION="0.81.0"            # vm/victoria-metrics-k8s-stack
VLOGS_VERSION="0.13.5"           # vm/victoria-logs-single
VLOGS_COLLECTOR_VERSION="0.3.4"  # vm/victoria-logs-collector
VTRACES_VERSION="0.1.6"          # vm/victoria-traces-single (BETA)
OTEL_VERSION="0.158.0"           # open-telemetry/opentelemetry-collector

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "${ROOT}/../.." && pwd)"
# shellcheck source=scripts/lib/target.sh
source "${PLATFORM_ROOT}/scripts/lib/target.sh"
# shellcheck source=scripts/lib/cluster-secrets.sh
source "${PLATFORM_ROOT}/scripts/lib/cluster-secrets.sh"

SECRETS_DIR="$(nagare_cluster_secrets_dir)"
GRAFANA_SECRET="$(nagare_require_cluster_secret "${SECRETS_DIR}" grafana-admin.yaml)"

# This sops build does not discover the conventional age identity file on its
# own. Honor an explicit setting, otherwise adopt the conventional XDG path
# when it exists; other sops identity mechanisms remain available when it does
# not.
if [ -z "${SOPS_AGE_KEY_FILE:-}" ]; then
  DEFAULT_SOPS_AGE_KEY_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  if [ -f "${DEFAULT_SOPS_AGE_KEY_FILE}" ]; then
    export SOPS_AGE_KEY_FILE="${DEFAULT_SOPS_AGE_KEY_FILE}"
  fi
fi

# Alertmanager remains optional until EP-101 M1 enables it. Once enabled in
# the values file, fail before Helm unless its context-owned encrypted config
# exists. This keeps released operation fail-closed without packaging secrets.
ALERTMANAGER_ENABLED="$({
  awk '
    $1 == "alertmanager:" { in_alertmanager = 1; next }
    in_alertmanager && /^[^[:space:]]/ { exit }
    in_alertmanager && $1 == "enabled:" { print $2; exit }
  ' "${ROOT}/victoria-metrics/values.yaml"
} || true)"
ALERTMANAGER_SECRET=""
if [ "${ALERTMANAGER_ENABLED}" = "true" ]; then
  ALERTMANAGER_SECRET="$(nagare_require_cluster_secret "${SECRETS_DIR}" alertmanager-config.yaml)"
elif [ -f "${SECRETS_DIR}/alertmanager-config.yaml" ]; then
  ALERTMANAGER_SECRET="${SECRETS_DIR}/alertmanager-config.yaml"
fi

# Resolve every required operator-owned input before contacting Helm or
# mutating the cluster. A missing packaged secret therefore fails closed.
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# --- M1: metrics + Grafana ---
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
sops -d "${GRAFANA_SECRET}" | kubectl apply -f -
if [ -n "${ALERTMANAGER_SECRET}" ]; then
  sops -d "${ALERTMANAGER_SECRET}" | kubectl apply -f -
fi

helm upgrade --install vmks vm/victoria-metrics-k8s-stack --version "$VMKS_VERSION" \
  --namespace monitoring --create-namespace \
  -f "$ROOT/victoria-metrics/values.yaml" --wait --timeout 10m

kubectl apply -f "$ROOT/brokers/vmservicescrape.yaml"
kubectl apply -f "$ROOT/cert-manager/vmservicescrape.yaml"
kubectl apply -f "$ROOT/vmrules/nagare-alerts.yaml"
kubectl -n monitoring create configmap grafana-dashboard-nagare-brokers \
  --from-file=nagare-brokers.json="$ROOT/grafana/dashboards/nagare-brokers.json" \
  --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 -o yaml | \
  kubectl apply -f -

for ds in victoria-logs victoria-traces; do
  kubectl -n monitoring create configmap "grafana-datasource-${ds}" \
    --from-file="${ds}.yaml=$ROOT/grafana/datasources/${ds}.yaml" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - grafana_datasource=1 -o yaml | \
    kubectl apply -f -
done

# --- M2: logs ---
helm upgrade --install victoria-logs vm/victoria-logs-single --version "$VLOGS_VERSION" \
  --namespace logging --create-namespace \
  -f "$ROOT/victoria-logs/values.yaml" --wait --timeout 5m

helm upgrade --install victoria-logs-collector vm/victoria-logs-collector --version "$VLOGS_COLLECTOR_VERSION" \
  --namespace logging \
  -f "$ROOT/victoria-logs/collector-values.yaml" --wait --timeout 5m

# --- M3: traces ---
helm upgrade --install victoria-traces vm/victoria-traces-single --version "$VTRACES_VERSION" \
  --namespace tracing --create-namespace \
  -f "$ROOT/victoria-traces/values.yaml" --wait --timeout 5m

helm upgrade --install otel-collector open-telemetry/opentelemetry-collector --version "$OTEL_VERSION" \
  --namespace tracing \
  -f "$ROOT/opentelemetry-collector/values.yaml" --wait --timeout 5m

echo
echo "Observability stack installed. Discover service names with:"
echo "  kubectl get svc -A | grep -E 'vmsingle|victoria|otel|grafana'"
