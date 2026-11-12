#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
tx="$(N inventory status --json 2>/dev/null | jq -r .activeTransaction)"
[ "$tx" != null ] || die "no active transaction"
N inventory resume "$tx" --yes > "$RUN/evidence/resume-$tx.log" 2>&1 || { tail -n 10 "$RUN/evidence/resume-$tx.log" | cut -c1-220 >&2; die "resume did not converge"; }
tail -n 1 "$RUN/evidence/resume-$tx.log" | cut -c1-120
