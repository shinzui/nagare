#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/assemble-release.sh --version VERSION --input-root DIR --output-dir DIR
  --transition-rehearsal FILE

Combine native artifacts, the platform metadata and the EP-172 transition rehearsal record into
immutable attachments. The record is the evidence/transition-rehearsal.json that
`just release-rehearse` writes after moving a disposable local context from the previous
release to this candidate; it must bind this candidate's version and revision.
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
transition_rehearsal=""

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
    --transition-rehearsal)
      [[ $# -ge 2 ]] || die "--transition-rehearsal requires a value"
      transition_rehearsal="$2"
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
[[ -n "$transition_rehearsal" && -f "$transition_rehearsal" && ! -L "$transition_rehearsal" ]] \
  || die "--transition-rehearsal requires the rehearsal record file"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

manifest_name="nagare-release-${version}.json"
notes_name="nagare-v${version}.md"
rehearsal_name="nagare-transition-rehearsal-v${version}.json"
metadata_name="nagare-platform-metadata-v${version}.json"
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
  diff -q \
    <(jq -S 'del(.payloadDigest)' "$base_manifest") \
    <(jq -S 'del(.payloadDigest)' "$candidate") >/dev/null \
    || die "native runners produced different $manifest_name fields other than payloadDigest"
done
for candidate in "${notes[@]:1}"; do
  cmp -s "$base_notes" "$candidate" \
    || die "native runners produced different $notes_name files"
done

expected_systems="$(jq -c '.systems | sort' "$base_manifest")"
revision="$(jq -er '.revision' "$base_manifest")"
observed_systems='[]'
payload_digests='{}'
for output in "${outputs[@]}"; do
  jq -e --arg version "$version" \
    '.version == $version
      and (.revision | type == "string" and length > 0)
      and (.system | type == "string" and length > 0)
      and (.outputs.nagarectl.narHash | startswith("sha256-"))
      and (.outputs["nagare-platform"].narHash | startswith("sha256-"))' \
    "$output" >/dev/null || die "invalid native output manifest: $output"
  output_revision="$(jq -er '.revision' "$output")"
  [[ "$output_revision" == "$revision" ]] \
    || die "native output revision does not match release manifest: $output"
  system="$(jq -er '.system' "$output")"
  payload_digest="$(jq -er '.outputs["nagare-platform"].narHash' "$output")"
  observed_systems="$(jq -c --arg system "$system" '. + [$system]' <<<"$observed_systems")"
  payload_digests="$(jq -c \
    --arg system "$system" \
    --arg digest "$payload_digest" \
    '. + {($system): $digest}' <<<"$payload_digests")"
done

[[ "$(jq -c 'sort | unique' <<<"$observed_systems")" == "$expected_systems" ]] \
  || die "native output manifests do not cover every supported system exactly once"
[[ "$(jq -r 'length' <<<"$observed_systems")" == "$(jq -r 'length' <<<"$expected_systems")" ]] \
  || die "duplicate native output manifests found"
for candidate in "${manifests[@]}"; do
  candidate_digest="$(jq -er '.payloadDigest' "$candidate")"
  jq -e --arg digest "$candidate_digest" \
    'to_entries | map(.value) | index($digest) != null' \
    <<<"$payload_digests" >/dev/null \
    || die "native release manifest payloadDigest has no matching output: $candidate"
done

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

# The transition rehearsal record binds this candidate, moved from a release this payload
# accepts, read its seeded row back unchanged, ended with every component on the candidate and
# no open transaction, and replanned with no operation. The publisher re-validates the copy.
jq -e --arg version "$version" --arg revision "$revision" \
  --argjson accepted "$(jq -c '.transitionsFrom // []' "$repo_root/release.json")" \
  '.schemaVersion == 1 and .mode == "local"
    and .candidate.version == $version and .candidate.revision == $revision
    and (.source.version as $source | $accepted | any(. == $source))
    and (.sentinel.seeded | type == "string" and length > 0) and .sentinel.readBack == .sentinel.seeded
    and (.transition.reviews | type == "number" and . >= 1)
    and (.platform.identities | [.cli, .payload, .cluster] | all(.version == $version and .revision == $revision))
    and .platform.identities.context.version == $version
    and .inventory.activeTransaction == null and .inventory.observationComplete == true
    and .replan.operations == 0 and .replan.reaccepts == 0' \
  "$transition_rehearsal" >/dev/null \
  || die "the transition rehearsal record does not prove this candidate: $transition_rehearsal"

mkdir -p "$output_dir"
jq -S \
  --argjson payloadDigests "$payload_digests" \
  '.payloadDigest = null | .payloadDigests = $payloadDigests' \
  "$base_manifest" > "$output_dir/$manifest_name"
cp "$base_notes" "$output_dir/$notes_name"
for output in "${outputs[@]}"; do
  cp "$output" "$output_dir/$(basename "$output")"
done
for rehearsal in "${rehearsals[@]}"; do
  cp "$rehearsal" "$output_dir/$(basename "$rehearsal")"
done
cp "$transition_rehearsal" "$output_dir/$rehearsal_name"
cp "$repo_root/release.json" "$output_dir/$metadata_name"

(
  cd "$output_dir"
  for file in "$manifest_name" "$notes_name" nix-output-*.json clone-free-*.json "$rehearsal_name" "$metadata_name"; do
    hash_file "$file"
  done
) > "$output_dir/SHA256SUMS"

printf 'Assembled Nagare %s release artifacts for %s.\n' \
  "$version" "$(jq -r 'join(", ")' <<<"$expected_systems")"
