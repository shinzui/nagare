#!/usr/bin/env bash
# A fresh cloud context has no state bucket, Pulumi stack, host, or Kubernetes.
# Its first public review must contain only the prerequisite cloud foundation.
set -euo pipefail

nagarectl_bin="${1:?pass the built nagarectl executable path}"
real_pulumi="$(command -v pulumi)"
real_helm="$(command -v helm)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-bootstrap-foundation.XXXXXX")"
bucket_fixture_pid=
created_controller_archive=0
cleanup() {
  local result=$?
  if test -n "$bucket_fixture_pid"; then kill "$bucket_fixture_pid" 2>/dev/null || true; fi
  if test "$created_controller_archive" = 1; then rm -f "$controller_archive"; fi
  if test "$result" = 0; then
    rm -rf "$fixture_root"
  else
    printf 'Failed fixture retained at %s\n' "$fixture_root" >&2
  fi
}
trap cleanup EXIT

export XDG_CONFIG_HOME="$fixture_root/config"
export XDG_STATE_HOME="$fixture_root/state"
export XDG_CACHE_HOME="$fixture_root/cache"
mkdir -p "$XDG_STATE_HOME"
python3 scripts/foundation_bucket_fixture.py "$XDG_STATE_HOME" "$fixture_root/storage-endpoint" &
bucket_fixture_pid=$!
for _ in {1..100}; do
  test -s "$fixture_root/storage-endpoint" && break
  sleep 0.05
done
test -s "$fixture_root/storage-endpoint"
export CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE="$(cat "$fixture_root/storage-endpoint")"
export CLOUDSDK_ACTIVE_CONFIG_NAME=fixture
export CLOUDSDK_CORE_ACCOUNT=fixture@example.invalid
export NAGARE_PLATFORM_ROOT="$(pwd)"
# The build subprocess is recorded below; no real builder tunnel is involved.
export NIX_BUILDER_TUNNEL_PORT=28157
export NIX_BUILDER_HOST_KEY_B64="$(printf 'ssh-ed25519 fixture-key\n' | base64 | tr -d '\n')"
controller_archive="$NAGARE_PLATFORM_ROOT/cluster/bootstrap/net-certmanager/nagare-net-certmanager-controller.tar.gz"
if test -L "$controller_archive"; then
  printf 'controller fixture archive path is a symlink\n' >&2
  exit 1
fi
if test ! -e "$controller_archive"; then
  printf 'fixture controller image archive\n' > "$controller_archive"
  created_controller_archive=1
fi
export PATH="$fixture_root/bin:$PATH"
export NAGARE_REAL_HELM="$real_helm"
export CLOUDSDK_CORE_PROJECT=fixture-project
export CLOUDSDK_COMPUTE_REGION=us-west1
export NAGARE_MODE=cloud
export NAGARE_PULUMI_BACKEND=gcs
export NAGARE_PULUMI_BACKEND_URL=
export NAGARE_INVENTORY_STORE_URL=
export GOOGLE_APPLICATION_CREDENTIALS="$fixture_root/adc.json"
printf '{"type":"authorized_user","quota_project_id":"fixture-project","account":"fixture@example.invalid"}\n' \
  > "$GOOGLE_APPLICATION_CREDENTIALS"
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
  "config config-helper --format=json --min-expiry=120s --quiet")
    python3 - <<'PYHELPER'
import json, os
print(json.dumps({'credential': {'access_token': 'fixture-token', 'token_expiry': '2099-01-01T00:00:00Z'},
 'configuration': {'active_configuration': 'fixture', 'properties': {
 'core': {'account': 'fixture@example.invalid', 'project': 'fixture-project'},
 'api_endpoint_overrides': {'storage': os.environ['CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE']}}}}))
PYHELPER
    ;;
  "auth list --filter=status:ACTIVE --format=value(account)") printf 'fixture@example.invalid\n' ;;
  "config get-value project") printf 'fixture-project\n' ;;
  "projects describe fixture-project --format=value(projectNumber)") printf '12345\n' ;;
  "services list --enabled --project=fixture-project --format=json")
    if [[ "${NAGARE_TEST_ENABLED_APIS:-0}" == 1 ]]; then
      printf '%s\n' '[{"config":{"name":"compute.googleapis.com"}},{"config":{"name":"dns.googleapis.com"}},{"config":{"name":"storage.googleapis.com"}},{"config":{"name":"artifactregistry.googleapis.com"}},{"config":{"name":"certificatemanager.googleapis.com"}},{"config":{"name":"iam.googleapis.com"}},{"config":{"name":"servicenetworking.googleapis.com"}}]'
    else
      printf '[]\n'
    fi ;;
  "storage buckets list --project=fixture-project --format=json(name)") printf '[]\n' ;;
  *) printf 'unexpected gcloud command: %s\n' "$*" >&2; exit 37 ;;
esac
EOF
chmod +x "$fixture_root/bin/gcloud"
cat > "$fixture_root/bin/pulumi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XDG_STATE_HOME/pulumi-plan.log"
printf 'Pulumi was called before the state bucket existed\n' >&2
exit 38
EOF
chmod +x "$fixture_root/bin/pulumi"

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
assert len(operations) == 9, operations
assert {operation["operation"]["executor"] for operation in operations} == {"CloudFoundationExecutor"}, operations
PY
if grep -Eq 'buckets (create|update)|services enable|kubectl|pulumi' "$XDG_STATE_HOME/gcloud.log"; then
  cat "$XDG_STATE_HOME/gcloud.log" >&2
  printf 'foundation planning attempted a provider write\n' >&2
  exit 1
fi
test ! -e "$XDG_STATE_HOME/pulumi-plan.log"
printf 'fresh cloud bootstrap planned nine reviewed foundation resources before Kubernetes\n'

# A fresh context in a shared project must verify already enabled APIs without
# claiming ownership of their existing project-level service registrations.
NAGARE_TEST_ENABLED_APIS=1 "$nagarectl_bin" --context fresh platform bootstrap plan \
  --out "$fixture_root/shared-project-review" > "$fixture_root/shared-project.out" 2>&1 || {
  cat "$fixture_root/shared-project.out" >&2
  exit 1
}
python3 - "$fixture_root/shared-project-review/review.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
resources = [resource for item in review["operations"]
             for resource in item["operation"]["resources"]]
assert len(resources) == 2, resources
assert all("/pulumi-stack/" in resource or "/state-" in resource
           for resource in resources), resources
PY
printf 'shared-project bootstrap left seven enabled APIs outside the owned fixture\n'

# A second isolated context keeps its inventory journal local so the fixture
# can exercise public apply without emulating the GCS object store migration.
sed 's/NAGARE_INVENTORY_STORE=gcs/NAGARE_INVENTORY_STORE=local/' \
  "$XDG_CONFIG_HOME/nagare/contexts/fresh.env" \
  > "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
printf '%s\n' 'NAGARE_PULUMI_BACKEND_MEMBER=serviceAccount:deployer@fixture-project.iam.gserviceaccount.com' \
  >> "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
cat > "$fixture_root/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/gcloud-apply.log"
case "$*" in
  "config config-helper --format=json --min-expiry=120s --quiet")
    python3 - <<'PYHELPER'
import json, os
print(json.dumps({'credential': {'access_token': 'fixture-token', 'token_expiry': '2099-01-01T00:00:00Z'},
 'configuration': {'active_configuration': 'fixture', 'properties': {
 'core': {'account': 'fixture@example.invalid', 'project': 'fixture-project'},
 'api_endpoint_overrides': {'storage': os.environ['CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE']}}}}))
