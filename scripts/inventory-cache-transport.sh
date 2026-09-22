#!/usr/bin/env bash
# Native transport for one reviewed logical Attic cache. Reads a JSON request
# on stdin and returns only a normalized observation on stdout.
set -euo pipefail

if [ "${NAGARE_INVENTORY_ADAPTER_CHILD:-}" != cache ]; then
  echo "cache transport requires the cache adapter child marker" >&2
  exit 2
fi

action="${1:-}"
case "${action}" in observe|create|configure) ;; *) exit 2 ;; esac
request="$(cat)"
version="$(jq -er '.version' <<<"${request}")"
context="$(jq -er '.context' <<<"${request}")"
cache_name="$(jq -er '.name' <<<"${request}")"
[ "${version}" = "1" ] || exit 2
[[ "${context}" =~ ^[A-Za-z0-9._:@/-]+$ ]] || exit 2
[[ "${cache_name}" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || exit 2

private_dir="$(mktemp -d /tmp/nagare-attic-transport.XXXXXX)"
chmod 700 "${private_dir}"
umask 077
port_forward_pid=""
cleanup() {
  if [ -n "${port_forward_pid}" ]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${private_dir}"
}
trap cleanup EXIT

kubectl_target=(kubectl --context "${context}" --request-timeout=10s)
namespace="$("${kubectl_target[@]}" get namespace nagare-system --ignore-not-found -o name)"
if [ -z "${namespace}" ]; then
  [ "${action}" = observe ] || exit 1
  printf '%s\n' '{"kind":"missing"}'
  exit 0
fi

# The cache's signing identity is stored in this PostgreSQL database. If the
# database volume does not exist, the logical cache cannot exist either.
database_volume="$("${kubectl_target[@]}" -n nagare-system get pvc nagare-db-nix-cache-db-data --ignore-not-found -o name)"
if [ -z "${database_volume}" ]; then
  [ "${action}" = observe ] || exit 1
  printf '%s\n' '{"kind":"missing"}'
  exit 0
fi

"${kubectl_target[@]}" -n nagare-system port-forward service/nix-cache 18080:80 \
  >"${private_dir}/port-forward.log" 2>&1 &
port_forward_pid=$!
ready=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "${port_forward_pid}" >/dev/null 2>&1 || break
  if curl --max-time 2 -fsS -H 'Host: 127.0.0.1:18080' \
      http://127.0.0.1:18080/ 2>/dev/null | grep -q 'Attic Binary Cache'; then
    ready=1
    break
  fi
  sleep 1
done
[ "${ready}" -eq 1 ] || exit 1

cache_url="http://127.0.0.1:18080/_api/v1/cache-config/${cache_name}"
read_cache() {
  curl --max-time 10 -sS -o "${private_dir}/cache.json" -w '%{http_code}' \
    -H 'Host: 127.0.0.1:18080' "${cache_url}"
}

status="$(read_cache)"
if [ "${action}" = observe ]; then
  case "${status}" in
    404) printf '%s\n' '{"kind":"missing"}'; exit 0 ;;
    200) jq -nc --slurpfile cache "${private_dir}/cache.json" '{kind:"present",cache:$cache[0]}'; exit 0 ;;
    *) exit 1 ;;
  esac
fi

if [ "${action}" = create ] && [ "${status}" != 404 ]; then exit 1; fi
if [ "${action}" = configure ] && [ "${status}" != 200 ]; then exit 1; fi

"${kubectl_target[@]}" -n nagare-system exec deployment/nix-cache -- \
  atticadm -f /config/server.toml make-token \
    --sub nagare-bootstrap --validity 5m \
    --pull "${cache_name}" --push "${cache_name}" \
    --create-cache "${cache_name}" \
    --configure-cache "${cache_name}" \
    --configure-cache-retention "${cache_name}" \
  >"${private_dir}/bootstrap.token"
chmod 600 "${private_dir}/bootstrap.token"
mkdir -p "${private_dir}/attic/attic"
cat >"${private_dir}/attic/attic/config.toml" <<EOF
default-server = "nagare"

[servers.nagare]
endpoint = "http://127.0.0.1:18080/"
token-file = "${private_dir}/bootstrap.token"
EOF
chmod 600 "${private_dir}/attic/attic/config.toml"

if [ "${action}" = create ]; then
  XDG_CONFIG_HOME="${private_dir}/attic" attic cache create "nagare:${cache_name}" --public >/dev/null
fi
XDG_CONFIG_HOME="${private_dir}/attic" attic cache configure "nagare:${cache_name}" \
  --public --retention-period '30 days' >/dev/null

status="$(read_cache)"
[ "${status}" = 200 ] || exit 1
jq -nc --slurpfile cache "${private_dir}/cache.json" '{kind:"present",cache:$cache[0]}'
