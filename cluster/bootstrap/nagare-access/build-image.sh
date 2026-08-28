#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ "${NAGARE_AUTH_LOCAL_SOURCES:-0}" == "1" || "${NAGARE_ACCESS_LOCAL_SOURCES:-0}" == "1" ]]; then
  exec "$ROOT/cluster/bootstrap/auth-images/build-local-image.sh" nagare-access "$@"
fi
# shellcheck source=scripts/lib/release.sh
source "$ROOT/scripts/lib/release.sh"

REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"
ARTIFACT_REPOSITORY="${NAGARE_ARTIFACT_REGISTRY_ID:-nagare}"
PLATFORM="${NAGARE_CONTAINER_PLATFORM:-linux/amd64}"
TAG="${1:-${NAGARE_AUTH_TAG:-$(nagare_release_source_tag "$ROOT")}}"

PROJECT="${CLOUDSDK_CORE_PROJECT:-}"
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
fi

if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  echo "CLOUDSDK_CORE_PROJECT is not set and gcloud has no active project." >&2
  exit 1
fi

IMAGE="${NAGARE_ACCESS_IMAGE:-${REGISTRY_HOST}/${PROJECT}/${ARTIFACT_REPOSITORY}/nagare-access:${TAG}}"
BUILD_ARGS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  BUILD_ARGS+=(--secret id=github_token,env=GITHUB_TOKEN)
fi

docker build \
  --platform "$PLATFORM" \
  "${BUILD_ARGS[@]}" \
  -f "$ROOT/cli/nagare-access/Dockerfile" \
  -t "$IMAGE" \
  "$ROOT"

if [[ "${NAGARE_ACCESS_PUSH:-1}" == "1" ]]; then
  gcloud auth configure-docker "$REGISTRY_HOST" --quiet
  docker push "$IMAGE"
fi

echo "$IMAGE"
