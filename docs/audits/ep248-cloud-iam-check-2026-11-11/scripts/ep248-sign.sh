#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
TS=/nix/store/74ladz50vzkifs07q4lxccs7jdqjn4fk-tailscale-1.102.3/bin/tailscale
listed="$("$TS" lock status 2>/dev/null | awk '$1 ~ /^ep248-nagare(-[0-9]+)?\./ {print $NF}' || true)"
[[ "$listed" =~ ^nodekey:[0-9a-f]{64}$ ]] || die "ep248-nagare is not listed as locked out"
W="$(N platform root --json 2>"$RUN/evidence/root.err" | jq -er '.workspaceRoot // .root')" || { cut -c1-200 "$RUN/evidence/root.err" >&2; die "no workspace root"; }
cd "$W"
self="$("$W/scripts/iap-ssh.sh" ssh ep248-01 -- "sudo -n tailscale status --json | jq -r .Self.PublicKey" 2>"$RUN/evidence/self.err" | tail -n 1)" || true
[ "$listed" = "$self" ] || { tail -n 4 "$RUN/evidence/self.err" | cut -c1-200 >&2; die "the listed key is not this VM's own"; }
"$TS" lock sign "$listed" >/dev/null 2>"$RUN/evidence/sign.err" || { cut -c1-200 "$RUN/evidence/sign.err" >&2; die "sign refused"; }
sleep 8
"$TS" lock status 2>/dev/null | grep -q "ep248-nagare.*${listed:0:20}" && die "still locked out"
log "signed exactly ep248-nagare (${self:0:16}…)"