PYHELPER
    ;;
  "auth list --filter=status:ACTIVE --format=value(account)") printf 'fixture@example.invalid\n' ;;
  "auth print-access-token") printf 'fixture-access-token\n' ;;
  "config get-value project") printf 'fixture-project\n' ;;
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
    printf '%s\n' "$3" >> "$XDG_STATE_HOME/enabled-services"
    if test -e "$XDG_STATE_HOME/fail-next-service-enable"; then
      mv "$XDG_STATE_HOME/fail-next-service-enable" "$XDG_STATE_HOME/failed-service-once"
      printf '%s\n' "$3" > "$XDG_STATE_HOME/failed-service"
      printf 'simulated lost gcloud acknowledgement\n' >&2
      exit 42
    fi
    ;;
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
  "storage buckets get-iam-policy gs://fixture-project-nagare-pulumi-state --format=json")
    if test -e "$XDG_STATE_HOME/member-granted"; then
      printf '{"bindings":[{"role":"roles/storage.objectAdmin","members":["serviceAccount:deployer@fixture-project.iam.gserviceaccount.com"]}]}\n'
    else
      printf '{"bindings":[]}\n'
    fi
    ;;
  "storage buckets add-iam-policy-binding gs://fixture-project-nagare-pulumi-state "*)
    touch "$XDG_STATE_HOME/member-granted" ;;
  "storage buckets describe gs://fixture-project-nagare-images --raw --format=value(projectNumber)")
    printf '12345\n' ;;
  "--project=fixture-project compute images describe nagare-image-image --format=json")
    if test -e "$XDG_STATE_HOME/image-created"; then
      printf '{"description":"nagare-content-digest=%s"}\n' "$(cat "$XDG_STATE_HOME/image-digest")"
    else
      printf 'image was not found\n' >&2
      exit 1
    fi ;;
  "--project=fixture-project compute images describe nagare-image-image --format=value(description)")
    if test -e "$XDG_STATE_HOME/image-created"; then
      printf 'nagare-content-digest=%s\n' "$(cat "$XDG_STATE_HOME/image-digest")"
    else exit 1; fi ;;
  "--project=fixture-project compute images describe nagare-image-image --format=value(selfLink)")
    printf 'https://www.googleapis.com/compute/v1/projects/fixture-project/global/images/nagare-image-image\n' ;;
  "--project=fixture-project compute images create nagare-image-image "*)
    for argument in "$@"; do
      case "$argument" in
        nagare-content-digest=*) printf '%s\n' "${argument#nagare-content-digest=}" > "$XDG_STATE_HOME/image-digest" ;;
      esac
    done
    test -s "$XDG_STATE_HOME/image-digest"
    touch "$XDG_STATE_HOME/image-created"
    if test -e "$XDG_STATE_HOME/fail-next-image-create"; then
      mv "$XDG_STATE_HOME/fail-next-image-create" "$XDG_STATE_HOME/failed-image-once"
      printf 'simulated lost GCE image acknowledgement\n' >&2
      exit 42
    fi ;;
  "--project=fixture-project compute instances describe nagare-01 --zone="*" --format=value(id)")
    printf '98765\n' ;;
  "--project=fixture-project compute start-iap-tunnel nagare-01 22 "*)
    port=''
    for argument in "$@"; do
      case "$argument" in --local-host-port=localhost:*) port="${argument##*:}" ;; esac
    done
    test -n "$port"
    exec python3 -c 'import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen()
while True:
    conn,_=s.accept(); conn.close()' "$port" ;;
  *) printf 'unexpected gcloud command: %s\n' "$*" >&2; exit 37 ;;
esac
EOF
chmod +x "$fixture_root/bin/gcloud"
cat > "$fixture_root/bin/gsutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/gsutil.log"
case "$*" in
  "ls -b gs://fixture-project-nagare-images/") ;;
  "-q stat gs://fixture-project-nagare-images/nagare-image-image.raw.tar.gz")
    test -e "$XDG_STATE_HOME/image-object-created" ;;
  "cp "*" gs://fixture-project-nagare-images/nagare-image-image.raw.tar.gz")
    touch "$XDG_STATE_HOME/image-object-created" ;;
  *) printf 'unexpected gsutil command: %s\n' "$*" >&2; exit 37 ;;
esac
EOF
chmod +x "$fixture_root/bin/gsutil"
cat > "$fixture_root/bin/pulumi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${NAGARE_REAL_PULUMI:-}"; then
  exec "$NAGARE_REAL_PULUMI" "$@"
fi
printf '%s %s\n' "${PULUMI_BACKEND_URL:-unset}" "$*" >> "$XDG_STATE_HOME/pulumi.log"
case "${3:-} ${4:-}" in
  "stack ls")
    if test -e "$XDG_STATE_HOME/fail-next-stack-list"; then
      mv "$XDG_STATE_HOME/fail-next-stack-list" "$XDG_STATE_HOME/failed-stack-list-once"
      printf 'simulated unavailable stack inspection\n' >&2
      exit 43
    fi
    if test -e "$XDG_STATE_HOME/stack-created"; then
      printf '[{"name":"freshlocal","current":false}]\n'
    else
      printf '[]\n'
    fi
    ;;
  "stack init") touch "$XDG_STATE_HOME/stack-created" ;;
  "stack select") test -e "$XDG_STATE_HOME/stack-created" ;;
  "stack export")
    python3 - "$XDG_STATE_HOME/applied-urns" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
urns = path.read_text().splitlines() if path.exists() else []
print(json.dumps({"deployment": {"resources": [
    {"urn": urn, "id": f"fixture-{index}"} for index, urn in enumerate(urns)
]}}))
PY
    ;;
  "config refresh")
    # Restore workstation YAML from the fixture backend's accepted config.
    printf 'config: {}\n' > "$XDG_CONFIG_HOME/nagare/pulumi/Pulumi.${NAGARE_PULUMI_STACK}.yaml"
    ;;
  "config set")
    printf '%s\t%s\n' "$7" "$8" >> "$XDG_STATE_HOME/pulumi-config.tsv" ;;
  "config get")
    test "$5" = imageBucket
    printf 'fixture-project-nagare-images\n' ;;
  "config --json")
    python3 - "$XDG_STATE_HOME/pulumi-config.tsv" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
values = {}
if path.exists():
    for line in path.read_text().splitlines():
        key, value = line.split("\t", 1)
        values[key] = {"value": value, "secret": False}
print(json.dumps(values))
PY
    ;;
  "preview --json")
    test -s "${NAGARE_RESOURCE_DECLARATIONS:?}"
    python3 - "$NAGARE_RESOURCE_DECLARATIONS" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    registrations = json.load(source)["registrations"]
assert len(registrations) in (24, 26), registrations
assert sum(registration["class"] == "managed" for registration in registrations) in (1, 10, 19, 24, 25, 26)
PY
    if [[ " $* " == *" --expect-no-changes "* ]]; then
      printf '{"steps":[]}\n'
      exit 0
    fi
    plan=''
    targets=()
    while test "$#" -gt 0; do
      case "$1" in
        --save-plan) shift; plan="$1" ;;
        --target) shift; targets+=("$1") ;;
      esac
      shift
    done
    test -n "$plan"
    test "${#targets[@]}" -gt 0
    printf 'reviewed-cloud-plan' > "$plan"
    python3 - "${targets[@]}" <<'PY'
import json
import sys
print(json.dumps({"steps": [{"op": "create", "urn": urn, "replaceReasons": []}
                            for urn in sys.argv[1:]]}))
