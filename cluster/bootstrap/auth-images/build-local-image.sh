#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: cluster/bootstrap/auth-images/build-local-image.sh <nagare-access|shomei|en> [tag]

Builds one auth-plane image from local source checkouts instead of fetching the
private shomei/en repositories during Docker build.

Relevant environment variables:
  NAGARE_AUTH_PUSH=0             Build locally without pushing.
  NAGARE_AUTH_BUILDER=docker     Builder: docker or cloud-build.
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
  SHOMEI_SRC=<path>              Default: ../shomei sibling checkout.
  EN_SRC=<path>                  Default: ../en sibling checkout.
  CODD_SRC=<path>                Default: local mori codd checkout package dir.
  JOSE_SRC=<path>                Default: local mori hs-jose package dir.
  WEBAUTHN_SRC=<path>            Default: local mori webauthn package dir.
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
platform="${NAGARE_CONTAINER_PLATFORM:-linux/amd64}"
push="${NAGARE_AUTH_PUSH:-1}"
builder="${NAGARE_AUTH_BUILDER:-docker}"

case "$builder" in
  docker|cloud-build) ;;
  *) fail "unsupported NAGARE_AUTH_BUILDER=$builder; expected docker or cloud-build" ;;
esac

if [[ "$builder" == "cloud-build" && "$push" != "1" ]]; then
  fail "NAGARE_AUTH_BUILDER=cloud-build requires NAGARE_AUTH_PUSH=1 because the image is produced remotely"
fi

project="${CLOUDSDK_CORE_PROJECT:-}"
if [[ -z "$project" ]]; then
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
jose_src="${JOSE_SRC:-/Users/shinzui/Keikaku/hub/haskell/jose-project/hs-jose}"
webauthn_src="${WEBAUTHN_SRC:-/Users/shinzui/Keikaku/hub/haskell/webauthn-project/webauthn}"

for path in "$shomei_src" "$en_src" "$codd_src" "$jose_src" "$webauthn_src"; do
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
copy_tree "$shomei_src" "$tmpdir/workspace/shomei"
copy_tree "$en_src" "$tmpdir/workspace/en"
copy_tree "$codd_src" "$tmpdir/workspace/deps/codd"
copy_tree "$jose_src" "$tmpdir/workspace/deps/jose"
copy_tree "$webauthn_src" "$tmpdir/workspace/deps/webauthn"

write_common_cabal_tail() {
  cat <<'EOF'
  deps/codd
  deps/jose
  deps/webauthn

package codd
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

write_codd_cabal_tail() {
  cat <<'EOF'
  deps/codd

package codd
  tests: False
  benchmarks: False
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
    cabal_targets=(exe:en-server)
    cabal_binaries=(exe:en-server)
    {
      cat <<'EOF'
with-compiler: ghc-9.12.4
write-ghc-environment-files: never

packages:
EOF
      write_en_packages
      write_codd_cabal_tail
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
    gcloud auth configure-docker "$registry_host" --quiet
    docker push "$image"
  fi
fi

echo "$image"
