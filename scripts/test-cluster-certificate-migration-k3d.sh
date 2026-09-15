#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$repo_root/cluster/test/fixtures/certificate-migration-0.2.2"
cluster_name="${NAGARE_CERTIFICATE_MIGRATION_TEST_CLUSTER:-nagare-certificate-migration-$$}"
case "$cluster_name" in
  nagare-certificate-migration-*) ;;
  *)
    echo "refusing to manage unexpected cluster name: $cluster_name" >&2
    exit 2
    ;;
esac

test_root="$(mktemp -d)"
export KUBECONFIG="$test_root/kubeconfig"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_STATE_HOME="$test_root/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

cleanup() {
  k3d cluster delete "$cluster_name" >/dev/null 2>&1 || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT

(cd "$repo_root/cli/nagarectl" && cabal build exe:nagarectl)
nagarectl_bin="$(cd "$repo_root/cli/nagarectl" && cabal list-bin exe:nagarectl)"
platform_out="$(cd "$repo_root" && nix build .#nagare-platform --no-link --print-out-paths | tail -n 1)"
payload_root="$platform_out/share/nagare"
platform_version="$($nagarectl_bin version --json | jq -er '.version')"

k3d cluster create "$cluster_name" \
  --image rancher/k3s:v1.34.6-k3s1 \
  --wait \
  --timeout 5m \
  --kubeconfig-update-default=false \
  --kubeconfig-switch-context=false
k3d kubeconfig get "$cluster_name" >"$KUBECONFIG"
expected_context="k3d-$cluster_name"
actual_context="$(kubectl config current-context)"
if [ "$actual_context" != "$expected_context" ]; then
  echo "refusing migration test: kube context '$actual_context' is not '$expected_context'" >&2
  exit 2
fi

kubectl create namespace cert-manager
kubectl create namespace knative-serving
kubectl create namespace personal
kubectl create namespace observability
kubectl label namespace personal nagare.dev/app-namespace=true

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=5m
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=5m
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=5m
kubectl apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  selfSigned: {}
YAML

kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.22.0/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.22.0/serving-core.yaml
kubectl -n knative-serving rollout status deployment/controller --timeout=5m
kubectl -n knative-serving rollout status deployment/webhook --timeout=5m
kubectl apply -f https://storage.googleapis.com/knative-releases/net-certmanager/previous/v1.14.0/net-certmanager.yaml
kubectl -n knative-serving rollout status deployment/net-certmanager-webhook --timeout=5m
"$repo_root/scripts/install-net-certmanager-controller.sh" --k3d-cluster "$cluster_name"

kubectl -n knative-serving patch configmap config-certmanager \
  --type merge \
  --patch "$(cat "$repo_root/cluster/bootstrap/knative-serving/config-certmanager.yaml")"
kubectl -n knative-serving patch configmap config-domain \
  --type merge \
  --patch '{"data":{"apps.example.test":""}}'
kubectl -n knative-serving patch configmap config-network \
  --type merge \
  --patch "$(jq -c '{data:.data}' "$fixture/config-network.json")"

# Load the fixture's 0.2.2 selector and let Knative materialize live chains.
# The upgrade review therefore binds API-server UIDs and controller-produced
# Secret content rather than trusting the illustrative IDs in the JSON fixture.
wait_for_legacy_chain() {
  local namespace="$1"
  local attempt
  for attempt in $(seq 1 150); do
    if kubectl get certificates.networking.internal.knative.dev -n "$namespace" \
      -l networking.knative.dev/wildcardDomain -o json 2>/dev/null |
      jq -e '.items | length >= 1 and all(.[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for a legacy wildcard chain in $namespace" >&2
  kubectl get certificates.networking.internal.knative.dev,certificates.cert-manager.io -A -o yaml >&2 || true
  return 1
}

wait_for_legacy_chain personal
wait_for_legacy_chain kube-system
wait_for_legacy_chain observability
kubectl wait --for=condition=Ready certificates.networking.internal.knative.dev --all -A --timeout=5m
kubectl wait --for=condition=Ready certificates.cert-manager.io --all -A --timeout=5m

"$nagarectl_bin" context create migration \
  --mode local \
  --registry-host localhost:5000 \
  --base-domain apps.example.test \
  --local-object-store http://minio:9000/nagare-backups
"$nagarectl_bin" context use migration
context_file="$XDG_CONFIG_HOME/nagare/contexts/migration.env"
sed -i.bak '/NAGARE_PLATFORM_VERSION=/d' "$context_file"
rm -f -- "$context_file.bak"
printf '%s\n' 'export NAGARE_PLATFORM_VERSION=0.2.2' >>"$context_file"
host_root="$XDG_CONFIG_HOME/nagare/hosts/migration"
mkdir -p "$host_root"
printf '%s\n' \
  '{' \
  '  inputs.nagare.url = "path:/old/nagare/nixos";' \
  '  # Generated by nagarectl 0.2.2; migration fixture.' \
  '  # Nagare platform version: 0.2.2' \
  '}' >"$host_root/flake.nix"
printf '%s\n' '{ ... }:' '{' '  hostName = "migration-nagare";' '}' >"$host_root/host.nix"
printf '%s\n' 'fixture: ENC[AES256_GCM,data:test]' 'sops: {}' >"$host_root/secrets.yaml"

fake_bin="$test_root/fake-bin"
tool_log="$test_root/tools.log"
mkdir -p "$fake_bin"
: >"$tool_log"
export NAGARE_MIGRATION_TOOL_LOG="$tool_log"
export NAGARE_MIGRATION_CTL="$nagarectl_bin"
export NAGARE_REAL_KUBECTL="$(command -v kubectl)"

cat >"$fake_bin/pulumi" <<'SH'
#!/bin/sh
printf 'pulumi %s\n' "$*" >>"$NAGARE_MIGRATION_TOOL_LOG"
case " $* " in
  " version ") printf '%s\n' 'v3.255.0' ;;
  *" config --json "*) printf '%s\n' '{}' ;;
  *" preview --json --save-plan "*)
    previous=""
    for argument in "$@"; do
      if [ "$previous" = "--save-plan" ]; then
        printf '%s\n' '{"version":1,"resourcePlans":{}}' >"$argument"
        break
      fi
      previous="$argument"
    done
    printf '%s\n' '{"steps":[]}'
    ;;
