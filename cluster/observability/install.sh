#!/usr/bin/env bash
# Idempotent installer for the Nagare observability stack (EP-5).
# Re-running updates each release in place (helm upgrade --install).
#
# Prerequisites:
#   - KUBECONFIG points at nagare-01 (see docs/plans/5-...md "Context and Orientation";
#     until Tailscale is joined, open an SSH local-forward to 127.0.0.1:6443 over the
#     port-22 IAP tunnel and use the unmodified kubeconfig).
#   - helm and kubectl on PATH (provided by `nix develop`).
#
# Chart versions are pinned. They move; refresh with `helm search repo vm/ --versions`
# and `helm search repo open-telemetry/ --versions`.
set -euo pipefail

VMKS_VERSION="0.81.0"            # vm/victoria-metrics-k8s-stack
VLOGS_VERSION="0.13.5"           # vm/victoria-logs-single
VLOGS_COLLECTOR_VERSION="0.3.4"  # vm/victoria-logs-collector
VTRACES_VERSION="0.1.6"          # vm/victoria-traces-single (BETA)
OTEL_VERSION="0.158.0"           # open-telemetry/opentelemetry-collector

helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- M1: metrics + Grafana ---
helm upgrade --install vmks vm/victoria-metrics-k8s-stack --version "$VMKS_VERSION" \
  --namespace monitoring --create-namespace \
  -f "$ROOT/victoria-metrics/values.yaml" --wait --timeout 10m

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
