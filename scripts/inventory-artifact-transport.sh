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
archive="$(jq -r '.archive // empty' <<<"${request}")"
if [ "${version}" != 1 ] && { [ "${version}" != 2 ] || [ "${kind}" != BuildJobArtifact ]; }; then
  echo "unsupported artifact transport version" >&2; exit 2
fi
[[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid expected artifact digest" >&2; exit 2; }
[[ "${source_digest}" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid source artifact digest" >&2; exit 2; }
if [ "${action}" = publish ]; then
  jq -e '
    .plan.version == 1
    and .plan.resource == .resource
    and .plan.kind == .kind
    and .plan.destination == .destination
    and .plan.expectedDigest == .expectedDigest
    and .plan.sourceDigest == .specDigest
  ' <<<"${request}" >/dev/null || { echo "artifact publication differs from the reviewed plan" >&2; exit 2; }
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=lib/target.sh
# Artifact observation and publication need the context guard, never a Pulumi
# stack. Local target loading otherwise selects or initializes one per call.
export NAGARE_SKIP_PULUMI_STACK_SELECT=1
source "${script_dir}/lib/target.sh"
# shellcheck source=lib/local-registry.sh
source "${script_dir}/lib/local-registry.sh"

absence_digest() {
  local value
  value="$(printf 'artifact-absence:%s:%s' "${kind}" "${destination}" | shasum -a 256 | awk '{print $1}')"
  printf '%s' "${value}"
}

emit_missing() {
  jq -nc --arg digest "$(absence_digest)" '{tag:"TransportMissing",contents:$digest}'
}

emit_present() {
  local digest="${2#sha256:}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid observed artifact digest" >&2; return 2; }
  jq -nc --arg physical "$1" --arg digest "${digest}" '{tag:"TransportPresent",contents:[$physical,$digest]}'
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
  local output status
  local tls_args=()
  local auth_args=()
  if [ "${NAGARE_MODE:-cloud}" = local ]; then
    if [ "${NAGARE_REGISTRY_HOST:-}" = k3d-registry.localhost:5000 ]; then
      if output="$(nagare_local_registry_digest "$destination")"; then
        emit_present "oci://${destination}" "$output"
        return
      else
        status=$?
        if [ "$status" -eq 4 ]; then emit_missing; return; fi
        return "$status"
      fi
    fi
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

kubeconfig_destination() {
  local root="${XDG_CONFIG_HOME:-${HOME}/.config}"
  printf '%s/nagare/kubeconfigs/%s.yaml' "${root}" "${NAGARE_CONTEXT}"
}

observe_kubeconfig() {
  [ "${destination}" = "$(kubeconfig_destination)" ] || {
    echo "kubeconfig destination differs from the selected context" >&2; return 2;
  }
  [ ! -L "${destination}" ] || { echo "refusing symlink kubeconfig destination" >&2; return 2; }
  if [ ! -e "${destination}" ]; then emit_missing; return; fi
  [ -f "${destination}" ] || { echo "kubeconfig destination is not a regular file" >&2; return 2; }
  local actual
  actual="$(shasum -a 256 "${destination}" | awk '{print $1}')"
  emit_present "kubeconfig://${destination}" "${actual}"
}

publish_kubeconfig() (
  [ "${destination}" = "$(kubeconfig_destination)" ] || {
    echo "kubeconfig destination differs from the selected context" >&2; return 2;
  }
  [ -n "${archive}" ] && [[ "${archive}" = /* ]] && [ -f "${archive}" ] && [ ! -L "${archive}" ] || {
    echo "reviewed prepared kubeconfig is missing or invalid" >&2; return 2;
  }
  [ ! -L "${destination}" ] || { echo "refusing symlink kubeconfig destination" >&2; return 2; }
  local actual parent temporary
  actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  [ "${actual}" = "${expected}" ] && [ "${source_digest}" = "${expected}" ] || {
    echo "prepared kubeconfig differs from the reviewed digest" >&2; return 2;
  }
  parent="$(dirname "${destination}")"
  mkdir -p "${parent}"
  chmod 0700 "${parent}"
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  trap 'rm -f "${temporary}"' EXIT
  cp "${archive}" "${temporary}"
  chmod 0600 "${temporary}"
  actual="$(shasum -a 256 "${temporary}" | awk '{print $1}')"
  [ "${actual}" = "${expected}" ] || { echo "staged kubeconfig digest changed" >&2; return 2; }
  mv "${temporary}" "${destination}"
)

observe_build_job() {
  local output marker status path digest
  [[ "${destination}" = /* ]] || { echo "build destination must be absolute" >&2; return 2; }
  output="$(NAGARE_ARTIFACT_DESTINATION="${destination}" \
    NAGARE_ARTIFACT_EXPECTED_DIGEST="${expected}" \
    bash "${script_dir}/upload-images.sh" --inspect-build --require-read-only)"
  IFS=$'\t' read -r marker status path digest <<<"${output}"
  [ "${marker}" = nagare-build ] && [ "${path}" = "${destination}" ] && [ "${digest}" = "${expected}" ] || {
    echo "build observation differs from the reviewed output" >&2; return 2;
  }
  case "${status}" in
    present) emit_present "build-job://${destination}" "${digest}" ;;
    missing) emit_missing ;;
    *) echo "invalid build observation status" >&2; return 2 ;;
  esac
}

load_local_substrate() {
  [ "${NAGARE_MODE:-cloud}" = local ] || { echo "local substrate requires local mode" >&2; return 2; }
  [ -n "${archive}" ] && [[ "${archive}" = /* ]] && [ -f "${archive}" ] && [ ! -L "${archive}" ] || {
    echo "reviewed local substrate specification is missing" >&2; return 2;
  }
  local actual
  actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  [ "${actual}" = "${source_digest}" ] && [ "${actual}" = "${expected}" ] || {
    echo "local substrate specification differs from the reviewed digest" >&2; return 2;
  }
  jq -e '
    .version == 1
    and .cluster == "nagare-local"
    and .registry == "registry.localhost"
    and .registryHost == "k3d-registry.localhost:5000"
    and .registryPort == "0.0.0.0:5000"
    and .k3sImage == "rancher/k3s:v1.34.6-k3s1"
    and .httpPort == "80:80@loadbalancer"
    and .httpsPort == "443:443@loadbalancer"
    and .k3sArg == "--disable=traefik@server:0"
  ' "${archive}" >/dev/null || { echo "local substrate specification is unsupported" >&2; return 2; }
  [ "${NAGARE_REGISTRY_HOST:-}" = "$(jq -r .registryHost "${archive}")" ] || {
    echo "local registry differs from the selected context" >&2; return 2;
  }
}

observe_local_registry() {
  load_local_substrate
  [ "${destination}" = "$(jq -r .registryHost "${archive}")" ] || {
    echo "local registry destination differs from the reviewed specification" >&2; return 2;
  }
  local observed matched count port host_ip mappings
  observed="$(k3d registry list -o json)"
  jq -e 'type == "array"' <<<"${observed}" >/dev/null || { echo "invalid k3d registry listing" >&2; return 2; }
  matched="$(jq -c --arg name "k3d-$(jq -r .registry "${archive}")" \
    '[.[] | select((.host // .name) == $name)]' <<<"${observed}")"
  count="$(jq 'length' <<<"${matched}")"
  if [ "${count}" = 0 ]; then emit_missing; return; fi
  if [ "${count}" != 1 ]; then emit_owner_mismatch "k3d-registry://${destination}" "multiple matching local registries"; return; fi
  mappings="$(jq -r '.[0].portMappings["5000/tcp"] // [] | length' <<<"${matched}")"
  port="$(jq -r '.[0].portMappings["5000/tcp"][0].HostPort // .[0].expose.binding.HostPort // .[0].expose.Binding.HostPort // .[0].expose.binding.hostPort // empty' <<<"${matched}")"
  host_ip="$(jq -r '.[0].portMappings["5000/tcp"][0].HostIp // .[0].expose.binding.HostIp // .[0].expose.binding.HostIP // .[0].expose.Binding.HostIp // .[0].expose.Binding.HostIP // empty' <<<"${matched}")"
  if { [ "${mappings}" != 0 ] && [ "${mappings}" != 1 ]; } \
    || [ "${port}" != 5000 ] || [ "${host_ip}" != "0.0.0.0" ]; then
    emit_owner_mismatch "k3d-registry://${destination}" "local registry port binding differs from the reviewed specification"
    return
  fi
  emit_present "k3d-registry://${destination}" "${expected}"
}

observe_local_cluster() {
  load_local_substrate
  [ "${destination}" = "$(jq -r .cluster "${archive}")" ] || {
    echo "local cluster destination differs from the reviewed specification" >&2; return 2;
  }
  local observed matched count server_identity
  observed="$(k3d cluster list -o json)"
  jq -e 'type == "array"' <<<"${observed}" >/dev/null || { echo "invalid k3d cluster listing" >&2; return 2; }
  matched="$(jq -c --arg name "${destination}" '[.[] | select(.name == $name)]' <<<"${observed}")"
  count="$(jq 'length' <<<"${matched}")"
  if [ "${count}" = 0 ]; then emit_missing; return; fi
  if [ "${count}" != 1 ]; then emit_owner_mismatch "k3d-cluster://${destination}" "multiple matching local clusters"; return; fi
  if ! jq -e --arg server "k3d-${destination}-server-0" '
    .[0].serversCount == 1
    and .[0].serversRunning == 1
    and .[0].hasLoadbalancer == true
    and ([.[0].nodes[] | select(.role == "server" and .name == $server
      and .State.Running == true)] | length) == 1
    and ([.[0].nodes[] | select(.role == "loadbalancer") | .portMappings
      | ((.["80/tcp"] // .["80"] // []) + (.["443/tcp"] // .["443"] // []))
      | .[].HostPort] | sort) == ["443", "80"]
  ' <<<"${matched}" >/dev/null; then
    emit_owner_mismatch "k3d-cluster://${destination}" "local cluster identity or port mapping differs from the reviewed specification"
    return
  fi
  server_identity="$(docker inspect --type container "k3d-${destination}-server-0")" || {
    echo "local cluster server container cannot be inspected" >&2; return 2;
  }
  if ! jq -e --arg cluster "${destination}" --arg digest "${expected}" '
    length == 1
    and .[0].State.Running == true
    and .[0].Config.Labels["k3d.cluster"] == $cluster
    and .[0].Config.Labels["k3d.role"] == "server"
    and .[0].Config.Labels["nagare.bootstrap.digest"] == $digest
  ' <<<"${server_identity}" >/dev/null; then
    emit_owner_mismatch "k3d-cluster://${destination}" "local cluster server digest label differs from the reviewed specification"
    return
  fi
  emit_present "k3d-cluster://${destination}" "${expected}"
}

observe() {
  case "${kind}" in
    GceImageArtifact) observe_gce_image ;;
    OciImageArtifact) observe_oci_image ;;
    GcsImageObjectArtifact) observe_gcs_object ;;
    KubeconfigArtifact) observe_kubeconfig ;;
    BuildJobArtifact) observe_build_job ;;
    LocalRegistryArtifact) observe_local_registry ;;
    LocalClusterArtifact) observe_local_cluster ;;
    *) echo "artifact kind ${kind} has no production transport" >&2; return 2 ;;
  esac
}

publish_oci_archive() (
  [ -n "${archive}" ] && [[ "${archive}" = /* ]] && [ -s "${archive}" ] || {
    echo "reviewed OCI archive is missing or is not an absolute file" >&2
    return 2
  }
  if [ "${NAGARE_MODE:-cloud}" = local ]; then
    case "${destination}" in
      "${NAGARE_REGISTRY_HOST}/"*) ;;
      *) echo "OCI destination differs from the selected local registry" >&2; return 2 ;;
    esac
  else
    _require_target_project
    case "${destination}" in
      "${NAGARE_REGISTRY_PREFIX}/"*) ;;
      *) echo "OCI destination differs from the selected project" >&2; return 2 ;;
    esac
  fi
  actual_source="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  [ "${actual_source}" = "${source_digest}" ] || {
    echo "OCI archive differs from the reviewed source digest" >&2
    return 2
  }
  private_dir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-app-image.XXXXXX")"
  chmod 700 "${private_dir}"
  trap 'rm -rf "${private_dir}"' EXIT
  policy="${private_dir}/policy.json"
  printf '%s\n' '{"default":[{"type":"insecureAcceptAnything"}]}' >"${policy}"
  chmod 600 "${policy}"
  source_manifest="$(skopeo --policy "${policy}" inspect --format '{{.Digest}}' "docker-archive:${archive}")"
  [ "${source_manifest}" = "sha256:${expected}" ] || {
    echo "OCI archive manifest differs from the reviewed digest" >&2
    return 2
  }
  tls_args=()
  auth_args=()
  if [ "${NAGARE_MODE:-cloud}" = local ]; then
    tls_args=(--dest-tls-verify=false)
  else
    gcloud auth print-access-token | skopeo login --username oauth2accesstoken \
      --password-stdin --authfile "${private_dir}/auth.json" "${NAGARE_REGISTRY_HOST}" >/dev/null
    auth_args=(--authfile "${private_dir}/auth.json")
  fi
  wire_destination="${destination}"
  if [ "${NAGARE_MODE:-cloud}" = local ] && [ "${NAGARE_REGISTRY_HOST:-}" = k3d-registry.localhost:5000 ] \
      && [ -n "${NAGARE_LOCAL_REGISTRY_FORWARD:-}" ]; then
    [[ "${NAGARE_LOCAL_REGISTRY_FORWARD}" =~ ^127\.0\.0\.1:([0-9]{1,5})$ ]] \
      && [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[1]}" -le 65535 ] || {
      echo "local registry forward must be a loopback host and port" >&2
      return 2
    }
    wire_destination="${NAGARE_LOCAL_REGISTRY_FORWARD}/${destination#"${NAGARE_REGISTRY_HOST}/"}"
  fi
  skopeo --policy "${policy}" copy --preserve-digests "${tls_args[@]}" "${auth_args[@]}" \
    "docker-archive:${archive}" "docker://${wire_destination}" >&2
)

publish() {
  case "${kind}" in
    BuildJobArtifact)
      NAGARE_ARTIFACT_DESTINATION="${destination}" \
      NAGARE_ARTIFACT_EXPECTED_DIGEST="${expected}" \
        bash "${script_dir}/upload-images.sh" --build-only >&2
      ;;
    KubeconfigArtifact) publish_kubeconfig ;;
    LocalRegistryArtifact)
      load_local_substrate
      [ "${destination}" = "$(jq -r .registryHost "${archive}")" ] || {
        echo "local registry destination differs from the reviewed specification" >&2; return 2;
      }
      k3d registry create "$(jq -r .registry "${archive}")" \
        --port "$(jq -r .registryPort "${archive}")" --no-help >&2
      ;;
    LocalClusterArtifact)
      load_local_substrate
      [ "${destination}" = "$(jq -r .cluster "${archive}")" ] || {
        echo "local cluster destination differs from the reviewed specification" >&2; return 2;
      }
      k3d cluster create "${destination}" \
        --image "$(jq -r .k3sImage "${archive}")" \
        --registry-use "$(jq -r .registryHost "${archive}")" \
        --port "$(jq -r .httpPort "${archive}")" \
        --port "$(jq -r .httpsPort "${archive}")" \
        --k3s-arg "$(jq -r .k3sArg "${archive}")" \
        --runtime-label "nagare.bootstrap.digest=${expected}@server:0" \
        --kubeconfig-update-default=false --kubeconfig-switch-context=false >&2
      ;;
    GceImageArtifact)
      NAGARE_ARTIFACT_DESTINATION="${destination}" \
      NAGARE_ARTIFACT_EXPECTED_DIGEST="sha256:${expected}" \
        bash "${script_dir}/upload-images.sh" >&2
      ;;
    OciImageArtifact)
      case "${destination}" in
        */attic:*)
          NAGARE_ARTIFACT_DESTINATION="${destination}" \
          NAGARE_ARTIFACT_EXPECTED_DIGEST="sha256:${expected}" \
          NAGARE_ARTIFACT_SOURCE_DIGEST="${source_digest}" \
            bash "${repo_root}/cluster/bootstrap/nix-cache/publish-image.sh" >&2
          ;;
        */net-certmanager-controller:v1.14.0-nagare.1)
          NAGARE_ARTIFACT_DESTINATION="${destination}" \
          NAGARE_ARTIFACT_EXPECTED_DIGEST="sha256:${expected}" \
          NAGARE_ARTIFACT_SOURCE_DIGEST="sha256:${source_digest}" \
            bash "${repo_root}/cluster/bootstrap/net-certmanager/publish-image.sh" >&2
          ;;
        *) publish_oci_archive ;;
      esac
      ;;
    *) echo "artifact kind ${kind} has no publication transport" >&2; return 2 ;;
  esac
  observe
}

if [ "${action}" = observe ]; then observe; else publish; fi
