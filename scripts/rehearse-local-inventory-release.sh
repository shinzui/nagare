#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$repo_root/fixtures/inventory-release/local/health.json"
generic_runner="$repo_root/scripts/rehearse-managed-resources.sh"

usage() {
  cat <<'EOF'
Usage: scripts/rehearse-local-inventory-release.sh --phase plan|apply|verify \
  --context NAME --expected-cluster CLUSTER --evidence-dir DIRECTORY \
  [--candidate COMPILED_DIRECTORY] [--private-store-export DIRECTORY] [--yes]

Check the exact local k3d target before entering the shared saved-review protocol.
Plan and verify require a compiled candidate; apply requires the saved review and --yes.
EOF
}

die() { printf 'local inventory release: %s\n' "$*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

phase=""
context=""
cluster=""
evidence_dir=""
candidate=""
private_store_export=""
yes=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase|--context|--expected-cluster|--evidence-dir|--candidate|--private-store-export)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      case "$1" in
        --phase) phase="$2" ;;
        --context) context="$2" ;;
        --expected-cluster) cluster="$2" ;;
        --evidence-dir) evidence_dir="$2" ;;
        --candidate) candidate="$2" ;;
        --private-store-export) private_store_export="$2" ;;
      esac
      shift 2 ;;
    --yes) yes=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$phase" == plan || "$phase" == apply || "$phase" == verify ]] \
  || die "--phase must be plan, apply, or verify"
[[ -n "$context" && -n "$cluster" && -n "$evidence_dir" ]] \
  || die "context, expected cluster, and evidence directory are required"
if [[ "$phase" == apply ]]; then
  [[ -z "$candidate" && "$yes" == true && -z "$private_store_export" ]] \
    || die "apply requires --yes and no candidate or export"
elif [[ "$phase" == plan ]]; then
  [[ -d "$candidate" && "$yes" == false && -z "$private_store_export" ]] \
    || die "plan requires a compiled candidate and no --yes or export"
else
  [[ -d "$candidate" && "$yes" == false ]] \
    || die "verify requires a compiled candidate and no --yes"
fi
if [[ "$phase" == plan || "$phase" == verify ]]; then
  [[ -f "$candidate/candidate.json" && -f "$candidate/candidate.sha256" ]] \
    || die "candidate is not a compiled inventory directory"
fi
if [[ "$phase" == plan ]]; then
  [[ ! -e "$evidence_dir" ]] || die "evidence directory already exists"
else
  [[ -f "$evidence_dir/local-health.json" ]] \
    || die "saved local fixture health evidence is missing"
fi
for tool in jq kubectl docker; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
cli="${NAGARECTL_BIN:-nagarectl}"
command -v "$cli" >/dev/null 2>&1 || die "nagarectl is required"
jq -e '.schemaVersion == 1 and .mode == "local" and .clusterPrefix == "k3d-"
  and ([.knativeNamespace, .knativeWebhook, .objectStoreNamespace,
        .objectStoreDeployment, .objectStoreService, .objectStoreBucketJob]
    | all(type == "string" and test("^[a-z0-9-]+$")))
  and .registryUrl == "http://k3d-registry.localhost:5000/v2/"' "$fixture" >/dev/null \
  || die "checked-in health fixture has an unsupported contract"
[[ "$cluster" == k3d-* ]] || die "the local release fixture requires a k3d cluster"
knative_ns="$(jq -er .knativeNamespace "$fixture")"
knative_webhook="$(jq -er .knativeWebhook "$fixture")"
store_ns="$(jq -er .objectStoreNamespace "$fixture")"
store_deployment="$(jq -er .objectStoreDeployment "$fixture")"
store_service="$(jq -er .objectStoreService "$fixture")"
store_bucket_job="$(jq -er .objectStoreBucketJob "$fixture")"
registry_url="$(jq -er .registryUrl "$fixture")"

# Validate the Nagare profile before contacting a Kubernetes API. This also
# refuses a workstation context whose profile is cloud even if its name matches.
guard="$($cli --context "$context" context guard --json)" \
  || die "Nagare context guard failed for $context"
jq -e --arg context "$context" \
  '.confined == true and .mode == "local" and .context == $context' \
  <<<"$guard" >/dev/null || die "selected Nagare context is not local and confined"
