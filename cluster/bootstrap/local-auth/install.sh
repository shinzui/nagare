#!/usr/bin/env bash
# Install the nagare auth plane (Shomei, en, nagare-access) on the local k3d
# cluster in NAGARE_MODE=local (MasterPlan 16 / EP-85).
#
# This is the "validated explicit path" the EP-85 plan describes: the cloud
# bootstrap manifests under cluster/bootstrap/{shomei,en,nagare-access}/ are the
# bases, applied unchanged, then the three differences for local mode are layered
# on as imperative overrides:
#   1. images  -> the local registry ($NAGARE_REGISTRY_HOST/<svc>:<tag>)
#   2. nagare-access NAGARE_ACCESS_COOKIE_DOMAIN -> the loopback parent domain
#      (.$NAGARE_BASE_DOMAIN) so a single sign-in covers every local app
#   3. Shomei WebAuthn relying-party settings -> the loopback HTTPS app origin
#
# A kustomize overlay was considered but cannot aggregate these bases: every base
# file redundantly declares `Namespace: nagare-system`, which kustomize rejects as
# a duplicate resource id, and removing those namespace docs would change the
# cloud apply path (forbidden by the MasterPlan). Imperative overrides keep the
# cloud bases byte-for-byte unchanged.
#
# Idempotent: safe to re-run. Requires the local profile sourced (NAGARE_MODE,
# NAGARE_REGISTRY_HOST, NAGARE_BASE_DOMAIN) and the three images already built and
# pushed by cluster/bootstrap/auth-images/build-local-image.sh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_dir="$(cd "$script_dir/.." && pwd)"

mode="${NAGARE_MODE:-cloud}"
if [[ "$mode" != "local" ]]; then
  echo "error: install.sh is local-mode only (NAGARE_MODE=local); got NAGARE_MODE=$mode" >&2
  exit 2
fi

registry="${NAGARE_REGISTRY_HOST:?NAGARE_REGISTRY_HOST must be set in local mode}"
base="${NAGARE_BASE_DOMAIN:?NAGARE_BASE_DOMAIN must be set in local mode}"
tag="${NAGARE_AUTH_TAG:-dev}"
ns=nagare-system

# The protected-hello example's public host is protected-hello.<base> (its
# Config derives the domain from NAGARE_BASE_DOMAIN). The WebAuthn origin must be
# that exact HTTPS origin; the cookie domain is the loopback parent so one
# sign-in covers every protected app under the base domain.
app_origin="https://protected-hello.${base}"
cookie_domain=".${base}"

echo "==> auth-plane local install: registry=$registry base=$base tag=$tag"

# 1) nagare-access cookie-signing key Secret — generate a real value once.
if ! kubectl -n "$ns" get secret nagare-access >/dev/null 2>&1; then
  echo "==> creating nagare-access cookie-key Secret"
  kubectl -n "$ns" create secret generic nagare-access \
    --from-literal=cookie-key="$(openssl rand -base64 48)"
else
  echo "==> nagare-access Secret already present (left as-is)"
fi

# 2) ConfigMaps: en authorization schema + the (initially empty) backends map.
kubectl apply -f "$bootstrap_dir/en/configmap.yaml"
kubectl apply -f "$bootstrap_dir/nagare-access/configmap.yaml"

# 3) en schema migration must run BEFORE en-server starts (en does not self-migrate).
kubectl apply -f "$bootstrap_dir/en/migrations.yaml"
echo "==> waiting for en-migrate Job to complete"
kubectl -n "$ns" wait --for=condition=complete job/en-migrate --timeout=180s

# 4) Workloads (apply the cloud bases, then override image + local env).
kubectl apply -f "$bootstrap_dir/shomei/service.yaml"
kubectl apply -f "$bootstrap_dir/en/service.yaml"
kubectl apply -f "$bootstrap_dir/nagare-access/service.yaml"

# 4a) local-registry images
kubectl -n "$ns" set image deployment/shomei "shomei=${registry}/shomei:${tag}"
kubectl -n "$ns" set image deployment/en "en=${registry}/en:${tag}"
kubectl -n "$ns" patch ksvc nagare-access --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${registry}/nagare-access:${tag}\"}]"

# 4b) local env: Shomei WebAuthn RP/origins + nagare-access loopback cookie domain
kubectl -n "$ns" set env deployment/shomei \
  "SHOMEI_WEBAUTHN_RP_ID=${base}" \
  "SHOMEI_WEBAUTHN_ORIGINS=${app_origin}"
# Cookie domain is env index 5 in nagare-access/service.yaml (the Knative
# container is unnamed, so a name-keyed strategic merge cannot match it).
kubectl -n "$ns" patch ksvc nagare-access --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/5/value\",\"value\":\"${cookie_domain}\"}]"

echo "==> waiting for rollouts"
kubectl -n "$ns" rollout status deploy/shomei --timeout=180s
kubectl -n "$ns" rollout status deploy/en --timeout=180s
kubectl -n "$ns" get ksvc nagare-access

echo "==> auth plane installed in local mode"
