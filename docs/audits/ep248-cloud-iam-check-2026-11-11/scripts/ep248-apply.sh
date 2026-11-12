#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
n="$1"; review="$RUN/reviews/s$n"; l="$review.apply.log"
[ -f "$review/review.json" ] || die "no review $n"; [ ! -e "$l" ] || die "$l exists"
log "apply $n"
N platform bootstrap apply "$review" --yes > "$l" 2>&1 || { tail -n 12 "$l" | cut -c1-240 >&2; die "apply $n did not converge"; }
tail -n 1 "$l" | cut -c1-90
gcloud compute instances list --project "$PROJECT" --format='value(name,status)' | sort | grep -vE 'nix-builder-x86|ep248-01' > "$RUN/evidence/others-$n.txt"
diff <(grep -vE 'nix-builder-x86' "$SP/ep248-vm-before.txt") "$RUN/evidence/others-$n.txt" >/dev/null || die "another VM changed state"
[ "$(cat "$HOME/.config/nagare/current-context")" = intranet ] || die "operator pointer moved"
C="$XDG_CONFIG_HOME/nagare/pulumi/Pulumi.$CTX.yaml"; if [ -f "$C" ] && [ ! -L "$C" ]; then mv "$C" "$OPS/pulumi/Pulumi.$CTX.yaml"; ln -s "$OPS/pulumi/Pulumi.$CTX.yaml" "$C"; fi
