#!/usr/bin/env bash
# Narrow typed transport for the artifact inventory adapter. The Haskell
# adapter owns planning, identity and recovery; this script only observes or
# publishes the exact destination/digest in the canonical request on stdin.
set -euo pipefail

if [ "${NAGARE_INVENTORY_ADAPTER_CHILD:-}" != "artifact" ]; then
  echo "artifact transport requires the artifact adapter child marker" >&2
  exit 2
fi

action="${1:-}"
case "${action}" in observe|publish) ;; *) echo "usage: $0 {observe|publish}" >&2; exit 2 ;; esac

request="$(cat)"
version="$(jq -er '.version' <<<"${request}")"
kind="$(jq -er '.kind' <<<"${request}")"
destination="$(jq -er '.destination' <<<"${request}")"
expected="$(jq -er '.expectedDigest' <<<"${request}")"
source_digest="$(jq -er '.specDigest' <<<"${request}")"
[ "${version}" = 1 ] || { echo "unsupported artifact transport version" >&2; exit 2; }
case "${expected}" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "invalid expected artifact digest" >&2; exit 2 ;; esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=lib/target.sh
source "${script_dir}/lib/target.sh"

absence_digest() {
  local value
  value="$(printf 'artifact-absence:%s:%s' "${kind}" "${destination}" | shasum -a 256 | awk '{print $1}')"
  printf 'sha256:%s' "${value}"
}

emit_missing() {
  jq -nc --arg digest "$(absence_digest)" '{tag:"TransportMissing",contents:$digest}'
}

emit_present() {
  jq -nc --arg physical "$1" --arg digest "$2" '{tag:"TransportPresent",contents:[$physical,$digest]}'
}

emit_owner_mismatch() {
  jq -nc --arg physical "$1" --arg reason "$2" '{tag:"TransportOwnershipMismatch",contents:[$physical,$reason]}'
}

observe_gce_image() {
  local project name output description actual
  IFS=/ read -r projects project global images name extra <<<"${destination}"
  if [ "${projects:-}" != projects ] || [ "${global:-}" != global ] || [ "${images:-}" != images ] || [ -z "${project:-}" ] || [ -z "${name:-}" ] || [ -n "${extra:-}" ]; then
    echo "invalid GCE image destination: ${destination}" >&2
    return 2
  fi
  if [ "${project}" != "${TARGET_PROJECT}" ]; then
    emit_owner_mismatch "gce://${destination}" "destination project ${project} differs from active project ${TARGET_PROJECT}"
    return
  fi
  if ! output="$(gcloud --project="${project}" compute images describe "${name}" --format=json 2>&1)"; then
    if grep -Eqi 'not found|was not found' <<<"${output}"; then emit_missing; return; fi
    printf '%s\n' "${output}" >&2
    return 1
  fi
  description="$(jq -er '.description // ""' <<<"${output}")"
  actual="$(sed -n 's/^nagare-content-digest=//p' <<<"${description}" | tail -n 1)"
  if [ -z "${actual}" ]; then
    emit_owner_mismatch "gce://${destination}" "image has no Nagare content-digest ownership stamp"
  else
    emit_present "gce://${destination}" "${actual}"
  fi
}

observe_oci_image() (
  local output
  local tls_args=()
  local auth_args=()
  if [ "${NAGARE_MODE:-cloud}" = local ]; then
    tls_args+=(--tls-verify=false)
  else
    _require_target_project
    case "${destination}" in
      "${NAGARE_REGISTRY_PREFIX}/"*) ;;
      *) emit_owner_mismatch "oci://${destination}" "registry destination differs from the selected project"; return ;;
    esac
    local private_dir
    private_dir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-artifact-observe.XXXXXX")"
    chmod 700 "${private_dir}"
    trap 'rm -rf "${private_dir}"' EXIT
    gcloud auth print-access-token | skopeo login --username oauth2accesstoken \
      --password-stdin --authfile "${private_dir}/auth.json" "${NAGARE_REGISTRY_HOST}" >/dev/null
    auth_args=(--authfile "${private_dir}/auth.json")
  fi
  if ! output="$(skopeo inspect "${tls_args[@]}" "${auth_args[@]}" --format '{{.Digest}}' "docker://${destination}" 2>&1)"; then
    if grep -Eqi 'manifest unknown|name unknown|not found' <<<"${output}"; then emit_missing; return; fi
    printf '%s\n' "${output}" >&2
    return 1
  fi
  emit_present "oci://${destination}" "$(tail -n 1 <<<"${output}")"
)

observe_gcs_object() {
  local output actual
  case "${destination}" in gs://*) ;; *) echo "invalid GCS object destination: ${destination}" >&2; return 2 ;; esac
  if ! output="$(gsutil stat "${destination}" 2>&1)"; then
    if grep -Eqi 'not found|No URLs matched' <<<"${output}"; then emit_missing; return; fi
    printf '%s\n' "${output}" >&2
    return 1
  fi
  actual="$(sed -n 's/^[[:space:]]*x-goog-meta-nagare-content-digest:[[:space:]]*//p' <<<"${output}" | tail -n 1)"
  if [ -z "${actual}" ]; then
    emit_owner_mismatch "gcs://${destination#gs://}" "object has no Nagare content-digest ownership metadata"
  else
    emit_present "gcs://${destination#gs://}" "${actual}"
  fi
}

observe() {
  case "${kind}" in
    GceImageArtifact) observe_gce_image ;;
    OciImageArtifact) observe_oci_image ;;
    GcsImageObjectArtifact) observe_gcs_object ;;
    *) echo "artifact kind ${kind} has no production transport" >&2; return 2 ;;
  esac
}

publish() {
  case "${kind}" in
    GceImageArtifact)
      NAGARE_ARTIFACT_DESTINATION="${destination}" \
      NAGARE_ARTIFACT_EXPECTED_DIGEST="${expected}" \
        bash "${script_dir}/upload-images.sh" >&2
      ;;
    OciImageArtifact)
      case "${destination}" in
        */attic:*)
          NAGARE_ARTIFACT_DESTINATION="${destination}" \
          NAGARE_ARTIFACT_EXPECTED_DIGEST="${expected}" \
          NAGARE_ARTIFACT_SOURCE_DIGEST="${source_digest}" \
            bash "${repo_root}/cluster/bootstrap/nix-cache/publish-image.sh" >&2
          ;;
        */net-certmanager-controller:v1.14.0-nagare.1)
          NAGARE_ARTIFACT_DESTINATION="${destination}" \
          NAGARE_ARTIFACT_EXPECTED_DIGEST="${expected}" \
          NAGARE_ARTIFACT_SOURCE_DIGEST="${source_digest}" \
            bash "${repo_root}/cluster/bootstrap/net-certmanager/publish-image.sh" >&2
          ;;
        *) echo "unsupported OCI image destination" >&2; return 2 ;;
      esac
      ;;
    *) echo "artifact kind ${kind} has no publication transport" >&2; return 2 ;;
  esac
  observe
}

if [ "${action}" = observe ]; then observe; else publish; fi
