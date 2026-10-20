#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=scripts/lib/release.sh
source "$repo_root/scripts/lib/release.sh"
version="$(jq -er '.platformVersion' "$repo_root/release.json")"
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
  mkdir -p "$destination/cli/nagarectl/src/Nagare/Host" "$destination/docs/releases"
  cp "$repo_root/release.json" "$destination/release.json"
  # Fixture notes: no check reads the real ones, so editing them never needs a gate (EP-210 M2).
  printf '# Nagare %s\n\nFixture release notes.\n' "$version" > "$destination/docs/releases/v${version}.md"
  cp "$repo_root/cli/nagarectl/src/Nagare/Host/Config.hs" "$destination/cli/nagarectl/src/Nagare/Host/Config.hs"
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
  --version "$version" \
  --source-root "$fixture" \
  --source-only \
  --revision fixture-revision \
  --output-dir "$test_root/artifacts" \
  --json | jq -e --arg version "$version" '.consistent and .version == $version and ((.systems | length) == 2)' >/dev/null
test -s "$test_root/artifacts/nagare-release-${version}.json"
test -s "$test_root/artifacts/nagare-v${version}.md"
test -s "$test_root/artifacts/SHA256SUMS"

for system in x86_64-linux aarch64-darwin; do
  native_dir="$test_root/native/$system"
  mkdir -p "$native_dir"
  platform_hash="sha256-platform-$system"
  jq --arg digest "$platform_hash" '.payloadDigest = $digest' \
    "$test_root/artifacts/nagare-release-${version}.json" \
    > "$native_dir/nagare-release-${version}.json"
  cp "$test_root/artifacts/nagare-v${version}.md" "$native_dir/"
  jq -n -S \
    --arg system "$system" \
    --arg version "$version" \
    --arg platformHash "$platform_hash" \
    '{version: $version, revision: "fixture-revision", system: $system,
      outputs: {
        nagarectl: {narHash: "sha256-cli", narSize: 1},
        "nagare-platform": {narHash: $platformHash, narSize: 2}
      }}' > "$native_dir/nix-output-$system.json"
  jq -n -S \
    --arg system "$system" \
    --arg version "$version" \
    '{version: $version, revision: "fixture-revision", system: $system,
      supportedSystems: ["x86_64-linux", "aarch64-darwin"], cloneFree: true,
      pulumiVersion: "v3.255.0", platformUpgrade: {state: "planned", previewCalls: 1},
      checks: ["version", "context", "typed-config", "inventory-compile", "payload", "host-config", "local-init", "cloud-init", "operator-recipe", "platform-upgrade"]}' \
    > "$native_dir/clone-free-$system.json"
done
# The EP-172 transition rehearsal record, as scripts/transition-rehearsal.sh writes it, bound to
# this fixture's candidate.
rehearsal="$test_root/transition-rehearsal.json"
jq -n -S --arg version "$version" --arg source "$(jq -er '.transitionsFrom[0]' "$repo_root/release.json")" \
  '{schemaVersion: 1, mode: "local", context: "transition",
    source: {version: $source, revision: "source-revision"},
    candidate: {version: $version, revision: "fixture-revision"},
    bootstrap: {reviews: 3}, transition: {reviews: 3, operations: 1},
    sentinel: {seeded: "transition fixture", readBack: "transition fixture"},
    platform: {identities: ({version: $version, revision: "fixture-revision"} as $at
      | {cli: $at, payload: $at, cluster: $at, context: {version: $version, revision: null}, host: {version: null, revision: null}})},
    inventory: {activeTransaction: null, transactionStatus: null, observationComplete: true},
    replan: {operations: 0, reaccepts: 0}}' > "$rehearsal"
expect_failure missing-transition-rehearsal assemble_release --version "$version" \
  --input-root "$test_root/native" --output-dir "$test_root/no-rehearsal"
assemble_release \
  --version "$version" \
  --input-root "$test_root/native" \
  --transition-rehearsal "$rehearsal" \
  --output-dir "$test_root/assembled"
test -s "$test_root/assembled/nagare-release-${version}.json"
test -s "$test_root/assembled/nix-output-x86_64-linux.json"
test -s "$test_root/assembled/nix-output-aarch64-darwin.json"
test -s "$test_root/assembled/clone-free-x86_64-linux.json"
test -s "$test_root/assembled/clone-free-aarch64-darwin.json"
test -s "$test_root/assembled/SHA256SUMS"
jq -e '
  .payloadDigest == null
    and .payloadDigests["x86_64-linux"] == "sha256-platform-x86_64-linux"
    and .payloadDigests["aarch64-darwin"] == "sha256-platform-aarch64-darwin"
' "$test_root/assembled/nagare-release-${version}.json" >/dev/null

