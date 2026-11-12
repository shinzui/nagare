#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
export CLOUDSDK_ACTIVE_CONFIG_NAME=default
g() { gcloud "$@" --project "$PROJECT"; }
[ "$(git -C $HOME/Keikaku/bokuno/nagare rev-parse origin/master)" != "" ]
log "gate: $(cd $HOME/Keikaku/bokuno/nagare && just gate-verify "$REV" 2>&1 | tail -n 1 | cut -c1-120)"
g compute instances list --filter='name~ep248' --format='value(name)' | grep -q . && die "an ep248 instance exists"
g iam service-accounts list --filter='email:ep248*' --format='value(email)' | grep -q . && die "an ep248 service account exists"
g artifacts repositories list --location us-west1 --format='value(name)' 2>/dev/null | grep -qx ep248 && die "repository exists"
gcloud storage ls --project "$PROJECT" 2>/dev/null | grep -q ep248 && die "an ep248 bucket exists"
log "no ep248 resource exists in the project"
g compute instances list --format='value(name,status)' | sort > "$SP/ep248-vm-before.txt"
g compute images list --no-standard-images --filter='name~^nagare-image-' --format='value(name)' | sort > "$SP/ep248-images-before.txt"; wc -l < "$SP/ep248-images-before.txt" | tr -d ' ' | sed 's/^/nagare images before: /'
get() { printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" | curl -sS --max-time 20 -K - "https://api.cloudflare.com/client/v4$1"; }
get "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?is_deleted=false" | jq -r '"tunnels: \(.result|length)"'
get "/zones/$CF_ZONE_ID/dns_records" | jq -r '"dns records: \(.result|length)"'
get "/zones/$CF_ZONE_ID/rulesets/phases/http_request_cache_settings/entrypoint" | jq -r '"cache ruleset: \(.errors[0].code // "present")"'
log "operator pointer: $(cat "$HOME/.config/nagare/current-context"); active gcloud config: $(cat "$CLOUDSDK_CONFIG/active_config")"
test -s "$SECRETS/tailscale-authkey-ep248" && log "tailscale key present"
test -s "$NIX_BUILDER_SSH_KEY" && log "builder key present" || log "builder key NOT yet present"
