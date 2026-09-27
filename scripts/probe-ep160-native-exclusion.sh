#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_name="ep160-ex-$$"
probe_root="$(mktemp -d)"
evidence_root="$(mktemp -d "${TMPDIR:-/tmp}/$cluster_name.XXXXXX")"
export KUBECONFIG="$probe_root/kubeconfig"
created=0

cleanup() {
  if [ "$created" -eq 1 ]; then
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
node="$cluster_name-server-0"
engines=("$@")
if [ "${#engines[@]}" -eq 0 ]; then
  engines=(postgres redis clickhouse)
fi

for engine in "${engines[@]}"; do
  namespace="ep160-$engine"
  pv="ep160-$engine-$cluster_name"
  docker exec "k3d-$node" mkdir -p "/tmp/$pv"
  case "$engine" in
    postgres)
      image="postgres:18"
      port=5432
      mount=/var/lib/postgresql/data
      env_yaml='        - name: POSTGRES_PASSWORD
          value: ep160-fixture-only
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata'
      command_yaml=''
      ;;
    redis)
      image="redis:8"
      port=6379
      mount=/data
      env_yaml='        - name: REDIS_PASSWORD
          value: ep160-fixture-only'
      command_yaml='        command: ["sh", "-c"]
        args: ["exec redis-server --requirepass \"$REDIS_PASSWORD\" --dir /data --save 60 1 --appendonly no"]'
      ;;
    clickhouse)
      image="clickhouse/clickhouse-server:25.8"
      port=9000
      mount=/var/lib/clickhouse
      env_yaml='        - name: CLICKHOUSE_USER
          value: nagare
        - name: CLICKHOUSE_PASSWORD
          value: ep160-fixture-only'
      command_yaml=''
      ;;
  esac
  kubectl --context "$context" create namespace "$namespace"
  cat >"$probe_root/$engine.yaml" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $pv
spec:
  capacity:
    storage: 1Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  local:
    path: /tmp/$pv
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: [k3d-$node]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
  namespace: $namespace
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  volumeName: $pv
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: database
  namespace: $namespace
spec:
  selector:
    nagare.dev/database: database
  ports:
  - port: $port
    targetPort: $port
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: database
  namespace: $namespace
  labels:
    nagare.dev/database: database
spec:
  serviceName: database
  replicas: 1
  selector:
    matchLabels:
      nagare.dev/database: database
  template:
    metadata:
      labels:
        nagare.dev/database: database
    spec:
      containers:
      - name: $engine
        image: $image
        ports:
        - containerPort: $port
        volumeMounts:
        - name: data
          mountPath: $mount
$command_yaml
        env:
$env_yaml
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: data-pvc
EOF
  kubectl --context "$context" apply -f "$probe_root/$engine.yaml"
  kubectl --context "$context" -n "$namespace" rollout status statefulset/database --timeout=180s
  kubectl --context "$context" -n "$namespace" get pvc,service,statefulset,pod -o wide \
    >"$evidence_root/$engine-before.txt"
  (
    cd "$repo_root/cli/nagarectl"
    NAGARE_EP160_EXCLUSION_CONTEXT="$context" \
      NAGARE_EP160_EXCLUSION_NAMESPACE="$namespace" \
      NAGARE_EP160_EXCLUSION_ENGINE="$engine" \
      cabal test nagarectl-test --test-options='-p "data fence"' \
        --test-show-details=failures
  )
  cp "$repo_root/cli/nagarectl/dist-newstyle/build/aarch64-osx/ghc-9.12.4/nagarectl-0.4.0/t/nagarectl-test/test/nagarectl-0.4.0-nagarectl-test.log" \
    "$evidence_root/$engine-test.log"
  kubectl --context "$context" -n "$namespace" get pvc,service,statefulset,pod -o wide \
    >"$evidence_root/$engine-after.txt"
done
git -C "$repo_root" rev-parse HEAD >"$evidence_root/base-revision.txt"
printf 'EP-160 native exclusion evidence: %s\n' "$evidence_root"
