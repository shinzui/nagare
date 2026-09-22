#!/usr/bin/env bash
set -euo pipefail

if [ -n "${NAGARE_INVENTORY_TRANSACTION:-}" ] && [ "${NAGARE_INVENTORY_ADAPTER_CHILD:-}" != "artifact" ]; then
  echo "nagare: refusing inventory re-entry without the artifact adapter child marker" >&2
  exit 2
fi

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

if [ -n "${NAGARE_INVENTORY_TRANSACTION:-}" ]; then
  [ "${NAGARE_ARTIFACT_DESTINATION:-}" = "${destination}" ] || {
    echo "nagare: reviewed Attic destination differs from ${destination}" >&2
    exit 2
  }
  [ "${NAGARE_ARTIFACT_EXPECTED_DIGEST:-}" = "${expected_digest}" ] || {
    echo "nagare: reviewed Attic digest differs from ${expected_digest}" >&2
    exit 2
  }
fi

case "${destination}" in
  "${registry}/${CLOUDSDK_CORE_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}/"*) ;;
  *)
    echo "nagare: refusing unexpected Attic destination ${destination}" >&2
    exit 1
    ;;
esac

private_dir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-attic-publish.XXXXXX")"
chmod 700 "${private_dir}"
trap 'rm -rf "${private_dir}"' EXIT
policy="${private_dir}/policy.json"
# Some supported systems do not install a host containers-policy file. This
# policy controls signature verification only; registry TLS remains enabled,
# and the archive plus published image are both checked against the immutable
# digest in attic-pin.json.
printf '%s\n' '{"default":[{"type":"insecureAcceptAnything"}]}' > "${policy}"
chmod 600 "${policy}"

source_digest="$(skopeo --policy "${policy}" inspect --format '{{.Digest}}' "docker-archive:${archive}")"
if [ "${source_digest}" != "${expected_digest}" ]; then
  echo "nagare: payload Attic digest ${source_digest} does not match pin ${expected_digest}" >&2
  exit 1
fi

gcloud auth print-access-token | \
  skopeo login --username oauth2accesstoken --password-stdin \
    --authfile "${private_dir}/auth.json" "${registry}" >/dev/null
skopeo --policy "${policy}" copy --preserve-digests --authfile "${private_dir}/auth.json" \
  "docker-archive:${archive}" "docker://${destination}" >&2
remote_digest="$(skopeo --policy "${policy}" inspect --authfile "${private_dir}/auth.json" --format '{{.Digest}}' "docker://${destination}")"
if [ "${remote_digest}" != "${expected_digest}" ]; then
  echo "nagare: published Attic digest ${remote_digest} does not match pin ${expected_digest}" >&2
  exit 1
fi
printf '%s@%s\n' "${destination%:*}" "${remote_digest}"
if [ -n "${NAGARE_INVENTORY_TRANSACTION:-}" ]; then
  printf 'nagare-artifact\toci-image\t%s\t%s\n' "${destination%:*}" "${remote_digest}"
fi
