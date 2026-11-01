#!/usr/bin/env bash
# MP-26 item 11: publish the run `just release-candidate VERSION` left ready
# (docs/runbooks/releases.md). It refuses unless the run's intranet record shows the intranet on
# the candidate (EP-210 M5). Sign the annotated tag with the maintainer's SSH key, verify it,
# push only the tag, publish with the candidate's own CLI from a checkout of the tag, check
# that the public flake reports VERSION at the candidate revision, then pin the operator
# repository to the tag. Each step stops at its first failure. The only retry is the publisher's "created draft is not yet visible", which a rerun
# completes. A rerun after a failure accepts the tag it already made.
set -euo pipefail

usage() { echo "usage: $0 VERSION" >&2; exit 2; }
die() { printf 'release-publish: %s\n' "$*" >&2; exit 1; }
step() { printf '%s release-publish: %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

[[ $# -eq 1 ]] || usage
version="$1"
tag="v$version"
repository=shinzui/nagare
key="${NAGARE_RELEASE_SIGNING_KEY:-$HOME/.ssh/id_ed25519.pub}"
draft_attempts=5

repo="$(git rev-parse --show-toplevel)"
cd "$repo"
run="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/releases/$tag/latest"
[[ -f "$run/candidate.json" ]] || die "no completed candidate run at $run; run just release-candidate $version"
run="$(cd "$run" && pwd -P)"
rev="$(jq -er '.revision' "$run/candidate.json")"
[[ "$(jq -er '.version' "$run/candidate.json")" == "$version" ]] || die "$run is not a run for $version"
[[ -f "$key" ]] || die "no SSH signing key at $key; set NAGARE_RELEASE_SIGNING_KEY"
# A release counts when the intranet runs it: the candidate run moved it and recorded that.
jq -e --arg v "$version" --arg r "$rev" '.version == $v and .revision == $r and .status.compatibility == "exact"' \
  "$run/intranet.json" >/dev/null 2>&1 \
  || die "no intranet record for $version at $rev in $run; run just release-candidate $version, or scripts/release-intranet.sh $version"

# --- preflight: the assembled attachments and the landed rehearsal record ---
(cd "$run/dist" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS does not verify in $run/dist"
git fetch -q origin master --tags
record="docs/release-evidence/$rev/transition-rehearsal.json"
git cat-file -e "origin/master:$record" 2>/dev/null || die "$record is not on origin/master"
cmp -s <(git show "origin/master:$record") "$run/dist/nagare-transition-rehearsal-$tag.json" \
  || die "the landed $record differs from the assembled one"

publish="$run/publish"
signers="$(mktemp)"
cleanup() {
  rm -f "$signers"
  git -C "$repo" worktree remove --force "$publish" 2>/dev/null || true
}
trap cleanup EXIT
printf '%s %s\n' "$(git config user.email)" "$(cat "$key")" > "$signers"

# --- 1. the signed tag ---
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  step "$tag exists; checking it"
else
  step "signing $tag on $rev"
  git -c gpg.format=ssh -c user.signingkey="$key" tag -s "$tag" -m "Nagare $tag" "$rev"
fi
[[ "$(git cat-file -t "refs/tags/$tag")" == tag ]] || die "$tag is not an annotated tag"
[[ "$(git rev-parse "refs/tags/$tag^{commit}")" == "$rev" ]] || die "$tag does not resolve to the candidate $rev"
git -c gpg.ssh.allowedSignersFile="$signers" tag -v "$tag" >/dev/null 2>&1 || die "$tag has no good signature by $key"

# --- 2. push only the tag ---
object="$(git rev-parse "refs/tags/$tag")"
remote="$(git ls-remote origin "refs/tags/$tag" | cut -f1)"
if [[ -z "$remote" ]]; then
  step "pushing $tag"
  git push origin "refs/tags/$tag"
else
  [[ "$remote" == "$object" ]] || die "origin holds a different $tag ($remote); never move a published tag"
  step "$tag is already on origin"
fi

# --- 3. publish with the candidate's CLI from a checkout of the tag ---
step "publishing $tag"
git worktree add -q --detach "$publish" "$tag"
cli="$(nix build --no-link --print-out-paths "git+file://$repo?rev=$rev#nagarectl")/bin/nagarectl"
log="$run/publish.log"
for attempt in $(seq 1 "$draft_attempts"); do
  if (cd "$publish" && "$cli" release publish --repo "$repository" --version "$version" --assets "$run/dist" --yes) 2>&1 | tee "$log"; then
    break
  fi
  grep -q 'created draft is not yet visible' "$log" || die "publication failed; see $log"
  [[ "$attempt" -lt "$draft_attempts" ]] || die "the draft was still not visible after $draft_attempts attempts; rerun just release-publish $version"
  step "the created draft is not yet visible; publishing again (attempt $((attempt + 1)))"
  sleep 15
done

# --- 4. the public flake ---
step "checking github:$repository/$tag"
nix run --refresh "github:$repository/$tag#nagarectl" -- version --json \
  | jq -e --arg version "$version" --arg revision "$rev" '.version == $version and .revision == $revision' >/dev/null \
  || die "github:$repository/$tag#nagarectl does not report $version at $rev"

# --- 5. the operator repository names the tag instead of the revision ---
"$publish/scripts/release-intranet.sh" "$version" --run "$run" --pin-tag
step "$tag is published"
