#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=scripts/lib/release.sh
source "$repo_root/scripts/lib/release.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

check_release() {
  bash "$repo_root/scripts/check-release.sh" "$@"
}

assemble_release() {
  bash "$repo_root/scripts/assemble-release.sh" "$@"
}

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

check_release \
  --version 0.1.0 \
  --source-root "$fixture" \
  --source-only \
  --revision fixture-revision \
  --output-dir "$test_root/artifacts" \
  --json | jq -e '.consistent and .version == "0.1.0" and ((.systems | length) == 2)' >/dev/null
test -s "$test_root/artifacts/nagare-release-0.1.0.json"
test -s "$test_root/artifacts/nagare-v0.1.0.md"
test -s "$test_root/artifacts/SHA256SUMS"

for system in x86_64-linux aarch64-darwin; do
  native_dir="$test_root/native/$system"
  mkdir -p "$native_dir"
  cp "$test_root/artifacts/nagare-release-0.1.0.json" "$native_dir/"
  cp "$test_root/artifacts/nagare-v0.1.0.md" "$native_dir/"
  jq -n -S \
    --arg system "$system" \
    '{version: "0.1.0", revision: "fixture-revision", system: $system,
      outputs: {
        nagarectl: {narHash: "sha256-cli", narSize: 1},
        "nagare-platform": {narHash: "sha256-platform", narSize: 2}
      }}' > "$native_dir/nix-output-$system.json"
  jq -n -S \
    --arg system "$system" \
    '{version: "0.1.0", revision: "fixture-revision", system: $system,
      supportedSystems: ["x86_64-linux", "aarch64-darwin"], cloneFree: true,
      checks: ["version", "context", "typed-config", "payload", "host-config", "local-init", "cloud-init", "operator-recipe"]}' \
    > "$native_dir/clone-free-$system.json"
done
assemble_release \
  --version 0.1.0 \
  --input-root "$test_root/native" \
  --output-dir "$test_root/assembled"
test -s "$test_root/assembled/nagare-release-0.1.0.json"
test -s "$test_root/assembled/nix-output-x86_64-linux.json"
test -s "$test_root/assembled/nix-output-aarch64-darwin.json"
test -s "$test_root/assembled/clone-free-x86_64-linux.json"
test -s "$test_root/assembled/clone-free-aarch64-darwin.json"
test -s "$test_root/assembled/SHA256SUMS"

expect_failure malformed-version \
  check_release --version 01.1.0 --source-root "$fixture" --source-only
expect_failure malformed-tag \
  check_release --version 0.1.0 --tag release-0.1.0 --source-root "$fixture" --source-only

for package in nagare-dsl nagarectl nagare-access; do
  mismatch="$test_root/mismatch-$package"
  copy_release_sources "$mismatch"
  sed -i.bak 's/version: *0\.1\.0$/version: 0.1.1/' "$mismatch/cli/$package/$package.cabal"
  rm "$mismatch/cli/$package/$package.cabal.bak"
  expect_failure "mismatch-$package" \
    check_release --version 0.1.0 --source-root "$mismatch" --source-only
done

missing_notes="$test_root/missing-notes"
copy_release_sources "$missing_notes"
rm "$missing_notes/docs/releases/v0.1.0.md"
expect_failure missing-notes \
  check_release --version 0.1.0 --source-root "$missing_notes" --source-only

unsupported="$test_root/unsupported-system"
copy_release_sources "$unsupported"
jq '.supportedSystems += ["x86_64-darwin"]' "$unsupported/release.json" > "$unsupported/release.tmp"
mv "$unsupported/release.tmp" "$unsupported/release.json"
expect_failure unsupported-system \
  check_release --version 0.1.0 --source-root "$unsupported" --source-only

git_fixture="$test_root/git-source"
copy_release_sources "$git_fixture"
git -C "$git_fixture" init -q
git -C "$git_fixture" config user.name 'Nagare release test'
git -C "$git_fixture" config user.email 'release-test@example.invalid'
git -C "$git_fixture" add .
git -C "$git_fixture" commit -qm 'test: seed release fixture'
git -C "$git_fixture" tag -a v0.1.0 -m 'Nagare v0.1.0'
check_release \
  --version 0.1.0 --tag v0.1.0 --source-root "$git_fixture" --skip-build --json \
  | jq -e '.consistent' >/dev/null

touch "$git_fixture/dirty"
expect_failure dirty-tree \
  check_release --version 0.1.0 --tag v0.1.0 --source-root "$git_fixture" --skip-build
rm "$git_fixture/dirty"
printf '\n' >> "$git_fixture/CHANGELOG.md"
git -C "$git_fixture" add CHANGELOG.md
git -C "$git_fixture" commit -qm 'docs: move candidate head'
expect_failure moving-tag \
  check_release --version 0.1.0 --tag v0.1.0 --source-root "$git_fixture" --skip-build

metadata_fixture="$git_fixture/packaged-source"
mkdir -p "$metadata_fixture"
jq '.sourceRevision = "0123456789abcdef0123456789abcdef01234567"' \
  "$repo_root/release.json" > "$metadata_fixture/release.json"
# A materialized payload can live below an unrelated Git worktree. Its injected
# provenance must win over that parent worktree's HEAD.
[[ "$(nagare_release_source_tag "$metadata_fixture")" == "0123456789ab" ]]

printf 'release consistency tests passed\n'
