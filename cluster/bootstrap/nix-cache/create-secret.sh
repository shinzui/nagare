#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform_root="$(cd "${script_dir}/../../.." && pwd)"
# shellcheck disable=SC1091
source "${platform_root}/scripts/lib/target.sh"
# shellcheck disable=SC1091
source "${platform_root}/scripts/lib/cluster-secrets.sh"

rotate=0
if [ "${1:-}" = "--rotate" ]; then
  rotate=1
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--rotate]" >&2
  exit 2
fi

_require_target_project
nagarectl platform guard >&2

if [ "${NAGARE_NIX_CACHE_ENABLED}" != "1" ]; then
  echo "nagare: Nix cache is disabled for context '${NAGARE_CONTEXT}'" >&2
  exit 1
fi

secrets_dir="$(nagare_cluster_secrets_dir)"
mkdir -p "${secrets_dir}"
destination="${secrets_dir}/nix-cache.yaml"
if [ -e "${destination}" ] && [ "${rotate}" -ne 1 ]; then
  echo "nagare: refusing to overwrite ${destination}; pass --rotate to replace both credentials" >&2
  exit 1
fi

# Keep the final ciphertext rename on the destination filesystem so a
# successful rotation is atomic even when the system temporary directory is a
# different mount.
private_dir="$(mktemp -d "${secrets_dir}/.nagare-nix-cache-secret.XXXXXX")"
chmod 700 "${private_dir}"
trap 'rm -rf "${private_dir}"' EXIT
umask 077

pulumi_dir="${NAGARE_REPO_ROOT}/infra/pulumi"
enabled="$(pulumi -C "${pulumi_dir}" stack output nixCacheEnabled)"
if [ "${enabled}" != "true" ]; then
  echo "nagare: Pulumi stack output nixCacheEnabled is not true; apply the reviewed enablement plan first" >&2
  exit 1
fi

pulumi -C "${pulumi_dir}" stack output nixCacheHmacAccessId | tr -d '\n' > "${private_dir}/AWS_ACCESS_KEY_ID"
pulumi -C "${pulumi_dir}" stack output --show-secrets nixCacheHmacSecret | tr -d '\n' > "${private_dir}/AWS_SECRET_ACCESS_KEY"
# OpenSSL 3 emits PKCS#8 unless asked for the traditional PKCS#1 encoding,
# while macOS LibreSSL already emits PKCS#1 and rejects `-traditional`.
if ! openssl genrsa -traditional -out "${private_dir}/attic-jwt.pem" 4096 >/dev/null 2>&1; then
  openssl genrsa -out "${private_dir}/attic-jwt.pem" 4096 >/dev/null 2>&1
fi
base64 < "${private_dir}/attic-jwt.pem" | tr -d '\n' > "${private_dir}/ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64"

kubectl -n nagare-system create secret generic nagare-nix-cache-storage \
  --from-file="AWS_ACCESS_KEY_ID=${private_dir}/AWS_ACCESS_KEY_ID" \
  --from-file="AWS_SECRET_ACCESS_KEY=${private_dir}/AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml > "${private_dir}/storage.yaml"
kubectl -n nagare-system create secret generic nagare-nix-cache-token-key \
  --from-file="ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=${private_dir}/ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64" \
  --dry-run=client -o yaml > "${private_dir}/token.yaml"

{
  cat "${private_dir}/storage.yaml"
  printf '\n%s\n' '---'
  cat "${private_dir}/token.yaml"
  printf '\n'
} > "${private_dir}/plain.yaml"

sops --encrypt \
  --filename-override "${destination}" \
  --input-type yaml \
  --output-type yaml \
  "${private_dir}/plain.yaml" > "${private_dir}/encrypted.yaml"
chmod 600 "${private_dir}/encrypted.yaml"
mv "${private_dir}/encrypted.yaml" "${destination}"
printf '%s\n' "${destination}"
