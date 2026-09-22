#!/usr/bin/env bash
# Build the Nagare NixOS GCE image on the remote x86_64-linux builder, upload
# the tarball to the image bucket, register it as a GCE image, and write its
# self-link to Pulumi config key `nagareImageSelfLink` (consumed by EP-2's
# instance component).
#
# Idempotent: existing GCS objects and registered GCE images are reused; only
# missing artifacts trigger writes. A rebuilt image gets a new content hash and
# therefore a new name, so old and new images coexist.
set -euo pipefail

if [ -n "${NAGARE_INVENTORY_TRANSACTION:-}" ] && [ "${NAGARE_INVENTORY_ADAPTER_CHILD:-}" != "artifact" ]; then
  echo "refusing inventory re-entry: upload-images.sh requires the artifact adapter child marker" >&2
  exit 2
fi

DRY_RUN=0
ALLOW_SHARED_BUILDER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --allow-shared-builder)
      [ "$#" -ge 2 ] || { echo "--allow-shared-builder requires a project" >&2; exit 2; }
      ALLOW_SHARED_BUILDER="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--dry-run] [--allow-shared-builder PROJECT]" >&2
      exit 2
      ;;
  esac
done

# Load the target profile and run the configurable, fail-closed project-isolation
# preflight (EP-60). Exports TARGET_PROJECT / TARGET_REGION / TARGET_ZONE.
source "$(dirname "${BASH_SOURCE[0]}")/lib/target.sh"
# Resolve the context-owned NixOS flake. NAGARE_HOST_FLAKE remains an explicit
# override for source compatibility and tests.
source "$(dirname "${BASH_SOURCE[0]}")/lib/host.sh"
_nagare_resolve_host_flake

REPO_ROOT="${NAGARE_REPO_ROOT}"
PULUMI_DIR="${REPO_ROOT}/infra/pulumi"
PROJECT="$TARGET_PROJECT"
REGION="${TARGET_REGION}"
BUILDER_PROJECT="${NAGARE_BUILDER_PROJECT}"
BUILDER_ZONE="${NAGARE_BUILDER_ZONE}"
BUILDER_INSTANCE="${NAGARE_BUILDER_INSTANCE}"
TARGET_SYSTEM="x86_64-linux"
OUTPUT="nagare-image"
ATTR="packages.x86_64-linux.${OUTPUT}"

log() { printf '[upload-images] %s\n' "$*" >&2; }

for builder_value in "${BUILDER_PROJECT}" "${BUILDER_ZONE}" "${BUILDER_INSTANCE}"; do
  case "${builder_value}" in
    ""|*[!A-Za-z0-9._:-]*)
      echo "refusing invalid builder project/zone/instance value: '${builder_value}'" >&2
      exit 2
      ;;
  esac
done

if [ "${BUILDER_PROJECT}" != "${PROJECT}" ]; then
  if [ "${ALLOW_SHARED_BUILDER}" != "${BUILDER_PROJECT}" ]; then
    echo "refusing shared builder: context '${NAGARE_CONTEXT}' targets project '${PROJECT}', but its builder project is '${BUILDER_PROJECT}'." >&2
    echo "repeat with --allow-shared-builder '${BUILDER_PROJECT}' to acknowledge that named project." >&2
    exit 2
  fi
  SHARED_BUILDER_EXCEPTION="yes (${ALLOW_SHARED_BUILDER})"
elif [ -n "${ALLOW_SHARED_BUILDER}" ] && [ "${ALLOW_SHARED_BUILDER}" != "${PROJECT}" ]; then
  echo "refusing shared builder acknowledgement '${ALLOW_SHARED_BUILDER}': effective builder project is '${BUILDER_PROJECT}'." >&2
  exit 2
else
  SHARED_BUILDER_EXCEPTION="no"
fi