esac
exit 0
SH
cat >"$fake_bin/npm" <<'SH'
#!/bin/sh
mkdir -p node_modules/@pulumi/pulumi
printf '%s\n' '{}' >node_modules/@pulumi/pulumi/package.json
SH
cat >"$fake_bin/nix" <<'SH'
#!/bin/sh
printf 'nix %s\n' "$*" >>"$NAGARE_MIGRATION_TOOL_LOG"
printf '%s\n' '"/tmp/nagare-certificate-migration-fixture.drv"'
SH
cat >"$fake_bin/bash" <<'SH'
#!/bin/sh
printf 'host-apply %s\n' "$*" >>"$NAGARE_MIGRATION_TOOL_LOG"
exit 0
SH
cat >"$fake_bin/just" <<'SH'
#!/bin/sh
printf 'certificate-policy %s\n' "$*" >>"$NAGARE_MIGRATION_TOOL_LOG"
"$NAGARE_MIGRATION_CTL" cluster certificate-policy
SH
cat >"$fake_bin/kubectl" <<'SH'
#!/bin/sh
printf 'kubectl %s\n' "$*" >>"$NAGARE_MIGRATION_TOOL_LOG"
exec "$NAGARE_REAL_KUBECTL" "$@"
SH
chmod +x "$fake_bin"/*
export PATH="$fake_bin:$PATH"

before_selector_version="$(kubectl get configmap config-network -n knative-serving -o json | jq -r '.metadata.resourceVersion')"
"$nagarectl_bin" --context migration platform upgrade \
  --to "$platform_version" --payload-root "$payload_root" --dry-run --json >"$test_root/upgrade.json"
transaction_id="$(jq -er '.id' "$test_root/upgrade.json")"
bundle="$XDG_STATE_HOME/nagare/migration/upgrades/$transaction_id/kubernetes-plan"
file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}
test "$(file_mode "$bundle")" = 700
test "$(file_mode "$bundle/review.json")" = 600
jq -e '
  .selectorChange.from == "{}" and
  any(.preserve[]; .knativeCertificate.namespace == "personal") and
  any(.remove[]; .knativeCertificate.namespace == "kube-system") and
  any(.remove[]; .knativeCertificate.namespace == "observability")
' "$bundle/review.json" >/dev/null
test "$(kubectl get configmap config-network -n knative-serving -o json | jq -r '.metadata.resourceVersion')" = "$before_selector_version"

: >"$tool_log"
"$nagarectl_bin" --context migration platform upgrade \
  --apply --resume "$transaction_id" --yes --json >"$test_root/applied.json"
jq -e '.state == "completed"' "$test_root/applied.json" >/dev/null
selector_line="$(grep -n -m1 '^kubectl apply --server-side' "$tool_log" | cut -d: -f1)"
policy_line="$(grep -n -m1 '^certificate-policy ' "$tool_log" | cut -d: -f1)"
test "$selector_line" -lt "$policy_line"

kubectl get configmap config-network -n knative-serving -o json |
  jq -e '.data["namespace-wildcard-cert-selector"] == "matchLabels:\n  nagare.dev/app-namespace: \"true\"\n"' >/dev/null
jq -r '.preserve[] | [.knativeCertificate.namespace, .knativeCertificate.name, .generatedSecret.name] | @tsv' \
  "$bundle/review.json" |
  while IFS=$'\t' read -r namespace certificate secret; do
    kubectl get certificates.networking.internal.knative.dev "$certificate" -n "$namespace" -o json |
      jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' >/dev/null
    kubectl get secret "$secret" -n "$namespace" >/dev/null
  done
jq -r '.remove[] | [
  .knativeCertificate.namespace,
  .knativeCertificate.name,
  .certManagerCertificate.name,
  .generatedSecret.name
] | @tsv' "$bundle/review.json" |
  while IFS=$'\t' read -r namespace knative_certificate manager_certificate secret; do
    for resource in \
      "certificates.networking.internal.knative.dev/$knative_certificate" \
      "certificates.cert-manager.io/$manager_certificate" \
      "secret/$secret"; do
      if kubectl get "$resource" -n "$namespace" >/dev/null 2>&1; then
        echo "reviewed obsolete resource remains: $namespace/$resource" >&2
        exit 1
      fi
    done
  done
"$nagarectl_bin" cluster certificate-policy

mutation_count="$(grep -Ec '^kubectl (apply --server-side|delete secret)|^certificate-policy ' "$tool_log")"
"$nagarectl_bin" --context migration platform upgrade \
  --apply --resume "$transaction_id" --yes --json >"$test_root/reapplied.json"
jq -e '.state == "completed"' "$test_root/reapplied.json" >/dev/null
test "$(grep -Ec '^kubectl (apply --server-side|delete secret)|^certificate-policy ' "$tool_log")" = "$mutation_count"

echo "ok: 0.2.2 certificate fixture converged through reviewed upgrade plan/apply and repeat apply"
