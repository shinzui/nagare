#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/nagare-app-image-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
printf 'docker archive fixture\n' >"${work}/image.tar"
source_digest="$(shasum -a 256 "${work}/image.tar" | awk '{print $1}')"
expected="$(printf 'b%.0s' {1..64})"
destination='127.0.0.1:5001/app:v1'
cat >"${work}/skopeo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' inspect '*'docker-archive:'*) printf 'sha256:%s\n' "${TEST_EXPECTED}" ;;
  *' inspect '*'docker://'*)
    if [ -f "${TEST_STATE}" ]; then printf 'sha256:%s\n' "${TEST_EXPECTED}"; else
      echo 'manifest unknown' >&2
      exit 1
    fi ;;
  *' copy '*) touch "${TEST_STATE}" ;;
  *) echo "unexpected skopeo invocation: $*" >&2; exit 2 ;;
esac
STUB
chmod 700 "${work}/skopeo"
request="$(jq -nc --arg archive "${work}/image.tar" --arg dest "${destination}" \
  --arg expected "${expected}" --arg source "${source_digest}" '
  {version:1,resource:"publication:app-image-test/test/oci-image",kind:"OciImageArtifact",
   destination:$dest,expectedDigest:$expected,specDigest:$source,archive:$archive,
   plan:{version:1,resource:"publication:app-image-test/test/oci-image",kind:"OciImageArtifact",
    destination:$dest,expectedDigest:$expected,sourceDigest:$source}}')"
export PATH="${work}:${PATH}" NAGARE_MODE=local NAGARE_REGISTRY_HOST=127.0.0.1:5001
export NAGARE_NIX_CACHE_ENABLED=0 NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED=0
export NAGARE_PULUMI_BACKEND=local NAGARE_INVENTORY_STORE=local
export NAGARE_INVENTORY_ADAPTER_CHILD=artifact TEST_EXPECTED="${expected}" TEST_STATE="${work}/published"

changed="$(jq '.specDigest = ("c" * 64) | .plan.sourceDigest = .specDigest' <<<"${request}")"
if bash "${repo_root}/scripts/inventory-artifact-transport.sh" publish <<<"${changed}" >"${work}/out" 2>"${work}/err"; then
  echo 'changed OCI archive was published' >&2
  exit 1
fi
[ ! -f "${TEST_STATE}" ] || { echo 'changed archive reached skopeo copy' >&2; exit 1; }

wrong_manifest="$(jq '.expectedDigest = ("c" * 64) | .plan.expectedDigest = .expectedDigest' <<<"${request}")"
if bash "${repo_root}/scripts/inventory-artifact-transport.sh" publish <<<"${wrong_manifest}" >"${work}/out" 2>"${work}/err"; then
  echo 'changed OCI manifest was published' >&2
  exit 1
fi
[ ! -f "${TEST_STATE}" ] || { echo 'changed manifest reached skopeo copy' >&2; exit 1; }

result="$(bash "${repo_root}/scripts/inventory-artifact-transport.sh" publish <<<"${request}")"
[ -f "${TEST_STATE}" ] || { echo 'reviewed archive was not copied' >&2; exit 1; }
[ "$(jq -r '.tag' <<<"${result}")" = TransportPresent ]
[ "$(jq -r '.contents[1]' <<<"${result}")" = "${expected}" ]
echo 'application image publication transport passed'
