#!/usr/bin/env bash
# Render the inventory's pinned charts and check every generated workload,
# including Victoria operator CRs whose pods do not appear in Helm output.
# Requires helm, yq, and jq.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
observability="$root/cluster/observability"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render() {
  local release="$1" archive="$2" namespace="$3" values="$4"
  helm template "$release" "$observability/vendor/$archive" --namespace "$namespace" \
    -f "$observability/$values" > "$tmp/$release.yaml"
}

render vmks victoria-metrics-k8s-stack-0.81.0.tgz monitoring victoria-metrics/values.yaml
render victoria-logs victoria-logs-single-0.13.5.tgz logging victoria-logs/values.yaml
render victoria-logs-collector victoria-logs-collector-0.3.4.tgz logging victoria-logs/collector-values.yaml
render victoria-traces victoria-traces-single-0.1.6.tgz tracing victoria-traces/values.yaml
render otel-collector opentelemetry-collector-0.158.0.tgz tracing opentelemetry-collector/values.yaml

yq -o=json '.' "$tmp"/*.yaml | jq -s -e '
  def bounded:
    (.requests.cpu // "0" | tostring | test("[1-9]")) and
    (.requests.memory // "0" | tostring | test("[1-9]")) and
    (.limits.memory // "0" | tostring | test("[1-9]"));
  [.[] | select(.kind == "Deployment" or .kind == "DaemonSet" or
                .kind == "StatefulSet" or .kind == "Job") |
    . as $workload | .spec.template.spec |
    ((.containers // []) + (.initContainers // []))[] |
    {workload: $workload.metadata.name, container: .name, resources: .resources}] as $containers |
  [.[] | select(.kind == "VMSingle" or .kind == "VMAgent" or .kind == "VMAlert")] as $crs |
  [$containers[] | select(.resources | bounded | not)] as $unbounded |
  if ($containers | length) < 10 then error("missing rendered workload containers")
  elif ($unbounded | length) > 0 then error("unbounded containers: \($unbounded)")
  elif ($crs | length) != 3 then error("missing Victoria custom resources")
  elif any($crs[]; .spec.resources | bounded | not) then error("unbounded Victoria custom resource")
  else . end |
  # Helm cannot render operator-created reloaders. Verify the defaults which
  # the pinned operator advertises via /app --printDefaults; live pod checks
  # remain necessary after reconciliation.
  [.[] | select(.kind == "Deployment" and .metadata.name == "vmks-victoria-metrics-operator") |
    .spec.template.spec.containers[] | select(.name == "operator") | .env[] |
    select(.name | startswith("VM_CONFIG_RELOADER_"))] |
  from_entries |
  .VM_CONFIG_RELOADER_REQUEST_CPU == "10m" and
  .VM_CONFIG_RELOADER_REQUEST_MEMORY == "25Mi" and
  .VM_CONFIG_RELOADER_LIMIT_MEMORY == "128Mi"
' > /dev/null

# Both stores were OOM-killed during their first empty-store start with the
# upstream 60% cache default under a 512Mi cgroup. Preserve the hard limit while
# reserving most of it for runtime/startup allocations. Check the operator CR
# and the direct StatefulSet separately because they render through different
# charts.
yq -o=json '.' "$tmp/vmks.yaml" | jq -s -e '
  any(.[];
    .kind == "VMSingle" and
    .spec.extraArgs["memory.allowedPercent"] == "40")
' > /dev/null

yq -o=json '.' "$tmp/victoria-logs.yaml" | jq -s -e '
  any(.[];
    .kind == "StatefulSet" and
    any(.spec.template.spec.containers[]?.args[]?;
      . == "--memory.allowedPercent=40"))
' > /dev/null

echo 'All five pinned charts have bounded containers, reloader defaults, and 40% store cache budgets.'
