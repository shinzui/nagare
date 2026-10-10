#!/usr/bin/env bash
# Interrupted backup. Adds INTERRUPT_BYTES of new random data, starts Backup $1,
# blocks the object store with a NetworkPolicy, kills the file-volume pod with a
# zero grace period KILL_AFTER seconds after it starts running, keeps the store
# unreachable for OUTAGE seconds while the Job retries, then restores access.
# Records what the Backup object, the Snapshot objects and the job logs say.
#
#   run 1 (b3): INTERRUPT_BYTES=805306368 KILL_AFTER=8 OUTAGE=45, outage applied
#               after the kill. The 768 MiB upload had already finished in under
#               8 s, so this run did not interrupt restic (kept as evidence).
#   run 2 (b4): INTERRUPT_BYTES=2147483648 KILL_AFTER=2 OUTAGE=90, outage applied
#               before the kill.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
. "$here/lib.sh"
name="${1:?backup name}"
bytes="${INTERRUPT_BYTES:-2147483648}"
kill_after="${KILL_AFTER:-2}"
outage="${OUTAGE:-90}"
out="$EVAL_STATE/k8up/$name-interrupt"
mkdir -p "$out"

k -n app exec deploy/writer -- sh -ec "head -c $bytes /dev/urandom > /files/blob-$name.bin"
before=$(k -n app get snapshots --no-headers | wc -l)
k apply -f - <<EOF
apiVersion: k8up.io/v1
kind: Backup
metadata: {name: $name, namespace: app}
spec:
  tags: [$name]
  podSecurityContext: {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000}
  backend:
    repoPasswordSecretRef: {name: backup-repo, key: password}
    s3:
      endpoint: http://minio.minio:9000
      bucket: k8up
      accessKeyIDSecretRef: {name: backup-credentials, key: username}
      secretAccessKeySecretRef: {name: backup-credentials, key: password}
EOF
top_sample app 90 >"$out/app-during.top" &
sampler=$!
pod=""
for _ in $(seq 1 120); do
  pod=$(k -n app get pods -l k8upjob=true --field-selector=status.phase=Running -o name | grep "backup-$name-0" | head -1 || true)
  [ -n "$pod" ] && break
  sleep 0.5
done
echo "victim=$pod" | tee "$out/victim.txt"
sleep "$kill_after"
# Take the object store away. It keeps its data in an emptyDir, so block
# ingress with a NetworkPolicy instead of stopping it.
k apply -f - <<EOF2
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: outage, namespace: minio}
spec: {podSelector: {}, policyTypes: [Ingress]}
EOF2
k -n app logs "$pod" --tail=8 >"$out/victim-before-kill.log" 2>&1 || true
k -n app delete "$pod" --grace-period=0 --force
echo "killed at $(date -u +%T)" | tee -a "$out/victim.txt"
sleep "$outage"
k -n app get backup "$name" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' | tee "$out/conditions-during-outage.txt"
k -n app get pods -l k8upjob=true | grep "backup-$name" | tee "$out/pods-during-outage.txt" || true
for p in $(k -n app get pods -l k8upjob=true -o name | grep "backup-$name"); do
  echo "== $p"; k -n app logs "$p" --tail=6 2>&1
done >"$out/job-logs-during-outage.txt"
k -n minio delete networkpolicy outage
echo "store restored at $(date -u +%T)" | tee -a "$out/victim.txt"
k8up_wait backup "$name" 900 | tee "$out/conditions-final.txt"
kill "$sampler" 2>/dev/null || true
after=$(k -n app get snapshots --no-headers | wc -l)
echo "snapshots before=$before after=$after" | tee "$out/snapshot-count.txt"
k -n app get snapshots -o custom-columns='ID:.spec.id,PATHS:.spec.paths,DATE:.spec.date' | tee "$out/snapshots.txt"
for p in $(k -n app get pods -l k8upjob=true -o name | grep "backup-$name"); do
  echo "== $p"; k -n app logs "$p" --tail=15 2>&1
done >"$out/job-logs.txt"