context_alias="$(printf '%s' "${NAGARE_CONTEXT}" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_-' '-')"
BUILDER_ALIAS="nagare-builder-${context_alias}"
BUILDER_STATE_DIR="$(_nagare_state_dir)/${NAGARE_CONTEXT}/nix-builder"
SSH_CONFIG="${BUILDER_STATE_DIR}/ssh_config"
BUILDERS_FILE="${BUILDER_STATE_DIR}/builders"
BUILDER_KEY="${NIX_BUILDER_SSH_KEY:-/etc/nix/builder_ed25519}"
PROXY_BIN="$(command -v nagare-nix-builder-proxy || true)"
[ -n "${PROXY_BIN}" ] || PROXY_BIN="${REPO_ROOT}/scripts/nix-builder-proxy.sh"
[ -x "${PROXY_BIN}" ] || { echo "builder proxy is not executable: ${PROXY_BIN}" >&2; exit 2; }
for builder_path in "${SSH_CONFIG}" "${PROXY_BIN}" "${BUILDER_KEY}"; do
  case "${builder_path}" in
    *[[:space:]]*) echo "builder paths may not contain whitespace: ${builder_path}" >&2; exit 2 ;;
  esac
done

mkdir -p "${BUILDER_STATE_DIR}"
chmod 0700 "${BUILDER_STATE_DIR}"
ssh_tmp="${SSH_CONFIG}.tmp.$$"
builders_tmp="${BUILDERS_FILE}.tmp.$$"
trap 'rm -f "${ssh_tmp:-}" "${builders_tmp:-}" "${NIX_BUILD_ERR:-}"' EXIT
printf '%s\n' \
  "Host ${BUILDER_ALIAS}" \
  "  HostName ${BUILDER_ALIAS}" \
  "  User builder" \
  "  IdentityFile \"${BUILDER_KEY}\"" \
  "  IdentitiesOnly yes" \
  "  StrictHostKeyChecking no" \
  "  UserKnownHostsFile /dev/null" \
  "  GlobalKnownHostsFile /dev/null" \
  "  LogLevel ERROR" \
  "  ServerAliveInterval 15" \
  "  ServerAliveCountMax 3" \
  "  ProxyCommand \"${PROXY_BIN}\" \"${BUILDER_PROJECT}\" \"${BUILDER_ZONE}\" \"${BUILDER_INSTANCE}\"" \
  >"${ssh_tmp}"
BUILDER_URI="ssh-ng://builder@${BUILDER_ALIAS}"
BUILDERS_SPEC="${BUILDER_URI} ${TARGET_SYSTEM} ${BUILDER_KEY} 4 1 big-parallel,benchmark"
printf '%s\n' "${BUILDERS_SPEC}" >"${builders_tmp}"
chmod 0600 "${ssh_tmp}" "${builders_tmp}"
mv "${ssh_tmp}" "${SSH_CONFIG}"
mv "${builders_tmp}" "${BUILDERS_FILE}"

local_system="$(nix config show system 2>/dev/null || true)"
local_system="${local_system#system = }"
[ -n "${local_system}" ] || local_system="unknown"

show_builder_selection() {
  printf 'context: %s\n' "${NAGARE_CONTEXT}"
  printf 'project: %s\n' "${PROJECT}"
  printf 'local system: %s\n' "${local_system}"
  printf 'target system: %s\n' "${TARGET_SYSTEM}"
  printf 'builder URI: %s\n' "${BUILDER_URI}"
  printf 'builder project: %s\n' "${BUILDER_PROJECT}"
  printf 'builder zone: %s\n' "${BUILDER_ZONE}"
  printf 'builder instance: %s\n' "${BUILDER_INSTANCE}"
  printf 'shared builder exception: %s\n' "${SHARED_BUILDER_EXCEPTION}"
  printf 'builder spec: %s\n' "${BUILDERS_SPEC}"
  printf 'builder SSH config: %s\n' "${SSH_CONFIG}"
}

if [ "${DRY_RUN}" -eq 1 ]; then
  show_builder_selection
  printf 'registry: %s\n' "${NAGARE_REGISTRY_HOST}"
  printf 'host flake: %s\n' "${NAGARE_HOST_FLAKE}"
  printf 'image attribute: %s\n' "${ATTR}"
  printf 'pulumi directory: %s\n' "${PULUMI_DIR}"
  exit 0
fi

_require_target_project
show_builder_selection >&2

# Private scratch file for nix build's stderr. A fixed /tmp path is
# world-predictable and shared between concurrent runs and users.
NIX_BUILD_ERR="$(mktemp -t nagare-nix-build.XXXXXX)"

BUCKET="$(pulumi --cwd "${PULUMI_DIR}" config get imageBucket)"
if [ -z "${BUCKET}" ]; then
  echo "imageBucket not set in Pulumi config. Run: pulumi --cwd infra/pulumi config set imageBucket <name>" >&2
  exit 2
