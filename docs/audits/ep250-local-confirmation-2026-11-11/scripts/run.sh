#!/usr/bin/env bash
# EP-250 D6: a fresh disposable context whose auth plane is this tree's (the enforcer built from it,
# En and Shomei unchanged, all tagged ep250); EP-248's P1-P4 deploy protected sites from the deployer
# Pod; P8 checks inheritance. Every phase from env -i; stops at the first failure.
set -euo pipefail
A=$HOME/Keikaku/bokuno/nagare/docs/audits/ep248-local-confirmation-2026-11-11/scripts
B=$(cd "$(dirname "$0")" && pwd)
R=$HOME/.local/state/nagare/drills/ep248
PKG="$(cat "$R.pkg250-path")"; REV="$(cat "$R/revision")"
O=$HOME/.local/state/nagare/drills/ep248-rehearsal
[ ! -e "${R}-ep248-final" ] && mv "$R" "${R}-ep248-final"
mkdir -p "$R/evidence"; cp -R "$O/fixtures" "$O/rendered" "$R/"; cp "$O/hello-v1.tar" "$O/docs-pod.tar" "$O/serve.sh" "$R/"
printf '%s\n' "$REV" > "$R/revision"; printf '%s/bin/nagarectl\n' "$PKG" > "$R/nagarectl.path"
clean() { env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" USER="$USER" LANG=en_US.UTF-8 "$@"; }
clean BOOTSTRAP_NAGARECTL="$PKG" BOOTSTRAP_IMAGE_TAG=ep250 bash "$A/bootstrap.sh" > "$R/bootstrap.log" 2>&1 || { echo "bootstrap FAILED"; tail -5 "$R/bootstrap.log"; exit 1; }
echo "bootstrap ok"
for p in "$A/p1.sh" "$A/p2.sh" "$A/p3.sh" "$A/p4.sh" "$B/p8.sh"; do
  n="$(basename "$p" .sh)"
  if clean bash "$p" > "$R/evidence/$n.log" 2>&1; then echo "$n ok"; else echo "$n FAILED"; tail -20 "$R/evidence/$n.log"; exit 1; fi
done
echo "all phases passed"
