#!/usr/bin/env bash
# Issue (or rotate) the deployer bundle into a new directory: ep248-cred.sh NAME
source "$(dirname "$0")/ep248-lib.sh"
B="$RUN/bundles/$1"; mkdir -p "$RUN/bundles"; [ ! -e "$B" ] || die "$B exists"
N delegation credentials ep248ci --out "$B" --duration 24h --contract 1 > "$RUN/evidence/credentials-$1.json" 2> "$RUN/evidence/credentials-$1.err" || { tail -n 12 "$RUN/evidence/credentials-$1.err" | cut -c1-220 >&2; die "credentials refused"; }
jq -c '{files: [.files[]?|(.path // .)], keyId: (.cloudKeyId // .keyId // .cloud.keyId), expires: (.tokenExpiry // .expiresAt)}' "$RUN/evidence/credentials-$1.json" | cut -c1-300
find "$B" -type f | sed "s#$B/##" | sort
