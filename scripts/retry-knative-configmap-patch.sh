#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 CONFIGMAP KUBECTL_PATCH_ARGUMENT..." >&2
}

if [ "$#" -lt 2 ]; then
  usage
  exit 2
fi

configmap="$1"
shift

max_attempts="${NAGARE_KNATIVE_PATCH_MAX_ATTEMPTS:-5}"
retry_delay="${NAGARE_KNATIVE_PATCH_RETRY_DELAY_SECONDS:-2}"

if ! [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]]; then
  echo "NAGARE_KNATIVE_PATCH_MAX_ATTEMPTS must be a positive integer" >&2
  exit 2
fi

if ! [[ "$retry_delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "NAGARE_KNATIVE_PATCH_RETRY_DELAY_SECONDS must be a nonnegative number" >&2
  exit 2
fi

attempt=1
while true; do
  if kubectl -n knative-serving patch configmap "$configmap" "$@"; then
    exit 0
  else
    status=$?
  fi

  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Knative ConfigMap $configmap patch failed after $attempt attempts" >&2
    exit "$status"
  fi

  echo "Knative ConfigMap $configmap patch failed on attempt $attempt/$max_attempts; retrying" >&2
  sleep "$retry_delay"
  attempt=$((attempt + 1))
done