PY
    ;;
  "up --plan")
    plan="$5"
    test "$(cat "$plan")" = reviewed-cloud-plan
    targets=()
    while test "$#" -gt 0; do
      if test "$1" = --target; then shift; targets+=("$1"); fi
      shift
    done
    test "${#targets[@]}" -gt 0
    for target in "${targets[@]}"; do
      if ! grep -Fqx "$target" "$XDG_STATE_HOME/applied-urns" 2>/dev/null; then
        printf '%s\n' "$target" >> "$XDG_STATE_HOME/applied-urns"
      fi
      if [[ "$target" == *"nagare:env:NagarePerimeter::nagare" ]]; then
        touch "$XDG_STATE_HOME/root-applied"
      fi
    done
    if test -e "$XDG_STATE_HOME/fail-next-up"; then
      mv "$XDG_STATE_HOME/fail-next-up" "$XDG_STATE_HOME/failed-up-once"
      printf '%s\n' "${targets[0]}" > "$XDG_STATE_HOME/failed-target"
      printf 'simulated lost Pulumi acknowledgement\n' >&2
      exit 41
    fi
    printf 'reviewed cloud root applied\n'
    ;;
  "version ") printf 'v3.255.0\n' ;;
  *) printf 'unexpected pulumi command: %s\n' "$*" >&2; exit 38 ;;
esac
EOF
chmod +x "$fixture_root/bin/pulumi"
cat > "$fixture_root/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = ci
mkdir -p node_modules/@pulumi/pulumi
printf '{"name":"@pulumi/pulumi"}\n' > node_modules/@pulumi/pulumi/package.json
EOF
chmod +x "$fixture_root/bin/npm"
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/local-review" > "$fixture_root/local-out" 2>&1 || {
  cat "$fixture_root/local-out" >&2
  exit 1
}
cp "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env" "$fixture_root/original-backend.env"
printf '%s\n' 'NAGARE_PULUMI_BACKEND_URL=gs://changed-state-bucket/nagare/freshlocal' \
  >> "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/local-review" --yes \
  > "$fixture_root/changed-out" 2>&1; then
  printf 'changed backend URL unexpectedly applied the review\n' >&2
  exit 1
fi
grep -Eq 'reviewed cloud foundation buckets differ|reviewed foundation target digest differs' \
  "$fixture_root/changed-out" || {
  cat "$fixture_root/changed-out" >&2
  exit 1
}
cp "$fixture_root/original-backend.env" "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
sed 's/deployer@fixture-project/other@fixture-project/' \
  "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env" \
  > "$fixture_root/changed-member.env"
cp "$fixture_root/changed-member.env" "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/local-review" --yes \
  > "$fixture_root/member-changed-out" 2>&1; then
  printf 'changed backend member unexpectedly applied the review\n' >&2
  exit 1
fi
sed 's/other@fixture-project/deployer@fixture-project/' \
  "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env" \
  > "$fixture_root/restored-member.env"
cp "$fixture_root/restored-member.env" "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
if grep -Eq 'services enable|buckets (create|update)' "$XDG_STATE_HOME/gcloud-apply.log"; then
  printf 'changed backend URL attempted a provider write\n' >&2
  exit 1
fi
touch "$XDG_STATE_HOME/fail-next-service-enable"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/local-review" --yes \
  > "$fixture_root/apply-out" 2>&1; then
  printf 'foundation apply unexpectedly acknowledged a simulated lost result\n' >&2
  exit 1
fi
test -s "$XDG_STATE_HOME/failed-service"
foundation_transaction="$(python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is not None, head
print(head["activeTransaction"])
PY
)"
"$nagarectl_bin" --context freshlocal inventory resume "$foundation_transaction" --yes \
  > "$fixture_root/foundation-resume-out" 2>&1 || {
  cat "$fixture_root/foundation-resume-out" >&2
  exit 1
}
failed_service="$(cat "$XDG_STATE_HOME/failed-service")"
test "$(grep -Fc "services enable $failed_service --project=fixture-project" "$XDG_STATE_HOME/gcloud-apply.log")" -eq 1
printf 'public inventory resume proved a lost foundation API acknowledgement without repeating its write\n'
test -e "$XDG_STATE_HOME/bucket-updated"
test -e "$XDG_STATE_HOME/member-granted"
test -e "$XDG_STATE_HOME/stack-created"
grep -q $'^nagare:manageProjectApis\tfalse$' "$XDG_STATE_HOME/pulumi-config.tsv"
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

# Initial GCS recovery must use the original local foundation journal before
# migrating it. Stop after the bucket exists, with no stack mutation intent.
(
  export XDG_CONFIG_HOME="$fixture_root/gcs-recovery/config"
  export XDG_STATE_HOME="$fixture_root/gcs-recovery/state"
  export XDG_CACHE_HOME="$fixture_root/gcs-recovery/cache"
  mkdir -p "$XDG_CONFIG_HOME/nagare/contexts" "$XDG_STATE_HOME"
  sed 's/NAGARE_INVENTORY_STORE=local/NAGARE_INVENTORY_STORE=gcs/' \
    "$fixture_root/original-backend.env" > "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
  python3 scripts/foundation_bucket_fixture.py "$XDG_STATE_HOME" "$fixture_root/gcs-recovery/endpoint" &
  recovery_fixture_pid=$!
  trap 'kill "$recovery_fixture_pid" 2>/dev/null || true' EXIT
  for _ in {1..100}; do
    test -s "$fixture_root/gcs-recovery/endpoint" && break
    sleep 0.05
  done
  export CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE="$(cat "$fixture_root/gcs-recovery/endpoint")"
  "$nagarectl_bin" --context freshlocal platform bootstrap plan \
    --out "$fixture_root/gcs-recovery/review" > "$fixture_root/gcs-recovery/plan.out" 2>&1 || {
    cat "$fixture_root/gcs-recovery/plan.out" >&2; exit 1;
  }
  touch "$XDG_STATE_HOME/fail-next-stack-list"
  if "$nagarectl_bin" --context freshlocal platform bootstrap apply \
    "$fixture_root/gcs-recovery/review" --yes > "$fixture_root/gcs-recovery/apply.out" 2>&1; then
    printf 'initial GCS foundation unexpectedly passed unavailable stack inspection\n' >&2; exit 1
  fi
  test -e "$XDG_STATE_HOME/bucket-created"
  test -e "$XDG_STATE_HOME/failed-stack-list-once"
  test ! -e "$XDG_STATE_HOME/stack-created"
  transaction="$(python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json, sys
head = json.load(open(sys.argv[1]))
assert head['activeTransaction'] is not None, head
assert head.get('migration') is None, head
print(head['activeTransaction'])
PY
)"
  "$nagarectl_bin" --context freshlocal inventory resume "$transaction" --yes \
    > "$fixture_root/gcs-recovery/resume.out" 2>&1 || {
    cat "$fixture_root/gcs-recovery/resume.out" >&2; exit 1;
  }
  test "$(grep -c '^storage buckets create ' "$XDG_STATE_HOME/gcloud-apply.log")" -eq 1
  test "$(grep -c ' stack init ' "$XDG_STATE_HOME/pulumi.log")" -eq 1
  python3 - "$XDG_STATE_HOME" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
