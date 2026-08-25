#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: cluster/bootstrap/auth-images/build-local-image.sh <nagare-access|shomei|en> [tag]

Builds one auth-plane image from local source checkouts instead of fetching the
private shomei/en repositories during Docker build.

Relevant environment variables:
  NAGARE_AUTH_PUSH=0             Build locally without pushing.
  NAGARE_AUTH_BUILDER=docker     Builder: docker, cloud-build, or k3s-import.
  NAGARE_AUTH_TAG=<tag>          Default tag when [tag] is omitted.
  NAGARE_AUTH_IMAGE=<image>      Exact image reference override.
  NAGARE_ACCESS_IMAGE=<image>    Exact image override for nagare-access.
  SHOMEI_IMAGE=<image>           Exact image override for shomei.
  EN_IMAGE=<image>               Exact image override for en.
  NAGARE_REGISTRY_HOST=<host>    Default: us-west1-docker.pkg.dev
  NAGARE_ARTIFACT_REGISTRY_ID=<repo>  Default: nagare
  NAGARE_CONTAINER_PLATFORM=<platform> Default: linux/amd64
  NAGARE_AUTH_CABAL_BUILD_FLAGS=<flags> Default: --jobs=1
  NAGARE_AUTH_CLOUD_BUILD_REGION=<region> Default: us-west1
  NAGARE_AUTH_CLOUD_BUILD_MACHINE_TYPE=<type> Default: e2-highcpu-32
  NAGARE_AUTH_CLOUD_BUILD_TIMEOUT=<duration> Default: 2h
  NAGARE_AUTH_REMOTE_INSTANCE=<instance> Default: nagare-01
  NAGARE_AUTH_K3S_IMAGE_PREFIX=<prefix> Default: dev.local/nagare-auth
  SHOMEI_SRC=<path>              Default: ../shomei sibling checkout.
  EN_SRC=<path>                  Default: ../en sibling checkout.
  CODD_SRC=<path>                Default: local Mori codd checkout; needed by Shomei builds.
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/../../.." && pwd)"
service="${1:-}"
[[ -n "$service" ]] || { usage; exit 2; }
shift || true

case "$service" in
  nagare-access|shomei|en) ;;
  *) usage; exit 2 ;;
esac

tag="${1:-${NAGARE_AUTH_TAG:-$(git -C "$root" rev-parse --short HEAD)}}"
registry_host="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"
artifact_repository="${NAGARE_ARTIFACT_REGISTRY_ID:-nagare}"
# Local mode (NAGARE_MODE=local, MasterPlan 16 Integration Point 1) builds for
# the host architecture so the image runs on the local k3d node; default the
# container platform to NAGARE_TARGET_PLATFORM from the profile when set.
platform="${NAGARE_CONTAINER_PLATFORM:-${NAGARE_TARGET_PLATFORM:-linux/amd64}}"
push="${NAGARE_AUTH_PUSH:-1}"
builder="${NAGARE_AUTH_BUILDER:-docker}"
mode="${NAGARE_MODE:-cloud}"

case "$builder" in
  docker|cloud-build|k3s-import) ;;
  *) fail "unsupported NAGARE_AUTH_BUILDER=$builder; expected docker, cloud-build, or k3s-import" ;;
esac

if [[ "$builder" == "cloud-build" && "$push" != "1" ]]; then
  fail "NAGARE_AUTH_BUILDER=cloud-build requires NAGARE_AUTH_PUSH=1 because the image is produced remotely"
fi

project="${CLOUDSDK_CORE_PROJECT:-}"
# In local mode there is no GCP project and gcloud must never be invoked
# (MasterPlan 16 Integration Point 2): skip the project lookup entirely.
if [[ -z "$project" && "$mode" != "local" ]]; then
  project="$(gcloud config get-value project 2>/dev/null || true)"
fi

if [[ "$builder" == "cloud-build" && ( -z "$project" || "$project" == "(unset)" ) ]]; then
  fail "NAGARE_AUTH_BUILDER=cloud-build requires CLOUDSDK_CORE_PROJECT or an active gcloud project"
fi

