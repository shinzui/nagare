#!/usr/bin/env bash
set -euo pipefail

# Import Nagare's patched net-certmanager controller into the selected k3s
# image store and update only the controller Deployment. The upstream webhook
# remains byte-for-byte at the latest v1.14.0 release image.

root="${NAGARE_PLATFORM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cluster=""
instance=""

usage() {
  cat >&2 <<'EOF'
usage: install-net-certmanager-controller.sh [--k3d-cluster NAME | --cloud-instance NAME]

With no option, the active Nagare context selects nagare-local in local mode or
NAGARE_INSTANCE_NAME in cloud mode.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --k3d-cluster)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      cluster="$2"
      shift 2
      ;;
    --cloud-instance)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      instance="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [ -n "$cluster" ] && [ -n "$instance" ]; then
  echo "error: select either --k3d-cluster or --cloud-instance, not both" >&2
  exit 2
fi

if [ -z "$cluster" ] && [ -z "$instance" ]; then
  # shellcheck source=scripts/lib/target.sh
  source "$root/scripts/lib/target.sh"
  if [ "${NAGARE_MODE:-cloud}" = "local" ]; then
    cluster="nagare-local"
  else
    _require_target_project
    instance="${NAGARE_INSTANCE_NAME:-nagare-01}"
  fi
fi

case "${cluster:-${instance:-}}" in
  ""|*[!A-Za-z0-9_.-]*)
    echo "error: target name must contain only letters, digits, '.', '_' or '-'" >&2
    exit 2
    ;;
esac

reference_file="$root/cluster/bootstrap/net-certmanager/image-reference"
if [ ! -f "$reference_file" ]; then
  echo "error: missing patched controller reference: $reference_file" >&2
  exit 1
fi
image_reference="$(tr -d '[:space:]' < "$reference_file")"
case "$image_reference" in
  nagare/net-certmanager-controller:v1.14.0-nagare.*) ;;
  *)
    echo "error: unexpected patched controller reference: $image_reference" >&2
    exit 1
    ;;
esac

archive="$root/cluster/bootstrap/net-certmanager/nagare-net-certmanager-controller.tar.gz"
if [ ! -s "$archive" ]; then
  if [ ! -f "$root/flake.nix" ]; then
    echo "error: installed platform payload is missing $archive" >&2
    exit 1
  fi
  archive="$(nix build --no-link --print-out-paths "$root#net-certmanager-controller-image")"
fi
if [ ! -s "$archive" ]; then
  echo "error: patched controller archive is missing or empty: $archive" >&2
  exit 1
fi

if [ -n "$cluster" ]; then
  k3d image import "$archive" --cluster "$cluster"
else
  remote_archive="/tmp/nagare-net-certmanager-controller-$$.tar.gz"
  "$root/scripts/iap-ssh.sh" scp "$archive" "${instance}:${remote_archive}"
  quoted_remote_archive="$(printf '%q' "$remote_archive")"
  remote_script="set -eu; trap 'rm -f ${quoted_remote_archive}' EXIT; sudo k3s ctr images import ${quoted_remote_archive} >/dev/null"
  "$root/scripts/iap-ssh.sh" ssh "$instance" -- "$remote_script"
fi

kubectl -n knative-serving set image \
  deployment/net-certmanager-controller \
  "controller=$image_reference"
kubectl -n knative-serving rollout status \
  deployment/net-certmanager-controller \
  --timeout=5m

actual_image="$(kubectl -n knative-serving get deployment net-certmanager-controller -o jsonpath='{.spec.template.spec.containers[?(@.name=="controller")].image}')"
if [ "$actual_image" != "$image_reference" ]; then
  echo "error: controller deployment uses '$actual_image', expected '$image_reference'" >&2
  exit 1
fi

echo "patched net-certmanager controller ready: $image_reference"
