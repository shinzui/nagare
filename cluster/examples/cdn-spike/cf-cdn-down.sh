#!/usr/bin/env bash
# cluster/examples/cdn-spike/cf-cdn-down.sh (EP-54 M2) — remove the Cloudflare
# proxy test artifacts: delete the proxied DNS record by name, and (optionally)
# clear the cache ruleset. Safe to re-run — a missing record is treated as
# already-gone.
#
# The SSL/TLS encryption mode is a zone SETTING, not a resource; this script
# does NOT touch it. If the zone is shared, record its original SSL mode before
# running cf-cdn-up.sh and restore it by hand here.
#
# Required env: CF_API_TOKEN, CF_HOST. Optional: CF_ZONE_ID (discovered from
# CF_HOST when absent), CF_CLEAR_RULESET=1 to also clear the cache ruleset.
set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:?set CF_API_TOKEN to a scoped Cloudflare API token}"
CF_HOST="${CF_HOST:?set CF_HOST to the proxied test hostname}"

API=https://api.cloudflare.com/client/v4
auth=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H 'Content-Type: application/json')

if [ -z "${CF_ZONE_ID:-}" ]; then
  reg_domain="$(echo "$CF_HOST" | awk -F. '{print $(NF-1)"."$NF}')"
  CF_ZONE_ID="$(curl -s "${API}/zones?name=${reg_domain}" "${auth[@]}" \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "${CF_ZONE_ID}" ] || { echo "could not discover zone id for ${reg_domain}; set CF_ZONE_ID" >&2; exit 1; }
fi

echo "==> delete proxied A record ${CF_HOST}"
rec_id="$(curl -s "${API}/zones/${CF_ZONE_ID}/dns_records?type=A&name=${CF_HOST}" "${auth[@]}" \
  | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
if [ -n "${rec_id}" ]; then
  curl -s -X DELETE "${API}/zones/${CF_ZONE_ID}/dns_records/${rec_id}" "${auth[@]}"
  echo
else
  echo "    (no record found — already gone)"
fi

# Optionally clear the cache ruleset (PUT an empty rules array).
if [ "${CF_CLEAR_RULESET:-0}" = "1" ]; then
  echo "==> clear http_request_cache_settings ruleset"
  curl -s -X PUT \
    "${API}/zones/${CF_ZONE_ID}/rulesets/phases/http_request_cache_settings/entrypoint" \
    "${auth[@]}" --data '{"rules":[]}'
  echo
fi

echo "Reminder: the SSL/TLS mode was NOT changed; restore it by hand if needed."