test -s "$test_root/assembled/nagare-transition-rehearsal-v${version}.json"
test -s "$test_root/assembled/nagare-platform-metadata-v${version}.json"
grep -q "nagare-transition-rehearsal-v${version}.json" "$test_root/assembled/SHA256SUMS"
jq '.candidate.revision = "different-revision"' "$rehearsal" > "$test_root/foreign-rehearsal.json"
expect_failure foreign-transition-rehearsal \
  assemble_release --version "$version" --input-root "$test_root/native" \
    --transition-rehearsal "$test_root/foreign-rehearsal.json" \
    --output-dir "$test_root/assembled-foreign-rehearsal"
jq '.sentinel.readBack = "another row"' "$rehearsal" > "$test_root/changed-rehearsal.json"
expect_failure changed-transition-rehearsal \
  assemble_release --version "$version" --input-root "$test_root/native" \
    --transition-rehearsal "$test_root/changed-rehearsal.json" \
    --output-dir "$test_root/assembled-changed-rehearsal"

cp -R "$test_root/native" "$test_root/divergent-native"
jq '.revision = "different-revision"' \
  "$test_root/divergent-native/x86_64-linux/nagare-release-${version}.json" \
  > "$test_root/divergent-native/x86_64-linux/manifest.tmp"
mv "$test_root/divergent-native/x86_64-linux/manifest.tmp" \
  "$test_root/divergent-native/x86_64-linux/nagare-release-${version}.json"
expect_failure divergent-native-manifest \
  assemble_release \
    --version "$version" \
    --input-root "$test_root/divergent-native" \
    --transition-rehearsal "$rehearsal" \
    --output-dir "$test_root/divergent-assembled"

expect_failure malformed-version \
  check_release --version 01.1.0 --source-root "$fixture" --source-only
expect_failure malformed-tag \
  check_release --version "$version" --tag "release-$version" --source-root "$fixture" --source-only

mismatch="$test_root/mismatch"
copy_release_sources "$mismatch"
jq '.platformVersion = "999.0.0"' "$mismatch/release.json" > "$mismatch/release.tmp"
mv "$mismatch/release.tmp" "$mismatch/release.json"
expect_failure mismatch \
  check_release --version "$version" --source-root "$mismatch" --source-only

missing_notes="$test_root/missing-notes"
copy_release_sources "$missing_notes"
rm "$missing_notes/docs/releases/v${version}.md"
expect_failure missing-notes \
  check_release --version "$version" --source-root "$missing_notes" --source-only

untitled_notes="$test_root/untitled-notes"
copy_release_sources "$untitled_notes"
printf 'Preface\n# Nagare %s\n' "$version" > "$untitled_notes/docs/releases/v${version}.md"
expect_failure untitled-notes \
  check_release --version "$version" --source-root "$untitled_notes" --source-only

unsupported="$test_root/unsupported-system"
copy_release_sources "$unsupported"
jq '.supportedSystems += ["x86_64-darwin"]' "$unsupported/release.json" > "$unsupported/release.tmp"
mv "$unsupported/release.tmp" "$unsupported/release.json"
expect_failure unsupported-system \
  check_release --version "$version" --source-root "$unsupported" --source-only

unsupported_wire="$test_root/unsupported-wire"
copy_release_sources "$unsupported_wire"
jq '.minimumUpgradeTransactionSchemaVersion = 2' "$unsupported_wire/release.json" > "$unsupported_wire/release.tmp"
mv "$unsupported_wire/release.tmp" "$unsupported_wire/release.json"
expect_failure unsupported-upgrade-wire \
  check_release --version "$version" --source-root "$unsupported_wire" --source-only

git_fixture="$test_root/git-source"
copy_release_sources "$git_fixture"
git -C "$git_fixture" init -q
git -C "$git_fixture" config user.name 'Nagare release test'
git -C "$git_fixture" config user.email 'release-test@example.invalid'
git -C "$git_fixture" add .
git -C "$git_fixture" commit -qm 'test: seed release fixture'
git -C "$git_fixture" tag -a "v$version" -m "Nagare v${version}"
check_release \
  --version "$version" --tag "v$version" --source-root "$git_fixture" --skip-build --json \
  | jq -e '.consistent' >/dev/null

touch "$git_fixture/dirty"
expect_failure dirty-tree \
  check_release --version "$version" --tag "v$version" --source-root "$git_fixture" --skip-build
rm "$git_fixture/dirty"
printf '\n' >> "$git_fixture/docs/releases/v${version}.md"
git -C "$git_fixture" add "docs/releases/v${version}.md"
git -C "$git_fixture" commit -qm 'docs: move candidate head'
expect_failure moving-tag \
  check_release --version "$version" --tag "v$version" --source-root "$git_fixture" --skip-build

metadata_fixture="$git_fixture/packaged-source"
mkdir -p "$metadata_fixture"
jq '.sourceRevision = "0123456789abcdef0123456789abcdef01234567"' \
  "$repo_root/release.json" > "$metadata_fixture/release.json"
# A materialized payload can live below an unrelated Git worktree. Its injected
# provenance must win over that parent worktree's HEAD.
[[ "$(nagare_release_source_tag "$metadata_fixture")" == "0123456789ab" ]]

bash "$repo_root/scripts/test-release-intranet.sh"

printf 'release consistency tests passed\n'
