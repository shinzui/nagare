#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_name="nagare-ep160-engine-shutdown-$$"
namespace="ep160-engine-shutdown"
probe_root="$(mktemp -d)"
evidence_root="$repo_root/.tmp/$cluster_name"
mkdir -p "$evidence_root"
export KUBECONFIG="$probe_root/kubeconfig"
created=0

cleanup() {
  if [ "$created" -eq 1 ]; then
    kubectl --context "k3d-$cluster_name" -n "$namespace" get pods -o wide \
      >"$evidence_root/final-pods.txt" 2>&1 || true
    k3d cluster delete "$cluster_name" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$probe_root"
}
trap cleanup EXIT

k3d cluster create "$cluster_name" \
  --image rancher/k3s:v1.32.5-k3s1 \
  --servers 1 --agents 0 \
  --kubeconfig-update-default=false \
  --kubeconfig-switch-context=false
created=1
k3d kubeconfig get "$cluster_name" >"$KUBECONFIG"
context="k3d-$cluster_name"

kubectl --context "$context" create namespace "$namespace"
kubectl --context "$context" -n "$namespace" run postgres \
  --image=postgres:18 \
  --env=POSTGRES_PASSWORD=ep160-fixture-only \
  --env=PGDATA=/var/lib/postgresql/data/pgdata
kubectl --context "$context" -n "$namespace" run redis \
  --image=redis:8 --env=REDIS_PASSWORD=ep160-fixture-only \
  --command -- sh -c 'exec redis-server --requirepass "$REDIS_PASSWORD" --dir /data --save 60 1 --appendonly no'
kubectl --context "$context" -n "$namespace" run clickhouse \
  --image=clickhouse/clickhouse-server:25.8 \
  --env=CLICKHOUSE_USER=nagare \
  --env=CLICKHOUSE_PASSWORD=ep160-fixture-only
kubectl --context "$context" -n "$namespace" wait --for=condition=Ready \
  pod/postgres pod/redis pod/clickhouse --timeout=180s
kubectl --context "$context" -n "$namespace" get pods -o \
  custom-columns='NAME:.metadata.name,UID:.metadata.uid,IMAGE:.spec.containers[0].image' \
  >"$evidence_root/fixture-pods.txt"

(
  cd "$repo_root/cli/nagarectl"
  NAGARE_EP160_SHUTDOWN_CONTEXT="$context" \
    NAGARE_EP160_SHUTDOWN_NAMESPACE="$namespace" \
    cabal test nagarectl-test --test-options='-p "data fence"' \
      --test-show-details=failures
)
cp "$repo_root/cli/nagarectl/dist-newstyle/build/aarch64-osx/ghc-9.12.4/nagarectl-0.4.0/t/nagarectl-test/test/nagarectl-0.4.0-nagarectl-test.log" \
  "$evidence_root/data-fence-test.log"
git -C "$repo_root" rev-parse HEAD >"$evidence_root/base-revision.txt"
printf 'EP-160 engine shutdown probe evidence: %s\n' "$evidence_root"
