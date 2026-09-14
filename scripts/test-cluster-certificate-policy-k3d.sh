#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_name="${NAGARE_TLS_TEST_CLUSTER:-nagare-tls-policy-$$}"
case "$cluster_name" in
  nagare-tls-policy-*) ;;
  *)
    echo "refusing to manage unexpected cluster name: $cluster_name" >&2
    exit 2
    ;;
esac

test_root="$(mktemp -d)"
export KUBECONFIG="$test_root/kubeconfig"

cleanup() {
  k3d cluster delete "$cluster_name" >/dev/null 2>&1 || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT

k3d cluster create "$cluster_name" \
  --image rancher/k3s:v1.34.6-k3s1 \
  --wait \
  --timeout 5m \
  --kubeconfig-update-default=false \
  --kubeconfig-switch-context=false
k3d kubeconfig get "$cluster_name" >"$KUBECONFIG"

kubectl create namespace cert-manager
kubectl create namespace knative-serving
kubectl create namespace personal
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
kubectl -n knative-serving rollout status deployment/net-certmanager-controller --timeout=5m
kubectl -n knative-serving rollout status deployment/net-certmanager-webhook --timeout=5m

kubectl -n knative-serving patch configmap config-certmanager \
  --type merge \
  --patch "$(cat "$repo_root/cluster/bootstrap/knative-serving/config-certmanager.yaml")"
# Restart after the patch so this test does not race the controller's asynchronous
# config watcher when it enables external-domain TLS immediately afterward.
kubectl -n knative-serving rollout restart deployment/net-certmanager-controller
kubectl -n knative-serving rollout status deployment/net-certmanager-controller --timeout=5m
kubectl -n knative-serving patch configmap config-domain \
  --type merge \
  --patch '{"data":{"apps.example.test":""}}'
kubectl -n knative-serving patch configmap config-network \
  --type merge \
  --patch "$(cat "$repo_root/cluster/bootstrap/knative-serving/config-network-tls.yaml")"

kubectl apply -f - <<'YAML'
apiVersion: networking.internal.knative.dev/v1alpha1
kind: Certificate
metadata:
  name: system-internal-fixture
  namespace: knative-serving
  annotations:
    networking.knative.dev/certificate.class: cert-manager.certificate.networking.knative.dev
  labels:
    networking.knative.dev/certificate-type: system-internal
spec:
  secretName: system-internal-fixture
  dnsNames:
    - kn-routing
---
apiVersion: networking.internal.knative.dev/v1alpha1
kind: Certificate
metadata:
  name: cluster-local-fixture
  namespace: knative-serving
  annotations:
    networking.knative.dev/certificate.class: cert-manager.certificate.networking.knative.dev
  labels:
    networking.knative.dev/certificate-type: cluster-local-domain
spec:
  secretName: cluster-local-fixture
  dnsNames:
    - api.personal.svc.cluster.local
YAML

wait_for_certificate() {
  local namespace="$1"
  local expression="$2"
  local conflicting_expression="${3:-}"
  local attempt
  for attempt in $(seq 1 150); do
    if kubectl get certificate -A -o json | jq -e "$expression" >/dev/null; then
      return 0
    fi
    if [ -n "$conflicting_expression" ] && kubectl get certificate -A -o json | jq -e "$conflicting_expression" >/dev/null; then
      echo "certificate policy conflict appeared in $namespace" >&2
      kubectl get certificate -A \
        -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,ISSUER:.spec.issuerRef.name,DNS_NAMES:.spec.dnsNames' >&2
      return 1
    fi
    sleep 2
  done
  echo "timed out waiting for certificate policy evidence in $namespace" >&2
  kubectl get certificate -A -o yaml >&2 || true
  return 1
}

wait_for_certificate knative-serving \
  '[.items[] | select(.metadata.namespace == "knative-serving" and .metadata.name == "system-internal-fixture" and .spec.issuerRef.name == "knative-selfsigned-issuer")] | length == 1'
wait_for_certificate knative-serving \
  '[.items[] | select(.metadata.namespace == "knative-serving" and .metadata.name == "cluster-local-fixture" and .spec.issuerRef.name == "knative-selfsigned-issuer")] | length == 1'
wait_for_certificate personal \
  '[.items[] | select(.metadata.namespace == "personal" and .spec.issuerRef.name == "letsencrypt-dns" and any(.spec.dnsNames[]; startswith("*.personal.")))] | length >= 1' \
  '[.items[] | select(.metadata.namespace == "personal" and .spec.issuerRef.name != "letsencrypt-dns" and any(.spec.dnsNames[]?; startswith("*.personal.")))] | length >= 1'

kubectl get certificate -A -o json | jq -e '
  [.items[]
   | select(.spec.issuerRef.name == "letsencrypt-dns")
   | select(any(.spec.dnsNames[]?; startswith("*.")))
   | select(.metadata.namespace != "personal")]
  | length == 0
' >/dev/null

(cd "$repo_root/cli/nagarectl" && cabal run nagarectl -- cluster certificate-policy)

echo "ok: disposable cluster confined public wildcards and used self-signed internal issuers"