local = json.loads((root/'nagare/freshlocal/inventory/head.json').read_text())
assert local['activeTransaction'] is None, local
assert local['accepted'] == local['converged'], local
assert local.get('migration') is not None, local
objects = json.loads((root/'remote-objects.json').read_text())
heads = [json.loads(v['bytes']) for k, v in objects.items() if k.endswith('/head.json')]
assert len(heads) == 1, heads
remote = heads[0]
assert remote['activeTransaction'] is None, remote
assert remote['accepted'] == local['accepted'], (remote, local)
assert remote['converged'] == local['converged'], (remote, local)
assert remote['sequence'] == local['sequence'], (remote, local)
for path in (root/'nagare/freshlocal/inventory/journal').glob('*.json'):
    copies = [v['bytes'] for k, v in objects.items() if k.endswith('/journal/'+path.name)]
    assert copies == [path.read_text()], path
PY
  "$nagarectl_bin" --context freshlocal inventory store status --json \
    > "$fixture_root/gcs-recovery/status.out" 2>&1 || {
    cat "$fixture_root/gcs-recovery/status.out" >&2; exit 1;
  }
  printf 'initial GCS foundation resumed its original local journal and migrated only after convergence\n'
)

cp "$XDG_STATE_HOME/enabled-services" "$fixture_root/enabled-services.saved"
sed '/^compute.googleapis.com$/d' "$fixture_root/enabled-services.saved" \
  > "$XDG_STATE_HOME/enabled-services"
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/drift-review" \
  > "$fixture_root/drift-out" 2>&1 || {
  cat "$fixture_root/drift-out" >&2
  exit 1
}
python3 - "$fixture_root/drift-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert len(operations) == 1, operations
assert operations[0]["operation"]["executor"] == "CloudFoundationExecutor", operations
assert "compute.googleapis.com" in str(operations[0]["operation"]["resources"]), operations
PY
cp "$fixture_root/enabled-services.saved" "$XDG_STATE_HOME/enabled-services"
printf 'an observed foundation drift planned a focused reviewed repair\n'

"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/cloud-root-review" \
  > "$fixture_root/cloud-root-out" 2>&1 || {
  cat "$fixture_root/cloud-root-out" >&2
  exit 1
}
python3 - "$fixture_root/cloud-root-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert len(operations) == 1, operations
assert operations[0]["operation"]["executor"] == "PulumiExecutor", operations
assert len(operations[0]["operation"]["resources"]) == 24, operations
assert "platform:cloud/nagare/nagare" in operations[0]["operation"]["resources"]
PY
printf 'the next public review grouped all 24 Pulumi registrations in one saved plan\n'
layer_review="$fixture_root/cloud-root-review"
touch "$XDG_STATE_HOME/fail-next-up"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$layer_review" --yes \
  > "$fixture_root/cloud-layer-apply-out" 2>&1; then
  printf 'cloud apply unexpectedly acknowledged a simulated lost result\n' >&2
  exit 1
fi
test -s "$XDG_STATE_HOME/failed-target"
transaction="$(python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is not None, head
print(head["activeTransaction"])
PY
)"
cp "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env" "$fixture_root/local-profile-before-refusal.env"
sed 's/NAGARE_INVENTORY_STORE=local/NAGARE_INVENTORY_STORE=gcs/' \
  "$fixture_root/local-profile-before-refusal.env" > "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
cp "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" "$fixture_root/nonfoundation-head-before.json"
cp "$XDG_STATE_HOME/pulumi.log" "$fixture_root/nonfoundation-pulumi-before.log"
if "$nagarectl_bin" --context freshlocal inventory resume "$transaction" --yes \
  > "$fixture_root/nonfoundation-resume-refusal.out" 2>&1; then
  printf 'GCS recovery unexpectedly selected a non-foundation local transaction\n' >&2; exit 1
fi
grep -q 'local inventory recovery requires the exact active initial cloud foundation review' \
  "$fixture_root/nonfoundation-resume-refusal.out" || {
  cat "$fixture_root/nonfoundation-resume-refusal.out" >&2; exit 1;
}
cmp "$fixture_root/nonfoundation-head-before.json" "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json"
cmp "$fixture_root/nonfoundation-pulumi-before.log" "$XDG_STATE_HOME/pulumi.log"
cp "$fixture_root/local-profile-before-refusal.env" "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
printf 'initial GCS recovery refused an unrelated active local transaction without effects\n'
"$nagarectl_bin" --context freshlocal inventory resume "$transaction" --yes \
  > "$fixture_root/cloud-layer-resume-out" 2>&1 || {
  cat "$fixture_root/cloud-layer-resume-out" >&2
  exit 1
}
failed_target="$(cat "$XDG_STATE_HOME/failed-target")"
test -e "$XDG_STATE_HOME/root-applied"
test "$(grep -Fc " up --plan " "$XDG_STATE_HOME/pulumi.log")" -eq 1
test "$(grep -F " up --plan " "$XDG_STATE_HOME/pulumi.log" | grep -Fc "$failed_target")" -eq 1
printf 'public inventory resume proved a lost grouped Pulumi acknowledgement without repeating its write\n'
test "$(wc -l < "$XDG_STATE_HOME/applied-urns")" -eq 24
python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is None, head
assert head["accepted"] == head["converged"], head
assert len(head["accepted"]) == 2, head
PY
printf 'one public cloud review converged all 24 foundation-managed Pulumi registrations\n'
cp "$XDG_STATE_HOME/applied-urns" "$fixture_root/applied-urns.saved"
sed '/::nagare-network-fw-web$/d' "$fixture_root/applied-urns.saved" \
  > "$XDG_STATE_HOME/applied-urns"
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/cloud-drift-review" \
  > "$fixture_root/cloud-drift-out" 2>&1 || {
  cat "$fixture_root/cloud-drift-out" >&2
  exit 1
}
python3 - "$fixture_root/cloud-drift-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert len(operations) == 1, operations
assert operations[0]["operation"]["resources"] == [
    "platform:cloud/nagare-network-fw-web/nagare-network-fw-web"
], operations
PY
cp "$fixture_root/applied-urns.saved" "$XDG_STATE_HOME/applied-urns"
printf 'an observed Pulumi absence planned one reviewed cloud repair\n'

# The next public review must bind the Nix output before a remote build.
mkdir -p "$XDG_CONFIG_HOME/nagare/hosts/freshlocal"
touch "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/flake.nix" \
  "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/host.nix"
export NAGARE_TEST_IMAGE_OUTPUT="$fixture_root/image-output"
cat > "$fixture_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/nix.log"
case "${1:-} ${2:-}" in
  "eval --raw") printf '%s' "$NAGARE_TEST_IMAGE_OUTPUT" ;;
  "config show") printf 'system = aarch64-darwin\n' ;;
  "build --builders")
    mkdir -p "$NAGARE_TEST_IMAGE_OUTPUT"
    printf 'fixture image\n' | gzip > "$NAGARE_TEST_IMAGE_OUTPUT/nagare.raw.tar.gz"
    printf '%s\n' "$NAGARE_TEST_IMAGE_OUTPUT" ;;
  "build --no-link") printf '%s\n' "$XDG_STATE_HOME/host-closure" ;;
  "eval --json")
    case "$*" in
      *"authorizedKeys.keys") printf '["ssh-ed25519 fixture-key"]\n' ;;
      *) printf 'false\n' ;;
    esac ;;
  "copy --no-check-sigs") ;;
  *) printf 'unexpected nix command: %s\n' "$*" >&2; exit 39 ;;
esac
EOF
cat > "$fixture_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
logline="$*"
case "$logline" in
  *"nagare-safe-activate arm "*) logline='host arm' ;;
  *"nagare-safe-activate activate "*) logline='host activate' ;;
  *"nagare-safe-activate commit "*) logline='host commit' ;;
