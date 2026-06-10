#!/usr/bin/env bash
# cluster/examples/cdn-spike/gcp-cdn-up.sh (EP-54 M1) — stand up a throwaway
# Google Cloud CDN load balancer in front of nagare-01 to prove host-routing,
# edge TLS, and a cache HIT. Throwaway: every object is named cdn-spike-* and
# is removed by gcp-cdn-down.sh. NOT production code — the production topology
# is built by the Pulumi NagareCdn component (EP-56).
#
# Why each object exists (Google external HTTP(S) LB, the shape EP-56 encodes):
#   instance group  — wraps the single VM with named ports http:80/https:443 so
#                      a backend service can target it.
#   health check    — probes Kourier on a KNOWN-GOOD app path WITH the app Host
#                      header, because Kourier answers an unmatched Host on GET /
#                      with 404, which would mark the backend UNHEALTHY.
#   backend service — CDN-enabled (--enable-cdn); forwards the client's original
#                      Host header unchanged (LB default) so Knative still routes.
#   url map         — routes all paths to the backend service.
#   target proxy    — terminates the client connection (HTTP here; HTTPS + a
#                      Google-managed cert is the once-origin-TLS-on path).
#   global IP       — the anycast IPv4 CDN-enabled hostnames resolve to.
#   forwarding rule — binds the global IP:80 to the target proxy.
#
# Idempotent: each create tolerates an already-existing object (re-run safe).
# The global IP and load balancer are BILLABLE — run gcp-cdn-down.sh when done.
#
# Required env:
#   HC_HOST   Host header / hostname the health check and your curl tests use
#             (a known Knative ksvc host, e.g. notes.personal.apps.example.com).
#   HC_PATH   Health-check request path (default "/"). Use a known-good app path
#             if GET / under HC_HOST does not return 2xx/3xx.
set -euo pipefail

# Load the target profile and run the configurable, fail-closed project-isolation
# preflight (EP-60). Exports TARGET_PROJECT / TARGET_ZONE.
source "$(cd "$(dirname "$0")/../../../scripts" && pwd)/lib/target.sh"
_require_target_project
PROJECT="$TARGET_PROJECT"

HC_HOST="${HC_HOST:?set HC_HOST to a known Knative ksvc hostname (e.g. notes.personal.apps.example.com)}"
HC_PATH="${HC_PATH:-/}"

ZONE="$TARGET_ZONE"
IG=cdn-spike-ig
HC=cdn-spike-hc
BES=cdn-spike-bes
UM=cdn-spike-um
PROXY=cdn-spike-proxy
FR=cdn-spike-fr
IP=cdn-spike-ip

g() { gcloud "$@" --project="$PROJECT"; }

# Run a create, but treat "already exists" as success so the script is re-runnable.
create() {
  local desc="$1"; shift
  echo "==> ${desc}"
  if ! "$@" 2> >(tee /tmp/cdn-spike-gerr >&2); then
    if grep -qiE 'already exists' /tmp/cdn-spike-gerr; then
      echo "    (already exists — continuing)"
    else
      return 1
    fi
  fi
}

# 1. Unmanaged zonal instance group containing the VM, with named ports.
create "instance group ${IG}" \
  g compute instance-groups unmanaged create "$IG" --zone="$ZONE"
create "add nagare-01 to ${IG}" \
  g compute instance-groups unmanaged add-instances "$IG" \
    --instances=nagare-01 --zone="$ZONE"
echo "==> set named ports http:80,https:443 on ${IG}"
g compute instance-groups unmanaged set-named-ports "$IG" \
  --named-ports=http:80,https:443 --zone="$ZONE"

# 2. Health check. Probe Kourier on port 80 with the app Host header so an
#    unmatched-Host 404 does not mark the backend UNHEALTHY.
create "health check ${HC}" \
  g compute health-checks create http "$HC" \
    --port=80 --request-path="$HC_PATH" --host="$HC_HOST"

# 3. CDN-enabled backend service + backend.
create "backend service ${BES} (CDN enabled)" \
  g compute backend-services create "$BES" \
    --global --protocol=HTTP --port-name=http \
    --health-checks="$HC" --enable-cdn
create "add backend ${IG} to ${BES}" \
  g compute backend-services add-backend "$BES" \
    --global --instance-group="$IG" --instance-group-zone="$ZONE"

# 4. URL map + HTTP target proxy + global IP + forwarding rule.
create "url map ${UM}" \
  g compute url-maps create "$UM" --default-service="$BES"
create "target HTTP proxy ${PROXY}" \
  g compute target-http-proxies create "$PROXY" --url-map="$UM"
create "global address ${IP}" \
  g compute addresses create "$IP" --global
create "forwarding rule ${FR} (:80)" \
  g compute forwarding-rules create "$FR" \
    --global --target-http-proxy="$PROXY" --address="$IP" --ports=80

LB_IP="$(g compute addresses describe "$IP" --global --format='value(address)')"
CDN_ON="$(g compute backend-services describe "$BES" --global --format='value(enableCDN)')"

cat <<EOF

cdn-spike Google load balancer is up.
  global IP (lbIp) : ${LB_IP}
  enableCDN        : ${CDN_ON}

Prove a routed response (Host header preserved) and a cache HIT:
  curl -s -o /dev/null -w '%{http_code}\\n' \\
    --resolve ${HC_HOST}:80:${LB_IP} http://${HC_HOST}/
  curl -sI --resolve ${HC_HOST}:80:${LB_IP} http://${HC_HOST}/<static-asset>
  curl -sI --resolve ${HC_HOST}:80:${LB_IP} http://${HC_HOST}/<static-asset>   # expect non-zero age:

Check backend health (can take a few minutes to go HEALTHY):
  gcloud compute backend-services get-health ${BES} --global --project=${PROJECT}

TEAR DOWN WHEN DONE (the global IP is billable):
  cluster/examples/cdn-spike/gcp-cdn-down.sh
EOF