image_override="${NAGARE_AUTH_IMAGE:-}"
case "$service" in
  nagare-access) image_override="${NAGARE_ACCESS_IMAGE:-$image_override}" ;;
  shomei) image_override="${SHOMEI_IMAGE:-$image_override}" ;;
  en) image_override="${EN_IMAGE:-$image_override}" ;;
esac

if [[ -n "$image_override" ]]; then
  image="$image_override"
elif [[ "$mode" == "local" ]]; then
  # Local registry name: <registry-host>/<service>:<tag>, no GCP project segment.
  image="${NAGARE_REGISTRY_HOST:?NAGARE_REGISTRY_HOST must be set in local mode}/${service}:${tag}"
elif [[ "$builder" == "k3s-import" ]]; then
  image="${NAGARE_AUTH_K3S_IMAGE_PREFIX:-dev.local/nagare-auth}/${service}:${tag}"
elif [[ -n "$project" && "$project" != "(unset)" ]]; then
  image="${registry_host}/${project}/${artifact_repository}/${service}:${tag}"
elif [[ "$push" == "1" ]]; then
  fail "CLOUDSDK_CORE_PROJECT is not set and gcloud has no active project."
else
  image="nagare-auth/${service}:${tag}"
fi

shomei_src="${SHOMEI_SRC:-/Users/shinzui/Keikaku/bokuno/shomei}"
en_src="${EN_SRC:-/Users/shinzui/Keikaku/bokuno/en}"
codd_src="${CODD_SRC:-/Users/shinzui/Keikaku/hub/haskell/codd-project/codd}"

required_sources=("$en_src")
if [[ "$service" != "en" ]]; then
  required_sources+=("$shomei_src" "$codd_src")
fi
for path in "${required_sources[@]}"; do
  [[ -d "$path" ]] || fail "required source directory does not exist: $path"
done

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/nagare-auth-image.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

copy_tree() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  rsync -a \
    --exclude '.git' \
    --exclude '.direnv' \
    --exclude '.stack-work' \
    --exclude 'dist-newstyle' \
    --exclude 'node_modules' \
    --exclude 'result' \
    --exclude 'result-*' \
    --exclude '.ghc.environment.*' \
    --exclude '.live-test' \
    "$src"/ "$dst"/
}

mkdir -p "$tmpdir/workspace/deps" "$tmpdir/runtime/usr/local/bin"
cp "$script_dir/Dockerfile.local-haskell" "$tmpdir/Dockerfile.local-haskell"
copy_tree "$root" "$tmpdir/workspace/nagare"
copy_tree "$en_src" "$tmpdir/workspace/en"
if [[ "$service" != "en" ]]; then
  copy_tree "$shomei_src" "$tmpdir/workspace/shomei"
  copy_tree "$codd_src" "$tmpdir/workspace/deps/codd"
fi

write_common_cabal_tail() {
  cat <<'EOF'
  deps/codd

source-repository-package
  type: git
  location: https://github.com/sumo/hs-jose.git
  tag: d00ad1794287ddd2d839b927690b580e58183fd9

source-repository-package
  type: git
  location: https://github.com/shinzui/servant-openapi.git
  tag: 558b7b9ee3aaf3bff70a4cf1d6c8e2ed4eaccbde

source-repository-package
  type: git
  location: https://github.com/shinzui/openapi-hs.git
  tag: dfcd77d1af494fb3b968c7318e09830f4882dbcc

source-repository-package
  type: git
  location: https://github.com/shinzui/webauthn.git
  tag: c274e23a5e31aac8932bac6398b65e8bca584a99

package codd
  tests: False
  benchmarks: False

package jose
  tests: False
  benchmarks: False

package webauthn
  tests: False
  benchmarks: False

allow-newer:
  haxl:time,
  webauthn:*
EOF
}

write_shomei_packages() {
  cat <<'EOF'
  shomei/shomei-core
  shomei/shomei-jwt
  shomei/shomei-webauthn
  shomei/shomei-postgres
  shomei/shomei-migrations
  shomei/shomei-servant
  shomei/shomei-server
  shomei/shomei-client
EOF
}

