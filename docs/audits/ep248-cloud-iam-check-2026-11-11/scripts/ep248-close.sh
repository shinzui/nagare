#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
n="$1"; review="$RUN/reviews/s$n"
tx="$(N inventory status --json 2>/dev/null | jq -r .activeTransaction)"
[ "$tx" != null ] || die "no active transaction"
sha="$(cat "$review/review.sha256" 2>/dev/null || shasum -a 256 "$review/review.json" | cut -d' ' -f1)"
log "closing $tx with review $sha"
N inventory close "$tx" --review "$sha" > "$RUN/evidence/close-$tx.log" 2>&1 || { tail -n 14 "$RUN/evidence/close-$tx.log" | cut -c1-220 >&2; die "close refused"; }
tail -n 6 "$RUN/evidence/close-$tx.log" | cut -c1-200
