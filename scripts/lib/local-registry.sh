#!/usr/bin/env bash
# Read the exact k3d registry through its container when macOS AirPlay owns the
# host's port 5000. Docker's daemon still reaches the registry by its k3d name.

nagare_local_registry_digest() {
  local destination="$1"
  local prefix="k3d-registry.localhost:5000/"
  local path repository tag response digest
  [[ "${NAGARE_REGISTRY_HOST:-}" == "${prefix%/}" && "$destination" == "$prefix"* ]] || {
    echo "local registry destination differs from the selected context" >&2
    return 2
  }
  path="${destination#"$prefix"}"
  repository="${path%:*}"
  tag="${path##*:}"
  [[ "$repository" =~ ^[a-z0-9][a-z0-9._/-]*$ && "$repository" != *..* \
    && "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ && "$repository:$tag" == "$path" ]] || {
    echo "invalid local registry image destination" >&2
    return 2
  }
  if ! response="$(docker exec k3d-registry.localhost wget -S -O /dev/null \
      --header='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      "http://localhost:5000/v2/${repository}/manifests/${tag}" 2>&1)"; then
    if [[ "$response" == *'HTTP/1.1 404 Not Found'* ]]; then return 4; fi
    printf '%s\n' "$response" >&2
    return 1
  fi
  digest="$(sed -n 's/^[[:space:]]*Docker-Content-Digest:[[:space:]]*\(sha256:[0-9a-f]*\).*/\1/p' <<<"$response" | head -n 1)"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "local registry returned no valid manifest digest" >&2
    return 1
  }
  printf '%s\n' "$digest"
}
