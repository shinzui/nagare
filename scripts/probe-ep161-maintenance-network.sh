#!/usr/bin/env bash
# Prove that a fenced engine remains reachable over its local socket while
# another Pod loses network ingress to it. This is a disposable CNI probe,
# not maintenance-session acceptance.
set -euo pipefail

context="${1:?pass a disposable Kubernetes context}"
namespace="nagare-ep161-network-$$"
kube() { kubectl --context "$context" "$@"; }

cleanup() {
  kube delete namespace "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kube create namespace "$namespace" >/dev/null
kube -n "$namespace" run server --image=postgres:18 \
  --env=POSTGRES_PASSWORD=probe-only --restart=Never --labels=app=server >/dev/null
kube -n "$namespace" run client --image=postgres:18 \
  --restart=Never --command -- sleep 3600 >/dev/null
kube -n "$namespace" wait --for=condition=Ready pod/server pod/client --timeout=120s >/dev/null

server_ip="$(kube -n "$namespace" get pod server -o jsonpath='{.status.podIP}')"
case "$server_ip" in
  *[!0-9.]*|'') printf 'server Pod has no IPv4 address\n' >&2; exit 1 ;;
esac
kube -n "$namespace" exec client -- pg_isready -t 2 -h "$server_ip" -p 5432 >/dev/null

kube create -f - >/dev/null <<EOF
{
  "apiVersion": "networking.k8s.io/v1",
  "kind": "NetworkPolicy",
  "metadata": {"name": "deny-server-ingress", "namespace": "$namespace"},
  "spec": {
    "podSelector": {"matchLabels": {"app": "server"}},
    "policyTypes": ["Ingress"],
    "ingress": []
  }
}
EOF

denied=0
for _ in {1..20}; do
  if kube -n "$namespace" exec client -- pg_isready -t 2 -h "$server_ip" -p 5432 \
      >/dev/null 2>&1; then
    sleep 1
  else
    denied=1
    break
  fi
done
if [[ "$denied" != 1 ]]; then
  printf 'network ingress remained reachable after the deny policy\n' >&2
  exit 1
fi
kube -n "$namespace" exec server -- pg_isready -t 2 \
  -h /var/run/postgresql -p 5432 >/dev/null
printf 'maintenance network probe passed: remote ingress denied, local socket usable\n'
