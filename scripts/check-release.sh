#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-release.sh --version VERSION [options]

Validate Nagare release sources and, by default, the current Nix-built CLI and payload.

Options:
  --tag TAG          Require an annotated vVERSION tag at HEAD (publication mode).
  --json             Print the release manifest JSON instead of a prose summary.
  --output-dir DIR   Write the manifest, release notes, and SHA256SUMS to DIR.
  --allow-dirty      Permit a dirty Git worktree for a local rehearsal.
  --source-root DIR  Validate another source tree (used by hermetic tests).
  --revision REV     Override the source revision (used by hermetic tests).
  --skip-build       Validate sources and Git state without invoking Nix.
  --source-only      Validate only source metadata; implies --skip-build and --allow-dirty.
EOF
}

die() {
  printf 'nagare release check: %s\n' "$*" >&2
  exit 1
}

hash_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
  else
    shasum -a 256 "$file"
  fi
}

cabal_version() {
  awk '$1 == "version:" { print $2; exit }' "$1"
}

version=""
tag=""
json_output=false
output_dir=""
allow_dirty=false
source_root=""
revision=""
skip_build=false
source_only=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      tag="$2"
      shift 2
      ;;
    --json)
      json_output=true
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --allow-dirty)
      allow_dirty=true
      shift
      ;;
    --source-root)
      [[ $# -ge 2 ]] || die "--source-root requires a value"
      source_root="$2"
      shift 2
      ;;
    --revision)
      [[ $# -ge 2 ]] || die "--revision requires a value"
      revision="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --source-only)
      source_only=true
      skip_build=true
      allow_dirty=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$version" ]] || die "--version is required"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "version must be an unpadded major.minor.patch semantic version"

if [[ -z "$source_root" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source_root="$(cd "$script_dir/.." && pwd)"
else
  source_root="$(cd "$source_root" && pwd)"
fi

expected_tag="v${version}"
if [[ -n "$tag" && "$tag" != "$expected_tag" ]]; then
  die "tag $tag does not match version $version (expected $expected_tag)"
fi

release_file="$source_root/release.json"
notes_file="$source_root/docs/releases/${expected_tag}.md"
changelog_file="$source_root/CHANGELOG.md"
host_schema_file="$source_root/cli/nagarectl/src/Nagare/Host/Config.hs"
compatibility_fixture="$source_root/cli/nagarectl/test/PlatformSpec.hs"

for required in \
  "$release_file" \
  "$notes_file" \
  "$changelog_file" \
  "$host_schema_file" \
  "$compatibility_fixture"; do
  [[ -f "$required" ]] || die "missing required release source: ${required#"$source_root/"}"
done

checked_sources='[]'
for cabal_file in \
  cli/nagare-dsl/nagare-dsl.cabal \
  cli/nagarectl/nagarectl.cabal \
  cli/nagare-access/nagare-access.cabal; do
  full_path="$source_root/$cabal_file"
  [[ -f "$full_path" ]] || die "missing Cabal package: $cabal_file"
  observed="$(cabal_version "$full_path")"
  [[ "$observed" == "$version" ]] \
    || die "$cabal_file declares $observed, expected $version"
  checked_sources="$(jq -c --arg source "$cabal_file" --arg observed "$observed" \
    '. + [{source: $source, version: $observed}]' <<<"$checked_sources")"
done

payload_version="$(jq -er '.platformVersion' "$release_file")"
[[ "$payload_version" == "$version" ]] \
  || die "release.json declares $payload_version, expected $version"

jq -e '
  .assetSchemaVersion == 1
  and .hostFlakeMetadataSchemaVersion == 1
  and .compatibilitySchemaVersion == 1
  and (.supportedSystems | type == "array" and length > 0)
  and (.supportedSystems | all(. == "x86_64-linux" or . == "aarch64-darwin"))
  and ((.supportedSystems | unique | length) == (.supportedSystems | length))
' "$release_file" >/dev/null || die "release.json has unsupported or invalid release schema metadata"

mapfile_supported_systems="$(jq -c '.supportedSystems' "$release_file")"
grep -Fq "## [$version]" "$changelog_file" \
  || die "CHANGELOG.md has no [$version] entry"
grep -Fq "# Nagare $version" "$notes_file" \
  || die "release notes do not begin with '# Nagare $version'"
grep -Fq 'Nagare platform version:' "$host_schema_file" \
  || die "host-flake version metadata marker is missing"
grep -Fq 'Nagare source revision:' "$host_schema_file" \
  || die "host-flake revision metadata marker is missing"
grep -Fq "\\\"platformVersion\\\":\\\"$version\\\"" "$compatibility_fixture" \
  || die "platform compatibility fixture does not cover release $version"

checked_sources="$(jq -c \
  --arg version "$version" \
  '. + [{source: "release.json", version: $version},
         {source: "CHANGELOG.md", version: $version},
         {source: "docs/releases/v" + $version + ".md", version: $version},
         {source: "host-flake-metadata-schema", version: "1"},
         {source: "platform-compatibility-schema", version: "1"}]' \
  <<<"$checked_sources")"

if [[ "$source_only" == false ]]; then
  git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "source root is not a Git worktree"
  git_revision="$(git -C "$source_root" rev-parse HEAD)"
  dirty_status="$(git -C "$source_root" status --porcelain)"
  if [[ "$allow_dirty" == false && -n "$dirty_status" ]]; then
    die "publication requires a clean Git worktree"
  fi
  if [[ -z "$revision" && ( -z "$dirty_status" || "$skip_build" == true ) ]]; then
    revision="$git_revision"
  fi
  if [[ -n "$tag" ]]; then
    tag_type="$(git -C "$source_root" cat-file -t "refs/tags/$tag" 2>/dev/null || true)"
    [[ "$tag_type" == "tag" ]] || die "publication tag $tag must exist and be annotated"
    tag_revision="$(git -C "$source_root" rev-parse "refs/tags/$tag^{commit}")"
    [[ "$tag_revision" == "$git_revision" ]] \
      || die "tag $tag resolves to $tag_revision, but candidate revision is $git_revision"
  fi
elif [[ -z "$revision" ]]; then
  revision="source-only"
fi

payload_digest=null
if [[ "$skip_build" == false ]]; then
  command -v nix >/dev/null 2>&1 || die "nix is required for built release validation"

  if [[ -z "$revision" ]]; then
    revision="$(nix eval --raw "$source_root#lib.release.sourceRevision")"
  fi

  evaluated_systems="$(nix eval --json "$source_root#packages" --apply builtins.attrNames)"
  [[ "$(jq -c 'sort' <<<"$evaluated_systems")" == "$(jq -c 'sort' <<<"$mapfile_supported_systems")" ]] \
    || die "flake package systems do not match release.json supportedSystems"

  while IFS= read -r system; do
    system_outputs="$(nix eval --json "$source_root#packages.$system" --apply builtins.attrNames)"
    for output in nagarectl nagare-platform; do
      jq -e --arg output "$output" 'index($output) != null' <<<"$system_outputs" >/dev/null \
        || die "missing flake output packages.$system.$output"
    done
  done < <(jq -r '.[]' <<<"$mapfile_supported_systems")

  cli_path="$(nix build --no-link --print-out-paths "$source_root#nagarectl")"
  payload_path="$(nix build --no-link --print-out-paths "$source_root#nagare-platform")"
  cli_json="$("$cli_path/bin/nagarectl" version --json)"
  built_payload="$payload_path/share/nagare/release.json"

  [[ "$(jq -er '.version' <<<"$cli_json")" == "$version" ]] \
    || die "built nagarectl version does not match $version"
  [[ "$(jq -er '.revision' <<<"$cli_json")" == "$revision" ]] \
    || die "built nagarectl revision does not match $revision"
  [[ "$(jq -er '.platformVersion' "$built_payload")" == "$version" ]] \
    || die "built payload version does not match $version"
  [[ "$(jq -er '.sourceRevision' "$built_payload")" == "$revision" ]] \
    || die "built payload revision does not match $revision"
  jq -e --argjson systems "$mapfile_supported_systems" '.supportedSystems == $systems' \
    "$built_payload" >/dev/null || die "built payload systems do not match release.json"

  payload_digest="$(nix path-info --json --json-format 1 "$payload_path" \
    | jq -c 'if type == "array" then .[0].narHash else (to_entries[0].value.narHash) end')"
  checked_sources="$(jq -c --arg version "$version" --arg revision "$revision" \
    '. + [{source: "nix:#nagarectl", version: $version, revision: $revision},
           {source: "nix:#nagare-platform", version: $version, revision: $revision}]' \
    <<<"$checked_sources")"
fi

manifest="$(jq -n -S \
  --arg version "$version" \
  --arg tag "$expected_tag" \
  --arg revision "$revision" \
  --argjson systems "$mapfile_supported_systems" \
  --argjson payloadDigest "$payload_digest" \
  --argjson checkedSources "$checked_sources" \
  '{version: $version,
    tag: $tag,
    revision: $revision,
    consistent: true,
    systems: $systems,
    payloadDigest: $payloadDigest,
    checkedSources: $checkedSources}')"

if [[ -n "$output_dir" ]]; then
  mkdir -p "$output_dir"
  manifest_name="nagare-release-${version}.json"
  notes_name="nagare-${expected_tag}.md"
  printf '%s\n' "$manifest" > "$output_dir/$manifest_name"
  cp "$notes_file" "$output_dir/$notes_name"
  (
    cd "$output_dir"
    hash_file "$manifest_name"
    hash_file "$notes_name"
  ) > "$output_dir/SHA256SUMS"
fi

if [[ "$json_output" == true ]]; then
  printf '%s\n' "$manifest"
else
  printf 'Nagare %s is release-consistent at %s for %s.\n' \
    "$version" "$revision" "$(jq -r 'join(", ")' <<<"$mapfile_supported_systems")"
fi
