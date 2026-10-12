#!/usr/bin/env bash
# MP-26 item 12: a release's upgrade rehearsal (EP-172) as one unattended command.
#
#   scripts/release-rehearse.sh REV PREV_VERSION
#
# It builds PREV_VERSION's packaged nagarectl (the published tag) and REV's, then runs
# scripts/transition-rehearsal.sh on a disposable local context in the Colima profile
# nagare-mp23, and writes the record a release binds to
# docs/release-evidence/<rev>/transition-rehearsal.json, uncommitted. An existing record is
# kept: only a green run writes one.
#
# Both CLIs are nix packages with every guard on. The rehearsal runs from an empty
# environment whose PATH holds only the operator tools below and no Helm, so the candidate
# must bring the tools it pins (F123). The source release gets nixpkgs' Helm from its own
# lock, as the installed release had on the intranet.
set -euo pipefail
[ $# = 2 ] || { echo "usage: release-rehearse REV PREV_VERSION" >&2; exit 2; }
repo="$(git rev-parse --show-toplevel)"
rev="$(git -C "$repo" rev-parse --verify "$1^{commit}")"
prev="${2#v}"
profile=nagare-mp23
socket="$HOME/.colima/$profile/docker.sock"
record="$repo/docs/release-evidence/$rev/transition-rehearsal.json"
log() { printf '%s release-rehearse: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

check_record() { # record
  python3 -I - "$1" "$rev" "$prev" <<'PY'
import json, sys
path, rev, prev = sys.argv[1:]
record = json.load(open(path))
assert record["candidate"]["revision"] == rev, record["candidate"]
assert record["source"]["version"] == prev, record["source"]
assert record["sentinel"]["seeded"] == record["sentinel"]["readBack"], record["sentinel"]
PY
}
if [ -e "$record" ]; then
  check_record "$record" || { echo "$record does not record a move from $prev to $rev" >&2; exit 1; }
  log "record exists: $record"
  exit 0
fi
work="$(mktemp -d /private/tmp/nagare-release-rehearse.XXXXXX)"
log "work $work; candidate $rev; source v$prev"

# --- the Colima profile, and a VM resolver that answers (a fresh VM's 192.168.5.3 does not) ---
colima status -p "$profile" >/dev/null 2>&1 || colima start -p "$profile" --activate=false
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | colima ssh -p "$profile" -- sudo tee /etc/resolv.conf >/dev/null

# --- the two packaged CLIs and the operator tools ---
source_flake="github:shinzui/nagare/v$prev"
candidate_flake="git+file://$repo?rev=$rev"
source_cli="$(nix build --no-link --print-out-paths "$source_flake#nagarectl")"
candidate_cli="$(nix build --no-link --print-out-paths "$candidate_flake#nagarectl")"
source_helm="$(nix build --no-link --print-out-paths --inputs-from "$source_flake" nixpkgs#kubernetes-helm)"
tool_path=""
for out in $(nix build --no-link --print-out-paths --inputs-from "$candidate_flake" \
  nixpkgs#{bash,coreutils,findutils,gnugrep,gnused,gawk,gnutar,gzip,curl,git,openssl,jq,python3,docker-client,k3d,kubectl,sops,age,skopeo,socat}); do
  [ -d "$out/bin" ] && tool_path="$tool_path${tool_path:+:}$out/bin"
done
tool_path="$tool_path:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$tool_path" command -v helm >/dev/null; then
  echo "the rehearsal PATH carries a helm; the candidate must bring its own" >&2; exit 1
fi
got="$("$candidate_cli/bin/nagarectl" version --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("revision"))')"
[ "$got" = "$rev" ] || { echo "the candidate nagarectl reports revision $got, not $rev" >&2; exit 1; }
mkdir -p "$work/bin"
printf '#!/bin/sh\nPATH=%s/bin:$PATH exec %s/bin/nagarectl "$@"\n' "$source_helm" "$source_cli" > "$work/bin/source-nagarectl"
chmod +x "$work/bin/source-nagarectl"

# --- the rehearsal, from an empty environment (no direnv context, payload root or kubeconfig) ---
env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" TMPDIR="${TMPDIR:-/tmp}" PATH="$tool_path" \
  DOCKER_HOST="unix://$socket" \
  NAGARE_REHEARSAL_SOURCE="$work/bin/source-nagarectl" \
  NAGARE_REHEARSAL_TARGET="$candidate_cli/bin/nagarectl" \
  NAGARE_REHEARSAL_ROOT="$work/run" \
  NAGARE_REHEARSAL_RESET=1 \
  bash "$repo/scripts/transition-rehearsal.sh" 2>&1 | tee "$work/rehearsal.log"

check_record "$work/run/evidence/transition-rehearsal.json"
mkdir -p "$(dirname "$record")"
cp "$work/run/evidence/transition-rehearsal.json" "$record"
log "transition rehearsal OK: $record"