esac
printf '%s\n' "$logline" >> "$XDG_STATE_HOME/ssh.log"
new="$XDG_STATE_HOME/host-closure"
current='/fixture/old-closure'
if test -e "$XDG_STATE_HOME/host-activated"; then current="$new"; fi
case "$*" in
  *"printf \"current=%s"*)
    printf 'current=%s\n' "$current"
    if test -e "$XDG_STATE_HOME/host-committed"; then
      printf 'profile=%s\ntimer=inactive\n' "$new"
    elif test -e "$XDG_STATE_HOME/host-armed"; then
      printf 'profile=/fixture/old-closure\ntimer=active\n'
    else
      printf 'profile=/fixture/old-closure\ntimer=inactive\n'
    fi ;;
  *"nagare-safe-activate arm "*)
    touch "$XDG_STATE_HOME/host-armed"
    printf 'ARMED\n' ;;
  *"nagare-safe-activate activate "*)
    touch "$XDG_STATE_HOME/host-activated"
    printf 'ACTIVATED\n' ;;
  *"nagare-safe-activate commit "*)
    mv "$XDG_STATE_HOME/host-armed" "$XDG_STATE_HOME/host-committed"
    if test -e "$XDG_STATE_HOME/fail-host-commit-ack"; then
      mv "$XDG_STATE_HOME/fail-host-commit-ack" "$XDG_STATE_HOME/failed-host-commit-ack"
      exit 42
    fi
    printf 'COMMITTED new=%s\n' "$new" ;;
  *"nagare-host-age-key status"*) printf 'age-key\tmissing\t/var/lib/sops-nix/age-key.txt\tmissing\n' ;;
  *"sudo -n true && readlink -f /run/current-system"*) printf '%s\n' "$current" ;;
  *"sudo cat /etc/rancher/k3s/k3s.yaml"*) cat "$XDG_STATE_HOME/remote-kubeconfig.yaml" ;;
  *"readlink -f /run/current-system"*) printf '%s\n' "$current" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fixture_root/bin/nix" "$fixture_root/bin/ssh"
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/build-review" \
  > "$fixture_root/build-plan-out" 2>&1 || {
  cat "$fixture_root/build-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/build-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert len(operations) == 1, operations
assert operations[0]["operation"]["executor"] == "ArtifactExecutor", operations
assert operations[0]["operation"]["resources"] == [
    "platform:host-image-build/host-image/host-image-build"
], operations
PY
test ! -e "$NAGARE_TEST_IMAGE_OUTPUT"
cp "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env" "$fixture_root/freshlocal.env.saved"
sed 's/NAGARE_PLATFORM_VERSION=0.4.0/NAGARE_PLATFORM_VERSION=0.4.1/' \
  "$fixture_root/freshlocal.env.saved" > "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/build-review" --yes \
  > "$fixture_root/changed-payload-apply-out" 2>&1; then
  printf 'changed payload pin unexpectedly applied the reviewed image build\n' >&2
  exit 1
fi
test ! -e "$NAGARE_TEST_IMAGE_OUTPUT"
if grep -q 'build --builders' "$XDG_STATE_HOME/nix.log"; then
  printf 'changed payload pin reached the Nix builder\n' >&2
  exit 1
fi
cp "$fixture_root/freshlocal.env.saved" "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env"
printf 'changed payload pin refused the retained build review before its provider effect\n'
"$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/build-review" --yes \
  > "$fixture_root/build-apply-out" 2>&1 || {
  cat "$fixture_root/build-apply-out" >&2
  exit 1
}
test -s "$NAGARE_TEST_IMAGE_OUTPUT/nagare.raw.tar.gz"
printf 'public bootstrap reviewed the Nix image build before its first build effect\n'
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/image-review" \
  > "$fixture_root/image-plan-out" 2>&1 || {
  cat "$fixture_root/image-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/image-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert len(operations) == 1, operations
assert operations[0]["operation"]["executor"] == "ArtifactExecutor", operations
assert operations[0]["operation"]["resources"] == [
    "platform:host-image/gce-image/nagare-image-image"
], operations
PY
test ! -e "$XDG_STATE_HOME/image-created"
printf 'public bootstrap bound the built tarball digest to a separate GCE image review\n'
touch "$XDG_STATE_HOME/fail-next-image-create"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/image-review" --yes \
  > "$fixture_root/image-apply-out" 2>&1; then
  printf 'GCE image apply unexpectedly acknowledged a simulated lost result\n' >&2
  exit 1
fi
image_transaction="$(python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is not None, head
print(head["activeTransaction"])
PY
)"
"$nagarectl_bin" --context freshlocal inventory resume "$image_transaction" --yes \
  > "$fixture_root/image-resume-out" 2>&1 || {
  cat "$fixture_root/image-resume-out" >&2
  tail -30 "$XDG_STATE_HOME/gcloud-apply.log" >&2
  tail -30 "$XDG_STATE_HOME/gsutil.log" >&2 2>/dev/null || true
  exit 1
}
test -e "$XDG_STATE_HOME/image-created"
test -e "$XDG_STATE_HOME/image-object-created"
test "$(grep -Fc 'compute images create nagare-image-image' "$XDG_STATE_HOME/gcloud-apply.log")" -eq 1
printf 'public inventory resume proved GCE image publication without repeating registration\n'
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/image-config-review" \
  > "$fixture_root/image-config-plan-out" 2>&1 || {
  cat "$fixture_root/image-config-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/image-config-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert len(operations) == 1, operations
assert operations[0]["operation"]["executor"] == "CloudFoundationExecutor", operations
assert operations[0]["operation"]["resources"] == [
    "platform:cloud-foundation/pulumi-stack/freshlocal"
], operations
PY
"$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/image-config-review" --yes \
  > "$fixture_root/image-config-apply-out" 2>&1 || {
  cat "$fixture_root/image-config-apply-out" >&2
  exit 1
}
grep -Fq $'nagare:nagareImageSelfLink\thttps://www.googleapis.com/compute/v1/projects/fixture-project/global/images/nagare-image-image' \
  "$XDG_STATE_HOME/pulumi-config.tsv"
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/vm-component-review" \
  > "$fixture_root/vm-component-plan-out" 2>&1 || {
  cat "$fixture_root/vm-component-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/vm-component-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert len(operations) == 1, operations
assert operations[0]["operation"]["executor"] == "PulumiExecutor", operations
assert set(operations[0]["operation"]["resources"]) == {
    "platform:cloud/nagare-instance/nagare-01",
    "platform:cloud/nagare-instance-vm/nagare-01",
}, operations
PY
"$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/vm-component-review" --yes \
  > "$fixture_root/vm-component-apply-out" 2>&1 || {
  cat "$fixture_root/vm-component-apply-out" >&2
  exit 1
}
test "$(wc -l < "$XDG_STATE_HOME/applied-urns")" -eq 26
printf 'reviewed image config enabled and converged both VM registrations\n'
cat > "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/host.nix" <<'EOF'
hostName = "freshlocal-nagare";
    registryCredentialOwner = "platform:host/nixos-system/system";
    registryServingControllerOwner = "platform:serving/serving/object-cb13aaa7348f14c3bc1ee1cf94987eb1803ad266";
EOF
printf '{}\n' > "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/flake.lock"
# Persisted operation inputs are sorted canonically. Force their wire order to
# differ from the compiler's configuration-then-lock order, as in the GCP fixture.
python3 - "$XDG_CONFIG_HOME/nagare/hosts/freshlocal" <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
configuration = hashlib.sha256((root / "flake.nix").read_bytes() + (root / "host.nix").read_bytes()).hexdigest()
for padding in range(1000):
    lock = b"{}" + b" " * padding + b"\n"
    if hashlib.sha256(lock).hexdigest() < configuration:
        (root / "flake.lock").write_bytes(lock)
        break
