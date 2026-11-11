#!/usr/bin/env bash
# EP-249 D6 step 1: render every fixture in a shell with no Nagare context (env -i, PATH only).
set -euo pipefail
R="$(cd "$(dirname "$0")" && pwd)"; F="$R/fixtures"; N="${NAGARE_DRILL_NAGARECTL:?}"
mkdir -p "$R/rendered"
for pair in app:app worker:worker site:docs site:rogue; do
  cmd="${pair%%:*}"; dir="${pair#*:}"
  ( cd "$F/$dir" && env -i PATH=/usr/bin:/bin "$N" "$cmd" render -f nagare/Config.hs --out "$R/rendered/$dir.json" ) > "$R/rendered/$dir.log" 2>&1 \
    || { echo "render $dir failed: $(tail -5 "$R/rendered/$dir.log")" >&2; exit 1; }
  echo "rendered $dir: $(jq -c '{contractVersion,document,kind,nagareVersion,configDigest}' "$R/rendered/$dir.json")"
done
