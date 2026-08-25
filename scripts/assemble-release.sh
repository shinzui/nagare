#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/assemble-release.sh --version VERSION --input-root DIR --output-dir DIR

Combine native-runner release artifacts into the immutable GitHub release attachment set.
EOF
}

die() {
  printf 'nagare release assembly: %s\n' "$*" >&2
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

version=""
input_root=""
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="$2"
      shift 2
      ;;
    --input-root)
      [[ $# -ge 2 ]] || die "--input-root requires a value"
      input_root="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
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

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "--version must be an unpadded major.minor.patch semantic version"
[[ -d "$input_root" ]] || die "--input-root is not a directory: $input_root"
[[ -n "$output_dir" ]] || die "--output-dir is required"

manifest_name="nagare-release-${version}.json"
notes_name="nagare-v${version}.md"
manifests=()
while IFS= read -r candidate; do
  manifests+=("$candidate")
done < <(find "$input_root" -type f -name "$manifest_name" | sort)
notes=()
while IFS= read -r candidate; do
  notes+=("$candidate")
done < <(find "$input_root" -type f -name "$notes_name" | sort)
outputs=()
while IFS= read -r candidate; do
  outputs+=("$candidate")
done < <(find "$input_root" -type f -name 'nix-output-*.json' | sort)
rehearsals=()
while IFS= read -r candidate; do
  rehearsals+=("$candidate")
done < <(find "$input_root" -type f -name 'clone-free-*.json' | sort)

[[ ${#manifests[@]} -gt 0 ]] || die "no $manifest_name inputs found"
[[ ${#notes[@]} -gt 0 ]] || die "no $notes_name inputs found"

base_manifest="${manifests[0]}"
base_notes="${notes[0]}"
for candidate in "${manifests[@]:1}"; do
  cmp -s "$base_manifest" "$candidate" \
    || die "native runners produced different $manifest_name files"
done
for candidate in "${notes[@]:1}"; do
  cmp -s "$base_notes" "$candidate" \
    || die "native runners produced different $notes_name files"
done

expected_systems="$(jq -c '.systems | sort' "$base_manifest")"
observed_systems='[]'
for output in "${outputs[@]}"; do
  jq -e --arg version "$version" \
    '.version == $version
      and (.revision | type == "string" and length > 0)
      and (.system | type == "string" and length > 0)
      and (.outputs.nagarectl.narHash | startswith("sha256-"))
      and (.outputs["nagare-platform"].narHash | startswith("sha256-"))' \
    "$output" >/dev/null || die "invalid native output manifest: $output"
  output_revision="$(jq -er '.revision' "$output")"
  [[ "$output_revision" == "$(jq -er '.revision' "$base_manifest")" ]] \
    || die "native output revision does not match release manifest: $output"
  system="$(jq -er '.system' "$output")"
  observed_systems="$(jq -c --arg system "$system" '. + [$system]' <<<"$observed_systems")"
done

[[ "$(jq -c 'sort | unique' <<<"$observed_systems")" == "$expected_systems" ]] \
  || die "native output manifests do not cover every supported system exactly once"
[[ "$(jq -r 'length' <<<"$observed_systems")" == "$(jq -r 'length' <<<"$expected_systems")" ]] \
  || die "duplicate native output manifests found"

rehearsed_systems='[]'
for rehearsal in "${rehearsals[@]}"; do
  jq -e --arg version "$version" \
    '.version == $version and .cloneFree == true and (.system | type == "string")' \
    "$rehearsal" >/dev/null || die "invalid clone-free rehearsal: $rehearsal"
  system="$(jq -er '.system' "$rehearsal")"
  rehearsed_systems="$(jq -c --arg system "$system" '. + [$system]' <<<"$rehearsed_systems")"
done
[[ "$(jq -c 'sort | unique' <<<"$rehearsed_systems")" == "$expected_systems" ]] \
  || die "clone-free rehearsals do not cover every supported system exactly once"
[[ "$(jq -r 'length' <<<"$rehearsed_systems")" == "$(jq -r 'length' <<<"$expected_systems")" ]] \
  || die "duplicate clone-free rehearsals found"

mkdir -p "$output_dir"
cp "$base_manifest" "$output_dir/$manifest_name"
cp "$base_notes" "$output_dir/$notes_name"
for output in "${outputs[@]}"; do
  cp "$output" "$output_dir/$(basename "$output")"
done
for rehearsal in "${rehearsals[@]}"; do
  cp "$rehearsal" "$output_dir/$(basename "$rehearsal")"
done

(
  cd "$output_dir"
  for file in "$manifest_name" "$notes_name" nix-output-*.json clone-free-*.json; do
    hash_file "$file"
  done
) > "$output_dir/SHA256SUMS"

printf 'Assembled Nagare %s release artifacts for %s.\n' \
  "$version" "$(jq -r 'join(", ")' <<<"$expected_systems")"