else:
    raise AssertionError("could not construct reversed canonical input order")
PY
printf 'ssh-ed25519 fixture-key fixture@example.invalid\n' > "$fixture_root/operator.pub"
export NAGARE_SSH_PUBLIC_KEY_FILE="$fixture_root/operator.pub"
cat > "$fixture_root/bin/nagarectl" <<'EOF'
#!/usr/bin/env bash
if test "$*" = 'host name'; then
  printf 'freshlocal-nagare\n'
else
  printf 'unexpected nested nagarectl command: %s\n' "$*" >&2
  exit 44
fi
EOF
chmod +x "$fixture_root/bin/nagarectl"
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/host-review" \
  > "$fixture_root/host-plan-out" 2>&1 || {
  cat "$fixture_root/host-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/host-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert {operation["operation"]["executor"] for operation in operations} == {"HostExecutor"}, operations
assert any(operation["operation"]["action"]["tag"] == "RunDeclaredOperation" for operation in operations), operations
PY
printf 'public bootstrap planned guarded host activation after the VM receipts\n'
touch "$XDG_STATE_HOME/fail-host-commit-ack"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/host-review" --yes \
  > "$fixture_root/host-apply-out" 2>&1; then
  printf 'host apply unexpectedly acknowledged a simulated lost commit result\n' >&2
  exit 1
fi
test -e "$XDG_STATE_HOME/host-committed"
host_transaction="$(python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is not None, head
print(head["activeTransaction"])
PY
)"
"$nagarectl_bin" --context freshlocal inventory resume "$host_transaction" --yes \
  > "$fixture_root/host-resume-out" 2>&1 || {
  cat "$fixture_root/host-apply-out" >&2
  cat "$fixture_root/host-resume-out" >&2
  tail -25 "$XDG_STATE_HOME/ssh.log" >&2
  exit 1
}
test "$(grep -Fc 'host activate' "$XDG_STATE_HOME/ssh.log")" -eq 1
printf 'public inventory resume proved guarded host activation after lost commit acknowledgement\n'

# Same-payload host updates use an explicit public review, never bootstrap's
# strict unchanged-host prerequisite shortcut or the legacy shell recipe.
if "$nagarectl_bin" --context freshlocal host apply "$fixture_root/vm-component-review" --yes \
  > "$fixture_root/host-foreign-review-out" 2>&1; then
  printf 'host apply accepted a cloud review\n' >&2; exit 1
fi
grep -q 'host-only review' "$fixture_root/host-foreign-review-out"
cp "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" "$fixture_root/host-update-before.json"
cp "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/flake.lock" "$fixture_root/host-lock-before"
printf '\n' >> "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/flake.lock"
if "$nagarectl_bin" --context freshlocal host plan --save-plan "$fixture_root/host-repin-refused" \
  > "$fixture_root/host-repin-out" 2>&1; then
  printf 'host plan accepted a changed dependency lock\n' >&2; exit 1
fi
grep -q 'cannot change the accepted flake.lock' "$fixture_root/host-repin-out"
cp "$fixture_root/host-lock-before" "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/flake.lock"
printf '\n# reviewed host input revision\n' >> "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/host.nix"
"$nagarectl_bin" --context freshlocal host plan --save-plan "$fixture_root/host-update-review" \
  > "$fixture_root/host-update-plan-out" 2>&1 || { cat "$fixture_root/host-update-plan-out" >&2; exit 1; }
python3 - "$fixture_root/host-update-review/review.json" <<'PYHOST'
import json,sys
review=json.load(open(sys.argv[1]))
assert {o['operation']['executor'] for o in review['operations']} == {'HostExecutor'}, review
assert any(o['operation']['action']['tag']=='UpdateResource' for o in review['operations']), review
PYHOST
cp "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/host.nix" "$fixture_root/reviewed-host-input"
printf '\n# unreviewed input\n' >> "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/host.nix"
if "$nagarectl_bin" --context freshlocal host apply "$fixture_root/host-update-review" --yes \
  > "$fixture_root/host-update-stale-out" 2>&1; then
  printf 'host apply accepted changed source input\n' >&2; exit 1
fi
cmp "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" "$fixture_root/host-update-before.json"
cp "$fixture_root/reviewed-host-input" "$XDG_CONFIG_HOME/nagare/hosts/freshlocal/host.nix"
"$nagarectl_bin" --context freshlocal host apply "$fixture_root/host-update-review" --yes \
  > "$fixture_root/host-update-apply-out" 2>&1 || { cat "$fixture_root/host-update-apply-out" >&2; exit 1; }
"$nagarectl_bin" --context freshlocal host plan --save-plan "$fixture_root/host-update-replay" \
  > "$fixture_root/host-replay-plan-out" 2>&1 || { cat "$fixture_root/host-replay-plan-out" >&2; exit 1; }
"$nagarectl_bin" --context freshlocal host apply "$fixture_root/host-update-replay" --yes \
  > "$fixture_root/host-replay-apply-out" 2>&1 || { cat "$fixture_root/host-replay-apply-out" >&2; exit 1; }
test "$(grep -Fc 'host activate' "$XDG_STATE_HOME/ssh.log")" -eq 1
printf 'reviewed host input update and replay preserved the already committed closure without activation\n'
cat > "$XDG_STATE_HOME/remote-kubeconfig.yaml" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: default
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority-data: Y2E=
users:
  - name: default
    user:
      client-certificate-data: Y2VydA==
      client-key-data: a2V5
contexts:
  - name: default
    context:
      cluster: default
      user: default
current-context: default
EOF
printf 'fixture-private-key\n' > "$fixture_root/ssh-key"
chmod 0600 "$fixture_root/ssh-key"
export SSH_KEY="$fixture_root/ssh-key"
export ZONE=us-west1-a
cat > "$fixture_root/bin/socat" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$fixture_root/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/kubectl.log"
case "$*" in
  "config set-cluster "*|"config set-context "*|"config use-context freshlocal") ;;
  "config current-context") printf 'freshlocal\n' ;;
  "get nodes -o json --request-timeout=10s")
    printf '{"items":[{"metadata":{"name":"freshlocal-nagare","labels":{"node-role.kubernetes.io/control-plane":""}}}]}\n' ;;
  "--context freshlocal version -o json")
    printf '{"serverVersion":{"gitVersion":"v1.33.0+k3s1"}}\n' ;;
  "--context freshlocal --request-timeout=10s get "*) ;;
  "--context freshlocal -n "*" get "*" -o json") printf '{}\n' ;;
  *) printf 'unexpected kubectl command: %s\n' "$*" >&2; exit 43 ;;
esac
EOF
chmod +x "$fixture_root/bin/socat" "$fixture_root/bin/kubectl"

# Inherited delivery inputs need the same v2 receipt authority as CLI flags.
printf 'AGE-SECRET-KEY-1PUBLIC-FIXTURE-CANARY\n' > "$fixture_root/host-key"
NAGARE_HOST_AGE_KEY_FILE="$fixture_root/host-key" \
  "$nagarectl_bin" --context freshlocal host plan --save-plan "$fixture_root/inherited-key-review" \
  > "$fixture_root/inherited-key-plan-out" 2>&1 || { cat "$fixture_root/inherited-key-plan-out" >&2; exit 1; }
