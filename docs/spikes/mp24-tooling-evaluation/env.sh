# Sourced by every EP-163 prototype script. The prototype owns exactly one k3d
# cluster, named mp24-eval, with its own kubeconfig. It never touches the
# operator's default kube context, the nagare-local cluster, or any cloud context.
export EVAL_CLUSTER=mp24-eval
export EVAL_STATE="${EVAL_STATE:-${TMPDIR:-/tmp}/mp24-eval}"
export KUBECONFIG="$EVAL_STATE/kubeconfig"
# EVAL_DOCKER_HOST must name a Docker daemon the operator has approved for this
# prototype. The 2026-10-09 run used the cp3 Colima profile's daemon, outside the
# cp3 claim protocol (docs/runbooks/native-verification-harness.md section 3);
# that was a mistake, and no further run may use cp3 without the claim.
export DOCKER_HOST="${EVAL_DOCKER_HOST:?set EVAL_DOCKER_HOST to an operator-approved Docker daemon}"
export EVAL_CTX="k3d-$EVAL_CLUSTER"

# Pinned candidate versions, checked against upstream release tags on 2026-10-09.
export K8UP_CHART_VERSION=4.10.0 # operator v2.16.0, embeds restic v0.19.0
export CNPG_VERSION=1.30.1
export BARMAN_PLUGIN_VERSION=0.15.1
export CERT_MANAGER_VERSION=1.21.2
# The object store is RustFS (10-objectstore.yaml); MinIO images were not
# pullable on 2026-10-09. Fixture PostgreSQL is postgres:18.

k() { kubectl --context "$EVAL_CTX" "$@"; }
