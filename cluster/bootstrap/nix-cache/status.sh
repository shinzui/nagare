#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform_root="$(cd "${script_dir}/../../.." && pwd)"
# shellcheck disable=SC1091
source "${platform_root}/scripts/lib/target.sh"

if [ "${NAGARE_NIX_CACHE_ENABLED}" != "1" ]; then
  echo "Nix cache: disabled"
  exit 0
fi

private_dir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-nix-cache-status.XXXXXX")"
port_forward_pid=""
cleanup() {
  if [ -n "${port_forward_pid}" ]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${private_dir}"
}
trap cleanup EXIT

image="$(kubectl -n nagare-system get deployment nix-cache -o jsonpath='{.spec.template.spec.containers[0].image}')"
database="$(kubectl -n nagare-system get statefulset nix-cache -o jsonpath='{.status.readyReplicas}/{.status.replicas}')"
migration="$(kubectl -n nagare-system get job nix-cache-migrate -o jsonpath='{.status.succeeded}')"
rollout="$(kubectl -n nagare-system get deployment nix-cache -o jsonpath='{.status.readyReplicas}/{.status.replicas}')"
gc_schedule="$(kubectl -n nagare-system get cronjob nix-cache-gc -o jsonpath='{.spec.schedule}')"
backup_schedule="$(kubectl -n nagare-system get cronjob nagare-dbbackup-nix-cache -o jsonpath='{.spec.schedule}')"
config_digest="$(kubectl -n personal get configmap nagare-nix-cache-client -o jsonpath='{.data.nix\.conf}' | sha256sum | cut -d' ' -f1)"

kubectl -n nagare-system port-forward service/nix-cache 8080:80 > "${private_dir}/port-forward.log" 2>&1 &
port_forward_pid=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS -H 'Host: 127.0.0.1:8080' \
    http://127.0.0.1:8080/_api/v1/cache-config/nagare-cache \
    > "${private_dir}/cache.json"; then
    break
  fi
  sleep 1
done
jq -e '.is_public == true and (.public_key | length > 0)' "${private_dir}/cache.json" >/dev/null

printf 'Nix cache: enabled\n'
printf 'Image: %s\n' "${image}"
printf 'Database ready: %s\n' "${database}"
printf 'Migration succeeded: %s\n' "${migration}"
printf 'API ready: %s\n' "${rollout}"
printf 'Public key: %s\n' "$(jq -r '.public_key' "${private_dir}/cache.json")"
printf 'Retention seconds: %s\n' "$(jq -r '.retention_period.Period' "${private_dir}/cache.json")"
printf 'GC schedule: %s\n' "${gc_schedule}"
printf 'Database backup schedule: %s\n' "${backup_schedule}"
printf 'Client ConfigMap SHA-256: %s\n' "${config_digest}"
