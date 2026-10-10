#!/usr/bin/env bash
# EP-183 stage B/N0 wrapper: gated d42913c9 CLI against the fresh local context in this root.
set -euo pipefail
root=/private/tmp/nagare-ep183-n0.aKMKyd
args=(PATH="$PATH" HOME=/Users/shinzui
  DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
  XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache"
  SOPS_AGE_KEY_FILE=/Users/shinzui/.config/sops/age/keys.txt
  NAGARE_CLUSTER_SECRETS_DIR="$root/cluster-secrets"
  NAGARE_LOCAL_REGISTRY_FORWARD=127.0.0.1:15013
  NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000)
source "$root/images.env"
for extra in NAGARE_AUTH_EN_IMAGE NAGARE_AUTH_SHOMEI_IMAGE NAGARE_AUTH_ACCESS_IMAGE NAGARE_LOCAL_MINIO_IMAGE NAGARE_LOCAL_MC_IMAGE; do
  if [[ -n "${!extra:-}" ]]; then args+=("$extra=${!extra}"); fi
done
if [[ -f "$root/config/nagare/kubeconfigs/local.yaml" ]]; then args+=(KUBECONFIG="$root/config/nagare/kubeconfigs/local.yaml"); fi
exec env -i "${args[@]}" /private/tmp/nagare-b9-ep183/result-d42913c9-nagare/bin/nagarectl --context local "$@"
