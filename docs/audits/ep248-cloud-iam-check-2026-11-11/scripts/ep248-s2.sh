#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
a="$(ssh-keygen -y -f "$NIX_BUILDER_SSH_KEY" | awk '{print $1,$2}')"; b="$(awk '{print $1,$2}' /etc/nix/builder_ed25519.pub)"; [ "$a" = "$b" ] || die "builder key does not match"
log "builder key matches"
[ ! -e "$RUN" ] || die "run root exists"
for p in contexts/$CTX.env hosts/$CTX cluster-secrets/$CTX pulumi/Pulumi.$CTX.yaml; do [ ! -e "$OPS/$p" ] || die "$OPS/$p exists"; done
umask 077
mkdir -p "$RUN/config/nagare" "$RUN/state" "$RUN/cache" "$RUN/evidence" "$RUN/reviews"
age-keygen -o "$AGE_KEY" >/dev/null 2>&1
recipient="$(age-keygen -y "$AGE_KEY")"
jq '.quota_project_id = "tan-nb-exp"' "$HOME/.config/gcloud/application_default_credentials.json" > "$SECRETS/ep248-adc.json"
CLOUDSDK_ACTIVE_CONFIG_NAME=default bash -c 'acct="$(gcloud config get-value account 2>/dev/null)"; gcloud config configurations create ep248 --no-activate >/dev/null 2>&1; CLOUDSDK_ACTIVE_CONFIG_NAME=ep248 gcloud config set account "$acct" >/dev/null 2>&1; CLOUDSDK_ACTIVE_CONFIG_NAME=ep248 gcloud config set project tan-nb-exp >/dev/null 2>&1'
log "scoped gcloud configuration: project $(env -u CLOUDSDK_CORE_PROJECT gcloud config get-value project 2>/dev/null); machine-wide active: $(cat "$CLOUDSDK_CONFIG/active_config")"
work="$(mktemp -d "$SECRETS/ep248-work.XXXXXX")"; trap 'rm -rf "$work"' EXIT
hs="$SECRETS/ep248-host-secrets.yaml"
printf 'creation_rules:\n  - age: %s\n' "$recipient" > "$work/sops.yaml"
printf 'tailscale:\n  authkey: %s\n' "$(cat "$SECRETS/tailscale-authkey-ep248")" > "$work/host.yaml"
sops --config "$work/sops.yaml" --encrypt --input-type yaml --output-type yaml "$work/host.yaml" > "$hs"
rm -f "$work/host.yaml"; grep -q 'ENC\[' "$hs" || die "host secrets are not encrypted"
"$PKG/bin/nagarectl" context create "$CTX" --project "$PROJECT" --base-domain "$BASE" --ingress cloudflare-tunnel --machine-type e2-standard-4 --artifact-registry-id ep248 --image-bucket tan-nb-exp-ep248-images --backup-bucket tan-nb-exp-ep248-backups --instance-name ep248-01 --service-account-id ep248-node --pulumi-backend local --inventory-store gcs --inventory-store-url gs://tan-nb-exp-ep248-state/inventory --acme-email ep248@topagentnetworklabs.com --acme-directory staging | cut -c1-120
ctx="$XDG_CONFIG_HOME/nagare/contexts/$CTX.env"
grep -E 'NAGARE_INGRESS|EXTERNAL_DOMAIN_TLS|BASE_DOMAIN' "$ctx" | cut -c1-80
"$PKG/bin/nagarectl" context create bad --mode local --ingress cloudflare-tunnel >/dev/null 2>"$RUN/evidence/refusal-local.txt" && die "a local tunnel was accepted" || log "refused as designed: $(tail -n 1 "$RUN/evidence/refusal-local.txt" | cut -c1-90)"
"$PKG/bin/nagarectl" context create bad2 --project x --ingress typo >/dev/null 2>"$RUN/evidence/refusal-typo.txt" && die "a typo was accepted" || log "refused as designed: $(tail -n 1 "$RUN/evidence/refusal-typo.txt" | cut -c1-90)"
rm -f "$XDG_CONFIG_HOME/nagare/contexts/bad.env" "$XDG_CONFIG_HOME/nagare/contexts/bad2.env"
"$PKG/bin/nagarectl" host init --context "$CTX" --ssh-public-key-file "$HOME/.ssh/id_ed25519.pub" --sops-file "$hs" 2>&1 | tail -n 1 | cut -c1-120
cs="$XDG_CONFIG_HOME/nagare/cluster-secrets/$CTX"; mkdir -p "$cs"
printf 'creation_rules:\n  - encrypted_regex: "^(data|stringData)$"\n    age: %s\n' "$recipient" > "$cs/.sops.yaml"
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin\n  namespace: monitoring\nstringData:\n  admin-user: admin\n  admin-password: %s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" > "$cs/grafana-admin.yaml"
sops --config "$cs/.sops.yaml" --encrypt --in-place "$cs/grafana-admin.yaml"
C="$XDG_CONFIG_HOME/nagare"
for pair in "contexts/$CTX.env" "hosts/$CTX" "cluster-secrets/$CTX"; do mv "$C/$pair" "$OPS/$pair"; ln -s "$OPS/$pair" "$C/$pair"; done
git -C "$OPS" add -N hosts/$CTX/flake.nix hosts/$CTX/flake.lock hosts/$CTX/host.nix hosts/$CTX/secrets.yaml
[ "$(cat "$HOME/.config/nagare/current-context")" = intranet ] || die "operator pointer moved"
log "step 2 ok; operator pointer intranet"
