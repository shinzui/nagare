#!/usr/bin/env bash
# Create the disposable EP-163 prototype cluster. Refuses to reuse an existing
# cluster of the same name: a pre-existing mp24-eval is not ours by assumption.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
mkdir -p "$EVAL_STATE"

if k3d cluster list -o json | jq -e --arg n "$EVAL_CLUSTER" '.[] | select(.name == $n)' >/dev/null; then
  echo "refusing: k3d cluster $EVAL_CLUSTER already exists; prove its ownership first" >&2
  exit 1
fi

k3d cluster create "$EVAL_CLUSTER" \
  --servers 1 --agents 0 --no-lb \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-node-label "nagare.dev/owner=ep-163@server:0" \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false \
  --wait
k3d kubeconfig get "$EVAL_CLUSTER" >"$KUBECONFIG"
echo "$EVAL_CLUSTER created $(date -u +%FT%TZ) by EP-163" >"$EVAL_STATE/owner"
k get nodes -o wide
