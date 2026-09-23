#!/usr/bin/env bash
# Gated disposable registry proof for the reviewed patched-controller publisher.
set -euo pipefail

if [ "${NAGARE_EP147_TEST_IMAGE_PUBLISH:-}" != 1 ]; then
  echo "set NAGARE_EP147_TEST_IMAGE_PUBLISH=1 for the disposable registry test" >&2
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/nagare-controller-publish-test.XXXXXX")"
container="nagare-controller-publish-test-$$"
cleanup() {
  docker container stop "${container}" >/dev/null 2>&1 || true
  docker container rm "${container}" >/dev/null 2>&1 || true
  rm -rf "${work}"
}
trap cleanup EXIT

printf 'fixture-controller\n' > "${work}/payload"
printf 'FROM scratch\nCOPY payload /payload\n' > "${work}/Dockerfile"
docker build --quiet --platform linux/amd64 \
  -t nagare/net-certmanager-controller:v1.14.0-nagare.1 "${work}" >/dev/null
docker save nagare/net-certmanager-controller:v1.14.0-nagare.1 | gzip > "${work}/archive.tar.gz"

docker run -d --name "${container}" -p 127.0.0.1::5000 registry:2 >/dev/null
port="$(docker port "${container}" 5000/tcp | sed -n 's/.*://p')"
test -n "${port}"
registry="127.0.0.1:${port}"
source_hash="$(shasum -a 256 "${work}/archive.tar.gz" | awk '{print $1}')"
policy="${work}/policy.json"
printf '%s\n' '{"default":[{"type":"insecureAcceptAnything"}]}' > "${policy}"
image_digest="$(skopeo --policy "${policy}" inspect --format '{{.Digest}}' "docker-archive:${work}/archive.tar.gz")"
destination="${registry}/net-certmanager-controller:v1.14.0-nagare.1"

if ! NAGARE_MODE=local \
NAGARE_NIX_CACHE_ENABLED=0 \
NAGARE_REGISTRY_HOST="${registry}" \
NAGARE_INVENTORY_ADAPTER_CHILD=artifact \
NAGARE_ARTIFACT_DESTINATION="${destination}" \
NAGARE_ARTIFACT_EXPECTED_DIGEST="${image_digest}" \
NAGARE_ARTIFACT_SOURCE_DIGEST="sha256:${source_hash}" \
NAGARE_CONTROLLER_IMAGE_ARCHIVE="${work}/archive.tar.gz" \
  bash cluster/bootstrap/net-certmanager/publish-image.sh >"${work}/out" 2>"${work}/err"; then
  cat "${work}/err" >&2
  exit 1
fi

actual="$(skopeo --policy "${policy}" inspect --tls-verify=false --format '{{.Digest}}' "docker://${destination}")"
[ "${actual}" = "${image_digest}" ] || {
  echo "published controller digest differs from the reviewed archive" >&2
  exit 1
}

printf 'changed\n' >> "${work}/archive.tar.gz"
if NAGARE_MODE=local NAGARE_NIX_CACHE_ENABLED=0 NAGARE_REGISTRY_HOST="${registry}" \
  NAGARE_INVENTORY_ADAPTER_CHILD=artifact \
  NAGARE_ARTIFACT_DESTINATION="${destination}" \
  NAGARE_ARTIFACT_EXPECTED_DIGEST="${image_digest}" \
  NAGARE_ARTIFACT_SOURCE_DIGEST="sha256:${source_hash}" \
  NAGARE_CONTROLLER_IMAGE_ARCHIVE="${work}/archive.tar.gz" \
    bash cluster/bootstrap/net-certmanager/publish-image.sh >"${work}/changed-out" 2>"${work}/changed-err"; then
  echo "publisher accepted an archive changed after review" >&2
  exit 1
fi
rg -q 'archive differs from the reviewed source digest' "${work}/changed-err"
printf 'controller image publication and changed-archive refusal passed\n'
