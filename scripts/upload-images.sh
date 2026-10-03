#!/usr/bin/env bash
# Build the Nagare NixOS GCE image on the remote x86_64-linux builder, upload
# the tarball to the image bucket, and register it as a GCE image. Reviewed
# bootstrap separates the build, publication, and Pulumi image-config effects.
# The legacy direct path still writes `nagareImageSelfLink` itself.
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
BUILD_MODE=publish
REQUIRE_READ_ONLY=0
ALLOW_SHARED_BUILDER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-read-only)
      REQUIRE_READ_ONLY=1
      shift
      ;;
    --inspect-build|--describe-build|--build-only)
      [ "${BUILD_MODE}" = publish ] || { echo "choose one build mode" >&2; exit 2; }
      BUILD_MODE="${1#--}"
      shift
      ;;
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
      echo "usage: $0 [--dry-run|--inspect-build|--describe-build|--build-only] [--allow-shared-builder PROJECT]" >&2
      exit 2
      ;;
  esac
done
if [ "$REQUIRE_READ_ONLY" -eq 1 ] && [ "$BUILD_MODE" != inspect-build ] && [ "$BUILD_MODE" != describe-build ]; then
  echo '--require-read-only requires an inspection mode' >&2
  exit 2
fi
# Outside the artifact adapter, the legacy publish path also writes the
# inventory-managed Pulumi config (nagareImageSelfLink). Refuse it once the
# context has inventory history; reviewed host image publication replaces it.
if [ "${NAGARE_INVENTORY_ADAPTER_CHILD:-}" != "artifact" ] && [ "$DRY_RUN" -eq 0 ] && [ "$BUILD_MODE" = publish ]; then
  "${NAGARECTL_BIN:-nagarectl}" inventory guard-legacy upload-images
fi

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
PROXY_MODE=""
case "$BUILD_MODE" in
  inspect-build|describe-build)
    SSH_CONFIG="${BUILDER_STATE_DIR}/ssh_config_read_only"
    PROXY_MODE=" --read-only"
    ;;
esac
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
  "  ProxyCommand \"${PROXY_BIN}\" \"${BUILDER_PROJECT}\" \"${BUILDER_ZONE}\" \"${BUILDER_INSTANCE}\"${PROXY_MODE}" \
  >"${ssh_tmp}"
BUILDER_URI="ssh-ng://builder@${BUILDER_ALIAS}"
BUILDERS_SPEC="${BUILDER_URI} ${TARGET_SYSTEM} ${BUILDER_KEY} 4 1 big-parallel,benchmark,kvm"
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
  printf 'builder build transport: pinned IAP loopback tunnel\n'
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

image_build_path() {
  (cd "${NAGARE_HOST_FLAKE}" && nix eval --raw ".#${ATTR}" --no-update-lock-file)
}

check_reviewed_build() {
  local path="$1" digest
  digest="$(printf '%s' "${path}" | shasum -a 256 | awk '{print $1}')"
  if [ -n "${NAGARE_ARTIFACT_DESTINATION:-}" ] || [ -n "${NAGARE_ARTIFACT_EXPECTED_DIGEST:-}" ]; then
    [ "${NAGARE_ARTIFACT_DESTINATION:-}" = "${path}" ] || {
      echo "refusing build: output path differs from the reviewed destination" >&2; return 2;
    }
    [ "${NAGARE_ARTIFACT_EXPECTED_DIGEST:-}" = "${digest}" ] || {
      echo "refusing build: output path digest differs from the review" >&2; return 2;
    }
  fi
  printf '%s' "${digest}"
}

build_present() {
  local path="$1" q result
  [ -d "${path}" ] && return 0
  q="$(printf '%q' "${path}")"
  result="$(ssh -F "${SSH_CONFIG}" "${BUILDER_ALIAS}" "if test -d ${q}; then printf present; else printf missing; fi")" || {
    echo 'host image observation unavailable; failed transport is not absence' >&2
    return 2
  }
  case "$result" in
    present) return 0 ;;
    missing) return 1 ;;
    *) echo 'invalid host image observation' >&2; return 2 ;;
  esac
}

