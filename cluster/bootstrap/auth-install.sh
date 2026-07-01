#!/usr/bin/env bash
# Install the cloud auth-plane manifests with image refs rendered from the active context.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bootstrap_dir="${repo_root}/cluster/bootstrap"

# shellcheck source=scripts/lib/target.sh
source "${repo_root}/scripts/lib/target.sh"

if [ "${NAGARE_MODE:-cloud}" = "local" ]; then
  echo "error: auth-install.sh is the cloud installer; use cluster/bootstrap/local-auth/install.sh for NAGARE_MODE=local" >&2
  exit 2
fi

tag="${NAGARE_AUTH_TAG:-latest}"

render_service() {
  local svc="$1"
  NAGARE_AUTH_TAG="${tag}" "${bootstrap_dir}/render-context-template.sh" "${bootstrap_dir}/${svc}/service.yaml"
}

kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -

render_service shomei | kubectl apply -f -
kubectl apply -f "${bootstrap_dir}/en/migrations.yaml"
kubectl -n nagare-system wait --for=condition=complete job/en-migrate --timeout=120s
kubectl apply -f "${bootstrap_dir}/en/configmap.yaml"
render_service en | kubectl apply -f -
kubectl apply -f "${bootstrap_dir}/nagare-access/configmap.yaml"
render_service nagare-access | kubectl apply -f -
