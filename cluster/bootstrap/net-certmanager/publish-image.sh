#!/usr/bin/env bash
# Publish only the released patched-controller archive named by a reviewed
# artifact operation. The Deployment itself is changed by the Kubernetes adapter.
set -euo pipefail

if [ "${NAGARE_INVENTORY_ADAPTER_CHILD:-}" != artifact ]; then
  echo "patched-controller publisher requires the artifact adapter child marker" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/../../.." && pwd)"
# shellcheck source=scripts/lib/target.sh
source "${root}/scripts/lib/target.sh"

if [ "${NAGARE_MODE:-cloud}" = local ]; then
  registry="${NAGARE_REGISTRY_HOST:?local registry host is required}"
  tls_args=(--dest-tls-verify=false)
  inspect_args=(--tls-verify=false)
  auth_args=()
else
  _require_target_project
  registry="${NAGARE_REGISTRY_PREFIX:?cloud registry prefix is required}"
  tls_args=()
  inspect_args=()
  auth_args=()
fi

destination="${registry}/net-certmanager-controller:v1.14.0-nagare.1"
[ "${NAGARE_ARTIFACT_DESTINATION:-}" = "${destination}" ] || {
  echo "reviewed patched-controller destination differs from the selected context" >&2
  exit 2
}
archive="${script_dir}/nagare-net-certmanager-controller.tar.gz"
[ -s "${archive}" ] || { echo "released patched-controller archive is missing" >&2; exit 1; }
actual_source="$(shasum -a 256 "${archive}" | awk '{print $1}')"
[ "sha256:${actual_source}" = "${NAGARE_ARTIFACT_SOURCE_DIGEST:-}" ] || {
  echo "patched-controller archive differs from the reviewed source digest" >&2
  exit 2
}

private_dir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-controller-publish.XXXXXX")"
chmod 700 "${private_dir}"
trap 'rm -rf "${private_dir}"' EXIT
policy="${private_dir}/policy.json"
printf '%s\n' '{"default":[{"type":"insecureAcceptAnything"}]}' > "${policy}"
chmod 600 "${policy}"
source_manifest="$(skopeo --policy "${policy}" inspect --format '{{.Digest}}' "docker-archive:${archive}")"
[ "${source_manifest}" = "${NAGARE_ARTIFACT_EXPECTED_DIGEST:-}" ] || {
  echo "patched-controller manifest differs from the reviewed digest" >&2
  exit 2
}

if [ "${NAGARE_MODE:-cloud}" != local ]; then
  gcloud auth print-access-token | skopeo login --username oauth2accesstoken \
    --password-stdin --authfile "${private_dir}/auth.json" "${NAGARE_REGISTRY_HOST}" >/dev/null
  auth_args=(--authfile "${private_dir}/auth.json")
fi

skopeo --policy "${policy}" copy --preserve-digests "${tls_args[@]}" "${auth_args[@]}" \
  "docker-archive:${archive}" "docker://${destination}" >&2
remote_manifest="$(skopeo --policy "${policy}" inspect "${inspect_args[@]}" "${auth_args[@]}" \
  --format '{{.Digest}}' "docker://${destination}")"
[ "${remote_manifest}" = "${source_manifest}" ] || {
  echo "published patched-controller manifest differs from the reviewed digest" >&2
  exit 2
}
printf 'nagare-artifact\toci-image\t%s\t%s\n' "${destination%:*}" "${remote_manifest}" >&2