python3 - "$fixture_root/inherited-key-review" "$XDG_STATE_HOME/nagare/freshlocal/inventory/native" <<'PYKEY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); plans=[]
for path in root.rglob('*'):
    if not path.is_file(): continue
    raw=path.read_bytes()
    assert b'AGE-SECRET-KEY-1PUBLIC-FIXTURE-CANARY' not in raw, path
    try: value=json.loads(raw)
    except (ValueError,UnicodeError): continue
review=json.loads((root/'review.json').read_text())
for operation in review['operations']:
    if operation['operation']['executor'] != 'HostExecutor': continue
    path=pathlib.Path(sys.argv[2])/(operation['nativeDigest']+'.json')
    raw=path.read_bytes()
    assert b'AGE-SECRET-KEY-1PUBLIC-FIXTURE-CANARY' not in raw, path
    plans.append(json.loads(raw))
assert plans, 'no retained native credential plan'
assert all(p['version']==2 and p['credentialReceiptRequired'] for p in plans), plans
PYKEY
printf 'inherited host credential input requires v2 activation receipt without exposing key bytes\n'
cat > "$fixture_root/bin/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/helm.log"
case "$*" in
  "status "*" -o json") printf 'Error: release: not found\n' >&2; exit 1 ;;
  *) exec "$NAGARE_REAL_HELM" "$@" ;;
esac
EOF
chmod +x "$fixture_root/bin/helm"
# An accepted running host must not depend on reevaluating installation media.
# Keep this refusing Nix executable through both kubeconfig and cluster planning.
cat > "$fixture_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected installation-image reevaluation after host acceptance\n' >&2
exit 44
EOF
chmod +x "$fixture_root/bin/nix"
# The shortcut must still reject changed host inputs before fetching credentials.
for input in flake.nix host.nix flake.lock; do
  host_input="$XDG_CONFIG_HOME/nagare/hosts/freshlocal/$input"
  cp "$host_input" "$fixture_root/accepted-host-input"
  printf '\n' >> "$host_input"
  if "$nagarectl_bin" --context freshlocal platform bootstrap plan \
    --out "$fixture_root/changed-$input-review" > "$fixture_root/changed-host-out" 2>&1; then
    printf 'changed accepted host input unexpectedly planned: %s\n' "$input" >&2
    exit 1
  fi
  grep -Fq 'accepted host configuration differs from the selected context' "$fixture_root/changed-host-out" || {
    cat "$fixture_root/changed-host-out" >&2
    exit 1
  }
  test ! -e "$fixture_root/changed-$input-review/review.json"
  cp "$fixture_root/accepted-host-input" "$host_input"
done
printf 'accepted host input changes refused before installation-image evaluation\n'
kubeconfig_destination="$XDG_CONFIG_HOME/nagare/kubeconfigs/freshlocal.yaml"
"$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/kubeconfig-review" \
  > "$fixture_root/kubeconfig-plan-out" 2>&1 || {
  cat "$fixture_root/kubeconfig-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/kubeconfig-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = review["operations"]
assert len(operations) == 1, operations
assert operations[0]["operation"]["executor"] == "ArtifactExecutor", operations
assert operations[0]["operation"]["resources"] == [
    "platform:kubeconfig/context-kubeconfig/freshlocal"
], operations
PY
test ! -e "$kubeconfig_destination"
export NAGARE_TEST_REAL_MV="$(command -v mv)"
export NAGARE_TEST_KUBECONFIG_DESTINATION="$kubeconfig_destination"
cat > "$fixture_root/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
"$NAGARE_TEST_REAL_MV" "$@"
if test "$destination" = "$NAGARE_TEST_KUBECONFIG_DESTINATION" \
  && test -e "$XDG_STATE_HOME/fail-kubeconfig-mv-ack"; then
  printf 'installed\n' >> "$XDG_STATE_HOME/kubeconfig-writes"
  "$NAGARE_TEST_REAL_MV" "$XDG_STATE_HOME/fail-kubeconfig-mv-ack" \
    "$XDG_STATE_HOME/failed-kubeconfig-mv-ack"
  exit 42
fi
EOF
chmod +x "$fixture_root/bin/mv"
touch "$XDG_STATE_HOME/fail-kubeconfig-mv-ack"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/kubeconfig-review" --yes \
  > "$fixture_root/kubeconfig-apply-out" 2>&1; then
  printf 'kubeconfig apply unexpectedly acknowledged a simulated lost result\n' >&2
  exit 1
fi
test -s "$kubeconfig_destination"
kubeconfig_transaction="$(python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is not None, head
print(head["activeTransaction"])
PY
)"
"$nagarectl_bin" --context freshlocal inventory resume "$kubeconfig_transaction" --yes \
  > "$fixture_root/kubeconfig-resume-out" 2>&1 || {
  cat "$fixture_root/kubeconfig-apply-out" >&2
  cat "$fixture_root/kubeconfig-resume-out" >&2
  exit 1
}
test -s "$kubeconfig_destination"
test "$(wc -l < "$XDG_STATE_HOME/kubeconfig-writes")" -eq 1
python3 - "$kubeconfig_destination" <<'PY'
import os
import stat
import sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
if grep -Eq 'client-key-data|a2V5' "$fixture_root/kubeconfig-review/review.json"; then
  printf 'public kubeconfig review exposed credential bytes\n' >&2
  exit 1
fi
python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is None, head
assert head["accepted"] == head["converged"], head
assert len(head["accepted"]) == 6, head
assert all(entry["scope"]["kind"] == "Platform" for entry in head["accepted"]), head
PY
printf 'public inventory resume proved the reviewed kubeconfig install after lost acknowledgement\n'
# A distinct config root consumes the same controlled accepted fixture history.
# Only profile/host inputs cross roots; immutable reviews and head stay untouched.
second_config="$fixture_root/second-config"
mkdir -p "$second_config/nagare/contexts" "$second_config/nagare/hosts"
cp "$XDG_CONFIG_HOME/nagare/contexts/freshlocal.env" "$second_config/nagare/contexts/"
cp -R "$XDG_CONFIG_HOME/nagare/hosts/freshlocal" "$second_config/nagare/hosts/"
cp "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" "$fixture_root/head-before-recovery"
XDG_CONFIG_HOME="$second_config" "$nagarectl_bin" --context freshlocal kubeconfig recover \
  > "$fixture_root/credential-recovery-out" 2>&1 || {
  cat "$fixture_root/credential-recovery-out" >&2
  exit 1
}
second_credential="$second_config/nagare/kubeconfigs/freshlocal.yaml"
cmp "$kubeconfig_destination" "$second_credential"
cmp "$fixture_root/head-before-recovery" "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json"
printf 'changed credential' > "$second_credential"
if XDG_CONFIG_HOME="$second_config" "$nagarectl_bin" --context freshlocal kubeconfig recover \
    > "$fixture_root/changed-credential-out" 2>&1; then
  printf 'credential recovery overwrote a different existing credential\n' >&2
  exit 1
fi
test "$(cat "$second_credential")" = 'changed credential'
grep -q 'different content digest' "$fixture_root/changed-credential-out"
cmp "$fixture_root/head-before-recovery" "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json"
printf 'public credential recovery materialized a second root and preserved changed-file refusal\n'
cat > "$fixture_root/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/skopeo.log"
case "$*" in
  *" inspect --format {{.Digest}} docker-archive:"*)
    printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
  "login --username oauth2accesstoken --password-stdin --authfile "*)
    cat >/dev/null ;;
  "inspect --authfile "*" --format {{.Digest}} docker://"*)
    printf 'manifest unknown\n' >&2; exit 1 ;;
  *) printf 'unexpected skopeo command: %s\n' "$*" >&2; exit 43 ;;
