#!/usr/bin/env bash
# cluster/examples/cdn-spike/gcp-cdn-down.sh (EP-54 M1) — delete every cdn-spike-*
# Google load-balancer object in reverse dependency order. Run this before
# leaving the spike: the global IP and forwarding rules are BILLABLE.
#
# Safe to run even after a partial gcp-cdn-up.sh: every delete is --quiet and
# the optional HTTPS objects (only created once origin TLS is on) tolerate
# absence via `|| true`.
set -euo pipefail

# Load the target profile and run the configurable, fail-closed project-isolation
# preflight (EP-60). Exports TARGET_PROJECT / TARGET_ZONE.
source "$(cd "$(dirname "$0")/../../../scripts" && pwd)/lib/target.sh"
_require_target_project
PROJECT="$TARGET_PROJECT"

ZONE="$TARGET_ZONE"
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
