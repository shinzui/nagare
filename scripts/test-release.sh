#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

copy_release_sources() {
  local destination="$1"
  mkdir -p \
    "$destination/cli/nagare-dsl" \
    "$destination/cli/nagarectl/src/Nagare/Host" \
    "$destination/cli/nagarectl/test" \
    "$destination/cli/nagare-access" \
    "$destination/docs/releases"
  cp "$repo_root/release.json" "$destination/release.json"
  cp "$repo_root/CHANGELOG.md" "$destination/CHANGELOG.md"
  cp "$repo_root/docs/releases/v0.1.0.md" "$destination/docs/releases/v0.1.0.md"
  cp "$repo_root/cli/nagare-dsl/nagare-dsl.cabal" "$destination/cli/nagare-dsl/nagare-dsl.cabal"
  cp "$repo_root/cli/nagarectl/nagarectl.cabal" "$destination/cli/nagarectl/nagarectl.cabal"
  cp "$repo_root/cli/nagarectl/src/Nagare/Host/Config.hs" "$destination/cli/nagarectl/src/Nagare/Host/Config.hs"
  cp "$repo_root/cli/nagarectl/test/PlatformSpec.hs" "$destination/cli/nagarectl/test/PlatformSpec.hs"
  cp "$repo_root/cli/nagare-access/nagare-access.cabal" "$destination/cli/nagare-access/nagare-access.cabal"
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$test_root/$label.out" 2>"$test_root/$label.err"; then
    printf 'expected failure: %s\n' "$label" >&2
    exit 1
  fi
}

fixture="$test_root/source"
copy_release_sources "$fixture"

"$repo_root/scripts/check-release.sh" \
  --version 0.1.0 \
  --source-root "$fixture" \
  --source-only \
  --revision fixture-revision \
  --output-dir "$test_root/artifacts" \
  --json | jq -e '.consistent and .version == "0.1.0" and ((.systems | length) == 2)' >/dev/null
test -s "$test_root/artifacts/nagare-release-0.1.0.json"
test -s "$test_root/artifacts/nagare-v0.1.0.md"
test -s "$test_root/artifacts/SHA256SUMS"

expect_failure malformed-version \
  "$repo_root/scripts/check-release.sh" --version 01.1.0 --source-root "$fixture" --source-only
expect_failure malformed-tag \
  "$repo_root/scripts/check-release.sh" --version 0.1.0 --tag release-0.1.0 --source-root "$fixture" --source-only

for package in nagare-dsl nagarectl nagare-access; do
  mismatch="$test_root/mismatch-$package"
  copy_release_sources "$mismatch"
  sed -i.bak 's/version: *0\.1\.0$/version: 0.1.1/' "$mismatch/cli/$package/$package.cabal"
  rm "$mismatch/cli/$package/$package.cabal.bak"
  expect_failure "mismatch-$package" \
    "$repo_root/scripts/check-release.sh" --version 0.1.0 --source-root "$mismatch" --source-only
done

missing_notes="$test_root/missing-notes"
copy_release_sources "$missing_notes"
rm "$missing_notes/docs/releases/v0.1.0.md"
expect_failure missing-notes \
  "$repo_root/scripts/check-release.sh" --version 0.1.0 --source-root "$missing_notes" --source-only

unsupported="$test_root/unsupported-system"
copy_release_sources "$unsupported"
jq '.supportedSystems += ["x86_64-darwin"]' "$unsupported/release.json" > "$unsupported/release.tmp"
mv "$unsupported/release.tmp" "$unsupported/release.json"
expect_failure unsupported-system \
  "$repo_root/scripts/check-release.sh" --version 0.1.0 --source-root "$unsupported" --source-only

git_fixture="$test_root/git-source"
copy_release_sources "$git_fixture"
git -C "$git_fixture" init -q
git -C "$git_fixture" config user.name 'Nagare release test'
git -C "$git_fixture" config user.email 'release-test@example.invalid'
git -C "$git_fixture" add .
git -C "$git_fixture" commit -qm 'test: seed release fixture'
git -C "$git_fixture" tag -a v0.1.0 -m 'Nagare v0.1.0'
"$repo_root/scripts/check-release.sh" \
  --version 0.1.0 --tag v0.1.0 --source-root "$git_fixture" --skip-build --json \
  | jq -e '.consistent' >/dev/null

touch "$git_fixture/dirty"
expect_failure dirty-tree \
  "$repo_root/scripts/check-release.sh" --version 0.1.0 --tag v0.1.0 --source-root "$git_fixture" --skip-build
rm "$git_fixture/dirty"
printf '\n' >> "$git_fixture/CHANGELOG.md"
git -C "$git_fixture" add CHANGELOG.md
git -C "$git_fixture" commit -qm 'docs: move candidate head'
expect_failure moving-tag \
  "$repo_root/scripts/check-release.sh" --version 0.1.0 --tag v0.1.0 --source-root "$git_fixture" --skip-build

printf 'release consistency tests passed\n'
