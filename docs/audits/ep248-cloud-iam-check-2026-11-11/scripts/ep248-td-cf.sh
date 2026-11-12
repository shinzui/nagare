#!/usr/bin/env bash
# Everything the zone stage created, by ID. The zone and its settings stay.
source "$(dirname "$0")/ep248-lib.sh"
Z=a0bc2ff68ebe0ae99b7f9864a2219722
A="https://api.cloudflare.com/client/v4"
c() { printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" | curl -sS --max-time 30 -K - "$@"; }
for id in $(c "$A/zones/$Z/dns_records?type=CNAME&per_page=50" | jq -r '.result[]|select(.content|endswith(".cfargotunnel.com"))|.id'); do
  c -X DELETE "$A/zones/$Z/dns_records/$id" -o /dev/null -w 'record delete %{http_code}\n'
done
RS="$(c "$A/zones/$Z/rulesets/phases/http_request_cache_settings/entrypoint" | jq -r '.result.id // empty')"
[ -z "$RS" ] || c -X DELETE "$A/zones/$Z/rulesets/$RS" -o /dev/null -w 'ruleset delete %{http_code}\n'
for t in $(c "$A/accounts/$CF_ACCOUNT_ID/cfd_tunnel?is_deleted=false&name=nagare-$CTX" | jq -r '.result[].id'); do
  c -X DELETE "$A/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$t/connections" -o /dev/null -w 'connections cleanup %{http_code}\n'
  c -X DELETE "$A/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$t" -o /dev/null -w 'tunnel delete %{http_code}\n'
done
log "records left: $(c "$A/zones/$Z/dns_records" | jq -c '.result|map(.name)')"
log "tunnels left: $(c "$A/accounts/$CF_ACCOUNT_ID/cfd_tunnel?is_deleted=false" | jq -c '.result|map(.name)')"
