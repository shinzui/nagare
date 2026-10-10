#!/usr/bin/env bash
# Retention on disposable snapshots: run a K8up Check (restic check) after the
# interrupted backups, then a Prune with keepLast=1 and keepTags=[g1], where the
# g1 tag stands in for "a recovery point Nagare's journal still references".
# Records which snapshots survive and whether the Snapshot objects follow.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
. "$here/lib.sh"
out="$EVAL_STATE/k8up/retention"
mkdir -p "$out"
backend='  backend:
    repoPasswordSecretRef: {name: backup-repo, key: password}
    s3:
      endpoint: http://minio.minio:9000
      bucket: k8up
      accessKeyIDSecretRef: {name: backup-credentials, key: username}
      secretAccessKeySecretRef: {name: backup-credentials, key: password}'

k -n app get snapshots -o custom-columns='ID:.spec.id,PATHS:.spec.paths,DATE:.spec.date' >"$out/snapshots-before.txt"
k apply -f - <<EOF
apiVersion: k8up.io/v1
kind: Check
metadata: {name: check1, namespace: app}
spec:
  podSecurityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
$backend
EOF
k8up_wait check check1 600 | tee "$out/check-conditions.txt"
k -n app logs -l job-name=check-check1 --tail=20 >"$out/check.log" 2>&1 || true

k apply -f - <<EOF
apiVersion: k8up.io/v1
kind: Prune
metadata: {name: prune1, namespace: app}
spec:
  podSecurityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  retention:
    keepLast: 1
    keepTags: [g1]
$backend
EOF
k8up_wait prune prune1 600 | tee "$out/prune-conditions.txt"
k -n app logs -l job-name=prune-prune1 --tail=40 >"$out/prune.log" 2>&1 || true
sleep 5
k -n app get snapshots -o custom-columns='ID:.spec.id,PATHS:.spec.paths,DATE:.spec.date' | tee "$out/snapshots-after.txt"