fi
log "Target bucket: gs://${BUCKET}/"
if ! gsutil ls -b "gs://${BUCKET}/" >/dev/null 2>&1; then
  echo "refusing to publish: inventory-owned image bucket gs://${BUCKET}/ does not exist" >&2
  echo "create or adopt the declared cloud foundation first; upload-images.sh never owns the bucket" >&2
  exit 2
fi
# GCS bucket names are GLOBAL, so a pre-existing same-named bucket in a FOREIGN
# project would answer "yes, it exists" and then receive the multi-gigabyte host
# image. Assert ownership by project number before anything else (EP-113).
_require_bucket_in_target_project "${BUCKET}" \
  "set a unique nagare:imageBucket with 'pulumi --cwd infra/pulumi config set imageBucket <unique-name>'."

# Build the image by FULL attribute path so aarch64-darwin offloads to the
# x86_64-linux remote builder. If the local copy-back over IAP-SSH drops on a
# multi-GB closure, recover by evaluating the (content-addressed) output path
# and checking it exists on the builder.
build_image() {
  local out_path
  if out_path=$( (cd "${NAGARE_HOST_FLAKE}" && NIX_SSHOPTS="-F${SSH_CONFIG}" \
    nix build --builders "${BUILDERS_SPEC}" --print-out-paths --no-link ".#${ATTR}") 2>"${NIX_BUILD_ERR}" ); then
    echo "${out_path}"; return 0
  fi
  out_path=$(cd "${NAGARE_HOST_FLAKE}" && nix eval --raw ".#${ATTR}" 2>/dev/null) || {
    log "nix build failed and nix eval could not resolve the output path:"; cat "${NIX_BUILD_ERR}" >&2; return 1; }
  local q; q="$(printf '%q' "${out_path}")"
  if ssh -F "${SSH_CONFIG}" "${BUILDER_ALIAS}" "test -d ${q}" 2>/dev/null; then
    log "Local copy-back failed but build is on builder at ${out_path} — using builder upload"
    echo "${out_path}"; return 0
  fi
  log "Build failed and is not on the builder; surfacing the nix error:"; cat "${NIX_BUILD_ERR}" >&2; return 1
}

image_hash() { local b; b="$(basename "$1")"; b="${b%%-*}"; echo "${b:0:12}"; }

locate_tarball() {
  local store_path="$1" tarball
  if [ -d "${store_path}" ]; then
    tarball="$(find "${store_path}" -maxdepth 1 -name '*.raw.tar.gz' -print -quit)"
  else
    local q; q="$(printf '%q' "${store_path}")"
    tarball="$(ssh -F "${SSH_CONFIG}" "${BUILDER_ALIAS}" "find ${q} -maxdepth 1 -type f -name '*.raw.tar.gz' -print -quit")"
  fi
  [ -n "${tarball}" ] || { echo "no *.raw.tar.gz in ${store_path}" >&2; return 1; }
  echo "${tarball}"
}

upload_if_missing() {
  local src="$1" uri="$2"
  if gsutil -q stat "${uri}"; then log "Already in GCS: ${uri}"; return 0; fi
  # Re-assert immediately before the write (EP-113). Not redundant with the
  # call above: the builder-side arm below uploads over SSH, and keeping the
  # guarantee local to the mutation removes any dependence on caller ordering.
  _require_bucket_in_target_project "${BUCKET}" \
    "set a unique nagare:imageBucket with 'pulumi --cwd infra/pulumi config set imageBucket <unique-name>'."
  if [ -f "${src}" ]; then
    log "Uploading ${src} -> ${uri}"; gsutil cp "${src}" "${uri}"
  else
    log "Uploading from builder: ${src} -> ${uri}"
    ssh -F "${SSH_CONFIG}" "${BUILDER_ALIAS}" "gsutil cp '${src}' '${uri}'"
  fi
}

register_if_missing() {
  local name="$1" uri="$2" digest="$3" description
  if description="$(gcloud --project="${PROJECT}" compute images describe "${name}" --format='value(description)' 2>/dev/null)"; then
    if [ -n "${NAGARE_INVENTORY_TRANSACTION:-}" ] && [ "${description}" != "nagare-content-digest=${digest}" ]; then
      echo "refusing existing GCE image ${name}: content digest ownership stamp differs from ${digest}" >&2
      return 1
    fi
    log "Already registered: ${name}"
  else
    log "Registering GCE image ${name} from ${uri}"
    gcloud --project="${PROJECT}" compute images create "${name}" --source-uri "${uri}" \
      --description "nagare-content-digest=${digest}" --quiet
  fi
}

