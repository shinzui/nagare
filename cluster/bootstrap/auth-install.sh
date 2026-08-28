#!/usr/bin/env bash
# Install the cloud auth-plane manifests with image refs rendered from the active context.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bootstrap_dir="${repo_root}/cluster/bootstrap"

# shellcheck source=scripts/lib/target.sh
source "${repo_root}/scripts/lib/target.sh"
# shellcheck source=scripts/lib/release.sh
source "${repo_root}/scripts/lib/release.sh"

if [ "${NAGARE_MODE:-cloud}" = "local" ]; then
  echo "error: auth-install.sh is the cloud installer; use cluster/bootstrap/local-auth/install.sh for NAGARE_MODE=local" >&2
  exit 2
fi

# Immutable-by-default: Knative skips tag->digest resolution for our registry
# (knative-serving/config-deployment.yaml), so a mutable tag can silently change
# across node restarts. build-local-image.sh tags with the same short SHA.
tag="${NAGARE_AUTH_TAG:-$(nagare_release_source_tag "${repo_root}")}"

render_service() {
  local svc="$1"
  NAGARE_AUTH_TAG="${tag}" "${bootstrap_dir}/render-context-template.sh" "${bootstrap_dir}/${svc}/service.yaml"
}

render_template() {
  NAGARE_AUTH_TAG="${tag}" "${bootstrap_dir}/render-context-template.sh" "$1"
}

kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n nagare-system get secret nagare-en-api-keys >/dev/null 2>&1; then
  echo "==> creating en API-key Secret"
  kubectl -n nagare-system create secret generic nagare-en-api-keys \
    --from-literal=read-write="$(openssl rand -base64 32)" \
    --from-literal=read-only="$(openssl rand -base64 32)"
else
  echo "==> en API-key Secret already present (left as-is)"
fi

if ! kubectl -n nagare-system get secret nagare-shomei-keys >/dev/null 2>&1; then
  echo "==> creating Shomei key-encryption Secret"
  kubectl -n nagare-system create secret generic nagare-shomei-keys \
    --from-literal=key-encryption-key="$(openssl rand -base64 32)"
else
  echo "==> Shomei key-encryption Secret already present (left as-is)"
fi

# Job spec.template is immutable and a completed Job never re-runs, so a new
# release image's embedded plan would otherwise silently never apply. Migrations are
# ledger-backed and idempotent while their published history is unchanged. Shomei
# 0.2.0.0 intentionally changed existing checksums; docs/user/access.md requires
# Nagare's unused pre-0.2 shomei-db to be recreated before this Job runs.
kubectl -n nagare-system delete job shomei-migrate --ignore-not-found=true
render_template "${bootstrap_dir}/shomei/migrations.yaml" | kubectl apply -f -
kubectl -n nagare-system wait --for=condition=complete job/shomei-migrate --timeout=120s
kubectl -n nagare-system delete job en-migrate --ignore-not-found=true
render_template "${bootstrap_dir}/en/migrations.yaml" | kubectl apply -f -
kubectl -n nagare-system wait --for=condition=complete job/en-migrate --timeout=120s
kubectl apply -f "${bootstrap_dir}/en/configmap.yaml"
render_service shomei | kubectl apply -f -
render_service en | kubectl apply -f -
kubectl apply -f "${bootstrap_dir}/nagare-access/configmap.yaml"
render_service nagare-access | kubectl apply -f -
