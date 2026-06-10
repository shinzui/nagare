#!/usr/bin/env bash
# cluster/examples/cdn-spike/cf-cdn-up.sh (EP-54 M2) — front the VM with a
# Cloudflare proxy via the Cloudflare HTTP API to prove proxied host-routing,
# the origin-TLS mode, and a cache HIT. NOT production code — the production
# client is Nagare.Cdn.Cloudflare (EP-57); this script's three API calls are the
# verified shapes of upsertProxiedRecord / setOriginTlsMode / applyCacheRules.
#
# Reads exactly the credential shape EP-57 will read:
#   CF_API_TOKEN  (required) scoped token: Zone:DNS:Edit + Zone:Cache Rules:Edit.
#   CF_ZONE_ID    (optional) zone id; discovered from CF_HOST's registrable
#                 domain when absent.
#   CF_HOST       (required) the proxied test hostname (must match a Knative
#                 DomainMapping / the Host Kourier expects).
#   ORIGIN_IP     (required) the VM's public IP (pulumi stack output publicIp).
#   CF_SSL_MODE   (optional) off|flexible|full|strict; default "flexible" for
#                 the HTTP-first origin. The steady-state default is "strict"
#                 (Full strict) once the origin serves the LE wildcard on 443.
#   CF_CACHE_PREFIX (optional) path prefix to force-cache; default "/assets/".
#   CF_CACHE_TTL  (optional) edge TTL seconds for that prefix; default 31536000.
set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:?set CF_API_TOKEN to a scoped Cloudflare API token}"
CF_HOST="${CF_HOST:?set CF_HOST to the proxied test hostname}"
ORIGIN_IP="${ORIGIN_IP:?set ORIGIN_IP to the VM public IP (pulumi -C infra/pulumi stack output publicIp)}"
CF_SSL_MODE="${CF_SSL_MODE:-flexible}"
CF_CACHE_PREFIX="${CF_CACHE_PREFIX:-/assets/}"
CF_CACHE_TTL="${CF_CACHE_TTL:-31536000}"

API=https://api.cloudflare.com/client/v4
auth=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H 'Content-Type: application/json')

# Discover the zone id from CF_HOST's registrable domain when not supplied.
# (Registrable domain = the last two labels; good enough for the spike. EP-57
# does the proper longest-suffix match against the account's zones.)
if [ -z "${CF_ZONE_ID:-}" ]; then
  reg_domain="$(echo "$CF_HOST" | awk -F. '{print $(NF-1)"."$NF}')"
  echo "==> discovering zone id for ${reg_domain}"
  CF_ZONE_ID="$(curl -s "${API}/zones?name=${reg_domain}" "${auth[@]}" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "${CF_ZONE_ID}" ] || { echo "could not discover zone id for ${reg_domain}; set CF_ZONE_ID" >&2; exit 1; }
fi
echo "    zone id: ${CF_ZONE_ID}"

# 1. Upsert a proxied (orange-cloud) A record CF_HOST -> ORIGIN_IP. The
#    load-bearing field is "proxied":true. If a record already exists, PATCH it
#    rather than POST a duplicate (Cloudflare rejects duplicate A records).
echo "==> upsert proxied A record ${CF_HOST} -> ${ORIGIN_IP}"
rec_id="$(curl -s "${API}/zones/${CF_ZONE_ID}/dns_records?type=A&name=${CF_HOST}" "${auth[@]}" \
  | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
body="{\"type\":\"A\",\"name\":\"${CF_HOST}\",\"content\":\"${ORIGIN_IP}\",\"proxied\":true,\"ttl\":1}"
if [ -n "${rec_id}" ]; then
  curl -s -X PATCH "${API}/zones/${CF_ZONE_ID}/dns_records/${rec_id}" "${auth[@]}" --data "${body}"
else
  curl -s -X POST  "${API}/zones/${CF_ZONE_ID}/dns_records" "${auth[@]}" --data "${body}"
fi
echo

# 2. Set the zone SSL/TLS encryption (origin-TLS) mode.
echo "==> set SSL mode = ${CF_SSL_MODE}"
curl -s -X PATCH "${API}/zones/${CF_ZONE_ID}/settings/ssl" "${auth[@]}" \
  --data "{\"value\":\"${CF_SSL_MODE}\"}"
echo

# 3. Force-cache the static path prefix with an edge TTL (Rulesets API,
#    http_request_cache_settings phase) — the operation EP-57.applyCacheRules
#    performs. PUT replaces the phase entrypoint ruleset (idempotent).
echo "==> cache rule: force-cache ${CF_CACHE_PREFIX} for ${CF_CACHE_TTL}s"
curl -s -X PUT \
  "${API}/zones/${CF_ZONE_ID}/rulesets/phases/http_request_cache_settings/entrypoint" \
  "${auth[@]}" \
  --data "{\"rules\":[{\"expression\":\"(starts_with(http.request.uri.path, \\\"${CF_CACHE_PREFIX}\\\"))\",\"action\":\"set_cache_settings\",\"action_parameters\":{\"cache\":true,\"edge_ttl\":{\"mode\":\"override_origin\",\"default\":${CF_CACHE_TTL}}}}]}"
echo

cat <<EOF

cdn-spike Cloudflare proxy is up for ${CF_HOST}.

Prove proxied routing + a cache HIT (second request MISS -> HIT):
  curl -sI "https://${CF_HOST}/" | grep -i -E 'http/|cf-cache-status'
  curl -sI "https://${CF_HOST}${CF_CACHE_PREFIX}<asset>"
  curl -sI "https://${CF_HOST}${CF_CACHE_PREFIX}<asset>"   # expect cf-cache-status: HIT

TEAR DOWN WHEN DONE:
  CF_HOST=${CF_HOST} cluster/examples/cdn-spike/cf-cdn-down.sh
EOF
