#!/usr/bin/env bash
# MP-33 batched local confirmation: render with no context, then phases 1-7, each from env -i.
# Stops at the first failure; every phase's transcript is evidence/pN.log.
set -euo pipefail
R="$(cd "$(dirname "$0")" && pwd)"; mkdir -p "$R/evidence"
NAGARE_DRILL_NAGARECTL="$(cat "$R/nagarectl.path")" bash "$R/render.sh" > "$R/evidence/p0-render.log" 2>&1
echo "p0 render ok"
for p in 1 2 3 4 5 6 7; do
  if env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" USER="$USER" LANG=en_US.UTF-8 bash "$R/p$p.sh" > "$R/evidence/p$p.log" 2>&1; then
    echo "p$p ok"
  else
    echo "p$p FAILED"; tail -15 "$R/evidence/p$p.log"; exit 1
  fi
done
echo "all phases passed"
