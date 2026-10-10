#!/usr/bin/env bash
# Mount a PVC read-only in a short-lived pod and print its file manifest
# (sorted "sha256  path" lines, relative to the volume root).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
claim="$1" pod="inspect-$1"
k -n app delete pod "$pod" --ignore-not-found --wait >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $pod, namespace: app}
spec:
  securityContext: {runAsUser: 1000, runAsGroup: 1000}
  containers:
    - name: c
      image: busybox:1.37
      command: [sleep, "3600"]
      volumeMounts: [{name: v, mountPath: /v, readOnly: true}]
  volumes: [{name: v, persistentVolumeClaim: {claimName: $claim, readOnly: true}}]
EOF
k -n app wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null
k -n app exec "$pod" -- sh -c "cd /v && find . -type f -exec sha256sum {} + | sort -k2"
k -n app delete pod "$pod" --wait=false >/dev/null