kube_context="$(kubectl config current-context)" \
  || die "no selected Kubernetes context"
[[ "$kube_context" == "$cluster" ]] \
  || die "Kubernetes context $kube_context differs from expected local cluster $cluster"
selected_cluster="$(kubectl config view -o json | jq -er --arg context "$kube_context" \
  '[.contexts[] | select(.name == $context) | .context.cluster]
    | if length == 1 then .[0] else error("context has no unique cluster") end')" \
  || die "Kubernetes context $kube_context is missing or ambiguous"
[[ "$selected_cluster" == "$cluster" ]] \
  || die "Kubernetes context $kube_context selects $selected_cluster, expected $cluster"

kubectl --context "$kube_context" get --raw=/readyz >/dev/null \
  || die "Kubernetes API is not ready for $kube_context"

ready_deployment() {
  local namespace="$1" name="$2"
  kubectl --context "$kube_context" -n "$namespace" get deployment "$name" -o json \
    | jq -e '(.spec.replicas // 1) > 0
      and (.status.readyReplicas // 0) >= (.spec.replicas // 1)
      and (.status.observedGeneration // 0) >= .metadata.generation' >/dev/null \
    || die "$namespace deployment/$name is not ready"
}

ready_deployment "$knative_ns" "$knative_webhook"
kubectl --context "$kube_context" -n "$knative_ns" get endpoints "$knative_webhook" -o json \
  | jq -e '[.subsets[]?.addresses[]?] | length > 0' >/dev/null \
  || die "Knative webhook has no ready endpoint"
ready_deployment "$store_ns" "$store_deployment"
kubectl --context "$kube_context" -n "$store_ns" get endpoints "$store_service" -o json \
  | jq -e '[.subsets[]?.addresses[]?] | length > 0' >/dev/null \
  || die "MinIO has no ready endpoint"
kubectl --context "$kube_context" -n "$store_ns" get job "$store_bucket_job" -o json \
  | jq -e '(.status.succeeded // 0) > 0' >/dev/null \
  || die "MinIO bucket-creation Job has not succeeded"
kubectl --context "$kube_context" get --raw \
  "/api/v1/namespaces/${store_ns}/services/http:${store_service}:9000/proxy/minio/health/ready" >/dev/null \
  || die "MinIO readiness endpoint is unavailable"
[[ "$registry_url" == http://k3d-registry.localhost:5000/v2/ ]] \
  || die "local registry URL differs from the checked-in fixture"
docker exec k3d-registry.localhost wget -qO- http://localhost:5000/v2/ \
  | jq -e 'type == "object"' >/dev/null \
  || die "local image registry API is unavailable"

tmp_health="$(mktemp "${TMPDIR:-/tmp}/nagare-local-health.XXXXXX")"
trap 'rm -f -- "$tmp_health"' EXIT
jq -n -S --arg context "$context" --arg cluster "$cluster" \
  --arg revision "$($cli version --json | jq -er .revision)" \
  --arg fixtureDigest "$(sha256_file "$fixture")" \
  '{schemaVersion: 1, mode: "local", context: $context, cluster: $cluster,
    operatorRevision: $revision, fixtureDigest: $fixtureDigest,
    healthy: true, checks: ["kubernetes-api", "knative-webhook",
      "local-registry", "object-store", "object-store-bucket"]}' > "$tmp_health"

args=(--phase "$phase" --mode local --context "$context"
  --kube-context "$kube_context" --expected-cluster "$cluster" --evidence-dir "$evidence_dir")
if [[ "$phase" == apply ]]; then
  args+=(--yes)
else
  args+=(--candidate "$candidate")
fi
if [[ -n "$private_store_export" ]]; then
  args+=(--private-store-export "$private_store_export")
fi
if [[ "$phase" != plan ]]; then
  jq -e --arg context "$context" --arg cluster "$cluster" \
    --arg fixtureDigest "$(jq -er .fixtureDigest "$tmp_health")" \
    '.schemaVersion == 1 and .context == $context and .cluster == $cluster
      and .fixtureDigest == $fixtureDigest and .healthy == true' \
    "$evidence_dir/local-health.json" >/dev/null \
    || die "saved local fixture identity changed"
fi
"$generic_runner" "${args[@]}"
if [[ "$phase" == plan ]]; then
  cp "$tmp_health" "$evidence_dir/local-health.json"
fi
