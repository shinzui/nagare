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

# Load the target profile and run the configurable, fail-closed project-isolation
# preflight (EP-60). Exports TARGET_PROJECT / TARGET_REGION / TARGET_ZONE.
source "$(dirname "${BASH_SOURCE[0]}")/lib/target.sh"
_require_target_project
PROJECT="$TARGET_PROJECT"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIXOS_DIR="${REPO_ROOT}/nixos"
PULUMI_DIR="${REPO_ROOT}/infra/pulumi"
IAP_SSH="${REPO_ROOT}/scripts/iap-ssh.sh"
REGION="${TARGET_REGION}"
BUILDER_INSTANCE="${BUILDER_INSTANCE:-nix-builder-x86}"
OUTPUT="nagare-image"
ATTR="packages.x86_64-linux.${OUTPUT}"

log() { printf '[upload-images] %s\n' "$*" >&2; }

BUCKET="$(pulumi --cwd "${PULUMI_DIR}" config get imageBucket)"
if [ -z "${BUCKET}" ]; then
  echo "imageBucket not set in Pulumi config. Run: pulumi --cwd infra/pulumi config set imageBucket <name>" >&2
  exit 2
fi
log "Target bucket: gs://${BUCKET}/"
if ! gsutil ls -b "gs://${BUCKET}/" >/dev/null 2>&1; then
  log "Creating bucket gs://${BUCKET}/ in ${REGION}"
  gsutil mb -p "${PROJECT}" -l "${REGION}" -b on "gs://${BUCKET}/"
fi

# Build the image by FULL attribute path so aarch64-darwin offloads to the
# x86_64-linux remote builder. If the local copy-back over IAP-SSH drops on a
# multi-GB closure, recover by evaluating the (content-addressed) output path
# and checking it exists on the builder.
build_image() {
  local out_path
  if out_path=$( (cd "${NIXOS_DIR}" && nix build --print-out-paths --no-link ".#${ATTR}") 2>/tmp/nagare-nix-build.err ); then
    echo "${out_path}"; return 0
  fi
  out_path=$(cd "${NIXOS_DIR}" && nix eval --raw ".#${ATTR}" 2>/dev/null) || {
    log "nix build failed and nix eval could not resolve the output path:"; cat /tmp/nagare-nix-build.err >&2; return 1; }
  local q; q="$(printf '%q' "${out_path}")"
  if [ -n "${BUILDER_INSTANCE}" ] && "${IAP_SSH}" ssh "${BUILDER_INSTANCE}" -- "test -d ${q}" 2>/dev/null; then
    log "Local copy-back failed but build is on builder at ${out_path} — using builder upload"
    echo "${out_path}"; return 0
  fi
  log "Build failed and is not on the builder; surfacing the nix error:"; cat /tmp/nagare-nix-build.err >&2; return 1
}

image_hash() { local b; b="$(basename "$1")"; b="${b%%-*}"; echo "${b:0:12}"; }

locate_tarball() {
  local store_path="$1" tarball
  if [ -d "${store_path}" ]; then
    tarball="$(find "${store_path}" -maxdepth 1 -name '*.raw.tar.gz' -print -quit)"
  elif [ -n "${BUILDER_INSTANCE}" ]; then
    local q; q="$(printf '%q' "${store_path}")"
    tarball="$("${IAP_SSH}" ssh "${BUILDER_INSTANCE}" -- "find ${q} -maxdepth 1 -type f -name '*.raw.tar.gz' -print -quit")"
  fi
  [ -n "${tarball}" ] || { echo "no *.raw.tar.gz in ${store_path}" >&2; return 1; }
  echo "${tarball}"
}

upload_if_missing() {
  local src="$1" uri="$2"
  if gsutil -q stat "${uri}"; then log "Already in GCS: ${uri}"; return 0; fi
  if [ -f "${src}" ]; then
    log "Uploading ${src} -> ${uri}"; gsutil cp "${src}" "${uri}"
  else
    log "Uploading from builder: ${src} -> ${uri}"
    "${IAP_SSH}" ssh "${BUILDER_INSTANCE}" -- "sudo -u builder gsutil cp '${src}' '${uri}'"
  fi
}

register_if_missing() {
  local name="$1" uri="$2"
  if gcloud --project="${PROJECT}" compute images describe "${name}" --format='value(name)' >/dev/null 2>&1; then
    log "Already registered: ${name}"
  else
    log "Registering GCE image ${name} from ${uri}"
    gcloud --project="${PROJECT}" compute images create "${name}" --source-uri "${uri}" --quiet
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
    if ! "${IAP_SSH}" ssh "${BUILDER_INSTANCE}" -- "gzip -t ${q}" 2>/dev/null; then
      echo "refusing to upload: builder tarball ${path} is a truncated/corrupt gzip" >&2
      return 1
    fi
  fi
}

store_path="$(build_image)"
hash="$(image_hash "${store_path}")"
image_name="${OUTPUT}-${hash}"
gs_uri="gs://${BUCKET}/${image_name}.raw.tar.gz"
tarball="$(locate_tarball "${store_path}")"

verify_tarball "${tarball}"
upload_if_missing "${tarball}" "${gs_uri}"
register_if_missing "${image_name}" "${gs_uri}"

self_link="$(gcloud --project="${PROJECT}" compute images describe "${image_name}" --format='value(selfLink)')"
# The self-link embeds the project (.../projects/<project>/global/images/...), so it
# is target-specific: it must be regenerated per target and never committed for a
# foreign project (MasterPlan-12 Integration Point 3). `pulumi config set` writes it
# into the local stack config, which is a derived projection of the profile.
log "pulumi config set nagareImageSelfLink ${self_link}"
pulumi --cwd "${PULUMI_DIR}" config set nagareImageSelfLink "${self_link}"
log "Done."
