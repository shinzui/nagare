#!/usr/bin/env bash
# Deployment readiness can precede CA injection into the admission webhook.
# Exercise admission without persisting any resource or bypassing TLS checks.
set -euo pipefail

attempts="${NAGARE_CERT_MANAGER_API_MAX_ATTEMPTS:-30}"
delay="${NAGARE_CERT_MANAGER_API_RETRY_DELAY_SECONDS:-2}"
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid cert-manager API attempt count' >&2; exit 2; }
[[ "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo 'invalid cert-manager API retry delay' >&2; exit 2; }

for ((attempt=1; attempt<=attempts; attempt++)); do
  if output="$(kubectl create --dry-run=server --request-timeout=10s -f - 2>&1 <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  generateName: nagare-api-readiness-
spec:
  selfSigned: {}
YAML
  )"; then
    echo 'cert-manager API admission is ready'
    exit 0
  else
    status=$?
  fi

  # Restrict retries to the known cert-manager webhook bootstrap race. RBAC,
  # validation and unrelated API failures must remain immediate stop conditions.
  if [[ "$output" != *'webhook.cert-manager.io'* ]] ||
     ! [[ "$output" =~ (unknown\ authority|no\ endpoints\ available|connection\ refused|context\ deadline\ exceeded) ]]; then
    printf '%s\n' "$output" >&2
    exit "$status"
  fi
  if [ "$attempt" -eq "$attempts" ]; then
    printf '%s\ncert-manager API admission failed after %s attempts\n' "$output" "$attempt" >&2
    exit "$status"
  fi
  echo "cert-manager webhook trust/transport pending ($attempt/$attempts); retrying dry run" >&2
  sleep "$delay"
done