write_en_packages() {
  cat <<'EOF'
  en/en-core
  en/en-migrations
  en/en-postgres
  en/en-servant
  en/en-server
  en/en-client
EOF
}

write_en_cabal_tail() {
  cat <<'EOF'

constraints:
  crypton >= 1.1

-- Current en source pins these GHC-9.12-compatible OpenAPI forks.
-- mori://shinzui/openapi-hs/repos/openapi-hs
source-repository-package
  type: git
  location: https://github.com/shinzui/openapi-hs.git
  tag: 965340a30fad0782f2c964ab97b4ab0f12fa044d

-- mori://shinzui/servant-openapi-hs/repos/servant-openapi-hs
source-repository-package
  type: git
  location: https://github.com/shinzui/servant-openapi-hs.git
  tag: 7cbbc234cb7c0e900495b2f676e2912a7f456ff0
EOF
}

cabal_targets=()
cabal_binaries=()
case "$service" in
  nagare-access)
    cabal_targets=(exe:nagare-access)
    cabal_binaries=(exe:nagare-access)
    {
      cat <<'EOF'
with-compiler: ghc-9.12.4
write-ghc-environment-files: never

constraints:
  time ==1.14

packages:
  nagare/cli/nagare-access
  nagare/cli/nagare-dsl
EOF
      write_shomei_packages
      write_en_packages
      write_common_cabal_tail
    } > "$tmpdir/workspace/cabal.project"
    cat > "$tmpdir/runtime/usr/local/bin/auth-entrypoint" <<'EOF'
#!/usr/bin/env sh
set -eu
exec /usr/local/bin/nagare-access "$@"
EOF
    ;;
  shomei)
    cabal_targets=(exe:shomei-server exe:shomei-admin)
    cabal_binaries=(exe:shomei-server exe:shomei-admin)
    {
      cat <<'EOF'
with-compiler: ghc-9.12.4
write-ghc-environment-files: never

packages:
EOF
      write_shomei_packages
      write_common_cabal_tail
    } > "$tmpdir/workspace/cabal.project"
    cp "$shomei_src/deploy/entrypoint.sh" "$tmpdir/runtime/usr/local/bin/auth-entrypoint"
    ;;
  en)
    cabal_targets=(exe:en-server exe:en-migrate)
    cabal_binaries=(exe:en-server exe:en-migrate)
    {
      cat <<'EOF'
with-compiler: ghc-9.12.4
write-ghc-environment-files: never

packages:
EOF
      write_en_packages
      write_en_cabal_tail
    } > "$tmpdir/workspace/cabal.project"
    cat > "$tmpdir/runtime/usr/local/bin/auth-entrypoint" <<'EOF'
#!/usr/bin/env sh
set -eu
exec /usr/local/bin/en-server "$@"
EOF
    ;;
esac

chmod 0555 "$tmpdir/runtime/usr/local/bin/auth-entrypoint"

if [[ "$builder" == "cloud-build" ]]; then
  region="${NAGARE_AUTH_CLOUD_BUILD_REGION:-us-west1}"
  machine_type="${NAGARE_AUTH_CLOUD_BUILD_MACHINE_TYPE:-e2-highcpu-32}"
  timeout="${NAGARE_AUTH_CLOUD_BUILD_TIMEOUT:-2h}"
  cat > "$tmpdir/cloudbuild.yaml" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    env:
      - DOCKER_BUILDKIT=1
    args:
      - build
      - --platform
      - "$platform"
      - --build-arg
      - "CABAL_TARGETS=${cabal_targets[*]}"
      - --build-arg
      - "CABAL_BINARIES=${cabal_binaries[*]}"
      - --build-arg
      - "CABAL_BUILD_FLAGS=${NAGARE_AUTH_CABAL_BUILD_FLAGS:---jobs=1}"
      - -f
      - Dockerfile.local-haskell
      - -t
      - "$image"
      - .
images:
  - "$image"
EOF
  gcloud builds submit "$tmpdir" \
    --config "$tmpdir/cloudbuild.yaml" \
    --project "$project" \
    --region "$region" \
    --machine-type "$machine_type" \
    --timeout "$timeout"
