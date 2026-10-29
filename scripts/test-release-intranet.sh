#!/usr/bin/env bash
# EP-210 M5: release-publish's intranet precondition. It refuses before signing without the run's
# intranet record for the candidate. The intranet move itself (nagare-harness transition run and
# pin-tag) is tested with a fake transport in cli/nagare-harness/test/ReleaseTransitionSpec.hs
# (EP-229). Run by scripts/test-release.sh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
version=9.8.7
rev=0123456789abcdef0123456789abcdef01234567
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME"

# A candidate run with the record nagare-harness transition run writes.
run="$test_root/run"
mkdir -p "$run"
jq -n --arg version "$version" --arg revision "$rev" '{version: $version, revision: $revision, previous: "9.8.6"}' > "$run/candidate.json"
jq -n --arg v "$version" --arg r "$rev" \
  '{version: $v, revision: $r, context: "intranet", checkedAt: "2026-10-29T14:04:58Z",
    status: {compatibility: "exact"}, inventory: {activeTransaction: null, accepted: 1, converged: true},
    protected: {url: "https://protected-hello.example.test/", status: 302, location: "https://auth.example.test/login"}}' > "$run/intranet.json"

publish_repo="$test_root/publish-repo"
git init -q "$publish_repo"
mkdir -p "$test_root/xdg/nagare/releases/v$version"
ln -s "$run" "$test_root/xdg/nagare/releases/v$version/latest"
touch "$test_root/key.pub"
publish() {
  (cd "$publish_repo" && XDG_STATE_HOME="$test_root/xdg" NAGARE_RELEASE_SIGNING_KEY="$test_root/key.pub" \
    bash "$repo_root/scripts/release-publish.sh" "$version") > "$test_root/publish.out" 2>&1 && return 1
  grep -Fq "$1" "$test_root/publish.out" || { cat "$test_root/publish.out" >&2; return 1; }
}
publish 'SHA256SUMS does not verify'
jq '.revision = "another"' "$run/intranet.json" > "$run/foreign.json"
mv "$run/foreign.json" "$run/intranet.json"
publish "no intranet record for $version at $rev"
rm "$run/intranet.json"
publish "no intranet record for $version at $rev"

printf 'release intranet tests passed\n'
