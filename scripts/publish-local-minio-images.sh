#!/usr/bin/env bash
set -euo pipefail

# Publish disposable local-only images from the last upstream binary releases.
# The released binaries are checked by exact asset digest before Docker sees
# them; the reviewed local bootstrap binds the resulting registry manifests.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/local-registry.sh"

for tool in gh docker; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'local MinIO publication requires %s\n' "$tool" >&2
    exit 1
  }
done

case "$(docker info --format '{{.Architecture}}')" in
  aarch64|arm64)
    arch=arm64
    server_sha=5c83cd2cf151717ba0243f73e1c7802ff36e272b67144bdd7f1f7d684fd6f03d
    client_sha=14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c
    ;;
  x86_64|amd64)
    arch=amd64
    server_sha=7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f
    client_sha=01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891
    ;;
  *) printf 'local MinIO publication supports linux/arm64 or linux/amd64\n' >&2; exit 1 ;;
esac

server_release=RELEASE.2025-09-07T16-13-09Z
client_release=RELEASE.2025-08-13T08-35-41Z
server_asset="minio.linux-${arch}.${server_release}"
client_asset="mc.linux-${arch}.${client_release}"
work="$(mktemp -d "${TMPDIR:-/tmp}/nagare-local-minio.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/server" "$work/client"
gh release download "$server_release" --repo minio/minio \
  --pattern "$server_asset" --dir "$work/server"
gh release download "$client_release" --repo minio/mc \
  --pattern "$client_asset" --dir "$work/client"

digest_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
[[ "$(digest_file "$work/server/$server_asset")" == "$server_sha" ]] \
  || { echo 'MinIO server asset digest differs from its upstream release' >&2; exit 1; }
[[ "$(digest_file "$work/client/$client_asset")" == "$client_sha" ]] \
  || { echo 'MinIO client asset digest differs from its upstream release' >&2; exit 1; }

mv "$work/server/$server_asset" "$work/server/minio"
mv "$work/client/$client_asset" "$work/client/mc"
chmod 755 "$work/server/minio" "$work/client/mc"
printf 'FROM scratch\nCOPY minio /minio\nENTRYPOINT ["/minio"]\n' \
  > "$work/server/Dockerfile"
printf 'FROM alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1\nCOPY mc /usr/local/bin/mc\n' \
  > "$work/client/Dockerfile"

registry=k3d-registry.localhost:5000
server_tag="$registry/nagare-minio:release-2025-09-07-${arch}"
client_tag="$registry/nagare-mc:release-2025-08-13-${arch}"
docker build --platform "linux/$arch" -t "$server_tag" "$work/server"
docker build --platform "linux/$arch" -t "$client_tag" "$work/client"
docker push "$server_tag"
docker push "$client_tag"
export NAGARE_REGISTRY_HOST="$registry"
server_digest="$(nagare_local_registry_digest "$server_tag")"
client_digest="$(nagare_local_registry_digest "$client_tag")"
printf 'NAGARE_LOCAL_MINIO_IMAGE=%s/nagare-minio@%s\n' "$registry" "$server_digest"
printf 'NAGARE_LOCAL_MC_IMAGE=%s/nagare-mc@%s\n' "$registry" "$client_digest"
