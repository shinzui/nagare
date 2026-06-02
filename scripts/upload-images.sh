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

PROJECT=tan-nb-exp
# IP-9 project-isolation guard: fail closed if gcloud's active project is wrong.
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  echo "fix: 'direnv allow' in the repo root, or 'export CLOUDSDK_CORE_PROJECT=$PROJECT'." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIXOS_DIR="${REPO_ROOT}/nixos"
PULUMI_DIR="${REPO_ROOT}/infra/pulumi"
IAP_SSH="${REPO_ROOT}/scripts/iap-ssh.sh"
REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
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

store_path="$(build_image)"
hash="$(image_hash "${store_path}")"
image_name="${OUTPUT}-${hash}"
gs_uri="gs://${BUCKET}/${image_name}.raw.tar.gz"
tarball="$(locate_tarball "${store_path}")"

upload_if_missing "${tarball}" "${gs_uri}"
register_if_missing "${image_name}" "${gs_uri}"

self_link="$(gcloud --project="${PROJECT}" compute images describe "${image_name}" --format='value(selfLink)')"
log "pulumi config set nagareImageSelfLink ${self_link}"
pulumi --cwd "${PULUMI_DIR}" config set nagareImageSelfLink "${self_link}"
log "Done."