esac
EOF
chmod +x "$fixture_root/bin/skopeo"
export NAGARE_CLUSTER_SECRETS_DIR="$fixture_root/cluster-secrets"
mkdir -p "$NAGARE_CLUSTER_SECRETS_DIR"
touch "$NAGARE_CLUSTER_SECRETS_DIR/grafana-admin.yaml" \
  "$NAGARE_CLUSTER_SECRETS_DIR/alertmanager-config.yaml"
cat > "$fixture_root/bin/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = -d
case "${2##*/}" in
  grafana-admin.yaml)
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin\n  namespace: monitoring\nstringData:\n  admin-user: fixture\n  admin-password: fixture-password\n' ;;
  alertmanager-config.yaml)
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: alertmanager-config\n  namespace: monitoring\nstringData:\n  alertmanager.yaml: fixture\n' ;;
  *) exit 43 ;;
esac
EOF
chmod +x "$fixture_root/bin/sops"
export NAGARE_AUTH_EN_IMAGE="fixture.invalid/en@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export NAGARE_AUTH_SHOMEI_IMAGE="fixture.invalid/shomei@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
export NAGARE_AUTH_ACCESS_IMAGE="fixture.invalid/nagare-access@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
if ! "$nagarectl_bin" --context freshlocal platform bootstrap plan --out "$fixture_root/cluster-review" \
  > "$fixture_root/cluster-plan-out" 2>&1; then
  cat "$fixture_root/cluster-plan-out" >&2
  exit 1
fi
python3 - "$fixture_root/cluster-review/review.json" <<'PY'
import collections
import glob
import json
import os
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = [item["operation"] for item in review["operations"]]
counts = collections.Counter(item["executor"] for item in operations)
assert len(operations) == 211, len(operations)
assert counts["KubernetesExecutor"] == 204, counts
assert counts["HelmExecutor"] == 5 and counts["ArtifactExecutor"] == 2, counts
assert sum(counts.values()) == len(operations), counts
assert all(entry["scope"]["kind"] == "Platform" for entry in review["desiredRevisions"])
marker_id = "platform:bootstrap-stamp/bootstrap/version"
marker_operations = [item for item in operations if marker_id in item["resources"]]
assert len(marker_operations) == 1, marker_operations
marker = marker_operations[0]
assert marker["action"]["tag"] == "CreateResource", marker
assert set(marker["dependencies"]) == {item["id"] for item in operations if item is not marker}
managed = []
for path in glob.glob(os.path.join(os.path.dirname(sys.argv[1]), "scopes", "*.json")):
    with open(path, encoding="utf-8") as source:
        scope = json.load(source)
    assert scope["scope"]["kind"] == "Platform", scope["scope"]
    managed.extend(declaration["contents"] for bundle in scope["bundles"]
                   for declaration in bundle["declarations"] if declaration["tag"] == "Managed")
kubeconfig_id = "platform:kubeconfig/context-kubeconfig/freshlocal"
edge = {"tag": "OrderedAfter", "contents": kubeconfig_id}
cluster_members = [resource for resource in managed if resource["executor"] in
                   ("KubernetesExecutor", "HelmExecutor")]
assert cluster_members, managed
assert all(edge in resource["dependencies"] for resource in cluster_members)
delegated_accounts = [resource for resource in cluster_members if resource["delegations"]]
assert len(delegated_accounts) == 1, delegated_accounts
account = delegated_accounts[0]
assert account["identity"] == "platform:serving/serving/object-cb13aaa7348f14c3bc1ee1cf94987eb1803ad266"
assert account["delegations"] == [{
    "controller": "platform:host/nixos-system/system",
    "fields": ["registry-credential-metadata", "registry-pull-reference"],
    "operations": ["RefreshCredential"],
}], account
marker_members = [resource for resource in managed if resource["identity"] == marker_id]
assert len(marker_members) == 1, marker_members
assert edge in marker_members[0]["dependencies"]
PY
if grep -Fq 'fixture-password' "$fixture_root/cluster-review/review.json"; then
  printf 'public cluster review exposed fixture secret bytes\n' >&2
  exit 1
fi
printf 'public bootstrap planned 211 cluster operations with kubeconfig edges and a final marker\n'

# A controlled head race reaches the apply factory and its native loaders, then
# must refuse admission. Planning alone cannot prove that saved grants survive
# reconstruction for apply/resume.
cp "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" "$fixture_root/cluster-head-before-race"
python3 - "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" <<'PYTEST'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
head = json.loads(path.read_text())
assert head["activeTransaction"] is None and head["executorClaim"] is None
head["generation"] += 1
path.write_text(json.dumps(head, sort_keys=True, separators=(",", ":")))
PYTEST
cp "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json" "$fixture_root/cluster-head-after-race"
if "$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/cluster-review" --yes \
  > "$fixture_root/cluster-stale-apply-out" 2>&1; then
  printf 'cluster apply accepted a changed head\n' >&2
  exit 1
fi
if ! grep -q 'stale-head' "$fixture_root/cluster-stale-apply-out"; then
  cat "$fixture_root/cluster-stale-apply-out" >&2
  printf 'cluster apply refused before completing native reconstruction\n' >&2
  exit 1
fi
cmp "$fixture_root/cluster-head-after-race" "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json"
cp "$fixture_root/cluster-head-before-race" "$XDG_STATE_HOME/nagare/freshlocal/inventory/head.json"
printf 'public cluster apply reconstructed the Serving grant and refused a stale head before admission\n'

# A separate context exercises the same reviewed stack operation with the
# actual Pulumi CLI and an isolated file backend. No cloud provider is used.
sed -e 's/NAGARE_PULUMI_BACKEND=gcs/NAGARE_PULUMI_BACKEND=local/' \
  -e 's/NAGARE_INVENTORY_STORE=gcs/NAGARE_INVENTORY_STORE=local/' \
  "$XDG_CONFIG_HOME/nagare/contexts/fresh.env" \
  > "$XDG_CONFIG_HOME/nagare/contexts/native.env"
export XDG_STATE_HOME="$fixture_root/native-state"
export NAGARE_REAL_PULUMI="$real_pulumi"
mkdir -p "$XDG_STATE_HOME"
"$nagarectl_bin" --context native platform bootstrap plan --out "$fixture_root/native-review" \
  > "$fixture_root/native-plan-out" 2>&1 || {
  cat "$fixture_root/native-plan-out" >&2
  exit 1
}
"$nagarectl_bin" --context native platform bootstrap apply "$fixture_root/native-review" --yes \
  > "$fixture_root/native-apply-out" 2>&1 || {
  cat "$fixture_root/native-apply-out" >&2
  cat "$XDG_STATE_HOME/gcloud-apply.log" >&2 2>/dev/null || true
  cat "$XDG_STATE_HOME/pulumi.log" >&2 2>/dev/null || true
  python3 - "$fixture_root/native-review/review.json" <<'PY' >&2
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
for item in review["operations"]:
    operation = item["operation"]
    print(operation["id"], operation["executor"], operation["action"], operation.get("resources"))
PY
  exit 1
}
test -s "$XDG_CONFIG_HOME/nagare/pulumi/Pulumi.native.yaml"
grep -q 'nagare:manageProjectApis' "$XDG_CONFIG_HOME/nagare/pulumi/Pulumi.native.yaml"
test -e "$XDG_STATE_HOME/nagare/native/inventory/head.json"
printf 'public foundation apply initialized and seeded a native local Pulumi stack\n'
