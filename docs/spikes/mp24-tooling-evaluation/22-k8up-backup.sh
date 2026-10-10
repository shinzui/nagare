#!/usr/bin/env bash
# Run one K8up Backup named $1 with restic tag $2, sampling resource use while it
# runs, then list the resulting Snapshot objects.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
. "$here/lib.sh"
name="$1" tag="$2"
out="$EVAL_STATE/k8up/$name"
mkdir -p "$out"

k top pod -n k8up --no-headers >"$out/operator-before.top" || true
k apply -f - <<EOF
apiVersion: k8up.io/v1
kind: Backup
metadata: {name: $name, namespace: app}
spec:
  tags: [$tag]
  podSecurityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  backend:
    repoPasswordSecretRef: {name: backup-repo, key: password}
    s3:
      endpoint: http://minio.minio:9000
      bucket: k8up
      accessKeyIDSecretRef: {name: backup-credentials, key: username}
      secretAccessKeySecretRef: {name: backup-credentials, key: password}
EOF
start=$(date +%s)
top_sample app 40 >"$out/app-during.top" &
sampler=$!
k8up_wait backup "$name" 600 | tee "$out/conditions.txt"
end=$(date +%s)
kill "$sampler" 2>/dev/null || true
echo "elapsed_seconds=$((end - start))" | tee "$out/elapsed.txt"
k -n app get snapshots -o custom-columns='ID:.spec.id,PATHS:.spec.paths,DATE:.spec.date,REPO:.spec.repository' | tee "$out/snapshots.txt"
k -n app logs -l k8up.io/owned-by=backup_"$name" --tail=40 >"$out/job.log" 2>&1 || true