# Fail closed if the tarball we are about to upload is not a complete,
# valid gzip stream. The remote->local copy-back of a multi-GB closure over
# the IAP tunnel can drop mid-transfer (a known flaky transfer; see this
# plan's Surprises), leaving a TRUNCATED local *.raw.tar.gz that nix never
# registers as a valid store path. Uploading that yields gcloud's opaque
# "The tar archive is not a valid image" at registration time. A cheap
# `gzip -t` here turns that into an early, obvious failure. For a tarball
# that lives only on the builder, verify it there instead.
verify_tarball() {
  local path="$1"
  if [ -f "${path}" ]; then
    if ! gzip -t "${path}" 2>/dev/null; then
      echo "refusing to upload: local tarball ${path} is a truncated/corrupt gzip" >&2
      echo "  (the builder->local copy-back likely dropped; re-run 'nix build .#${ATTR}' to re-copy)" >&2
      return 1
    fi
  else
    local q; q="$(printf '%q' "${path}")"
    if ! ssh -F "${SSH_CONFIG}" "${BUILDER_ALIAS}" "gzip -t ${q}" 2>/dev/null; then
      echo "refusing to upload: builder tarball ${path} is a truncated/corrupt gzip" >&2
      return 1
    fi
  fi
}

tarball_digest() {
  local path="$1" value q
  if [ -f "${path}" ]; then
    value="$(shasum -a 256 "${path}" | awk '{print $1}')"
  else
    q="$(printf '%q' "${path}")"
    value="$(ssh -F "${SSH_CONFIG}" "${BUILDER_ALIAS}" "sha256sum ${q}" | awk '{print $1}')"
  fi
  printf 'sha256:%s\n' "${value}"
}

store_path="$(build_image)"
hash="$(image_hash "${store_path}")"
image_name="${OUTPUT}-${hash}"
gs_uri="gs://${BUCKET}/${image_name}.raw.tar.gz"
tarball="$(locate_tarball "${store_path}")"

verify_tarball "${tarball}"
content_digest="$(tarball_digest "${tarball}")"
if [ -n "${NAGARE_INVENTORY_TRANSACTION:-}" ]; then
  [ -n "${NAGARE_ARTIFACT_EXPECTED_DIGEST:-}" ] || { echo "inventory publication requires NAGARE_ARTIFACT_EXPECTED_DIGEST" >&2; exit 2; }
  [ "${content_digest}" = "${NAGARE_ARTIFACT_EXPECTED_DIGEST}" ] || {
    echo "refusing publication: built content ${content_digest} differs from reviewed ${NAGARE_ARTIFACT_EXPECTED_DIGEST}" >&2
    exit 2
  }
  expected_destination="projects/${PROJECT}/global/images/${image_name}"
  [ "${NAGARE_ARTIFACT_DESTINATION:-}" = "${expected_destination}" ] || {
    echo "refusing publication: built destination ${expected_destination} differs from reviewed ${NAGARE_ARTIFACT_DESTINATION:-<unset>}" >&2
    exit 2
  }
fi
upload_if_missing "${tarball}" "${gs_uri}"
register_if_missing "${image_name}" "${gs_uri}" "${content_digest}"

self_link="$(gcloud --project="${PROJECT}" compute images describe "${image_name}" --format='value(selfLink)')"
# The self-link embeds the project (.../projects/<project>/global/images/...), so it
# is target-specific: it must be regenerated per target and never committed for a
# foreign project (MasterPlan-12 Integration Point 3). `pulumi config set` writes it
# into the local stack config, which is a derived projection of the profile.
if [ -n "${NAGARE_INVENTORY_TRANSACTION:-}" ]; then
  printf 'nagare-artifact\tgce-image\t%s\t%s\n' "${self_link}" "${content_digest}"
  log "bounded publication complete; a new Pulumi review must bind nagareImageSelfLink"
else
  log "legacy path: pulumi config set nagareImageSelfLink ${self_link}"
  pulumi --cwd "${PULUMI_DIR}" config set nagareImageSelfLink "${self_link}"
fi
log "Done."