if [ "${BUILD_MODE}" = inspect-build ]; then
  # Observation is about the immutable reviewed output, not today's checkout.
  # Build execution still evaluates and checks its output against the review.
  store_path="${NAGARE_ARTIFACT_DESTINATION:-}"
  if [ -z "${store_path}" ]; then store_path="$(image_build_path)"; fi
  [[ "${store_path}" = /* ]] || { echo "build destination must be absolute" >&2; exit 2; }
  reviewed_digest="$(check_reviewed_build "${store_path}")"
  if build_present "${store_path}"; then build_status=present; else
    observed_status="$?"
    [ "$observed_status" -eq 1 ] || exit "$observed_status"
    build_status=missing
  fi
  printf 'nagare-build\t%s\t%s\t%s\n' "${build_status}" "${store_path}" "${reviewed_digest}"
  exit 0
fi

# Private scratch file for nix build's stderr. A fixed /tmp path is
# world-predictable and shared between concurrent runs and users.
NIX_BUILD_ERR="$(mktemp -t nagare-nix-build.XXXXXX)"

if [ "${BUILD_MODE}" = publish ]; then
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
  # GCS bucket names are global. Assert project ownership before publication.
  _require_bucket_in_target_project "${BUCKET}" \
    "set a unique nagare:imageBucket with 'pulumi --cwd infra/pulumi config set imageBucket <unique-name>'."
fi

# Build the image by FULL attribute path so aarch64-darwin offloads to the
# x86_64-linux remote builder. If the local copy-back over IAP-SSH drops on a
# multi-GB closure, recover by evaluating the (content-addressed) output path
# and checking it exists on the builder.
build_image() {
  local out_path direct_port host_key_b64 host_key_line scanned_host_key_b64 tunnel_log tunnel_pid status ready deadline
  local direct_builders
  direct_port="${NIX_BUILDER_TUNNEL_PORT:-}"
  host_key_b64="${NIX_BUILDER_HOST_KEY_B64:-}"
  tunnel_pid=""
  tunnel_log=""
  # This function runs inside a command substitution. Keep its tunnel bound to
  # that subprocess even if evaluation, copy-back, or a signal exits early.
  daemon_tunnel_pid=""
  daemon_tunnel_log=""
  trap 'if [ -n "${daemon_tunnel_pid:-}" ]; then kill "${daemon_tunnel_pid}" 2>/dev/null || true; wait "${daemon_tunnel_pid}" 2>/dev/null || true; fi; [ -z "${daemon_tunnel_log:-}" ] || rm -f "${daemon_tunnel_log}"' EXIT
  if [ -n "${direct_port}" ]; then
    [[ "${direct_port}" =~ ^[0-9]+$ ]] && [ "${direct_port}" -gt 0 ] && [ "${direct_port}" -le 65535 ] \
      && [[ "${host_key_b64}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || {
        echo "external builder tunnel requires a valid port and pinned host key" >&2; return 2;
      }
  else
    status="$(gcloud --project="${BUILDER_PROJECT}" compute instances describe "${BUILDER_INSTANCE}" \
      --zone="${BUILDER_ZONE}" --format='value(status)')" || return 1
    if [ "${status}" != RUNNING ]; then
      gcloud --project="${BUILDER_PROJECT}" compute instances start "${BUILDER_INSTANCE}" \
        --zone="${BUILDER_ZONE}" --quiet >/dev/null || return 1
    fi
    tunnel_log="$(mktemp -t nagare-builder-daemon-tunnel.XXXXXX)"
    daemon_tunnel_log="${tunnel_log}"
    ready=0
    for _attempt in 1 2 3 4 5; do
      direct_port=$((30000 + RANDOM % 30000))
      : >"${tunnel_log}"
      gcloud --project="${BUILDER_PROJECT}" compute start-iap-tunnel "${BUILDER_INSTANCE}" 22 \
        --zone="${BUILDER_ZONE}" --local-host-port="localhost:${direct_port}" --quiet \
        >"${tunnel_log}" 2>&1 &
      tunnel_pid=$!
      daemon_tunnel_pid="${tunnel_pid}"
      deadline=$((SECONDS + 60))
      while [ "${SECONDS}" -lt "${deadline}" ]; do
        if (echo ""; sleep 1) | nc -w 5 127.0.0.1 "${direct_port}" 2>/dev/null | grep '^SSH-' >/dev/null; then
          ready=1
          break
        fi
        kill -0 "${tunnel_pid}" 2>/dev/null || break
        sleep 1
      done
      [ "${ready}" -eq 1 ] && break
      kill "${tunnel_pid}" 2>/dev/null || true
      wait "${tunnel_pid}" 2>/dev/null || true
      tunnel_pid=""
      daemon_tunnel_pid=""
    done
    if [ "${ready}" -ne 1 ]; then
      cat "${tunnel_log}" >&2 || true
      rm -f "${tunnel_log}"
      echo "builder IAP tunnel did not become ready" >&2
      return 1
    fi
    host_key_line="$(ssh-keyscan -T 5 -t ed25519 -p "${direct_port}" 127.0.0.1 2>/dev/null \
      | awk '$2 == "ssh-ed25519" {print $2 " " $3; exit}')" || true
    if [ -z "${host_key_line}" ]; then
      kill "${tunnel_pid}" 2>/dev/null || true
      wait "${tunnel_pid}" 2>/dev/null || true
      rm -f "${tunnel_log}"
      echo "builder host key could not be read through the IAP tunnel" >&2
      return 1
    fi
    scanned_host_key_b64="$(printf '%s\n' "${host_key_line}" | base64 | tr -d '\n')"
    if [ -n "${host_key_b64}" ] && [ "${host_key_b64}" != "${scanned_host_key_b64}" ]; then
      echo "builder host key differs from the pinned key" >&2
      return 1
    fi
    host_key_b64="${scanned_host_key_b64}"
  fi
  # The macOS Nix daemon performs distributed builds as root and does not
  # inherit the caller's ProxyCommand configuration. A pinned loopback IAP
  # endpoint makes the same reviewed derivation reachable by that daemon.
  direct_builders="ssh-ng://builder@localhost:${direct_port} ${TARGET_SYSTEM} ${BUILDER_KEY} 4 1 big-parallel,benchmark,kvm - ${host_key_b64}"
  if out_path=$( (cd "${NAGARE_HOST_FLAKE}" && NIX_SSHOPTS= \
    nix build --builders "${direct_builders}" --print-out-paths --no-link ".#${ATTR}" --no-update-lock-file) 2>"${NIX_BUILD_ERR}" ); then
    if [ -n "${tunnel_pid}" ]; then
      kill "${tunnel_pid}" 2>/dev/null || true
      wait "${tunnel_pid}" 2>/dev/null || true
      rm -f "${tunnel_log}"
      daemon_tunnel_pid=""
      daemon_tunnel_log=""
    fi
    echo "${out_path}"; return 0
  fi
  if [ -n "${tunnel_pid}" ]; then
    kill "${tunnel_pid}" 2>/dev/null || true
    wait "${tunnel_pid}" 2>/dev/null || true
    rm -f "${tunnel_log}"
    daemon_tunnel_pid=""
    daemon_tunnel_log=""
  fi
  out_path=$(cd "${NAGARE_HOST_FLAKE}" && nix eval --raw ".#${ATTR}" --no-update-lock-file 2>/dev/null) || {
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

if [ "${BUILD_MODE}" = describe-build ]; then
  store_path="$(image_build_path)"
  build_present "${store_path}" || { echo "host image build is absent" >&2; exit 2; }
  tarball="$(locate_tarball "${store_path}")"
  verify_tarball "${tarball}"
  content_digest="$(tarball_digest "${tarball}")"
  printf 'nagare-image\t%s\t%s\t%s\n' "${store_path}" "${OUTPUT}-$(image_hash "${store_path}")" "${content_digest#sha256:}"
  exit 0
fi

if [ "${BUILD_MODE}" = build-only ]; then
  reviewed_path="$(image_build_path)"
  check_reviewed_build "${reviewed_path}" >/dev/null
fi
store_path="$(build_image)"
if [ "${BUILD_MODE}" = build-only ]; then
  [ "${store_path}" = "${reviewed_path}" ] || {
    echo "refusing build: Nix returned a different output path from the review" >&2; exit 2;
  }
  reviewed_digest="$(check_reviewed_build "${store_path}")"
  tarball="$(locate_tarball "${store_path}")"
  verify_tarball "${tarball}"
  printf 'nagare-build\tpresent\t%s\t%s\n' "${store_path}" "${reviewed_digest}"
  exit 0
fi
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
