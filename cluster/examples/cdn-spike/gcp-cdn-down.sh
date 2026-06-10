#!/usr/bin/env bash
# cluster/examples/cdn-spike/gcp-cdn-down.sh (EP-54 M1) — delete every cdn-spike-*
# Google load-balancer object in reverse dependency order. Run this before
# leaving the spike: the global IP and forwarding rules are BILLABLE.
#
# Safe to run even after a partial gcp-cdn-up.sh: every delete is --quiet and
# the optional HTTPS objects (only created once origin TLS is on) tolerate
# absence via `|| true`.
set -euo pipefail

# --- Project isolation preflight (CLAUDE.md): refuse to run outside tan-nb-exp ---
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi

ZONE=us-west1-a
IG=cdn-spike-ig
HC=cdn-spike-hc
BES=cdn-spike-bes
UM=cdn-spike-um
PROXY=cdn-spike-proxy
FR=cdn-spike-fr
IP=cdn-spike-ip

g() { gcloud "$@" --project="$PROJECT"; }
# del tolerates a missing object so the teardown is safe to re-run.
del() { echo "==> delete: $*"; g "$@" --quiet || true; }

# Reverse dependency order: forwarding rules -> proxies -> cert -> url map ->
# backend service -> health check -> instance group -> global IP.
del compute forwarding-rules delete "$FR" --global
del compute forwarding-rules delete cdn-spike-fr-https --global
del compute target-http-proxies delete "$PROXY"
del compute target-https-proxies delete cdn-spike-hproxy
del compute ssl-certificates delete cdn-spike-cert --global
del compute url-maps delete "$UM"
del compute backend-services delete "$BES" --global
del compute health-checks delete "$HC"
del compute instance-groups unmanaged delete "$IG" --zone="$ZONE"
del compute addresses delete "$IP" --global

echo
echo "Verify no cdn-spike-* resources remain:"
echo "  gcloud compute forwarding-rules list --global --project=${PROJECT}"
g compute forwarding-rules list --global --filter='name~cdn-spike' \
  --format='value(name)' || true