elif [[ "$builder" == "k3s-import" ]]; then
  remote_instance="${NAGARE_AUTH_REMOTE_INSTANCE:-nagare-01}"
  safe_tag="${tag//[^A-Za-z0-9_.-]/-}"
  archive="${TMPDIR:-/tmp}/nagare-auth-image-${service}-${safe_tag}-$$.tar.gz"
  remote_archive="/tmp/nagare-auth-image-${service}-${safe_tag}-$$.tar.gz"
  rm -f "$archive"
  trap 'cleanup; rm -f "$archive"' EXIT
  tar -C "$tmpdir" -czf "$archive" .
  "$root/scripts/iap-ssh.sh" scp "$archive" "${remote_instance}:${remote_archive}"
  remote_script=$(cat <<EOF
set -euo pipefail
remote_archive=$(printf '%q' "$remote_archive")
image=$(printf '%q' "$image")
platform=$(printf '%q' "$platform")
cabal_targets=$(printf '%q' "${cabal_targets[*]}")
cabal_binaries=$(printf '%q' "${cabal_binaries[*]}")
cabal_build_flags=$(printf '%q' "${NAGARE_AUTH_CABAL_BUILD_FLAGS:---jobs=1}")
workdir=\$(mktemp -d /tmp/nagare-auth-build.XXXXXX)
cleanup() {
  set +e
  if [ -n "\${workdir:-}" ] && [ -d "\$workdir" ]; then
    HOME="\$workdir/home" nix shell nixpkgs#podman -c podman image rm "\$image" >/dev/null 2>&1 || true
    HOME="\$workdir/home" nix shell nixpkgs#podman -c podman system reset -f >/dev/null 2>&1 || true
    HOME="\$workdir/home" nix shell nixpkgs#podman -c podman unshare rm -rf "\$workdir/home/.local/share/containers" >/dev/null 2>&1 || true
    rm -rf "\$workdir"
  fi
  rm -f "\$remote_archive"
}
trap cleanup EXIT
tar -xzf "\$remote_archive" -C "\$workdir"
mkdir -p "\$workdir/home/.config/containers"
printf '%s\n' '{"default":[{"type":"insecureAcceptAnything"}]}' > "\$workdir/home/.config/containers/policy.json"
HOME="\$workdir/home" nix shell nixpkgs#podman -c podman build \
  --platform "\$platform" \
  --build-arg "CABAL_TARGETS=\$cabal_targets" \
  --build-arg "CABAL_BINARIES=\$cabal_binaries" \
  --build-arg "CABAL_BUILD_FLAGS=\$cabal_build_flags" \
  -f "\$workdir/Dockerfile.local-haskell" \
  -t "\$image" \
  "\$workdir"
HOME="\$workdir/home" nix shell nixpkgs#podman -c podman save -o "\$workdir/image.tar" "\$image"
sudo k3s ctr images import "\$workdir/image.tar" >/dev/null
sudo k3s ctr images list name=="\$image"
EOF
)
  "$root/scripts/iap-ssh.sh" ssh "$remote_instance" -- "$remote_script"
else
  docker build \
    --platform "$platform" \
    --build-arg "CABAL_TARGETS=${cabal_targets[*]}" \
    --build-arg "CABAL_BINARIES=${cabal_binaries[*]}" \
    --build-arg "CABAL_BUILD_FLAGS=${NAGARE_AUTH_CABAL_BUILD_FLAGS:---jobs=1}" \
    -f "$tmpdir/Dockerfile.local-haskell" \
    -t "$image" \
    "$tmpdir"

  if [[ "$push" == "1" ]]; then
    if [[ "$mode" == "local" ]]; then
      # Local registry is plain HTTP and unauthenticated; push straight to it
      # without gcloud (MasterPlan 16 Integration Point 2). The host-side
      # insecure-registries prerequisite is documented in nagare.local.env.example.
      docker push "$image"
    else
      gcloud auth configure-docker "$registry_host" --quiet
      docker push "$image"
    fi
  fi
fi

echo "$image"
