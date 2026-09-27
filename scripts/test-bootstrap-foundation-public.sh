#!/usr/bin/env bash
# A fresh cloud context has no state bucket, Pulumi stack, host, or Kubernetes.
# Its first public review must contain only the prerequisite cloud foundation.
set -euo pipefail

nagarectl_bin="${1:?pass the built nagarectl executable path}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-bootstrap-foundation.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

export XDG_CONFIG_HOME="$fixture_root/config"
export XDG_STATE_HOME="$fixture_root/state"
export NAGARE_PLATFORM_ROOT="$(pwd)"
export PATH="$fixture_root/bin:$PATH"
export CLOUDSDK_CORE_PROJECT=fixture-project
export CLOUDSDK_COMPUTE_REGION=us-west1
export NAGARE_MODE=cloud
export NAGARE_PULUMI_BACKEND=gcs
export NAGARE_PULUMI_BACKEND_URL=
export NAGARE_INVENTORY_STORE_URL=
mkdir -p "$XDG_CONFIG_HOME/nagare/contexts" "$fixture_root/bin"
cat > "$XDG_CONFIG_HOME/nagare/contexts/fresh.env" <<'EOF'
CLOUDSDK_CORE_PROJECT=fixture-project
CLOUDSDK_COMPUTE_REGION=us-west1
NAGARE_MODE=cloud
NAGARE_PULUMI_BACKEND=gcs
NAGARE_INVENTORY_STORE=gcs
NAGARE_PLATFORM_VERSION=0.4.0
EOF
cat > "$fixture_root/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XDG_STATE_HOME/gcloud.log"
case "$*" in
  "projects describe fixture-project --format=value(projectNumber)") printf '12345\n' ;;
  "services list --enabled --project=fixture-project --format=json") printf '[]\n' ;;
  "storage buckets list --project=fixture-project --format=json(name)") printf '[]\n' ;;
  *) printf 'unexpected gcloud command: %s\n' "$*" >&2; exit 37 ;;
esac
EOF
chmod +x "$fixture_root/bin/gcloud"

"$nagarectl_bin" --context fresh platform bootstrap plan --out "$fixture_root/review" > "$fixture_root/out" 2>&1 || {
  cat "$fixture_root/out" >&2
  cat "$XDG_STATE_HOME/gcloud.log" >&2 2>/dev/null || true
  exit 1
}
python3 - "$fixture_root/review/review.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
assert review["payloadIdentity"] == "nagare-bootstrap:source-development", review
operations = review["operations"]
assert len(operations) == 8, operations
assert {operation["operation"]["executor"] for operation in operations} == {"CloudFoundationExecutor"}, operations
PY
if grep -Eq 'buckets (create|update)|services enable|kubectl|pulumi' "$XDG_STATE_HOME/gcloud.log"; then
  cat "$XDG_STATE_HOME/gcloud.log" >&2
  printf 'foundation planning attempted a provider write\n' >&2
  exit 1
fi
printf 'fresh cloud bootstrap planned eight reviewed foundation resources before Kubernetes\n'

# A second isolated context keeps its inventory journal local so the fixture
# can exercise public apply without emulating the GCS object store migration.
sed 's/NAGARE_INVENTORY_STORE=gcs/NAGARE_INVENTORY_STORE=local/' \
  "$XDG_CONFIG_HOME/nagare/contexts/fresh.env" \
  > "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
cat > "$fixture_root/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/gcloud-apply.log"
case "$*" in
  "projects describe fixture-project --format=value(projectNumber)") printf '12345\n' ;;
  "services list --enabled --project=fixture-project --format=json")
    python3 - "$XDG_STATE_HOME/enabled-services" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
services = path.read_text().splitlines() if path.exists() else []
print(json.dumps([{"config": {"name": service}} for service in services]))
PY
    ;;
  "services enable "*" --project=fixture-project")
    printf '%s\n' "$3" >> "$XDG_STATE_HOME/enabled-services" ;;
  "storage buckets list --project=fixture-project --format=json(name)")
    if test -e "$XDG_STATE_HOME/bucket-created"; then
      printf '[{"name":"fixture-project-nagare-pulumi-state"}]\n'
    else
      printf '[]\n'
    fi
    ;;
  "storage buckets create gs://fixture-project-nagare-pulumi-state "*)
    touch "$XDG_STATE_HOME/bucket-created" ;;
  "storage buckets describe gs://fixture-project-nagare-pulumi-state --raw --format=value(projectNumber)")
    printf '12345\n' ;;
  "storage buckets describe gs://fixture-project-nagare-pulumi-state --raw --format=json")
    if test -e "$XDG_STATE_HOME/bucket-updated"; then
      printf '{"projectNumber":"12345","location":"US-WEST1","versioning":{"enabled":true},"iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true},"publicAccessPrevention":"enforced"}}\n'
    else
      printf '{"projectNumber":"12345","location":"US-WEST1","versioning":{"enabled":false},"iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true},"publicAccessPrevention":"enforced"}}\n'
    fi
    ;;
  "storage buckets update gs://fixture-project-nagare-pulumi-state "*)
    touch "$XDG_STATE_HOME/bucket-updated" ;;
  *) printf 'unexpected gcloud command: %s\n' "$*" >&2; exit 37 ;;
esac
EOF
chmod +x "$fixture_root/bin/gcloud"
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/local-review" > "$fixture_root/local-out" 2>&1 || {
  cat "$fixture_root/local-out" >&2
  exit 1
}
if NAGARE_PULUMI_BACKEND_URL=gs://changed-state-bucket/nagare/freshlocal \
  "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/local-review" --yes \
  > "$fixture_root/changed-out" 2>&1; then
  printf 'changed backend URL unexpectedly applied the review\n' >&2
  exit 1
fi
grep -q 'reviewed cloud foundation buckets differ' "$fixture_root/changed-out"
if grep -Eq 'services enable|buckets (create|update)' "$XDG_STATE_HOME/gcloud-apply.log"; then
  printf 'changed backend URL attempted a provider write\n' >&2
  exit 1
fi
"$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/local-review" --yes > "$fixture_root/apply-out" 2>&1 || {
  cat "$fixture_root/apply-out" >&2
  cat "$XDG_STATE_HOME/gcloud-apply.log" >&2
  exit 1
}
test -e "$XDG_STATE_HOME/bucket-updated"
test "$(wc -l < "$XDG_STATE_HOME/enabled-services")" -eq 7
test "$(grep -c '^storage buckets create ' "$XDG_STATE_HOME/gcloud-apply.log")" -eq 1
test -e "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json"
python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is None, head
assert head["accepted"] == head["converged"], head
assert len(head["accepted"]) == 1, head
PY
printf 'public foundation apply converged and retained its local inventory journal\n'
