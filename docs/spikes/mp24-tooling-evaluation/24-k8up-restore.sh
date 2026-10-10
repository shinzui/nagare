#!/usr/bin/env bash
# Run one K8up folder Restore into a PVC and report the outcome.
#   $1 restore name   $2 claim name (created if absent)
#   $3 extra spec lines (YAML, two-space indented), e.g. "  snapshot: <id>"
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
. "$here/lib.sh"
name="$1" claim="$2" extra="${3:-}"
out="$EVAL_STATE/k8up/$name"
mkdir -p "$out"

if ! k -n app get pvc "$claim" >/dev/null 2>&1; then
  k apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $claim, namespace: app}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
EOF
fi

k apply -f - <<EOF
apiVersion: k8up.io/v1
kind: Restore
metadata: {name: $name, namespace: app}
spec:
$extra
  podSecurityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  restoreMethod:
    folder: {claimName: $claim}
  backend:
    repoPasswordSecretRef: {name: backup-repo, key: password}
    s3:
      endpoint: http://minio.minio:9000
      bucket: k8up
      accessKeyIDSecretRef: {name: backup-credentials, key: username}
      secretAccessKeySecretRef: {name: backup-credentials, key: password}
EOF
start=$(date +%s)
k8up_wait restore "$name" 300 | tee "$out/conditions.txt"
echo "elapsed_seconds=$(($(date +%s) - start))" | tee "$out/elapsed.txt"
pod=$(k -n app get pods -l "job-name=restore-$name" -o name | tail -1)
[ -n "$pod" ] && k -n app logs "$pod" --tail=30 >"$out/job.log" 2>&1 || true
tail -6 "$out/job.log" 2>/dev/null || true
