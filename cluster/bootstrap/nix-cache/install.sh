#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform_root="$(cd "${script_dir}/../../.." && pwd)"
# shellcheck disable=SC1091
source "${platform_root}/scripts/lib/target.sh"
# shellcheck disable=SC1091
source "${platform_root}/scripts/lib/cluster-secrets.sh"

if [ "${NAGARE_NIX_CACHE_ENABLED}" != "1" ]; then
  echo "Nix cache disabled for context '${NAGARE_CONTEXT}'; no resources changed."
  exit 0
fi

_require_target_project
secret_dir="$(nagare_cluster_secrets_dir)"
secret_file="$(nagare_require_cluster_secret "${secret_dir}" nix-cache.yaml)"

if [ -z "${SOPS_AGE_KEY_FILE:-}" ]; then
  default_sops_key="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  if [ -f "${default_sops_key}" ]; then
    export SOPS_AGE_KEY_FILE="${default_sops_key}"
  fi
fi

private_dir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-nix-cache-install.XXXXXX")"
chmod 700 "${private_dir}"
port_forward_pid=""
cleanup() {
  if [ -n "${port_forward_pid}" ]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${private_dir}"
}
trap cleanup EXIT
umask 077

image_ref="$("${script_dir}/publish-image.sh")"
case "${image_ref}" in
  *@sha256:*) ;;
  *) echo "nagare: image publisher did not return an immutable digest" >&2; exit 1 ;;
esac

# Resolve all private inputs before the first cluster mutation.
sops -d "${secret_file}" > "${private_dir}/secrets.yaml"

kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace personal --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace personal nagare.dev/app-namespace=true --overwrite
kubectl apply -f "${private_dir}/secrets.yaml"

nagarectl db create postgres nix-cache \
  --namespace nagare-system --system-namespace --size 5Gi --cpu 500m --memory 1Gi

escaped_bucket="$(printf '%s' "${NAGARE_NIX_CACHE_BUCKET}" | sed -e 's/[&|]/\\&/g')"
sed "s|\${NAGARE_NIX_CACHE_BUCKET}|${escaped_bucket}|g" \
  "${script_dir}/server.toml.tmpl" > "${private_dir}/server.toml"
kubectl -n nagare-system create configmap nagare-nix-cache-server \
  --from-file="server.toml=${private_dir}/server.toml" \
  --dry-run=client -o yaml | kubectl apply -f -

escaped_image="$(printf '%s' "${image_ref}" | sed -e 's/[&|]/\\&/g')"
for template in config-check-job migration-job workloads; do
  sed "s|\${ATTIC_IMAGE}|${escaped_image}|g" \
    "${script_dir}/${template}.yaml.tmpl" > "${private_dir}/${template}.yaml"
done

kubectl -n nagare-system delete job nix-cache-config-check --ignore-not-found=true
kubectl apply -f "${private_dir}/config-check-job.yaml"
kubectl -n nagare-system wait --for=condition=complete job/nix-cache-config-check --timeout=180s

kubectl -n nagare-system delete job nix-cache-migrate --ignore-not-found=true
kubectl apply -f "${private_dir}/migration-job.yaml"
kubectl -n nagare-system wait --for=condition=complete job/nix-cache-migrate --timeout=300s

kubectl apply -f "${private_dir}/workloads.yaml"
kubectl apply -f "${script_dir}/networkpolicies.yaml"
kubectl -n nagare-system rollout status deployment/nix-cache --timeout=300s

kubectl -n nagare-system exec deployment/nix-cache -- \
  atticadm -f /config/server.toml make-token \
    --sub nagare-bootstrap --validity 5m \
    --pull nagare-cache --push nagare-cache \
    --create-cache nagare-cache \
    --configure-cache nagare-cache \
    --configure-cache-retention nagare-cache > "${private_dir}/bootstrap.token"
chmod 600 "${private_dir}/bootstrap.token"

mkdir -p "${private_dir}/attic/attic"
cat > "${private_dir}/attic/attic/config.toml" <<EOF
default-server = "nagare"

[servers.nagare]
endpoint = "http://127.0.0.1:8080/"
token-file = "${private_dir}/bootstrap.token"
EOF
chmod 600 "${private_dir}/attic/attic/config.toml"

kubectl -n nagare-system port-forward service/nix-cache 8080:80 \
  > "${private_dir}/port-forward.log" 2>&1 &
port_forward_pid=$!
ready=0
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sS -o /dev/null -H 'Host: 127.0.0.1:8080' http://127.0.0.1:8080/; then
    ready=1
    break
  fi
  sleep 1
done
if [ "${ready}" -ne 1 ]; then
  cat "${private_dir}/port-forward.log" >&2
  echo "nagare: Attic port-forward did not become ready" >&2
  exit 1
fi

if ! XDG_CONFIG_HOME="${private_dir}/attic" attic cache info nagare:nagare-cache >/dev/null 2>&1; then
  XDG_CONFIG_HOME="${private_dir}/attic" attic cache create nagare:nagare-cache --public
fi
XDG_CONFIG_HOME="${private_dir}/attic" attic cache configure nagare:nagare-cache \
  --public --retention-period '30 days'

curl -fsS -H 'Host: 127.0.0.1:8080' \
  http://127.0.0.1:8080/_api/v1/cache-config/nagare-cache \
  > "${private_dir}/cache.json"
jq -e '
  .substituter_endpoint == "http://nix-cache.nagare-system.svc.cluster.local/nagare-cache" and
  .api_endpoint == "http://127.0.0.1:8080/" and
  .is_public == true and
  .retention_period.Period == 2592000 and
  (.public_key | type == "string" and length > 0)
' "${private_dir}/cache.json" >/dev/null

jq -er '.public_key' "${private_dir}/cache.json" > "${private_dir}/public-key"
public_key="$(cat "${private_dir}/public-key")"
escaped_key="$(printf '%s' "${public_key}" | sed -e 's/[&|]/\\&/g')"
sed "s|\${ATTIC_PUBLIC_KEY}|${escaped_key}|g" \
  "${script_dir}/client-configmap.yaml.tmpl" > "${private_dir}/client-configmap.yaml"
kubectl apply -f "${private_dir}/client-configmap.yaml"

echo "Attic reconciled at http://nix-cache.nagare-system.svc.cluster.local/nagare-cache"
