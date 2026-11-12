#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
d="$RUN/reviews/delegation-revoke"; rm -rf "$d"
N delegation revoke ep248ci --save-plan "$d" > "$RUN/evidence/delegation-revoke.log" 2>&1 || { tail -n 12 "$RUN/evidence/delegation-revoke.log" | cut -c1-220 >&2; die "revoke refused"; }
log "revoke review: $(jq '.operations|length' "$d/review.json") operations"
N inventory apply "$d" --yes >> "$RUN/evidence/delegation-revoke.log" 2>&1 || { tail -n 12 "$RUN/evidence/delegation-revoke.log" | cut -c1-220 >&2; die "revoke apply did not converge"; }
tail -n 1 "$RUN/evidence/delegation-revoke.log" | cut -c1-120
N delegation show ep248ci --contract 1 | jq -c '{name,state,revision: .acceptedRevision}'
