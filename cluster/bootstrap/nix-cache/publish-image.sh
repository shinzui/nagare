#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform_root="$(cd "${script_dir}/../../.." && pwd)"
# shellcheck disable=SC1091
source "${platform_root}/scripts/lib/target.sh"

_require_target_project

pin_file="${script_dir}/attic-pin.json"
archive="${script_dir}/attic-server-image.tar.gz"
if [ ! -s "${pin_file}" ] || [ ! -s "${archive}" ]; then
  echo "nagare: immutable Attic image assets are missing from ${script_dir}" >&2
  exit 1
fi

commit="$(jq -er '.sourceCommit' "${pin_file}")"
expected_digest="$(jq -er '.linuxAmd64Digest' "${pin_file}")"
registry="${NAGARE_REGISTRY_HOST}"
destination="${NAGARE_REGISTRY_PREFIX}/attic:${commit}"

case "${destination}" in
  "${registry}/${CLOUDSDK_CORE_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}/"*) ;;
  *)
    echo "nagare: refusing unexpected Attic destination ${destination}" >&2
    exit 1
    ;;
esac

source_digest="$(skopeo inspect --format '{{.Digest}}' "docker-archive:${archive}")"
if [ "${source_digest}" != "${expected_digest}" ]; then
  echo "nagare: payload Attic digest ${source_digest} does not match pin ${expected_digest}" >&2
  exit 1
fi

private_dir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-attic-publish.XXXXXX")"
chmod 700 "${private_dir}"
trap 'rm -rf "${private_dir}"' EXIT
gcloud auth print-access-token | \
  skopeo login --username oauth2accesstoken --password-stdin \
    --authfile "${private_dir}/auth.json" "${registry}" >/dev/null
skopeo copy --authfile "${private_dir}/auth.json" \
  "docker-archive:${archive}" "docker://${destination}" >&2
remote_digest="$(skopeo inspect --authfile "${private_dir}/auth.json" --format '{{.Digest}}' "docker://${destination}")"
if [ "${remote_digest}" != "${expected_digest}" ]; then
  echo "nagare: published Attic digest ${remote_digest} does not match pin ${expected_digest}" >&2
  exit 1
fi
printf '%s@%s\n' "${destination%:*}" "${remote_digest}"
