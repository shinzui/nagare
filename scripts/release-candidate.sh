#!/usr/bin/env bash
# MP-26 item 11: everything up to the tag, unattended (docs/runbooks/releases.md). The release
# gate, the transition rehearsal from the newest release the candidate accepts, both systems'
# native attachments (aarch64-darwin here, x86_64-linux in an amd64 Apple container), and
# two assemblies that must be byte-identical. The release gate runs alongside the other steps.
# Then the rehearsal record is committed on
# origin/master and landed. Every step stops at its first failure; nothing is retried.
# `just release-publish VERSION` takes the run from here.
#
# --rehearsal runs every step for an already tagged or unreleased revision but lands nothing
# and leaves the run where release-publish does not look.
set -euo pipefail

usage() { echo "usage: $0 VERSION [--revision REV] [--rehearsal]" >&2; exit 2; }
die() { printf 'release-candidate: %s\n' "$*" >&2; exit 1; }
step() { printf '%s release-candidate: %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

[[ $# -ge 1 ]] || usage
version="$1"
shift
revision=HEAD
rehearsal=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --revision) [[ $# -ge 2 ]] || usage; revision="$2"; shift 2 ;;
    --rehearsal) rehearsal=true; shift ;;
    *) usage ;;
  esac
done
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "VERSION must be an unpadded major.minor.patch version"

repo="$(git rev-parse --show-toplevel)"
cd "$repo"
rev="$(git rev-parse --verify "$revision^{commit}")"
state="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/releases"
image=nixos/nix:2.35.2

# --- preflight: everything that can refuse without building ---
[[ "$(nix eval --impure --raw --expr builtins.currentSystem)" == aarch64-darwin ]] \
  || die "run it on the aarch64-darwin workstation; the x86_64-linux attachments come from an Apple container"
metadata="$(git show "$rev:release.json")"
[[ "$(jq -r .platformVersion <<<"$metadata")" == "$version" ]] \
  || die "release.json at $rev is not $version; land chore(release): prepare v$version first"
[[ "$(jq -c '.supportedSystems | sort' <<<"$metadata")" == '["aarch64-darwin","x86_64-linux"]' ]] \
  || die "release.json at $rev names systems this command does not build"
git fetch -q origin master --tags
git merge-base --is-ancestor "$rev" origin/master || die "$rev is not on origin/master; land the candidate first"
if ! $rehearsal; then
  ! git rev-parse -q --verify "refs/tags/v$version" >/dev/null || die "v$version is already tagged"
fi
# The rehearsal starts from the newest release the candidate accepts a transition from.
previous="$(jq -r '.transitionsFrom[]' <<<"$metadata" | sort -V | tail -1)"
[[ -n "$previous" ]] || die "release.json at $rev accepts no transition"
git rev-parse -q --verify "refs/tags/v$previous" >/dev/null || die "v$previous, the newest accepted source, is not a published tag"
command -v container >/dev/null || die "Apple container is not installed"

run="$state/v$version/$($rehearsal && echo rehearsal-)$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$run"
worktree="$run/worktree"
evidence="$run/evidence"
gate=""
cleanup() {
  [[ -z "$gate" ]] || kill "$gate" 2>/dev/null || true
  git -C "$repo" worktree remove --force "$worktree" 2>/dev/null || true
  git -C "$repo" worktree remove --force "$evidence" 2>/dev/null || true
}
trap cleanup EXIT
step "v$version at $rev from v$previous; run directory $run"

# --- 1. the release gate, in parallel with steps 2-5 (it works on the builder, they mostly
# work here); its result is required before anything lands ---
step "release gate (in the background, log $run/gate-release.log)"
just gate-release "$rev" > "$run/gate-release.log" 2>&1 &
gate=$!

# --- 2. the transition rehearsal ---
step "transition rehearsal from v$previous"
just release-rehearse "$rev" "$previous"
record="docs/release-evidence/$rev/transition-rehearsal.json"
[[ -f "$record" ]] || die "release-rehearse left no $record"
cp "$record" "$run/transition-rehearsal.json"

# --- 3. aarch64-darwin attachments, from a clean worktree of the candidate ---
step "aarch64-darwin attachments"
git worktree add -q --detach "$worktree" "$rev"
(cd "$worktree" && scripts/release-native.sh "$version" "$run/native/aarch64-darwin")

# --- 4. x86_64-linux attachments, in an amd64 Apple container under Rosetta ---
# The work root is the container's only mount and persists across releases, so the file cache
# of builder outputs is reused. Each run gets a fresh VM with its settings on the command line.
step "x86_64-linux outputs on the builder"
work="$state/x86-work"
mkdir -p "$work/cache"
flake="git+file://$repo?rev=$rev"
outputs=()
for package in nagarectl nagare nagare-platform release-tools; do
  outputs+=("$(nix build --no-link --print-out-paths --max-jobs 0 "$flake#packages.x86_64-linux.$package")")
done
nix copy --to "file://$work/cache" "${outputs[@]}"
rm -rf "$work/out" "$work/candidate.bundle"
git -C "$worktree" bundle create -q "$work/candidate.bundle" HEAD
cp "$worktree/scripts/release-native-container.sh" "$work/release-native-container.sh"

step "x86_64-linux attachments"
container system status >/dev/null 2>&1 || container system start
# Apple container starts processes with HOME=/, so nix profile would install off PATH.
container run --rm --platform linux/amd64 --rosetta -c 4 -m 16G -e HOME=/root -v "$work:/work" "$image" \
  bash /work/release-native-container.sh "$rev" "$version"
mkdir -p "$run/native"
cp -R "$work/out/x86_64-linux" "$run/native/x86_64-linux"

# --- 5. assemble twice and compare ---
step "assembly"
for dist in dist dist-again; do
  "$worktree/scripts/assemble-release.sh" --version "$version" --input-root "$run/native" \
    --transition-rehearsal "$run/transition-rehearsal.json" --output-dir "$run/$dist"
done
diff -r "$run/dist" "$run/dist-again" >/dev/null || die "the two assemblies differ: $run/dist $run/dist-again"
(cd "$run/dist" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS does not verify in $run/dist"
jq -n -S --arg version "$version" --arg revision "$rev" --arg previous "$previous" \
  '{version: $version, revision: $revision, previous: $previous}' > "$run/candidate.json"

step "waiting for the release gate"
wait "$gate" || die "the release gate failed: $run/gate-release.log"
tail -1 "$run/gate-release.log"

if $rehearsal; then
  step "rehearsal complete; nothing landed. Attachments in $run/dist; $record is left uncommitted"
  exit 0
fi

# --- 6. land the rehearsal record on origin/master (never part of the candidate itself) ---
step "rehearsal record"
if git cat-file -e "origin/master:$record" 2>/dev/null; then
  cmp -s <(git show "origin/master:$record") "$run/transition-rehearsal.json" \
    || die "origin/master already holds a different $record"
else
  git worktree add -q --detach "$evidence" origin/master
  mkdir -p "$evidence/$(dirname "$record")"
  cp "$run/transition-rehearsal.json" "$evidence/$record"
  git -C "$evidence" add -- "$record"
  git -C "$evidence" commit -q -m "docs(release): record the v$version transition rehearsal" \
    -m "Moved a disposable local context from v$previous to the candidate $rev; the seeded row read back unchanged."
  just land "$(git -C "$evidence" rev-parse HEAD)"
fi
ln -sfn "$run" "$state/v$version/latest"
step "v$version is ready to publish: just release-publish $version"
